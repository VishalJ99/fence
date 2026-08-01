import AppKit
import CoreGraphics
import Foundation

struct ScreenContextCaptureRunGate: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var activeRunID: UInt64?

    mutating func beginRun() -> UInt64 {
        generation &+= 1
        activeRunID = generation
        return generation
    }

    func accepts(_ runID: UInt64) -> Bool {
        activeRunID == runID
    }

    mutating func clearCurrentRun() {
        activeRunID = nil
    }

    mutating func finishIfCurrent(_ runID: UInt64) -> Bool {
        guard accepts(runID) else { return false }
        activeRunID = nil
        return true
    }
}

struct ScreenContextInferenceIdentity: Equatable {
    let analysisFingerprint: String
    let observationGeneration: UInt64

    var policyFingerprint: String {
        "\(analysisFingerprint)\u{1D}\(observationGeneration)"
    }
}

struct ScreenContextRequestGate: Equatable {
    private(set) var activeRequestID: UUID?
    private(set) var cancellationRequested = false

    var isIdle: Bool {
        activeRequestID == nil
    }

    mutating func begin(_ requestID: UUID) -> Bool {
        guard isIdle else { return false }
        activeRequestID = requestID
        cancellationRequested = false
        return true
    }

    mutating func requestCancellation() {
        guard activeRequestID != nil else { return }
        cancellationRequested = true
    }

    mutating func complete(_ requestID: UUID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        cancellationRequested = false
        return true
    }
}

final class ScreenContextCoordinator {
    private enum AnalysisStage: Equatable {
        case metadata
        case screenshot
    }

    private struct AnalysisPayload {
        let metadata: ScreenContextMetadata
        let sourceImage: CGImage
        let inferenceIdentity: ScreenContextInferenceIdentity
        let stage: AnalysisStage
        let notBefore: Date
    }

    private let logWindow: ScreenContextLogWindowController
    private let processingQueue = DispatchQueue(
        label: "app.usefence.tab.screen-context-processing",
        qos: .userInitiated
    )
    private let processingQueueKey = DispatchSpecificKey<Void>()
    private let samplingPolicy = ScreenContextSamplingPolicy(
        minimumInterval: 1,
        visualChangeThreshold: 0.012
    )
    private let inferencePolicy = ScreenContextInferencePolicy()
    private let resourceMonitor = ProcessResourceMonitor()
    private let timestampFormatter: DateFormatter

    private var captureSource: AnyObject?
    private var captureRunGate = ScreenContextCaptureRunGate()
    private var previousAcceptedSample: ScreenContextSample?
    private var contextFingerprint: String?
    private var contextStartedAt = Date()
    private var focusGoal: String?
    private var lunaAPIKey: String?
    private var inferenceTask: Task<Void, Never>?
    private var pendingAnalysis: AnalysisPayload?
    private var inFlightAnalysis: AnalysisPayload?
    private var analysisStartScheduled = false
    private var latestProviderMetadata: ScreenContextMetadata?
    private var latestProviderImage: CGImage?
    private var latestInferenceIdentity: ScreenContextInferenceIdentity?
    private var latestObservationGeneration: UInt64 = 0
    private var analysisFingerprintStartedAt = Date()
    private var lastMetadataRequestIdentity: ScreenContextInferenceIdentity?
    private var lastMetadataRequestAt: Date?
    private var lastScreenshotIdentity: ScreenContextInferenceIdentity?
    private var lastScreenshotStartedAt: Date?
    private var sessionRemoteCostCredits = 0.0
    private var analysisGeneration = 0
    private var requestGate = ScreenContextRequestGate()
    private var isRunning = false
    private var framesSinceResourceSample = 0
    private var lastResourceSampleUptime = ProcessInfo.processInfo.systemUptime

    init(logWindow: ScreenContextLogWindowController) {
        self.logWindow = logWindow
        processingQueue.setSpecific(key: processingQueueKey, value: ())
        timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "HH:mm:ss.SSS"

        resourceMonitor.onSample = { [weak self] sample in
            self?.processingQueue.async {
                self?.publishResourceSample(sample)
            }
        }
    }

    func start() {
        processingQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        guard #available(macOS 12.3, *) else {
            logWindow.setCaptureRunning(false)
            logWindow.setStatus("Unavailable on this macOS version")
            logWindow.append("Screen context requires macOS 12.3 or later.")
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            logWindow.setStatus("Waiting for Screen Recording permission")
            logWindow.append(
                "macOS Screen Recording permission is required for Tab's live pixel and window context."
            )
            guard CGRequestScreenCaptureAccess() else {
                logWindow.setCaptureRunning(false)
                logWindow.setStatus("Permission not granted — relaunch after enabling Tab")
                logWindow.append(
                    "Permission is not active. Enable Tab in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Tab."
                )
                return
            }
        }

        isRunning = true
        previousAcceptedSample = nil
        contextFingerprint = nil
        contextStartedAt = Date()
        latestProviderMetadata = nil
        latestProviderImage = nil
        latestInferenceIdentity = nil
        latestObservationGeneration = 0
        lastMetadataRequestIdentity = nil
        lastMetadataRequestAt = nil
        lastScreenshotIdentity = nil
        lastScreenshotStartedAt = nil
        sessionRemoteCostCredits = 0
        framesSinceResourceSample = 0
        lastResourceSampleUptime = ProcessInfo.processInfo.systemUptime
        logWindow.setStatus("Starting ScreenCaptureKit…")
        resourceMonitor.start()

        let source = ScreenCaptureKitContextSource()
        let captureRunID = captureRunGate.beginRun()
        source.onStarted = { [weak self] in
            self?.handleCaptureStarted(runID: captureRunID)
        }
        source.onFrame = { [weak self] frame in
            self?.processingQueue.async {
                guard let self, self.captureRunGate.accepts(captureRunID) else { return }
                self.process(frame)
            }
        }
        source.onError = { [weak self] error in
            self?.handleCaptureError(error, runID: captureRunID)
        }
        source.onStopped = { [weak self] in
            self?.handleCaptureStopped(runID: captureRunID)
        }
        captureSource = source
        source.start()
    }

    func stop(clearCredential: Bool = true) {
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            stopOnQueue(clearCredential: clearCredential)
        } else {
            processingQueue.sync { [weak self] in
                self?.stopOnQueue(clearCredential: clearCredential)
            }
        }
    }

    private func stopOnQueue(clearCredential: Bool) {
        guard isRunning || captureSource != nil else {
            if clearCredential {
                lunaAPIKey = nil
            }
            return
        }
        isRunning = false
        captureRunGate.clearCurrentRun()
        analysisGeneration += 1
        requestGate.requestCancellation()
        inferenceTask?.cancel()
        pendingAnalysis = nil
        analysisStartScheduled = false
        previousAcceptedSample = nil
        latestProviderMetadata = nil
        latestProviderImage = nil
        latestInferenceIdentity = nil
        latestObservationGeneration = 0
        lastMetadataRequestIdentity = nil
        lastMetadataRequestAt = nil
        lastScreenshotIdentity = nil
        lastScreenshotStartedAt = nil
        sessionRemoteCostCredits = 0
        resourceMonitor.stop()

        if #available(macOS 12.3, *),
           let source = captureSource as? ScreenCaptureKitContextSource {
            source.stop()
        }
        captureSource = nil
        if clearCredential {
            lunaAPIKey = nil
            logWindow.clearCredential()
        }
        logWindow.setCaptureRunning(false)
        logWindow.setStatus("Capture is off")
        logWindow.append("Screen context stopped. In-memory frames and credentials were released.")
    }

    func configureFocusGoal(_ goal: String?) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let bounded = ScreenContextText.optionalCollapsed(
                goal,
                maximumCharacters: ScreenContextMetadata.maximumFocusGoalCharacters
            )
            guard bounded != focusGoal else { return }
            focusGoal = bounded
            contextFingerprint = nil
            invalidatePendingInferenceForContextChange()
        }
    }

    func configureLuna(apiKey: String?) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = lunaAPIKey != nil
            let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            lunaAPIKey = trimmed?.isEmpty == false ? trimmed : nil
            if lunaAPIKey == nil {
                analysisGeneration += 1
                requestGate.requestCancellation()
                inferenceTask?.cancel()
                pendingAnalysis = nil
                latestProviderImage = nil
                latestInferenceIdentity = nil
                if wasEnabled {
                    logWindow.append("Luna remote analysis is off. Capture and OCR remain local.")
                }
            } else if !wasEnabled {
                if let latestProviderMetadata {
                    latestInferenceIdentity = ScreenContextInferenceIdentity(
                        analysisFingerprint: latestProviderMetadata.analysisFingerprint,
                        observationGeneration: latestObservationGeneration
                    )
                    analysisFingerprintStartedAt = Date()
                }
                lastMetadataRequestIdentity = nil
                lastMetadataRequestAt = nil
                lastScreenshotIdentity = nil
                lastScreenshotStartedAt = nil
                sessionRemoteCostCredits = 0
                logWindow.append(
                    "Luna remote analysis is on. Tab sends bounded window metadata and local OCR first; a low-detail screenshot is sent only when Luna says the text context is insufficient."
                )
            }
        }
    }

    private func process(_ frame: RawScreenContextFrame) {
        guard isRunning else { return }
        framesSinceResourceSample += 1

        let samples = ScreenImageProcessor.grayscaleSamples(from: frame.image)
        let signature = try? GrayscaleVisualSignature(
            width: 32,
            height: 18,
            samples: samples
        )
        let preliminaryMetadata = ScreenContextMetadata(
            observedAt: frame.receivedAt,
            applicationName: frame.applicationName,
            bundleIdentifier: frame.bundleIdentifier,
            windowTitle: frame.windowTitle,
            focusGoal: focusGoal,
            dwellTime: 0
        )
        if contextFingerprint != preliminaryMetadata.semanticFingerprint {
            contextFingerprint = preliminaryMetadata.semanticFingerprint
            contextStartedAt = frame.receivedAt
            invalidatePendingInferenceForContextChange()
        }
        let metadata = ScreenContextMetadata(
            observedAt: frame.receivedAt,
            applicationName: frame.applicationName,
            bundleIdentifier: frame.bundleIdentifier,
            windowTitle: frame.windowTitle,
            focusGoal: focusGoal,
            dwellTime: frame.receivedAt.timeIntervalSince(contextStartedAt)
        )
        let sample = ScreenContextSample(metadata: metadata, visualSignature: signature)
        let decision = samplingPolicy.decision(
            previousAcceptedSample: previousAcceptedSample,
            candidate: sample
        )
        if decision.shouldSample {
            previousAcceptedSample = sample
            processAcceptedLocalSample(
                frame,
                metadata: metadata,
                decision: decision
            )
        } else {
            refreshProviderDwell(using: metadata)
        }
        evaluateRemoteInference(at: frame.receivedAt)
    }

    private func processAcceptedLocalSample(
        _ frame: RawScreenContextFrame,
        metadata: ScreenContextMetadata,
        decision: ScreenContextSamplingDecision
    ) {
        latestObservationGeneration &+= 1
        let recognizedText: String?
        do {
            let value = try ScreenImageProcessor.recognizedText(from: frame.image)
            recognizedText = value.isEmpty ? nil : value
        } catch {
            recognizedText = nil
            logWindow.append("Local OCR unavailable: \(safeError(error))")
        }

        let localLatency = Date().timeIntervalSince(frame.receivedAt)
        let score = decision.normalizedVisualChangeScore.map {
            String(format: "%.1f%%", $0 * 100)
        } ?? "initial"
        let window = metadata.windowTitle.map { " — \($0)" } ?? ""
        let text = recognizedText ?? "No readable text"
        logWindow.append(
            "[\(timestampFormatter.string(from: frame.receivedAt))] LOCAL · \(metadata.applicationName)\(window)\nchange=\(score) · reason=\(decision.reason.rawValue) · capture+OCR=\(milliseconds(localLatency)) ms\n\(text)"
        )

        let providerMetadata = ScreenContextMetadata(
            observedAt: metadata.observedAt,
            applicationName: metadata.applicationName,
            bundleIdentifier: metadata.bundleIdentifier,
            windowTitle: metadata.windowTitle,
            documentURL: metadata.documentURL,
            focusGoal: metadata.focusGoal,
            visibleTextExcerpt: recognizedText,
            dwellTime: metadata.dwellTime
        )
        let inferenceIdentity = ScreenContextInferenceIdentity(
            analysisFingerprint: providerMetadata.analysisFingerprint,
            observationGeneration: latestObservationGeneration
        )
        if inferenceIdentity != latestInferenceIdentity {
            invalidateInFlightInferenceForContentChange()
            analysisFingerprintStartedAt = frame.receivedAt
        }
        latestProviderMetadata = providerMetadata
        latestProviderImage = frame.image
        latestInferenceIdentity = inferenceIdentity
    }

    private func refreshProviderDwell(using metadata: ScreenContextMetadata) {
        guard let previous = latestProviderMetadata,
              previous.semanticFingerprint == metadata.semanticFingerprint else {
            return
        }
        latestProviderMetadata = ScreenContextMetadata(
            observedAt: metadata.observedAt,
            applicationName: metadata.applicationName,
            bundleIdentifier: metadata.bundleIdentifier,
            windowTitle: metadata.windowTitle,
            documentURL: metadata.documentURL,
            focusGoal: metadata.focusGoal,
            visibleTextExcerpt: previous.visibleTextExcerpt,
            dwellTime: metadata.dwellTime
        )
    }

    private func evaluateRemoteInference(at now: Date) {
        guard lunaAPIKey != nil,
              let metadata = latestProviderMetadata,
              let image = latestProviderImage,
              let inferenceIdentity = latestInferenceIdentity else {
            return
        }
        let decision = inferencePolicy.metadataDecision(
            fingerprintAge: now.timeIntervalSince(analysisFingerprintStartedAt),
            candidateFingerprint: inferenceIdentity.policyFingerprint,
            lastRequestFingerprint: lastMetadataRequestIdentity?.policyFingerprint,
            lastRequestAt: lastMetadataRequestAt,
            now: now
        )
        guard decision.shouldAnalyze else { return }

        let alreadyPending = pendingAnalysis.map {
            $0.stage == .metadata && $0.inferenceIdentity == inferenceIdentity
        } ?? false
        let alreadyInFlight = inFlightAnalysis.map {
            $0.stage == .metadata && $0.inferenceIdentity == inferenceIdentity
        } ?? false
        guard !alreadyPending, !alreadyInFlight else { return }

        pendingAnalysis = AnalysisPayload(
            metadata: metadata,
            sourceImage: image,
            inferenceIdentity: inferenceIdentity,
            stage: .metadata,
            notBefore: now
        )
        startNextAnalysisIfPossible()
    }

    private func startNextAnalysisIfPossible() {
        guard isRunning,
              inferenceTask == nil,
              requestGate.isIdle,
              !analysisStartScheduled,
              lunaAPIKey != nil,
              pendingAnalysis != nil else {
            return
        }

        guard let payload = pendingAnalysis, let key = lunaAPIKey else { return }
        guard payload.inferenceIdentity == latestInferenceIdentity else {
            pendingAnalysis = nil
            startNextAnalysisIfPossible()
            return
        }

        let remaining = payload.notBefore.timeIntervalSinceNow
        if remaining > 0 {
            analysisStartScheduled = true
            processingQueue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.analysisStartScheduled = false
                self?.startNextAnalysisIfPossible()
            }
            return
        }

        pendingAnalysis = nil
        inFlightAnalysis = payload
        let startedAt = Date()
        if payload.stage == .metadata {
            lastMetadataRequestIdentity = payload.inferenceIdentity
            lastMetadataRequestAt = startedAt
        } else {
            lastScreenshotIdentity = payload.inferenceIdentity
            lastScreenshotStartedAt = startedAt
        }
        let generation = analysisGeneration
        let requestID = UUID()
        guard requestGate.begin(requestID) else { return }
        let client = OpenRouterContextClient(apiKeyProvider: { key })
        let jpegImageData: Data?
        if payload.stage == .screenshot {
            guard let encoded = ScreenImageProcessor.jpegData(from: payload.sourceImage) else {
                _ = requestGate.complete(requestID)
                inFlightAnalysis = nil
                logWindow.append("Luna screenshot escalation skipped because JPEG encoding failed.")
                startNextAnalysisIfPossible()
                return
            }
            jpegImageData = encoded
        } else {
            jpegImageData = nil
        }
        let request = ScreenContextAnalysisRequest(
            metadata: payload.metadata,
            jpegImageData: jpegImageData
        )
        let completionQueue = processingQueue

        inferenceTask = Task { [weak self] in
            let outcome: Result<ScreenContextAnalysisResult, Error>
            do {
                outcome = .success(try await client.analyze(request))
            } catch {
                outcome = .failure(error)
            }
            let completion = DispatchWorkItem { [weak self] in
                self?.finishAnalysis(
                    outcome,
                    payload: payload,
                    startedAt: startedAt,
                    generation: generation,
                    requestID: requestID
                )
            }
            completionQueue.async(execute: completion)
        }
    }

    private func finishAnalysis(
        _ outcome: Result<ScreenContextAnalysisResult, Error>,
        payload: AnalysisPayload,
        startedAt: Date,
        generation: Int,
        requestID: UUID
    ) {
        guard requestGate.complete(requestID) else { return }
        inferenceTask = nil
        inFlightAnalysis = nil
        guard generation == analysisGeneration else {
            startNextAnalysisIfPossible()
            return
        }
        let latency = Date().timeIntervalSince(startedAt)

        switch outcome {
        case let .success(result):
            let analysis = result.analysis
            if let billedCredits = result.usage?.billedCredits {
                sessionRemoteCostCredits += billedCredits
            }
            let usage = result.usage.map {
                let cost = $0.billedCredits.map {
                    String(format: " · credits %.6f · session %.4f", $0, sessionRemoteCostCredits)
                } ?? ""
                return " · tokens \($0.inputTokens)+\($0.outputTokens)\(cost)"
            } ?? ""
            guard payload.inferenceIdentity == latestInferenceIdentity else {
                if payload.stage == .metadata {
                    lastMetadataRequestIdentity = nil
                }
                logWindow.append(
                    "[\(timestampFormatter.string(from: Date()))] LUNA STALE · result discarded\nAPI=\(milliseconds(latency)) ms\(usage)"
                )
                startNextAnalysisIfPossible()
                return
            }
            let stage = payload.stage == .metadata ? "TEXT" : "IMAGE"
            logWindow.append(
                "[\(timestampFormatter.string(from: Date()))] LUNA \(stage) · \(analysis.alignment.rawValue.uppercased()) · \(Int((analysis.confidence * 100).rounded()))%\n\(analysis.summary)\nAPI=\(milliseconds(latency)) ms\(usage)"
            )
            if payload.stage == .metadata, analysis.needsScreenshot {
                enqueueScreenshotEscalation(for: payload)
            }
        case let .failure(error):
            if error is CancellationError { break }
            logWindow.append(
                "[\(timestampFormatter.string(from: Date()))] LUNA ERROR · \(milliseconds(latency)) ms\n\(safeError(error))"
            )
        }
        startNextAnalysisIfPossible()
    }

    private func enqueueScreenshotEscalation(for payload: AnalysisPayload) {
        guard payload.inferenceIdentity == latestInferenceIdentity,
              payload.inferenceIdentity != lastScreenshotIdentity,
              let metadata = latestProviderMetadata,
              let image = latestProviderImage,
              let inferenceIdentity = latestInferenceIdentity else {
            return
        }

        let cooldownReadyAt = lastScreenshotStartedAt?.addingTimeInterval(
            inferencePolicy.screenshotCooldown
        ) ?? .distantPast
        pendingAnalysis = AnalysisPayload(
            metadata: metadata,
            sourceImage: image,
            inferenceIdentity: inferenceIdentity,
            stage: .screenshot,
            notBefore: max(Date(), cooldownReadyAt)
        )
    }

    private func invalidatePendingInferenceForContextChange() {
        latestProviderMetadata = nil
        latestProviderImage = nil
        latestInferenceIdentity = nil
        invalidateInFlightInferenceForContentChange()
    }

    private func invalidateInFlightInferenceForContentChange() {
        analysisGeneration += 1
        requestGate.requestCancellation()
        inferenceTask?.cancel()
        pendingAnalysis = nil
        analysisStartScheduled = false
        if inferenceTask == nil {
            inFlightAnalysis = nil
        }
    }

    private func handleCaptureStarted(runID: UInt64) {
        processingQueue.async { [weak self] in
            guard let self, self.captureRunGate.accepts(runID) else { return }
            logWindow.setStatus("Capturing locally at up to 1 frame/second")
            logWindow.append("ScreenCaptureKit started. Tab windows and the pointer are excluded.")
        }
    }

    private func handleCaptureError(_ error: Error, runID: UInt64) {
        processingQueue.async { [weak self] in
            guard let self, self.captureRunGate.finishIfCurrent(runID) else { return }
            logWindow.append("ScreenCaptureKit error: \(safeError(error))")
            transitionToStoppedAfterCaptureFailure()
        }
    }

    private func handleCaptureStopped(runID: UInt64) {
        processingQueue.async { [weak self] in
            guard let self, self.captureRunGate.finishIfCurrent(runID) else { return }
            if isRunning {
                logWindow.append("ScreenCaptureKit stopped unexpectedly.")
                transitionToStoppedAfterCaptureFailure()
            } else {
                logWindow.setCaptureRunning(false)
            }
        }
    }

    private func transitionToStoppedAfterCaptureFailure() {
        isRunning = false
        captureSource = nil
        resourceMonitor.stop()
        analysisGeneration += 1
        requestGate.requestCancellation()
        inferenceTask?.cancel()
        pendingAnalysis = nil
        analysisStartScheduled = false
        previousAcceptedSample = nil
        latestProviderMetadata = nil
        latestProviderImage = nil
        latestInferenceIdentity = nil
        latestObservationGeneration = 0
        logWindow.setCaptureRunning(false)
        logWindow.setStatus("Capture error — press Start to retry")
    }

    private func publishResourceSample(_ sample: ProcessResourceSample) {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - lastResourceSampleUptime, 0.001)
        let fps = Double(framesSinceResourceSample) / elapsed
        framesSinceResourceSample = 0
        lastResourceSampleUptime = now
        let remoteState = lunaAPIKey == nil ? "Luna off" : "Luna on"
        logWindow.setStatus(
            String(
                format: "Local %.2f fps · CPU %.1f%% · Footprint %.0f MB · %@",
                fps,
                sample.cpuPercent,
                sample.physicalFootprintMegabytes,
                remoteState
            )
        )
    }

    private func milliseconds(_ interval: TimeInterval) -> Int {
        Int((max(interval, 0) * 1_000).rounded())
    }

    private func safeError(_ error: Error) -> String {
        ScreenContextText.collapsed(String(describing: error), maximumCharacters: 300)
    }
}

import AppKit
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

struct RawScreenContextFrame {
    let image: CGImage
    let receivedAt: Date
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
}

enum ScreenContextCaptureError: LocalizedError {
    case noDisplay
    case unavailable
    case missingFrame

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No shareable display is available."
        case .unavailable:
            return "Screen context requires macOS 12.3 or later."
        case .missingFrame:
            return "ScreenCaptureKit returned a frame without an image buffer."
        }
    }
}

struct ScreenCaptureLifecycleGate: Equatable {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case stopping
    }

    struct StopTransition: Equatable {
        let generation: UInt64
        let waitsForStream: Bool
    }

    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .stopped

    mutating func beginStart() -> UInt64? {
        guard phase == .stopped else { return nil }
        generation &+= 1
        phase = .starting
        return generation
    }

    func acceptsStartup(generation candidate: UInt64) -> Bool {
        phase == .starting && generation == candidate
    }

    mutating func markRunning(generation candidate: UInt64) -> Bool {
        guard acceptsStartup(generation: candidate) else { return false }
        phase = .running
        return true
    }

    mutating func failCurrent(generation candidate: UInt64) -> Bool {
        guard generation == candidate, phase == .starting || phase == .running else {
            return false
        }
        phase = .stopped
        return true
    }

    mutating func beginStop(hasStream: Bool) -> StopTransition? {
        guard phase == .starting || phase == .running else { return nil }
        generation &+= 1
        phase = hasStream ? .stopping : .stopped
        return StopTransition(generation: generation, waitsForStream: hasStream)
    }

    mutating func completeStop(generation candidate: UInt64) -> Bool {
        guard phase == .stopping, generation == candidate else { return false }
        phase = .stopped
        return true
    }
}

struct ScreenCaptureWindowCandidate: Equatable {
    let ownerPID: pid_t?
    let layer: Int?
    let alpha: Double
    let bounds: CGRect?
    let applicationName: String?
    let windowTitle: String?
}

struct ScreenCaptureVisibleContext: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
}

enum ScreenCaptureVisibleContextSelector {
    static func select(
        from candidates: [ScreenCaptureWindowCandidate],
        capturedDisplayBounds: CGRect,
        ownPID: pid_t,
        bundleIdentifier: (pid_t) -> String?
    ) -> ScreenCaptureVisibleContext {
        for candidate in candidates {
            guard let ownerPID = candidate.ownerPID,
                  ownerPID != ownPID,
                  candidate.layer == 0,
                  candidate.alpha > 0,
                  let windowBounds = candidate.bounds else {
                continue
            }

            let intersection = windowBounds.intersection(capturedDisplayBounds)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                continue
            }

            let applicationName = candidate.applicationName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let applicationName,
                  !applicationName.isEmpty,
                  applicationName != "Window Server" else {
                continue
            }
            let title = candidate.windowTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ScreenCaptureVisibleContext(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier(ownerPID),
                windowTitle: title?.isEmpty == false ? title : nil
            )
        }

        return ScreenCaptureVisibleContext(
            applicationName: "Captured display",
            bundleIdentifier: nil,
            windowTitle: nil
        )
    }
}

@available(macOS 12.3, *)
final class ScreenCaptureKitContextSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "app.usefence.tab.screen-capture", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var lifecycle = ScreenCaptureLifecycleGate()
    private var startupTask: Task<Void, Never>?
    private var stream: SCStream?
    private var capturedDisplayBounds: CGRect?

    var onFrame: ((RawScreenContextFrame) -> Void)?
    var onError: ((Error) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: (() -> Void)?

    func start() {
        captureQueue.async { [self] in
            startOnCaptureQueue()
        }
    }

    func stop() {
        captureQueue.async { [self] in
            stopOnCaptureQueue()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              self.stream === stream,
              lifecycle.phase == .running,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = imageContext.createCGImage(inputImage, from: inputImage.extent) else {
            stopCurrentStream(with: ScreenContextCaptureError.missingFrame)
            return
        }
        let context = frontmostVisibleContext(
            capturedDisplayBounds: capturedDisplayBounds ?? .null
        )
        onFrame?(
            RawScreenContextFrame(
                image: image,
                receivedAt: Date(),
                applicationName: context.applicationName,
                bundleIdentifier: context.bundleIdentifier,
                windowTitle: context.windowTitle
            )
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureQueue.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream else { return }
            let generation = self.lifecycle.generation
            self.stream = nil
            self.capturedDisplayBounds = nil
            guard self.lifecycle.failCurrent(generation: generation) else { return }
            self.publishStopped(error: error)
        }
    }

    private func startOnCaptureQueue() {
        guard let generation = lifecycle.beginStart() else { return }

        let task = Task { [weak self] in
            let result: Result<SCShareableContent, Error>
            do {
                result = .success(
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                )
            } catch {
                result = .failure(error)
            }

            self?.captureQueue.async { [weak self] in
                self?.handleShareableContent(result, generation: generation)
            }
        }
        startupTask = task
    }

    private func stopOnCaptureQueue() {
        let currentStream = stream
        guard let transition = lifecycle.beginStop(hasStream: currentStream != nil) else {
            return
        }

        startupTask?.cancel()
        startupTask = nil
        stream = nil
        capturedDisplayBounds = nil

        guard transition.waitsForStream, let currentStream else {
            publishStopped(error: nil)
            return
        }
        stop(
            currentStream,
            generation: transition.generation,
            primaryError: nil
        )
    }

    private func configuration(for display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let longEdge = 1_024.0
        let sourceWidth = max(Double(display.width), 1)
        let sourceHeight = max(Double(display.height), 1)
        let scale = min(1, longEdge / max(sourceWidth, sourceHeight))
        configuration.width = max(2, Int((sourceWidth * scale).rounded()))
        configuration.height = max(2, Int((sourceHeight * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        return configuration
    }

    private func handleShareableContent(
        _ result: Result<SCShareableContent, Error>,
        generation: UInt64
    ) {
        startupTask = nil
        guard lifecycle.acceptsStartup(generation: generation) else { return }

        switch result {
        case let .success(content):
            configureStream(with: content, generation: generation)
        case let .failure(error):
            finishCurrent(generation: generation, error: error)
        }
    }

    private func configureStream(with content: SCShareableContent, generation: UInt64) {
        guard lifecycle.acceptsStartup(generation: generation) else { return }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            finishCurrent(generation: generation, error: ScreenContextCaptureError.noDisplay)
            return
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter {
            $0.processID == getpid() || $0.bundleIdentifier == ownBundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = configuration(for: display)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            finishCurrent(generation: generation, error: error)
            return
        }

        self.stream = stream
        capturedDisplayBounds = display.frame
        stream.startCapture { [weak self] error in
            self?.captureQueue.async { [weak self, weak stream] in
                guard let self,
                      let stream,
                      self.stream === stream,
                      self.lifecycle.acceptsStartup(generation: generation) else {
                    return
                }
                if let error {
                    self.stream = nil
                    self.capturedDisplayBounds = nil
                    self.finishCurrent(generation: generation, error: error)
                } else if self.lifecycle.markRunning(generation: generation) {
                    self.onStarted?()
                }
            }
        }
    }

    private func finishCurrent(generation: UInt64, error: Error) {
        guard lifecycle.failCurrent(generation: generation) else { return }
        startupTask?.cancel()
        startupTask = nil
        stream = nil
        capturedDisplayBounds = nil
        publishStopped(error: error)
    }

    private func stopCurrentStream(with error: Error) {
        let currentStream = stream
        guard let transition = lifecycle.beginStop(hasStream: currentStream != nil) else {
            return
        }
        startupTask?.cancel()
        startupTask = nil
        stream = nil
        capturedDisplayBounds = nil

        guard transition.waitsForStream, let currentStream else {
            publishStopped(error: error)
            return
        }
        stop(
            currentStream,
            generation: transition.generation,
            primaryError: error
        )
    }

    private func stop(
        _ stream: SCStream,
        generation: UInt64,
        primaryError: Error?
    ) {
        stream.stopCapture { [self] stopError in
            captureQueue.async { [self] in
                guard lifecycle.completeStop(generation: generation) else {
                    return
                }
                publishStopped(error: primaryError ?? stopError)
            }
        }
    }

    private func publishStopped(error: Error?) {
        if let error {
            onError?(error)
        }
        onStopped?()
    }

    private func frontmostVisibleContext(
        capturedDisplayBounds: CGRect
    ) -> ScreenCaptureVisibleContext {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = windowInfo.map { window in
            ScreenCaptureWindowCandidate(
                ownerPID: (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                alpha: (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: (window[kCGWindowBounds as String] as? NSDictionary).flatMap {
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                },
                applicationName: window[kCGWindowOwnerName as String] as? String,
                windowTitle: window[kCGWindowName as String] as? String
            )
        }
        return ScreenCaptureVisibleContextSelector.select(
            from: candidates,
            capturedDisplayBounds: capturedDisplayBounds,
            ownPID: getpid(),
            bundleIdentifier: { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
        )
    }
}

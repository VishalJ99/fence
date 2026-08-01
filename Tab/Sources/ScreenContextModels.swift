import Foundation

enum ScreenContextText {
    static func collapsed(_ value: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0 else { return "" }

        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > maximumCharacters else { return collapsed }
        guard maximumCharacters > 1 else { return String(collapsed.prefix(1)) }
        return String(collapsed.prefix(maximumCharacters - 1)) + "…"
    }

    static func optionalCollapsed(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let collapsed = collapsed(value, maximumCharacters: maximumCharacters)
        return collapsed.isEmpty ? nil : collapsed
    }
}

struct ScreenContextMetadata: Codable, Equatable {
    static let maximumApplicationNameCharacters = 96
    static let maximumBundleIdentifierCharacters = 160
    static let maximumWindowTitleCharacters = 320
    static let maximumDocumentURLCharacters = 640
    static let maximumFocusGoalCharacters = 500
    static let maximumVisibleTextExcerptCharacters = 500

    let observedAt: Date
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let documentURL: String?
    let focusGoal: String?
    let visibleTextExcerpt: String?
    let dwellTime: TimeInterval

    init(
        observedAt: Date,
        applicationName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        documentURL: String? = nil,
        focusGoal: String? = nil,
        visibleTextExcerpt: String? = nil,
        dwellTime: TimeInterval = 0
    ) {
        self.observedAt = observedAt
        self.applicationName = ScreenContextText.collapsed(
            applicationName,
            maximumCharacters: Self.maximumApplicationNameCharacters
        )
        self.bundleIdentifier = ScreenContextText.optionalCollapsed(
            bundleIdentifier,
            maximumCharacters: Self.maximumBundleIdentifierCharacters
        )
        self.windowTitle = ScreenContextText.optionalCollapsed(
            windowTitle,
            maximumCharacters: Self.maximumWindowTitleCharacters
        )
        self.documentURL = ScreenContextText.optionalCollapsed(
            documentURL,
            maximumCharacters: Self.maximumDocumentURLCharacters
        )
        self.focusGoal = ScreenContextText.optionalCollapsed(
            focusGoal,
            maximumCharacters: Self.maximumFocusGoalCharacters
        )
        self.visibleTextExcerpt = ScreenContextText.optionalCollapsed(
            visibleTextExcerpt,
            maximumCharacters: Self.maximumVisibleTextExcerptCharacters
        )
        self.dwellTime = dwellTime.isFinite ? max(0, dwellTime) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case applicationName
        case bundleIdentifier
        case windowTitle
        case documentURL
        case focusGoal
        case visibleTextExcerpt
        case dwellTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            applicationName: try container.decode(String.self, forKey: .applicationName),
            bundleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .bundleIdentifier
            ),
            windowTitle: try container.decodeIfPresent(String.self, forKey: .windowTitle),
            documentURL: try container.decodeIfPresent(String.self, forKey: .documentURL),
            focusGoal: try container.decodeIfPresent(String.self, forKey: .focusGoal),
            visibleTextExcerpt: try container.decodeIfPresent(
                String.self,
                forKey: .visibleTextExcerpt
            ),
            dwellTime: try container.decode(TimeInterval.self, forKey: .dwellTime)
        )
    }

    var semanticFingerprint: String {
        [
            applicationName,
            bundleIdentifier ?? "",
            windowTitle ?? "",
            documentURL ?? "",
            focusGoal ?? ""
        ].joined(separator: "\u{1F}")
    }

    var analysisFingerprint: String {
        [semanticFingerprint, visibleTextExcerpt ?? ""].joined(separator: "\u{1E}")
    }

    var providerMetadataText: String {
        let roundedDwellTime = (dwellTime * 10).rounded() / 10
        let milliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        let payload = ProviderMetadata(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            documentURL: documentURL,
            dwellSeconds: roundedDwellTime,
            focusGoal: focusGoal,
            observedAtUnixMilliseconds: milliseconds,
            visibleTextExcerpt: visibleTextExcerpt,
            windowTitle: windowTitle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private struct ProviderMetadata: Encodable {
    let applicationName: String
    let bundleIdentifier: String?
    let documentURL: String?
    let dwellSeconds: TimeInterval
    let focusGoal: String?
    let observedAtUnixMilliseconds: Int64
    let visibleTextExcerpt: String?
    let windowTitle: String?

    private enum CodingKeys: String, CodingKey {
        case applicationName = "application_name"
        case bundleIdentifier = "bundle_identifier"
        case documentURL = "document_url"
        case dwellSeconds = "dwell_seconds"
        case focusGoal = "focus_goal"
        case observedAtUnixMilliseconds = "observed_at_unix_ms"
        case visibleTextExcerpt = "visible_text_excerpt"
        case windowTitle = "window_title"
    }
}

enum GrayscaleVisualSignatureError: Error, Equatable {
    case invalidDimensions
    case invalidSampleCount(expected: Int, actual: Int)
    case tooManySamples(maximum: Int, actual: Int)
}

struct GrayscaleVisualSignature: Codable, Equatable {
    static let maximumSampleCount = 4_096

    let width: Int
    let height: Int
    let samples: [UInt8]

    init(width: Int, height: Int, samples: [UInt8]) throws {
        guard width > 0, height > 0,
              width <= Self.maximumSampleCount / height else {
            throw GrayscaleVisualSignatureError.invalidDimensions
        }
        let expectedCount = width * height
        guard expectedCount <= Self.maximumSampleCount else {
            throw GrayscaleVisualSignatureError.tooManySamples(
                maximum: Self.maximumSampleCount,
                actual: expectedCount
            )
        }
        guard samples.count == expectedCount else {
            throw GrayscaleVisualSignatureError.invalidSampleCount(
                expected: expectedCount,
                actual: samples.count
            )
        }
        self.width = width
        self.height = height
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(Int.self, forKey: .width),
            height: container.decode(Int.self, forKey: .height),
            samples: container.decode([UInt8].self, forKey: .samples)
        )
    }

    func normalizedChangeScore(comparedTo other: GrayscaleVisualSignature) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        guard !samples.isEmpty else { return 0 }

        let absoluteDifference = zip(samples, other.samples).reduce(0.0) { result, pair in
            result + Double(abs(Int(pair.0) - Int(pair.1)))
        }
        return absoluteDifference / (Double(samples.count) * 255.0)
    }
}

struct ScreenContextSample: Equatable {
    let metadata: ScreenContextMetadata
    let visualSignature: GrayscaleVisualSignature?

    init(
        metadata: ScreenContextMetadata,
        visualSignature: GrayscaleVisualSignature? = nil
    ) {
        self.metadata = metadata
        self.visualSignature = visualSignature
    }
}

enum ScreenContextSamplingReason: String, Codable, Equatable {
    case initial
    case minimumInterval
    case metadataChanged
    case visualChanged
    case unchanged
}

struct ScreenContextSamplingDecision: Equatable {
    let shouldSample: Bool
    let reason: ScreenContextSamplingReason
    let normalizedVisualChangeScore: Double?
}

struct ScreenContextSamplingPolicy: Equatable {
    static let absoluteMinimumInterval: TimeInterval = 1

    let minimumInterval: TimeInterval
    let visualChangeThreshold: Double

    init(
        minimumInterval: TimeInterval = 1,
        visualChangeThreshold: Double = 0.08
    ) {
        self.minimumInterval = max(Self.absoluteMinimumInterval, minimumInterval)
        self.visualChangeThreshold = min(max(visualChangeThreshold, 0), 1)
    }

    func decision(
        previousAcceptedSample: ScreenContextSample?,
        candidate: ScreenContextSample
    ) -> ScreenContextSamplingDecision {
        guard let previous = previousAcceptedSample else {
            return ScreenContextSamplingDecision(
                shouldSample: true,
                reason: .initial,
                normalizedVisualChangeScore: nil
            )
        }

        let elapsed = candidate.metadata.observedAt.timeIntervalSince(
            previous.metadata.observedAt
        )
        guard elapsed >= minimumInterval else {
            return ScreenContextSamplingDecision(
                shouldSample: false,
                reason: .minimumInterval,
                normalizedVisualChangeScore: nil
            )
        }

        if candidate.metadata.semanticFingerprint != previous.metadata.semanticFingerprint {
            return ScreenContextSamplingDecision(
                shouldSample: true,
                reason: .metadataChanged,
                normalizedVisualChangeScore: visualChangeScore(
                    previous: previous.visualSignature,
                    candidate: candidate.visualSignature
                )
            )
        }

        let score = visualChangeScore(
            previous: previous.visualSignature,
            candidate: candidate.visualSignature
        )
        if let score, score >= visualChangeThreshold {
            return ScreenContextSamplingDecision(
                shouldSample: true,
                reason: .visualChanged,
                normalizedVisualChangeScore: score
            )
        }

        return ScreenContextSamplingDecision(
            shouldSample: false,
            reason: .unchanged,
            normalizedVisualChangeScore: score
        )
    }

    private func visualChangeScore(
        previous: GrayscaleVisualSignature?,
        candidate: GrayscaleVisualSignature?
    ) -> Double? {
        switch (previous, candidate) {
        case let (.some(previous), .some(candidate)):
            return candidate.normalizedChangeScore(comparedTo: previous)
        case (.none, .none):
            return nil
        case (.some, .none), (.none, .some):
            return 1
        }
    }
}

enum ScreenContextInferenceReason: String, Equatable {
    case settling
    case changedContext
    case minimumInterval
    case heartbeat
    case unchanged
}

struct ScreenContextInferenceDecision: Equatable {
    let shouldAnalyze: Bool
    let reason: ScreenContextInferenceReason
}

struct ScreenContextInferencePolicy: Equatable {
    let settleInterval: TimeInterval
    let changedContextMinimumInterval: TimeInterval
    let unchangedHeartbeatInterval: TimeInterval
    let screenshotCooldown: TimeInterval

    init(
        settleInterval: TimeInterval = 1,
        changedContextMinimumInterval: TimeInterval = 5,
        unchangedHeartbeatInterval: TimeInterval = 30,
        screenshotCooldown: TimeInterval = 30
    ) {
        self.settleInterval = max(0, settleInterval)
        self.changedContextMinimumInterval = max(0, changedContextMinimumInterval)
        self.unchangedHeartbeatInterval = max(
            self.changedContextMinimumInterval,
            unchangedHeartbeatInterval
        )
        self.screenshotCooldown = max(0, screenshotCooldown)
    }

    func metadataDecision(
        fingerprintAge: TimeInterval,
        candidateFingerprint: String,
        lastRequestFingerprint: String?,
        lastRequestAt: Date?,
        now: Date
    ) -> ScreenContextInferenceDecision {
        guard max(0, fingerprintAge) >= settleInterval else {
            return ScreenContextInferenceDecision(
                shouldAnalyze: false,
                reason: .settling
            )
        }

        guard let lastRequestAt else {
            return ScreenContextInferenceDecision(
                shouldAnalyze: true,
                reason: .changedContext
            )
        }

        let elapsed = max(0, now.timeIntervalSince(lastRequestAt))
        if candidateFingerprint != lastRequestFingerprint {
            guard elapsed >= changedContextMinimumInterval else {
                return ScreenContextInferenceDecision(
                    shouldAnalyze: false,
                    reason: .minimumInterval
                )
            }
            return ScreenContextInferenceDecision(
                shouldAnalyze: true,
                reason: .changedContext
            )
        }

        if elapsed >= unchangedHeartbeatInterval {
            return ScreenContextInferenceDecision(
                shouldAnalyze: true,
                reason: .heartbeat
            )
        }
        return ScreenContextInferenceDecision(
            shouldAnalyze: false,
            reason: .unchanged
        )
    }
}

enum ScreenContextAlignment: String, Codable, Equatable {
    case productive
    case unclear
    case distracting
}

struct ScreenContextAnalysis: Codable, Equatable {
    static let maximumSummaryCharacters = 120
    static let maximumEvidenceItems = 2
    static let maximumEvidenceCharacters = 80

    let alignment: ScreenContextAlignment
    let confidence: Double
    let summary: String
    let evidence: [String]
    let needsScreenshot: Bool

    init(
        alignment: ScreenContextAlignment,
        confidence: Double,
        summary: String,
        evidence: [String],
        needsScreenshot: Bool
    ) {
        self.alignment = alignment
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.summary = ScreenContextText.collapsed(
            summary,
            maximumCharacters: Self.maximumSummaryCharacters
        )
        self.evidence = Array(
            evidence.lazy
                .map {
                    ScreenContextText.collapsed(
                        $0,
                        maximumCharacters: Self.maximumEvidenceCharacters
                    )
                }
                .filter { !$0.isEmpty }
                .prefix(Self.maximumEvidenceItems)
        )
        self.needsScreenshot = needsScreenshot
    }

    private enum CodingKeys: String, CodingKey {
        case alignment
        case confidence
        case summary
        case evidence
        case needsScreenshot = "needs_screenshot"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            alignment: try container.decode(ScreenContextAlignment.self, forKey: .alignment),
            confidence: try container.decode(Double.self, forKey: .confidence),
            summary: try container.decode(String.self, forKey: .summary),
            evidence: try container.decode([String].self, forKey: .evidence),
            needsScreenshot: try container.decode(Bool.self, forKey: .needsScreenshot)
        )
    }
}

struct ContextModelUsage: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let billedCredits: Double?

    init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        billedCredits: Double? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(0, totalTokens)
        if let billedCredits, billedCredits.isFinite, billedCredits >= 0 {
            self.billedCredits = billedCredits
        } else {
            self.billedCredits = nil
        }
    }
}

struct ScreenContextAnalysisResult: Equatable {
    let analysis: ScreenContextAnalysis
    let usage: ContextModelUsage?
    let providerResponseID: String?
    let providerModel: String?
}

struct ScreenContextAnalysisRequest: Equatable {
    static let maximumJPEGByteCount = 4 * 1_024 * 1_024

    let metadata: ScreenContextMetadata
    let jpegImageData: Data?

    init(metadata: ScreenContextMetadata, jpegImageData: Data? = nil) {
        self.metadata = metadata
        self.jpegImageData = jpegImageData
    }
}

protocol ContextModelClient {
    func analyze(_ request: ScreenContextAnalysisRequest) async throws
        -> ScreenContextAnalysisResult
}

enum ScreenContextLogFormatter {
    static func observation(_ sample: ScreenContextSample) -> String {
        let windowState = sample.metadata.windowTitle == nil ? "absent" : "present"
        let documentState = sample.metadata.documentURL == nil ? "absent" : "present"
        let visualState = sample.visualSignature == nil ? "absent" : "present"
        return "screen_context observation window=\(windowState) document=\(documentState) visual=\(visualState)"
    }

    static func analysis(_ result: ScreenContextAnalysisResult) -> String {
        let confidence = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            result.analysis.confidence
        )
        let usage: String
        if let value = result.usage {
            let cost = value.billedCredits.map {
                String(format: " billed_credits=%.8f", locale: Locale(identifier: "en_US_POSIX"), $0)
            } ?? " billed_credits=unknown"
            usage = " input_tokens=\(value.inputTokens) output_tokens=\(value.outputTokens) total_tokens=\(value.totalTokens)\(cost)"
        } else {
            usage = " input_tokens=unknown output_tokens=unknown total_tokens=unknown billed_credits=unknown"
        }
        return "screen_context analysis alignment=\(result.analysis.alignment.rawValue) confidence=\(confidence) needs_screenshot=\(result.analysis.needsScreenshot) evidence_count=\(result.analysis.evidence.count)\(usage)"
    }
}

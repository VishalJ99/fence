import Foundation
import XCTest
@testable import Tab

final class ScreenContextModelsTests: XCTestCase {
    func testMetadataCollapsesBoundsAndProducesStableProviderJSON() throws {
        let metadata = ScreenContextMetadata(
            observedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            applicationName: "  Visual   Studio\nCode  ",
            bundleIdentifier: " com.microsoft.VSCode ",
            windowTitle: String(repeating: "x", count: 400),
            documentURL: "  https://example.com/a   path ",
            focusGoal: "  Finish\tthe  tests ",
            visibleTextExcerpt: "  README   implementation\nnotes ",
            dwellTime: 12.34
        )

        XCTAssertEqual(metadata.applicationName, "Visual Studio Code")
        XCTAssertEqual(metadata.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(metadata.windowTitle?.count, 320)
        XCTAssertTrue(metadata.windowTitle?.hasSuffix("…") == true)
        XCTAssertEqual(metadata.documentURL, "https://example.com/a path")
        XCTAssertEqual(metadata.focusGoal, "Finish the tests")
        XCTAssertEqual(metadata.visibleTextExcerpt, "README implementation notes")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(metadata.providerMetadataText.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["application_name"] as? String, "Visual Studio Code")
        XCTAssertEqual(object["dwell_seconds"] as? Double, 12.3)
        XCTAssertEqual(object["observed_at_unix_ms"] as? Int64, 1_700_000_000_125)
        XCTAssertEqual(object["visible_text_excerpt"] as? String, "README implementation notes")
    }

    func testVisualSignatureChangeScoreIsNormalized() throws {
        let black = try GrayscaleVisualSignature(
            width: 2,
            height: 2,
            samples: [0, 0, 0, 0]
        )
        let white = try GrayscaleVisualSignature(
            width: 2,
            height: 2,
            samples: [255, 255, 255, 255]
        )
        let mixed = try GrayscaleVisualSignature(
            width: 2,
            height: 2,
            samples: [0, 255, 0, 255]
        )

        XCTAssertEqual(black.normalizedChangeScore(comparedTo: black), 0)
        XCTAssertEqual(black.normalizedChangeScore(comparedTo: white), 1)
        XCTAssertEqual(black.normalizedChangeScore(comparedTo: mixed), 0.5)
    }

    func testVisualSignatureRejectsInvalidSampleCount() {
        XCTAssertThrowsError(
            try GrayscaleVisualSignature(width: 2, height: 2, samples: [0])
        ) { error in
            XCTAssertEqual(
                error as? GrayscaleVisualSignatureError,
                .invalidSampleCount(expected: 4, actual: 1)
            )
        }
    }

    func testSamplingPolicyEnforcesOneSecondBeforeMaterialChanges() throws {
        let policy = ScreenContextSamplingPolicy(
            minimumInterval: 0.1,
            visualChangeThreshold: 0.1
        )
        XCTAssertEqual(policy.minimumInterval, 1)

        let baseline = sample(
            time: 100,
            applicationName: "Xcode",
            signature: try signature([0, 0, 0, 0])
        )
        let tooSoon = sample(
            time: 100.9,
            applicationName: "Safari",
            signature: try signature([255, 255, 255, 255])
        )
        XCTAssertEqual(
            policy.decision(previousAcceptedSample: baseline, candidate: tooSoon),
            ScreenContextSamplingDecision(
                shouldSample: false,
                reason: .minimumInterval,
                normalizedVisualChangeScore: nil
            )
        )

        let metadataChange = sample(
            time: 101,
            applicationName: "Safari",
            signature: try signature([0, 0, 0, 0])
        )
        XCTAssertEqual(
            policy.decision(previousAcceptedSample: baseline, candidate: metadataChange).reason,
            .metadataChanged
        )
    }

    func testSamplingPolicyUsesVisualThresholdAndIgnoresDwellOnlyChanges() throws {
        let policy = ScreenContextSamplingPolicy(visualChangeThreshold: 0.1)
        let baseline = sample(
            time: 100,
            applicationName: "Xcode",
            dwellTime: 1,
            signature: try signature([0, 0, 0, 0])
        )
        let unchanged = sample(
            time: 101,
            applicationName: "Xcode",
            dwellTime: 10,
            signature: try signature([10, 10, 10, 10])
        )
        let changed = sample(
            time: 102,
            applicationName: "Xcode",
            dwellTime: 11,
            signature: try signature([255, 255, 255, 255])
        )

        let unchangedDecision = policy.decision(
            previousAcceptedSample: baseline,
            candidate: unchanged
        )
        XCTAssertFalse(unchangedDecision.shouldSample)
        XCTAssertEqual(unchangedDecision.reason, .unchanged)

        let changedDecision = policy.decision(
            previousAcceptedSample: baseline,
            candidate: changed
        )
        XCTAssertTrue(changedDecision.shouldSample)
        XCTAssertEqual(changedDecision.reason, .visualChanged)
        XCTAssertEqual(changedDecision.normalizedVisualChangeScore, 1)
    }

    func testInferencePolicySettlesAndThrottlesChangedContext() {
        let policy = ScreenContextInferencePolicy()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 0.99,
                candidateFingerprint: "new",
                lastRequestFingerprint: nil,
                lastRequestAt: nil,
                now: now
            ),
            ScreenContextInferenceDecision(shouldAnalyze: false, reason: .settling)
        )
        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 1,
                candidateFingerprint: "new",
                lastRequestFingerprint: nil,
                lastRequestAt: nil,
                now: now
            ),
            ScreenContextInferenceDecision(shouldAnalyze: true, reason: .changedContext)
        )
        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 10,
                candidateFingerprint: "new",
                lastRequestFingerprint: "old",
                lastRequestAt: now.addingTimeInterval(-4.99),
                now: now
            ),
            ScreenContextInferenceDecision(shouldAnalyze: false, reason: .minimumInterval)
        )
    }

    func testInferencePolicyUsesThirtySecondUnchangedHeartbeat() {
        let policy = ScreenContextInferencePolicy()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 40,
                candidateFingerprint: "same",
                lastRequestFingerprint: "same",
                lastRequestAt: now.addingTimeInterval(-29.99),
                now: now
            ),
            ScreenContextInferenceDecision(shouldAnalyze: false, reason: .unchanged)
        )
        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 40,
                candidateFingerprint: "same",
                lastRequestFingerprint: "same",
                lastRequestAt: now.addingTimeInterval(-30),
                now: now
            ),
            ScreenContextInferenceDecision(shouldAnalyze: true, reason: .heartbeat)
        )
    }

    func testAnalysisBoundsModelSuppliedTextAndStableLogOmitsPayload() {
        let analysis = ScreenContextAnalysis(
            alignment: .distracting,
            confidence: 2,
            summary: "  Browsing\nnews  instead of work ",
            evidence: [" one ", " two ", " three ", " four "],
            needsScreenshot: false
        )
        let result = ScreenContextAnalysisResult(
            analysis: analysis,
            usage: ContextModelUsage(
                inputTokens: 50,
                outputTokens: 12,
                totalTokens: 62,
                billedCredits: 0.00012345
            ),
            providerResponseID: "id",
            providerModel: "model"
        )

        XCTAssertEqual(analysis.confidence, 1)
        XCTAssertEqual(analysis.summary, "Browsing news instead of work")
        XCTAssertEqual(analysis.evidence, ["one", "two"])
        XCTAssertEqual(
            ScreenContextLogFormatter.analysis(result),
            "screen_context analysis alignment=distracting confidence=1.000 needs_screenshot=false evidence_count=2 input_tokens=50 output_tokens=12 total_tokens=62 billed_credits=0.00012345"
        )
        XCTAssertFalse(ScreenContextLogFormatter.analysis(result).contains(analysis.summary))
    }

    private func sample(
        time: TimeInterval,
        applicationName: String,
        dwellTime: TimeInterval = 0,
        signature: GrayscaleVisualSignature?
    ) -> ScreenContextSample {
        ScreenContextSample(
            metadata: ScreenContextMetadata(
                observedAt: Date(timeIntervalSince1970: time),
                applicationName: applicationName,
                bundleIdentifier: "example.bundle",
                windowTitle: "Window",
                focusGoal: "Work",
                dwellTime: dwellTime
            ),
            visualSignature: signature
        )
    }

    private func signature(_ samples: [UInt8]) throws -> GrayscaleVisualSignature {
        try GrayscaleVisualSignature(width: 2, height: 2, samples: samples)
    }
}

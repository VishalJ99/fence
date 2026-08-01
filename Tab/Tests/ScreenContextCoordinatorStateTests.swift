import Foundation
import XCTest
@testable import Tab

final class ScreenContextCoordinatorStateTests: XCTestCase {
    func testDelayedOldCaptureCallbackCannotFinishNewRun() {
        var gate = ScreenContextCaptureRunGate()
        let firstRun = gate.beginRun()
        gate.clearCurrentRun()
        let secondRun = gate.beginRun()

        XCTAssertFalse(gate.finishIfCurrent(firstRun))
        XCTAssertTrue(gate.accepts(secondRun))
        XCTAssertEqual(gate.activeRunID, secondRun)

        XCTAssertTrue(gate.finishIfCurrent(secondRun))
        XCTAssertNil(gate.activeRunID)
    }

    func testVisualOnlyObservationGetsDistinctInferenceIdentity() {
        let first = ScreenContextInferenceIdentity(
            analysisFingerprint: "same metadata and OCR",
            observationGeneration: 41
        )
        let visuallyChanged = ScreenContextInferenceIdentity(
            analysisFingerprint: "same metadata and OCR",
            observationGeneration: 42
        )

        XCTAssertNotEqual(first, visuallyChanged)
        XCTAssertNotEqual(first.policyFingerprint, visuallyChanged.policyFingerprint)

        let policy = ScreenContextInferencePolicy(
            settleInterval: 0,
            changedContextMinimumInterval: 0,
            unchangedHeartbeatInterval: 30
        )
        XCTAssertEqual(
            policy.metadataDecision(
                fingerprintAge: 1,
                candidateFingerprint: visuallyChanged.policyFingerprint,
                lastRequestFingerprint: first.policyFingerprint,
                lastRequestAt: Date(timeIntervalSince1970: 99),
                now: Date(timeIntervalSince1970: 100)
            ),
            ScreenContextInferenceDecision(shouldAnalyze: true, reason: .changedContext)
        )
    }

    func testCancellationKeepsRequestGateClosedUntilMatchingCompletion() {
        var gate = ScreenContextRequestGate()
        let firstRequest = UUID()
        let replacementRequest = UUID()

        XCTAssertTrue(gate.begin(firstRequest))
        gate.requestCancellation()

        XCTAssertTrue(gate.cancellationRequested)
        XCTAssertFalse(gate.isIdle)
        XCTAssertFalse(gate.begin(replacementRequest))
        XCTAssertFalse(gate.complete(replacementRequest))

        XCTAssertTrue(gate.complete(firstRequest))
        XCTAssertTrue(gate.isIdle)
        XCTAssertFalse(gate.cancellationRequested)
        XCTAssertTrue(gate.begin(replacementRequest))
    }
}

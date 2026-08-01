import CoreGraphics
import XCTest
@testable import Tab

final class ScreenCaptureKitContextSourceTests: XCTestCase {
    func testStopDuringStartupInvalidatesOldGeneration() throws {
        var gate = ScreenCaptureLifecycleGate()
        let firstGeneration = try XCTUnwrap(gate.beginStart())

        let stop = try XCTUnwrap(gate.beginStop(hasStream: false))

        XCTAssertFalse(stop.waitsForStream)
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertGreaterThan(stop.generation, firstGeneration)
        XCTAssertFalse(gate.acceptsStartup(generation: firstGeneration))
        XCTAssertFalse(gate.markRunning(generation: firstGeneration))

        let secondGeneration = try XCTUnwrap(gate.beginStart())
        XCTAssertGreaterThan(secondGeneration, stop.generation)
        XCTAssertFalse(gate.acceptsStartup(generation: firstGeneration))
        XCTAssertTrue(gate.acceptsStartup(generation: secondGeneration))
        XCTAssertTrue(gate.markRunning(generation: secondGeneration))
        XCTAssertEqual(gate.phase, .running)
    }

    func testStoppingStreamBlocksRestartUntilMatchingCompletion() throws {
        var gate = ScreenCaptureLifecycleGate()
        let startGeneration = try XCTUnwrap(gate.beginStart())
        XCTAssertTrue(gate.markRunning(generation: startGeneration))

        let stop = try XCTUnwrap(gate.beginStop(hasStream: true))

        XCTAssertTrue(stop.waitsForStream)
        XCTAssertEqual(gate.phase, .stopping)
        XCTAssertNil(gate.beginStart())
        XCTAssertFalse(gate.completeStop(generation: startGeneration))
        XCTAssertTrue(gate.completeStop(generation: stop.generation))
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertNotNil(gate.beginStart())
    }

    func testStartupFailureReturnsGateToRecoverableStoppedState() throws {
        var gate = ScreenCaptureLifecycleGate()
        let failedGeneration = try XCTUnwrap(gate.beginStart())

        XCTAssertTrue(gate.failCurrent(generation: failedGeneration))
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertFalse(gate.failCurrent(generation: failedGeneration))
        XCTAssertNotNil(gate.beginStart())
    }

    func testVisibleContextSkipsFrontWindowOnAnotherDisplay() {
        let candidates = [
            candidate(
                pid: 10,
                bounds: CGRect(x: 200, y: 0, width: 100, height: 100),
                applicationName: "Other Display"
            ),
            candidate(
                pid: 20,
                bounds: CGRect(x: 25, y: 25, width: 50, height: 50),
                applicationName: "Captured Display",
                windowTitle: "Visible document"
            )
        ]

        let context = ScreenCaptureVisibleContextSelector.select(
            from: candidates,
            capturedDisplayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownPID: 99,
            bundleIdentifier: { "bundle.\($0)" }
        )

        XCTAssertEqual(
            context,
            ScreenCaptureVisibleContext(
                applicationName: "Captured Display",
                bundleIdentifier: "bundle.20",
                windowTitle: "Visible document"
            )
        )
    }

    func testVisibleContextFallsBackRatherThanUsingAnotherDisplay() {
        let context = ScreenCaptureVisibleContextSelector.select(
            from: [
                candidate(
                    pid: 10,
                    bounds: CGRect(x: -300, y: 0, width: 200, height: 100),
                    applicationName: "Other Display"
                )
            ],
            capturedDisplayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownPID: 99,
            bundleIdentifier: { _ in "must.not.be.used" }
        )

        XCTAssertEqual(
            context,
            ScreenCaptureVisibleContext(
                applicationName: "Captured display",
                bundleIdentifier: nil,
                windowTitle: nil
            )
        )
    }

    func testVisibleContextRequiresLayerZeroAndPositiveIntersection() {
        let candidates = [
            ScreenCaptureWindowCandidate(
                ownerPID: 10,
                layer: 1,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                applicationName: "Overlay",
                windowTitle: nil
            ),
            candidate(
                pid: 20,
                bounds: CGRect(x: 100, y: 0, width: 10, height: 10),
                applicationName: "Touches Edge"
            )
        ]

        let context = ScreenCaptureVisibleContextSelector.select(
            from: candidates,
            capturedDisplayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownPID: 99,
            bundleIdentifier: { _ in nil }
        )

        XCTAssertEqual(context.applicationName, "Captured display")
    }

    private func candidate(
        pid: pid_t,
        bounds: CGRect,
        applicationName: String,
        windowTitle: String? = nil
    ) -> ScreenCaptureWindowCandidate {
        ScreenCaptureWindowCandidate(
            ownerPID: pid,
            layer: 0,
            alpha: 1,
            bounds: bounds,
            applicationName: applicationName,
            windowTitle: windowTitle
        )
    }
}

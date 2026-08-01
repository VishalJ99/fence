import CoreGraphics
import XCTest
@testable import Tab

final class EyeTrackingGeometryTests: XCTestCase {
    func testPupilOffsetUsesFullRadiusTowardCursor() {
        let offset = EyeTrackingGeometry.pupilOffset(
            eyeCenter: CGPoint(x: 10, y: 10),
            cursorLocation: CGPoint(x: 110, y: 10),
            maximumDisplacement: 3.5
        )

        XCTAssertEqual(offset.x, 3.5, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 0, accuracy: 0.0001)
    }

    func testPupilOffsetNormalizesDiagonalDirection() {
        let offset = EyeTrackingGeometry.pupilOffset(
            eyeCenter: .zero,
            cursorLocation: CGPoint(x: 3, y: 4),
            maximumDisplacement: 5
        )

        XCTAssertEqual(offset.x, 3, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 4, accuracy: 0.0001)
    }

    func testPupilOffsetIsZeroAtEyeCenter() {
        XCTAssertEqual(
            EyeTrackingGeometry.pupilOffset(
                eyeCenter: CGPoint(x: 4, y: 7),
                cursorLocation: CGPoint(x: 4, y: 7),
                maximumDisplacement: 3.5
            ),
            .zero
        )
    }

    func testSmootherConvergesWithoutJumping() {
        var smoother = ExponentialPointSmoother()
        XCTAssertEqual(
            smoother.update(target: .zero, deltaTime: 0, timeConstant: 0.08),
            .zero
        )

        let next = smoother.update(
            target: CGPoint(x: 100, y: 0),
            deltaTime: 1.0 / 30.0,
            timeConstant: 0.08
        )

        XCTAssertGreaterThan(next.x, 0)
        XCTAssertLessThan(next.x, 100)
        XCTAssertEqual(next.y, 0)
    }
}

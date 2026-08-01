import CoreGraphics
import XCTest
@testable import Tab

final class NotchLayoutTests: XCTestCase {
    func testPanelIsCenteredImmediatelyBelowPhysicalHousing() throws {
        let screen = ScreenSnapshot(
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1291, width: 918, height: 38),
            auxiliaryTopRightArea: CGRect(x: 1138, y: 1291, width: 918, height: 38),
            isBuiltIn: true
        )

        let frame = try XCTUnwrap(NotchLayout.panelFrame(for: screen))
        XCTAssertEqual(frame, CGRect(x: 1006, y: 1271, width: 44, height: 20))
    }

    func testExternalNotchedGeometryIsIgnored() {
        let screen = ScreenSnapshot(
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1291, width: 918, height: 38),
            auxiliaryTopRightArea: CGRect(x: 1138, y: 1291, width: 918, height: 38),
            isBuiltIn: false
        )

        XCTAssertNil(NotchLayout.panelFrame(for: screen))
    }

    func testMissingAuxiliaryAreaIsTreatedAsNoNotch() {
        let screen = ScreenSnapshot(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 24,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: true
        )

        XCTAssertNil(NotchLayout.panelFrame(for: screen))
    }

    func testCompactMetricsProduceMinimalPanelSize() {
        XCTAssertEqual(EyeMetrics.compact.panelSize, CGSize(width: 44, height: 20))
    }
}

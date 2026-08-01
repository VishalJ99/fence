import AppKit
import CoreGraphics

struct ScreenSnapshot: Equatable {
    let frame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?
    let isBuiltIn: Bool

    init(
        frame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        isBuiltIn: Bool
    ) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.isBuiltIn = isBuiltIn
    }

    init(screen: NSScreen) {
        frame = screen.frame
        safeAreaTop = screen.safeAreaInsets.top
        auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea
        auxiliaryTopRightArea = screen.auxiliaryTopRightArea

        if let displayID = screen.tabDisplayID {
            isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        } else {
            isBuiltIn = false
        }
    }
}

struct NotchPlacement {
    let screen: NSScreen
    let panelFrame: CGRect
}

enum NotchLayout {
    static func panelFrame(
        for screen: ScreenSnapshot,
        panelSize: CGSize = EyeMetrics.compact.panelSize
    ) -> CGRect? {
        guard screen.isBuiltIn,
              screen.safeAreaTop > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              leftArea.maxX < rightArea.minX,
              panelSize.width > 0,
              panelSize.height > 0 else {
            return nil
        }

        let housingCenterX = (leftArea.maxX + rightArea.minX) / 2
        let housingBottom = screen.frame.maxY - screen.safeAreaTop

        return CGRect(
            x: housingCenterX - panelSize.width / 2,
            y: housingBottom - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        ).integral
    }

    static func placement(
        in screens: [NSScreen],
        panelSize: CGSize = EyeMetrics.compact.panelSize
    ) -> NotchPlacement? {
        for screen in screens {
            let snapshot = ScreenSnapshot(screen: screen)
            if let panelFrame = panelFrame(for: snapshot, panelSize: panelSize) {
                return NotchPlacement(screen: screen, panelFrame: panelFrame)
            }
        }
        return nil
    }
}

enum ExpressionPanelLayout {
    static let veryConcernedGutterWidth: CGFloat = 8

    static func frame(
        baseFrame: CGRect,
        expression: TabExpression
    ) -> CGRect {
        guard expression == .veryConcerned else { return baseFrame }

        return CGRect(
            x: baseFrame.minX,
            y: baseFrame.minY,
            width: baseFrame.width + veryConcernedGutterWidth,
            height: baseFrame.height
        )
    }
}

private extension NSScreen {
    var tabDisplayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

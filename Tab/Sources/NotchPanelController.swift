import AppKit

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchPanelController {
    private let metrics: EyeMetrics
    private let panel: PassivePanel
    private let eyesView: EyesView
    private let cursorTracker: CursorTracker
    private var currentExpression: TabExpression = .neutral

    var onExpressionChange: ((TabExpression) -> Void)?

    init(frame: CGRect, metrics: EyeMetrics = .compact) {
        self.metrics = metrics
        panel = PassivePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        eyesView = EyesView(
            frame: CGRect(origin: .zero, size: frame.size),
            metrics: metrics
        )
        cursorTracker = CursorTracker(eyesView: eyesView, metrics: metrics)

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.contentView = eyesView
        panel.title = "Tab - neutral"
        eyesView.onClick = { [weak self] in
            self?.cycleExpression()
        }
    }

    func show(at frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        cursorTracker.start()
    }

    func hide() {
        cursorTracker.stop()
        panel.orderOut(nil)
    }

    func setExpression(_ expression: TabExpression, animated: Bool) {
        currentExpression = expression
        panel.title = "Tab - \(expression.accessibilityName)"
        eyesView.setExpression(expression, animated: animated)
    }

    private func cycleExpression() {
        currentExpression = currentExpression.next
        panel.title = "Tab - \(currentExpression.accessibilityName)"
        eyesView.setExpression(currentExpression, animated: true)
        onExpressionChange?(currentExpression)
    }
}

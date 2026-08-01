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
    private var baseFrame: CGRect
    private var currentExpression: TabExpression = .neutral

    var onExpressionChange: ((TabExpression) -> Void)?

    init(frame: CGRect, metrics: EyeMetrics = .compact) {
        self.metrics = metrics
        baseFrame = frame
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
        baseFrame = frame
        updatePanelFrame(for: currentExpression)
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
        updatePanelFrame(for: expression)
        eyesView.setExpression(expression, animated: animated)
    }

    private func cycleExpression() {
        currentExpression = currentExpression.next
        setExpression(currentExpression, animated: true)
        onExpressionChange?(currentExpression)
    }

    private func updatePanelFrame(for expression: TabExpression) {
        panel.setFrame(
            ExpressionPanelLayout.frame(
                baseFrame: baseFrame,
                expression: expression
            ),
            display: true
        )
    }
}

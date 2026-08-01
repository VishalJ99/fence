import AppKit

final class EyesView: NSView {
    private let metrics: EyeMetrics
    private var visuals = ExpressionVisuals.neutral
    private var animationStartVisuals = ExpressionVisuals.neutral
    private var animationTargetVisuals = ExpressionVisuals.neutral
    private var animationStartTime: TimeInterval?
    private var animationTimer: Timer?
    private var faceWiggleOffset: CGFloat = 0

    var onClick: (() -> Void)?

    var cursorLocation: CGPoint = .zero {
        didSet { needsDisplay = true }
    }

    init(frame frameRect: NSRect, metrics: EyeMetrics = .compact) {
        self.metrics = metrics
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tab expression: neutral. Click to cycle.")
        setAccessibilityHelp("Cycles between neutral, mild concern, and very concerned.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    deinit {
        animationTimer?.invalidate()
    }

    func setExpression(_ expression: TabExpression, animated: Bool) {
        setAccessibilityLabel(
            "Tab expression: \(expression.accessibilityName). Click to cycle."
        )
        animationTimer?.invalidate()
        animationTimer = nil

        let target = ExpressionVisuals(expression: expression)
        guard animated else {
            visuals = target
            animationStartVisuals = target
            animationTargetVisuals = target
            animationStartTime = nil
            faceWiggleOffset = 0
            needsDisplay = true
            return
        }

        animationStartVisuals = visuals
        animationTargetVisuals = target
        animationStartTime = ProcessInfo.processInfo.systemUptime

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceExpressionAnimation(toward: expression)
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawNotchExtension()

        for center in eyeCenters {
            drawEye(center: center)
        }
        drawConcernBrows()
        drawStressHatch()
    }

    private var eyeCenters: [CGPoint] {
        let firstX = metrics.horizontalPadding + metrics.eyeDiameter / 2 + faceWiggleOffset
        let secondX = firstX + metrics.eyeDiameter + metrics.eyeGap
        let centerY = bounds.midY
        return [
            CGPoint(x: firstX, y: centerY),
            CGPoint(x: secondX, y: centerY)
        ]
    }

    private func drawNotchExtension() {
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: metrics.cornerRadius,
            yRadius: metrics.cornerRadius
        ).fill()

        NSBezierPath(
            rect: NSRect(
                x: bounds.minX,
                y: bounds.midY,
                width: bounds.width,
                height: bounds.height / 2
            )
        ).fill()
    }

    private func drawEye(center: CGPoint) {
        let eyeRect = CGRect(
            x: center.x - metrics.eyeDiameter / 2,
            y: center.y - metrics.eyeDiameter / 2,
            width: metrics.eyeDiameter,
            height: metrics.eyeDiameter
        )

        NSColor.white.setFill()
        NSBezierPath(ovalIn: eyeRect).fill()
        NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
        let outline = NSBezierPath(ovalIn: eyeRect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        let offset = EyeTrackingGeometry.pupilOffset(
            eyeCenter: globalPoint(for: center),
            cursorLocation: cursorLocation,
            maximumDisplacement: metrics.maximumPupilDisplacement
        )
        let pupilDiameter = metrics.pupilDiameter * visuals.pupilScale
        let pupilCenter = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        let pupilRect = CGRect(
            x: pupilCenter.x - pupilDiameter / 2,
            y: pupilCenter.y - pupilDiameter / 2,
            width: pupilDiameter,
            height: pupilDiameter
        )

        NSColor.black.setFill()
        NSBezierPath(ovalIn: pupilRect).fill()
    }

    private func drawConcernBrows() {
        guard visuals.browOpacity > 0.001 else { return }

        let outerY = bounds.maxY - visuals.browOuterInset
        let innerY = min(
            bounds.maxY - 1,
            max(bounds.minY + 1, outerY + visuals.browLift)
        )
        let leftOuter = CGPoint(x: 6 + faceWiggleOffset, y: outerY)
        let leftInner = CGPoint(x: 19 + faceWiggleOffset, y: innerY)
        let rightInner = CGPoint(x: 25 + faceWiggleOffset, y: innerY)
        let rightOuter = CGPoint(x: 38 + faceWiggleOffset, y: outerY)

        NSColor(calibratedWhite: 0.97, alpha: visuals.browOpacity).setStroke()

        let leftBrow = NSBezierPath()
        leftBrow.move(to: leftOuter)
        leftBrow.curve(
            to: leftInner,
            controlPoint1: CGPoint(x: 10 + faceWiggleOffset, y: outerY + 0.2),
            controlPoint2: CGPoint(x: 16 + faceWiggleOffset, y: innerY - 0.2)
        )
        styleAndStrokeBrow(leftBrow)

        let rightBrow = NSBezierPath()
        rightBrow.move(to: rightInner)
        rightBrow.curve(
            to: rightOuter,
            controlPoint1: CGPoint(x: 28 + faceWiggleOffset, y: innerY - 0.2),
            controlPoint2: CGPoint(x: 34 + faceWiggleOffset, y: outerY + 0.2)
        )
        styleAndStrokeBrow(rightBrow)
    }

    private func styleAndStrokeBrow(_ path: NSBezierPath) {
        path.lineWidth = 1 + visuals.browOpacity * 0.8
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawStressHatch() {
        guard visuals.stressOpacity > 0.001 else { return }

        let mark = NSBezierPath()
        let centerX = metrics.panelSize.width - 2
        let centerY = bounds.midY + 3.8
        let radialSpacingIncrease: CGFloat = 0.1
        let topBottomOffset = 4 * radialSpacingIncrease
        let sideOffset = 4.5 * radialSpacingIncrease
        let rotationCosine: CGFloat = 0.939_692_620_785_908_4
        let rotationSine: CGFloat = 0.342_020_143_325_668_7

        // Apply a 20-degree clockwise rotation around the temple anchor after
        // moving each complete C outward. The C shapes and stroke stay the
        // same size; only the negative space between them grows.
        let rotatedPoint: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(
                x: centerX + x * rotationCosine + y * rotationSine,
                y: centerY + y * rotationCosine - x * rotationSine
            )
        }

        // The familiar chibi anger hatch is four separate arcs bowing toward
        // an empty center. It sits at the top-right temple, with a small part
        // grazing the eye/brow region and the remainder in the state gutter.
        mark.move(to: rotatedPoint(-2.3, 4 + topBottomOffset))
        mark.curve(
            to: rotatedPoint(2.3, 4 + topBottomOffset),
            controlPoint1: rotatedPoint(-2.3, 1.5 + topBottomOffset),
            controlPoint2: rotatedPoint(2.3, 1.5 + topBottomOffset)
        )

        mark.move(to: rotatedPoint(2.3, -4 - topBottomOffset))
        mark.curve(
            to: rotatedPoint(-2.3, -4 - topBottomOffset),
            controlPoint1: rotatedPoint(2.3, -1.5 - topBottomOffset),
            controlPoint2: rotatedPoint(-2.3, -1.5 - topBottomOffset)
        )

        mark.move(to: rotatedPoint(-4.5 - sideOffset, -2.3))
        mark.curve(
            to: rotatedPoint(-4.5 - sideOffset, 2.3),
            controlPoint1: rotatedPoint(-1.9 - sideOffset, -2.3),
            controlPoint2: rotatedPoint(-1.9 - sideOffset, 2.3)
        )

        mark.move(to: rotatedPoint(4.5 + sideOffset, 2.3))
        mark.curve(
            to: rotatedPoint(4.5 + sideOffset, -2.3),
            controlPoint1: rotatedPoint(1.9 + sideOffset, 2.3),
            controlPoint2: rotatedPoint(1.9 + sideOffset, -2.3)
        )

        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round

        NSColor(
            srgbRed: 1,
            green: 0.32,
            blue: 0.39,
            alpha: visuals.stressOpacity
        ).setStroke()
        mark.lineWidth = 1.8
        mark.stroke()
    }

    private func advanceExpressionAnimation(toward expression: TabExpression) {
        guard let animationStartTime else { return }

        let duration: TimeInterval = 0.24
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartTime
        let linearProgress = min(max(elapsed / duration, 0), 1)
        let easedProgress = 1 - pow(1 - linearProgress, 3)
        visuals = animationStartVisuals.interpolated(
            to: animationTargetVisuals,
            progress: CGFloat(easedProgress)
        )

        if expression == .veryConcerned {
            faceWiggleOffset = CGFloat(
                sin(linearProgress * .pi * 4) * (1 - linearProgress) * 0.7
            )
        } else {
            faceWiggleOffset = 0
        }
        needsDisplay = true

        if linearProgress >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
            self.animationStartTime = nil
            faceWiggleOffset = 0
            visuals = animationTargetVisuals
            needsDisplay = true
        }
    }

    private func globalPoint(for localPoint: CGPoint) -> CGPoint {
        guard let window else { return localPoint }
        let pointInWindow = convert(localPoint, to: nil)
        return window.convertPoint(toScreen: pointInWindow)
    }
}

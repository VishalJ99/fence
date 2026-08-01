import CoreGraphics
import Foundation

struct EyeMetrics: Equatable {
    let eyeDiameter: CGFloat
    let pupilDiameter: CGFloat
    let eyeGap: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let smoothingTimeConstant: TimeInterval

    static let compact = EyeMetrics(
        eyeDiameter: 14,
        pupilDiameter: 5,
        eyeGap: 4,
        horizontalPadding: 6,
        verticalPadding: 3,
        cornerRadius: 6,
        smoothingTimeConstant: 0.08
    )

    var panelSize: CGSize {
        CGSize(
            width: horizontalPadding * 2 + eyeDiameter * 2 + eyeGap,
            height: verticalPadding * 2 + eyeDiameter
        )
    }

    var maximumPupilDisplacement: CGFloat {
        max(0, (eyeDiameter - pupilDiameter) / 2 - 1)
    }
}

enum EyeTrackingGeometry {
    static func pupilOffset(
        eyeCenter: CGPoint,
        cursorLocation: CGPoint,
        maximumDisplacement: CGFloat
    ) -> CGPoint {
        guard maximumDisplacement > 0 else { return .zero }

        let deltaX = cursorLocation.x - eyeCenter.x
        let deltaY = cursorLocation.y - eyeCenter.y
        let distance = hypot(deltaX, deltaY)
        guard distance > .ulpOfOne else { return .zero }

        return CGPoint(
            x: deltaX / distance * maximumDisplacement,
            y: deltaY / distance * maximumDisplacement
        )
    }
}

struct ExponentialPointSmoother {
    private(set) var value: CGPoint?

    mutating func reset(to point: CGPoint? = nil) {
        value = point
    }

    mutating func update(
        target: CGPoint,
        deltaTime: TimeInterval,
        timeConstant: TimeInterval
    ) -> CGPoint {
        guard let current = value else {
            value = target
            return target
        }

        guard deltaTime > 0, timeConstant > 0 else {
            value = target
            return target
        }

        let alpha = 1 - exp(-deltaTime / timeConstant)
        let updated = CGPoint(
            x: current.x + (target.x - current.x) * alpha,
            y: current.y + (target.y - current.y) * alpha
        )
        value = updated
        return updated
    }
}

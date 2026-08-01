import CoreGraphics
import Foundation

enum TabExpression: String, CaseIterable {
    case neutral
    case mildConcern = "mild"
    case veryConcerned = "very"

    var next: TabExpression {
        switch self {
        case .neutral:
            return .mildConcern
        case .mildConcern:
            return .veryConcerned
        case .veryConcerned:
            return .neutral
        }
    }

    var accessibilityName: String {
        switch self {
        case .neutral:
            return "neutral"
        case .mildConcern:
            return "mild concern"
        case .veryConcerned:
            return "very concerned"
        }
    }

    static func parse(_ value: String) -> TabExpression? {
        switch value.lowercased() {
        case "neutral":
            return .neutral
        case "mild", "mild-concern", "mildconcern":
            return .mildConcern
        case "very", "concerned", "very-concerned", "veryconcerned":
            return .veryConcerned
        default:
            return nil
        }
    }
}

struct ExpressionVisuals: Equatable {
    let browOpacity: CGFloat
    let browOuterInset: CGFloat
    let browLift: CGFloat
    let pupilScale: CGFloat
    let stressOpacity: CGFloat

    static let neutral = ExpressionVisuals(
        browOpacity: 0,
        browOuterInset: 4.8,
        browLift: 0,
        pupilScale: 1,
        stressOpacity: 0
    )

    static let mildConcern = ExpressionVisuals(
        browOpacity: 0.92,
        browOuterInset: 4.8,
        browLift: 2.4,
        pupilScale: 0.94,
        stressOpacity: 0
    )

    static let veryConcerned = ExpressionVisuals(
        browOpacity: 1,
        browOuterInset: 1.6,
        browLift: -4,
        pupilScale: 0.82,
        stressOpacity: 1
    )

    init(expression: TabExpression) {
        switch expression {
        case .neutral:
            self = .neutral
        case .mildConcern:
            self = .mildConcern
        case .veryConcerned:
            self = .veryConcerned
        }
    }

    init(
        browOpacity: CGFloat,
        browOuterInset: CGFloat,
        browLift: CGFloat,
        pupilScale: CGFloat,
        stressOpacity: CGFloat
    ) {
        self.browOpacity = browOpacity
        self.browOuterInset = browOuterInset
        self.browLift = browLift
        self.pupilScale = pupilScale
        self.stressOpacity = stressOpacity
    }

    func interpolated(to target: ExpressionVisuals, progress: CGFloat) -> ExpressionVisuals {
        let amount = min(max(progress, 0), 1)
        return ExpressionVisuals(
            browOpacity: browOpacity + (target.browOpacity - browOpacity) * amount,
            browOuterInset: browOuterInset + (target.browOuterInset - browOuterInset) * amount,
            browLift: browLift + (target.browLift - browLift) * amount,
            pupilScale: pupilScale + (target.pupilScale - pupilScale) * amount,
            stressOpacity: stressOpacity + (target.stressOpacity - stressOpacity) * amount
        )
    }
}

struct TabLaunchConfiguration: Equatable {
    let initialExpression: TabExpression
    let cyclesExpressions: Bool

    init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        cyclesExpressions = arguments.contains("--demo-expressions")

        var expressionValue = environment["TAB_EXPRESSION"]
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--expression=") {
                expressionValue = String(argument.dropFirst("--expression=".count))
            } else if argument == "--expression", arguments.indices.contains(index + 1) {
                expressionValue = arguments[index + 1]
            }
        }
        initialExpression = expressionValue.flatMap(TabExpression.parse) ?? .neutral
    }
}

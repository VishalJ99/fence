import XCTest
@testable import Tab

final class TabExpressionTests: XCTestCase {
    func testMildConcernUsesBrowsWithoutAlarmColor() {
        let visuals = ExpressionVisuals(expression: .mildConcern)
        XCTAssertGreaterThanOrEqual(visuals.browOpacity, 0.9)
        XCTAssertGreaterThan(visuals.browLift, 0)
        XCTAssertEqual(visuals.stressOpacity, 0)
    }

    func testVeryConcernedAddsStressCueAndSmallerPupils() {
        let mild = ExpressionVisuals(expression: .mildConcern)
        let very = ExpressionVisuals(expression: .veryConcerned)
        XCTAssertGreaterThan(mild.browLift, 0)
        XCTAssertLessThan(very.browLift, 0)
        XCTAssertLessThan(very.browOuterInset, mild.browOuterInset)
        XCTAssertGreaterThan(very.stressOpacity, 0)
        XCTAssertLessThan(very.pupilScale, mild.pupilScale)
    }

    func testLaunchArgumentsSelectExpressionAndDemo() {
        let configuration = TabLaunchConfiguration(
            arguments: ["Tab", "--expression", "very", "--demo-expressions"],
            environment: [:]
        )
        XCTAssertEqual(configuration.initialExpression, .veryConcerned)
        XCTAssertTrue(configuration.cyclesExpressions)
        XCTAssertFalse(configuration.showsScreenContextLog)
    }

    func testEnvironmentCanSelectMildConcern() {
        let configuration = TabLaunchConfiguration(
            arguments: ["Tab"],
            environment: ["TAB_EXPRESSION": "mild"]
        )
        XCTAssertEqual(configuration.initialExpression, .mildConcern)
        XCTAssertFalse(configuration.cyclesExpressions)
        XCTAssertFalse(configuration.showsScreenContextLog)
    }

    func testScreenContextLogRequiresExplicitOptIn() {
        let argumentConfiguration = TabLaunchConfiguration(
            arguments: ["Tab", "--screen-context-log"],
            environment: [:]
        )
        XCTAssertTrue(argumentConfiguration.showsScreenContextLog)

        let environmentConfiguration = TabLaunchConfiguration(
            arguments: ["Tab"],
            environment: ["TAB_SCREEN_CONTEXT_LOG": "1"]
        )
        XCTAssertTrue(environmentConfiguration.showsScreenContextLog)
    }

    func testClickCycleVisitsEveryExpression() {
        XCTAssertEqual(TabExpression.neutral.next, .mildConcern)
        XCTAssertEqual(TabExpression.mildConcern.next, .veryConcerned)
        XCTAssertEqual(TabExpression.veryConcerned.next, .neutral)
    }
}

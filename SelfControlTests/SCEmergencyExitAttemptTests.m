//
//  SCEmergencyExitAttemptTests.m
//  SelfControlTests
//

#import <XCTest/XCTest.h>

#import "SCEmergencyExitAttempt.h"

@interface SCEmergencyExitAttemptTests : XCTestCase
@end

@implementation SCEmergencyExitAttemptTests

- (void)testBoxMullerSamplerUsesProductMeanAndClampsBothTails {
    XCTAssertEqualWithAccuracy(SCEmergencyExitCheckpointOffsetForUniforms(0.5, 0.25), 90.0, 0.0001);
    XCTAssertEqualWithAccuracy(SCEmergencyExitCheckpointOffsetForUniforms(0.01, 0.0), 177.0, 0.0001);
    XCTAssertEqualWithAccuracy(SCEmergencyExitCheckpointOffsetForUniforms(0.01, 0.5), 45.0, 0.0001);
}

- (void)testDurationRelativeSamplerPreservesThreeMinuteDistributionAndBounds {
    XCTAssertEqualWithAccuracy(
        SCEmergencyExitCheckpointOffsetForUniformsAndDuration(0.5, 0.25, 180.0),
        SCEmergencyExitCheckpointOffsetForUniforms(0.5, 0.25), 0.0001);
    XCTAssertEqualWithAccuracy(
        SCEmergencyExitCheckpointOffsetForUniformsAndDuration(0.01, 0.5, 60.0),
        45.0, 0.0001);
    XCTAssertEqualWithAccuracy(
        SCEmergencyExitCheckpointOffsetForUniformsAndDuration(0.01, 0.0, 600.0),
        597.0, 0.0001);
}

- (void)testConfiguredDurationControlsCompletion {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithDuration:60.0 checkpointProvider:^NSTimeInterval{ return 45.0; }];
    XCTAssertEqual([attempt updateAtUptime:10 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionStarted);
    XCTAssertEqual([attempt updateAtUptime:55 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCheckpointPresented);
    XCTAssertEqual([attempt confirmCheckpointAtUptime:56],
                   SCEmergencyExitAttemptTransitionCheckpointConfirmed);
    XCTAssertEqual([attempt updateAtUptime:70 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCompleted);
}

- (void)testAttemptStartsOnlyWhenAllEligibilityConditionsAreTrueAndSamplesOnce {
    __block NSUInteger sampleCount = 0;
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{
            sampleCount += 1;
            return 90.0;
        }];

    XCTAssertEqual([attempt updateAtUptime:1 applicationActive:NO windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:2 applicationActive:YES windowKey:NO fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:3 applicationActive:YES windowKey:YES fullScreen:NO],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual(sampleCount, 0u);

    XCTAssertEqual([attempt updateAtUptime:4 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionStarted);
    XCTAssertEqual(sampleCount, 1u);
    XCTAssertEqual(attempt.attemptCount, 1u);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateRunningBeforeCheckpoint);

    XCTAssertEqual([attempt updateAtUptime:5 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual(sampleCount, 1u);
}

- (void)testAcknowledgedCheckpointAllowsCompletionAtExactlyThreeMinutesOnce {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 90.0; }];

    XCTAssertEqual([attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionStarted);
    XCTAssertEqual([attempt updateAtUptime:89.999 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:90 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCheckpointPresented);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateCheckpointPending);
    XCTAssertEqual([attempt wholeCheckpointSecondsRemainingAtUptime:90], 3);

    XCTAssertEqual([attempt confirmCheckpointAtUptime:92.999],
                   SCEmergencyExitAttemptTransitionCheckpointConfirmed);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateRunningAfterCheckpoint);
    XCTAssertEqual([attempt updateAtUptime:179.999 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:180 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCompleted);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateCompleted);
    XCTAssertEqual([attempt updateAtUptime:181 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
}

- (void)testCheckpointClickAtDeadlineIsRejectedAndRestartsImmediately {
    __block NSUInteger sampleCount = 0;
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{
            sampleCount += 1;
            return 90.0;
        }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    [attempt updateAtUptime:90 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt confirmCheckpointAtUptime:93], SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateRunningBeforeCheckpoint);
    XCTAssertEqual(attempt.attemptCount, 2u);
    XCTAssertEqual(sampleCount, 2u);
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:93], 180);
}

- (void)testMissingCheckpointRestartsAtThreeSecondDeadline {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 60.0; }];

    [attempt updateAtUptime:10 applicationActive:YES windowKey:YES fullScreen:YES];
    [attempt updateAtUptime:70 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt updateAtUptime:72.999 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:73 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual(attempt.attemptCount, 2u);
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:73], 180);
}

- (void)testCheckpointGetsThreeSecondsFromWhenItBecomesVisible {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 60.0; }];

    [attempt updateAtUptime:10 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt updateAtUptime:70.1 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCheckpointPresented);
    XCTAssertEqual([attempt wholeCheckpointSecondsRemainingAtUptime:70.1], 3);
    XCTAssertEqual([attempt confirmCheckpointAtUptime:73.099],
                   SCEmergencyExitAttemptTransitionCheckpointConfirmed);
}

- (void)testDelayedTickCannotSkipEntireCheckpointWindow {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 90.0; }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt updateAtUptime:94 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateRunningBeforeCheckpoint);
    XCTAssertEqual(attempt.attemptCount, 2u);
}

- (void)testMaximumCheckpointMustBeAcknowledgedBeforeCompletionBoundary {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 177.0; }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt updateAtUptime:177 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionCheckpointPresented);
    XCTAssertEqual([attempt updateAtUptime:180 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertNotEqual(attempt.state, SCEmergencyExitAttemptStateCompleted);
}

- (void)testEachEligibilityFailureResetsAndWaitsForAllConditionsBeforeRestarting {
    __block NSUInteger sampleCount = 0;
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{
            sampleCount += 1;
            return 90.0;
        }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt updateAtUptime:1 applicationActive:NO windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateWaitingForEligibility);
    XCTAssertEqual([attempt updateAtUptime:2 applicationActive:YES windowKey:NO fullScreen:YES],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual([attempt updateAtUptime:3 applicationActive:YES windowKey:YES fullScreen:NO],
                   SCEmergencyExitAttemptTransitionNone);
    XCTAssertEqual(sampleCount, 1u);

    XCTAssertEqual([attempt updateAtUptime:4 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionStarted);
    XCTAssertEqual(sampleCount, 2u);
    XCTAssertEqual([attempt updateAtUptime:5 applicationActive:YES windowKey:NO fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual([attempt updateAtUptime:6 applicationActive:YES windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionStarted);
    XCTAssertEqual(sampleCount, 3u);
    XCTAssertEqual([attempt updateAtUptime:7 applicationActive:YES windowKey:YES fullScreen:NO],
                   SCEmergencyExitAttemptTransitionReset);
}

- (void)testResetSamplesANewCheckpointForTheNextAttempt {
    __block NSArray<NSNumber *> *offsets = @[@60.0, @120.0];
    __block NSUInteger index = 0;
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{
            return offsets[index++].doubleValue;
        }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqualWithAccuracy(attempt.checkpointOffset, 60.0, 0.001);
    [attempt updateAtUptime:1 applicationActive:NO windowKey:YES fullScreen:YES];
    [attempt updateAtUptime:2 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqualWithAccuracy(attempt.checkpointOffset, 120.0, 0.001);
    XCTAssertEqual(index, 2u);
}

- (void)testLosingEligibilityAfterCheckpointConfirmationAlsoResets {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 45.0; }];

    [attempt updateAtUptime:0 applicationActive:YES windowKey:YES fullScreen:YES];
    [attempt updateAtUptime:45 applicationActive:YES windowKey:YES fullScreen:YES];
    [attempt confirmCheckpointAtUptime:46];
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateRunningAfterCheckpoint);
    XCTAssertEqual([attempt updateAtUptime:100 applicationActive:NO windowKey:YES fullScreen:YES],
                   SCEmergencyExitAttemptTransitionReset);
    XCTAssertEqual(attempt.state, SCEmergencyExitAttemptStateWaitingForEligibility);
}

- (void)testPrimaryCountdownRoundsUpAndResetsToThreeMinutes {
    SCEmergencyExitAttempt *attempt = [[SCEmergencyExitAttempt alloc]
        initWithCheckpointProvider:^NSTimeInterval{ return 90.0; }];

    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:1000], 180);
    [attempt updateAtUptime:10 applicationActive:YES windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:10], 180);
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:10.001], 180);
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:11], 179);
    [attempt updateAtUptime:12 applicationActive:NO windowKey:YES fullScreen:YES];
    XCTAssertEqual([attempt wholeSecondsRemainingAtUptime:12], 180);
}

@end

//
//  SCEmergencyExitAttempt.m
//  SelfControl
//

#import "SCEmergencyExitAttempt.h"

#import <float.h>
#import <math.h>
#import <stdlib.h>

const NSTimeInterval SCEmergencyExitAttemptDuration = 180.0;
const NSTimeInterval SCEmergencyExitCheckpointResponseDuration = 3.0;
const NSTimeInterval SCEmergencyExitMinimumCheckpointOffset = 45.0;
const NSTimeInterval SCEmergencyExitMaximumCheckpointOffset = 177.0;

static double SCClampOpenUniform(double value) {
    if (!isfinite(value)) return 0.5;
    return MIN(MAX(value, DBL_EPSILON), 1.0 - DBL_EPSILON);
}

NSTimeInterval SCEmergencyExitCheckpointOffsetForUniforms(double firstUniform,
                                                           double secondUniform) {
    return SCEmergencyExitCheckpointOffsetForUniformsAndDuration(
        firstUniform, secondUniform, SCEmergencyExitAttemptDuration);
}

NSTimeInterval SCEmergencyExitCheckpointOffsetForUniformsAndDuration(
    double firstUniform, double secondUniform, NSTimeInterval duration) {
    NSTimeInterval resolvedDuration = MAX(60.0, duration);
    double u1 = SCClampOpenUniform(firstUniform);
    double u2 = SCClampOpenUniform(secondUniform);
    double standardNormal = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
    double sampledOffset = (resolvedDuration / 2.0) +
        ((resolvedDuration / 6.0) * standardNormal);
    NSTimeInterval maximumOffset = resolvedDuration -
        SCEmergencyExitCheckpointResponseDuration;
    return MIN(MAX(sampledOffset, SCEmergencyExitMinimumCheckpointOffset), maximumOffset);
}

static double SCOpenUniformSample(void) {
    static const uint32_t sampleCount = (1u << 24);
    return ((double)arc4random_uniform(sampleCount) + 1.0) / ((double)sampleCount + 1.0);
}

NSTimeInterval SCEmergencyExitSampleCheckpointOffset(void) {
    return SCEmergencyExitSampleCheckpointOffsetForDuration(SCEmergencyExitAttemptDuration);
}

NSTimeInterval SCEmergencyExitSampleCheckpointOffsetForDuration(NSTimeInterval duration) {
    return SCEmergencyExitCheckpointOffsetForUniformsAndDuration(
        SCOpenUniformSample(), SCOpenUniformSample(), duration);
}

@interface SCEmergencyExitAttempt ()

@property (nonatomic, readwrite) SCEmergencyExitAttemptState state;
@property (nonatomic, readwrite) NSTimeInterval checkpointOffset;
@property (nonatomic, readwrite) NSTimeInterval attemptDuration;
@property (nonatomic, readwrite) NSUInteger attemptCount;
@property (nonatomic, copy) SCEmergencyExitCheckpointProvider checkpointProvider;
@property (nonatomic) NSTimeInterval startUptime;
@property (nonatomic) NSTimeInterval checkpointPresentedUptime;

@end

@implementation SCEmergencyExitAttempt

- (instancetype)initWithCheckpointProvider:(SCEmergencyExitCheckpointProvider)checkpointProvider {
    return [self initWithDuration:SCEmergencyExitAttemptDuration
               checkpointProvider:checkpointProvider];
}

- (instancetype)initWithDuration:(NSTimeInterval)duration
               checkpointProvider:(SCEmergencyExitCheckpointProvider)checkpointProvider {
    self = [super init];
    if (self) {
        _attemptDuration = MAX(60.0, duration);
        _checkpointProvider = [checkpointProvider copy];
        _state = SCEmergencyExitAttemptStateWaitingForEligibility;
    }
    return self;
}

- (BOOL)isEligibleWithApplicationActive:(BOOL)applicationActive
                               windowKey:(BOOL)windowKey
                              fullScreen:(BOOL)fullScreen {
    return applicationActive && windowKey && fullScreen;
}

- (void)startAtUptime:(NSTimeInterval)uptime {
    NSTimeInterval sampledOffset = self.checkpointProvider();
    NSTimeInterval maximumCheckpointOffset = self.attemptDuration -
        SCEmergencyExitCheckpointResponseDuration;
    self.checkpointOffset = MIN(MAX(sampledOffset, SCEmergencyExitMinimumCheckpointOffset),
                                maximumCheckpointOffset);
    self.startUptime = uptime;
    self.checkpointPresentedUptime = 0;
    self.attemptCount += 1;
    self.state = SCEmergencyExitAttemptStateRunningBeforeCheckpoint;
}

- (NSTimeInterval)elapsedAtUptime:(NSTimeInterval)uptime {
    return MAX(0.0, uptime - self.startUptime);
}

- (SCEmergencyExitAttemptTransition)resetForEligibility:(BOOL)eligible
                                                uptime:(NSTimeInterval)uptime {
    self.state = SCEmergencyExitAttemptStateWaitingForEligibility;
    if (eligible) {
        [self startAtUptime:uptime];
    }
    return SCEmergencyExitAttemptTransitionReset;
}

- (SCEmergencyExitAttemptTransition)updateAtUptime:(NSTimeInterval)uptime
                                  applicationActive:(BOOL)applicationActive
                                          windowKey:(BOOL)windowKey
                                         fullScreen:(BOOL)fullScreen {
    if (self.state == SCEmergencyExitAttemptStateCompleted) {
        return SCEmergencyExitAttemptTransitionNone;
    }

    BOOL eligible = [self isEligibleWithApplicationActive:applicationActive
                                                 windowKey:windowKey
                                                fullScreen:fullScreen];
    if (!eligible) {
        if (self.state != SCEmergencyExitAttemptStateWaitingForEligibility) {
            return [self resetForEligibility:NO uptime:uptime];
        }
        return SCEmergencyExitAttemptTransitionNone;
    }

    if (self.state == SCEmergencyExitAttemptStateWaitingForEligibility) {
        [self startAtUptime:uptime];
        return SCEmergencyExitAttemptTransitionStarted;
    }

    NSTimeInterval elapsed = [self elapsedAtUptime:uptime];
    NSTimeInterval checkpointDeadline = self.checkpointOffset + SCEmergencyExitCheckpointResponseDuration;

    if (self.state == SCEmergencyExitAttemptStateRunningBeforeCheckpoint) {
        // A delayed run-loop callback must not skip over the attention check.
        if (elapsed >= checkpointDeadline) {
            return [self resetForEligibility:YES uptime:uptime];
        }
        if (elapsed >= self.checkpointOffset) {
            self.checkpointPresentedUptime = uptime;
            self.state = SCEmergencyExitAttemptStateCheckpointPending;
            return SCEmergencyExitAttemptTransitionCheckpointPresented;
        }
        return SCEmergencyExitAttemptTransitionNone;
    }

    if (self.state == SCEmergencyExitAttemptStateCheckpointPending) {
        if (uptime >= self.checkpointPresentedUptime + SCEmergencyExitCheckpointResponseDuration) {
            return [self resetForEligibility:YES uptime:uptime];
        }
        return SCEmergencyExitAttemptTransitionNone;
    }

    if (self.state == SCEmergencyExitAttemptStateRunningAfterCheckpoint &&
        elapsed >= self.attemptDuration) {
        self.state = SCEmergencyExitAttemptStateCompleted;
        return SCEmergencyExitAttemptTransitionCompleted;
    }

    return SCEmergencyExitAttemptTransitionNone;
}

- (SCEmergencyExitAttemptTransition)confirmCheckpointAtUptime:(NSTimeInterval)uptime {
    if (self.state != SCEmergencyExitAttemptStateCheckpointPending) {
        return SCEmergencyExitAttemptTransitionNone;
    }

    NSTimeInterval checkpointDeadline = self.checkpointPresentedUptime +
        SCEmergencyExitCheckpointResponseDuration;
    if (uptime >= checkpointDeadline) {
        return [self resetForEligibility:YES uptime:uptime];
    }

    self.state = SCEmergencyExitAttemptStateRunningAfterCheckpoint;
    return SCEmergencyExitAttemptTransitionCheckpointConfirmed;
}

- (NSInteger)wholeSecondsRemainingAtUptime:(NSTimeInterval)uptime {
    if (self.state == SCEmergencyExitAttemptStateWaitingForEligibility) {
        return (NSInteger)self.attemptDuration;
    }
    if (self.state == SCEmergencyExitAttemptStateCompleted) {
        return 0;
    }
    NSTimeInterval remaining = MAX(0.0, self.attemptDuration - [self elapsedAtUptime:uptime]);
    return (NSInteger)ceil(remaining);
}

- (NSInteger)wholeCheckpointSecondsRemainingAtUptime:(NSTimeInterval)uptime {
    if (self.state != SCEmergencyExitAttemptStateCheckpointPending) return 0;
    NSTimeInterval deadline = self.checkpointPresentedUptime +
        SCEmergencyExitCheckpointResponseDuration;
    return (NSInteger)ceil(MAX(0.0, deadline - uptime));
}

@end

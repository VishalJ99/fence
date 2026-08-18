//
//  SCEmergencyExitAttempt.h
//  SelfControl
//
//  Pure state machine for the Emergency Exit continuous-attention wait.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSTimeInterval SCEmergencyExitAttemptDuration;
FOUNDATION_EXPORT const NSTimeInterval SCEmergencyExitCheckpointResponseDuration;
FOUNDATION_EXPORT const NSTimeInterval SCEmergencyExitMinimumCheckpointOffset;
FOUNDATION_EXPORT const NSTimeInterval SCEmergencyExitMaximumCheckpointOffset;

typedef NS_ENUM(NSInteger, SCEmergencyExitAttemptState) {
    SCEmergencyExitAttemptStateWaitingForEligibility = 0,
    SCEmergencyExitAttemptStateRunningBeforeCheckpoint,
    SCEmergencyExitAttemptStateCheckpointPending,
    SCEmergencyExitAttemptStateRunningAfterCheckpoint,
    SCEmergencyExitAttemptStateCompleted,
};

typedef NS_ENUM(NSInteger, SCEmergencyExitAttemptTransition) {
    SCEmergencyExitAttemptTransitionNone = 0,
    SCEmergencyExitAttemptTransitionStarted,
    SCEmergencyExitAttemptTransitionCheckpointPresented,
    SCEmergencyExitAttemptTransitionCheckpointConfirmed,
    SCEmergencyExitAttemptTransitionReset,
    SCEmergencyExitAttemptTransitionCompleted,
};

typedef NSTimeInterval (^SCEmergencyExitCheckpointProvider)(void);

/// Converts two independent uniform samples into the product checkpoint offset.
/// The inputs are clamped into the open interval (0, 1), making this function a
/// deterministic test seam for the production Box-Muller sampler.
FOUNDATION_EXPORT NSTimeInterval SCEmergencyExitCheckpointOffsetForUniforms(double firstUniform,
                                                                             double secondUniform);

/// Samples one checkpoint from N(90 seconds, 30 seconds), clamped to 45...177.
FOUNDATION_EXPORT NSTimeInterval SCEmergencyExitSampleCheckpointOffset(void);

@interface SCEmergencyExitAttempt : NSObject

@property (nonatomic, readonly) SCEmergencyExitAttemptState state;
@property (nonatomic, readonly) NSTimeInterval checkpointOffset;
@property (nonatomic, readonly) NSUInteger attemptCount;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCheckpointProvider:(SCEmergencyExitCheckpointProvider)checkpointProvider
    NS_DESIGNATED_INITIALIZER;

/// Advances the state using an injected monotonic time and the three conditions
/// that must remain true for the entire attempt.
- (SCEmergencyExitAttemptTransition)updateAtUptime:(NSTimeInterval)uptime
                                  applicationActive:(BOOL)applicationActive
                                          windowKey:(BOOL)windowKey
                                         fullScreen:(BOOL)fullScreen;

/// Confirms the one checkpoint. Activation at the three-second deadline is too
/// late and resets the attempt.
- (SCEmergencyExitAttemptTransition)confirmCheckpointAtUptime:(NSTimeInterval)uptime;

/// Whole seconds shown by the primary 3:00 countdown, rounded up.
- (NSInteger)wholeSecondsRemainingAtUptime:(NSTimeInterval)uptime;

/// Whole seconds left to confirm a pending checkpoint, rounded up.
- (NSInteger)wholeCheckpointSecondsRemainingAtUptime:(NSTimeInterval)uptime;

@end

NS_ASSUME_NONNULL_END

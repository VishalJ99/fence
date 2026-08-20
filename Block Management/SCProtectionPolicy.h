//
//  SCProtectionPolicy.h
//  SelfControl
//
//  Pure policy helpers shared by the app and daemon-facing scheduler code.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const SCBreakCreditDefaultAllowance;
FOUNDATION_EXPORT NSInteger const SCBreakCreditMaximumAllowance;

/// Clamps a daily break allowance to the supported 0...10 range.
FOUNDATION_EXPORT NSInteger SCClampBreakCreditAllowance(NSInteger allowance);

/// An active commitment freezes the allowance until the commitment is ended.
FOUNDATION_EXPORT NSInteger SCResolveBreakCreditAllowanceUpdate(NSInteger requestedAllowance,
                                                                 NSInteger currentAllowance,
                                                                 BOOL hasSurvivingCommitment);

FOUNDATION_EXPORT NSInteger const SCEmergencyWaitDefaultMinutes;
FOUNDATION_EXPORT NSInteger const SCEmergencyWaitMinimumMinutes;
FOUNDATION_EXPORT NSInteger const SCEmergencyWaitMaximumMinutes;

/// Clamps the emergency-unlock wait to the supported 1...10 minute range.
FOUNDATION_EXPORT NSInteger SCClampEmergencyWaitMinutes(NSInteger minutes);

/// Reconciles the remaining daily credits against an injected local calendar.
/// A missing/different reset day or `forceReset` refills to the allowance.
/// Otherwise spent credits stay spent, subject only to clamping if the
/// allowance was reduced. The resolved reset day is normalized to local
/// midnight in `calendar`.
FOUNDATION_EXPORT NSInteger SCReconcileBreakCredits(NSInteger allowance,
                                                     NSInteger remainingToday,
                                                     NSDate * _Nullable lastResetDay,
                                                     NSDate *date,
                                                     NSCalendar *calendar,
                                                     BOOL forceReset,
                                                     NSDate * _Nullable * _Nullable resolvedResetDay,
                                                     BOOL * _Nullable didReset);

FOUNDATION_EXPORT NSInteger const SCProtectedHoursMinutesPerDay;
FOUNDATION_EXPORT NSInteger const SCProtectedHoursSnapIntervalMinutes;
FOUNDATION_EXPORT NSInteger const SCProtectedHoursMinimumDurationMinutes;
FOUNDATION_EXPORT NSInteger const SCProtectedHoursEditLockLeadMinutes;

typedef struct {
    NSInteger startMinute;
    NSInteger endMinute;
} SCProtectedHoursRange;

/// Wraps each endpoint into a local day, snaps it to 15 minutes, and guarantees
/// at least a 15-minute interval when both normalized endpoints coincide.
FOUNDATION_EXPORT SCProtectedHoursRange SCNormalizeProtectedHoursRange(NSInteger startMinute,
                                                                       NSInteger endMinute);

/// Tests the normalized half-open protected interval at an injected date.
/// Same-day intervals use start <= minute < end; overnight intervals wrap.
FOUNDATION_EXPORT BOOL SCProtectedHoursAreActive(BOOL enabled,
                                                 SCProtectedHoursRange range,
                                                 NSDate *date,
                                                 NSCalendar *calendar);

/// Tests the half-open edit lock from two hours before protected start through
/// protected end. Very long protected ranges whose lock covers a full day are
/// treated as locked all day.
FOUNDATION_EXPORT BOOL SCProtectedHoursEditLockIsActive(BOOL enabled,
                                                        SCProtectedHoursRange range,
                                                        NSDate *date,
                                                        NSCalendar *calendar);

/// Returns the next protected start/end transition strictly after `date`,
/// resolved as local wall time by the injected calendar. Returns nil when the
/// policy is disabled.
FOUNDATION_EXPORT NSDate * _Nullable SCNextProtectedHoursBoundary(BOOL enabled,
                                                                  SCProtectedHoursRange range,
                                                                  NSDate *date,
                                                                  NSCalendar *calendar);

NS_ASSUME_NONNULL_END

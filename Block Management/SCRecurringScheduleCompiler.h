//
//  SCRecurringScheduleCompiler.h
//  SelfControl
//
//  Pure compilation helpers for the recurring weekly scheduler.
//

#import <Foundation/Foundation.h>

@class SCBlockBundle;
@class SCWeeklySchedule;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const SCRecurringSegmentIDKey;
FOUNDATION_EXPORT NSString * const SCRecurringSegmentStartMinuteKey;
FOUNDATION_EXPORT NSString * const SCRecurringSegmentEndMinuteKey;
FOUNDATION_EXPORT NSString * const SCRecurringSegmentBlocklistKey;
FOUNDATION_EXPORT NSString * const SCRecurringSegmentSourceBundleIDsKey;
FOUNDATION_EXPORT NSString * const SCRecurringSegmentPolicyRevisionKey;

/// Compiles enabled allow-window bundles into non-overlapping, half-open
/// Monday-based minute-of-week denylist segments. Missing schedules are treated
/// as empty allow schedules (blocked all week), matching the existing product.
@interface SCRecurringScheduleCompiler : NSObject

+ (NSArray<NSDictionary<NSString *, id> *> *)segmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                       schedules:(NSArray<SCWeeklySchedule *> *)schedules;

/// Canonical serialization used only to compare legacy current/next drafts.
/// It contains no dates and does not mutate the source schedules.
+ (NSArray<NSDictionary *> *)canonicalDictionariesForSchedules:(NSArray<SCWeeklySchedule *> *)schedules;

@end

NS_ASSUME_NONNULL_END

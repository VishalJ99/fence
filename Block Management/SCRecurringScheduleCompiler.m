//
//  SCRecurringScheduleCompiler.m
//  SelfControl
//

#import "SCRecurringScheduleCompiler.h"
#import "SCBlockBundle.h"
#import "SCWeeklySchedule.h"
#import "SCTimeRange.h"

NSString * const SCRecurringSegmentIDKey = @"segmentID";
NSString * const SCRecurringSegmentStartMinuteKey = @"startMinuteOfWeek";
NSString * const SCRecurringSegmentEndMinuteKey = @"endMinuteOfWeek";
NSString * const SCRecurringSegmentBlocklistKey = @"blocklist";
NSString * const SCRecurringSegmentSourceBundleIDsKey = @"sourceBundleIDs";
NSString * const SCRecurringSegmentPolicyRevisionKey = @"policyRevision";

static const NSInteger SCMinutesPerDay = 24 * 60;
static const NSInteger SCMinutesPerWeek = 7 * SCMinutesPerDay;

@implementation SCRecurringScheduleCompiler

+ (BOOL)schedule:(SCWeeklySchedule *)schedule
isAllowedAtMondayBasedMinute:(NSInteger)minuteOfWeek {
    NSInteger dayFromMonday = minuteOfWeek / SCMinutesPerDay;
    NSInteger minuteOfDay = minuteOfWeek % SCMinutesPerDay;
    SCDayOfWeek day = dayFromMonday == 6
        ? SCDayOfWeekSunday
        : (SCDayOfWeek)(SCDayOfWeekMonday + dayFromMonday);

    for (SCTimeRange *range in [schedule allowedWindowsForDay:day]) {
        NSInteger start = MAX(0, MIN(SCMinutesPerDay - 1, range.startMinutes));
        NSInteger end = MAX(0, MIN(SCMinutesPerDay, range.endMinutes));
        if (start <= minuteOfDay && minuteOfDay < end) return YES;
    }
    return NO;
}

+ (NSDictionary<NSString *, SCWeeklySchedule *> *)schedulesByBundleID:(NSArray<SCWeeklySchedule *> *)schedules {
    NSMutableDictionary<NSString *, SCWeeklySchedule *> *result = [NSMutableDictionary dictionary];
    for (id candidate in schedules ?: @[]) {
        if (![candidate isKindOfClass:[SCWeeklySchedule class]]) continue;
        SCWeeklySchedule *schedule = candidate;
        if (schedule.bundleID.length > 0 && result[schedule.bundleID] == nil) {
            result[schedule.bundleID] = schedule;
        }
    }
    return result;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)policyAtMinute:(NSInteger)minute
                                                              bundles:(NSArray<SCBlockBundle *> *)bundles
                                                    schedulesByBundle:(NSDictionary<NSString *, SCWeeklySchedule *> *)schedulesByBundle {
    NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *sourceBundleIDs = [NSMutableOrderedSet orderedSet];

    for (SCBlockBundle *bundle in bundles) {
        if (![bundle isKindOfClass:[SCBlockBundle class]] || !bundle.enabled || bundle.bundleID.length == 0) continue;
        SCWeeklySchedule *schedule = schedulesByBundle[bundle.bundleID];
        if (schedule == nil) schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
        if ([self schedule:schedule isAllowedAtMondayBasedMinute:minute]) continue;

        BOOL contributed = NO;
        for (id candidate in bundle.entries ?: @[]) {
            if (![candidate isKindOfClass:[NSString class]] || [(NSString *)candidate length] == 0) continue;
            [entries addObject:candidate];
            contributed = YES;
        }
        if (contributed) [sourceBundleIDs addObject:bundle.bundleID];
    }

    return @{
        SCRecurringSegmentBlocklistKey: entries.array,
        SCRecurringSegmentSourceBundleIDsKey: sourceBundleIDs.array,
    };
}

+ (BOOL)policy:(NSDictionary<NSString *, NSArray<NSString *> *> *)left
equalsPolicy:(NSDictionary<NSString *, NSArray<NSString *> *> *)right {
    return [left[SCRecurringSegmentBlocklistKey] isEqual:right[SCRecurringSegmentBlocklistKey]] &&
        [left[SCRecurringSegmentSourceBundleIDsKey] isEqual:right[SCRecurringSegmentSourceBundleIDsKey]];
}

+ (NSArray<NSDictionary<NSString *,id> *> *)segmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                       schedules:(NSArray<SCWeeklySchedule *> *)schedules {
    NSArray<SCBlockBundle *> *orderedBundles = [bundles sortedArrayUsingComparator:^NSComparisonResult(
        SCBlockBundle *left, SCBlockBundle *right) {
        if (left.displayOrder < right.displayOrder) return NSOrderedAscending;
        if (left.displayOrder > right.displayOrder) return NSOrderedDescending;
        return [left.bundleID compare:right.bundleID];
    }];
    NSDictionary *schedulesByBundle = [self schedulesByBundleID:schedules];
    NSMutableArray<NSDictionary<NSString *, id> *> *segments = [NSMutableArray array];

    NSDictionary<NSString *, NSArray<NSString *> *> *activePolicy = nil;
    NSInteger activeStart = 0;
    for (NSInteger minute = 0; minute <= SCMinutesPerWeek; minute++) {
        NSDictionary *policy = minute < SCMinutesPerWeek
            ? [self policyAtMinute:minute bundles:orderedBundles schedulesByBundle:schedulesByBundle]
            : nil;
        if (activePolicy != nil && policy != nil && [self policy:activePolicy equalsPolicy:policy]) continue;

        if ([activePolicy[SCRecurringSegmentBlocklistKey] count] > 0) {
            [segments addObject:@{
                SCRecurringSegmentIDKey: NSUUID.UUID.UUIDString,
                SCRecurringSegmentStartMinuteKey: @(activeStart),
                SCRecurringSegmentEndMinuteKey: @(minute),
                SCRecurringSegmentBlocklistKey: activePolicy[SCRecurringSegmentBlocklistKey],
                SCRecurringSegmentSourceBundleIDsKey: activePolicy[SCRecurringSegmentSourceBundleIDsKey],
                SCRecurringSegmentPolicyRevisionKey: NSUUID.UUID.UUIDString,
            }];
        }
        activePolicy = policy;
        activeStart = minute;
    }
    return segments;
}

+ (NSArray<NSDictionary *> *)canonicalDictionariesForSchedules:(NSArray<SCWeeklySchedule *> *)schedules {
    NSMutableArray<NSDictionary *> *canonical = [NSMutableArray array];
    NSArray<SCWeeklySchedule *> *ordered = [schedules sortedArrayUsingComparator:^NSComparisonResult(
        SCWeeklySchedule *left, SCWeeklySchedule *right) {
        return [left.bundleID compare:right.bundleID];
    }];
    for (SCWeeklySchedule *schedule in ordered) {
        NSMutableDictionary *days = [NSMutableDictionary dictionary];
        for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
            NSArray<SCTimeRange *> *windows = [[schedule allowedWindowsForDay:day]
                sortedArrayUsingComparator:^NSComparisonResult(SCTimeRange *left, SCTimeRange *right) {
                    if (left.startMinutes < right.startMinutes) return NSOrderedAscending;
                    if (left.startMinutes > right.startMinutes) return NSOrderedDescending;
                    if (left.endMinutes < right.endMinutes) return NSOrderedAscending;
                    if (left.endMinutes > right.endMinutes) return NSOrderedDescending;
                    return NSOrderedSame;
                }];
            NSMutableArray *serializedWindows = [NSMutableArray arrayWithCapacity:windows.count];
            for (SCTimeRange *window in windows) [serializedWindows addObject:window.toDictionary];
            days[[SCWeeklySchedule stringForDay:day]] = serializedWindows;
        }
        [canonical addObject:@{
            @"bundleID": schedule.bundleID ?: @"",
            @"daySchedules": days,
        }];
    }
    return canonical;
}

@end

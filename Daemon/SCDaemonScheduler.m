//
//  SCDaemonScheduler.m
//  selfcontrold
//

#import "SCDaemonScheduler.h"
#include <math.h>
#include <time.h>

NSString * const SCDaemonScheduleSchemaVersionKey = @"schemaVersion";
NSString * const SCDaemonScheduleWeekKey = @"weekKey";
NSString * const SCDaemonScheduleCommitmentIDKey = @"commitmentID";
NSString * const SCDaemonScheduleGenerationKey = @"generation";
NSString * const SCDaemonSchedulePolicyRevisionKey = @"policyRevision";
NSString * const SCDaemonScheduleSourceBundleIDsKey = @"sourceBundleIDs";
NSString * const SCDaemonRecurringTimeZoneIdentifierKey = @"timeZoneIdentifier";
NSString * const SCDaemonRecurringFollowsLocationTimeZoneKey = @"followsLocationTimeZone";

NSString * const SCDaemonActiveBlockSourceManual = @"manual";
NSString * const SCDaemonActiveBlockSourceTest = @"test";
NSString * const SCDaemonActiveBlockSourceLegacySchedule = @"legacy_schedule";
NSString * const SCDaemonActiveBlockSourceSchedulerV2 = @"scheduler_v2";
NSString * const SCDaemonActiveBlockSourceSchedulerRecurring = @"scheduler_recurring";

BOOL SCDaemonScheduleEntryCountCanAdd(NSUInteger currentCount,
                                      NSUInteger additionCount,
                                      NSUInteger maximumCount) {
    return currentCount <= maximumCount && additionCount <= maximumCount - currentCount;
}

BOOL SCDaemonScheduleIntervalsOverlap(NSDate *leftStart,
                                      NSDate *leftEnd,
                                      NSDate *rightStart,
                                      NSDate *rightEnd) {
    if (![leftStart isKindOfClass:[NSDate class]] || ![leftEnd isKindOfClass:[NSDate class]] ||
        ![rightStart isKindOfClass:[NSDate class]] || ![rightEnd isKindOfClass:[NSDate class]] ||
        [leftEnd compare:leftStart] != NSOrderedDescending ||
        [rightEnd compare:rightStart] != NSOrderedDescending) return NO;
    return [leftStart compare:rightEnd] == NSOrderedAscending &&
        [rightStart compare:leftEnd] == NSOrderedAscending;
}

BOOL SCDaemonScheduleAdmissionConflictsWithRecurringCommitments(id recurringCommitments,
                                                                uid_t ownerUID) {
    if (ownerUID == 0 || ![recurringCommitments isKindOfClass:[NSDictionary class]]) return NO;
    for (id candidate in [(NSDictionary *)recurringCommitments allValues]) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *owner = [candidate[@"controllingUID"] isKindOfClass:[NSNumber class]]
            ? candidate[@"controllingUID"] : nil;
        if (owner.unsignedIntValue == ownerUID) return YES;
    }
    return NO;
}

static NSString * const SCDaemonSchedulerRecordIDKey = @"scheduleID";
static NSString * const SCDaemonSchedulerStartKey = @"approvedStartDate";
static NSString * const SCDaemonSchedulerEndKey = @"approvedEndDate";
static NSString * const SCDaemonSchedulerOwnerKey = @"controllingUID";
static NSString * const SCDaemonSchedulerBlocklistKey = @"blocklist";
static NSString * const SCDaemonSchedulerBlockSettingsKey = @"blockSettings";
static NSString * const SCDaemonSchedulerRecurringMarkerKey = @"recurringOccurrence";

static BOOL SCDaemonSchedulerUUIDString(id value) {
    return [value isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:(NSString *)value] != nil;
}

static BOOL SCDaemonSchedulerStringArray(id value, BOOL requireUUIDs) {
    if (![value isKindOfClass:[NSArray class]]) return NO;
    for (id candidate in (NSArray *)value) {
        if (![candidate isKindOfClass:[NSString class]] ||
            (requireUUIDs && !SCDaemonSchedulerUUIDString(candidate))) return NO;
    }
    return YES;
}

static BOOL SCDaemonSchedulerIntegerInRange(id value, NSInteger minimum, NSInteger maximum) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number && number >= minimum && number <= maximum;
}

static BOOL SCDaemonSchedulerBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSTimeZone *SCDaemonSchedulerTimeZoneFromIdentifier(id value) {
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) return nil;
    return [NSTimeZone timeZoneWithName:(NSString *)value];
}

static BOOL SCDaemonSchedulerProtectedHoursAreValid(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *hours = value;
    id enabled = hours[@"enabled"];
    if (![enabled isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID()) return NO;
    if (!SCDaemonSchedulerIntegerInRange(hours[@"startMinute"], 0, 1439) ||
        !SCDaemonSchedulerIntegerInRange(hours[@"endMinute"], 0, 1439)) return NO;
    return [hours[@"startMinute"] integerValue] != [hours[@"endMinute"] integerValue];
}

static NSDate *SCDaemonSchedulerStartOfMondayWeek(NSDate *date, NSCalendar *calendar) {
    NSDate *startOfDay = [calendar startOfDayForDate:date];
    NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:startOfDay];
    NSInteger daysSinceMonday = (weekday + 5) % 7;
    return [calendar dateByAddingUnit:NSCalendarUnitDay value:-daysSinceMonday toDate:startOfDay options:0];
}

static NSDate *SCDaemonSchedulerDateForMinuteOfWeek(NSInteger minuteOfWeek,
                                                     NSDate *weekStart,
                                                     NSCalendar *calendar) {
    NSInteger dayOffset = minuteOfWeek / (24 * 60);
    NSInteger minuteOfDay = minuteOfWeek % (24 * 60);
    NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:dayOffset toDate:weekStart options:0];
    return [calendar dateBySettingHour:minuteOfDay / 60
                                minute:minuteOfDay % 60
                                second:0
                                ofDate:day
                               options:NSCalendarMatchNextTimePreservingSmallerUnits];
}

static NSString *SCDaemonSchedulerWeekKey(NSDate *weekStart, NSCalendar *calendar) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = calendar;
    formatter.timeZone = calendar.timeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:weekStart];
}

static BOOL SCDaemonSchedulerRecordIsValid(NSString *scheduleID,
                                           NSDictionary<NSString *, id> *record,
                                           uid_t ownerUID) {
    if (!SCDaemonSchedulerUUIDString(scheduleID)) return NO;
    NSNumber *owner = [record[SCDaemonSchedulerOwnerKey] isKindOfClass:[NSNumber class]]
        ? record[SCDaemonSchedulerOwnerKey] : nil;
    NSDate *start = [record[SCDaemonSchedulerStartKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerStartKey] : nil;
    NSDate *end = [record[SCDaemonSchedulerEndKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerEndKey] : nil;
    if (owner == nil || owner.longLongValue <= 0 ||
        (ownerUID != 0 && owner.unsignedIntValue != ownerUID) ||
        start == nil || end == nil || [end compare:start] != NSOrderedDescending ||
        !SCDaemonSchedulerStringArray(record[SCDaemonSchedulerBlocklistKey], NO) ||
        ![record[SCDaemonSchedulerBlockSettingsKey] isKindOfClass:[NSDictionary class]]) return NO;

    id schemaVersionValue = record[SCDaemonScheduleSchemaVersionKey];
    if (schemaVersionValue == nil) return YES;
    if (![schemaVersionValue isKindOfClass:[NSNumber class]]) return NO;
    NSNumber *schemaVersion = schemaVersionValue;
    if (schemaVersion.integerValue == 1) return YES;
    if (schemaVersion.integerValue != 2 ||
        ![record[SCDaemonScheduleWeekKey] isKindOfClass:[NSString class]] ||
        [(NSString *)record[SCDaemonScheduleWeekKey] length] != 10 ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonScheduleCommitmentIDKey]) ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonScheduleGenerationKey]) ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonSchedulePolicyRevisionKey]) ||
        !SCDaemonSchedulerStringArray(record[SCDaemonScheduleSourceBundleIDsKey], YES)) return NO;
    return YES;
}

static BOOL SCDaemonSchedulerRecurringSegmentIsValid(NSDictionary<NSString *, id> *segment) {
    if (![segment isKindOfClass:[NSDictionary class]] ||
        !SCDaemonSchedulerUUIDString(segment[@"segmentID"]) ||
        !SCDaemonSchedulerIntegerInRange(segment[@"startMinuteOfWeek"], 0, 10079) ||
        !SCDaemonSchedulerIntegerInRange(segment[@"endMinuteOfWeek"], 1, 10080) ||
        [segment[@"endMinuteOfWeek"] integerValue] <= [segment[@"startMinuteOfWeek"] integerValue] ||
        !SCDaemonSchedulerStringArray(segment[@"blocklist"], NO) ||
        [segment[@"blocklist"] count] == 0 ||
        !SCDaemonSchedulerStringArray(segment[SCDaemonScheduleSourceBundleIDsKey], YES) ||
        [segment[SCDaemonScheduleSourceBundleIDsKey] count] == 0 ||
        !SCDaemonSchedulerUUIDString(segment[SCDaemonSchedulePolicyRevisionKey])) return NO;
    id allowlist = segment[@"isAllowlist"];
    return [allowlist isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)allowlist) == CFBooleanGetTypeID() && ![allowlist boolValue];
}

static BOOL SCDaemonSchedulerRecurringCommitmentIsValid(NSString *commitmentID,
                                                         NSDictionary<NSString *, id> *commitment,
                                                         uid_t ownerUID) {
    NSNumber *owner = [commitment[@"controllingUID"] isKindOfClass:[NSNumber class]]
        ? commitment[@"controllingUID"] : nil;
    NSDate *startedAt = [commitment[@"startedAt"] isKindOfClass:[NSDate class]]
        ? commitment[@"startedAt"] : nil;
    NSDate *lockEndsAt = [commitment[@"lockEndsAt"] isKindOfClass:[NSDate class]]
        ? commitment[@"lockEndsAt"] : nil;
    NSArray *segments = [commitment[@"segments"] isKindOfClass:[NSArray class]]
        ? commitment[@"segments"] : nil;
    id timeZoneIdentifier = commitment[SCDaemonRecurringTimeZoneIdentifierKey];
    id followsLocation = commitment[SCDaemonRecurringFollowsLocationTimeZoneKey];
    BOOL hasTimeZone = timeZoneIdentifier != nil;
    BOOL hasLocationMode = followsLocation != nil;
    if (!SCDaemonSchedulerUUIDString(commitmentID) ||
        ![commitment[@"commitmentID"] isEqual:commitmentID] ||
        !SCDaemonSchedulerUUIDString(commitment[@"generation"]) ||
        !SCDaemonSchedulerIntegerInRange(commitment[@"schemaVersion"], 1, 1) ||
        owner == nil || owner.longLongValue <= 0 ||
        (ownerUID != 0 && owner.unsignedIntValue != ownerUID) ||
        startedAt == nil || lockEndsAt == nil || [lockEndsAt compare:startedAt] != NSOrderedDescending ||
        !SCDaemonSchedulerProtectedHoursAreValid(commitment[@"protectedHours"]) ||
        ![commitment[@"blockSettings"] isKindOfClass:[NSDictionary class]] ||
        segments == nil || segments.count == 0 || segments.count > 512) return NO;
    // Both fields are absent only for a shipped legacy record waiting for the
    // startup pinning migration. Partial or malformed extensions are unsafe.
    if (hasTimeZone != hasLocationMode ||
        (hasTimeZone && (SCDaemonSchedulerTimeZoneFromIdentifier(timeZoneIdentifier) == nil ||
                         !SCDaemonSchedulerBoolean(followsLocation)))) return NO;

    NSMutableSet<NSString *> *segmentIDs = [NSMutableSet set];
    NSInteger previousEnd = 0;
    BOOL first = YES;
    for (id value in segments) {
        NSDictionary *segment = [value isKindOfClass:[NSDictionary class]] ? value : nil;
        if (!SCDaemonSchedulerRecurringSegmentIsValid(segment) ||
            [segmentIDs containsObject:segment[@"segmentID"]]) return NO;
        NSInteger start = [segment[@"startMinuteOfWeek"] integerValue];
        if (!first && start < previousEnd) return NO;
        first = NO;
        previousEnd = [segment[@"endMinuteOfWeek"] integerValue];
        [segmentIDs addObject:segment[@"segmentID"]];
    }
    return YES;
}

@interface SCDaemonScheduler ()
@property (nonatomic, copy) SCDaemonSchedulerStateProvider stateProvider;
@property (nonatomic, copy) SCDaemonSchedulerReconcileHandler reconcileHandler;
@property (nonatomic, copy) SCDaemonSchedulerEndHandler endHandler;
@property (nonatomic, copy, nullable) SCDaemonSchedulerAnomalyHandler anomalyHandler;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, nullable) dispatch_source_t boundaryTimer;
@property (nonatomic, nullable) dispatch_source_t backstopTimer;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL evaluationInFlight;
@property (nonatomic) BOOL evaluationPending;
@property (nonatomic, copy) NSString *pendingTrigger;
@property (nonatomic) NSMutableArray *currentCompletions;
@property (nonatomic) NSMutableArray *pendingCompletions;
- (void)armBoundaryAfterDate:(NSDate *)now
                      records:(NSArray<NSDictionary<NSString *, id> *> *)records
                        state:(NSDictionary<NSString *, id> *)state
                   commitment:(nullable NSDictionary<NSString *, id> *)commitment
                  activeBreak:(nullable NSDictionary<NSString *, id> *)activeBreak
                     calendar:(NSCalendar *)calendar;
@end

@implementation SCDaemonScheduler

+ (NSArray<NSDictionary<NSString *,id> *> *)validScheduleRecordsFromApprovedSchedules:(id)approvedSchedules
                                                                               ownerUID:(uid_t)ownerUID {
    if (![approvedSchedules isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *records = [NSMutableArray array];
    [(NSDictionary *)approvedSchedules enumerateKeysAndObjectsUsingBlock:^(id scheduleID, id value, BOOL *stop) {
        if (![scheduleID isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *record = (NSDictionary *)value;
        if (!SCDaemonSchedulerRecordIsValid(scheduleID, record, ownerUID)) return;
        NSMutableDictionary *recordWithID = [record mutableCopy];
        recordWithID[SCDaemonSchedulerRecordIDKey] = scheduleID;
        [records addObject:[recordWithID copy]];
    }];
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult startOrder = [left[SCDaemonSchedulerStartKey] compare:right[SCDaemonSchedulerStartKey]];
        if (startOrder != NSOrderedSame) return startOrder;
        return [left[SCDaemonSchedulerRecordIDKey] compare:right[SCDaemonSchedulerRecordIDKey]];
    }];
    return records;
}

+ (NSArray<NSDictionary<NSString *,id> *> *)validRecurringCommitmentsFromValue:(id)value
                                                                        ownerUID:(uid_t)ownerUID {
    if (![value isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *commitments = [NSMutableArray array];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id candidate, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![candidate isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *commitment = candidate;
        if (!SCDaemonSchedulerRecurringCommitmentIsValid(key, commitment, ownerUID)) return;
        [commitments addObject:commitment];
    }];
    [commitments sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"commitmentID"] compare:right[@"commitmentID"]];
    }];
    return commitments;
}

+ (NSCalendar *)calendarForRecurringCommitment:(NSDictionary<NSString *,id> *)commitment
                              fallbackTimeZone:(NSTimeZone *)fallbackTimeZone {
    NSTimeZone *timeZone = SCDaemonSchedulerTimeZoneFromIdentifier(
        commitment[SCDaemonRecurringTimeZoneIdentifierKey]) ?: fallbackTimeZone;
    NSCalendar *calendar = [[NSCalendar alloc]
        initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    calendar.timeZone = timeZone ?: NSTimeZone.localTimeZone;
    calendar.firstWeekday = 2;
    return calendar;
}

+ (NSArray<NSDictionary<NSString *,id> *> *)recurringOccurrenceRecordsAtDate:(NSDate *)now
                                                                    commitments:(NSArray<NSDictionary<NSString *,id> *> *)commitments
                                                                        calendar:(NSCalendar *)calendar {
    if (![now isKindOfClass:[NSDate class]] || ![calendar isKindOfClass:[NSCalendar class]]) return @[];
    NSDate *currentWeek = SCDaemonSchedulerStartOfMondayWeek(now, calendar);
    if (currentWeek == nil) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *records = [NSMutableArray array];
    for (NSDictionary *commitment in commitments) {
        NSArray *segments = commitment[@"segments"];
        for (NSInteger weekOffset = -1; weekOffset <= 1; weekOffset++) {
            NSDate *weekStart = [calendar dateByAddingUnit:NSCalendarUnitDay
                                                     value:weekOffset * 7
                                                    toDate:currentWeek
                                                   options:0];
            NSString *weekKey = SCDaemonSchedulerWeekKey(weekStart, calendar);
            for (NSDictionary *segment in segments) {
                NSDate *start = SCDaemonSchedulerDateForMinuteOfWeek(
                    [segment[@"startMinuteOfWeek"] integerValue], weekStart, calendar);
                NSDate *end = SCDaemonSchedulerDateForMinuteOfWeek(
                    [segment[@"endMinuteOfWeek"] integerValue], weekStart, calendar);
                if (start == nil || end == nil || [end compare:start] != NSOrderedDescending) continue;
                [records addObject:@{
                    SCDaemonSchedulerRecordIDKey: segment[@"segmentID"],
                    SCDaemonScheduleSchemaVersionKey: @3,
                    SCDaemonScheduleWeekKey: weekKey,
                    SCDaemonScheduleCommitmentIDKey: commitment[@"commitmentID"],
                    SCDaemonScheduleGenerationKey: commitment[@"generation"],
                    SCDaemonSchedulePolicyRevisionKey: segment[SCDaemonSchedulePolicyRevisionKey],
                    SCDaemonScheduleSourceBundleIDsKey: segment[SCDaemonScheduleSourceBundleIDsKey],
                    SCDaemonSchedulerBlocklistKey: segment[@"blocklist"],
                    @"isAllowlist": segment[@"isAllowlist"],
                    SCDaemonSchedulerBlockSettingsKey: commitment[@"blockSettings"],
                    SCDaemonSchedulerOwnerKey: commitment[@"controllingUID"],
                    SCDaemonSchedulerStartKey: start,
                    SCDaemonSchedulerEndKey: end,
                    SCDaemonSchedulerRecurringMarkerKey: @YES,
                }];
            }
        }
    }
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult startOrder = [left[SCDaemonSchedulerStartKey] compare:right[SCDaemonSchedulerStartKey]];
        if (startOrder != NSOrderedSame) return startOrder;
        return [left[SCDaemonSchedulerRecordIDKey] compare:right[SCDaemonSchedulerRecordIDKey]];
    }];
    return records;
}

+ (BOOL)protectedHoursAreActiveAtDate:(NSDate *)date
                            commitment:(NSDictionary<NSString *,id> *)commitment
                               calendar:(NSCalendar *)calendar {
    NSDictionary *hours = commitment[@"protectedHours"];
    if (![date isKindOfClass:[NSDate class]] || ![calendar isKindOfClass:[NSCalendar class]] ||
        !SCDaemonSchedulerProtectedHoursAreValid(hours) || ![hours[@"enabled"] boolValue]) return NO;
    NSDateComponents *components = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                                fromDate:date];
    NSInteger minute = components.hour * 60 + components.minute;
    NSInteger start = [hours[@"startMinute"] integerValue];
    NSInteger end = [hours[@"endMinute"] integerValue];
    return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end);
}

+ (BOOL)protectedHoursEditLockIsActiveAtDate:(NSDate *)date
                                     commitment:(NSDictionary<NSString *,id> *)commitment
                                        calendar:(NSCalendar *)calendar {
    NSDictionary *hours = commitment[@"protectedHours"];
    if (![date isKindOfClass:[NSDate class]] || ![calendar isKindOfClass:[NSCalendar class]] ||
        !SCDaemonSchedulerProtectedHoursAreValid(hours) || ![hours[@"enabled"] boolValue]) return NO;
    NSInteger start = [hours[@"startMinute"] integerValue];
    NSInteger end = [hours[@"endMinute"] integerValue];
    NSInteger protectedDuration = start < end ? end - start : 24 * 60 - start + end;
    if (protectedDuration + 120 >= 24 * 60) return YES;

    NSDateComponents *components = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                                fromDate:date];
    NSInteger minute = components.hour * 60 + components.minute;
    NSInteger lockStart = (start - 120 + 24 * 60) % (24 * 60);
    return lockStart < end ? (minute >= lockStart && minute < end)
                           : (minute >= lockStart || minute < end);
}

+ (NSDate *)nextProtectedHoursBoundaryAfterDate:(NSDate *)date
                                      commitment:(NSDictionary<NSString *,id> *)commitment
                                         calendar:(NSCalendar *)calendar {
    NSDictionary *hours = commitment[@"protectedHours"];
    if (![date isKindOfClass:[NSDate class]] || ![calendar isKindOfClass:[NSCalendar class]] ||
        !SCDaemonSchedulerProtectedHoursAreValid(hours) || ![hours[@"enabled"] boolValue]) return nil;
    NSDate *startOfDay = [calendar startOfDayForDate:date];
    NSDate *next = nil;
    for (NSInteger dayOffset = 0; dayOffset <= 1; dayOffset++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:dayOffset toDate:startOfDay options:0];
        for (NSString *key in @[@"startMinute", @"endMinute"]) {
            NSInteger minute = [hours[key] integerValue];
            NSDate *candidate = [calendar dateBySettingHour:minute / 60
                                                     minute:minute % 60
                                                     second:0
                                                     ofDate:day
                                                    options:NSCalendarMatchNextTimePreservingSmallerUnits];
            if (candidate == nil || [candidate compare:date] != NSOrderedDescending) continue;
            if (next == nil || [candidate compare:next] == NSOrderedAscending) next = candidate;
        }
    }
    return next;
}

+ (NSDictionary<NSString *,id> *)activeBreakAtDate:(NSDate *)date
                                               value:(id)value
                                            ownerUID:(uid_t)ownerUID
                                          commitment:(NSDictionary<NSString *,id> *)commitment {
    if (![date isKindOfClass:[NSDate class]] || ![value isKindOfClass:[NSDictionary class]] ||
        ![commitment isKindOfClass:[NSDictionary class]]) return nil;
    NSString *commitmentID = commitment[@"commitmentID"];
    NSDictionary *activeBreak = [(NSDictionary *)value objectForKey:commitmentID];
    if (![activeBreak isKindOfClass:[NSDictionary class]] ||
        ![activeBreak[@"commitmentID"] isEqual:commitmentID] ||
        ![activeBreak[@"generation"] isEqual:commitment[@"generation"]] ||
        [activeBreak[@"controllingUID"] unsignedIntValue] != ownerUID ||
        !SCDaemonSchedulerIntegerInRange(activeBreak[@"schemaVersion"], 1, 1) ||
        ![activeBreak[@"startedAt"] isKindOfClass:[NSDate class]] ||
        ![activeBreak[@"endsAt"] isKindOfClass:[NSDate class]] ||
        [activeBreak[@"endsAt"] compare:activeBreak[@"startedAt"]] != NSOrderedDescending ||
        [activeBreak[@"endsAt"] compare:date] != NSOrderedDescending) return nil;
    return activeBreak;
}

+ (NSDictionary<NSString *,id> *)desiredScheduleRecordAtDate:(NSDate *)now
                                                       records:(NSArray<NSDictionary<NSString *,id> *> *)records {
    if (![now isKindOfClass:[NSDate class]]) return nil;
    NSDictionary *desired = nil;
    for (NSDictionary *record in records) {
        NSDate *start = record[SCDaemonSchedulerStartKey];
        NSDate *end = record[SCDaemonSchedulerEndKey];
        if (![start isKindOfClass:[NSDate class]] || ![end isKindOfClass:[NSDate class]] ||
            [start compare:now] == NSOrderedDescending || [end compare:now] != NSOrderedDescending) continue;
        if (desired == nil || [start compare:desired[SCDaemonSchedulerStartKey]] == NSOrderedDescending ||
            ([start isEqualToDate:desired[SCDaemonSchedulerStartKey]] &&
             [record[SCDaemonSchedulerRecordIDKey] compare:desired[SCDaemonSchedulerRecordIDKey]] == NSOrderedAscending)) {
            desired = record;
        }
    }
    return desired;
}

+ (NSDate *)nextBoundaryAfterDate:(NSDate *)now
                           records:(NSArray<NSDictionary<NSString *,id> *> *)records {
    if (![now isKindOfClass:[NSDate class]]) return nil;
    NSDate *next = nil;
    for (NSDictionary *record in records) {
        for (NSString *key in @[SCDaemonSchedulerStartKey, SCDaemonSchedulerEndKey]) {
            NSDate *candidate = [record[key] isKindOfClass:[NSDate class]] ? record[key] : nil;
            if (candidate == nil || [candidate compare:now] != NSOrderedDescending) continue;
            if (next == nil || [candidate compare:next] == NSOrderedAscending) next = candidate;
        }
    }
    return next;
}

+ (BOOL)activeState:(NSDictionary<NSString *,id> *)state
       matchesRecord:(NSDictionary<NSString *,id> *)record {
    if (![state[@"block_running"] boolValue]) return NO;
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : nil;
    NSInteger schemaVersion = [record[SCDaemonScheduleSchemaVersionKey] integerValue];
    BOOL sourceMatches = schemaVersion >= 3
        ? [source isEqualToString:SCDaemonActiveBlockSourceSchedulerRecurring]
        : ([source isEqualToString:SCDaemonActiveBlockSourceLegacySchedule] ||
           [source isEqualToString:SCDaemonActiveBlockSourceSchedulerV2]);
    if (!sourceMatches) return NO;
    NSNumber *activeOwner = [state[@"active_owner_uid"] isKindOfClass:[NSNumber class]]
        ? state[@"active_owner_uid"] : nil;
    NSNumber *recordOwner = [record[SCDaemonSchedulerOwnerKey] isKindOfClass:[NSNumber class]]
        ? record[SCDaemonSchedulerOwnerKey] : nil;
    if (activeOwner.unsignedIntValue != 0 && recordOwner.unsignedIntValue != 0 &&
        activeOwner.unsignedIntValue != recordOwner.unsignedIntValue) return NO;
    if (![state[@"active_schedule_id"] isEqual:record[SCDaemonSchedulerRecordIDKey]]) return NO;
    NSString *recordRevision = record[SCDaemonSchedulePolicyRevisionKey];
    if (recordRevision != nil && ![state[@"active_policy_revision"] isEqual:recordRevision]) return NO;
    if (schemaVersion >= 2 &&
        (![state[@"active_commitment_id"] isEqual:record[SCDaemonScheduleCommitmentIDKey]] ||
         ![state[@"active_generation"] isEqual:record[SCDaemonScheduleGenerationKey]])) return NO;
    if (schemaVersion >= 3 && ![state[@"block_end_date"] isEqual:record[SCDaemonSchedulerEndKey]]) return NO;

    BOOL recordIsAllowlist = [record[@"isAllowlist"] boolValue];
    if ([state[@"active_is_allowlist"] boolValue] != recordIsAllowlist) return NO;
    NSArray *activeBlocklist = [state[@"active_blocklist"] isKindOfClass:[NSArray class]]
        ? state[@"active_blocklist"] : nil;
    NSArray *recordBlocklist = [record[SCDaemonSchedulerBlocklistKey] isKindOfClass:[NSArray class]]
        ? record[SCDaemonSchedulerBlocklistKey] : nil;
    if (activeBlocklist == nil || recordBlocklist == nil ||
        !SCDaemonSchedulerStringArray(activeBlocklist, NO) ||
        !SCDaemonSchedulerStringArray(recordBlocklist, NO)) return NO;
    NSSet *activeEntries = [NSSet setWithArray:activeBlocklist];
    NSSet *recordEntries = [NSSet setWithArray:recordBlocklist];
    if (recordIsAllowlist) {
        if (![activeEntries isEqualToSet:recordEntries]) return NO;
    } else if (![recordEntries isSubsetOfSet:activeEntries]) {
        // A stricter active denylist is safe (for example if physical apply
        // succeeded before a root-store retry). A weaker one never matches.
        return NO;
    }
    return YES;
}

- (instancetype)initWithStateProvider:(SCDaemonSchedulerStateProvider)stateProvider
                      reconcileHandler:(SCDaemonSchedulerReconcileHandler)reconcileHandler
                            endHandler:(SCDaemonSchedulerEndHandler)endHandler
                         anomalyHandler:(SCDaemonSchedulerAnomalyHandler)anomalyHandler {
    self = [super init];
    if (self) {
        _stateProvider = [stateProvider copy];
        _reconcileHandler = [reconcileHandler copy];
        _endHandler = [endHandler copy];
        _anomalyHandler = [anomalyHandler copy];
        _queue = dispatch_queue_create("org.eyebeam.Fence.daemon-scheduler", DISPATCH_QUEUE_SERIAL);
        _pendingTrigger = @"periodic";
        _currentCompletions = [NSMutableArray array];
        _pendingCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.started) return;
        self.started = YES;
        self.backstopTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.backstopTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                                  60 * NSEC_PER_SEC,
                                  10 * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.backstopTimer, ^{
            [weakSelf evaluateForTrigger:@"periodic"];
        });
        dispatch_resume(self.backstopTimer);
        [self enqueueEvaluationForTrigger:@"startup" completion:nil];
    });
}

- (void)stop {
    dispatch_sync(self.queue, ^{
        self.started = NO;
        if (self.boundaryTimer != nil) {
            dispatch_source_cancel(self.boundaryTimer);
            self.boundaryTimer = nil;
        }
        if (self.backstopTimer != nil) {
            dispatch_source_cancel(self.backstopTimer);
            self.backstopTimer = nil;
        }
        [self.currentCompletions removeAllObjects];
        [self.pendingCompletions removeAllObjects];
    });
}

- (void)evaluateForTrigger:(NSString *)trigger {
    [self evaluateForTrigger:trigger completion:nil];
}

- (void)evaluateForTrigger:(NSString *)trigger
                 completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    dispatch_async(self.queue, ^{
        [self enqueueEvaluationForTrigger:trigger completion:completion];
    });
}

- (void)enqueueEvaluationForTrigger:(NSString *)trigger
                          completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    self.pendingTrigger = [self safeTrigger:trigger];
    if (self.evaluationInFlight) {
        if (completion != nil) [self.pendingCompletions addObject:[completion copy]];
        self.evaluationPending = YES;
        return;
    }
    if (completion != nil) [self.currentCompletions addObject:[completion copy]];
    [self performEvaluationForTrigger:self.pendingTrigger];
}

- (NSString *)safeTrigger:(NSString *)trigger {
    static NSSet<NSString *> *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[@"startup", @"timer", @"wake", @"clock_change",
                                               @"session_change", @"mutation", @"periodic", @"legacy"]];
    });
    return [allowed containsObject:trigger] ? trigger : @"periodic";
}

- (void)performEvaluationForTrigger:(NSString *)trigger {
    self.evaluationInFlight = YES;
    NSDictionary *state = self.stateProvider ? self.stateProvider() : @{};
    BOOL settingsAvailable = [state[@"settings_available"] boolValue];
    if (!settingsAvailable) {
        [self finishEvaluation:@{@"status": @"failed", @"stage": @"load", @"trigger": trigger}];
        [self emitAnomalyForTrigger:trigger transition:@"idle_idle" stage:@"load"
                            outcome:@"failed" state:state record:nil error:nil];
        return;
    }

    BOOL blockRunning = [state[@"block_running"] boolValue];
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : @"unknown";
    BOOL schedulerOwnsActive = [source isEqualToString:SCDaemonActiveBlockSourceLegacySchedule] ||
        [source isEqualToString:SCDaemonActiveBlockSourceSchedulerV2] ||
        [source isEqualToString:SCDaemonActiveBlockSourceSchedulerRecurring];
    uid_t consoleUID = [state[@"console_uid"] unsignedIntValue];
    uid_t activeOwnerUID = [state[@"active_owner_uid"] unsignedIntValue];
    // A fast-user switch must never make another console user's empty desired
    // set tear down a still-valid scheduled block. Finish the active owner's
    // policy first; once it ends, a fresh evaluation selects the console user.
    uid_t selectedOwner = blockRunning && schedulerOwnsActive && activeOwnerUID != 0
        ? activeOwnerUID : (consoleUID != 0 ? consoleUID : activeOwnerUID);
    NSDate *now = [state[@"now"] isKindOfClass:[NSDate class]] ? state[@"now"] : [NSDate date];
    NSArray *absoluteRecords = [SCDaemonScheduler
        validScheduleRecordsFromApprovedSchedules:state[@"approved_schedules"]
                                           ownerUID:selectedOwner];
    NSArray *recurringCommitments = [SCDaemonScheduler
        validRecurringCommitmentsFromValue:state[@"approved_recurring_commitments"]
                                  ownerUID:selectedOwner];
    NSDictionary *recurringCommitment = recurringCommitments.firstObject;
    NSCalendar *calendar = [SCDaemonScheduler calendarForRecurringCommitment:recurringCommitment
                                                            fallbackTimeZone:NSTimeZone.localTimeZone];
    NSArray *recurringRecords = [SCDaemonScheduler recurringOccurrenceRecordsAtDate:now
                                                                         commitments:recurringCommitments
                                                                             calendar:calendar];
    NSMutableArray *allRecords = [absoluteRecords mutableCopy];
    [allRecords addObjectsFromArray:recurringRecords];
    NSDictionary *activeBreak = [SCDaemonScheduler activeBreakAtDate:now
                                                               value:state[@"active_schedule_breaks"]
                                                            ownerUID:selectedOwner
                                                          commitment:recurringCommitment];
    BOOL protectedHoursActive = recurringCommitment != nil &&
        [SCDaemonScheduler protectedHoursAreActiveAtDate:now
                                               commitment:recurringCommitment
                                                  calendar:calendar];
    NSArray *effectiveRecords = allRecords;
    if (activeBreak != nil && !protectedHoursActive) {
        NSPredicate *notRecurring = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *record,
                                                                          NSDictionary *bindings) {
            return ![record[SCDaemonSchedulerRecurringMarkerKey] boolValue];
        }];
        effectiveRecords = [allRecords filteredArrayUsingPredicate:notRecurring];
    }
    NSDictionary *desired = [SCDaemonScheduler desiredScheduleRecordAtDate:now records:effectiveRecords];
    BOOL activeMatches = desired != nil && [SCDaemonScheduler activeState:state matchesRecord:desired];

    [self armBoundaryAfterDate:now
                       records:allRecords
                         state:state
                    commitment:recurringCommitment
                   activeBreak:activeBreak
                      calendar:calendar];
    if (activeMatches || (!blockRunning && desired == nil)) {
        [self finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
        return;
    }

    if (blockRunning && !schedulerOwnsActive) {
        [self finishEvaluation:@{@"status": @"deferred", @"stage": @"select", @"trigger": trigger}];
        return;
    }

    NSString *transition = !blockRunning ? @"idle_active" : (desired == nil ? @"active_idle" : @"active_active");
    // A policy replacement needs a staged PF/hosts/AppBlocker primitive. Keep
    // the currently enforced schedule until its approved end instead of
    // weakening enforcement with remove-then-add during a V2 mutation.
    if (blockRunning && schedulerOwnsActive && desired != nil) {
        [self finishEvaluation:@{@"status": @"deferred", @"stage": @"select", @"trigger": trigger}];
        return;
    }

    if (blockRunning && schedulerOwnsActive) {
        __weak typeof(self) weakSelf = self;
        self.endHandler(^(NSError *error) {
            dispatch_async(weakSelf.queue, ^{
                if (error != nil) {
                    [weakSelf emitAnomalyForTrigger:trigger transition:transition stage:@"teardown"
                                           outcome:@"failed" state:state record:desired error:error];
                    [weakSelf finishEvaluation:@{@"status": @"failed", @"stage": @"teardown", @"trigger": trigger}];
                    return;
                }
                if (desired == nil) {
                    if (consoleUID != 0 && consoleUID != selectedOwner) {
                        // The previous evaluation deliberately finished the
                        // old active owner's schedule after a fast-user
                        // switch. Immediately run once more for the current
                        // console user rather than waiting for the backstop.
                        weakSelf.evaluationPending = YES;
                        weakSelf.pendingTrigger = @"session_change";
                    }
                    [weakSelf finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
                    return;
                }
                [weakSelf reconcileRecord:desired trigger:trigger transition:transition state:state];
            });
        });
        return;
    }

    [self reconcileRecord:desired trigger:trigger transition:transition state:state];
}

- (void)reconcileRecord:(NSDictionary<NSString *, id> *)record
                 trigger:(NSString *)trigger
              transition:(NSString *)transition
                   state:(NSDictionary<NSString *, id> *)state {
    NSString *scheduleID = record[SCDaemonSchedulerRecordIDKey];
    __weak typeof(self) weakSelf = self;
    self.reconcileHandler(scheduleID, record, ^(NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            if (error != nil) {
                [weakSelf emitAnomalyForTrigger:trigger transition:transition stage:@"apply"
                                       outcome:@"failed" state:state record:record error:error];
                [weakSelf finishEvaluation:@{@"status": @"failed", @"stage": @"apply", @"trigger": trigger}];
                return;
            }
            [weakSelf finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
        });
    });
}

- (void)armBoundaryAfterDate:(NSDate *)now
                      records:(NSArray<NSDictionary<NSString *, id> *> *)records
                        state:(NSDictionary<NSString *, id> *)state
                   commitment:(NSDictionary<NSString *, id> *)commitment
                  activeBreak:(NSDictionary<NSString *, id> *)activeBreak
                     calendar:(NSCalendar *)calendar {
    NSDate *next = [SCDaemonScheduler nextBoundaryAfterDate:now records:records];
    NSDate *activeEnd = [state[@"block_end_date"] isKindOfClass:[NSDate class]] ? state[@"block_end_date"] : nil;
    if (activeEnd != nil && [activeEnd compare:now] == NSOrderedDescending &&
        (next == nil || [activeEnd compare:next] == NSOrderedAscending)) next = activeEnd;
    NSDate *breakEnd = [activeBreak[@"endsAt"] isKindOfClass:[NSDate class]] ? activeBreak[@"endsAt"] : nil;
    if (breakEnd != nil && [breakEnd compare:now] == NSOrderedDescending &&
        (next == nil || [breakEnd compare:next] == NSOrderedAscending)) next = breakEnd;
    NSDate *protectedBoundary = [SCDaemonScheduler nextProtectedHoursBoundaryAfterDate:now
                                                                            commitment:commitment
                                                                               calendar:calendar];
    if (protectedBoundary != nil &&
        (next == nil || [protectedBoundary compare:next] == NSOrderedAscending)) next = protectedBoundary;

    if (self.boundaryTimer != nil) {
        dispatch_source_cancel(self.boundaryTimer);
        self.boundaryTimer = nil;
    }
    if (next == nil || !self.started) return;

    NSTimeInterval interval = next.timeIntervalSince1970;
    struct timespec wallTime = {
        .tv_sec = (time_t)floor(interval),
        .tv_nsec = (long)((interval - floor(interval)) * NSEC_PER_SEC),
    };
    self.boundaryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.boundaryTimer, dispatch_walltime(&wallTime, 0), DISPATCH_TIME_FOREVER,
                              1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.boundaryTimer, ^{
        weakSelf.boundaryTimer = nil;
        [weakSelf enqueueEvaluationForTrigger:@"timer" completion:nil];
    });
    dispatch_resume(self.boundaryTimer);
}

- (void)emitAnomalyForTrigger:(NSString *)trigger
                    transition:(NSString *)transition
                         stage:(NSString *)stage
                       outcome:(NSString *)outcome
                         state:(NSDictionary<NSString *, id> *)state
                        record:(NSDictionary<NSString *, id> *)record
                         error:(NSError *)error {
    if (self.anomalyHandler == nil) return;
    NSDate *now = [state[@"now"] isKindOfClass:[NSDate class]] ? state[@"now"] : [NSDate date];
    NSDate *start = [record[SCDaemonSchedulerStartKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerStartKey] : nil;
    NSUInteger minutesLate = start == nil ? 0 : (NSUInteger)floor(MAX(0, [now timeIntervalSinceDate:start]) / 60.0);
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : @"unknown";
    uid_t consoleUID = [state[@"console_uid"] unsignedIntValue];
    uid_t activeOwnerUID = [state[@"active_owner_uid"] unsignedIntValue];
    uid_t selectedOwner = consoleUID != 0 ? consoleUID : activeOwnerUID;
    NSUInteger ownedRecordCount = [[SCDaemonScheduler
        validScheduleRecordsFromApprovedSchedules:state[@"approved_schedules"]
                                           ownerUID:selectedOwner] count];
    self.anomalyHandler(@{
        @"trigger": trigger,
        @"transition": transition,
        @"stage": stage,
        @"outcome": outcome,
        @"applied_source": source,
        @"block_running": @([state[@"block_running"] boolValue]),
        @"stored_segment_count": @(ownedRecordCount),
        @"minutes_late_bucket": @(MIN(minutesLate, (NSUInteger)1440)),
        @"error_code": @(error != nil ? error.code : 0),
    });
}

- (void)finishEvaluation:(NSDictionary<NSString *, id> *)result {
    NSArray *completions = [self.currentCompletions copy];
    [self.currentCompletions removeAllObjects];
    self.evaluationInFlight = NO;
    for (void (^completion)(NSDictionary *) in completions) completion(result);
    if (self.evaluationPending) {
        self.evaluationPending = NO;
        [self.currentCompletions addObjectsFromArray:self.pendingCompletions];
        [self.pendingCompletions removeAllObjects];
        [self performEvaluationForTrigger:self.pendingTrigger];
    }
}

- (void)dealloc {
    if (_boundaryTimer != nil) dispatch_source_cancel(_boundaryTimer);
    if (_backstopTimer != nil) dispatch_source_cancel(_backstopTimer);
}

@end

//
//  SCWeeklySchedule.m
//  SelfControl
//

#import "SCWeeklySchedule.h"

static BOOL SCActiveEditTimeIsCanonical(NSString *time) {
    if (![time isKindOfClass:NSString.class] || time.length != 5 || [time characterAtIndex:2] != ':') return NO;
    for (NSNumber *index in @[@0, @1, @3, @4]) {
        unichar character = [time characterAtIndex:index.unsignedIntegerValue];
        if (character < '0' || character > '9') return NO;
    }
    NSInteger hour = [[time substringToIndex:2] integerValue];
    NSInteger minute = [[time substringFromIndex:3] integerValue];
    return hour <= 24 && minute < 60 && (hour < 24 || minute == 0);
}

static BOOL SCActiveEditRangeFitsOriginal(SCTimeRange *range, SCTimeRange *original) {
    if (![range isKindOfClass:SCTimeRange.class] || ![original isKindOfClass:SCTimeRange.class] ||
        !SCActiveEditTimeIsCanonical(range.startTime) || !SCActiveEditTimeIsCanonical(range.endTime) ||
        !SCActiveEditTimeIsCanonical(original.startTime) || !SCActiveEditTimeIsCanonical(original.endTime) ||
        !range.isValid || !original.isValid || range.durationMinutes <= 0) return NO;
    BOOL unchanged = [range.startTime isEqualToString:original.startTime] && [range.endTime isEqualToString:original.endTime];
    return (unchanged || range.durationMinutes >= 15) &&
        range.startMinutes >= original.startMinutes && range.endMinutes <= original.endMinutes;
}

// An augmenting-path match handles overlapping legacy originals without
// accepting two new entries derived from the same original.
static BOOL SCMatchActiveEditWindow(NSUInteger proposedIndex,
                                    NSArray<SCTimeRange *> *proposed,
                                    NSArray<SCTimeRange *> *originals,
                                    NSMutableArray<NSNumber *> *owners,
                                    NSMutableIndexSet *visited) {
    SCTimeRange *range = proposed[proposedIndex];
    for (NSUInteger pass = 0; pass < 2; pass++) {
        for (NSUInteger index = 0; index < originals.count; index++) {
            SCTimeRange *original = originals[index];
            BOOL equal = [range.startTime isEqualToString:original.startTime] && [range.endTime isEqualToString:original.endTime];
            if ((pass == 0) != equal || [visited containsIndex:index] || !SCActiveEditRangeFitsOriginal(range, original)) continue;
            [visited addIndex:index];
            NSInteger previous = owners[index].integerValue;
            if (previous < 0 || SCMatchActiveEditWindow((NSUInteger)previous, proposed, originals, owners, visited)) {
                owners[index] = @(proposedIndex);
                return YES;
            }
        }
    }
    return NO;
}

@implementation SCWeeklySchedule

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bundleID = @"";
        _daySchedules = [NSMutableDictionary dictionary];

        // Initialize empty arrays for each day (blocked all day)
        for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
            NSString *key = [SCWeeklySchedule stringForDay:day];
            _daySchedules[key] = [NSMutableArray array];
        }
    }
    return self;
}

+ (instancetype)emptyScheduleForBundleID:(NSString *)bundleID {
    SCWeeklySchedule *schedule = [[SCWeeklySchedule alloc] init];
    schedule.bundleID = bundleID;
    return schedule;
}

+ (nullable instancetype)scheduleFromDictionary:(NSDictionary *)dict {
    if (!dict[@"bundleID"]) {
        return nil;
    }

    SCWeeklySchedule *schedule = [[SCWeeklySchedule alloc] init];
    schedule.bundleID = dict[@"bundleID"];

    // Parse day schedules
    NSDictionary *days = dict[@"daySchedules"];
    if ([days isKindOfClass:[NSDictionary class]]) {
        for (NSString *dayKey in days) {
            NSArray *windowDicts = days[dayKey];
            if ([windowDicts isKindOfClass:[NSArray class]]) {
                NSMutableArray *windows = [NSMutableArray array];
                for (NSDictionary *windowDict in windowDicts) {
                    SCTimeRange *range = [SCTimeRange rangeFromDictionary:windowDict];
                    if (range) {
                        [windows addObject:range];
                    }
                }
                schedule.daySchedules[dayKey] = windows;
            }
        }
    }

    return schedule;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dayDicts = [NSMutableDictionary dictionary];

    for (NSString *dayKey in self.daySchedules) {
        NSMutableArray *windowDicts = [NSMutableArray array];
        for (SCTimeRange *range in self.daySchedules[dayKey]) {
            [windowDicts addObject:[range toDictionary]];
        }
        dayDicts[dayKey] = windowDicts;
    }

    return @{
        @"bundleID": self.bundleID ?: @"",
        @"daySchedules": dayDicts
    };
}

#pragma mark - Day Access

- (BOOL)isValidActiveEditOfSchedule:(SCWeeklySchedule *)baselineSchedule policy:(SCBundlePolicy)policy {
    if (policy == SCBundlePolicyAllow) return [self isValidActiveEditOfSchedule:baselineSchedule];
    if (baselineSchedule == nil || ![self.bundleID isEqual:baselineSchedule.bundleID]) return NO;
    for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
        for (NSInteger minute = 0; minute < 1440; minute++) {
            BOOL wasBlocked = NO, isBlocked = NO;
            for (SCTimeRange *window in [baselineSchedule allowedWindowsForDay:day]) {
                if (window.startMinutes <= minute && minute < window.endMinutes) wasBlocked = YES;
            }
            for (SCTimeRange *window in [self allowedWindowsForDay:day]) {
                if (window.startMinutes <= minute && minute < window.endMinutes) isBlocked = YES;
            }
            if (wasBlocked && !isBlocked) return NO;
        }
    }
    return YES;
}

- (BOOL)isValidActiveEditOfSchedule:(SCWeeklySchedule *)baselineSchedule {
    if (![self.bundleID isEqualToString:baselineSchedule.bundleID]) return NO;
    for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
        if ([self activeEditBaselineWindowIndexesForDay:day baselineSchedule:baselineSchedule] == nil) return NO;
    }
    return YES;
}

- (NSArray<NSNumber *> *)activeEditBaselineWindowIndexesForDay:(SCDayOfWeek)day
                                            baselineSchedule:(SCWeeklySchedule *)baselineSchedule {
    if (baselineSchedule == nil || ![self.bundleID isEqualToString:baselineSchedule.bundleID]) return nil;
    NSArray<SCTimeRange *> *proposed = [self allowedWindowsForDay:day];
    NSArray<SCTimeRange *> *originals = [baselineSchedule allowedWindowsForDay:day];
    if (proposed.count > originals.count) return nil;
    NSMutableArray<NSNumber *> *owners = [NSMutableArray arrayWithCapacity:originals.count];
    for (NSUInteger index = 0; index < originals.count; index++) [owners addObject:@(-1)];
    for (NSUInteger index = 0; index < proposed.count; index++) {
        if (!SCMatchActiveEditWindow(index, proposed, originals, owners, [NSMutableIndexSet indexSet])) return nil;
    }
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray arrayWithCapacity:proposed.count];
    for (NSUInteger index = 0; index < proposed.count; index++) [indexes addObject:@(-1)];
    [owners enumerateObjectsUsingBlock:^(NSNumber *owner, NSUInteger originalIndex, BOOL *stop) {
        if (owner.integerValue >= 0) indexes[owner.unsignedIntegerValue] = @(originalIndex);
    }];
    return indexes;
}

- (NSArray<SCTimeRange *> *)allowedWindowsForDay:(SCDayOfWeek)day {
    NSString *key = [SCWeeklySchedule stringForDay:day];
    return [self.daySchedules[key] copy] ?: @[];
}

- (void)setAllowedWindows:(NSArray<SCTimeRange *> *)windows forDay:(SCDayOfWeek)day {
    NSString *key = [SCWeeklySchedule stringForDay:day];
    self.daySchedules[key] = [windows mutableCopy] ?: [NSMutableArray array];
}

- (void)addAllowedWindow:(SCTimeRange *)window toDay:(SCDayOfWeek)day {
    NSString *key = [SCWeeklySchedule stringForDay:day];
    if (!self.daySchedules[key]) {
        self.daySchedules[key] = [NSMutableArray array];
    }
    [self.daySchedules[key] addObject:window];

    // Sort windows by start time
    [self.daySchedules[key] sortUsingComparator:^NSComparisonResult(SCTimeRange *r1, SCTimeRange *r2) {
        return [@([r1 startMinutes]) compare:@([r2 startMinutes])];
    }];
}

- (void)removeAllowedWindow:(SCTimeRange *)window fromDay:(SCDayOfWeek)day {
    NSString *key = [SCWeeklySchedule stringForDay:day];
    [self.daySchedules[key] removeObject:window];
}

- (void)clearDay:(SCDayOfWeek)day {
    NSString *key = [SCWeeklySchedule stringForDay:day];
    [self.daySchedules[key] removeAllObjects];
}

#pragma mark - Day String Conversion

+ (NSString *)stringForDay:(SCDayOfWeek)day {
    switch (day) {
        case SCDayOfWeekSunday: return @"sunday";
        case SCDayOfWeekMonday: return @"monday";
        case SCDayOfWeekTuesday: return @"tuesday";
        case SCDayOfWeekWednesday: return @"wednesday";
        case SCDayOfWeekThursday: return @"thursday";
        case SCDayOfWeekFriday: return @"friday";
        case SCDayOfWeekSaturday: return @"saturday";
        default: return @"sunday";
    }
}

+ (SCDayOfWeek)dayForString:(NSString *)string {
    static NSDictionary *mapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mapping = @{
            @"sunday": @(SCDayOfWeekSunday),
            @"monday": @(SCDayOfWeekMonday),
            @"tuesday": @(SCDayOfWeekTuesday),
            @"wednesday": @(SCDayOfWeekWednesday),
            @"thursday": @(SCDayOfWeekThursday),
            @"friday": @(SCDayOfWeekFriday),
            @"saturday": @(SCDayOfWeekSaturday)
        };
    });
    return [mapping[string.lowercaseString] integerValue];
}

+ (NSString *)displayNameForDay:(SCDayOfWeek)day {
    switch (day) {
        case SCDayOfWeekSunday: return @"Sunday";
        case SCDayOfWeekMonday: return @"Monday";
        case SCDayOfWeekTuesday: return @"Tuesday";
        case SCDayOfWeekWednesday: return @"Wednesday";
        case SCDayOfWeekThursday: return @"Thursday";
        case SCDayOfWeekFriday: return @"Friday";
        case SCDayOfWeekSaturday: return @"Saturday";
        default: return @"";
    }
}

+ (NSString *)shortNameForDay:(SCDayOfWeek)day {
    switch (day) {
        case SCDayOfWeekSunday: return @"Sun";
        case SCDayOfWeekMonday: return @"Mon";
        case SCDayOfWeekTuesday: return @"Tue";
        case SCDayOfWeekWednesday: return @"Wed";
        case SCDayOfWeekThursday: return @"Thu";
        case SCDayOfWeekFriday: return @"Fri";
        case SCDayOfWeekSaturday: return @"Sat";
        default: return @"";
    }
}

+ (SCDayOfWeek)today {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitWeekday fromDate:[NSDate date]];
    // NSCalendar weekday: 1 = Sunday, 7 = Saturday
    return (SCDayOfWeek)(components.weekday - 1);
}

#pragma mark - Schedule Queries

- (BOOL)isAllowedNow {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    return [self isAllowedAtDate:[NSDate date] calendar:calendar];
}

- (BOOL)isAllowedAtDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSDateComponents *components = [calendar
        components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
          fromDate:date];
    SCDayOfWeek day = (SCDayOfWeek)(components.weekday - 1);
    NSInteger minutesFromMidnight = components.hour * 60 + components.minute;
    return [self isAllowedOnDay:day atMinutes:minutesFromMidnight];
}

- (BOOL)isAllowedOnDay:(SCDayOfWeek)day atMinutes:(NSInteger)minutesFromMidnight {
    NSArray<SCTimeRange *> *windows = [self allowedWindowsForDay:day];

    // No windows = blocked all day
    if (windows.count == 0) {
        return NO;
    }

    // Check if current time falls within any allowed window
    for (SCTimeRange *window in windows) {
        if (window.startMinutes <= minutesFromMidnight && minutesFromMidnight < window.endMinutes) {
            return YES;
        }
    }

    return NO;
}

- (nullable NSDate *)nextStateChangeDate {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    return [self nextStateChangeDateAfterDate:[NSDate date] calendar:calendar];
}

- (nullable NSDate *)nextStateChangeDateAfterDate:(NSDate *)date
                                         calendar:(NSCalendar *)calendar {
    BOOL currentlyAllowed = [self isAllowedAtDate:date calendar:calendar];
    NSDateComponents *nowComponents = [calendar
        components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
          fromDate:date];
    SCDayOfWeek today = (SCDayOfWeek)(nowComponents.weekday - 1);
    NSInteger currentMinutes = nowComponents.hour * 60 + nowComponents.minute;

    // Include the same weekday next week after its final window has ended.
    for (NSInteger dayOffset = 0; dayOffset <= 7; dayOffset++) {
        SCDayOfWeek checkDay = (today + dayOffset) % 7;
        NSArray<SCTimeRange *> *windows = [self allowedWindowsForDay:checkDay];

        NSInteger startMinute = (dayOffset == 0) ? currentMinutes + 1 : 0;

        for (NSInteger minute = startMinute; minute < 24 * 60; minute++) {
            BOOL allowedAtMinute = NO;
            for (SCTimeRange *window in windows) {
                if (window.startMinutes <= minute && minute < window.endMinutes) {
                    allowedAtMinute = YES;
                    break;
                }
            }

            if (allowedAtMinute != currentlyAllowed) {
                // Found a state change
                NSDate *targetDate = [calendar dateByAddingUnit:NSCalendarUnitDay
                                                          value:dayOffset
                                                         toDate:date
                                                        options:0];

                NSDateComponents *targetComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                                                 fromDate:targetDate];
                targetComponents.hour = minute / 60;
                targetComponents.minute = minute % 60;

                return [calendar dateFromComponents:targetComponents];
            }
        }
    }

    return nil;
}

- (NSString *)currentStatusString {
    return [self currentStatusStringAtDate:[NSDate date]
                                   calendar:[NSCalendar currentCalendar]];
}

- (NSString *)currentStatusStringAtDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    return [self currentStatusStringAtDate:date calendar:calendar policy:SCBundlePolicyAllow];
}

- (NSString *)currentStatusStringAtDate:(NSDate *)date calendar:(NSCalendar *)calendar policy:(SCBundlePolicy)policy {
    // Returns just the "till X" part - caller adds "blocked"/"allowed"
    NSDate *nextChange = [self nextStateChangeDateAfterDate:date calendar:calendar];
    if (nextChange) {
        // When currently allowed, show the last allowed minute (subtract 1 min)
        // nextStateChangeDate returns first minute of NEXT state, but users expect
        // "allowed till X" where X is the last allowed minute, not first blocked minute
        NSDateComponents *components = [calendar components:NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
        NSInteger minute = components.hour * 60 + components.minute;
        BOOL insideWindow = NO;
        for (SCTimeRange *window in [self allowedWindowsForDay:(SCDayOfWeek)(components.weekday - 1)]) {
            if (window.startMinutes <= minute && minute < window.endMinutes) insideWindow = YES;
        }
        BOOL isAllowed = policy == SCBundlePolicyBlock ? !insideWindow : insideWindow;
        if (isAllowed) {
            nextChange = [calendar dateByAddingUnit:NSCalendarUnitMinute
                                              value:-1
                                             toDate:nextChange
                                            options:0];
        }

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.calendar = calendar;
        formatter.timeZone = calendar.timeZone;

        // Check if next change is today - if so, just show time; otherwise include day
        if ([calendar isDate:nextChange inSameDayAsDate:date]) {
            formatter.dateFormat = @"h:mma";  // Just time: "5:00pm"
        } else {
            formatter.dateFormat = @"EEE h:mma";  // Day + time: "Mon 5:00pm"
        }
        return [NSString stringWithFormat:@"till %@", [formatter stringFromDate:nextChange]];
    }
    return @"";  // Empty - manager will add commitment end date
}

- (NSInteger)totalAllowedMinutesForDay:(SCDayOfWeek)day {
    NSArray<SCTimeRange *> *windows = [self allowedWindowsForDay:day];
    NSInteger total = 0;
    for (SCTimeRange *window in windows) {
        total += [window durationMinutes];
    }
    return total;
}

- (BOOL)hasAllowedWindowsForDay:(SCDayOfWeek)day {
    return [self allowedWindowsForDay:day].count > 0;
}

- (BOOL)hasAnyWindows {
    for (NSInteger day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
        if ([self hasAllowedWindowsForDay:day]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Copy Operations

- (void)copyDay:(SCDayOfWeek)fromDay toDay:(SCDayOfWeek)toDay {
    NSArray<SCTimeRange *> *sourceWindows = [self allowedWindowsForDay:fromDay];
    NSMutableArray *copiedWindows = [NSMutableArray array];
    for (SCTimeRange *window in sourceWindows) {
        [copiedWindows addObject:[window copy]];
    }
    [self setAllowedWindows:copiedWindows forDay:toDay];
}

- (void)copyDay:(SCDayOfWeek)fromDay toDays:(NSArray<NSNumber *> *)toDays {
    for (NSNumber *dayNum in toDays) {
        [self copyDay:fromDay toDay:[dayNum integerValue]];
    }
}

- (void)applyToWeekdays:(NSArray<SCTimeRange *> *)windows {
    for (SCDayOfWeek day = SCDayOfWeekMonday; day <= SCDayOfWeekFriday; day++) {
        NSMutableArray *copied = [NSMutableArray array];
        for (SCTimeRange *w in windows) {
            [copied addObject:[w copy]];
        }
        [self setAllowedWindows:copied forDay:day];
    }
}

- (void)applyToWeekend:(NSArray<SCTimeRange *> *)windows {
    NSArray<NSNumber *> *weekendDays = @[@(SCDayOfWeekSaturday), @(SCDayOfWeekSunday)];
    for (NSNumber *dayNum in weekendDays) {
        NSMutableArray *copied = [NSMutableArray array];
        for (SCTimeRange *w in windows) {
            [copied addObject:[w copy]];
        }
        [self setAllowedWindows:copied forDay:[dayNum integerValue]];
    }
}

#pragma mark - Week Navigation

+ (NSArray<NSNumber *> *)remainingDaysInWeekStartingMonday:(BOOL)startsOnMonday {
    SCDayOfWeek today = [self today];
    NSMutableArray *days = [NSMutableArray array];

    NSArray<NSNumber *> *allDays = [self allDaysStartingMonday:startsOnMonday];
    BOOL foundToday = NO;

    for (NSNumber *dayNum in allDays) {
        if ([dayNum integerValue] == today) {
            foundToday = YES;
        }
        if (foundToday) {
            [days addObject:dayNum];
        }
    }

    return days;
}

+ (NSArray<NSNumber *> *)allDaysStartingMonday:(BOOL)startsOnMonday {
    if (startsOnMonday) {
        return @[
            @(SCDayOfWeekMonday),
            @(SCDayOfWeekTuesday),
            @(SCDayOfWeekWednesday),
            @(SCDayOfWeekThursday),
            @(SCDayOfWeekFriday),
            @(SCDayOfWeekSaturday),
            @(SCDayOfWeekSunday)
        ];
    } else {
        return @[
            @(SCDayOfWeekSunday),
            @(SCDayOfWeekMonday),
            @(SCDayOfWeekTuesday),
            @(SCDayOfWeekWednesday),
            @(SCDayOfWeekThursday),
            @(SCDayOfWeekFriday),
            @(SCDayOfWeekSaturday)
        ];
    }
}

+ (NSDate *)startOfCurrentWeek {
    return [self startOfWeekContaining:[NSDate date]];
}

+ (NSDate *)startOfNextWeek {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *currentWeekStart = [self startOfCurrentWeek];
    return [calendar dateByAddingUnit:NSCalendarUnitDay value:7 toDate:currentWeekStart options:0];
}

+ (NSDate *)startOfWeekContaining:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitWeekday fromDate:date];
    NSInteger weekday = components.weekday; // 1 = Sunday, 2 = Monday, ...

    // Calculate days to subtract to get to Monday
    // If Sunday (1), go back 6 days; if Monday (2), go back 0; if Tuesday (3), go back 1, etc.
    NSInteger daysToMonday = (weekday == 1) ? -6 : -(weekday - 2);

    NSDate *monday = [calendar dateByAddingUnit:NSCalendarUnitDay value:daysToMonday toDate:date options:0];

    // Normalize to start of day
    return [calendar startOfDayForDate:monday];
}

+ (NSString *)weekKeyForDate:(NSDate *)date {
    NSDate *weekStart = [self startOfWeekContaining:date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:weekStart];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    SCWeeklySchedule *copy = [[SCWeeklySchedule allocWithZone:zone] init];
    copy.bundleID = [self.bundleID copy];

    for (NSString *dayKey in self.daySchedules) {
        NSMutableArray *windowsCopy = [NSMutableArray array];
        for (SCTimeRange *range in self.daySchedules[dayKey]) {
            [windowsCopy addObject:[range copy]];
        }
        copy.daySchedules[dayKey] = windowsCopy;
    }

    return copy;
}

#pragma mark - NSSecureCoding

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.bundleID forKey:@"bundleID"];
    [coder encodeObject:[self toDictionary][@"daySchedules"] forKey:@"daySchedules"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _bundleID = [coder decodeObjectOfClass:[NSString class] forKey:@"bundleID"];
        _daySchedules = [NSMutableDictionary dictionary];

        // Initialize empty
        for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
            NSString *key = [SCWeeklySchedule stringForDay:day];
            _daySchedules[key] = [NSMutableArray array];
        }

        // Load from coder
        NSSet *allowed = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], nil];
        NSDictionary *dayDicts = [coder decodeObjectOfClasses:allowed forKey:@"daySchedules"];
        if (dayDicts) {
            for (NSString *dayKey in dayDicts) {
                NSArray *windowDicts = dayDicts[dayKey];
                NSMutableArray *windows = [NSMutableArray array];
                for (NSDictionary *windowDict in windowDicts) {
                    SCTimeRange *range = [SCTimeRange rangeFromDictionary:windowDict];
                    if (range) {
                        [windows addObject:range];
                    }
                }
                _daySchedules[dayKey] = windows;
            }
        }
    }
    return self;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[SCWeeklySchedule class]]) return NO;

    SCWeeklySchedule *other = (SCWeeklySchedule *)object;
    return [self.bundleID isEqualToString:other.bundleID];
}

- (NSUInteger)hash {
    return [self.bundleID hash];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SCWeeklySchedule: bundleID=%@>", self.bundleID];
}

@end

//
//  SCWeeklySchedule.h
//  SelfControl
//
//  Represents a weekly schedule for a single bundle.
//  Contains allowed time windows for each day of the week.
//

#import <Foundation/Foundation.h>
#import "SCTimeRange.h"

NS_ASSUME_NONNULL_BEGIN

/// Days of the week (0 = Sunday, 6 = Saturday)
typedef NS_ENUM(NSInteger, SCDayOfWeek) {
    SCDayOfWeekSunday = 0,
    SCDayOfWeekMonday = 1,
    SCDayOfWeekTuesday = 2,
    SCDayOfWeekWednesday = 3,
    SCDayOfWeekThursday = 4,
    SCDayOfWeekFriday = 5,
    SCDayOfWeekSaturday = 6
};

@interface SCWeeklySchedule : NSObject <NSCopying, NSSecureCoding>

/// The bundle ID this schedule applies to
@property (nonatomic, copy) NSString *bundleID;

/// Schedule for each day: @{ @"sunday": @[SCTimeRange, ...], @"monday": @[...], ... }
/// Arrays contain SCTimeRange objects representing ALLOWED windows
/// Empty array = blocked all day
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<SCTimeRange *> *> *daySchedules;

/// Creates an empty schedule for a bundle (blocked all day every day)
+ (instancetype)emptyScheduleForBundleID:(NSString *)bundleID;

/// Creates a schedule from a dictionary (for persistence)
+ (nullable instancetype)scheduleFromDictionary:(NSDictionary *)dict;

/// Converts to dictionary for persistence
- (NSDictionary *)toDictionary;

#pragma mark - Day Access

/// Returns the allowed windows for a specific day
- (NSArray<SCTimeRange *> *)allowedWindowsForDay:(SCDayOfWeek)day;

/// Sets the allowed windows for a specific day
- (void)setAllowedWindows:(NSArray<SCTimeRange *> *)windows forDay:(SCDayOfWeek)day;

/// Adds an allowed window to a specific day
- (void)addAllowedWindow:(SCTimeRange *)window toDay:(SCDayOfWeek)day;

/// Removes an allowed window from a specific day
- (void)removeAllowedWindow:(SCTimeRange *)window fromDay:(SCDayOfWeek)day;

/// Clears all allowed windows for a specific day (makes it fully blocked)
- (void)clearDay:(SCDayOfWeek)day;

#pragma mark - Day String Conversion

/// Converts SCDayOfWeek to string key (e.g., "monday")
+ (NSString *)stringForDay:(SCDayOfWeek)day;

/// Converts string key to SCDayOfWeek
+ (SCDayOfWeek)dayForString:(NSString *)string;

/// Returns display name for day (e.g., "Monday")
+ (NSString *)displayNameForDay:(SCDayOfWeek)day;

/// Returns short name for day (e.g., "Mon")
+ (NSString *)shortNameForDay:(SCDayOfWeek)day;

/// Returns today's day of week
+ (SCDayOfWeek)today;

#pragma mark - Schedule Queries

/// Checks if the bundle should be ALLOWED (not blocked) at current time
- (BOOL)isAllowedNow;

/// Calendar-aware variants used while a recurring commitment is pinned to a
/// root-owned timezone. Draft callers can keep using the convenience methods.
- (BOOL)isAllowedAtDate:(NSDate *)date calendar:(NSCalendar *)calendar;

/// Checks if the bundle should be ALLOWED at a specific day and time
- (BOOL)isAllowedOnDay:(SCDayOfWeek)day atMinutes:(NSInteger)minutesFromMidnight;

/// Returns the next state change time (when allowed -> blocked or blocked -> allowed)
- (nullable NSDate *)nextStateChangeDate;
- (nullable NSDate *)nextStateChangeDateAfterDate:(NSDate *)date
                                         calendar:(NSCalendar *)calendar;

/// Returns human-readable status for current state
- (NSString *)currentStatusString;
- (NSString *)currentStatusStringAtDate:(NSDate *)date calendar:(NSCalendar *)calendar;

/// Total allowed minutes for a specific day
- (NSInteger)totalAllowedMinutesForDay:(SCDayOfWeek)day;

/// Checks if a day has any allowed windows
- (BOOL)hasAllowedWindowsForDay:(SCDayOfWeek)day;

/// Checks if any day has any allowed windows
- (BOOL)hasAnyWindows;

#pragma mark - Copy Operations

/// Copies schedule from one day to another
- (void)copyDay:(SCDayOfWeek)fromDay toDay:(SCDayOfWeek)toDay;

/// Copies schedule from one day to multiple days
- (void)copyDay:(SCDayOfWeek)fromDay toDays:(NSArray<NSNumber *> *)toDays;

/// Applies a preset to all weekdays (Mon-Fri)
- (void)applyToWeekdays:(NSArray<SCTimeRange *> *)windows;

/// Applies a preset to weekend (Sat-Sun)
- (void)applyToWeekend:(NSArray<SCTimeRange *> *)windows;

#pragma mark - Week Navigation

/// Returns days remaining in the week starting from today
+ (NSArray<NSNumber *> *)remainingDaysInWeekStartingMonday:(BOOL)startsOnMonday;

/// Returns all days in order based on week start preference
+ (NSArray<NSNumber *> *)allDaysStartingMonday:(BOOL)startsOnMonday;

/// Returns the Monday of the current week
+ (NSDate *)startOfCurrentWeek;

/// Returns the Monday of next week
+ (NSDate *)startOfNextWeek;

/// Returns the Monday of the week containing the given date
+ (NSDate *)startOfWeekContaining:(NSDate *)date;

/// Returns a string key for storing week data (e.g., "2024-12-23")
+ (NSString *)weekKeyForDate:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END

//
//  SCProtectionPolicy.m
//  SelfControl
//

#import "SCProtectionPolicy.h"

NSInteger const SCBreakCreditDefaultAllowance = 3;
NSInteger const SCBreakCreditMaximumAllowance = 10;
NSInteger const SCEmergencyWaitDefaultMinutes = 3;
NSInteger const SCEmergencyWaitMinimumMinutes = 1;
NSInteger const SCEmergencyWaitMaximumMinutes = 10;

NSInteger const SCProtectedHoursMinutesPerDay = 24 * 60;
NSInteger const SCProtectedHoursSnapIntervalMinutes = 15;
NSInteger const SCProtectedHoursMinimumDurationMinutes = 15;
NSInteger const SCProtectedHoursEditLockLeadMinutes = 2 * 60;

NSInteger SCClampBreakCreditAllowance(NSInteger allowance) {
    return MIN(MAX(allowance, 0), SCBreakCreditMaximumAllowance);
}

NSInteger SCResolveBreakCreditAllowanceUpdate(NSInteger requestedAllowance,
                                                NSInteger currentAllowance,
                                                BOOL hasSurvivingCommitment) {
    NSInteger requested = SCClampBreakCreditAllowance(requestedAllowance);
    NSInteger current = SCClampBreakCreditAllowance(currentAllowance);
    return hasSurvivingCommitment ? MIN(requested, current) : requested;
}

NSInteger SCClampEmergencyWaitMinutes(NSInteger minutes) {
    return MIN(MAX(minutes, SCEmergencyWaitMinimumMinutes), SCEmergencyWaitMaximumMinutes);
}

NSInteger SCResolveEmergencyWaitUpdate(NSInteger requestedMinutes,
                                       NSInteger currentMinutes,
                                       BOOL hasSurvivingCommitment) {
    NSInteger requested = SCClampEmergencyWaitMinutes(requestedMinutes);
    NSInteger current = SCClampEmergencyWaitMinutes(currentMinutes);
    return hasSurvivingCommitment ? MAX(requested, current) : requested;
}

NSInteger SCReconcileBreakCredits(NSInteger allowance,
                                  NSInteger remainingToday,
                                  NSDate *lastResetDay,
                                  NSDate *date,
                                  NSCalendar *calendar,
                                  BOOL forceReset,
                                  NSDate **resolvedResetDay,
                                  BOOL *didReset) {
    NSInteger clampedAllowance = SCClampBreakCreditAllowance(allowance);
    BOOL reset = forceReset || lastResetDay == nil ||
        ![calendar isDate:lastResetDay inSameDayAsDate:date];
    NSDate *day = [calendar startOfDayForDate:(reset ? date : lastResetDay)];
    if (resolvedResetDay != NULL) *resolvedResetDay = day;
    if (didReset != NULL) *didReset = reset;
    if (reset) return clampedAllowance;
    return MIN(MAX(remainingToday, 0), clampedAllowance);
}

static NSInteger SCProtectedHoursWrappedMinute(NSInteger minute) {
    NSInteger wrapped = minute % SCProtectedHoursMinutesPerDay;
    return wrapped < 0 ? wrapped + SCProtectedHoursMinutesPerDay : wrapped;
}

static NSInteger SCProtectedHoursSnappedMinute(NSInteger minute) {
    NSInteger wrapped = SCProtectedHoursWrappedMinute(minute);
    NSInteger snapped = ((wrapped + SCProtectedHoursSnapIntervalMinutes / 2) /
                         SCProtectedHoursSnapIntervalMinutes) *
        SCProtectedHoursSnapIntervalMinutes;
    return snapped >= SCProtectedHoursMinutesPerDay ? 0 : snapped;
}

SCProtectedHoursRange SCNormalizeProtectedHoursRange(NSInteger startMinute,
                                                      NSInteger endMinute) {
    SCProtectedHoursRange range = {
        .startMinute = SCProtectedHoursSnappedMinute(startMinute),
        .endMinute = SCProtectedHoursSnappedMinute(endMinute),
    };
    if (range.startMinute == range.endMinute) {
        range.endMinute = SCProtectedHoursWrappedMinute(
            range.startMinute + SCProtectedHoursMinimumDurationMinutes);
    }
    return range;
}

static NSInteger SCProtectedHoursDuration(SCProtectedHoursRange range) {
    range = SCNormalizeProtectedHoursRange(range.startMinute, range.endMinute);
    if (range.startMinute < range.endMinute) {
        return range.endMinute - range.startMinute;
    }
    return SCProtectedHoursMinutesPerDay - range.startMinute + range.endMinute;
}

static BOOL SCProtectedHoursRangeContainsMinute(NSInteger minute,
                                                NSInteger startMinute,
                                                NSInteger endMinute) {
    minute = SCProtectedHoursWrappedMinute(minute);
    startMinute = SCProtectedHoursWrappedMinute(startMinute);
    endMinute = SCProtectedHoursWrappedMinute(endMinute);
    if (startMinute < endMinute) {
        return minute >= startMinute && minute < endMinute;
    }
    return minute >= startMinute || minute < endMinute;
}

static NSInteger SCProtectedHoursMinuteOfDay(NSDate *date, NSCalendar *calendar) {
    NSDateComponents *components = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                               fromDate:date];
    return components.hour * 60 + components.minute;
}

BOOL SCProtectedHoursAreActive(BOOL enabled,
                               SCProtectedHoursRange range,
                               NSDate *date,
                               NSCalendar *calendar) {
    if (!enabled) return NO;
    range = SCNormalizeProtectedHoursRange(range.startMinute, range.endMinute);
    return SCProtectedHoursRangeContainsMinute(
        SCProtectedHoursMinuteOfDay(date, calendar), range.startMinute, range.endMinute);
}

BOOL SCProtectedHoursUpdateIsNoWeaker(BOOL currentEnabled,
                                      SCProtectedHoursRange currentRange,
                                      BOOL proposedEnabled,
                                      SCProtectedHoursRange proposedRange) {
    if (!currentEnabled) return YES;
    if (!proposedEnabled) return NO;
    for (NSInteger minute = 0; minute < SCProtectedHoursMinutesPerDay; minute++) {
        if (SCProtectedHoursRangeContainsMinute(minute, currentRange.startMinute,
                                                currentRange.endMinute) &&
            !SCProtectedHoursRangeContainsMinute(minute, proposedRange.startMinute,
                                                 proposedRange.endMinute)) {
            return NO;
        }
    }
    return YES;
}

BOOL SCProtectedHoursEditLockIsActive(BOOL enabled,
                                      SCProtectedHoursRange range,
                                      NSDate *date,
                                      NSCalendar *calendar) {
    if (!enabled) return NO;
    range = SCNormalizeProtectedHoursRange(range.startMinute, range.endMinute);
    if (SCProtectedHoursDuration(range) + SCProtectedHoursEditLockLeadMinutes >=
        SCProtectedHoursMinutesPerDay) {
        return YES;
    }
    NSInteger lockStart = SCProtectedHoursWrappedMinute(
        range.startMinute - SCProtectedHoursEditLockLeadMinutes);
    return SCProtectedHoursRangeContainsMinute(
        SCProtectedHoursMinuteOfDay(date, calendar), lockStart, range.endMinute);
}

static NSDate *SCNextLocalWallTime(NSDate *date,
                                   NSInteger minuteOfDay,
                                   NSCalendar *calendar) {
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.hour = minuteOfDay / 60;
    components.minute = minuteOfDay % 60;
    components.second = 0;
    return [calendar nextDateAfterDate:date
                   matchingComponents:components
                              options:NSCalendarMatchNextTime];
}

NSDate *SCNextProtectedHoursBoundary(BOOL enabled,
                                     SCProtectedHoursRange range,
                                     NSDate *date,
                                     NSCalendar *calendar) {
    if (!enabled) return nil;
    range = SCNormalizeProtectedHoursRange(range.startMinute, range.endMinute);
    NSDate *nextStart = SCNextLocalWallTime(date, range.startMinute, calendar);
    NSDate *nextEnd = SCNextLocalWallTime(date, range.endMinute, calendar);
    if (nextStart == nil) return nextEnd;
    if (nextEnd == nil) return nextStart;
    return [nextStart compare:nextEnd] == NSOrderedAscending ? nextStart : nextEnd;
}

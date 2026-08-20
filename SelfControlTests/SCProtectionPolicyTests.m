//
//  SCProtectionPolicyTests.m
//  SelfControlTests
//

#import <XCTest/XCTest.h>

#import "SCProtectionPolicy.h"

@interface SCProtectionPolicyTests : XCTestCase
@end

@implementation SCProtectionPolicyTests

- (NSCalendar *)calendarWithTimeZone:(NSTimeZone *)timeZone {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone;
    return calendar;
}

- (NSDate *)dateInCalendar:(NSCalendar *)calendar
                       day:(NSInteger)day
                      hour:(NSInteger)hour
                    minute:(NSInteger)minute {
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = 2026;
    components.month = 8;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    return [calendar dateFromComponents:components];
}

- (void)testBreakAllowanceClampsToZeroThroughTen {
    XCTAssertEqual(SCClampBreakCreditAllowance(-1), 0);
    XCTAssertEqual(SCClampBreakCreditAllowance(0), 0);
    XCTAssertEqual(SCClampBreakCreditAllowance(3), 3);
    XCTAssertEqual(SCClampBreakCreditAllowance(10), 10);
    XCTAssertEqual(SCClampBreakCreditAllowance(11), 10);
}

- (void)testBreakAllowanceIsFrozenDuringSurvivingCommitment {
    XCTAssertEqual(SCResolveBreakCreditAllowanceUpdate(7, 3, NO), 7);
    XCTAssertEqual(SCResolveBreakCreditAllowanceUpdate(7, 3, YES), 3);
    XCTAssertEqual(SCResolveBreakCreditAllowanceUpdate(2, 3, YES), 3);
    XCTAssertEqual(SCResolveBreakCreditAllowanceUpdate(-5, 3, YES), 3);
    XCTAssertEqual(SCResolveBreakCreditAllowanceUpdate(20, 20, YES), 10);
}

- (void)testEmergencyWaitClampsToOneThroughTenMinutes {
    XCTAssertEqual(SCClampEmergencyWaitMinutes(0), 1);
    XCTAssertEqual(SCClampEmergencyWaitMinutes(3), 3);
    XCTAssertEqual(SCClampEmergencyWaitMinutes(11), 10);
}

- (void)testSameLocalDayPreservesSpentCreditsAndClampsOnlyToReducedAllowance {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    NSDate *lastReset = [self dateInCalendar:calendar day:1 hour:0 minute:0];
    NSDate *later = [self dateInCalendar:calendar day:1 hour:18 minute:30];
    NSDate *resolvedDay = nil;
    BOOL didReset = YES;

    NSInteger remaining = SCReconcileBreakCredits(3, 1, lastReset, later, calendar, NO,
                                                   &resolvedDay, &didReset);
    XCTAssertEqual(remaining, 1);
    XCTAssertFalse(didReset);
    XCTAssertEqualObjects(resolvedDay, lastReset);

    remaining = SCReconcileBreakCredits(2, 8, lastReset, later, calendar, NO,
                                        &resolvedDay, &didReset);
    XCTAssertEqual(remaining, 2);
    XCTAssertFalse(didReset);
}

- (void)testDifferentLocalDayAndForcedResetRefillToClampedAllowance {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    NSDate *firstDay = [self dateInCalendar:calendar day:1 hour:12 minute:0];
    NSDate *nextDay = [self dateInCalendar:calendar day:2 hour:7 minute:0];
    NSDate *resolvedDay = nil;
    BOOL didReset = NO;

    NSInteger remaining = SCReconcileBreakCredits(3, 0, firstDay, nextDay, calendar, NO,
                                                   &resolvedDay, &didReset);
    XCTAssertEqual(remaining, 3);
    XCTAssertTrue(didReset);
    XCTAssertEqualObjects(resolvedDay, [calendar startOfDayForDate:nextDay]);

    remaining = SCReconcileBreakCredits(30, 0, nextDay, nextDay, calendar, YES,
                                        &resolvedDay, &didReset);
    XCTAssertEqual(remaining, 10);
    XCTAssertTrue(didReset);

    remaining = SCReconcileBreakCredits(0, 8, nil, nextDay, calendar, NO,
                                        &resolvedDay, &didReset);
    XCTAssertEqual(remaining, 0);
    XCTAssertTrue(didReset);
}

- (void)testDailyResetUsesInjectedLocalCalendarDay {
    NSDate *firstInstant = [NSDate dateWithTimeIntervalSince1970:1775003400]; // 2026-04-01 00:30 UTC
    NSDate *laterInstant = [firstInstant dateByAddingTimeInterval:23 * 60 * 60];
    NSCalendar *utc = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    NSCalendar *plusTwo = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:2 * 60 * 60]];
    BOOL didReset = NO;

    XCTAssertEqual(SCReconcileBreakCredits(3, 1, firstInstant, laterInstant, utc, NO,
                                           NULL, &didReset), 1);
    XCTAssertFalse(didReset);
    XCTAssertEqual(SCReconcileBreakCredits(3, 1, firstInstant, laterInstant, plusTwo, NO,
                                           NULL, &didReset), 3);
    XCTAssertTrue(didReset);
}

- (void)testProtectedRangeWrapsSnapsAndGuaranteesMinimumDuration {
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(22 * 60 + 53, 5 * 60 + 7);
    XCTAssertEqual(range.startMinute, 23 * 60);
    XCTAssertEqual(range.endMinute, 5 * 60);

    range = SCNormalizeProtectedHoursRange(-1, 24 * 60 + 1);
    XCTAssertEqual(range.startMinute, 0);
    XCTAssertEqual(range.endMinute, 15);

    range = SCNormalizeProtectedHoursRange(9 * 60 + 2, 9 * 60 + 6);
    XCTAssertEqual(range.startMinute, 9 * 60);
    XCTAssertEqual(range.endMinute, 9 * 60 + 15);
}

- (void)testSameDayProtectedRangeIsHalfOpen {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(9 * 60, 17 * 60);
    XCTAssertFalse(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:8 minute:59], calendar));
    XCTAssertTrue(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:9 minute:0], calendar));
    XCTAssertTrue(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:16 minute:59], calendar));
    XCTAssertFalse(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:17 minute:0], calendar));
    XCTAssertFalse(SCProtectedHoursAreActive(NO, range,
        [self dateInCalendar:calendar day:1 hour:12 minute:0], calendar));
}

- (void)testOvernightProtectedRangeIsHalfOpen {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(23 * 60, 5 * 60);
    XCTAssertTrue(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:23 minute:0], calendar));
    XCTAssertTrue(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:2 hour:4 minute:59], calendar));
    XCTAssertFalse(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:2 hour:5 minute:0], calendar));
    XCTAssertFalse(SCProtectedHoursAreActive(YES, range,
        [self dateInCalendar:calendar day:2 hour:12 minute:0], calendar));
}

- (void)testProtectedEditLockStartsTwoHoursBeforeAndEndsAtProtectedEnd {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(23 * 60, 5 * 60);
    XCTAssertFalse(SCProtectedHoursEditLockIsActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:20 minute:59], calendar));
    XCTAssertTrue(SCProtectedHoursEditLockIsActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:21 minute:0], calendar));
    XCTAssertTrue(SCProtectedHoursEditLockIsActive(YES, range,
        [self dateInCalendar:calendar day:2 hour:4 minute:59], calendar));
    XCTAssertFalse(SCProtectedHoursEditLockIsActive(YES, range,
        [self dateInCalendar:calendar day:2 hour:5 minute:0], calendar));
    XCTAssertFalse(SCProtectedHoursEditLockIsActive(NO, range,
        [self dateInCalendar:calendar day:1 hour:23 minute:30], calendar));
}

- (void)testVeryLongProtectedRangeLocksEditingAllDay {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(0, 23 * 60 + 45);
    XCTAssertTrue(SCProtectedHoursEditLockIsActive(YES, range,
        [self dateInCalendar:calendar day:1 hour:12 minute:0], calendar));
}

- (void)testNextSameDayProtectedBoundaryIsStrictlyAfterInput {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(9 * 60, 17 * 60);

    NSDate *atEight = [self dateInCalendar:calendar day:1 hour:8 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, atEight, calendar),
                          [self dateInCalendar:calendar day:1 hour:9 minute:0]);

    NSDate *atStart = [self dateInCalendar:calendar day:1 hour:9 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, atStart, calendar),
                          [self dateInCalendar:calendar day:1 hour:17 minute:0]);

    NSDate *afterEnd = [self dateInCalendar:calendar day:1 hour:18 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, afterEnd, calendar),
                          [self dateInCalendar:calendar day:2 hour:9 minute:0]);
    XCTAssertNil(SCNextProtectedHoursBoundary(NO, range, atEight, calendar));
}

- (void)testNextOvernightBoundaryUsesInjectedLocalWallTime {
    NSCalendar *calendar = [self calendarWithTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:5 * 60 * 60 + 30 * 60]];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(23 * 60, 5 * 60);

    NSDate *beforeStart = [self dateInCalendar:calendar day:1 hour:22 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, beforeStart, calendar),
                          [self dateInCalendar:calendar day:1 hour:23 minute:0]);

    NSDate *atStart = [self dateInCalendar:calendar day:1 hour:23 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, atStart, calendar),
                          [self dateInCalendar:calendar day:2 hour:5 minute:0]);

    NSDate *afterEnd = [self dateInCalendar:calendar day:2 hour:6 minute:0];
    XCTAssertEqualObjects(SCNextProtectedHoursBoundary(YES, range, afterEnd, calendar),
                          [self dateInCalendar:calendar day:2 hour:23 minute:0]);
}

@end

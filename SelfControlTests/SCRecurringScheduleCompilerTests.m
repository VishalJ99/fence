//
//  SCRecurringScheduleCompilerTests.m
//  SelfControlTests
//

#import <XCTest/XCTest.h>

#import "SCRecurringScheduleCompiler.h"
#import "SCBlockBundle.h"
#import "SCWeeklySchedule.h"
#import "SCTimeRange.h"

@interface SCRecurringScheduleCompilerTests : XCTestCase
@end

@implementation SCRecurringScheduleCompilerTests

- (SCBlockBundle *)bundleNamed:(NSString *)name entry:(NSString *)entry order:(NSInteger)order {
    SCBlockBundle *bundle = [[SCBlockBundle alloc] init];
    bundle.name = name;
    bundle.enabled = YES;
    bundle.displayOrder = order;
    [bundle.entries addObject:entry];
    return bundle;
}

- (void)allowAllWeekForSchedule:(SCWeeklySchedule *)schedule {
    for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
        [schedule setAllowedWindows:@[[SCTimeRange allDay]] forDay:day];
    }
}

- (void)testCompilerUsesOneRepeatingMondayBasedWeekAndHalfOpenWindows {
    SCBlockBundle *bundle = [self bundleNamed:@"Work" entry:@"example.com" order:0];
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
    [schedule setAllowedWindows:@[[SCTimeRange rangeWithStart:@"09:00" end:@"17:00"]]
                         forDay:SCDayOfWeekMonday];

    NSArray *segments = [SCRecurringScheduleCompiler segmentsForBundles:@[bundle]
                                                               schedules:@[schedule]];
    XCTAssertEqual(segments.count, 2);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentStartMinuteKey], @0);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentEndMinuteKey], @(9 * 60));
    XCTAssertEqualObjects(segments[1][SCRecurringSegmentStartMinuteKey], @(17 * 60));
    XCTAssertEqualObjects(segments[1][SCRecurringSegmentEndMinuteKey], @(7 * 24 * 60));
}

- (void)testAllWeekAllowProducesNoEnforcementSegments {
    SCBlockBundle *bundle = [self bundleNamed:@"Work" entry:@"example.com" order:0];
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
    [self allowAllWeekForSchedule:schedule];
    XCTAssertEqual([SCRecurringScheduleCompiler segmentsForBundles:@[bundle]
                                                          schedules:@[schedule]].count, 0);
}

- (void)testEnabledBundleWithoutScheduleDefaultsToBlockedAllWeek {
    SCBlockBundle *bundle = [self bundleNamed:@"Work" entry:@"example.com" order:0];

    NSArray *segments = [SCRecurringScheduleCompiler segmentsForBundles:@[bundle]
                                                               schedules:@[]];

    XCTAssertEqual(segments.count, 1);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentStartMinuteKey], @0);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentEndMinuteKey], @(7 * 24 * 60));
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentBlocklistKey], (@[@"example.com"]));
}

- (void)testCompilerMergesBundlesOnlyWhileTheirBlockedPoliciesMatch {
    SCBlockBundle *first = [self bundleNamed:@"First" entry:@"one.example" order:0];
    SCBlockBundle *second = [self bundleNamed:@"Second" entry:@"two.example" order:1];
    SCWeeklySchedule *firstSchedule = [SCWeeklySchedule emptyScheduleForBundleID:first.bundleID];
    SCWeeklySchedule *secondSchedule = [SCWeeklySchedule emptyScheduleForBundleID:second.bundleID];
    [self allowAllWeekForSchedule:firstSchedule];
    [self allowAllWeekForSchedule:secondSchedule];
    [firstSchedule setAllowedWindows:@[] forDay:SCDayOfWeekMonday];
    [secondSchedule setAllowedWindows:@[[SCTimeRange rangeWithStart:@"00:00" end:@"12:00"]]
                               forDay:SCDayOfWeekMonday];

    NSArray *segments = [SCRecurringScheduleCompiler segmentsForBundles:@[first, second]
                                                               schedules:@[firstSchedule, secondSchedule]];
    XCTAssertEqual(segments.count, 2);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentBlocklistKey], (@[@"one.example"]));
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentStartMinuteKey], @0);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentEndMinuteKey], @(12 * 60));
    XCTAssertEqualObjects(segments[1][SCRecurringSegmentBlocklistKey],
                          (@[@"one.example", @"two.example"]));
    XCTAssertEqualObjects(segments[1][SCRecurringSegmentEndMinuteKey], @(24 * 60));
}

- (void)testCanonicalSerializationIgnoresInputOrdering {
    SCBlockBundle *first = [self bundleNamed:@"First" entry:@"one.example" order:0];
    SCBlockBundle *second = [self bundleNamed:@"Second" entry:@"two.example" order:1];
    SCWeeklySchedule *firstSchedule = [SCWeeklySchedule emptyScheduleForBundleID:first.bundleID];
    SCWeeklySchedule *secondSchedule = [SCWeeklySchedule emptyScheduleForBundleID:second.bundleID];
    [firstSchedule setAllowedWindows:@[
        [SCTimeRange rangeWithStart:@"12:00" end:@"13:00"],
        [SCTimeRange rangeWithStart:@"09:00" end:@"10:00"],
    ] forDay:SCDayOfWeekTuesday];

    NSArray *left = [SCRecurringScheduleCompiler canonicalDictionariesForSchedules:
        @[secondSchedule, firstSchedule]];
    NSArray *right = [SCRecurringScheduleCompiler canonicalDictionariesForSchedules:
        @[firstSchedule, secondSchedule]];
    XCTAssertEqualObjects(left, right);
}

@end

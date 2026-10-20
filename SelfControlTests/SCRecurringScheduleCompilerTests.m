//
//  SCRecurringScheduleCompilerTests.m
//  SelfControlTests
//

#import <XCTest/XCTest.h>

#import "SCRecurringScheduleCompiler.h"
#import "SCBlockBundle.h"
#import "SCWeeklySchedule.h"
#import "SCTimeRange.h"
#import "SCScheduleManager.h"

@interface SCScheduleManager (MembershipTestTransport)
- (NSArray<NSString *> *)expectedRecurringActiveEntriesAtDate:(NSDate *)date;
@end

@interface SCBundleMembershipTestManager : SCScheduleManager
@property (nonatomic, copy) NSDictionary *submittedCommitment;
@property (nonatomic) BOOL rejectCalendarSave;
@end
@implementation SCBundleMembershipTestManager
- (void)submitRecurringCalendarSegments:(NSArray<NSDictionary<NSString *, id> *> *)segments
                             commitment:(NSDictionary<NSString *, id> *)commitment
                                  reply:(void (^)(NSDictionary<NSString *, id> *, NSError *))reply {
    self.submittedCommitment = commitment;
    reply(@{@"store_persisted": @(!self.rejectCalendarSave), @"post_write_match": @(!self.rejectCalendarSave),
        @"reconcile_succeeded": @(!self.rejectCalendarSave),
        @"outcome": self.rejectCalendarSave ? @"failed" : @"verified", @"failed_stage": @"none"}, nil);
}
@end

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

- (void)testBlockPolicyUsesInsideWindowsAndLegacyPersistenceDefaultsToAllow {
    SCBlockBundle *bundle = [self bundleNamed:@"Block" entry:@"example.com" order:0];
    NSMutableDictionary *legacy = [bundle.toDictionary mutableCopy];
    [legacy removeObjectForKey:@"policy"];
    XCTAssertEqual([SCBlockBundle bundleFromDictionary:legacy].policy, SCBundlePolicyAllow);
    bundle.policy = SCBundlePolicyBlock;
    XCTAssertEqual([SCBlockBundle bundleFromDictionary:bundle.toDictionary].policy, SCBundlePolicyBlock);
    XCTAssertEqual(((SCBlockBundle *)[bundle copy]).policy, SCBundlePolicyBlock);
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
    [schedule setAllowedWindows:@[[SCTimeRange rangeWithStart:@"09:00" end:@"10:00"]] forDay:SCDayOfWeekMonday];
    NSArray *segments = [SCRecurringScheduleCompiler segmentsForBundles:@[bundle] schedules:@[schedule]];
    XCTAssertEqual(segments.count, 1U);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentStartMinuteKey], @540);
    XCTAssertEqualObjects(segments[0][SCRecurringSegmentEndMinuteKey], @600);
    XCTAssertEqual([SCRecurringScheduleCompiler segmentsForBundles:@[bundle] schedules:@[]].count, 0U);
}

- (void)testProtectedBlockEditsPreserveEachBlockedMinute {
    SCWeeklySchedule *baseline = [SCWeeklySchedule emptyScheduleForBundleID:NSUUID.UUID.UUIDString];
    [baseline setAllowedWindows:@[[SCTimeRange rangeWithStart:@"09:00" end:@"10:00"]] forDay:SCDayOfWeekMonday];
    SCWeeklySchedule *draft = [baseline copy];
    [draft setAllowedWindows:@[[SCTimeRange rangeWithStart:@"08:00" end:@"11:00"]] forDay:SCDayOfWeekMonday];
    XCTAssertTrue([draft isValidActiveEditOfSchedule:baseline policy:SCBundlePolicyBlock]);
    XCTAssertFalse([draft isValidActiveEditOfSchedule:baseline policy:SCBundlePolicyAllow]);
    [draft setAllowedWindows:@[[SCTimeRange rangeWithStart:@"10:00" end:@"11:00"]] forDay:SCDayOfWeekMonday];
    XCTAssertFalse([draft isValidActiveEditOfSchedule:baseline policy:SCBundlePolicyBlock]);
    [draft clearDay:SCDayOfWeekMonday];
    XCTAssertFalse([draft isValidActiveEditOfSchedule:baseline policy:SCBundlePolicyBlock]);
}

- (void)testNewBundleRemainsUnenforcedEditableUntilVerifiedCalendarAdmission {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *keys = @[@"SCScheduleBundles", @"SCRecurringSchedules", @"SCRecurringCommitment",
        @"SCRecurringScheduleMigrationVersion", @"SCRecurringScheduleMigrationState"];
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSString *key in keys) saved[key] = [defaults objectForKey:key] ?: NSNull.null;
    @try {
        SCBlockBundle *existing = [self bundleNamed:@"Existing" entry:@"existing.example" order:0];
        SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:existing.bundleID];
        NSMutableDictionary *profile = [existing.toDictionary mutableCopy];
        profile[@"blockedRanges"] = @[@{@"start": @0, @"end": @10080}];
        NSDictionary *commitment = @{@"schemaVersion": @1, @"commitmentID": NSUUID.UUID.UUIDString,
            @"generation": NSUUID.UUID.UUIDString, @"startedAt": [NSDate dateWithTimeIntervalSinceNow:-86400],
            @"lockEndsAt": [NSDate dateWithTimeIntervalSinceNow:-1],
            @"timeZoneIdentifier": @"UTC", @"followsLocationTimeZone": @NO, @"protectedBundles": @[profile]};
        [defaults setObject:@[existing.toDictionary] forKey:@"SCScheduleBundles"];
        [defaults setObject:@[schedule.toDictionary] forKey:@"SCRecurringSchedules"];
        [defaults setObject:commitment forKey:@"SCRecurringCommitment"];
        [defaults setInteger:1 forKey:@"SCRecurringScheduleMigrationVersion"];
        [defaults setObject:@{@"schemaVersion": @1, @"status": @"complete"} forKey:@"SCRecurringScheduleMigrationState"];
        SCBundleMembershipTestManager *manager = [SCBundleMembershipTestManager new];
        XCTAssertTrue([manager isBundleProtected:existing.bundleID], @"Deadline expiry does not end membership");
        SCBlockBundle *draft = [self bundleNamed:@"Draft" entry:@"draft.example" order:1];
        [manager addBundle:draft];
        XCTAssertFalse([manager isBundleProtected:draft.bundleID]);
        XCTAssertFalse([[manager expectedRecurringActiveEntriesAtDate:NSDate.date] containsObject:@"draft.example"]);
        SCBlockBundle *edited = [draft copy];
        edited.name = @"Edited draft";
        [edited removeEntry:@"draft.example"];
        [edited addEntry:@"new.example"];
        [manager updateBundle:edited];
        XCTAssertEqualObjects([manager bundleWithID:draft.bundleID].name, @"Edited draft");
        XCTAssertEqualObjects([manager bundleWithID:draft.bundleID].entries, (@[@"new.example"]));
        SCBlockBundle *allWeekAllowed = [self bundleNamed:@"Always allowed" entry:@"allowed.example" order:2];
        [manager addBundle:allWeekAllowed];
        SCWeeklySchedule *allWeekWindows = [SCWeeklySchedule emptyScheduleForBundleID:allWeekAllowed.bundleID];
        [self allowAllWeekForSchedule:allWeekWindows];
        [manager updateRecurringSchedule:allWeekWindows];
        SCBlockBundle *noWindowsBlock = [self bundleNamed:@"Unscheduled Block" entry:@"block.example" order:3];
        noWindowsBlock.policy = SCBundlePolicyBlock;
        [manager addBundle:noWindowsBlock];
        manager.rejectCalendarSave = YES;
        XCTestExpectation *rejected = [self expectationWithDescription:@"Unverified admission stays editable"];
        [manager updateRecurringSchedules:manager.recurringSchedules completion:^(BOOL updated, NSError *error) {
            XCTAssertFalse(updated);
            XCTAssertFalse([manager isBundleProtected:draft.bundleID]);
            [rejected fulfill];
        }];
        [self waitForExpectations:@[rejected] timeout:2];
        manager.rejectCalendarSave = NO;
        XCTestExpectation *admitted = [self expectationWithDescription:@"Verified admission"];
        [manager updateRecurringSchedules:manager.recurringSchedules completion:^(BOOL updated, NSError *error) {
            XCTAssertTrue(updated);
            XCTAssertNil(error);
            XCTAssertTrue([manager isBundleProtected:draft.bundleID]);
            XCTAssertTrue([manager isBundleProtected:allWeekAllowed.bundleID], @"Allow remains a member even when never blocking");
            XCTAssertFalse([manager isBundleProtected:noWindowsBlock.bundleID], @"Unscheduled Block is not yet eligible for admission");
            XCTAssertFalse([[manager expectedRecurringActiveEntriesAtDate:NSDate.date] containsObject:@"allowed.example"]);
            XCTAssertEqualObjects([defaults objectForKey:@"SCRecurringCommitment"][@"lockEndsAt"], commitment[@"lockEndsAt"]);
            XCTAssertTrue([[manager expectedRecurringActiveEntriesAtDate:NSDate.date] containsObject:@"new.example"]);
            [admitted fulfill];
        }];
        [self waitForExpectations:@[admitted] timeout:2];
        SCBlockBundle *lockedEdit = [[manager bundleWithID:draft.bundleID] copy];
        lockedEdit.name = @"Forbidden rename";
        lockedEdit.policy = SCBundlePolicyBlock;
        [lockedEdit.entries removeAllObjects];
        [manager updateBundle:lockedEdit];
        [manager removeBundleWithID:draft.bundleID];
        XCTAssertEqualObjects([manager bundleWithID:draft.bundleID].name, @"Edited draft");
        XCTAssertEqualObjects([manager bundleWithID:draft.bundleID].entries, (@[@"new.example"]));
        SCBlockBundle *disposable = [self bundleNamed:@"Disposable" entry:@"unused.example" order:2];
        [manager addBundle:disposable];
        [manager removeBundleWithID:disposable.bundleID];
        XCTAssertNil([manager bundleWithID:disposable.bundleID]);
    } @finally {
        for (NSString *key in keys) {
            if (saved[key] == NSNull.null) [defaults removeObjectForKey:key];
            else [defaults setObject:saved[key] forKey:key];
        }
        [defaults synchronize];
    }
}

- (void)testBlockStatusUsesTheEnforcementBoundary {
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:NSUUID.UUID.UUIDString];
    [schedule setAllowedWindows:@[[SCTimeRange rangeWithStart:@"09:00" end:@"10:00"]] forDay:SCDayOfWeekMonday];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSDateComponents *components = [NSDateComponents new];
    components.year = 2026; components.month = 7; components.day = 13;
    components.hour = 9; components.minute = 30;
    NSDate *inside = [calendar dateFromComponents:components];
    NSString *insideStatus = [schedule currentStatusStringAtDate:inside calendar:calendar policy:SCBundlePolicyBlock];
    components.hour = 8;
    NSString *beforeStatus = [schedule currentStatusStringAtDate:[calendar dateFromComponents:components]
        calendar:calendar policy:SCBundlePolicyBlock];
    XCTAssertTrue([insideStatus containsString:@"10:00"], @"%@", insideStatus);
    XCTAssertTrue([beforeStatus containsString:@"8:59"], @"%@", beforeStatus);
}

- (void)testWindowBoundariesAreHalfOpenAndNextChangeIncludesNextWeek {
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:NSUUID.UUID.UUIDString];
    [schedule setAllowedWindows:@[[SCTimeRange rangeWithStart:@"09:00" end:@"10:00"]] forDay:SCDayOfWeekMonday];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSDateComponents *components = [NSDateComponents new];
    components.year = 2026; components.month = 7; components.day = 13;
    components.hour = 9; components.minute = 0;
    NSDate *start = [calendar dateFromComponents:components];
    components.hour = 10;
    NSDate *end = [calendar dateFromComponents:components];
    components.day = 20; components.hour = 9;
    NSDate *nextWeekStart = [calendar dateFromComponents:components];
    XCTAssertTrue([schedule isAllowedAtDate:start calendar:calendar]);
    XCTAssertFalse([schedule isAllowedAtDate:end calendar:calendar]);
    XCTAssertEqualObjects([schedule nextStateChangeDateAfterDate:start calendar:calendar], end);
    XCTAssertEqualObjects([schedule nextStateChangeDateAfterDate:end calendar:calendar], nextWeekStart);
    XCTAssertEqualObjects([schedule nextStateChangeDateAfterDate:[end dateByAddingTimeInterval:-1] calendar:calendar], end);
    NSString *blockStart = [schedule currentStatusStringAtDate:start calendar:calendar policy:SCBundlePolicyBlock];
    NSString *allowStart = [schedule currentStatusStringAtDate:start calendar:calendar policy:SCBundlePolicyAllow];
    NSString *blockEnd = [schedule currentStatusStringAtDate:end calendar:calendar policy:SCBundlePolicyBlock];
    NSString *allowEnd = [schedule currentStatusStringAtDate:end calendar:calendar policy:SCBundlePolicyAllow];
    XCTAssertTrue([blockStart containsString:@"10:00"], @"%@", blockStart);
    XCTAssertTrue([allowStart containsString:@"9:59"], @"%@", allowStart);
    XCTAssertTrue([blockEnd containsString:@"Mon 8:59"], @"%@", blockEnd);
    XCTAssertTrue([allowEnd containsString:@"Mon 9:00"], @"%@", allowEnd);
}

@end

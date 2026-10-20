//
//  SCDaemonSchedulerTests.m
//  SelfControlTests
//

#import <XCTest/XCTest.h>

#import "SCDaemonScheduler.h"

static NSString * const SCSchedulerTestScheduleID1 = @"00000000-0000-4000-8000-000000000001";
static NSString * const SCSchedulerTestScheduleID2 = @"00000000-0000-4000-8000-000000000002";
static NSString * const SCSchedulerTestScheduleID3 = @"00000000-0000-4000-8000-000000000003";
static NSString * const SCSchedulerTestCommitmentID = @"10000000-0000-4000-8000-000000000001";
static NSString * const SCSchedulerTestGenerationID = @"20000000-0000-4000-8000-000000000001";
static NSString * const SCSchedulerTestPolicyRevisionID = @"30000000-0000-4000-8000-000000000001";
static NSString * const SCSchedulerTestBundleID = @"40000000-0000-4000-8000-000000000001";

static NSDictionary<NSString *, id> *SCSchedulerTestV1Record(uid_t ownerUID,
                                                              NSDate *start,
                                                              NSDate *end) {
    return @{
        @"controllingUID": @(ownerUID),
        @"approvedStartDate": start,
        @"approvedEndDate": end,
        @"blocklist": @[@"example.com"],
        @"blockSettings": @{},
    };
}

static NSDictionary<NSString *, id> *SCSchedulerTestV2Record(uid_t ownerUID,
                                                              NSDate *start,
                                                              NSDate *end) {
    NSMutableDictionary<NSString *, id> *record = [SCSchedulerTestV1Record(ownerUID, start, end) mutableCopy];
    [record addEntriesFromDictionary:@{
        SCDaemonScheduleSchemaVersionKey: @2,
        SCDaemonScheduleWeekKey: @"2026-07-13",
        SCDaemonScheduleCommitmentIDKey: SCSchedulerTestCommitmentID,
        SCDaemonScheduleGenerationKey: SCSchedulerTestGenerationID,
        SCDaemonSchedulePolicyRevisionKey: SCSchedulerTestPolicyRevisionID,
        SCDaemonScheduleSourceBundleIDsKey: @[SCSchedulerTestBundleID],
    }];
    return [record copy];
}

static NSDictionary<NSString *, id> *SCSchedulerTestRecordWithID(NSString *scheduleID,
                                                                  NSDate *start,
                                                                  NSDate *end) {
    NSMutableDictionary<NSString *, id> *record = [SCSchedulerTestV2Record(501, start, end) mutableCopy];
    record[@"scheduleID"] = scheduleID;
    return [record copy];
}

static NSDictionary<NSString *, id> *SCSchedulerTestRecurringCommitment(uid_t ownerUID,
                                                                         NSDate *startedAt,
                                                                         NSDate *lockEndsAt,
                                                                         NSDictionary *protectedHours) {
    return @{
        @"schemaVersion": @1,
        @"commitmentID": SCSchedulerTestCommitmentID,
        @"generation": SCSchedulerTestGenerationID,
        @"controllingUID": @(ownerUID),
        @"startedAt": startedAt,
        @"lockEndsAt": lockEndsAt,
        @"protectedHours": protectedHours,
        @"blockSettings": @{},
        @"segments": @[@{
            @"segmentID": SCSchedulerTestScheduleID1,
            @"startMinuteOfWeek": @(9 * 60),
            @"endMinuteOfWeek": @(10 * 60),
            @"blocklist": @[@"example.com"],
            @"isAllowlist": @NO,
            SCDaemonScheduleSourceBundleIDsKey: @[SCSchedulerTestBundleID],
            SCDaemonSchedulePolicyRevisionKey: SCSchedulerTestPolicyRevisionID,
        }],
    };
}

@interface SCDaemonSchedulerTests : XCTestCase
@end

@implementation SCDaemonSchedulerTests

- (void)testCommitmentAggregateEntryLimitIsOverflowSafeAndInclusive {
    XCTAssertTrue(SCDaemonScheduleEntryCountCanAdd(0, 4096, 4096));
    XCTAssertTrue(SCDaemonScheduleEntryCountCanAdd(4095, 1, 4096));
    XCTAssertFalse(SCDaemonScheduleEntryCountCanAdd(4095, 2, 4096));
    XCTAssertFalse(SCDaemonScheduleEntryCountCanAdd(4097, 0, 4096));
    XCTAssertFalse(SCDaemonScheduleEntryCountCanAdd(NSUIntegerMax, 1, 4096));
}

- (void)testCommitmentAdmissionUsesHalfOpenAbsoluteOverlap {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *boundary = [start dateByAddingTimeInterval:60];
    NSDate *end = [boundary dateByAddingTimeInterval:60];
    XCTAssertFalse(SCDaemonScheduleIntervalsOverlap(start, boundary, boundary, end));
    XCTAssertTrue(SCDaemonScheduleIntervalsOverlap(
        start, boundary, [boundary dateByAddingTimeInterval:-1], end));
    XCTAssertTrue(SCDaemonScheduleIntervalsOverlap(start, end, start, end));
    XCTAssertFalse(SCDaemonScheduleIntervalsOverlap(start, start, start, end));
}

- (void)testFiniteScheduleAdmissionRejectsOnlyTheOwnersRecurringCommitment {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *expiredLockCommitment = SCSchedulerTestRecurringCommitment(
        501,
        [now dateByAddingTimeInterval:-7200],
        [now dateByAddingTimeInterval:-3600],
        @{@"enabled": @NO, @"startMinute": @1380, @"endMinute": @300});
    NSDictionary *store = @{SCSchedulerTestCommitmentID: expiredLockCommitment};

    XCTAssertTrue(SCDaemonScheduleAdmissionConflictsWithRecurringCommitments(store, 501),
        @"The edit-lock deadline does not expire recurring enforcement");
    XCTAssertFalse(SCDaemonScheduleAdmissionConflictsWithRecurringCommitments(store, 502));
    XCTAssertFalse(SCDaemonScheduleAdmissionConflictsWithRecurringCommitments(@[], 501));
}

- (NSMutableDictionary<NSString *, id> *)idleStateAtDate:(NSDate *)now
                                       approvedSchedules:(NSDictionary<NSString *, id> *)approvedSchedules {
    return [@{
        @"settings_available": @YES,
        @"console_uid": @501,
        @"active_owner_uid": @0,
        @"approved_schedules": approvedSchedules,
        @"approved_recurring_commitments": @{},
        @"active_schedule_breaks": @{},
        @"now": now,
        @"block_running": @NO,
        @"active_block_source": @"none",
        @"active_commitment_id": SCSchedulerTestCommitmentID,
        @"active_generation": SCSchedulerTestGenerationID,
        @"active_policy_revision": SCSchedulerTestPolicyRevisionID,
        @"active_blocklist": @[@"example.com"],
        @"active_is_allowlist": @NO,
        @"block_end_date": [NSDate distantFuture],
    } mutableCopy];
}

- (NSCalendar *)utcGregorianCalendar {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    calendar.firstWeekday = 2;
    return calendar;
}

- (NSDate *)dateWithYear:(NSInteger)year month:(NSInteger)month day:(NSInteger)day
                    hour:(NSInteger)hour minute:(NSInteger)minute {
    NSDateComponents *components = [NSDateComponents new];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    return [[self utcGregorianCalendar] dateFromComponents:components];
}

- (NSDictionary<NSString *, id> *)evaluateScheduler:(SCDaemonScheduler *)scheduler
                                             trigger:(NSString *)trigger {
    XCTestExpectation *completionExpectation = [self expectationWithDescription:
        [NSString stringWithFormat:@"%@ evaluation", trigger]];
    __block NSDictionary<NSString *, id> *result = nil;
    [scheduler evaluateForTrigger:trigger completion:^(NSDictionary<NSString *,id> *value) {
        result = value;
        [completionExpectation fulfill];
    }];
    [self waitForExpectations:@[completionExpectation] timeout:1.0];
    return result;
}

- (void)testValidatedRecordsAcceptV1AndV2AndEnforceOwnership {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSMutableDictionary *explicitV1 = [SCSchedulerTestV1Record(501, now,
        [now dateByAddingTimeInterval:210]) mutableCopy];
    explicitV1[SCDaemonScheduleSchemaVersionKey] = @1;
    NSMutableDictionary *stringSchema = [SCSchedulerTestV1Record(501, now,
        [now dateByAddingTimeInterval:330]) mutableCopy];
    stringSchema[SCDaemonScheduleSchemaVersionKey] = @"2";
    NSMutableDictionary *unsupportedSchema = [SCSchedulerTestV2Record(501, now,
        [now dateByAddingTimeInterval:360]) mutableCopy];
    unsupportedSchema[SCDaemonScheduleSchemaVersionKey] = @3;
    NSDictionary *approvedSchedules = @{
        SCSchedulerTestScheduleID1: SCSchedulerTestV1Record(501, now, [now dateByAddingTimeInterval:60]),
        SCSchedulerTestScheduleID2: SCSchedulerTestV2Record(501, now, [now dateByAddingTimeInterval:120]),
        SCSchedulerTestScheduleID3: SCSchedulerTestV1Record(502, now, [now dateByAddingTimeInterval:180]),
        @"not-a-uuid": SCSchedulerTestV1Record(501, now, [now dateByAddingTimeInterval:240]),
        @"00000000-0000-4000-8000-000000000004": @{
            @"controllingUID": @501,
            @"approvedStartDate": now,
            @"approvedEndDate": [now dateByAddingTimeInterval:300],
            @"blocklist": @[@"example.com"],
            @"blockSettings": @{},
            SCDaemonScheduleSchemaVersionKey: @2,
        },
        @"00000000-0000-4000-8000-000000000005": explicitV1,
        @"00000000-0000-4000-8000-000000000006": stringSchema,
        @"00000000-0000-4000-8000-000000000007": unsupportedSchema,
    };

    NSArray<NSDictionary<NSString *, id> *> *owned =
        [SCDaemonScheduler validScheduleRecordsFromApprovedSchedules:approvedSchedules ownerUID:501];
    XCTAssertEqual(owned.count, 3U);
    XCTAssertEqualObjects([owned valueForKey:@"scheduleID"],
                          (@[SCSchedulerTestScheduleID1, SCSchedulerTestScheduleID2,
                             @"00000000-0000-4000-8000-000000000005"]));

    NSArray<NSDictionary<NSString *, id> *> *prelogin =
        [SCDaemonScheduler validScheduleRecordsFromApprovedSchedules:approvedSchedules ownerUID:0];
    XCTAssertEqual(prelogin.count, 4U);
    XCTAssertEqualObjects([prelogin valueForKey:@"scheduleID"],
                          (@[SCSchedulerTestScheduleID1, SCSchedulerTestScheduleID2,
                             SCSchedulerTestScheduleID3,
                             @"00000000-0000-4000-8000-000000000005"]));
    XCTAssertEqual([SCDaemonScheduler validScheduleRecordsFromApprovedSchedules:@[] ownerUID:501].count, 0U);
}

- (void)testV2RecordMissingRequiredEnvelopeFieldsIsRejected {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *approvedSchedules = @{
        SCSchedulerTestScheduleID1: @{
            @"controllingUID": @501,
            @"approvedStartDate": now,
            @"approvedEndDate": [now dateByAddingTimeInterval:300],
            @"blocklist": @[@"example.com"],
            @"blockSettings": @{},
            SCDaemonScheduleSchemaVersionKey: @2,
        },
    };
    XCTAssertEqual([SCDaemonScheduler validScheduleRecordsFromApprovedSchedules:approvedSchedules
                                                                        ownerUID:501].count, 0U);
}

- (void)testRecurringCommitmentMaterializesAcrossLocalWeeksAfterLockExpiry {
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30]; // Monday
    NSDate *startedAt = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSDate *lockEndsAt = [self dateWithYear:2026 month:7 day:2 hour:9 minute:0];
    NSDictionary *commitment = SCSchedulerTestRecurringCommitment(501, startedAt, lockEndsAt, @{
        @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
    });
    NSArray *valid = [SCDaemonScheduler validRecurringCommitmentsFromValue:@{
        SCSchedulerTestCommitmentID: commitment,
    } ownerUID:501];
    XCTAssertEqual(valid.count, 1U);
    NSArray *foreignOwner = [SCDaemonScheduler validRecurringCommitmentsFromValue:@{
        SCSchedulerTestCommitmentID: commitment,
    } ownerUID:502];
    XCTAssertEqual(foreignOwner.count, 0U);

    NSArray *occurrences = [SCDaemonScheduler recurringOccurrenceRecordsAtDate:now
                                                                    commitments:valid
                                                                        calendar:[self utcGregorianCalendar]];
    XCTAssertEqual(occurrences.count, 3U);
    NSDictionary *desired = [SCDaemonScheduler desiredScheduleRecordAtDate:now records:occurrences];
    XCTAssertEqualObjects(desired[@"scheduleID"], SCSchedulerTestScheduleID1);
    XCTAssertEqualObjects(desired[SCDaemonScheduleSchemaVersionKey], @3);
    XCTAssertEqualObjects(desired[SCDaemonScheduleCommitmentIDKey], SCSchedulerTestCommitmentID);
    XCTAssertEqualObjects(desired[@"approvedStartDate"],
                          [self dateWithYear:2026 month:7 day:13 hour:9 minute:0]);
    XCTAssertEqualObjects(desired[@"approvedEndDate"],
                          [self dateWithYear:2026 month:7 day:13 hour:10 minute:0]);
    XCTAssertTrue([lockEndsAt compare:now] == NSOrderedAscending,
                  @"The elapsed edit lock must not remove recurring enforcement occurrences");
}

- (void)testRecurringBundleAppendPreservesOtherSegmentsAndAllMetadata {
    NSDate *startedAt = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSMutableDictionary *original = [SCSchedulerTestRecurringCommitment(501, startedAt,
        [startedAt dateByAddingTimeInterval:86400], @{
            @"enabled": @YES, @"startMinute": @1380, @"endMinute": @300,
        }) mutableCopy];
    original[SCDaemonRecurringTimeZoneIdentifierKey] = @"Europe/London";
    original[SCDaemonRecurringFollowsLocationTimeZoneKey] = @YES;
    NSDictionary *first = [original[@"segments"] firstObject];
    NSMutableDictionary *other = [first mutableCopy];
    other[@"segmentID"] = SCSchedulerTestScheduleID2;
    other[@"startMinuteOfWeek"] = @600;
    other[@"endMinuteOfWeek"] = @660;
    other[@"blocklist"] = @[@"other.example"];
    other[SCDaemonScheduleSourceBundleIDsKey] = @[SCSchedulerTestScheduleID3];
    NSMutableDictionary *overlap = [first mutableCopy];
    overlap[@"segmentID"] = SCSchedulerTestScheduleID3;
    overlap[@"startMinuteOfWeek"] = @660;
    overlap[@"endMinuteOfWeek"] = @720;
    overlap[@"blocklist"] = @[@"example.com", @"other.example"];
    overlap[SCDaemonScheduleSourceBundleIDsKey] = @[SCSchedulerTestBundleID, SCSchedulerTestScheduleID3];
    original[@"segments"] = @[first, other, overlap];
    NSArray *additions = @[@"new.example", @"app:com.apple.Calculator", @"new.example"];
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original appendingEntries:additions
        forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    XCTAssertNotNil(updated);
    for (NSString *key in original) {
        if (![key isEqual:@"segments"]) XCTAssertEqualObjects(updated[key], original[key]);
    }
    NSArray *updatedSegments = updated[@"segments"];
    XCTAssertEqualObjects(updatedSegments[1], other);
    XCTAssertEqualObjects(updatedSegments[0][@"blocklist"],
        (@[@"example.com", @"new.example", @"app:com.apple.Calculator"]));
    XCTAssertEqualObjects(updatedSegments[2][@"blocklist"],
        (@[@"example.com", @"other.example", @"new.example", @"app:com.apple.Calculator"]));
    for (NSUInteger index = 0; index < updatedSegments.count; index++) {
        NSDictionary *before = original[@"segments"][index];
        for (NSString *key in before) {
            if (![key isEqual:@"blocklist"]) XCTAssertEqualObjects(updatedSegments[index][key], before[key]);
        }
    }
    XCTAssertEqualObjects(first[@"blocklist"], (@[@"example.com"]), @"No in-place root mutation");
    XCTAssertEqualObjects(updated, [SCDaemonScheduler recurringCommitment:updated appendingEntries:additions
        forBundleID:SCSchedulerTestBundleID maximumEntries:4096], @"Exact retry is idempotent");
}

- (void)testRecurringBundleAppendRejectsUnknownBundleAndOversizedOrInvalidRecords {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *original = SCSchedulerTestRecurringCommitment(501, start,
        [start dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        });
    XCTAssertNil([SCDaemonScheduler recurringCommitment:original appendingEntries:@[@"new.example"]
        forBundleID:SCSchedulerTestScheduleID3 maximumEntries:4096]);
    XCTAssertNil([SCDaemonScheduler recurringCommitment:original appendingEntries:@[@"new.example"]
        forBundleID:SCSchedulerTestBundleID maximumEntries:1]);
    XCTAssertNil([SCDaemonScheduler recurringCommitment:original appendingEntries:@[]
        forBundleID:SCSchedulerTestBundleID maximumEntries:4096]);
    NSMutableDictionary *invalid = [original mutableCopy];
    NSMutableDictionary *segment = [[original[@"segments"] firstObject] mutableCopy];
    segment[@"isAllowlist"] = @YES;
    invalid[@"segments"] = @[segment];
    XCTAssertNil([SCDaemonScheduler recurringCommitment:invalid appendingEntries:@[@"new.example"]
        forBundleID:SCSchedulerTestBundleID maximumEntries:4096]);
}

- (void)testRecurringBundleAppendSurvivesPropertyListRoundTripAndFutureWeeks {
    NSDate *start = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSDictionary *original = SCSchedulerTestRecurringCommitment(501, start,
        [start dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        });
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        appendingEntries:@[@"new.example"] forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{SCSchedulerTestCommitmentID: updated}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    XCTAssertNil(error);
    NSDictionary *restored = [NSPropertyListSerialization propertyListWithData:data options:0
        format:NULL error:&error];
    XCTAssertNil(error);
    NSArray *valid = [SCDaemonScheduler validRecurringCommitmentsFromValue:restored ownerUID:501];
    XCTAssertEqualObjects(valid.firstObject, updated);
    for (NSInteger day = 13; day <= 27; day += 7) {
        NSDate *now = [self dateWithYear:2026 month:7 day:day hour:9 minute:30];
        NSArray *records = [SCDaemonScheduler recurringOccurrenceRecordsAtDate:now commitments:valid
            calendar:[self utcGregorianCalendar]];
        NSDictionary *desired = [SCDaemonScheduler desiredScheduleRecordAtDate:now records:records];
        XCTAssertEqualObjects(desired[@"blocklist"], (@[@"example.com", @"new.example"]));
        NSDate *allowed = [self dateWithYear:2026 month:7 day:day hour:10 minute:0];
        XCTAssertNil([SCDaemonScheduler desiredScheduleRecordAtDate:allowed records:records]);
    }
}

- (void)testRecurringBundleAppendDoesNotEndBreakAndResumesWithAddedEntries {
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:9 minute:15];
    NSMutableDictionary *original = [SCSchedulerTestRecurringCommitment(501,
        [now dateByAddingTimeInterval:-86400], [now dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        }) mutableCopy];
    original[SCDaemonRecurringTimeZoneIdentifierKey] = @"UTC";
    original[SCDaemonRecurringFollowsLocationTimeZoneKey] = @NO;
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        appendingEntries:@[@"new.example"] forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    NSDate *endsAt = [now dateByAddingTimeInterval:15 * 60];
    NSDictionary *breaks = @{SCSchedulerTestCommitmentID: @{
        @"schemaVersion": @1, @"commitmentID": SCSchedulerTestCommitmentID,
        @"generation": SCSchedulerTestGenerationID, @"controllingUID": @501,
        @"startedAt": now, @"endsAt": endsAt,
    }};
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{}];
    state[@"approved_recurring_commitments"] = @{SCSchedulerTestCommitmentID: updated};
    state[@"active_schedule_breaks"] = breaks;
    __block NSUInteger applies = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *, id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *, id> *record,
                           void (^completion)(NSError *)) {
            applies += 1;
            XCTAssertEqualObjects(record[@"blocklist"], (@[@"example.com", @"new.example"]));
            completion(nil);
        } endHandler:^(void (^completion)(NSError *)) {
            XCTFail(@"A bundle addition must not cancel the timed break");
            completion(nil);
        } anomalyHandler:nil];
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"mutation"][@"status"], @"verified");
    XCTAssertEqual(applies, 0U);
    XCTAssertEqualObjects(state[@"active_schedule_breaks"], breaks);
    state[@"now"] = endsAt;
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"timer"][@"status"], @"verified");
    XCTAssertEqual(applies, 1U);
}

- (void)testRecurringBundleAppendRequiresCouplingBeforeStaleOccurrenceVerifies {
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:9 minute:15];
    NSMutableDictionary *original = [SCSchedulerTestRecurringCommitment(501,
        [now dateByAddingTimeInterval:-86400], [now dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        }) mutableCopy];
    original[SCDaemonRecurringTimeZoneIdentifierKey] = @"UTC";
    original[SCDaemonRecurringFollowsLocationTimeZoneKey] = @NO;
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        appendingEntries:@[@"new.example"] forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    NSDictionary *record = [SCDaemonScheduler desiredScheduleRecordAtDate:now
        records:[SCDaemonScheduler recurringOccurrenceRecordsAtDate:now commitments:@[original]
            calendar:[self utcGregorianCalendar]]];
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{}];
    [state addEntriesFromDictionary:@{
        @"approved_recurring_commitments": @{SCSchedulerTestCommitmentID: updated},
        @"block_running": @YES, @"block_end_date": record[@"approvedEndDate"],
        @"active_block_source": SCDaemonActiveBlockSourceSchedulerRecurring,
        @"active_schedule_id": record[@"scheduleID"],
        @"active_commitment_id": SCSchedulerTestCommitmentID,
        @"active_generation": SCSchedulerTestGenerationID,
        @"active_policy_revision": SCSchedulerTestPolicyRevisionID,
        @"active_owner_uid": @501, @"active_is_allowlist": @NO,
        @"active_blocklist": @[@"example.com"],
    }];
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *, id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *, id> *desired,
                           void (^completion)(NSError *)) {
            XCTFail(@"The scheduler must not replace a running policy");
            completion(nil);
        } endHandler:^(void (^completion)(NSError *)) {
            XCTFail(@"A stricter append must never tear down the running block");
            completion(nil);
        } anomalyHandler:nil];
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"mutation"][@"status"], @"deferred");
    // This is the active-settings postcondition of the daemon's additive
    // physical coupling, after a stale pre-mutation start has completed.
    state[@"active_blocklist"] = [updated[@"segments"] firstObject][@"blocklist"];
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"mutation"][@"status"], @"verified");
}

- (void)testRecurringTimeZoneFieldsAcceptLegacyAndCompleteValidPairsOnly {
    NSDate *startedAt = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSDictionary *legacyCommitment = SCSchedulerTestRecurringCommitment(501, startedAt,
        [startedAt dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        });
    NSDictionary *(^storeForCommitment)(NSDictionary *) = ^NSDictionary *(NSDictionary *commitment) {
        return @{SCSchedulerTestCommitmentID: commitment};
    };

    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(legacyCommitment) ownerUID:501].count, 1U,
        @"Records shipped before the additive timezone fields must remain readable for startup pinning");

    NSMutableDictionary *fixedCommitment = [legacyCommitment mutableCopy];
    fixedCommitment[SCDaemonRecurringTimeZoneIdentifierKey] = @"Europe/London";
    fixedCommitment[SCDaemonRecurringFollowsLocationTimeZoneKey] = @NO;
    NSArray *validFixed = [SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(fixedCommitment) ownerUID:501];
    XCTAssertEqual(validFixed.count, 1U);
    XCTAssertEqualObjects(validFixed.firstObject[SCDaemonRecurringTimeZoneIdentifierKey],
                          @"Europe/London");
    XCTAssertEqualObjects(validFixed.firstObject[SCDaemonRecurringFollowsLocationTimeZoneKey], @NO);

    NSMutableDictionary *automaticCommitment = [fixedCommitment mutableCopy];
    automaticCommitment[SCDaemonRecurringFollowsLocationTimeZoneKey] = @YES;
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(automaticCommitment) ownerUID:501].count, 1U);

    NSMutableDictionary *missingMode = [legacyCommitment mutableCopy];
    missingMode[SCDaemonRecurringTimeZoneIdentifierKey] = @"Europe/London";
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(missingMode) ownerUID:501].count, 0U);

    NSMutableDictionary *missingIdentifier = [legacyCommitment mutableCopy];
    missingIdentifier[SCDaemonRecurringFollowsLocationTimeZoneKey] = @YES;
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(missingIdentifier) ownerUID:501].count, 0U);

    NSMutableDictionary *invalidIdentifier = [fixedCommitment mutableCopy];
    invalidIdentifier[SCDaemonRecurringTimeZoneIdentifierKey] = @"Mars/Olympus_Mons";
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(invalidIdentifier) ownerUID:501].count, 0U);

    NSMutableDictionary *nonBooleanMode = [fixedCommitment mutableCopy];
    nonBooleanMode[SCDaemonRecurringFollowsLocationTimeZoneKey] = @1;
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:
        storeForCommitment(nonBooleanMode) ownerUID:501].count, 0U);
}

- (void)testStoredRecurringTimeZoneIgnoresChangedLiveFallback {
    NSDate *startedAt = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSMutableDictionary *commitment = [SCSchedulerTestRecurringCommitment(501, startedAt,
        [startedAt dateByAddingTimeInterval:86400], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        }) mutableCopy];
    commitment[SCDaemonRecurringTimeZoneIdentifierKey] = @"Europe/London";
    commitment[SCDaemonRecurringFollowsLocationTimeZoneKey] = @NO;

    NSCalendar *withHonoluluFallback = [SCDaemonScheduler
        calendarForRecurringCommitment:commitment
                    fallbackTimeZone:[NSTimeZone timeZoneWithName:@"Pacific/Honolulu"]];
    NSCalendar *withTokyoFallback = [SCDaemonScheduler
        calendarForRecurringCommitment:commitment
                    fallbackTimeZone:[NSTimeZone timeZoneWithName:@"Asia/Tokyo"]];
    XCTAssertEqualObjects(withHonoluluFallback.timeZone.name, @"Europe/London");
    XCTAssertEqualObjects(withTokyoFallback.timeZone.name, @"Europe/London");

    // 08:30 UTC is 09:30 in London during British Summer Time. A live
    // Honolulu or Tokyo timezone would not select this Monday 09:00 segment.
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:8 minute:30];
    NSArray *honoluluFallbackOccurrences = [SCDaemonScheduler
        recurringOccurrenceRecordsAtDate:now commitments:@[commitment]
                                calendar:withHonoluluFallback];
    NSArray *tokyoFallbackOccurrences = [SCDaemonScheduler
        recurringOccurrenceRecordsAtDate:now commitments:@[commitment]
                                calendar:withTokyoFallback];
    NSDictionary *honoluluFallbackDesired = [SCDaemonScheduler desiredScheduleRecordAtDate:now
        records:honoluluFallbackOccurrences];
    NSDictionary *tokyoFallbackDesired = [SCDaemonScheduler desiredScheduleRecordAtDate:now
        records:tokyoFallbackOccurrences];
    XCTAssertNotNil(honoluluFallbackDesired);
    XCTAssertEqualObjects(honoluluFallbackDesired[@"approvedStartDate"],
                          [self dateWithYear:2026 month:7 day:13 hour:8 minute:0]);
    XCTAssertEqualObjects(honoluluFallbackDesired[@"approvedEndDate"],
                          [self dateWithYear:2026 month:7 day:13 hour:9 minute:0]);
    XCTAssertEqualObjects(tokyoFallbackDesired[@"approvedStartDate"],
                          honoluluFallbackDesired[@"approvedStartDate"]);
    XCTAssertEqualObjects(tokyoFallbackDesired[@"approvedEndDate"],
                          honoluluFallbackDesired[@"approvedEndDate"]);
}

- (void)testProtectedHoursAndTimedBreakUseHalfOpenRuntimeTransitions {
    NSCalendar *calendar = [self utcGregorianCalendar];
    NSDate *startedAt = [self dateWithYear:2026 month:7 day:1 hour:9 minute:0];
    NSDictionary *commitment = SCSchedulerTestRecurringCommitment(501, startedAt,
        [startedAt dateByAddingTimeInterval:86400], @{
            @"enabled": @YES, @"startMinute": @1380, @"endMinute": @300,
        });
    NSDate *atStart = [self dateWithYear:2026 month:7 day:13 hour:23 minute:0];
    NSDate *beforeEnd = [self dateWithYear:2026 month:7 day:14 hour:4 minute:59];
    NSDate *atEnd = [self dateWithYear:2026 month:7 day:14 hour:5 minute:0];
    XCTAssertTrue([SCDaemonScheduler protectedHoursAreActiveAtDate:atStart
                                                        commitment:commitment calendar:calendar]);
    XCTAssertTrue([SCDaemonScheduler protectedHoursAreActiveAtDate:beforeEnd
                                                        commitment:commitment calendar:calendar]);
    XCTAssertFalse([SCDaemonScheduler protectedHoursAreActiveAtDate:atEnd
                                                         commitment:commitment calendar:calendar]);
    XCTAssertEqualObjects([SCDaemonScheduler nextProtectedHoursBoundaryAfterDate:atStart
                                                                       commitment:commitment
                                                                          calendar:calendar], atEnd);
    XCTAssertFalse([SCDaemonScheduler protectedHoursEditLockIsActiveAtDate:
        [self dateWithYear:2026 month:7 day:13 hour:20 minute:59]
                                                               commitment:commitment calendar:calendar]);
    XCTAssertTrue([SCDaemonScheduler protectedHoursEditLockIsActiveAtDate:
        [self dateWithYear:2026 month:7 day:13 hour:21 minute:0]
                                                              commitment:commitment calendar:calendar]);
    XCTAssertFalse([SCDaemonScheduler protectedHoursEditLockIsActiveAtDate:atEnd
                                                               commitment:commitment calendar:calendar]);

    NSDictionary *almostAllDay = SCSchedulerTestRecurringCommitment(501, startedAt,
        [startedAt dateByAddingTimeInterval:86400], @{
            @"enabled": @YES, @"startMinute": @0, @"endMinute": @(23 * 60),
        });
    XCTAssertTrue([SCDaemonScheduler protectedHoursEditLockIsActiveAtDate:
        [self dateWithYear:2026 month:7 day:13 hour:12 minute:0]
                                                              commitment:almostAllDay calendar:calendar]);

    NSDate *breakStart = [self dateWithYear:2026 month:7 day:13 hour:9 minute:15];
    NSDate *breakEnd = [breakStart dateByAddingTimeInterval:15 * 60];
    NSDictionary *activeBreaks = @{SCSchedulerTestCommitmentID: @{
        @"schemaVersion": @1,
        @"commitmentID": SCSchedulerTestCommitmentID,
        @"generation": SCSchedulerTestGenerationID,
        @"controllingUID": @501,
        @"startedAt": breakStart,
        @"endsAt": breakEnd,
    }};
    XCTAssertNotNil([SCDaemonScheduler activeBreakAtDate:breakStart value:activeBreaks
                                                 ownerUID:501 commitment:commitment]);
    XCTAssertNil([SCDaemonScheduler activeBreakAtDate:breakEnd value:activeBreaks
                                              ownerUID:501 commitment:commitment]);
    XCTAssertNil([SCDaemonScheduler activeBreakAtDate:breakStart value:activeBreaks
                                              ownerUID:502 commitment:commitment]);
}

- (NSDictionary *)calendarCommitmentAtDate:(NSDate *)date {
    NSMutableDictionary *commitment = [SCSchedulerTestRecurringCommitment(501,
        [date dateByAddingTimeInterval:-86400], [date dateByAddingTimeInterval:-1],
        @{@"enabled": @NO, @"startMinute": @1380, @"endMinute": @300}) mutableCopy];
    commitment[SCDaemonRecurringTimeZoneIdentifierKey] = @"UTC";
    commitment[SCDaemonRecurringFollowsLocationTimeZoneKey] = @NO;
    NSMutableDictionary *segment = [commitment[@"segments"][0] mutableCopy];
    segment[@"endMinuteOfWeek"] = @720;
    commitment[@"segments"] = @[segment];
    return [commitment copy];
}

- (NSArray *)splitCalendarSegmentsForCommitment:(NSDictionary *)commitment {
    NSMutableArray *segments = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        NSMutableDictionary *segment = [commitment[@"segments"][0] mutableCopy];
        segment[@"segmentID"] = NSUUID.UUID.UUIDString;
        segment[SCDaemonSchedulePolicyRevisionKey] = NSUUID.UUID.UUIDString;
        segment[@"startMinuteOfWeek"] = @(540 + 60 * index);
        segment[@"endMinuteOfWeek"] = @(600 + 60 * index);
        if (index == 1) {
            segment[@"blocklist"] = @[@"example.com", @"added.example"];
            segment[SCDaemonScheduleSourceBundleIDsKey] = @[SCSchedulerTestBundleID, SCSchedulerTestScheduleID3];
        }
        [segments addObject:[segment copy]];
    }
    return [segments copy];
}

- (void)testCalendarStrictificationPreservesEnvelopeAndExpiredButSurvivingCommitment {
    NSDate *date = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSDictionary *original = [self calendarCommitmentAtDate:date];
    NSArray *segments = [self splitCalendarSegmentsForCommitment:original];
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        strictifyingSegments:segments maximumEntries:4096];
    XCTAssertNotNil(updated);
    for (NSString *key in original) {
        if (![key isEqual:@"segments"]) XCTAssertEqualObjects(updated[key], original[key]);
    }
    XCTAssertEqualObjects(updated[@"segments"], segments);
    XCTAssertEqual([original[@"segments"] count], 1U, @"No in-place mutation of the root record");
    XCTAssertEqualObjects(updated, [SCDaemonScheduler recurringCommitment:updated
        strictifyingSegments:segments maximumEntries:4096], @"Exact retries remain valid");
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:updated
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSDictionary *restored = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil];
    XCTAssertEqualObjects(restored, updated);
    NSDate *nextWeek = [date dateByAddingTimeInterval:7 * 86400 + 3600];
    XCTAssertEqualObjects([SCDaemonScheduler recurringRecordAtDate:nextWeek commitment:restored
        activeBreaks:@{}][@"blocklist"], (@[@"example.com", @"added.example"]));
}

- (void)testCalendarStrictificationRejectsLostMinutesEntriesSourcesAndInvalidLimits {
    NSDate *date = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSDictionary *original = [self calendarCommitmentAtDate:date];
    NSArray *segments = [self splitCalendarSegmentsForCommitment:original];
    for (NSDictionary *change in @[
        @{@"startMinuteOfWeek": @601}, // one uncovered minute
        @{@"blocklist": @[@"added.example"]},
        @{SCDaemonScheduleSourceBundleIDsKey: @[SCSchedulerTestScheduleID3]},
        @{@"startMinuteOfWeek": @599}, // overlap
        @{@"isAllowlist": @YES},
        @{@"segmentID": segments[0][@"segmentID"]},
    ]) {
        NSMutableArray *candidate = [segments mutableCopy];
        NSMutableDictionary *middle = [candidate[1] mutableCopy];
        [middle addEntriesFromDictionary:change];
        candidate[1] = middle;
        XCTAssertNil([SCDaemonScheduler recurringCommitment:original
            strictifyingSegments:candidate maximumEntries:4096], @"Rejected %@", change);
    }
    XCTAssertNil([SCDaemonScheduler recurringCommitment:original strictifyingSegments:@[] maximumEntries:4096]);
    XCTAssertNil([SCDaemonScheduler recurringCommitment:original strictifyingSegments:segments maximumEntries:3]);
    XCTAssertNotNil([SCDaemonScheduler recurringCommitment:original strictifyingSegments:segments maximumEntries:4]);
}

- (void)testCalendarStrictificationRejectsStaleProposalAfterConcurrentBundleAddition {
    NSDate *date = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSDictionary *original = [self calendarCommitmentAtDate:date];
    NSArray *stale = [self splitCalendarSegmentsForCommitment:original];
    NSDictionary *current = [SCDaemonScheduler recurringCommitment:original
        appendingEntries:@[@"concurrent.example"] forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    XCTAssertNil([SCDaemonScheduler recurringCommitment:current strictifyingSegments:stale maximumEntries:4096]);
    XCTAssertTrue([current[@"segments"][0][@"blocklist"] containsObject:@"concurrent.example"]);
}

- (void)testCalendarCurrentRootResolverRejectsStaleOccurrenceAndPreservesBreak {
    NSDate *date = [self dateWithYear:2026 month:7 day:13 hour:10 minute:15];
    NSDictionary *original = [self calendarCommitmentAtDate:date];
    NSDictionary *stale = [SCDaemonScheduler recurringRecordAtDate:date commitment:original activeBreaks:@{}];
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        strictifyingSegments:[self splitCalendarSegmentsForCommitment:original] maximumEntries:4096];
    NSDictionary *current = [SCDaemonScheduler recurringRecordAtDate:date commitment:updated activeBreaks:@{}];
    XCTAssertNotEqualObjects(stale[@"scheduleID"], current[@"scheduleID"]);
    XCTAssertNotEqualObjects(stale[@"approvedEndDate"], current[@"approvedEndDate"]);
    XCTAssertEqualObjects(current[@"blocklist"], (@[@"example.com", @"added.example"]));
    NSDictionary *breaks = @{SCSchedulerTestCommitmentID: @{
        @"schemaVersion": @1, @"commitmentID": SCSchedulerTestCommitmentID,
        @"generation": SCSchedulerTestGenerationID, @"controllingUID": @501,
        @"startedAt": [date dateByAddingTimeInterval:-60], @"endsAt": [date dateByAddingTimeInterval:60],
    }};
    XCTAssertNil([SCDaemonScheduler recurringRecordAtDate:date commitment:updated activeBreaks:breaks]);
    XCTAssertNotNil([SCDaemonScheduler recurringRecordAtDate:[date dateByAddingTimeInterval:60]
        commitment:updated activeBreaks:breaks]);
    NSMutableDictionary *protected = [updated mutableCopy];
    protected[@"protectedHours"] = @{@"enabled": @YES, @"startMinute": @600, @"endMinute": @660};
    XCTAssertNotNil([SCDaemonScheduler recurringRecordAtDate:date commitment:protected activeBreaks:breaks]);
}

- (void)testCalendarSplitBoundariesUseApprovedEndTurnoverAndNeverEarlyTeardown {
    NSDate *date = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSDictionary *original = [self calendarCommitmentAtDate:date];
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original
        strictifyingSegments:[self splitCalendarSegmentsForCommitment:original] maximumEntries:4096];
    NSDictionary *first = [SCDaemonScheduler recurringRecordAtDate:date commitment:updated activeBreaks:@{}];
    NSMutableDictionary *state = [self idleStateAtDate:date approvedSchedules:@{}];
    [state addEntriesFromDictionary:@{
        @"approved_recurring_commitments": @{SCSchedulerTestCommitmentID: updated},
        @"block_running": @YES, @"active_owner_uid": @501,
        @"active_block_source": SCDaemonActiveBlockSourceSchedulerRecurring,
        @"active_schedule_id": first[@"scheduleID"],
        @"active_policy_revision": first[SCDaemonSchedulePolicyRevisionKey],
        @"block_end_date": first[@"approvedEndDate"],
    }];
    __block NSUInteger ends = 0;
    __block NSUInteger starts = 0;
    __block BOOL failEnd = NO;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary *record, void (^completion)(NSError *)) {
            starts++;
            state[@"block_running"] = @YES;
            state[@"active_schedule_id"] = scheduleID;
            state[@"active_policy_revision"] = record[SCDaemonSchedulePolicyRevisionKey];
            state[@"block_end_date"] = record[@"approvedEndDate"];
            state[@"active_blocklist"] = record[@"blocklist"];
            completion(nil);
        } endHandler:^(void (^completion)(NSError *)) {
            ends++;
            if (failEnd) {
                completion([NSError errorWithDomain:@"test" code:1 userInfo:nil]);
                return;
            }
            state[@"block_running"] = @NO;
            completion(nil);
        } anomalyHandler:nil];
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"mutation"][@"status"], @"verified");
    XCTAssertEqual(ends, 0U);
    state[@"now"] = [self dateWithYear:2026 month:7 day:13 hour:10 minute:0];
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"timer"][@"status"], @"verified");
    XCTAssertEqual(ends, 1U);
    XCTAssertEqual(starts, 1U);
    XCTAssertEqualObjects(state[@"active_blocklist"], (@[@"example.com", @"added.example"]));
    state[@"now"] = [self dateWithYear:2026 month:7 day:13 hour:11 minute:0];
    failEnd = YES;
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"timer"][@"status"], @"failed");
    XCTAssertEqual(starts, 1U, @"Failed teardown never starts a replacement");
    failEnd = NO;
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"timer"][@"status"], @"verified");
    XCTAssertEqual(starts, 2U);
    XCTAssertEqualObjects(state[@"active_blocklist"], (@[@"example.com"]));
}

- (void)testRecurringActiveMatchRequiresRecurringProvenanceAndOccurrenceEnd {
    NSDate *start = [self dateWithYear:2026 month:7 day:13 hour:9 minute:0];
    NSDictionary *commitment = SCSchedulerTestRecurringCommitment(501,
        [start dateByAddingTimeInterval:-86400], [start dateByAddingTimeInterval:-1], @{
            @"enabled": @NO, @"startMinute": @1380, @"endMinute": @300,
        });
    NSDictionary *record = [SCDaemonScheduler recurringOccurrenceRecordsAtDate:start
                                                                     commitments:@[commitment]
                                                                         calendar:[self utcGregorianCalendar]][1];
    NSMutableDictionary *state = [@{
        @"block_running": @YES,
        @"block_end_date": record[@"approvedEndDate"],
        @"active_block_source": SCDaemonActiveBlockSourceSchedulerRecurring,
        @"active_schedule_id": record[@"scheduleID"],
        @"active_commitment_id": SCSchedulerTestCommitmentID,
        @"active_generation": SCSchedulerTestGenerationID,
        @"active_policy_revision": SCSchedulerTestPolicyRevisionID,
        @"active_blocklist": @[@"example.com"],
        @"active_is_allowlist": @NO,
        @"active_owner_uid": @501,
    } mutableCopy];
    XCTAssertTrue([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerV2;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerRecurring;
    state[@"block_end_date"] = [record[@"approvedEndDate"] dateByAddingTimeInterval:60];
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
}

- (void)testSelectionUsesHalfOpenIntervalsAndFindsStrictlyFutureBoundaries {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *handoff = [start dateByAddingTimeInterval:60];
    NSDate *end = [handoff dateByAddingTimeInterval:60];
    NSArray *records = @[
        SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID1, start, handoff),
        SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID2, handoff, end),
    ];

    XCTAssertNil([SCDaemonScheduler desiredScheduleRecordAtDate:[start dateByAddingTimeInterval:-1]
                                                         records:records]);
    XCTAssertEqualObjects([SCDaemonScheduler desiredScheduleRecordAtDate:start records:records][@"scheduleID"],
                          SCSchedulerTestScheduleID1);
    XCTAssertEqualObjects([SCDaemonScheduler desiredScheduleRecordAtDate:handoff records:records][@"scheduleID"],
                          SCSchedulerTestScheduleID2);
    XCTAssertNil([SCDaemonScheduler desiredScheduleRecordAtDate:end records:records]);

    XCTAssertEqualObjects([SCDaemonScheduler nextBoundaryAfterDate:[start dateByAddingTimeInterval:-1]
                                                            records:records], start);
    XCTAssertEqualObjects([SCDaemonScheduler nextBoundaryAfterDate:start records:records], handoff);
    XCTAssertEqualObjects([SCDaemonScheduler nextBoundaryAfterDate:handoff records:records], end);
    XCTAssertNil([SCDaemonScheduler nextBoundaryAfterDate:end records:records]);
}

- (void)testOverlapSelectionPrefersLatestStartThenLexicographicallyLowestID {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *laterStart = [start dateByAddingTimeInterval:10];
    NSDate *end = [start dateByAddingTimeInterval:120];
    NSDictionary *early = SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID1, start, end);
    NSDictionary *laterHighID = SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID3, laterStart, end);
    NSDictionary *laterLowID = SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID2, laterStart, end);

    NSDictionary *desired = [SCDaemonScheduler desiredScheduleRecordAtDate:[laterStart dateByAddingTimeInterval:1]
                                                                    records:@[early, laterHighID, laterLowID]];
    XCTAssertEqualObjects(desired[@"scheduleID"], SCSchedulerTestScheduleID2);
}

- (void)testActiveMatchRequiresScheduleOwnershipIDAndPolicyRevision {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *record = SCSchedulerTestRecordWithID(SCSchedulerTestScheduleID1,
                                                       start,
                                                       [start dateByAddingTimeInterval:60]);
    NSMutableDictionary *state = [@{
        @"block_running": @YES,
        @"active_block_source": SCDaemonActiveBlockSourceSchedulerV2,
        @"active_schedule_id": SCSchedulerTestScheduleID1,
        @"active_commitment_id": SCSchedulerTestCommitmentID,
        @"active_generation": SCSchedulerTestGenerationID,
        @"active_policy_revision": SCSchedulerTestPolicyRevisionID,
        @"active_blocklist": @[@"example.com"],
        @"active_is_allowlist": @NO,
    } mutableCopy];
    XCTAssertTrue([SCDaemonScheduler activeState:state matchesRecord:record]);

    state[@"active_blocklist"] = @[@"example.com", @"strictly-more.example"];
    XCTAssertTrue([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_blocklist"] = @[];
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_blocklist"] = @[@"example.com"];
    state[@"active_generation"] = NSUUID.UUID.UUIDString;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_generation"] = SCSchedulerTestGenerationID;

    state[@"active_policy_revision"] = NSUUID.UUID.UUIDString;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_policy_revision"] = SCSchedulerTestPolicyRevisionID;
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID2;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID1;
    state[@"active_block_source"] = SCDaemonActiveBlockSourceManual;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerV2;
    state[@"block_running"] = @NO;
    XCTAssertFalse([SCDaemonScheduler activeState:state matchesRecord:record]);
}

- (void)testConsoleUserSwitchDoesNotEndAnotherOwnersActiveSchedule {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *owner501Record = SCSchedulerTestV2Record(
        501, [now dateByAddingTimeInterval:-30], [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{
        SCSchedulerTestScheduleID1: owner501Record,
    }];
    state[@"console_uid"] = @502;
    state[@"active_owner_uid"] = @501;
    state[@"block_running"] = @YES;
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerV2;
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID1;
    state[@"active_policy_revision"] = SCSchedulerTestPolicyRevisionID;

    __block NSUInteger handlerCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        anomalyHandler:nil];

    NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"wake"];
    XCTAssertEqualObjects(result[@"status"], @"verified");
    XCTAssertEqual(handlerCount, 0U);

    NSMutableDictionary *foreignRecord = [owner501Record mutableCopy];
    foreignRecord[@"controllingUID"] = @502;
    XCTAssertFalse([SCDaemonScheduler activeState:state
                                     matchesRecord:[foreignRecord copy]]);
}

- (void)testIdleToActiveReconcilesDesiredRecord {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *record = SCSchedulerTestV2Record(501,
                                                   [now dateByAddingTimeInterval:-30],
                                                   [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now
                                     approvedSchedules:@{SCSchedulerTestScheduleID1: record}];
    __block NSUInteger reconcileCount = 0;
    __block NSString *reconciledID = nil;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            reconcileCount += 1;
            reconciledID = scheduleID;
            XCTAssertEqualObjects(desired[SCDaemonSchedulePolicyRevisionKey], SCSchedulerTestPolicyRevisionID);
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            XCTFail(@"An idle-to-active transition must not tear down a block");
            completion(nil);
        }
        anomalyHandler:nil];

    NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"wake"];
    XCTAssertEqualObjects(result[@"status"], @"verified");
    XCTAssertEqualObjects(result[@"trigger"], @"wake");
    XCTAssertEqual(reconcileCount, 1U);
    XCTAssertEqualObjects(reconciledID, SCSchedulerTestScheduleID1);
}

- (void)testSessionChangeImmediatelySelectsTheNewConsoleOwnersSchedule {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *owner502Record = SCSchedulerTestV2Record(
        502, [now dateByAddingTimeInterval:-30], [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{
        SCSchedulerTestScheduleID1: owner502Record,
    }];
    state[@"console_uid"] = @501;

    __block NSUInteger reconcileCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            reconcileCount += 1;
            XCTAssertEqualObjects(scheduleID, SCSchedulerTestScheduleID1);
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            XCTFail(@"An idle session change must not tear down a block");
            completion(nil);
        }
        anomalyHandler:nil];

    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"periodic"][@"status"], @"verified");
    XCTAssertEqual(reconcileCount, 0U);
    state[@"console_uid"] = @502;
    NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"session_change"];
    XCTAssertEqualObjects(result[@"status"], @"verified");
    XCTAssertEqualObjects(result[@"trigger"], @"session_change");
    XCTAssertEqual(reconcileCount, 1U);
}

- (void)testFastUserSwitchReevaluatesNewOwnerImmediatelyAfterOldOwnersBlockEnds {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000060];
    NSDictionary *oldOwnerRecord = SCSchedulerTestV2Record(
        501, [now dateByAddingTimeInterval:-60], now);
    NSDictionary *newOwnerRecord = SCSchedulerTestV2Record(
        502, [now dateByAddingTimeInterval:-30], [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{
        SCSchedulerTestScheduleID1: oldOwnerRecord,
        SCSchedulerTestScheduleID2: newOwnerRecord,
    }];
    state[@"console_uid"] = @502;
    state[@"active_owner_uid"] = @501;
    state[@"block_running"] = @YES;
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerV2;
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID1;

    XCTestExpectation *newOwnerApplied = [self expectationWithDescription:@"new owner schedule applied"];
    __block NSUInteger endCount = 0;
    __block NSUInteger reconcileCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            reconcileCount += 1;
            XCTAssertEqualObjects(scheduleID, SCSchedulerTestScheduleID2);
            XCTAssertEqualObjects(desired[@"controllingUID"], @502);
            [newOwnerApplied fulfill];
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            endCount += 1;
            state[@"block_running"] = @NO;
            state[@"active_block_source"] = @"none";
            state[@"active_owner_uid"] = @0;
            completion(nil);
        }
        anomalyHandler:nil];

    NSDictionary *firstResult = [self evaluateScheduler:scheduler trigger:@"timer"];
    XCTAssertEqualObjects(firstResult[@"status"], @"verified");
    [self waitForExpectations:@[newOwnerApplied] timeout:1.0];
    XCTAssertEqual(endCount, 1U);
    XCTAssertEqual(reconcileCount, 1U);
}

- (void)testFailedApplyReportsAnomalyAndRetriesOnNextTrigger {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *record = SCSchedulerTestV2Record(501,
                                                   [now dateByAddingTimeInterval:-30],
                                                   [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now
                                     approvedSchedules:@{SCSchedulerTestScheduleID1: record}];
    __block NSUInteger reconcileCount = 0;
    NSMutableArray<NSDictionary<NSString *, id> *> *anomalies = [NSMutableArray array];
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            reconcileCount += 1;
            if (reconcileCount == 1) {
                completion([NSError errorWithDomain:@"SCDaemonSchedulerTests" code:17 userInfo:nil]);
            } else {
                completion(nil);
            }
        }
        endHandler:^(void (^completion)(NSError *)) { completion(nil); }
        anomalyHandler:^(NSDictionary<NSString *,id> *fields) {
            [anomalies addObject:fields];
        }];

    NSDictionary *failed = [self evaluateScheduler:scheduler trigger:@"startup"];
    XCTAssertEqualObjects(failed[@"status"], @"failed");
    XCTAssertEqualObjects(failed[@"stage"], @"apply");
    XCTAssertEqual(anomalies.count, 1U);
    XCTAssertEqualObjects(anomalies.firstObject[@"transition"], @"idle_active");
    XCTAssertEqualObjects(anomalies.firstObject[@"error_code"], @17);

    NSDictionary *retried = [self evaluateScheduler:scheduler trigger:@"periodic"];
    XCTAssertEqualObjects(retried[@"status"], @"verified");
    XCTAssertEqual(reconcileCount, 2U);
}

- (void)testManualAndTestBlocksDeferScheduleReconciliation {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *record = SCSchedulerTestV2Record(501,
                                                   [now dateByAddingTimeInterval:-30],
                                                   [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now
                                     approvedSchedules:@{SCSchedulerTestScheduleID1: record}];
    state[@"block_running"] = @YES;
    __block NSUInteger handlerCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        anomalyHandler:nil];

    for (NSString *source in @[SCDaemonActiveBlockSourceManual, SCDaemonActiveBlockSourceTest]) {
        state[@"active_block_source"] = source;
        NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"mutation"];
        XCTAssertEqualObjects(result[@"status"], @"deferred");
        XCTAssertEqualObjects(result[@"stage"], @"select");
    }
    XCTAssertEqual(handlerCount, 0U);
}

- (void)testSchedulePolicyReplacementDefersUntilStagedApplyExists {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *record = SCSchedulerTestV2Record(501,
                                                   [now dateByAddingTimeInterval:-30],
                                                   [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *state = [self idleStateAtDate:now
                                     approvedSchedules:@{SCSchedulerTestScheduleID2: record}];
    state[@"block_running"] = @YES;
    state[@"active_block_source"] = SCDaemonActiveBlockSourceSchedulerV2;
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID1;
    state[@"active_policy_revision"] = NSUUID.UUID.UUIDString;
    __block NSUInteger handlerCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            handlerCount += 1;
            completion(nil);
        }
        anomalyHandler:nil];

    NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"mutation"];
    XCTAssertEqualObjects(result[@"status"], @"deferred");
    XCTAssertEqual(handlerCount, 0U);
}

- (void)testScheduleOwnedBlockEndsWhenNoRecordIsDesired {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{}];
    state[@"block_running"] = @YES;
    state[@"active_block_source"] = SCDaemonActiveBlockSourceLegacySchedule;
    state[@"active_schedule_id"] = SCSchedulerTestScheduleID1;
    __block NSUInteger endCount = 0;
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            XCTFail(@"No replacement should be applied");
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) {
            endCount += 1;
            completion(nil);
        }
        anomalyHandler:nil];

    NSDictionary *result = [self evaluateScheduler:scheduler trigger:@"timer"];
    XCTAssertEqualObjects(result[@"status"], @"verified");
    XCTAssertEqual(endCount, 1U);
}

- (void)testCoalescedCompletionWaitsForTheFreshEvaluation {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSDictionary *firstRecord = SCSchedulerTestV2Record(501,
                                                        [now dateByAddingTimeInterval:-30],
                                                        [now dateByAddingTimeInterval:30]);
    NSMutableDictionary *secondRecord = [firstRecord mutableCopy];
    secondRecord[SCDaemonSchedulePolicyRevisionKey] = @"30000000-0000-4000-8000-000000000002";
    __block NSMutableDictionary *state = [self idleStateAtDate:now
                                            approvedSchedules:@{SCSchedulerTestScheduleID1: firstRecord}];
    __block NSUInteger reconcileCount = 0;
    __block __weak SCDaemonScheduler *weakScheduler = nil;
    XCTestExpectation *firstCompletion = [self expectationWithDescription:@"first evaluation completion"];
    XCTestExpectation *secondCompletion = [self expectationWithDescription:@"coalesced fresh completion"];
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) {
            reconcileCount += 1;
            if (reconcileCount == 1) {
                state[@"approved_schedules"] = @{SCSchedulerTestScheduleID2: [secondRecord copy]};
                [weakScheduler evaluateForTrigger:@"clock_change" completion:^(NSDictionary<NSString *,id> *result) {
                    XCTAssertEqual(reconcileCount, 2U,
                        @"The coalesced completion must not fire with the stale in-flight result");
                    XCTAssertEqualObjects(result[@"trigger"], @"clock_change");
                    [secondCompletion fulfill];
                }];
            } else {
                XCTAssertEqualObjects(scheduleID, SCSchedulerTestScheduleID2);
                XCTAssertEqualObjects(desired[SCDaemonSchedulePolicyRevisionKey],
                                      secondRecord[SCDaemonSchedulePolicyRevisionKey]);
            }
            completion(nil);
        }
        endHandler:^(void (^completion)(NSError *)) { completion(nil); }
        anomalyHandler:nil];
    weakScheduler = scheduler;

    [scheduler evaluateForTrigger:@"wake" completion:^(NSDictionary<NSString *,id> *result) {
        XCTAssertEqualObjects(result[@"trigger"], @"wake");
        XCTAssertEqual(reconcileCount, 1U);
        [firstCompletion fulfill];
    }];
    [self waitForExpectations:@[firstCompletion, secondCompletion] timeout:1.0];
    XCTAssertEqual(reconcileCount, 2U);
}

- (void)testWakeAndClockTriggersArePreservedAndUnknownTriggersAreSanitized {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000030];
    NSMutableDictionary *state = [self idleStateAtDate:now approvedSchedules:@{}];
    SCDaemonScheduler *scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{ return [state copy]; }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *desired,
                           void (^completion)(NSError *)) { completion(nil); }
        endHandler:^(void (^completion)(NSError *)) { completion(nil); }
        anomalyHandler:nil];

    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"wake"][@"trigger"], @"wake");
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"clock_change"][@"trigger"], @"clock_change");
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"session_change"][@"trigger"], @"session_change");
    XCTAssertEqualObjects([self evaluateScheduler:scheduler trigger:@"contains-private-context"][@"trigger"],
                          @"periodic");
}

- (NSDictionary *)protectedProfileWithID:(NSString *)bundleID policy:(NSInteger)policy ranges:(NSArray *)ranges {
    return @{@"bundleID": bundleID, @"name": @"Protected", @"colorHex": @"007AFF",
        @"enabled": @YES, @"displayOrder": @0, @"policy": @(policy),
        @"entries": @[@"example.com"], @"blockedRanges": ranges};
}

- (void)testRootBundleMembershipPersistsAndRejectsMetadataRemovalAndWeakerMinutes {
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSDictionary *original = [self calendarCommitmentAtDate:now];
    NSDictionary *profile = [self protectedProfileWithID:SCSchedulerTestBundleID policy:0
        ranges:@[@{@"start": @540, @"end": @720}]];
    NSDictionary *protected = [SCDaemonScheduler recurringCommitment:original protectingBundles:@[profile]];
    XCTAssertNotNil(protected);
    XCTAssertEqualObjects(protected[@"lockEndsAt"], original[@"lockEndsAt"]);
    XCTAssertEqualObjects(protected[@"generation"], original[@"generation"]);
    XCTAssertTrue([SCDaemonScheduler protectedBundles:@[profile] areCoveredBySegments:protected[@"segments"]]);
    for (NSDictionary *change in @[@{@"name": @"Renamed"}, @{@"policy": @1},
         @{@"colorHex": @"FF0000"}, @{@"entries": @[]},
         @{@"blockedRanges": @[@{@"start": @541, @"end": @720}]}]) {
        NSMutableDictionary *weaker = [profile mutableCopy];
        [weaker addEntriesFromDictionary:change];
        XCTAssertNil([SCDaemonScheduler recurringCommitment:protected protectingBundles:@[weaker]]);
    }
    XCTAssertNil([SCDaemonScheduler recurringCommitment:protected protectingBundles:@[]]);
    NSDictionary *appended = [SCDaemonScheduler recurringCommitment:protected
        appendingEntries:@[@"new.example"] forBundleID:SCSchedulerTestBundleID maximumEntries:4096];
    XCTAssertTrue([appended[@"protectedBundles"][0][@"entries"] containsObject:@"new.example"]);
    XCTAssertEqualObjects(appended[@"lockEndsAt"], original[@"lockEndsAt"]);
    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:appended
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSDictionary *restored = [NSPropertyListSerialization propertyListWithData:serialized
        options:NSPropertyListImmutable format:NULL error:nil];
    XCTAssertEqualObjects(restored, appended);
    XCTAssertEqual([SCDaemonScheduler validRecurringCommitmentsFromValue:@{SCSchedulerTestCommitmentID: restored}
        ownerUID:501].count, 1U);
}

- (void)testRootAdmissionIncludesNonBlockingMemberAndRejectsInventedCoverage {
    NSDate *now = [self dateWithYear:2026 month:7 day:13 hour:9 minute:30];
    NSMutableDictionary *original = [[self calendarCommitmentAtDate:now] mutableCopy];
    NSDictionary *old = [self protectedProfileWithID:SCSchedulerTestBundleID policy:0
        ranges:@[@{@"start": @540, @"end": @720}]];
    original[@"protectedBundles"] = @[old];
    NSDictionary *new = [self protectedProfileWithID:SCSchedulerTestScheduleID3 policy:0 ranges:@[]];
    NSDictionary *updated = [SCDaemonScheduler recurringCommitment:original protectingBundles:@[old, new]];
    XCTAssertNotNil(updated);
    XCTAssertEqualObjects(updated[@"lockEndsAt"], original[@"lockEndsAt"]);
    NSDictionary *added = [SCDaemonScheduler recurringCommitment:updated appendingEntries:@[@"new.example"]
        forBundleID:SCSchedulerTestScheduleID3 maximumEntries:4096];
    XCTAssertNotNil(added, @"A member stays appendable even while it has no blocked minutes");
    NSMutableDictionary *invented = [new mutableCopy];
    invented[@"blockedRanges"] = @[@{@"start": @0, @"end": @10080}];
    XCTAssertFalse(([SCDaemonScheduler protectedBundles:@[old, invented] areCoveredBySegments:original[@"segments"]]));
    XCTAssertFalse(([SCDaemonScheduler protectedBundlesAreValid:@[old, old]]));
}

@end

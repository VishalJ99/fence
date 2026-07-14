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

- (NSMutableDictionary<NSString *, id> *)idleStateAtDate:(NSDate *)now
                                       approvedSchedules:(NSDictionary<NSString *, id> *)approvedSchedules {
    return [@{
        @"settings_available": @YES,
        @"console_uid": @501,
        @"active_owner_uid": @0,
        @"approved_schedules": approvedSchedules,
        @"now": now,
        @"block_running": @NO,
        @"active_block_source": @"none",
        @"active_commitment_id": SCSchedulerTestCommitmentID,
        @"active_generation": SCSchedulerTestGenerationID,
        @"active_policy_revision": SCSchedulerTestPolicyRevisionID,
        @"active_blocklist": @[@"example.com"],
        @"active_is_allowlist": @NO,
    } mutableCopy];
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

@end

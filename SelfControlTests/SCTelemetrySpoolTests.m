//
//  SCTelemetrySpoolTests.m
//  SelfControlTests
//


#import <XCTest/XCTest.h>
#import <math.h>
#import <sys/stat.h>

#import "SCTelemetrySpool.h"
#import "SCXPCClient.h"
#import "SCDaemonProtocol.h"

@interface SCTelemetrySpoolTests : XCTestCase

@property (nonatomic, copy) NSString *temporaryBaseDirectory;
@property (nonatomic, strong) SCTelemetrySpool *spool;

@end

@implementation SCTelemetrySpoolTests

- (void)setUp {
    [super setUp];
    self.temporaryBaseDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"fence-telemetry-tests-%@",
                                       NSUUID.UUID.UUIDString]];
    self.spool = [[SCTelemetrySpool alloc] initWithBaseDirectory:self.temporaryBaseDirectory];
    XCTAssertNotNil(self.spool);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.temporaryBaseDirectory error:nil];
    self.spool = nil;
    self.temporaryBaseDirectory = nil;
    [super tearDown];
}

- (BOOL)appendSettingsEventForUID:(uid_t)uid
                       generation:(NSUInteger)generation
                            index:(NSUInteger)index
                            error:(NSError **)error {
    return [self.spool appendEventName:@"daemon.settings_load_failed"
                                 level:SCTelemetryEventLevelWarning
                                fields:@{
                                    @"reason": @"missing",
                                    @"settings_version": @(index),
                                    @"recovery_attempted": @NO,
                                    @"recovery_succeeded": @NO,
                                }
                                origin:SCTelemetryOriginDaemon
                                forUID:uid
                      consentGeneration:generation
                        consentEnabled:YES
                                 error:error];
}

- (NSArray<NSDictionary *> *)drainRecordsForUID:(uid_t)uid {
    NSMutableArray *allRecords = [NSMutableArray array];
    while (YES) {
        NSError *fetchError = nil;
        NSArray *batch = [self.spool recordsForUID:uid limit:100 error:&fetchError];
        XCTAssertNil(fetchError);
        if (batch.count == 0) break;
        [allRecords addObjectsFromArray:batch];
        NSArray *recordIDs = [batch valueForKey:@"id"];
        NSError *ackError = nil;
        XCTAssertTrue([self.spool acknowledgeRecordIDs:recordIDs forUID:uid error:&ackError]);
        XCTAssertNil(ackError);
    }
    return allRecords;
}

- (NSUInteger)permissionsAtPath:(NSString *)path {
    struct stat status;
    XCTAssertEqual(lstat(path.fileSystemRepresentation, &status), 0);
    return status.st_mode & 0777;
}

- (void)testUnknownDisabledAndStaleConsentNeverRecordsAndOptOutPurges {
    uid_t uid = 41001;
    NSError *error = nil;

    XCTAssertFalse([self appendSettingsEventForUID:uid generation:1 index:1 error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:self.temporaryBaseDirectory]);

    XCTAssertTrue([self.spool setConsentEnabled:NO generation:1 forUID:uid error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([self.spool appendEventName:@"daemon.settings_load_failed"
                                        level:SCTelemetryEventLevelWarning
                                       fields:@{@"reason": @"missing"}
                                       origin:SCTelemetryOriginDaemon
                                       forUID:uid
                             consentGeneration:1
                               consentEnabled:NO
                                        error:&error]);
    XCTAssertNil(error);

    XCTAssertTrue([self.spool setConsentEnabled:YES generation:2 forUID:uid error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([self appendSettingsEventForUID:uid generation:1 index:2 error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:2 index:3 error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue(([self.spool appendEventName:@"daemon.settings_load_failed"
                                        level:SCTelemetryEventLevelWarning
                                       fields:@{
                                           @"reason": @"missing",
                                           @"settings_version": @4,
                                           @"recovery_attempted": @NO,
                                           @"recovery_succeeded": @NO,
                                       }
                                       origin:SCTelemetryOriginDaemon
                                       forUID:uid
                                        error:&error]));
    XCTAssertEqual([self.spool recordsForUID:uid limit:25 error:&error].count, 2U);

    XCTAssertTrue([self.spool setConsentEnabled:NO generation:3 forUID:uid error:&error]);
    XCTAssertNil(error);
    XCTAssertEqual([self.spool recordsForUID:uid limit:25 error:&error].count, 0U);
    NSString *eventsPath = [[[self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]]
        stringByAppendingPathComponent:@"events.ndjson"] copy];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:eventsPath]);
    XCTAssertTrue([self.spool acknowledgeRecordIDs:@[NSUUID.UUID.UUIDString]
                                             forUID:uid
                                              error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:eventsPath]);
}

- (void)testStoragePermissionsBoundsAndRotation {
    uid_t uid = 41002;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    XCTAssertNil(error);

    for (NSUInteger index = 0; index < 130; index++) {
        XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:index error:&error]);
        XCTAssertNil(error);
    }

    NSString *uidDirectory = [self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]];
    NSString *lockPath = [uidDirectory stringByAppendingPathComponent:@".lock"];
    NSString *consentPath = [uidDirectory stringByAppendingPathComponent:@"consent.json"];
    NSString *eventsPath = [uidDirectory stringByAppendingPathComponent:@"events.ndjson"];
    XCTAssertEqual([self permissionsAtPath:self.temporaryBaseDirectory], 0700U);
    XCTAssertEqual([self permissionsAtPath:uidDirectory], 0700U);
    XCTAssertEqual([self permissionsAtPath:lockPath], 0600U);
    XCTAssertEqual([self permissionsAtPath:consentPath], 0600U);
    XCTAssertEqual([self permissionsAtPath:eventsPath], 0600U);

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:eventsPath error:&error];
    XCTAssertNil(error);
    XCTAssertLessThanOrEqual([attributes[NSFileSize] unsignedIntegerValue], 256U * 1024U);

    NSArray *records = [self drainRecordsForUID:uid];
    XCTAssertEqual(records.count, 100U);
    XCTAssertEqualObjects([records.firstObject valueForKeyPath:@"fields.settings_version"], @30);
    XCTAssertEqualObjects([records.lastObject valueForKeyPath:@"fields.settings_version"], @129);
    XCTAssertEqual([NSSet setWithArray:[records valueForKey:@"id"]].count, records.count);
}

- (void)testFetchGarbageCollectsExpiredAndExcessivelyFutureRecords {
    uid_t uid = 41011;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:1 error:&error]);

    NSString *eventsPath = [[self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]]
        stringByAppendingPathComponent:@"events.ndjson"];
    NSString *expiredID = NSUUID.UUID.UUIDString.lowercaseString;
    unsigned long long expiredMilliseconds = (unsigned long long)floor(
        ([[NSDate date] timeIntervalSince1970] - (15 * 24 * 60 * 60)) * 1000.0);
    NSDictionary *expiredRecord = @{
        @"id": expiredID,
        @"schema_version": @1,
        @"event_name": @"daemon.settings_load_failed",
        @"level": @"warning",
        @"origin": @"daemon",
        @"created_at_ms": @(expiredMilliseconds),
        @"fields": @{
            @"reason": @"missing",
            @"settings_version": @0,
            @"recovery_attempted": @NO,
            @"recovery_succeeded": @NO,
        },
    };
    NSMutableData *eventsData = [[NSData dataWithContentsOfFile:eventsPath] mutableCopy];
    [eventsData appendData:[NSJSONSerialization dataWithJSONObject:expiredRecord options:0 error:&error]];
    [eventsData appendBytes:"\n" length:1];
    NSString *futureID = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *futureRecord = [expiredRecord mutableCopy];
    futureRecord[@"id"] = futureID;
    futureRecord[@"created_at_ms"] = @((unsigned long long)floor(
        ([[NSDate date] timeIntervalSince1970] + (60 * 60)) * 1000.0));
    [eventsData appendData:[NSJSONSerialization dataWithJSONObject:futureRecord options:0 error:&error]];
    [eventsData appendBytes:"\n" length:1];
    XCTAssertTrue([eventsData writeToFile:eventsPath options:0 error:&error]);

    NSArray *records = [self.spool recordsForUID:uid limit:25 error:&error];
    XCTAssertNil(error);
    XCTAssertEqual(records.count, 1U);
    XCTAssertNotEqualObjects(records.firstObject[@"id"], expiredID);
    NSString *compacted = [NSString stringWithContentsOfFile:eventsPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:&error];
    XCTAssertNil(error);
    XCTAssertFalse([compacted containsString:expiredID]);
    XCTAssertFalse([compacted containsString:futureID]);
}

- (void)testOptOutRecoversFromCorruptConsentAndPurgesQueue {
    uid_t uid = 41007;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:1 error:&error]);

    NSString *uidDirectory = [self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]];
    NSString *consentPath = [uidDirectory stringByAppendingPathComponent:@"consent.json"];
    NSString *eventsPath = [uidDirectory stringByAppendingPathComponent:@"events.ndjson"];
    XCTAssertTrue([[@"not-json" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:consentPath atomically:NO]);

    error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:NO generation:2 forUID:uid error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:eventsPath]);
    XCTAssertEqual([self permissionsAtPath:consentPath], 0600U);
    XCTAssertEqual([self.spool recordsForUID:uid limit:25 error:&error].count, 0U);
    XCTAssertNil(error);
}

- (void)testOptOutPurgesQueueWhenConsentMarkerIsSymlinked {
    uid_t uid = 41012;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:1 error:&error]);

    NSString *uidDirectory = [self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]];
    NSString *consentPath = [uidDirectory stringByAppendingPathComponent:@"consent.json"];
    NSString *eventsPath = [uidDirectory stringByAppendingPathComponent:@"events.ndjson"];
    NSString *victimPath = [self.temporaryBaseDirectory stringByAppendingPathComponent:@"consent-victim"];
    NSData *victimData = [@"must-remain-private" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([victimData writeToFile:victimPath atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:consentPath error:&error]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:consentPath
                                                      withDestinationPath:victimPath
                                                                    error:&error]);

    error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:NO generation:2 forUID:uid error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:eventsPath]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:victimPath], victimData);
    NSDictionary *disabledState = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:consentPath]
                                                                   options:0
                                                                     error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(disabledState[@"enabled"], @NO);
    XCTAssertEqualObjects(disabledState[@"generation"], @2);
}

- (void)testConcurrentAppendsRemainValidAndUIDQueuesStayIsolated {
    uid_t firstUID = 41003;
    uid_t secondUID = 41004;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:7 forUID:firstUID error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:9 forUID:secondUID error:&error]);
    XCTAssertNil(error);

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    for (NSUInteger index = 0; index < 64; index++) {
        dispatch_group_async(group, queue, ^{
            NSError *appendError = nil;
            if (![self appendSettingsEventForUID:firstUID generation:7 index:index error:&appendError]) {
                @synchronized (errors) {
                    [errors addObject:appendError ?: [NSError errorWithDomain:@"test" code:1 userInfo:nil]];
                }
            }
        });
    }
    XCTAssertEqual(dispatch_group_wait(group,
                                       dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
    XCTAssertEqual(errors.count, 0U);

    XCTAssertTrue([self appendSettingsEventForUID:secondUID generation:9 index:999 error:&error]);
    XCTAssertNil(error);
    NSArray *firstRecords = [self drainRecordsForUID:firstUID];
    NSArray *secondRecords = [self drainRecordsForUID:secondUID];
    XCTAssertEqual(firstRecords.count, 64U);
    XCTAssertEqual(secondRecords.count, 1U);
    XCTAssertEqualObjects([secondRecords.firstObject valueForKeyPath:@"fields.settings_version"], @999);
    XCTAssertNil(firstRecords.firstObject[@"uid"]);
    XCTAssertNil(secondRecords.firstObject[@"uid"]);
}

- (void)testSymlinkedDirectoriesAndQueueFilesFailClosed {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    XCTAssertTrue([fileManager createDirectoryAtPath:self.temporaryBaseDirectory
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:&error]);
    XCTAssertNil(error);

    NSString *trapDirectory = [self.temporaryBaseDirectory stringByAppendingPathComponent:@"trap"];
    XCTAssertTrue([fileManager createDirectoryAtPath:trapDirectory
                          withIntermediateDirectories:NO
                                           attributes:nil
                                                error:&error]);
    NSString *symlinkedUIDDirectory = [self.temporaryBaseDirectory stringByAppendingPathComponent:@"41009"];
    XCTAssertTrue([fileManager createSymbolicLinkAtPath:symlinkedUIDDirectory
                                    withDestinationPath:trapDirectory
                                                  error:&error]);
    XCTAssertFalse([self.spool setConsentEnabled:YES generation:1 forUID:41009 error:&error]);
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorUnsafePath);

    uid_t fileUID = 41010;
    error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:fileUID error:&error]);
    NSString *victimPath = [self.temporaryBaseDirectory stringByAppendingPathComponent:@"victim.txt"];
    NSData *victimData = [@"must-not-change" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([victimData writeToFile:victimPath atomically:YES]);
    NSString *eventsPath = [[self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", fileUID]]
        stringByAppendingPathComponent:@"events.ndjson"];
    XCTAssertTrue([fileManager createSymbolicLinkAtPath:eventsPath
                                    withDestinationPath:victimPath
                                                  error:&error]);

    error = nil;
    XCTAssertFalse([self appendSettingsEventForUID:fileUID generation:1 index:1 error:&error]);
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorIO);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:victimPath], victimData);
}

- (void)testAcknowledgementsAreRetrySafeAndDoNotRemoveNewRecords {
    uid_t uid = 41005;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    for (NSUInteger index = 0; index < 3; index++) {
        XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:index error:&error]);
    }

    NSArray *initial = [self.spool recordsForUID:uid limit:25 error:&error];
    NSArray *firstTwoIDs = @[[initial[0] objectForKey:@"id"], [initial[1] objectForKey:@"id"]];
    XCTAssertTrue([self.spool acknowledgeRecordIDs:firstTwoIDs forUID:uid error:&error]);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:99 error:&error]);
    XCTAssertTrue([self.spool acknowledgeRecordIDs:firstTwoIDs forUID:uid error:&error]);
    XCTAssertNil(error);

    NSArray *remaining = [self.spool recordsForUID:uid limit:25 error:&error];
    XCTAssertEqual(remaining.count, 2U);
    XCTAssertEqualObjects([remaining[0] valueForKeyPath:@"fields.settings_version"], @2);
    XCTAssertEqualObjects([remaining[1] valueForKeyPath:@"fields.settings_version"], @99);
}

- (void)testTypedSchemaAndPrivacyTripwireFailClosedOnAppendAndFetch {
    uid_t uid = 41006;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);
    XCTAssertTrue([self appendSettingsEventForUID:uid generation:1 index:1 error:&error]);

    XCTAssertFalse([self.spool appendEventName:@"daemon.settings_load_failed"
                                         level:SCTelemetryEventLevelError
                                        fields:@{@"raw_blocklist": @[@"example.com"]}
                                        origin:SCTelemetryOriginDaemon
                                        forUID:uid
                              consentGeneration:1
                                consentEnabled:YES
                                         error:&error]);
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorPrivacyRejected);

    error = nil;
    XCTAssertFalse(([self.spool appendEventName:@"daemon.incompatible"
                                         level:SCTelemetryEventLevelError
                                        fields:@{
                                            @"reason": @"protocol_too_old",
                                            @"daemon_build": @"canary-telemetry-test.example",
                                        }
                                        origin:SCTelemetryOriginDaemon
                                        forUID:uid
                              consentGeneration:1
                                consentEnabled:YES
                                         error:&error]));
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorPrivacyRejected);

    NSString *eventsPath = [[self.temporaryBaseDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", uid]]
        stringByAppendingPathComponent:@"events.ndjson"];
    error = nil;
    NSString *storedText = [NSString stringWithContentsOfFile:eventsPath encoding:NSUTF8StringEncoding error:&error];
    XCTAssertNil(error);
    XCTAssertFalse([storedText containsString:@"example.com"]);

    NSDictionary *tamperedRecord = @{
        @"id": NSUUID.UUID.UUIDString.lowercaseString,
        @"schema_version": @1,
        @"event_name": @"daemon.incompatible",
        @"level": @"error",
        @"origin": @"daemon",
        @"created_at_ms": @1,
        @"fields": @{
            @"reason": @"protocol_too_old",
            @"daemon_build": @"canary-telemetry-test.example",
        },
    };
    NSMutableData *tamperedData = [[NSData dataWithContentsOfFile:eventsPath] mutableCopy];
    [tamperedData appendData:[NSJSONSerialization dataWithJSONObject:tamperedRecord options:0 error:nil]];
    [tamperedData appendBytes:"\n" length:1];

    NSDictionary *zeroIDRecord = @{
        @"id": @"00000000-0000-0000-0000-000000000000",
        @"schema_version": @1,
        @"event_name": @"daemon.settings_load_failed",
        @"level": @"warning",
        @"origin": @"daemon",
        @"created_at_ms": @1,
        @"fields": @{
            @"reason": @"missing",
            @"settings_version": @2,
            @"recovery_attempted": @NO,
            @"recovery_succeeded": @NO,
        },
    };
    [tamperedData appendData:[NSJSONSerialization dataWithJSONObject:zeroIDRecord options:0 error:nil]];
    [tamperedData appendBytes:"\n" length:1];
    [tamperedData appendData:[@"{\"id\":" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertTrue([tamperedData writeToFile:eventsPath atomically:NO]);

    error = nil;
    NSArray *fetched = [self.spool recordsForUID:uid limit:25 error:&error];
    XCTAssertNil(error);
    XCTAssertEqual(fetched.count, 1U);
    XCTAssertEqualObjects(fetched.firstObject[@"event_name"], @"daemon.settings_load_failed");

    error = nil;
    XCTAssertFalse([self.spool acknowledgeRecordIDs:@[zeroIDRecord[@"id"]] forUID:uid error:&error]);
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorInvalidArgument);
}

- (void)testRootSchedulerTelemetrySchemasAcceptOnlyTypedPrivacySafeFields {
    uid_t uid = 41007;
    NSError *error = nil;
    XCTAssertTrue([self.spool setConsentEnabled:YES generation:1 forUID:uid error:&error]);

    XCTAssertTrue(([self.spool appendEventName:@"schedule.reconcile_anomaly"
                                         level:SCTelemetryEventLevelError
                                        fields:@{
                                            @"trigger": @"wake",
                                            @"transition": @"idle_active",
                                            @"stage": @"apply",
                                            @"outcome": @"failed",
                                            @"applied_source": @"none",
                                            @"block_running": @NO,
                                            @"stored_segment_count": @3,
                                            @"minutes_late_bucket": @5,
                                            @"error_code": @500,
                                        }
                                        origin:SCTelemetryOriginDaemon
                                        forUID:uid
                              consentGeneration:1
                                consentEnabled:YES
                                         error:&error]));
    XCTAssertNil(error);

    XCTAssertTrue(([self.spool appendEventName:@"schedule.commit_store_failed"
                                         level:SCTelemetryEventLevelError
                                        fields:@{
                                            @"stage": @"lock",
                                            @"store_persisted": @NO,
                                            @"post_write_match": @NO,
                                            @"reconcile_succeeded": @NO,
                                            @"segments_planned": @4,
                                            @"segments_stored": @0,
                                            @"week_offset": @1,
                                            @"error_code": @500,
                                        }
                                        origin:SCTelemetryOriginApp
                                        forUID:uid
                              consentGeneration:1
                                consentEnabled:YES
                                         error:&error]));
    XCTAssertNil(error);

    error = nil;
    XCTAssertFalse(([self.spool appendEventName:@"schedule.reconcile_anomaly"
                                          level:SCTelemetryEventLevelError
                                         fields:@{
                                             @"trigger": @"wake",
                                             @"transition": @"idle_active",
                                             @"stage": @"apply",
                                             @"outcome": @"failed",
                                             @"applied_source": @"scheduler_v2",
                                             @"block_running": @NO,
                                             @"stored_segment_count": @3,
                                             @"minutes_late_bucket": @5,
                                             @"error_code": @500,
                                             @"schedule_id": NSUUID.UUID.UUIDString,
                                         }
                                         origin:SCTelemetryOriginDaemon
                                         forUID:uid
                               consentGeneration:1
                                 consentEnabled:YES
                                          error:&error]));
    XCTAssertEqual(error.code, SCTelemetrySpoolErrorPrivacyRejected);

    error = nil;
    NSArray *records = [self.spool recordsForUID:uid limit:25 error:&error];
    XCTAssertNil(error);
    XCTAssertEqual(records.count, 2U);
}

- (void)testTelemetryCapabilityIsRequiredForCurrentAndFutureProtocols {
    NSArray *required = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
        SCDaemonCapabilityStrictApplyResults,
        SCDaemonCapabilityScheduleOwnerBounds,
        SCDaemonCapabilityConsistencyProjection,
        SCDaemonCapabilityRootScheduleStore,
        SCDaemonCapabilityRootScheduleTimer,
        SCDaemonCapabilityRecurringScheduleStore,
        SCDaemonCapabilityRecurringScheduleTimer,
        SCDaemonCapabilityRecurringScheduleBreaks,
        SCDaemonCapabilityRecurringCommitmentExtend,
        SCDaemonCapabilityRecurringTimeZone,
    ];
    NSString *reason = nil;
    XCTAssertTrue([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                          capabilities:required
                    compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"compatible");

    NSArray *missingSpool = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
    ];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingSpool
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"capabilities-missing");

    NSArray *missingConsistencyProjection = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
        SCDaemonCapabilityStrictApplyResults,
        SCDaemonCapabilityScheduleOwnerBounds,
    ];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingConsistencyProjection
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"consistency-projection-missing");

    NSArray *missingStrictResults = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
    ];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingStrictResults
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"capabilities-missing");

    NSArray *missingScheduleBounds = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
        SCDaemonCapabilityStrictApplyResults,
    ];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingScheduleBounds
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"capabilities-missing");

    XCTAssertTrue([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent + 1
                                          capabilities:[required arrayByAddingObject:@"future-capability"]
                    compatibleWithCurrentAppWithReason:&reason]);

    NSArray *missingRootStore = [required filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *capability, NSDictionary *bindings) {
            return ![capability isEqualToString:SCDaemonCapabilityRootScheduleStore];
        }]];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingRootStore
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"root-schedule-store-missing");

    NSArray *missingRootTimer = [required filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *capability, NSDictionary *bindings) {
            return ![capability isEqualToString:SCDaemonCapabilityRootScheduleTimer];
        }]];
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:missingRootTimer
                     compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"root-schedule-timer-missing");
}

- (void)testActiveStrictifyOwnershipPredicateFailsClosed {
    XCTAssertTrue(SCDaemonClientMayStrictifyActiveBlock(501, @501, 502));
    XCTAssertFalse(SCDaemonClientMayStrictifyActiveBlock(501, @502, 501));

    XCTAssertTrue(SCDaemonClientMayStrictifyActiveBlock(501, nil, 501));
    XCTAssertTrue(SCDaemonClientMayStrictifyActiveBlock(501, @0, 501));
    XCTAssertFalse(SCDaemonClientMayStrictifyActiveBlock(501, nil, 502));
    XCTAssertFalse(SCDaemonClientMayStrictifyActiveBlock(0, nil, 0));
}

- (void)testActiveStrictifyReappliesIdempotentAndRetryUnionRequests {
    XCTAssertTrue(SCDaemonActiveStrictifyRequiresPhysicalReapply(1, 0, YES, NO));
    XCTAssertTrue(SCDaemonActiveStrictifyRequiresPhysicalReapply(1, 1, NO, YES));

    XCTAssertFalse(SCDaemonActiveStrictifyRequiresPhysicalReapply(1, 1, YES, NO));
    XCTAssertFalse(SCDaemonActiveStrictifyRequiresPhysicalReapply(0, 0, YES, NO));
    XCTAssertFalse(SCDaemonActiveStrictifyRequiresPhysicalReapply(1, 0, NO, NO));
}

- (void)testFutureStrictifyRequiresEveryLaunchdJobLoaded {
    XCTAssertTrue(SCDaemonFutureStrictifyPostconditionsSatisfied(YES, 2, 2, YES, 2, 0));

    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfied(YES, 2, 2, YES, 1, 0));
    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfied(YES, 2, 2, YES, 2, 1));
    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfied(YES, 2, 1, YES, 1, 0));
    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfied(NO, 2, 2, YES, 2, 0));
}

- (void)testFutureStrictifyTreatsV2RecordsAsRootSchedulerOwned {
    XCTAssertTrue(SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        YES, 3, 3, YES, 1, 1, 2, 0));
    XCTAssertTrue(SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        YES, 2, 2, YES, 0, 0, 2, 0));

    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        YES, 3, 3, YES, 1, 0, 2, 0));
    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        YES, 3, 3, YES, 1, 1, 1, 0));
    XCTAssertFalse(SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        YES, 3, 3, YES, 1, 1, 2, 1));
}

- (void)testActiveConsistencyFailsClosedOnPhysicalRemnantsWithoutProjection {
    XCTAssertTrue(SCAppDaemonActiveStateMatches(NO, NO, NO, NO, NO, YES));
    XCTAssertFalse(SCAppDaemonActiveStateMatches(NO, NO, NO, NO, NO, NO));
    XCTAssertFalse(SCAppDaemonActiveStateMatches(NO, NO, NO, YES, NO, YES));

    XCTAssertTrue(SCAppDaemonActiveStateMatches(YES, YES, YES, YES, YES, YES));
    XCTAssertFalse(SCAppDaemonActiveStateMatches(YES, YES, YES, YES, YES, NO));
    XCTAssertFalse(SCAppDaemonActiveStateMatches(YES, NO, YES, YES, YES, YES));
}

- (void)testScheduleOwnershipAndApprovedWindowPredicatesFailClosed {
    XCTAssertTrue(SCDaemonClientOwnsSchedule(501, @501));
    XCTAssertFalse(SCDaemonClientOwnsSchedule(501, @502));
    XCTAssertFalse(SCDaemonClientOwnsSchedule(501, nil));

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
    NSDate *approvedStart = [NSDate dateWithTimeIntervalSince1970:900];
    NSDate *approvedEnd = [NSDate dateWithTimeIntervalSince1970:1100];
    XCTAssertTrue(SCDaemonScheduledStartRequestIsValid(approvedEnd, approvedStart, approvedEnd, now));
    XCTAssertTrue(SCDaemonScheduledStartRequestIsValid(
        [approvedEnd dateByAddingTimeInterval:-0.5], approvedStart, approvedEnd, now));
    XCTAssertFalse(SCDaemonScheduledStartRequestIsValid(
        [approvedEnd dateByAddingTimeInterval:0.001], approvedStart, approvedEnd, now));
    XCTAssertFalse(SCDaemonScheduledStartRequestIsValid(
        [approvedEnd dateByAddingTimeInterval:-2], approvedStart, approvedEnd, now));
    XCTAssertFalse(SCDaemonScheduledStartRequestIsValid(
        approvedEnd, [now dateByAddingTimeInterval:1], approvedEnd, now));
    XCTAssertFalse(SCDaemonScheduledStartRequestIsValid(
        approvedEnd, [now dateByAddingTimeInterval:61], approvedEnd, now));
    XCTAssertFalse(SCDaemonScheduledStartRequestIsValid(now, approvedStart, now, now));
}

@end

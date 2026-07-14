//
//  SCDaemonXPC.m
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import "SCDaemonXPC.h"
#import "SCDaemon.h"
#import "SCDaemonBlockMethods.h"
#import "SCDaemonScheduler.h"
#import "SCXPCAuthorization.h"
#import "SCHelperToolUtilities.h"
#import "SCErr.h"
#import "SCTelemetrySpool.h"
#import "AppBlocker.h"
#import "PacketFilter.h"
#import "HostFileBlockerSet.h"
#import "SCBlockUtilities.h"
#include <pwd.h>
#include <math.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

@interface SCDaemonXPC ()

@property (nonatomic, assign, readonly) uid_t clientUID;
@property (nonatomic, strong, readonly) SCTelemetrySpool *telemetrySpool;

- (void)buildSanitizedDaemonSnapshotForExpectedState:(nullable NSDictionary<NSString *, id> *)expectedState
                                                reply:(void(^)(NSDictionary<NSString *, id> *snapshot,
                                                               NSError * _Nullable error))reply;

@end

static void SCDaemonXPCLogError(NSString *message, NSError *error) {
    NSLog(@"SCDaemonXPC: %@ (domain=%@ code=%ld)",
          message,
          error.domain ?: @"unknown",
          (long)error.code);
}

static NSString *SCDaemonXPCSafeBuildValue(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 || [value length] > 64) {
        return @"unknown";
    }
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._+-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? value : @"unknown";
}

static NSUInteger SCScheduleMinutesLateBucket(NSDate *approvedStartDate) {
    if (![approvedStartDate isKindOfClass:[NSDate class]]) return 0;
    NSTimeInterval secondsLate = MAX(0, -[approvedStartDate timeIntervalSinceNow]);
    NSUInteger minutes = (NSUInteger)floor(secondsLate / 60.0);
    if (minutes == 0) return 0;
    if (minutes < 5) return 1;
    if (minutes < 15) return 5;
    if (minutes < 60) return 15;
    if (minutes < 360) return 60;
    if (minutes < 1440) return 360;
    return 1440;
}

static NSUInteger SCScheduleCountOwnedApprovals(NSDictionary *approvedSchedules, uid_t uid) {
    NSUInteger count = 0;
    for (id candidate in approvedSchedules.allValues) {
        NSDictionary *schedule = [candidate isKindOfClass:[NSDictionary class]] ? candidate : nil;
        NSNumber *owner = schedule[@"controllingUID"];
        if ([owner isKindOfClass:[NSNumber class]] && owner.unsignedIntValue == uid) count += 1;
    }
    return count;
}

static NSString * const SCDaemonConsistencyErrorDomain = @"org.eyebeam.Fence.DaemonConsistency";
static const NSUInteger SCDaemonConsistencyMaximumSchedules = 512;
static const NSUInteger SCDaemonConsistencyMaximumEntries = 4096;
static NSString * const SCDaemonApprovedScheduleCommitmentsKey = @"ApprovedScheduleCommitments";

static NSObject *SCDaemonScheduleStoreLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL SCDaemonUUIDString(id value) {
    return [value isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:(NSString *)value] != nil;
}

static BOOL SCDaemonWeekKeyIsValid(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] != 10) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger index = 0; index < 10; index++) {
        unichar character = [value characterAtIndex:index];
        if (index == 4 || index == 7) {
            if (character != '-') return NO;
        } else if (![digits characterIsMember:character]) {
            return NO;
        }
    }
    return YES;
}

static BOOL SCDaemonCommitmentWindowIsCanonical(NSString *weekKey,
                                                 NSDate *weekStartDate,
                                                 NSDate *weekEndDate) {
    if (!SCDaemonWeekKeyIsValid(weekKey) ||
        ![weekStartDate isKindOfClass:[NSDate class]] ||
        ![weekEndDate isKindOfClass:[NSDate class]]) return NO;

    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone localTimeZone];
    NSDateComponents *startComponents = [calendar components:(NSCalendarUnitWeekday |
        NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                                       fromDate:weekStartDate];
    if (startComponents.weekday != 2 || startComponents.hour != 0 ||
        startComponents.minute != 0 || startComponents.second != 0) return NO;
    NSDate *expectedEnd = [calendar dateByAddingUnit:NSCalendarUnitDay
                                               value:7
                                              toDate:weekStartDate
                                             options:0];
    if (expectedEnd == nil || ![expectedEnd isEqualToDate:weekEndDate]) return NO;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = calendar;
    formatter.timeZone = calendar.timeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [[formatter stringFromDate:weekStartDate] isEqualToString:weekKey];
}

static NSDictionary<NSString *, id> *SCDaemonCommitmentEnvelope(
    uid_t ownerUID,
    NSString *weekKey,
    NSDate *weekStartDate,
    NSDate *weekEndDate,
    NSString *commitmentID,
    NSString *generation,
    NSArray<NSString *> *scheduleIDs,
    NSDate *registeredAt) {
    return @{
        @"schemaVersion": @1,
        @"controllingUID": @(ownerUID),
        @"weekKey": weekKey,
        @"weekStartDate": weekStartDate,
        @"weekEndDate": weekEndDate,
        @"commitmentID": commitmentID,
        @"generation": generation,
        @"scheduleIDs": scheduleIDs,
        @"registeredAt": registeredAt,
    };
}

static BOOL SCDaemonStoredCommitmentMatchesRequest(NSDictionary *stored,
                                                    NSDictionary *proposed) {
    NSArray<NSString *> *keys = @[@"schemaVersion", @"controllingUID", @"weekKey",
        @"weekStartDate", @"weekEndDate", @"commitmentID", @"generation", @"scheduleIDs"];
    for (NSString *key in keys) {
        if (![stored[key] isEqual:proposed[key]]) return NO;
    }
    return YES;
}

static BOOL SCDaemonStoredScheduleMatchesValidatedRecord(NSString *scheduleID,
                                                          NSDictionary *stored,
                                                          NSDictionary *validated) {
    if (![scheduleID isEqual:validated[@"scheduleID"]]) return NO;
    NSArray<NSString *> *keys = @[SCDaemonScheduleSchemaVersionKey, SCDaemonScheduleWeekKey,
        SCDaemonScheduleCommitmentIDKey, SCDaemonScheduleGenerationKey,
        SCDaemonSchedulePolicyRevisionKey, SCDaemonScheduleSourceBundleIDsKey,
        @"blocklist", @"isAllowlist", @"blockSettings", @"controllingUID",
        @"approvedStartDate", @"approvedEndDate"];
    for (NSString *key in keys) {
        if (![stored[key] isEqual:validated[key]]) return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *SCDaemonValidatedV2ScheduleRecord(
    id value,
    uid_t ownerUID,
    NSString *weekKey,
    NSDate *weekStartDate,
    NSDate *weekEndDate,
    NSString *commitmentID,
    NSString *generation) {
    if (![value isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *segment = value;
    NSString *scheduleID = segment[@"scheduleID"];
    NSDate *startDate = segment[@"approvedStartDate"];
    NSDate *endDate = segment[@"approvedEndDate"];
    NSArray *rawBlocklist = segment[@"blocklist"];
    NSDictionary *blockSettings = segment[@"blockSettings"];
    NSArray *sourceBundleIDs = segment[SCDaemonScheduleSourceBundleIDsKey];
    NSString *policyRevision = segment[SCDaemonSchedulePolicyRevisionKey];
    if (!SCDaemonUUIDString(scheduleID) || ![startDate isKindOfClass:[NSDate class]] ||
        ![endDate isKindOfClass:[NSDate class]] || [endDate compare:startDate] != NSOrderedDescending ||
        [startDate compare:weekStartDate] == NSOrderedAscending ||
        [endDate compare:weekEndDate] == NSOrderedDescending ||
        ![rawBlocklist isKindOfClass:[NSArray class]] || rawBlocklist.count == 0 ||
        rawBlocklist.count > SCDaemonConsistencyMaximumEntries ||
        ![blockSettings isKindOfClass:[NSDictionary class]] || [segment[@"isAllowlist"] boolValue] ||
        ![sourceBundleIDs isKindOfClass:[NSArray class]] || sourceBundleIDs.count == 0 ||
        !SCDaemonUUIDString(policyRevision)) return nil;

    for (id bundleID in sourceBundleIDs) if (!SCDaemonUUIDString(bundleID)) return nil;
    NSMutableOrderedSet<NSString *> *canonicalEntries = [NSMutableOrderedSet orderedSet];
    for (id entry in rawBlocklist) {
        if (![entry isKindOfClass:[NSString class]]) return nil;
        NSString *canonical = [SCMiscUtilities canonicalBlockEntryFromString:entry];
        if (canonical == nil) return nil;
        [canonicalEntries addObject:canonical];
    }
    if (canonicalEntries.count == 0) return nil;

    return @{
        @"scheduleID": scheduleID,
        SCDaemonScheduleSchemaVersionKey: @2,
        SCDaemonScheduleWeekKey: weekKey,
        SCDaemonScheduleCommitmentIDKey: commitmentID,
        SCDaemonScheduleGenerationKey: generation,
        SCDaemonSchedulePolicyRevisionKey: policyRevision,
        SCDaemonScheduleSourceBundleIDsKey: [sourceBundleIDs copy],
        @"blocklist": canonicalEntries.array,
        @"isAllowlist": @NO,
        @"blockSettings": [blockSettings copy],
        @"controllingUID": @(ownerUID),
        @"approvedStartDate": startDate,
        @"approvedEndDate": endDate,
        @"registeredAt": [NSDate date],
    };
}

static NSSet<NSString *> *SCDaemonCanonicalEntrySet(id value, BOOL *valid) {
    if (![value isKindOfClass:[NSArray class]] || [value count] > SCDaemonConsistencyMaximumEntries) {
        if (valid != NULL) *valid = NO;
        return [NSSet set];
    }

    NSMutableSet<NSString *> *entries = [NSMutableSet set];
    for (id candidate in value) {
        if (![candidate isKindOfClass:[NSString class]] || [candidate length] == 0 || [candidate length] > 2048) {
            if (valid != NULL) *valid = NO;
            return [NSSet set];
        }
        NSString *canonical = [SCMiscUtilities canonicalBlockEntryFromString:candidate];
        if (canonical == nil) {
            // Preserve equality for opaque entries created by older Fence
            // builds. The fallback remains local and is never returned.
            canonical = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (canonical.length == 0 || canonical.length > 2048) {
            if (valid != NULL) *valid = NO;
            return [NSSet set];
        }
        [entries addObject:canonical];
    }
    if (valid != NULL) *valid = YES;
    return [entries copy];
}

static NSString *SCDaemonScheduleProjectionKey(id value, BOOL *valid) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (valid != NULL) *valid = NO;
        return nil;
    }
    NSDictionary *descriptor = value;
    NSDate *startDate = descriptor[@"start_date"];
    NSDate *endDate = descriptor[@"end_date"];
    BOOL entriesValid = NO;
    NSSet<NSString *> *entries = SCDaemonCanonicalEntrySet(descriptor[@"entries"], &entriesValid);
    if (!entriesValid || ![startDate isKindOfClass:[NSDate class]] ||
        ![endDate isKindOfClass:[NSDate class]] ||
        [endDate compare:startDate] != NSOrderedDescending) {
        if (valid != NULL) *valid = NO;
        return nil;
    }

    NSArray<NSString *> *sortedEntries = [entries.allObjects sortedArrayUsingSelector:@selector(compare:)];
    long long startSecond = llround(floor(startDate.timeIntervalSince1970));
    long long endSecond = llround(floor(endDate.timeIntervalSince1970));
    NSString *key = [NSString stringWithFormat:@"%lld\x1e%lld\x1e%@",
                     startSecond, endSecond, [sortedEntries componentsJoinedByString:@"\x1f"]];
    if (valid != NULL) *valid = YES;
    return key;
}

static NSCountedSet<NSString *> *SCDaemonScheduleProjectionSet(id value, BOOL *valid) {
    if (![value isKindOfClass:[NSArray class]] || [value count] > SCDaemonConsistencyMaximumSchedules) {
        if (valid != NULL) *valid = NO;
        return [NSCountedSet set];
    }
    NSCountedSet<NSString *> *result = [NSCountedSet set];
    NSUInteger totalEntries = 0;
    for (id descriptor in value) {
        id entries = [descriptor isKindOfClass:[NSDictionary class]] ? descriptor[@"entries"] : nil;
        totalEntries += [entries isKindOfClass:[NSArray class]] ? [entries count] : 0;
        if (totalEntries > SCDaemonConsistencyMaximumEntries) {
            if (valid != NULL) *valid = NO;
            return [NSCountedSet set];
        }
        BOOL descriptorValid = NO;
        NSString *key = SCDaemonScheduleProjectionKey(descriptor, &descriptorValid);
        if (!descriptorValid || key == nil) {
            if (valid != NULL) *valid = NO;
            return [NSCountedSet set];
        }
        [result addObject:key];
    }
    if (valid != NULL) *valid = YES;
    return result;
}

static NSDictionary<NSString *, NSNumber *> *SCDaemonCountedSetDelta(NSCountedSet *expected,
                                                                       NSCountedSet *actual) {
    NSMutableSet *allKeys = [NSMutableSet setWithArray:expected.allObjects];
    [allKeys addObjectsFromArray:actual.allObjects];
    NSUInteger missing = 0;
    NSUInteger extra = 0;
    for (id key in allKeys) {
        NSUInteger expectedCount = [expected countForObject:key];
        NSUInteger actualCount = [actual countForObject:key];
        if (expectedCount > actualCount) missing += expectedCount - actualCount;
        if (actualCount > expectedCount) extra += actualCount - expectedCount;
    }
    NSUInteger expectedTotal = 0;
    NSUInteger actualTotal = 0;
    for (id key in expected) expectedTotal += [expected countForObject:key];
    for (id key in actual) actualTotal += [actual countForObject:key];
    return @{
        @"matches": @(missing == 0 && extra == 0),
        @"expected_count": @(expectedTotal),
        @"actual_count": @(actualTotal),
        @"missing_count": @(missing),
        @"extra_count": @(extra),
    };
}

static NSDictionary<NSString *, NSNumber *> *SCDaemonSetDelta(NSSet *expected, NSSet *actual) {
    NSMutableSet *missing = [expected mutableCopy];
    [missing minusSet:actual];
    NSMutableSet *extra = [actual mutableCopy];
    [extra minusSet:expected];
    return @{
        @"matches": @(missing.count == 0 && extra.count == 0),
        @"expected_count": @(expected.count),
        @"actual_count": @(actual.count),
        @"missing_count": @(missing.count),
        @"extra_count": @(extra.count),
    };
}

static NSString *SCDaemonHomeDirectoryForUID(uid_t uid) {
    long suggestedBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t bufferSize = (suggestedBufferSize > 0 && suggestedBufferSize <= 65536)
        ? (size_t)suggestedBufferSize : 16384;
    char *passwordBuffer = calloc(1, bufferSize);
    if (passwordBuffer == NULL) return nil;

    struct passwd passwordEntry;
    struct passwd *passwordResult = NULL;
    NSString *homeDirectory = nil;
    if (getpwuid_r(uid, &passwordEntry, passwordBuffer, bufferSize, &passwordResult) == 0 &&
        passwordResult != NULL && passwordEntry.pw_dir != NULL) {
        homeDirectory = [NSString stringWithUTF8String:passwordEntry.pw_dir];
    }
    free(passwordBuffer);
    return homeDirectory;
}

static BOOL SCDaemonLaunchdJobIsLoaded(uid_t uid, NSString *label, NSDate *deadline, BOOL *probeSucceeded) {
    if (deadline.timeIntervalSinceNow <= 0) {
        if (probeSucceeded != NULL) *probeSucceeded = NO;
        return NO;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"print", [NSString stringWithFormat:@"gui/%u/%@", uid, label]];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (probeSucceeded != NULL) *probeSucceeded = NO;
        return NO;
    }
    while (task.running && deadline.timeIntervalSinceNow > 0) {
        usleep(10000);
    }
    if (task.running) {
        [task terminate];
        if (probeSucceeded != NULL) *probeSucceeded = NO;
        return NO;
    }
    if (probeSucceeded != NULL) *probeSucceeded = YES;
    return task.terminationStatus == 0;
}

static NSString *SCDaemonScheduleJobLabel(NSString *scheduleID, NSDate *startDate) {
    if ([[NSUUID alloc] initWithUUIDString:scheduleID ?: @""] == nil ||
        ![startDate isKindOfClass:[NSDate class]]) return nil;
    NSDateComponents *components = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
          fromDate:startDate];
    NSArray<NSString *> *dayNames = @[@"sunday", @"monday", @"tuesday", @"wednesday",
                                      @"thursday", @"friday", @"saturday"];
    NSInteger dayIndex = components.weekday - 1;
    if (dayIndex < 0 || dayIndex >= (NSInteger)dayNames.count) return nil;
    return [NSString stringWithFormat:@"org.eyebeam.selfcontrol.schedule.merged-%@.%@.%02ld%02ld",
            scheduleID, dayNames[(NSUInteger)dayIndex], (long)components.hour, (long)components.minute];
}

@implementation SCDaemonXPC

- (instancetype)initWithClientUID:(uid_t)clientUID {
    self = [super init];
    if (self) {
        _clientUID = clientUID;
        _telemetrySpool = [[SCTelemetrySpool alloc] init];
    }
    return self;
}

- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: startBlockWithControllingUID");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"startBlock authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"SCDaemonXPC: startBlock authorization accepted");
    }

    [SCDaemonBlockMethods startBlockWithControllingUID: controllingUID blocklist: blocklist isAllowlist:isAllowlist endDate: endDate blockSettings:blockSettings authorization: authData reply: reply];
}

- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlocklist");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"updateBlocklist authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"SCDaemonXPC: updateBlocklist authorization accepted");
    }
    
    [SCDaemonBlockMethods updateBlocklist: newBlocklist authorization: authData reply: reply];
}

- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply {
    [self appendEntriesToActiveBlocklist:entries
               matchingExistingBlocklist:existingBlocklist
                              resultReply:^(NSDictionary<NSString *,id> *result, NSError *error) {
        reply(error);
    }];
}

- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString *,id> *result,
                                                 NSError *error))reply {
    NSLog(@"XPC method called: appendEntriesToActiveBlocklist (structured result)");

    SCSettings *settings = [SCSettings sharedSettings];
    NSNumber *activeOwner = [settings valueForKey:@"ActiveBlockControllingUID"];
    uid_t consoleUID = [SCMiscUtilities consoleUserUID];
    if (!SCDaemonClientMayStrictifyActiveBlock(self.clientUID, activeOwner, consoleUID)) {
        NSDictionary *result = @{
            @"schema_version": @1,
            @"outcome": @"failed",
            @"failed_stage": @"owner_precondition",
            @"requested_count": @([entries isKindOfClass:[NSArray class]] ? entries.count : 0),
            @"canonical_count": @0,
            @"rejected_count": @0,
            @"duplicate_count": @0,
            @"active_before_count": @0,
            @"active_after_count": @0,
            @"settings_persisted": @NO,
            @"active_verified": @NO,
            @"physical_reapply_attempted": @NO,
        };
        NSError *ownerError = [SCErr errorWithCode:403
                                    subDescription:@"Active block ownership precondition failed"];
        reply(result, ownerError);
        return;
    }

    [SCDaemonBlockMethods appendEntriesToActiveBlocklist:entries
                               matchingExistingBlocklist:existingBlocklist
                                              resultReply:^(NSDictionary<NSString *,id> *result,
                                                            NSError *error) {
        NSMutableDictionary *safeResult = [result isKindOfClass:[NSDictionary class]]
            ? [result mutableCopy] : nil;
        NSDictionary *applyResult = [safeResult[@"apply_result"] isKindOfClass:[NSDictionary class]]
            ? safeResult[@"apply_result"] : nil;
        if (applyResult != nil) {
            NSMutableDictionary *safeApplyResult = [applyResult mutableCopy];
            id entryCounts = safeApplyResult[@"entries"];
            [safeApplyResult removeObjectForKey:@"entries"];
            if ([entryCounts isKindOfClass:[NSDictionary class]]) {
                safeApplyResult[@"entry_counts"] = entryCounts;
            }
            safeResult[@"apply_result"] = safeApplyResult;
        }
        if (safeResult == nil ||
            ![SCSentry payloadPassesTelemetryPrivacyTripwire:safeResult]) {
            NSError *privacyError = [NSError errorWithDomain:SCTelemetrySpoolErrorDomain
                                                         code:SCTelemetrySpoolErrorPrivacyRejected
                                                     userInfo:nil];
            reply(@{}, privacyError);
            return;
        }
        reply([safeResult copy], error);
    }];
}

- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlockEndDate");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"updateBlockEndDate authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"SCDaemonXPC: updateBlockEndDate authorization accepted");
    }
    
    [SCDaemonBlockMethods updateBlockEndDate: newEndDate authorization: authData reply: reply];
}

// Part of the HelperToolProtocol.  Returns the version number of the tool.  Note that never
// requires authorization.
- (void)getVersionWithReply:(void(^)(NSString * version))reply {
    NSLog(@"XPC method called: getVersionWithReply");
    // We specifically don't check for authorization here.  Everyone is always allowed to get
    // the version of the helper tool.
    reply(SELFCONTROL_VERSION_STRING);
}

- (void)getCompatibilityInfoWithReply:(void(^)(NSInteger protocolVersion,
                                                NSString *buildVersion,
                                                NSString *marketingVersion,
                                                NSArray<NSString *> *capabilities))reply {
    NSLog(@"XPC method called: getCompatibilityInfoWithReply");

    // This is deliberately a read-only, authorization-free handshake. The
    // returned values are static binary metadata and safe capability names.
    NSBundle *daemonBundle = [NSBundle mainBundle];
    NSString *buildVersion = [daemonBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSString *marketingVersion = [daemonBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

    if (![buildVersion isKindOfClass:[NSString class]] || buildVersion.length == 0) {
        buildVersion = @"unknown";
    }
    if (![marketingVersion isKindOfClass:[NSString class]] || marketingVersion.length == 0) {
        marketingVersion = @"unknown";
    }

    reply(SCDaemonProtocolVersionCurrent,
          buildVersion,
          marketingVersion,
          @[
              SCDaemonCapabilityActiveBlocklistAppend,
              SCDaemonCapabilityApprovedSchedulesAppend,
              SCDaemonCapabilityTelemetrySpool,
              SCDaemonCapabilityStrictApplyResults,
              SCDaemonCapabilityScheduleOwnerBounds,
              SCDaemonCapabilityConsistencyProjection,
              SCDaemonCapabilityRootScheduleStore,
              SCDaemonCapabilityRootScheduleTimer,
          ]);
}

#pragma mark - Privacy-safe telemetry transport

- (void)setTelemetryConsentEnabled:(BOOL)enabled
                        generation:(NSUInteger)generation
                             reply:(void(^)(NSError *error))reply {
    NSError *error = nil;
    [self.telemetrySpool setConsentEnabled:enabled
                                generation:generation
                                    forUID:self.clientUID
                                     error:&error];
    reply(error);
}

- (void)fetchTelemetryRecordsWithLimit:(NSUInteger)limit
                                  reply:(void(^)(NSArray<NSDictionary<NSString *,id> *> *records,
                                                 NSError *error))reply {
    NSError *error = nil;
    NSArray *records = [self.telemetrySpool recordsForUID:self.clientUID
                                                     limit:MIN(limit, 25)
                                                     error:&error];
    reply(records ?: @[], error);
}

- (void)acknowledgeTelemetryRecordIDs:(NSArray<NSString *> *)recordIDs
                                 reply:(void(^)(NSError *error))reply {
    NSError *error = nil;
    [self.telemetrySpool acknowledgeRecordIDs:recordIDs
                                        forUID:self.clientUID
                                         error:&error];
    reply(error);
}

- (void)getSanitizedDaemonSnapshotWithReply:(void(^)(NSDictionary<NSString *,id> *snapshot,
                                                      NSError *error))reply {
    [self buildSanitizedDaemonSnapshotForExpectedState:nil reply:reply];
}

- (void)getSanitizedDaemonSnapshotForExpectedState:(NSDictionary<NSString *,id> *)expectedState
                                             reply:(void(^)(NSDictionary<NSString *,id> *snapshot,
                                                            NSError *error))reply {
    [self buildSanitizedDaemonSnapshotForExpectedState:expectedState reply:reply];
}

- (void)buildSanitizedDaemonSnapshotForExpectedState:(NSDictionary<NSString *,id> *)expectedState
                                                reply:(void(^)(NSDictionary<NSString *,id> *snapshot,
                                                               NSError *error))reply {
    BOOL comparisonRequested = expectedState != nil;
    BOOL projectionValid = !comparisonRequested ||
        ([expectedState isKindOfClass:[NSDictionary class]] &&
         [expectedState[@"schema_version"] isEqual:@1] &&
         [expectedState[@"projection_valid"] isEqual:@YES] &&
         [expectedState[@"active_projection_available"] isKindOfClass:[NSNumber class]]);

    BOOL expectedActiveValid = NO;
    BOOL expectedApprovalsValid = NO;
    BOOL expectedJobsValid = NO;
    NSSet<NSString *> *expectedActiveEntries = comparisonRequested
        ? SCDaemonCanonicalEntrySet(expectedState[@"active_entries"], &expectedActiveValid)
        : [NSSet set];
    NSCountedSet<NSString *> *expectedApprovals = comparisonRequested
        ? SCDaemonScheduleProjectionSet(expectedState[@"approval_schedules"], &expectedApprovalsValid)
        : [NSCountedSet set];
    NSCountedSet<NSString *> *expectedJobs = comparisonRequested
        ? SCDaemonScheduleProjectionSet(expectedState[@"job_schedules"], &expectedJobsValid)
        : [NSCountedSet set];
    projectionValid = projectionValid &&
        (!comparisonRequested || (expectedActiveValid && expectedApprovalsValid && expectedJobsValid));
    if (!projectionValid) {
        NSError *projectionError = [NSError errorWithDomain:SCDaemonConsistencyErrorDomain
                                                        code:1
                                                    userInfo:nil];
        reply(@{}, projectionError);
        return;
    }

    SCSettings *settings = [SCSettings sharedSettings];
    BOOL settingsAvailable = settings.settingsStateAvailableForEnforcement;
    NSNumber *activeOwner = [settings valueForKey:@"ActiveBlockControllingUID"];
    BOOL ownerKnown = [activeOwner isKindOfClass:[NSNumber class]] && activeOwner.unsignedIntValue != 0;
    BOOL ownsActiveState = ownerKnown && activeOwner.unsignedIntValue == self.clientUID;
    NSString *activeOwnerState = !ownerKnown ? @"missing" : (ownsActiveState ? @"self" : @"other");
    // Blocks created before PER-355 have no owner marker. The caller has
    // already passed Fence's code-signature requirement, so expose only the
    // same sanitized booleans/counts for this legacy ownerless state. A known
    // other user's active state remains fully hidden.
    BOOL mayExposeActiveState = ownsActiveState || !ownerKnown;
    BOOL blockRunning = settingsAvailable && mayExposeActiveState && [settings boolForKey:@"BlockIsRunning"];

    id activeEntriesValue = [settings valueForKey:@"ActiveBlocklist"];
    BOOL actualActiveEntriesValid = NO;
    NSSet<NSString *> *actualActiveEntries = blockRunning
        ? SCDaemonCanonicalEntrySet(activeEntriesValue, &actualActiveEntriesValid)
        : [NSSet set];
    if (!blockRunning) actualActiveEntriesValid = YES;
    NSUInteger activeEntryCount = actualActiveEntries.count;
    BOOL pfActive = [PacketFilter blockFoundInPF];
    BOOL hostsRulesPresent = [[HostFileBlockerSet new].defaultBlocker containsSelfControlBlock];
    BOOL hostsActive = (settingsAvailable && blockRunning && [settings boolForKey:@"ActiveBlockAsWhitelist"])
        || hostsRulesPresent;
    BOOL appMonitoring = [AppBlocker sharedBlocker].isMonitoring;

    NSString *blockEndState = @"none";
    if (blockRunning) {
        id blockEndDate = [settings valueForKey:@"BlockEndDate"];
        if ([blockEndDate isKindOfClass:[NSDate class]]) {
            blockEndState = [blockEndDate timeIntervalSinceNow] > 0 ? @"future" : @"past";
        } else if (blockEndDate != nil && blockEndDate != [NSNull null]) {
            blockEndState = @"invalid";
        } else {
            blockEndState = @"missing";
        }
    }

    NSDate *now = [NSDate date];
    BOOL collectorPartial = !settingsAvailable || !actualActiveEntriesValid;
    NSUInteger expiredApprovalCount = 0;
    NSUInteger approvedEntryCount = 0;
    id approvedValue = [settings valueForKey:@"ApprovedSchedules"];
    NSDictionary *approvedSchedules = [approvedValue isKindOfClass:[NSDictionary class]] ? approvedValue : @{};
    NSMutableDictionary<NSString *, NSDictionary *> *ownedSchedulesByID = [NSMutableDictionary dictionary];
    NSCountedSet<NSString *> *actualApprovals = [NSCountedSet set];
    NSUInteger invalidOwnedApprovalCount = 0;
    NSUInteger inProgressApprovalCount = 0;
    NSUInteger schedulerApprovalCount = 0;
    NSUInteger legacyApprovalCount = 0;
    for (id candidateID in approvedSchedules) {
        id candidate = approvedSchedules[candidateID];
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *schedule = (NSDictionary *)candidate;
        NSNumber *owner = schedule[@"controllingUID"];
        if (![owner isKindOfClass:[NSNumber class]] || owner.unsignedIntValue != self.clientUID) continue;
        NSDate *approvedStartDate = schedule[@"approvedStartDate"];
        NSDate *approvedEndDate = schedule[@"approvedEndDate"];
        id blocklist = schedule[@"blocklist"];
        if ([approvedEndDate isKindOfClass:[NSDate class]] &&
            [approvedEndDate compare:now] != NSOrderedDescending) {
            expiredApprovalCount += 1;
            continue;
        }
        BOOL validScheduleID = [candidateID isKindOfClass:[NSString class]] &&
            [[NSUUID alloc] initWithUUIDString:candidateID] != nil;
        NSDictionary *descriptor = @{
            @"entries": [blocklist isKindOfClass:[NSArray class]] ? blocklist : @[],
            @"start_date": [approvedStartDate isKindOfClass:[NSDate class]] ? approvedStartDate : [NSNull null],
            @"end_date": [approvedEndDate isKindOfClass:[NSDate class]] ? approvedEndDate : [NSNull null],
        };
        BOOL descriptorValid = NO;
        NSString *projectionKey = SCDaemonScheduleProjectionKey(descriptor, &descriptorValid);
        if (!validScheduleID || !descriptorValid || projectionKey == nil) {
            invalidOwnedApprovalCount += 1;
            collectorPartial = YES;
            [actualApprovals addObject:[NSString stringWithFormat:@"__invalid_approval_%lu",
                                        (unsigned long)invalidOwnedApprovalCount]];
            continue;
        }
        BOOL schedulerRecord = [schedule[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2;
        if (schedulerRecord) {
            schedulerApprovalCount += 1;
        } else {
            legacyApprovalCount += 1;
            // Only V1 records have a user LaunchAgent to inspect/probe.
            ownedSchedulesByID[candidateID] = schedule;
        }
        BOOL blocklistValid = NO;
        NSUInteger canonicalBlocklistCount = SCDaemonCanonicalEntrySet(blocklist, &blocklistValid).count;
        if ([approvedStartDate compare:now] != NSOrderedDescending) {
            // A segment already in progress may have been started directly
            // and intentionally has no launchd job. Exclude it from the
            // future graph comparison while retaining its sanitized count.
            inProgressApprovalCount += 1;
            continue;
        }
        [actualApprovals addObject:projectionKey];
        approvedEntryCount += canonicalBlocklistCount;
    }

    NSCountedSet<NSString *> *actualPlists = [NSCountedSet set];
    NSCountedSet<NSString *> *actualLoadedJobs = [NSCountedSet set];
    NSUInteger launchdProbeFailureCount = 0;
    NSUInteger invalidPlistCount = 0;
    NSUInteger inProgressPlistCount = 0;
    NSUInteger inspectedPlistCount = 0;
    NSMutableSet<NSString *> *probedScheduleIDs = [NSMutableSet set];
    NSDate *launchdDeadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    NSString *homeDirectory = SCDaemonHomeDirectoryForUID(self.clientUID);
    if (homeDirectory != nil) {
        NSString *launchAgentsDirectory = [homeDirectory stringByAppendingPathComponent:@"Library/LaunchAgents"];
        struct stat directoryStatus;
        int directoryStatResult = lstat(launchAgentsDirectory.fileSystemRepresentation, &directoryStatus);
        BOOL directoryIsMissing = directoryStatResult != 0 && errno == ENOENT;
        BOOL safeLaunchAgentsDirectory = directoryStatResult == 0 &&
            S_ISDIR(directoryStatus.st_mode) && !S_ISLNK(directoryStatus.st_mode);
        NSError *directoryError = nil;
        NSArray<NSString *> *filenames = safeLaunchAgentsDirectory
            ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:launchAgentsDirectory
                                                                  error:&directoryError]
            : nil;
        if (filenames == nil) {
            if (expectedJobs.count > 0 || !directoryIsMissing) {
                collectorPartial = YES;
            }
        } else {
            for (NSString *filename in filenames) {
                if (![filename hasPrefix:@"org.eyebeam.selfcontrol.schedule.merged-"] ||
                    ![filename hasSuffix:@".plist"]) continue;
                if (inspectedPlistCount >= SCDaemonConsistencyMaximumSchedules) {
                    collectorPartial = YES;
                    break;
                }
                inspectedPlistCount += 1;

                NSString *fullPath = [launchAgentsDirectory stringByAppendingPathComponent:filename];
                struct stat fileStatus;
                BOOL regularFile = lstat(fullPath.fileSystemRepresentation, &fileStatus) == 0 &&
                    S_ISREG(fileStatus.st_mode) && !S_ISLNK(fileStatus.st_mode) &&
                    fileStatus.st_size >= 0 && fileStatus.st_size <= 262144;
                NSData *plistData = regularFile ? [NSData dataWithContentsOfFile:fullPath] : nil;
                id plistObject = plistData ? [NSPropertyListSerialization propertyListWithData:plistData
                                                                                        options:NSPropertyListImmutable
                                                                                         format:nil
                                                                                          error:nil] : nil;
                NSDictionary *plist = [plistObject isKindOfClass:[NSDictionary class]] ? plistObject : nil;
                NSString *label = [plist[@"Label"] isKindOfClass:[NSString class]] ? plist[@"Label"] : nil;
                NSString *expectedLabel = filename.stringByDeletingPathExtension;
                BOOL labelValid = label.length <= 180 && [label isEqualToString:expectedLabel];

                NSString *scheduleID = nil;
                NSString *startText = nil;
                NSString *endText = nil;
                id argumentsValue = plist[@"ProgramArguments"];
                NSArray *arguments = [argumentsValue isKindOfClass:[NSArray class]] ? argumentsValue : nil;
                if ([argumentsValue isKindOfClass:[NSArray class]]) {
                    for (id argument in argumentsValue) {
                        if (![argument isKindOfClass:[NSString class]]) continue;
                        if ([argument hasPrefix:@"--schedule-id="]) scheduleID = [argument substringFromIndex:14];
                        if ([argument hasPrefix:@"--startdate="]) startText = [argument substringFromIndex:12];
                        if ([argument hasPrefix:@"--enddate="]) endText = [argument substringFromIndex:10];
                    }
                }
                NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
                formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
                NSDate *startDate = startText ? [formatter dateFromString:startText] : nil;
                NSDate *endDate = endText ? [formatter dateFromString:endText] : nil;
                BOOL argumentsValid = arguments.count == 5 &&
                    [arguments[0] isKindOfClass:[NSString class]] &&
                    [[arguments[0] lastPathComponent] isEqualToString:@"selfcontrol-cli"] &&
                    [arguments[1] isEqualToString:@"start"];
                BOOL labelContainsScheduleID = scheduleID.length > 0 &&
                    [label containsString:[NSString stringWithFormat:@".merged-%@.", scheduleID]];
                NSDictionary *calendarInterval = [plist[@"StartCalendarInterval"]
                    isKindOfClass:[NSDictionary class]] ? plist[@"StartCalendarInterval"] : nil;
                BOOL calendarValid = NO;
                if ([startDate isKindOfClass:[NSDate class]] && calendarInterval != nil) {
                    NSDateComponents *components = [[NSCalendar currentCalendar]
                        components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
                          fromDate:startDate];
                    calendarValid = [calendarInterval[@"Weekday"] integerValue] == components.weekday - 1 &&
                        [calendarInterval[@"Hour"] integerValue] == components.hour &&
                        [calendarInterval[@"Minute"] integerValue] == components.minute;
                }
                NSDictionary *approvedSchedule = scheduleID ? ownedSchedulesByID[scheduleID] : nil;
                NSDictionary *plistDescriptor = approvedSchedule ? @{
                    @"entries": approvedSchedule[@"blocklist"] ?: @[],
                    @"start_date": startDate ?: [NSNull null],
                    @"end_date": endDate ?: [NSNull null],
                } : nil;
                BOOL descriptorValid = NO;
                NSString *plistKey = SCDaemonScheduleProjectionKey(plistDescriptor, &descriptorValid);
                BOOL inProgressJob = [startDate isKindOfClass:[NSDate class]] &&
                    [startDate compare:now] != NSOrderedDescending;
                if (!regularFile || !labelValid || !labelContainsScheduleID ||
                    !argumentsValid || !calendarValid ||
                    [[NSUUID alloc] initWithUUIDString:scheduleID ?: @""] == nil ||
                    !descriptorValid || plistKey == nil) {
                    invalidPlistCount += 1;
                    collectorPartial = YES;
                    plistKey = [NSString stringWithFormat:@"__invalid_plist_%lu",
                                (unsigned long)invalidPlistCount];
                }

                BOOL probeSucceeded = !labelValid;
                BOOL loaded = NO;
                if (labelValid) {
                    loaded = SCDaemonLaunchdJobIsLoaded(self.clientUID, label,
                                                       launchdDeadline, &probeSucceeded);
                    if (scheduleID.length > 0) [probedScheduleIDs addObject:scheduleID];
                }
                if (!probeSucceeded) {
                    launchdProbeFailureCount += 1;
                    collectorPartial = YES;
                }
                if (inProgressJob) {
                    inProgressPlistCount += 1;
                    continue;
                }
                [actualPlists addObject:plistKey];
                if (probeSucceeded && loaded) {
                    [actualLoadedJobs addObject:plistKey];
                }
            }
        }

        // A loaded job can outlive a deleted plist. Probe the root-approved
        // labels that were not represented by any plist so loaded-vs-plist
        // drift remains distinguishable without enumerating or returning
        // launchd labels.
        for (NSString *scheduleID in ownedSchedulesByID) {
            if ([probedScheduleIDs containsObject:scheduleID]) continue;
            NSDictionary *schedule = ownedSchedulesByID[scheduleID];
            NSDate *startDate = schedule[@"approvedStartDate"];
            if (![startDate isKindOfClass:[NSDate class]] ||
                [startDate compare:now] != NSOrderedDescending) continue;
            NSString *label = SCDaemonScheduleJobLabel(scheduleID, startDate);
            if (label == nil) continue;
            BOOL probeSucceeded = NO;
            BOOL loaded = SCDaemonLaunchdJobIsLoaded(self.clientUID, label,
                                                     launchdDeadline, &probeSucceeded);
            if (!probeSucceeded) {
                launchdProbeFailureCount += 1;
                collectorPartial = YES;
                continue;
            }
            if (loaded) {
                NSDictionary *descriptor = @{
                    @"entries": schedule[@"blocklist"] ?: @[],
                    @"start_date": startDate,
                    @"end_date": schedule[@"approvedEndDate"] ?: [NSNull null],
                };
                BOOL descriptorValid = NO;
                NSString *key = SCDaemonScheduleProjectionKey(descriptor, &descriptorValid);
                if (descriptorValid && key != nil) [actualLoadedJobs addObject:key];
            }
        }
    } else if (expectedJobs.count > 0 || ownedSchedulesByID.count > 0) {
        collectorPartial = YES;
    }

    BOOL expectedActiveProjectionAvailable = comparisonRequested &&
        [expectedState[@"active_projection_available"] boolValue] && mayExposeActiveState;
    NSDictionary *activeDelta = expectedActiveProjectionAvailable
        ? SCDaemonSetDelta(expectedActiveEntries, actualActiveEntries)
        : SCDaemonSetDelta([NSSet set], [NSSet set]);
    NSDictionary *approvalDelta = SCDaemonCountedSetDelta(
        comparisonRequested ? expectedApprovals : [NSCountedSet set], actualApprovals);
    NSDictionary *plistDelta = SCDaemonCountedSetDelta(
        comparisonRequested ? expectedJobs : [NSCountedSet set], actualPlists);
    NSDictionary *loadedJobDelta = SCDaemonCountedSetDelta(
        comparisonRequested ? expectedJobs : [NSCountedSet set], actualLoadedJobs);

    NSBundle *daemonBundle = [NSBundle mainBundle];
    NSString *activeSource = [settings valueForKey:@"ActiveBlockSource"];
    NSSet<NSString *> *knownSources = [NSSet setWithArray:@[
        @"none", SCDaemonActiveBlockSourceManual, SCDaemonActiveBlockSourceTest,
        SCDaemonActiveBlockSourceLegacySchedule, SCDaemonActiveBlockSourceSchedulerV2,
    ]];
    if (![activeSource isKindOfClass:[NSString class]] || ![knownSources containsObject:activeSource]) {
        activeSource = @"unknown";
    }
    NSDictionary *snapshot = @{
        @"schema_version": @2,
        @"collector_status": collectorPartial ? @"partial" : @"complete",
        @"comparison_status": !comparisonRequested ? @"not_requested" :
            (expectedActiveProjectionAvailable || ![expectedState[@"active_projection_available"] boolValue]
                ? @"exact" : @"unavailable"),
        @"active_owner_state": activeOwnerState,
        @"active_block_source": activeSource,
        @"settings_available": @(settingsAvailable),
        @"block_running": @(blockRunning),
        @"pf_active": @(pfActive),
        @"hosts_active": @(hostsActive),
        @"app_monitoring": @(appMonitoring),
        @"active_entry_count": @(activeEntryCount),
        @"approved_schedule_count": approvalDelta[@"actual_count"],
        @"approved_entry_count": @(approvedEntryCount),
        @"scheduler_record_count": @(schedulerApprovalCount),
        @"legacy_approval_count": @(legacyApprovalCount),
        @"schedule_plist_count": plistDelta[@"actual_count"],
        @"schedule_job_count": loadedJobDelta[@"actual_count"],
        @"expired_approval_count": @(expiredApprovalCount),
        @"in_progress_approval_count": @(inProgressApprovalCount),
        @"in_progress_plist_count": @(inProgressPlistCount),
        @"invalid_approval_count": @(invalidOwnedApprovalCount),
        @"invalid_plist_count": @(invalidPlistCount),
        @"launchd_probe_failure_count": @(launchdProbeFailureCount),
        @"active_comparison_available": @(expectedActiveProjectionAvailable),
        @"active_entries_match": activeDelta[@"matches"],
        @"active_expected_count": activeDelta[@"expected_count"],
        @"active_actual_count": activeDelta[@"actual_count"],
        @"active_missing_count": activeDelta[@"missing_count"],
        @"active_extra_count": activeDelta[@"extra_count"],
        @"approval_schedules_match": approvalDelta[@"matches"],
        @"approval_expected_count": approvalDelta[@"expected_count"],
        @"approval_actual_count": approvalDelta[@"actual_count"],
        @"approval_missing_count": approvalDelta[@"missing_count"],
        @"approval_extra_count": approvalDelta[@"extra_count"],
        @"plist_schedules_match": plistDelta[@"matches"],
        @"plist_expected_count": plistDelta[@"expected_count"],
        @"plist_actual_count": plistDelta[@"actual_count"],
        @"plist_missing_count": plistDelta[@"missing_count"],
        @"plist_extra_count": plistDelta[@"extra_count"],
        @"loaded_jobs_match": loadedJobDelta[@"matches"],
        @"loaded_job_expected_count": loadedJobDelta[@"expected_count"],
        @"loaded_job_actual_count": loadedJobDelta[@"actual_count"],
        @"loaded_job_missing_count": loadedJobDelta[@"missing_count"],
        @"loaded_job_extra_count": loadedJobDelta[@"extra_count"],
        @"block_end_state": blockEndState,
        @"daemon_protocol": @(SCDaemonProtocolVersionCurrent),
        @"daemon_build": SCDaemonXPCSafeBuildValue(
            [daemonBundle objectForInfoDictionaryKey:@"CFBundleVersion"]),
    };
    if (![SCSentry payloadPassesTelemetryPrivacyTripwire:snapshot]) {
        NSError *privacyError = [NSError errorWithDomain:SCTelemetrySpoolErrorDomain
                                                     code:SCTelemetrySpoolErrorPrivacyRejected
                                                 userInfo:nil];
        reply(@{}, privacyError);
        return;
    }
    reply(snapshot, nil);
}

#pragma mark - Schedule Registration (Pre-Authorization System)

- (void)replaceScheduledCommitmentForWeekKey:(NSString *)weekKey
                               weekStartDate:(NSDate *)weekStartDate
                                 weekEndDate:(NSDate *)weekEndDate
                                commitmentID:(NSString *)commitmentID
                                  generation:(NSString *)generation
                                    segments:(NSArray<NSDictionary<NSString *,id> *> *)segments
                               authorization:(NSData *)authData
                                       reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    NSMutableDictionary<NSString *, id> *result = [@{
        @"schema_version": @1,
        @"outcome": @"failed",
        @"failed_stage": @"validate",
        @"segments_planned": @([segments isKindOfClass:[NSArray class]] ? segments.count : 0),
        @"segments_stored": @0,
        @"store_persisted": @NO,
        @"post_write_match": @NO,
        @"reconcile_succeeded": @NO,
        @"legacy_records_replaced": @0,
        @"expired_records_pruned": @0,
    } mutableCopy];

    NSError *authorizationError = [SCXPCAuthorization checkAuthorization:authData
        command:@selector(replaceScheduledCommitmentForWeekKey:weekStartDate:weekEndDate:commitmentID:generation:segments:authorization:reply:)];
    if (authorizationError != nil) {
        result[@"failed_stage"] = @"authorize";
        reply([result copy], authorizationError);
        return;
    }

    BOOL basicInputValid = self.clientUID != 0 &&
        SCDaemonCommitmentWindowIsCanonical(weekKey, weekStartDate, weekEndDate) &&
        SCDaemonUUIDString(commitmentID) && SCDaemonUUIDString(generation) &&
        [segments isKindOfClass:[NSArray class]] && segments.count <= SCDaemonConsistencyMaximumSchedules;
    if (!basicInputValid) {
        reply([result copy], [SCErr errorWithCode:403 subDescription:@"Invalid scheduled commitment envelope"]);
        return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *validated = [NSMutableArray arrayWithCapacity:segments.count];
    NSMutableSet<NSString *> *validatedScheduleIDs = [NSMutableSet setWithCapacity:segments.count];
    NSUInteger aggregateEntryCount = 0;
    for (id segment in segments) {
        NSDictionary *record = SCDaemonValidatedV2ScheduleRecord(segment, self.clientUID, weekKey,
                                                                 weekStartDate, weekEndDate,
                                                                 commitmentID, generation);
        NSString *scheduleID = record[@"scheduleID"];
        NSUInteger recordEntryCount = [record[@"blocklist"] count];
        BOOL aggregateWouldOverflow = !SCDaemonScheduleEntryCountCanAdd(
            aggregateEntryCount, recordEntryCount, SCDaemonConsistencyMaximumEntries);
        if (record == nil || [validatedScheduleIDs containsObject:scheduleID] || aggregateWouldOverflow) {
            reply([result copy], [SCErr errorWithCode:403 subDescription:@"Invalid scheduled commitment segment"]);
            return;
        }
        aggregateEntryCount += recordEntryCount;
        [validatedScheduleIDs addObject:scheduleID];
        [validated addObject:record];
    }
    [validated sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"approvedStartDate"] compare:right[@"approvedStartDate"]];
    }];
    for (NSUInteger index = 1; index < validated.count; index++) {
        if ([validated[index - 1][@"approvedEndDate"] compare:validated[index][@"approvedStartDate"]] == NSOrderedDescending) {
            reply([result copy], [SCErr errorWithCode:403 subDescription:@"Scheduled commitment segments overlap"]);
            return;
        }
    }

    if (![SCDaemonBlockMethods lockOrTimeout:^(NSError *lockError) {
        result[@"failed_stage"] = @"lock";
        reply([result copy], lockError);
    }]) return;

    SCSettings *settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        result[@"failed_stage"] = @"persist";
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([result copy], [SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *validatedByID = [NSMutableDictionary dictionary];
    for (NSDictionary *record in validated) validatedByID[record[@"scheduleID"]] = record;
    NSArray<NSString *> *proposedScheduleIDs =
        [validatedScheduleIDs.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary<NSString *, id> *proposedEnvelope = SCDaemonCommitmentEnvelope(
        self.clientUID, weekKey, weekStartDate, weekEndDate, commitmentID, generation,
        proposedScheduleIDs, [NSDate date]);

    __block NSArray<NSString *> *expiredLegacyIDs = @[];
    __block NSUInteger expiredRecordsPruned = 0;
    __block NSError *persistenceError = nil;
    __block BOOL postWriteMatch = NO;
    __block BOOL immutableConflict = NO;
    __block BOOL exactRetry = NO;
    @synchronized (SCDaemonScheduleStoreLock()) {
        NSDictionary *oldValue = [settings valueForKey:@"ApprovedSchedules"];
        NSDictionary *oldSchedules = [oldValue isKindOfClass:[NSDictionary class]] ? oldValue : @{};
        NSDictionary *oldCommitmentValue = [settings valueForKey:SCDaemonApprovedScheduleCommitmentsKey];
        NSDictionary *oldCommitments = [oldCommitmentValue isKindOfClass:[NSDictionary class]]
            ? oldCommitmentValue : @{};
        NSDate *now = [NSDate date];
        __block BOOL matchingEnvelopeFound = NO;
        __block BOOL foreignCommitmentIDCollision = NO;

        [oldCommitments enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSDictionary *storedEnvelope = [value isKindOfClass:[NSDictionary class]] ? value : nil;
            NSNumber *owner = storedEnvelope[@"controllingUID"];
            NSDate *start = storedEnvelope[@"weekStartDate"];
            NSDate *end = storedEnvelope[@"weekEndDate"];
            BOOL owned = storedEnvelope != nil && SCDaemonClientOwnsSchedule(self.clientUID, owner);
            if ([key isEqual:commitmentID] && !owned) foreignCommitmentIDCollision = YES;
            if (!owned || ![start isKindOfClass:[NSDate class]] ||
                ![end isKindOfClass:[NSDate class]] || [end compare:now] != NSOrderedDescending) return;
            if (!SCDaemonScheduleIntervalsOverlap(start, end, weekStartDate, weekEndDate)) return;
            BOOL isMatchingEnvelope = [key isEqual:commitmentID] &&
                SCDaemonStoredCommitmentMatchesRequest(storedEnvelope, proposedEnvelope);
            if (isMatchingEnvelope && !matchingEnvelopeFound) {
                matchingEnvelopeFound = YES;
            } else {
                immutableConflict = YES;
            }
        }];
        if (foreignCommitmentIDCollision) immutableConflict = YES;

        NSMutableSet<NSString *> *matchingRecordIDs = [NSMutableSet set];
        [oldSchedules enumerateKeysAndObjectsUsingBlock:^(id scheduleID, id value, BOOL *stop) {
            NSDictionary *storedRecord = [value isKindOfClass:[NSDictionary class]] ? value : nil;
            NSNumber *owner = storedRecord[@"controllingUID"];
            NSDate *start = storedRecord[@"approvedStartDate"];
            NSDate *end = storedRecord[@"approvedEndDate"];
            BOOL owned = storedRecord != nil && SCDaemonClientOwnsSchedule(self.clientUID, owner);
            BOOL expired = [end isKindOfClass:[NSDate class]] &&
                [end compare:now] != NSOrderedDescending;
            if ([validatedScheduleIDs containsObject:scheduleID] && !owned) {
                immutableConflict = YES;
                return;
            }
            if (!owned || expired) return;
            // A malformed live owner record cannot be proven non-overlapping;
            // refuse the mutation instead of deleting the only root evidence.
            if (![start isKindOfClass:[NSDate class]] || ![end isKindOfClass:[NSDate class]]) {
                immutableConflict = YES;
                return;
            }
            if (!SCDaemonScheduleIntervalsOverlap(start, end, weekStartDate, weekEndDate)) {
                if ([validatedScheduleIDs containsObject:scheduleID]) immutableConflict = YES;
                return;
            }
            NSDictionary *proposedRecord = validatedByID[scheduleID];
            if (!matchingEnvelopeFound || proposedRecord == nil ||
                !SCDaemonStoredScheduleMatchesValidatedRecord(scheduleID, storedRecord, proposedRecord)) {
                immutableConflict = YES;
                return;
            }
            [matchingRecordIDs addObject:scheduleID];
        }];

        exactRetry = matchingEnvelopeFound && !immutableConflict &&
            [matchingRecordIDs isEqualToSet:validatedScheduleIDs];
        if (matchingEnvelopeFound && !exactRetry) immutableConflict = YES;

        if (!immutableConflict && exactRetry) {
            postWriteMatch = YES;
        } else if (!immutableConflict) {
            NSMutableDictionary *replacement = [oldSchedules mutableCopy];
            NSMutableDictionary *replacementCommitments = [oldCommitments mutableCopy];
            NSMutableSet<NSString *> *legacyIDs = [NSMutableSet set];

            [oldSchedules enumerateKeysAndObjectsUsingBlock:^(id scheduleID, id value, BOOL *stop) {
                NSDictionary *record = [value isKindOfClass:[NSDictionary class]] ? value : nil;
                NSNumber *owner = record[@"controllingUID"];
                NSDate *end = record[@"approvedEndDate"];
                BOOL expired = [end isKindOfClass:[NSDate class]] &&
                    [end compare:now] != NSOrderedDescending;
                if (record == nil || !SCDaemonClientOwnsSchedule(self.clientUID, owner) || !expired) return;
                [replacement removeObjectForKey:scheduleID];
                expiredRecordsPruned += 1;
                if ([record[SCDaemonScheduleSchemaVersionKey] integerValue] < 2 &&
                    [scheduleID isKindOfClass:[NSString class]]) [legacyIDs addObject:scheduleID];
            }];
            [oldCommitments enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                NSDictionary *storedEnvelope = [value isKindOfClass:[NSDictionary class]] ? value : nil;
                NSNumber *owner = storedEnvelope[@"controllingUID"];
                NSDate *end = storedEnvelope[@"weekEndDate"];
                BOOL expired = [end isKindOfClass:[NSDate class]] &&
                    [end compare:now] != NSOrderedDescending;
                if (storedEnvelope != nil && SCDaemonClientOwnsSchedule(self.clientUID, owner) && expired) {
                    [replacementCommitments removeObjectForKey:key];
                }
            }];

            for (NSDictionary *record in validated) {
                NSMutableDictionary *storedRecord = [record mutableCopy];
                NSString *scheduleID = storedRecord[@"scheduleID"];
                [storedRecord removeObjectForKey:@"scheduleID"];
                replacement[scheduleID] = [storedRecord copy];
            }
            replacementCommitments[commitmentID] = proposedEnvelope;

            [settings setValue:replacement forKey:@"ApprovedSchedules"];
            [settings setValue:replacementCommitments forKey:SCDaemonApprovedScheduleCommitmentsKey];
            persistenceError = [settings syncSettingsAndWait:5];
            if (persistenceError == nil) {
                NSDictionary *persistedSchedulesValue = [settings valueForKey:@"ApprovedSchedules"];
                NSDictionary *persistedSchedules = [persistedSchedulesValue isKindOfClass:[NSDictionary class]]
                    ? persistedSchedulesValue : @{};
                NSDictionary *persistedCommitmentsValue = [settings valueForKey:SCDaemonApprovedScheduleCommitmentsKey];
                NSDictionary *persistedCommitments = [persistedCommitmentsValue isKindOfClass:[NSDictionary class]]
                    ? persistedCommitmentsValue : @{};
                NSDictionary *persistedEnvelope = persistedCommitments[commitmentID];
                postWriteMatch = SCDaemonStoredCommitmentMatchesRequest(persistedEnvelope, proposedEnvelope);
                for (NSDictionary *record in validated) {
                    NSString *scheduleID = record[@"scheduleID"];
                    if (!SCDaemonStoredScheduleMatchesValidatedRecord(
                            scheduleID, persistedSchedules[scheduleID], record)) {
                        postWriteMatch = NO;
                        break;
                    }
                }
                if (!postWriteMatch) {
                    persistenceError = [SCErr errorWithCode:500
                                             subDescription:@"Scheduled commitment did not verify after persistence"];
                }
            }
            if (persistenceError != nil) {
                [settings setValue:oldSchedules forKey:@"ApprovedSchedules"];
                [settings setValue:oldCommitments forKey:SCDaemonApprovedScheduleCommitmentsKey];
                [settings syncSettingsAndWait:5];
            } else {
                expiredLegacyIDs = legacyIDs.allObjects;
            }
        }
    }

    if (immutableConflict) {
        result[@"failed_stage"] = @"validate";
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([result copy], [SCErr errorWithCode:403
            subDescription:@"An unexpired root schedule commitment already owns this time window"]);
        return;
    }

    if (persistenceError != nil) {
        result[@"failed_stage"] = @"persist";
        result[@"post_write_match"] = @(postWriteMatch);
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([result copy], persistenceError);
        return;
    }

    result[@"segments_stored"] = @(validated.count);
    result[@"store_persisted"] = @YES;
    result[@"post_write_match"] = @(postWriteMatch);
    result[@"legacy_records_replaced"] = @0;
    result[@"expired_records_pruned"] = @(expiredRecordsPruned);
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    for (NSString *legacyID in expiredLegacyIDs) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [[SCDaemon sharedDaemon] cleanupLegacyScheduleArtifactsWithID:legacyID
                                                           controllingUID:self.clientUID];
        });
    }

    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation" completion:^(NSDictionary<NSString *,id> *schedulerResult) {
        BOOL reconciled = [schedulerResult[@"status"] isEqualToString:@"verified"] ||
            [schedulerResult[@"status"] isEqualToString:@"deferred"];
        result[@"reconcile_succeeded"] = @(reconciled);
        result[@"outcome"] = reconciled ? @"verified" : @"stored";
        result[@"failed_stage"] = reconciled ? @"none" : @"evaluate";
        reply([result copy], nil);
    }];
}

// Register a schedule - stores approved schedule in secure settings
// Legacy V1 registration remains available during the rollback/drain window.
- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                   startDate:(NSDate*)startDate
                     endDate:(NSDate*)endDate
                 authorization:(NSData *)authData
                         reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: registerScheduleWithID");

    NSError *authorizationError = [SCXPCAuthorization checkAuthorization:authData
        command:@selector(startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:)];
    if (authorizationError != nil) {
        reply(authorizationError);
        return;
    }

    BOOL validScheduleID = [scheduleId isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:scheduleId] != nil;
    BOOL validBounds = [startDate isKindOfClass:[NSDate class]] &&
        [endDate isKindOfClass:[NSDate class]] &&
        [endDate compare:startDate] == NSOrderedDescending;
    if (!validScheduleID || controllingUID != self.clientUID || !validBounds) {
        reply([SCErr errorWithCode:403 subDescription:@"Schedule registration precondition failed"]);
        return;
    }

    if (![SCDaemonBlockMethods lockOrTimeout:reply]) return;

    // Store the approved schedule in secure settings (root-only file)
    SCSettings* settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }
    NSMutableDictionary* approvedSchedules = [[settings valueForKey: @"ApprovedSchedules"] mutableCopy];
    if (approvedSchedules == nil) {
        approvedSchedules = [NSMutableDictionary new];
    }
    NSDictionary *existingSchedule = [approvedSchedules[scheduleId] isKindOfClass:[NSDictionary class]]
        ? approvedSchedules[scheduleId] : nil;
    NSNumber *existingOwner = existingSchedule[@"controllingUID"];
    NSDate *existingEnd = existingSchedule[@"approvedEndDate"];
    BOOL existingLiveV2 = [existingSchedule[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2 &&
        [existingEnd isKindOfClass:[NSDate class]] && [existingEnd compare:[NSDate date]] == NSOrderedDescending;
    if ((existingSchedule != nil && !SCDaemonClientOwnsSchedule(self.clientUID, existingOwner)) ||
        existingLiveV2) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:403 subDescription:@"Schedule ID cannot be replaced"]);
        return;
    }
    NSDictionary *commitmentValue = [settings valueForKey:SCDaemonApprovedScheduleCommitmentsKey];
    NSDictionary *commitments = [commitmentValue isKindOfClass:[NSDictionary class]]
        ? commitmentValue : @{};
    NSDate *now = [NSDate date];
    __block BOOL overlapsRootCommitment = NO;
    [commitments enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        NSDictionary *envelope = [value isKindOfClass:[NSDictionary class]] ? value : nil;
        NSNumber *owner = envelope[@"controllingUID"];
        NSDate *commitmentStart = envelope[@"weekStartDate"];
        NSDate *commitmentEnd = envelope[@"weekEndDate"];
        if (envelope != nil && SCDaemonClientOwnsSchedule(self.clientUID, owner) &&
            [commitmentStart isKindOfClass:[NSDate class]] &&
            [commitmentEnd isKindOfClass:[NSDate class]] &&
            [commitmentEnd compare:now] == NSOrderedDescending &&
            SCDaemonScheduleIntervalsOverlap(startDate, endDate, commitmentStart, commitmentEnd)) {
            overlapsRootCommitment = YES;
            *stop = YES;
        }
    }];
    if (overlapsRootCommitment) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:403
                    subDescription:@"Legacy registration overlaps an unexpired root commitment"]);
        return;
    }

    // Store schedule details keyed by scheduleId
    approvedSchedules[scheduleId] = @{
        @"blocklist": blocklist ?: @[],
        @"isAllowlist": @(isAllowlist),
        @"blockSettings": blockSettings ?: @{},
        @"controllingUID": @(controllingUID),
        @"approvedStartDate": startDate,
        @"approvedEndDate": endDate,
        @"registeredAt": [NSDate date]
    };

    [settings setValue: approvedSchedules forKey: @"ApprovedSchedules"];
    NSError *syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) {
        SCDaemonXPCLogError(@"Schedule registration persistence failed", syncError);
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply(syncError);
        return;
    }

    NSLog(@"SCDaemonXPC: Schedule registered successfully");
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"legacy"];
    reply(nil);
}

// Start a pre-registered schedule - NO authorization required (schedule was pre-approved)
- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                            reply:(void(^)(NSError* error))reply {
    [self startScheduledBlockWithID:scheduleId
                            endDate:endDate
                      executionPath:@"xpc_direct"
                              reply:reply];
}

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                    executionPath:(NSString*)executionPath
                            reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: startScheduledBlockWithID");

    NSString *safePath = [executionPath isEqualToString:@"cli_launchd"]
        ? @"cli_launchd" : @"xpc_direct";

    // NO authorization check - we trust the schedule because it was pre-approved
    // and stored in root-only settings file

    // Look up the approved schedule
    SCSettings* settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }
    NSDictionary* approvedSchedules = [settings valueForKey: @"ApprovedSchedules"];
    NSDictionary *safeApprovedSchedules = [approvedSchedules isKindOfClass:[NSDictionary class]]
        ? approvedSchedules : @{};
    NSLog(@"DAEMON: ApprovedSchedules count = %lu", (unsigned long)safeApprovedSchedules.count);

    BOOL validScheduleID = [scheduleId isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:scheduleId] != nil;
    NSDictionary* schedule = validScheduleID ? safeApprovedSchedules[scheduleId] : nil;

    void (^spoolFailure)(NSInteger) = ^(NSInteger errorCode) {
        NSArray *candidateList = [schedule[@"blocklist"] isKindOfClass:[NSArray class]]
            ? schedule[@"blocklist"] : @[];
        NSDictionary *fields = @{
            @"path": safePath,
            @"block_already_running": @([SCBlockUtilities anyBlockIsRunning]),
            @"minutes_late_bucket": @(SCScheduleMinutesLateBucket(schedule[@"approvedStartDate"])),
            @"approved_count": @(SCScheduleCountOwnedApprovals(safeApprovedSchedules, self.clientUID)),
            @"list_count": @(candidateList.count),
            @"error_code": @(errorCode),
        };
        NSError *spoolError = nil;
        [self.telemetrySpool appendEventName:@"schedule.exec_failed"
                                       level:SCTelemetryEventLevelError
                                      fields:fields
                                      origin:SCTelemetryOriginDaemon
                                      forUID:self.clientUID
                                       error:&spoolError];
        if (spoolError != nil) {
            SCDaemonXPCLogError(@"Could not spool schedule execution failure", spoolError);
        }
    };

    if (schedule == nil) {
        NSLog(@"SCDaemonXPC: Requested schedule was not found in approved schedules");
        spoolFailure(403);
        reply([SCErr errorWithCode: 403 subDescription: @"Schedule not registered or unauthorized"]);
        return;
    }

    NSLog(@"SCDaemonXPC: Found approved schedule");

    NSNumber *scheduleOwner = schedule[@"controllingUID"];
    NSDate *approvedStartDate = schedule[@"approvedStartDate"];
    NSDate *approvedEndDate = schedule[@"approvedEndDate"];
    if (!SCDaemonClientOwnsSchedule(self.clientUID, scheduleOwner) ||
        !SCDaemonScheduledStartRequestIsValid(endDate,
                                               approvedStartDate,
                                               approvedEndDate,
                                               [NSDate date])) {
        NSLog(@"SCDaemonXPC: Scheduled start failed ownership or bounds precondition");
        spoolFailure(403);
        reply([SCErr errorWithCode:403 subDescription:@"Scheduled start precondition failed"]);
        return;
    }

    // Extract schedule parameters
    NSArray* blocklist = schedule[@"blocklist"];
    NSDictionary* blockSettings = schedule[@"blockSettings"];
    if (![blocklist isKindOfClass:[NSArray class]] ||
        ![blockSettings isKindOfClass:[NSDictionary class]]) {
        spoolFailure(403);
        reply([SCErr errorWithCode:403 subDescription:@"Approved schedule state was invalid"]);
        return;
    }

    NSLog(@"DAEMON: blocklist count = %lu", (unsigned long)blocklist.count);

    if (blocklist.count == 0) {
        NSLog(@"DAEMON WARNING: Blocklist is EMPTY! Block may not do anything.");
    }

    NSLog(@"DAEMON: Calling startBlockWithControllingUID...");

    // Start the block without authorization (it was pre-approved), while
    // preserving the provenance required for idempotent legacy/V2 arbitration.
    [SCDaemonBlockMethods startScheduledBlockWithID:scheduleId
                                             record:schedule
                                              reply:^(NSError *error) {
        if (error) {
            SCDaemonXPCLogError(@"startScheduledBlock failed", error);
            spoolFailure(error.code);
        } else {
            NSLog(@"SCDaemonXPC: Scheduled block started successfully");
        }
        NSLog(@"SCDaemonXPC: startScheduledBlockWithID complete");
        reply(error);
    }];
}

// Unregister a schedule - requires authorization
- (void)unregisterScheduleWithID:(NSString*)scheduleId
                   authorization:(NSData *)authData
                           reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: unregisterScheduleWithID");

    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: @selector(startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:)];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"unregisterSchedule authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    }

    if (![SCDaemonBlockMethods lockOrTimeout:reply]) return;

    SCSettings* settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }
    NSMutableDictionary* approvedSchedules = [[settings valueForKey: @"ApprovedSchedules"] mutableCopy];
    if (approvedSchedules != nil) {
        NSDictionary *storedSchedule = [approvedSchedules[scheduleId] isKindOfClass:[NSDictionary class]]
            ? approvedSchedules[scheduleId] : nil;
        NSNumber *owner = storedSchedule[@"controllingUID"];
        NSDate *end = storedSchedule[@"approvedEndDate"];
        BOOL liveV2 = [storedSchedule[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2 &&
            [end isKindOfClass:[NSDate class]] && [end compare:[NSDate date]] == NSOrderedDescending;
        if (storedSchedule == nil || !SCDaemonClientOwnsSchedule(self.clientUID, owner) || liveV2) {
            [SCDaemonBlockMethods.daemonMethodLock unlock];
            reply([SCErr errorWithCode:403
                        subDescription:@"Root-owned schedule cannot be unregistered before expiry"]);
            return;
        }
        [approvedSchedules removeObjectForKey: scheduleId];
        [settings setValue: approvedSchedules forKey: @"ApprovedSchedules"];
        NSError *syncError = [settings syncSettingsAndWait:5];
        if (syncError != nil) {
            SCDaemonXPCLogError(@"Schedule unregistration persistence failed", syncError);
            [SCDaemonBlockMethods.daemonMethodLock unlock];
            reply(syncError);
            return;
        }
    }

    NSLog(@"SCDaemonXPC: Schedule unregistered successfully");
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation"];
    reply(nil);
}

- (void)clearAllApprovedSchedulesWithAuthorization:(NSData *)authData
                                             reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: clearAllApprovedSchedules");

    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: @selector(startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:)];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"clearAllApprovedSchedules authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    }

    if (![SCDaemonBlockMethods lockOrTimeout:reply]) return;

#ifndef DEBUG
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    reply([SCErr errorWithCode:403 subDescription:@"Bulk schedule clearing is debug-only"]);
    return;
#else

    SCSettings* settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }
    [settings setValue:nil forKey:@"ApprovedSchedules"];
    [settings setValue:nil forKey:SCDaemonApprovedScheduleCommitmentsKey];
    NSError *syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) {
        SCDaemonXPCLogError(@"Approved schedule clear persistence failed", syncError);
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply(syncError);
        return;
    }

    NSLog(@"INFO: All approved schedules cleared successfully");
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation"];
    reply(nil);
#endif
}

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                 entries:(NSArray<NSString*>*)entries
                                   reply:(void(^)(NSError* error))reply {
    [self appendEntriesToApprovedSchedules:expectedBlocklistsByScheduleID
                                   entries:entries
                               resultReply:^(NSDictionary<NSString *,id> *result, NSError *error) {
        reply(error);
    }];
}

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                 entries:(NSArray<NSString*>*)entries
                             resultReply:(void(^)(NSDictionary<NSString *,id> *result,
                                                  NSError *error))reply {
    NSLog(@"XPC method called: appendEntriesToApprovedSchedules (structured result)");

    NSUInteger requestedCount = [entries isKindOfClass:[NSArray class]] ? entries.count : 0;
    NSUInteger candidateCount = [expectedBlocklistsByScheduleID isKindOfClass:[NSDictionary class]]
        ? expectedBlocklistsByScheduleID.count : 0;
    __block NSMutableDictionary<NSString *, id> *result = [@{
        @"schema_version": @1,
        @"requested_count": @(requestedCount),
        @"candidate_count": @(candidateCount),
        @"matched_count": @0,
        @"updated_count": @0,
        @"skipped_count": @(candidateCount),
        @"legacy_candidate_count": @0,
        @"scheduler_record_count": @0,
        @"loaded_job_count": @0,
        @"launchd_probe_failure_count": @0,
        @"settings_persisted": @NO,
        @"future_verified": @NO,
        @"outcome": @"failed",
        @"failed_stage": @"precondition",
    } mutableCopy];

    void (^replySafely)(NSError *) = ^(NSError *error) {
        NSDictionary *immutableResult = [result copy];
        if (![SCSentry payloadPassesTelemetryPrivacyTripwire:immutableResult]) {
            NSError *privacyError = [NSError errorWithDomain:SCTelemetrySpoolErrorDomain
                                                         code:SCTelemetrySpoolErrorPrivacyRejected
                                                     userInfo:nil];
            reply(@{}, privacyError);
            return;
        }
        reply(immutableResult, error);
    };

    if (![SCDaemonBlockMethods lockOrTimeout:^(NSError *lockError) {
        result[@"failed_stage"] = @"lock";
        replySafely(lockError);
    }]) return;

    SCSettings *settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        result[@"failed_stage"] = @"resolution";
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        replySafely([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }

    NSUInteger validInputCount = 0;
    for (id rawEntry in entries ?: @[]) {
        if ([rawEntry isKindOfClass:[NSString class]] &&
            [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] != nil) {
            validInputCount += 1;
        }
    }
    NSArray<NSString *> *sanitizedEntries = [SCDaemonBlockMethods sanitizedBlocklistEntries:entries];
    if (validInputCount != requestedCount) {
        result[@"failed_stage"] = @"canonicalize";
        NSError *error = [SCErr errorWithCode:500 subDescription:@"Approved schedule append contained invalid entries"];
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        replySafely(error);
        return;
    }

    if (candidateCount == 0 || requestedCount == 0) {
        result[@"outcome"] = @"skipped";
        result[@"failed_stage"] = @"none";
        result[@"settings_persisted"] = @YES;
        result[@"future_verified"] = @YES;
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        replySafely(nil);
        return;
    }

    id approvedValue = [settings valueForKey:@"ApprovedSchedules"];
    NSMutableDictionary *approvedSchedules = [approvedValue isKindOfClass:[NSDictionary class]]
        ? [approvedValue mutableCopy] : nil;
    if (approvedSchedules == nil) {
        result[@"failed_stage"] = @"resolution";
        NSError *error = [SCErr errorWithCode:500 subDescription:@"Approved schedules were unavailable"];
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        replySafely(error);
        return;
    }

    __block NSUInteger matchedCount = 0;
    __block NSUInteger updatedCount = 0;
    __block NSUInteger retryMatchedCount = 0;
    __block NSUInteger legacyCandidateCount = 0;
    __block NSUInteger schedulerRecordCount = 0;
    NSString *activeScheduleID = [[settings valueForKey:@"ActiveScheduleID"] isKindOfClass:[NSString class]]
        ? [settings valueForKey:@"ActiveScheduleID"] : @"";
    NSString *activeSource = [[settings valueForKey:@"ActiveBlockSource"] isKindOfClass:[NSString class]]
        ? [settings valueForKey:@"ActiveBlockSource"] : @"";
    NSNumber *activeOwner = [[settings valueForKey:@"ActiveBlockControllingUID"] isKindOfClass:[NSNumber class]]
        ? [settings valueForKey:@"ActiveBlockControllingUID"] : @0;
    BOOL schedulerOwnedActive = [SCBlockUtilities modernBlockIsRunning] &&
        activeOwner.unsignedIntValue == self.clientUID &&
        ([activeSource isEqualToString:SCDaemonActiveBlockSourceSchedulerV2] ||
         [activeSource isEqualToString:SCDaemonActiveBlockSourceLegacySchedule]);
    __block NSArray<NSString *> *activeExpectedBlocklist = nil;
    NSMutableSet<NSString *> *matchedScheduleIDs = [NSMutableSet set];
    [expectedBlocklistsByScheduleID enumerateKeysAndObjectsUsingBlock:^(id scheduleID,
                                                                        id expectedBlocklist,
                                                                        BOOL *stop) {
        if (![scheduleID isKindOfClass:[NSString class]] ||
            ![expectedBlocklist isKindOfClass:[NSArray class]]) return;

        NSUInteger validExpectedCount = 0;
        for (id rawEntry in expectedBlocklist) {
            if ([rawEntry isKindOfClass:[NSString class]] &&
                [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] != nil) {
                validExpectedCount += 1;
            }
        }
        NSArray<NSString *> *sanitizedExpected =
            [SCDaemonBlockMethods sanitizedBlocklistEntries:expectedBlocklist];
        if (validExpectedCount != [expectedBlocklist count] || sanitizedExpected.count == 0) return;

        NSDictionary *schedule = approvedSchedules[scheduleID];
        if (![schedule isKindOfClass:[NSDictionary class]]) return;
        NSNumber *owner = schedule[@"controllingUID"];
        if (![owner isKindOfClass:[NSNumber class]] || owner.unsignedIntValue != self.clientUID) return;
        if ([schedule[@"isAllowlist"] boolValue]) return;

        NSArray *blocklist = [schedule[@"blocklist"] isKindOfClass:[NSArray class]]
            ? [SCDaemonBlockMethods sanitizedBlocklistEntries:schedule[@"blocklist"]] : @[];
        NSSet *blocklistSet = [NSSet setWithArray:blocklist];
        NSSet *expectedSet = [NSSet setWithArray:sanitizedExpected];
        NSMutableOrderedSet *expectedAfterAppend =
            [NSMutableOrderedSet orderedSetWithArray:sanitizedExpected];
        [expectedAfterAppend addObjectsFromArray:sanitizedEntries];
        NSSet *expectedAfterSet = [NSSet setWithArray:expectedAfterAppend.array];
        BOOL matchesOriginalPrecondition = blocklistSet.count == expectedSet.count &&
            [expectedSet isSubsetOfSet:blocklistSet];
        BOOL matchesPriorAppend = blocklistSet.count == expectedAfterSet.count &&
            [expectedAfterSet isSubsetOfSet:blocklistSet];
        if (!matchesOriginalPrecondition && !matchesPriorAppend) return;

        matchedCount += 1;
        [matchedScheduleIDs addObject:scheduleID];
        if (schedulerOwnedActive && [scheduleID isEqual:activeScheduleID]) {
            activeExpectedBlocklist = sanitizedExpected;
        }
        if ([schedule[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2) {
            schedulerRecordCount += 1;
        } else {
            legacyCandidateCount += 1;
        }

        // A retry can observe the exact already-unioned root state. Count it
        // as matched and verified without rewriting or duplicating entries.
        if (!matchesOriginalPrecondition && matchesPriorAppend) {
            retryMatchedCount += 1;
            return;
        }

        NSMutableOrderedSet *updatedEntries = [NSMutableOrderedSet orderedSetWithArray:blocklist];
        NSUInteger beforeCount = updatedEntries.count;
        [updatedEntries addObjectsFromArray:sanitizedEntries];
        if (updatedEntries.count == beforeCount) return;

        NSMutableDictionary *updatedSchedule = [schedule mutableCopy];
        updatedSchedule[@"blocklist"] = updatedEntries.array;
        approvedSchedules[scheduleID] = updatedSchedule;
        updatedCount += 1;
    }];

    NSUInteger skippedCount = candidateCount - MIN(candidateCount, matchedCount);
    result[@"matched_count"] = @(matchedCount);
    result[@"updated_count"] = @(updatedCount);
    result[@"skipped_count"] = @(skippedCount);
    result[@"legacy_candidate_count"] = @(legacyCandidateCount);
    result[@"scheduler_record_count"] = @(schedulerRecordCount);

    __block NSError *activeCouplingError = nil;
    if (activeExpectedBlocklist != nil && sanitizedEntries.count > 0) {
        [SCDaemonBlockMethods appendEntriesToActiveBlocklistWhileHoldingDaemonLock:sanitizedEntries
                                                         matchingExistingBlocklist:activeExpectedBlocklist
                                                                        resultReply:^(NSDictionary<NSString *,id> *activeResult,
                                                                                      NSError *error) {
            activeCouplingError = error;
            if (error != nil) {
                NSString *stage = [activeResult[@"failed_stage"] isKindOfClass:[NSString class]]
                    ? activeResult[@"failed_stage"] : @"physical_apply";
                result[@"failed_stage"] = stage;
            }
        }];
        if (activeCouplingError != nil) {
            result[@"outcome"] = @"failed";
            [SCDaemonBlockMethods.daemonMethodLock unlock];
            replySafely(activeCouplingError);
            return;
        }
    }

    NSError *syncError = nil;
    if (updatedCount > 0 || retryMatchedCount > 0) {
        [settings setValue:approvedSchedules forKey:@"ApprovedSchedules"];
        syncError = [settings syncSettingsAndWait:5];
    }
    result[@"settings_persisted"] = @(syncError == nil);
    NSDictionary *persistedApprovedValue = [settings valueForKey:@"ApprovedSchedules"];
    NSDictionary *persistedApprovedSchedules = [persistedApprovedValue isKindOfClass:[NSDictionary class]]
        ? persistedApprovedValue : @{};

    BOOL matchedSchedulesVerified = YES;
    NSSet *additionSet = [NSSet setWithArray:sanitizedEntries];
    for (NSString *scheduleID in matchedScheduleIDs) {
        NSDictionary *schedule = persistedApprovedSchedules[scheduleID];
        NSArray *blocklist = [schedule[@"blocklist"] isKindOfClass:[NSArray class]]
            ? [SCDaemonBlockMethods sanitizedBlocklistEntries:schedule[@"blocklist"]] : @[];
        NSSet *blocklistSet = [NSSet setWithArray:blocklist];
        if (![additionSet isSubsetOfSet:blocklistSet]) {
            matchedSchedulesVerified = NO;
            break;
        }
    }

    NSUInteger loadedJobCount = 0;
    NSUInteger launchdProbeFailureCount = 0;
    // Keep the probe budget comfortably inside the app's 10-second aggregate
    // strictify timeout even if the preceding settings sync uses its full
    // five-second allowance.
    NSDate *launchdDeadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    for (NSString *scheduleID in matchedScheduleIDs) {
        NSDictionary *schedule = persistedApprovedSchedules[scheduleID];
        if ([schedule[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2) continue;
        NSDate *startDate = [schedule[@"approvedStartDate"] isKindOfClass:[NSDate class]]
            ? schedule[@"approvedStartDate"] : nil;
        NSString *label = SCDaemonScheduleJobLabel(scheduleID, startDate);
        BOOL probeSucceeded = NO;
        BOOL loaded = label != nil && SCDaemonLaunchdJobIsLoaded(
            self.clientUID, label, launchdDeadline, &probeSucceeded);
        if (!probeSucceeded) {
            launchdProbeFailureCount += 1;
        } else if (loaded) {
            loadedJobCount += 1;
        }
    }
    result[@"loaded_job_count"] = @(loadedJobCount);
    result[@"launchd_probe_failure_count"] = @(launchdProbeFailureCount);

    BOOL futureVerified = SCDaemonFutureStrictifyPostconditionsSatisfiedV2(
        syncError == nil,
        candidateCount,
        matchedCount,
        matchedSchedulesVerified,
        legacyCandidateCount,
        loadedJobCount,
        schedulerRecordCount,
        launchdProbeFailureCount);
    result[@"future_verified"] = @(futureVerified);
    NSError *resultError = nil;
    if (futureVerified) {
        result[@"outcome"] = @"verified";
        result[@"failed_stage"] = @"none";
    } else if (syncError != nil) {
        result[@"outcome"] = @"failed";
        result[@"failed_stage"] = @"settings_sync";
        resultError = syncError;
    } else if (matchedCount == candidateCount && matchedSchedulesVerified &&
               (loadedJobCount != legacyCandidateCount || launchdProbeFailureCount > 0)) {
        result[@"outcome"] = @"failed";
        result[@"failed_stage"] = @"job_verification";
        resultError = [SCErr errorWithCode:500 subDescription:@"Legacy approved schedule jobs did not verify"];
    } else if (matchedCount > 0 && matchedSchedulesVerified) {
        result[@"outcome"] = @"partial";
        result[@"failed_stage"] = @"precondition";
        resultError = [SCErr errorWithCode:500 subDescription:@"Some approved schedules did not match"];
    } else {
        result[@"outcome"] = @"failed";
        result[@"failed_stage"] = matchedCount == 0 ? @"precondition" : @"verification";
        resultError = [SCErr errorWithCode:500 subDescription:@"Approved schedule append did not verify"];
    }

    if (resultError != nil) [SCSentry captureError:resultError];
    NSLog(@"appendEntriesToApprovedSchedules: candidates=%lu matched=%lu updated=%lu skipped=%lu",
          (unsigned long)candidateCount,
          (unsigned long)matchedCount,
          (unsigned long)updatedCount,
          (unsigned long)skippedCount);
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    if (syncError == nil && matchedCount > 0) {
        [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation"];
    }
    replySafely(resultError);
}

- (void)clearBlockForDebugWithAuthorization:(NSData *)authData
                                      reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: clearBlockForDebug");

#ifdef DEBUG
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: @selector(startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:)];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            SCDaemonXPCLogError(@"clearBlockForDebug authorization failed", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    }

    NSLog(@"WARNING: Forcibly clearing active block (DEBUG MODE)");
    [SCHelperToolUtilities removeBlock];

    NSLog(@"INFO: Block cleared via debug method");
    reply(nil);
#else
    NSLog(@"ERROR: clearBlockForDebug called in non-DEBUG build - ignoring");
    reply([SCErr errorWithCode: 500 subDescription: @"Debug methods not available in release builds"]);
#endif
}

- (void)isPFBlockActiveWithReply:(void(^)(BOOL active))reply {
    // No authorization needed - this is a read-only query
    // Delegate to SCDaemonBlockMethods which has access to PacketFilter
    [[SCDaemonBlockMethods new] isPFBlockActiveWithReply:reply];
}

- (void)stopTestBlockWithReply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: stopTestBlock");

    // NO authorization required - test blocks are meant to be freely stoppable
    // But we MUST verify this is actually a test block
    SCSettings* settings = [SCSettings sharedSettings];
    BOOL isTestBlock = [[settings valueForKey:@"IsTestBlock"] boolValue];

    if (!isTestBlock) {
        NSLog(@"ERROR: stopTestBlock called but IsTestBlock=NO - refusing to stop");
        reply([SCErr errorWithCode: 401 subDescription: @"Not a test block - cannot stop without emergency unlock"]);
        return;
    }

    [SCDaemonBlockMethods stopTestBlock:reply];
}

- (void)clearExpiredBlockWithReply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: clearExpiredBlock");

    // NO authorization required - the block is already expired, user's commitment fulfilled
    // This is the same operation that checkupBlock would do automatically
    // We're just doing it synchronously when CLI detects the situation (e.g., after sleep/wake)

    if (![SCDaemonBlockMethods lockOrTimeout:^(NSError *lockError) {
        reply(lockError);
    }]) return;

    SCSettings *settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }

    // Check under the same daemon-wide lock used for teardown so block state
    // cannot change between the expiry decision and physical removal.
    id blockEndValue = [settings valueForKey:@"BlockEndDate"];
    BOOL hasVerifiedExpiredEnd = [blockEndValue isKindOfClass:[NSDate class]] &&
        [(NSDate *)blockEndValue compare:[NSDate date]] != NSOrderedDescending;
    if (!hasVerifiedExpiredEnd) {
        NSLog(@"ERROR: clearExpiredBlock called but block is NOT expired!");
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode: 310 subDescription: @"Block is not expired - cannot clear"]);
        return;
    }

    BOOL teardownVerified = [SCDaemonBlockMethods removeBlockWithTelemetry];
    if (!teardownVerified) {
        // removeBlockWithTelemetry keeps declared state intact, records a
        // privacy-safe failure, and leaves the checkup timer running for retry.
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:500
                    subDescription:@"Expired block teardown did not verify"]);
        return;
    }

    [[SCDaemon sharedDaemon] stopCheckupTimer];
    [SCDaemonBlockMethods.daemonMethodLock unlock];
    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation"];
    NSLog(@"clearExpiredBlock: Successfully cleared expired block");
    reply(nil);
}

- (void)cleanupStaleScheduleWithID:(NSString*)scheduleId
                             reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: cleanupStaleScheduleWithID");

    BOOL validScheduleID = [scheduleId isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:scheduleId] != nil;
    if (!validScheduleID) {
        reply([SCErr errorWithCode:403 subDescription:@"Schedule cleanup precondition failed"]);
        return;
    }
    if (![SCDaemonBlockMethods lockOrTimeout:reply]) return;

    SCSettings *settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:SCSettingsStateUnavailableErrorCode]);
        return;
    }
    NSDictionary *approvedValue = [settings valueForKey:@"ApprovedSchedules"];
    NSDictionary *approvedSchedules = [approvedValue isKindOfClass:[NSDictionary class]]
        ? approvedValue : @{};
    NSDictionary *schedule = [approvedSchedules[scheduleId] isKindOfClass:[NSDictionary class]]
        ? approvedSchedules[scheduleId] : nil;
    NSNumber *owner = schedule[@"controllingUID"];
    NSDate *approvedEndDate = schedule[@"approvedEndDate"];
    BOOL expired = [approvedEndDate isKindOfClass:[NSDate class]] &&
        [approvedEndDate compare:[NSDate date]] != NSOrderedDescending;
    if (![schedule isKindOfClass:[NSDictionary class]] ||
        !SCDaemonClientOwnsSchedule(self.clientUID, owner) || !expired) {
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply([SCErr errorWithCode:403 subDescription:@"Schedule cleanup precondition failed"]);
        return;
    }

    NSMutableDictionary *updatedSchedules = [approvedSchedules mutableCopy];
    [updatedSchedules removeObjectForKey:scheduleId];
    NSDictionary *commitmentValue = [settings valueForKey:SCDaemonApprovedScheduleCommitmentsKey];
    NSDictionary *oldCommitments = [commitmentValue isKindOfClass:[NSDictionary class]]
        ? commitmentValue : @{};
    NSMutableDictionary *updatedCommitments = [oldCommitments mutableCopy];
    NSDate *now = [NSDate date];
    [oldCommitments enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        NSDictionary *envelope = [value isKindOfClass:[NSDictionary class]] ? value : nil;
        NSNumber *envelopeOwner = envelope[@"controllingUID"];
        NSDate *end = envelope[@"weekEndDate"];
        if (envelope != nil && SCDaemonClientOwnsSchedule(self.clientUID, envelopeOwner) &&
            [end isKindOfClass:[NSDate class]] && [end compare:now] != NSOrderedDescending) {
            [updatedCommitments removeObjectForKey:key];
        }
    }];
    [settings setValue:updatedSchedules forKey:@"ApprovedSchedules"];
    [settings setValue:updatedCommitments forKey:SCDaemonApprovedScheduleCommitmentsKey];
    NSError *syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) {
        [settings setValue:approvedSchedules forKey:@"ApprovedSchedules"];
        [settings setValue:oldCommitments forKey:SCDaemonApprovedScheduleCommitmentsKey];
        [settings syncSettingsAndWait:5];
        [SCDaemonBlockMethods.daemonMethodLock unlock];
        reply(syncError);
        return;
    }
    [SCDaemonBlockMethods.daemonMethodLock unlock];

    [[SCDaemon sharedDaemon] cleanupLegacyScheduleArtifactsWithID:scheduleId
                                                   controllingUID:self.clientUID];
    [[SCDaemon sharedDaemon] scheduleStateDidChangeWithTrigger:@"mutation"];

    NSLog(@"SCDaemonXPC: Stale schedule cleaned up successfully");
    reply(nil);
}

@end

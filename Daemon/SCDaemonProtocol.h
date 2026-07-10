//
//  SCDaemonProtocol.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Increment this only when the daemon's XPC contract changes in a way the app
// must be able to detect. Marketing versions are not protocol versions: older
// Fence releases used a separate version line for the daemon, so comparing the
// two can incorrectly retain a daemon that does not implement newer selectors.
typedef NS_ENUM(NSInteger, SCDaemonProtocolVersion) {
    SCDaemonProtocolVersionLegacy = 0,
    SCDaemonProtocolVersionStrictAppend = 1,
    SCDaemonProtocolVersionTelemetrySpool = 2,
    SCDaemonProtocolVersionExactConsistency = 3,
    SCDaemonProtocolVersionScheduleExecutionSource = 4,
    SCDaemonProtocolVersionCurrent = SCDaemonProtocolVersionScheduleExecutionSource,
};

// These names are intentionally static and contain no blocklist or user data.
#define SCDaemonCapabilityActiveBlocklistAppend @"active-blocklist-append-v1"
#define SCDaemonCapabilityApprovedSchedulesAppend @"approved-schedules-append-v1"
#define SCDaemonCapabilityTelemetrySpool @"telemetry-spool-v1"
#define SCDaemonCapabilityStrictApplyResults @"strict-apply-results-v1"
#define SCDaemonCapabilityScheduleOwnerBounds @"schedule-owner-bounds-v1"
#define SCDaemonCapabilityConsistencyProjection @"consistency-projection-v1"

/// Pure ownership predicate shared with focused tests. A known owner must
/// match exactly. Legacy ownerless blocks may be strictified only by the
/// current non-root console user.
NS_INLINE BOOL SCDaemonClientMayStrictifyActiveBlock(uid_t clientUID,
                                                      NSNumber * _Nullable activeOwner,
                                                      uid_t consoleUID) {
    BOOL ownerKnown = [activeOwner isKindOfClass:[NSNumber class]] && activeOwner.longLongValue > 0;
    if (ownerKnown) return activeOwner.unsignedIntValue == clientUID;
    return consoleUID > 0 && consoleUID == clientUID;
}

NS_INLINE BOOL SCDaemonClientOwnsSchedule(uid_t clientUID, NSNumber * _Nullable scheduleOwner) {
    return [scheduleOwner isKindOfClass:[NSNumber class]] &&
        scheduleOwner.longLongValue >= 0 && scheduleOwner.unsignedIntValue == clientUID;
}

/// An idempotent strictify request still has to exercise the physical layers.
/// The settings precondition only proves that the entry is recorded, not that
/// its hosts, PF, or process-monitoring enforcement survived.
NS_INLINE BOOL SCDaemonActiveStrictifyRequiresPhysicalReapply(NSUInteger canonicalRequestCount,
                                                               NSUInteger newlyAddedCount,
                                                               BOOL matchesOriginalPrecondition,
                                                               BOOL isRetryUnionState) {
    return canonicalRequestCount > 0 &&
        (isRetryUnionState ||
         (newlyAddedCount == 0 && matchesOriginalPrecondition));
}

/// Future strictification is verified only when every requested approval was
/// updated and its launchd job can be proven loaded. These are aggregate
/// postconditions; labels and schedule identifiers never cross the reply.
NS_INLINE BOOL SCDaemonFutureStrictifyPostconditionsSatisfied(BOOL settingsPersisted,
                                                               NSUInteger candidateCount,
                                                               NSUInteger matchedCount,
                                                               BOOL matchedSchedulesVerified,
                                                               NSUInteger loadedJobCount,
                                                               NSUInteger launchdProbeFailureCount) {
    return settingsPersisted && candidateCount > 0 &&
        matchedCount == candidateCount && matchedSchedulesVerified &&
        loadedJobCount == candidateCount && launchdProbeFailureCount == 0;
}

/// Exact consistency must fail closed on physical remnants even when the app
/// has no active commitment projection to compare with daemon settings.
NS_INLINE BOOL SCAppDaemonActiveStateMatches(BOOL projectionAvailable,
                                              BOOL activeComparisonAvailable,
                                              BOOL activeEntriesMatch,
                                              BOOL blockRunning,
                                              BOOL expectedBlockRunning,
                                              BOOL physicalLayersMatch) {
    if (!physicalLayersMatch) return NO;
    if (!projectionAvailable) return !blockRunning;
    return activeComparisonAvailable && activeEntriesMatch &&
        blockRunning == expectedBlockRunning;
}

/// Scheduled starts must occur inside the root-approved window and request the
/// approved end (allowing only sub-second serialization loss toward an earlier
/// end). The daemon still applies the exact root-owned end date.
NS_INLINE BOOL SCDaemonScheduledStartRequestIsValid(NSDate * _Nullable requestedEndDate,
                                                     NSDate * _Nullable approvedStartDate,
                                                     NSDate * _Nullable approvedEndDate,
                                                     NSDate *now) {
    if (![requestedEndDate isKindOfClass:[NSDate class]] ||
        ![approvedStartDate isKindOfClass:[NSDate class]] ||
        ![approvedEndDate isKindOfClass:[NSDate class]] ||
        ![now isKindOfClass:[NSDate class]]) return NO;
    if ([approvedStartDate compare:now] == NSOrderedDescending) return NO;
    if ([approvedEndDate compare:now] != NSOrderedDescending) return NO;
    if ([requestedEndDate compare:approvedEndDate] == NSOrderedDescending) return NO;
    if ([approvedEndDate timeIntervalSinceDate:requestedEndDate] > 1.0) return NO;
    return [requestedEndDate compare:now] == NSOrderedDescending;
}

@protocol SCDaemonProtocol <NSObject>

// XPC method to start block
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to add to blocklist
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to append stricter entries to the active blocklist.
// No authorization prompt: the daemon validates signed callers and this can only add entries.
- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply;

// Structured v2 variant. The result contains typed outcomes/counts and the
// physical apply postconditions, never entries or identifiers.
- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString *, id> *result,
                                                 NSError * _Nullable error))reply;

// XPC method to extend block
- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to get version of the installed daemon
- (void)getVersionWithReply:(void(^)(NSString * version))reply;

// XPC method to determine whether the installed daemon implements the contract
// required by this app. Build and marketing versions are diagnostic only;
// compatibility is determined by the monotonic protocol and capability names.
- (void)getCompatibilityInfoWithReply:(void(^)(NSInteger protocolVersion,
                                                NSString *buildVersion,
                                                NSString *marketingVersion,
                                                NSArray<NSString *> *capabilities))reply;

// Privacy-safe telemetry transport. The daemon binds each exported object to
// the already code-signature-validated connection's effective UID, so callers
// cannot select another user's queue.
- (void)setTelemetryConsentEnabled:(BOOL)enabled
                        generation:(NSUInteger)generation
                             reply:(void(^)(NSError * _Nullable error))reply;

- (void)fetchTelemetryRecordsWithLimit:(NSUInteger)limit
                                  reply:(void(^)(NSArray<NSDictionary<NSString *, id> *> *records,
                                                 NSError * _Nullable error))reply;

- (void)acknowledgeTelemetryRecordIDs:(NSArray<NSString *> *)recordIDs
                                 reply:(void(^)(NSError * _Nullable error))reply;

// Sanitized cross-layer state for the authenticated connection's UID. Values
// are booleans, counts, static enums, and binary metadata only.
- (void)getSanitizedDaemonSnapshotWithReply:(void(^)(NSDictionary<NSString *, id> *snapshot,
                                                      NSError * _Nullable error))reply;

// Exact local comparison variant. `expectedState` stays inside the signed XPC
// boundary and may contain entries/dates. The reply is privacy-safe and
// contains only static enums, booleans, and aggregate counts/deltas.
- (void)getSanitizedDaemonSnapshotForExpectedState:(NSDictionary<NSString *, id> *)expectedState
                                             reply:(void(^)(NSDictionary<NSString *, id> *snapshot,
                                                            NSError * _Nullable error))reply;

// XPC method to register a schedule (requires authorization, stores approved schedule)
- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                   startDate:(NSDate*)startDate
                     endDate:(NSDate*)endDate
                 authorization:(NSData *)authData
                         reply:(void(^)(NSError* error))reply;

// XPC method to start a pre-registered schedule (NO authorization required)
- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                            reply:(void(^)(NSError* error))reply;

/// Source-aware variant used so root-side failure telemetry can distinguish a
/// launchd-fired CLI execution from an app/direct recovery request. The daemon
/// accepts only the static values cli_launchd and xpc_direct.
- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                    executionPath:(NSString*)executionPath
                            reply:(void(^)(NSError* error))reply;

// XPC method to unregister a schedule
- (void)unregisterScheduleWithID:(NSString*)scheduleId
                   authorization:(NSData *)authData
                           reply:(void(^)(NSError* error))reply;

// XPC method to clear all approved schedules (for debug reset)
- (void)clearAllApprovedSchedulesWithAuthorization:(NSData *)authData
                                             reply:(void(^)(NSError* error))reply;

// XPC method to append stricter entries to selected pre-approved schedules.
// Each selected schedule must contain the provided existing entries before it is changed.
- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                 entries:(NSArray<NSString*>*)entries
                                   reply:(void(^)(NSError* error))reply;

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                 entries:(NSArray<NSString*>*)entries
                             resultReply:(void(^)(NSDictionary<NSString *, id> *result,
                                                  NSError * _Nullable error))reply;

// XPC method to forcibly clear an active block (DEBUG ONLY)
- (void)clearBlockForDebugWithAuthorization:(NSData *)authData
                                      reply:(void(^)(NSError* error))reply;

// XPC method to check if PF block is active (runs as root, can query pfctl)
- (void)isPFBlockActiveWithReply:(void(^)(BOOL active))reply;

// XPC method to stop a test block (only works when IsTestBlock=YES, no auth required)
- (void)stopTestBlockWithReply:(void(^)(NSError* _Nullable error))reply;

// XPC method to clear an expired block (no auth required - block already expired)
// This clears PF rules, /etc/hosts, AppBlocker, and sets BlockIsRunning=NO
// Used when CLI detects an expired block that wasn't cleared (e.g., after sleep/wake)
- (void)clearExpiredBlockWithReply:(void(^)(NSError* _Nullable error))reply;

// XPC method to cleanup a stale schedule (expired endDate)
// Removes from ApprovedSchedules and deletes launchd job plist
// No authorization required - this is cleanup of pre-authorized schedules
- (void)cleanupStaleScheduleWithID:(NSString*)scheduleId
                             reply:(void(^)(NSError* _Nullable error))reply;

@end

NS_ASSUME_NONNULL_END

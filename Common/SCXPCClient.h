//
//  SCAppXPC.h
//  SelfControl
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCXPCClient : NSObject

@property (readonly, getter=isConnected) BOOL connected;
@property (atomic, assign, readonly) BOOL connectionIsValid;

- (void)connectToHelperTool;
- (void)forceDisconnect;
- (void)installDaemon:(void(^)(NSError*))callback;
- (BOOL)refreshAuthorizationRights:(NSError **)error;
- (BOOL)refreshAuthorizationRightsAllowingInteraction:(BOOL)allowInteraction error:(NSError **)error;
- (void)refreshConnectionAndRun:(void(^)(void))callback;
- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock;

- (void)getVersion:(void(^)(NSString* version, NSError* error))reply;
- (void)getCompatibilityInfo:(void(^)(NSInteger protocolVersion,
                                      NSString* _Nullable buildVersion,
                                      NSString* _Nullable marketingVersion,
                                      NSArray<NSString*>* _Nullable capabilities,
                                      NSError* _Nullable error))reply;

// Pure compatibility predicate used by launch repair and focused tests. A
// future protocol is accepted when it retains the required capabilities.
+ (BOOL)isDaemonProtocolVersion:(NSInteger)protocolVersion
                   capabilities:(NSArray<NSString*>* _Nullable)capabilities
compatibleWithCurrentAppWithReason:(NSString* _Nullable * _Nullable)reason;

// Builds the complete privacy-safe E7 payload used by AppController after an
// initially unreachable daemon goes through its one allowed repair attempt.
// Returning nil means the supplied state is internally inconsistent.
+ (nullable NSDictionary<NSString *, id>*)daemonUnreachableReinstallTelemetryFieldsForOutcome:(NSString*)outcome
                                                                          initialHandshakeError:(NSError*)initialHandshakeError
                                                                                     finalError:(NSError* _Nullable)finalError
                                                                  installedHelperPresentBefore:(BOOL)installedHelperPresentBefore
                                                                   installedHelperPresentAfter:(BOOL)installedHelperPresentAfter
                                                                          bundledHelperPresent:(BOOL)bundledHelperPresent
                                                                            reinstallSucceeded:(BOOL)reinstallSucceeded
                                                                             reconnectAttempted:(BOOL)reconnectAttempted
                                                                  postRepairHandshakeSucceeded:(BOOL)postRepairHandshakeSucceeded
                                                                          postRepairCompatible:(BOOL)postRepairCompatible;

// Daemon-owned telemetry transport. The daemon derives the queue UID from the
// signed XPC connection; these methods deliberately accept no UID argument.
- (void)setTelemetryConsentEnabled:(BOOL)enabled
                        generation:(NSUInteger)generation
                             reply:(void(^)(NSError * _Nullable error))reply;
- (void)fetchTelemetryRecordsWithLimit:(NSUInteger)limit
                                  reply:(void(^)(NSArray<NSDictionary<NSString *, id> *> *records,
                                                 NSError * _Nullable error))reply;
- (void)acknowledgeTelemetryRecordIDs:(NSArray<NSString *> *)recordIDs
                                 reply:(void(^)(NSError * _Nullable error))reply;
- (void)getSanitizedDaemonSnapshot:(void(^)(NSDictionary<NSString *, id> *snapshot,
                                             NSError * _Nullable error))reply;
- (void)getSanitizedDaemonSnapshotForExpectedState:(NSDictionary<NSString *, id> *)expectedState
                                              reply:(void(^)(NSDictionary<NSString *, id> *snapshot,
                                                             NSError * _Nullable error))reply;

- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply;
- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply;
- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString *, id> *result,
                                                 NSError * _Nullable error))reply;
- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply;

// Schedule registration methods (for pre-authorized scheduled blocks)
- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                   startDate:(NSDate*)startDate
                     endDate:(NSDate*)endDate
                         reply:(void(^)(NSError* error))reply;

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                            reply:(void(^)(NSError* error))reply;

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                    executionPath:(NSString*)executionPath
                            reply:(void(^)(NSError* error))reply;

- (void)unregisterScheduleWithID:(NSString*)scheduleId
                           reply:(void(^)(NSError* error))reply;

- (void)clearAllApprovedSchedules:(void(^)(NSError* error))reply;

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                  entries:(NSArray<NSString*>*)entries
                                    reply:(void(^)(NSError* error))reply;
- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                  entries:(NSArray<NSString*>*)entries
                              resultReply:(void(^)(NSDictionary<NSString *, id> *result,
                                                   NSError * _Nullable error))reply;

- (void)clearBlockForDebug:(void(^)(NSError* error))reply;

// Stop a test block (only works when IsTestBlock=YES, no auth required)
- (void)stopTestBlock:(void(^)(NSError* error))reply;

// Clear an expired block (no auth required - block already expired)
// Clears PF rules, /etc/hosts, AppBlocker, and sets BlockIsRunning=NO
// Used when CLI detects an expired block that wasn't cleared (e.g., after sleep/wake)
- (void)clearExpiredBlock:(void(^)(NSError* _Nullable error))reply;

// Query PF state from daemon (which runs as root)
- (void)isPFBlockActive:(void(^)(BOOL active, NSError* _Nullable error))reply;

// Cleanup a stale schedule (expired endDate) - removes from ApprovedSchedules and launchd
- (void)cleanupStaleSchedule:(NSString*)scheduleId
                       reply:(void(^)(NSError* _Nullable error))reply;

@end

NS_ASSUME_NONNULL_END

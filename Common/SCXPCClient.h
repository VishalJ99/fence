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
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply;
- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply;
- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply;

// Schedule registration methods (for pre-authorized scheduled blocks)
- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                         reply:(void(^)(NSError* error))reply;

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                            reply:(void(^)(NSError* error))reply;

- (void)unregisterScheduleWithID:(NSString*)scheduleId
                           reply:(void(^)(NSError* error))reply;

- (void)clearAllApprovedSchedules:(void(^)(NSError* error))reply;

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                  entries:(NSArray<NSString*>*)entries
                                    reply:(void(^)(NSError* error))reply;

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

//
//  SCDaemonProtocol.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

// XPC method to extend block
- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to get version of the installed daemon
- (void)getVersionWithReply:(void(^)(NSString * version))reply;

// XPC method to register a schedule (requires authorization, stores approved schedule)
- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                 authorization:(NSData *)authData
                         reply:(void(^)(NSError* error))reply;

// XPC method to start a pre-registered schedule (NO authorization required)
- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
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

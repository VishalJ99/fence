//
//  SCDaemonBlockMethods.h
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Top-level logic for different methods run by the SelfControl daemon
// these logics can be run by XPC methods, or elsewhere
@interface SCDaemonBlockMethods : NSObject

@property (class, readonly) NSLock* daemonMethodLock;

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply;
+ (NSArray<NSString *> *)sanitizedBlocklistEntries:(NSArray<NSString *> *)entries;

/// Performs a verified teardown and emits the typed daemon-spool failure event
/// when any physical layer remains active. Caller must hold daemonMethodLock.
+ (BOOL)removeBlockWithTelemetry;

// Starts a block
+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData * _Nullable)authData reply:(void(^)(NSError* _Nullable error))reply;

/// Starts one root-approved schedule record and persists local-only active
/// provenance before releasing the daemon method lock. Duplicate legacy/V2
/// triggers for the already-applied record are idempotent.
+ (void)startScheduledBlockWithID:(NSString *)scheduleID
                           record:(NSDictionary<NSString *, id> *)record
                            reply:(void(^)(NSError * _Nullable error))reply;

/// Removes the active block only when it is owned by the legacy/V2 scheduler.
/// Manual, startup-safety, and test blocks are never removed by this method.
+ (void)endScheduledBlockWithReply:(void(^)(NSError * _Nullable error))reply;

// Checks whether the block is expired or compromised, and takes action to fix
+ (void)checkupBlock;

// updates the blocklist for the currently running block
// (i.e. adds new sites to the list)
+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// Appends entries to the currently running block. This is stricter-only and
// intentionally cannot remove existing blocklist entries.
+ (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply;

/// Structured variant used by the current XPC contract. The result contains
/// counts, enum outcomes, and the privacy-safe physical apply result only.
+ (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString*, id>* result, NSError* _Nullable error))reply;

/// Synchronous implementation used to couple an active scheduled-block append
/// with its root ApprovedSchedules mutation. Caller must already hold
/// daemonMethodLock; this method never unlocks it.
+ (void)appendEntriesToActiveBlocklistWhileHoldingDaemonLock:(NSArray<NSString*>*)entries
                                    matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                                   resultReply:(void(^)(NSDictionary<NSString*, id>* result,
                                                                        NSError* _Nullable error))reply;

// updates the block end date for the currently running block
// (i.e. extends the block)
+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

+ (void)checkBlockIntegrity;

// Stop a test block (only works when IsTestBlock=YES)
+ (void)stopTestBlock:(void(^)(NSError* error))reply;

// Check if PF block is active (for XPC query from app)
- (void)isPFBlockActiveWithReply:(void(^)(BOOL active))reply;

@end

NS_ASSUME_NONNULL_END

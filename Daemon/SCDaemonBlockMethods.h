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

// Starts a block
+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

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

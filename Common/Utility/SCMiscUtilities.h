//
//  SCMiscUtilities.h
//  SelfControl
//
//  Created by Charles Stigler on 07/07/2018.
//

#import <Foundation/Foundation.h>
#import "SCMigrationUtilities.h"

// Holds utility methods for use throughout SelfControl


@interface SCMiscUtilities : NSObject

+ (dispatch_source_t)createDebounceDispatchTimer:(double) debounceTime queue:(dispatch_queue_t)queue block:(dispatch_block_t)block;

+ (NSString *)getSerialNumber;
+ (NSString *)sha1:(NSString*)stringToHash;

+ (BOOL)systemThirdPartyCrashReportingEnabled;

/// Returns a deterministic storage form for one block entry, or nil when the
/// input cannot be represented safely. URL paths, queries, and fragments are
/// discarded because Fence blocks hosts rather than individual pages.
+ (NSString*)canonicalBlockEntryFromString:(NSString*)rawEntry;

+ (NSArray<NSString*>*)cleanBlocklistEntry:(NSString*)rawEntry;

+ (NSArray<NSString*>*)cleanBlocklist:(NSArray<NSString*>*)blocklist;

+ (NSDictionary*) defaultsDictForUser:(uid_t)controllingUID;

+ (NSArray<NSURL*>*)allUserHomeDirectoryURLs:(NSError**)errPtr;

+ (BOOL)errorIsAuthCanceled:(NSError*)err;

+ (NSString*)killerKeyForDate:(NSDate*)date;

/// Returns the UID of the currently logged-in console user, or 0 if none/error
+ (uid_t)consoleUserUID;

@end

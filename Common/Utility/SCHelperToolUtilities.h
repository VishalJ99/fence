//
//  SCHelperToolUtilities.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SCBlockApplyResult;

// Utility methods athat are only used by the helper tools
// (i.e. selfcontrold, selfcontrol-cli, and SCKillerHelper)
// note that this is NOT included in SCUtility.h currently!
@interface SCHelperToolUtilities : NSObject

// Reads the domain block list from the settings for SelfControl, and adds deny
// rules for all of the IPs (or the A DNS record IPS for doamin names) to the
// ipfw firewall.
+ (SCBlockApplyResult*)installBlockRulesFromSettings;

// calls SMJobRemove to unload the daemon from launchd
// (which also kills the running process, synchronously)
+ (void)unloadDaemonJob;

// Checks the settings system to see whether the user wants their web browser
// caches cleared, and deletes the specific cache folders for a few common
// web browsers if it is required.
+ (void)clearCachesIfRequested;

// Clear only the caches for browsers
+ (NSError*)clearBrowserCaches;

// Clear only the OS-level DNS cache
+ (void)clearOSDNSCache;

// Removes block via settings, host file rules and ipfw rules,
// deleting user caches if requested, and migrating legacy settings.
+ (BOOL)removeBlock;
/// Same teardown with its privacy-safe per-layer postconditions returned to
/// daemon callers for telemetry. The dictionary never contains block entries.
+ (BOOL)removeBlockWithResult:(NSDictionary<NSString *, id> * _Nullable * _Nullable)result;

+ (void)sendConfigurationChangedNotification;

@end

NS_ASSUME_NONNULL_END

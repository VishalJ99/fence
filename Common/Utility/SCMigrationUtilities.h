//SCMigrationUtilities//  SCMigration.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Utility methods dealing with legacy settings, legacy blocks,
// and migrating us from old versions of the app to the new one

@interface SCMigrationUtilities : NSObject

+ (NSString*)legacySecuredSettingsFilePathForUser:(uid_t)userId;

+ (BOOL)legacySettingsFoundForUser:(uid_t)controllingUID;
+ (BOOL)legacySettingsFoundForCurrentUser;
+ (BOOL)legacyLockFileExists;

+ (BOOL)legacyBlockIsRunningInSettingsFile:(NSURL*)settingsFileURL;
+ (BOOL)blockIsRunningInLegacyDictionary:(NSDictionary*)dict;

+ (NSDate*)legacyBlockEndDate;

+ (void)copyLegacySettingsToDefaults:(uid_t)controllingUID;
+ (void)copyLegacySettingsToDefaults;

/// Restores Fence's app-owned schedule state after the historical bundle-ID
/// transition from org.eyebeam.SelfControl to org.eyebeam.Fence.
///
/// Migration is intentionally conservative: legacy schedule state is copied
/// only when the current domain has no schedule state of its own. The method is
/// idempotent and never overwrites a calendar already created in Fence. Stale
/// boolean or expired commitment markers do not count as current schedule
/// state and therefore cannot suppress calendar recovery.
+ (BOOL)migrateLegacyFenceScheduleDefaultsIfNeeded;

/// Pure helper used by the migration and focused tests. Returns only the
/// allowlisted keys that are safe to restore, or an empty dictionary when the
/// current domain already owns schedule state.
+ (NSDictionary<NSString*, id>*)legacyFenceScheduleValuesToRestoreFromDomain:(NSDictionary<NSString*, id>*)legacyDomain
                                                               currentDomain:(NSDictionary<NSString*, id>*)currentDomain;

+ (NSError*)clearLegacySettingsForUser:(uid_t)controllingUID;
+ (NSError*)clearLegacySettingsForUser:(uid_t)controllingUID ignoreRunningBlock:(BOOL)ignoreRunningBlock;

@end

NS_ASSUME_NONNULL_END

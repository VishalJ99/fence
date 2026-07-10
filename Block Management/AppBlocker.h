//
//  AppBlocker.h
//  SelfControl
//
//  Monitors running applications and terminates blocked apps.
//  Uses low-level libproc APIs to work in daemon context (no NSWorkspace).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppBlocker : NSObject

/// Shared singleton instance - persists for the lifetime of the daemon
+ (instancetype)sharedBlocker;

/// Set of bundle IDs to block (e.g., "com.apple.Terminal")
@property (nonatomic, readonly) NSSet<NSString*>* blockedBundleIDs;

/// Whether the blocker is currently monitoring
@property (nonatomic, readonly) BOOL isMonitoring;

/// Add an app bundle ID to the blocklist
- (void)addBlockedApp:(NSString*)bundleID;

/// Remove an app from the blocklist
- (void)removeBlockedApp:(NSString*)bundleID;

/// Start monitoring and killing blocked apps (poll every 500ms)
/// @return Privacy-safe counts from the initial scan. No PIDs or bundle IDs
/// are included.
- (NSDictionary<NSString*, NSNumber*>*)startMonitoring;

/// Stop monitoring
- (void)stopMonitoring;

/// Immediately scan and kill any running blocked apps
/// @return Array of PIDs (as NSNumber) that were terminated
- (NSArray<NSNumber*>*)findAndKillBlockedApps;

/// Immediately scan and return privacy-safe outcome counts. Keys are
/// attempt_count, terminate_success_count, force_kill_count, failure_count,
/// scan_error_code, and kill_error_code. Error keys are zero when the related
/// operation succeeded.
- (NSDictionary<NSString*, NSNumber*>*)findAndKillBlockedAppsResult;

/// Clear all blocked apps (used when block ends)
- (void)clearAllBlockedApps;

@end

NS_ASSUME_NONNULL_END

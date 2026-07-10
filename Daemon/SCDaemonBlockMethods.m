//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCDaemonProtocol.h"
#import "SCSettings.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"
#import "AppBlocker.h"
#import "SCMiscUtilities.h"
#import "SCTelemetrySpool.h"

static NSString *SCBlockApplyFailureLayer(NSDictionary<NSString *, id> *applyResult) {
    NSDictionary *hosts = [applyResult[@"hosts"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"hosts"] : @{};
    NSDictionary *packetFilter = [applyResult[@"packet_filter"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"packet_filter"] : @{};
    NSDictionary *apps = [applyResult[@"apps"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"apps"] : @{};
    BOOL (^failed)(id) = ^BOOL(id value) {
        return [value isKindOfClass:[NSString class]] && [value isEqualToString:@"failed"];
    };
    if (failed(hosts[@"ready"]) || failed(hosts[@"write"]) || failed(hosts[@"verify"])) return @"hosts";
    if (failed(packetFilter[@"anchor_open"]) || failed(packetFilter[@"anchor_write"]) ||
        failed(packetFilter[@"main_config_write"]) || failed(packetFilter[@"verify"]) ||
        [packetFilter[@"exit_code"] integerValue] != 0) return @"pf";
    if ([apps[@"kill_failure_count"] unsignedIntegerValue] > 0 ||
        ([apps[@"blocked_count"] unsignedIntegerValue] > 0 && ![apps[@"monitoring_after"] boolValue])) {
        return @"apps";
    }
    return @"verification";
}

static uid_t SCTelemetryUIDForCurrentBlock(void) {
    NSNumber *owner = [[SCSettings sharedSettings] valueForKey:@"ActiveBlockControllingUID"];
    uid_t uid = [owner isKindOfClass:[NSNumber class]] ? owner.unsignedIntValue : 0;
    return uid > 0 ? uid : [SCMiscUtilities consoleUserUID];
}

static void SCSpoolBlockApplyFailure(uid_t uid,
                                     SCBlockApplyResult *result,
                                     BOOL isAllowlist,
                                     BOOL settingsPersisted) {
    if (uid == 0 || result == nil || (result.succeeded && settingsPersisted)) return;
    NSDictionary *rawResult = [result dictionaryRepresentation];
    NSDictionary *fields = [SCSentry telemetryFieldsForBlockApplyResultDictionary:rawResult
                                                                         eventName:@"block.apply_failed"
                                                                supplementalFields:@{
        @"layer": settingsPersisted ? SCBlockApplyFailureLayer(rawResult) : @"settings",
        @"is_allowlist": @(isAllowlist),
        @"settings_persisted": @(settingsPersisted),
    }];
    if (fields == nil) return;
    NSError *spoolError = nil;
    [[[SCTelemetrySpool alloc] init] appendEventName:@"block.apply_failed"
                                               level:SCTelemetryEventLevelError
                                              fields:fields
                                              origin:SCTelemetryOriginDaemon
                                              forUID:uid
                                               error:&spoolError];
    if (spoolError != nil) {
        NSLog(@"Daemon telemetry apply record failed (domain=%@ code=%ld)",
              spoolError.domain, (long)spoolError.code);
    }
}

static void SCSpoolBlockTeardownFailure(uid_t uid, NSDictionary<NSString *, id> *result) {
    if (uid == 0 || ![result isKindOfClass:[NSDictionary class]] || [result[@"verified"] boolValue]) return;
    NSString *layer = ![result[@"hosts_removed"] boolValue] ? @"hosts" :
        (![result[@"pf_removed"] boolValue] ? @"pf" :
         (![result[@"app_monitoring_stopped"] boolValue] ? @"apps" : @"settings"));
    NSMutableDictionary *fields = [@{
        @"layer": layer,
        @"hosts_removed": @([result[@"hosts_removed"] boolValue]),
        @"pf_removed": @([result[@"pf_removed"] boolValue]),
        @"app_monitoring_stopped": @([result[@"app_monitoring_stopped"] boolValue]),
        @"settings_cleared": @([result[@"settings_cleared"] boolValue]),
        @"verified": @NO,
        @"duration_milliseconds": @([result[@"duration_milliseconds"] unsignedIntegerValue]),
    } mutableCopy];
    if ([result[@"error_code"] isKindOfClass:[NSNumber class]]) fields[@"error_code"] = result[@"error_code"];
    NSDictionary *safeFields = [SCSentry sanitizedTelemetryFields:fields forEventName:@"block.teardown_failed"];
    if (safeFields == nil) return;
    NSError *spoolError = nil;
    [[[SCTelemetrySpool alloc] init] appendEventName:@"block.teardown_failed"
                                               level:SCTelemetryEventLevelError
                                              fields:safeFields
                                              origin:SCTelemetryOriginDaemon
                                              forUID:uid
                                               error:&spoolError];
    if (spoolError != nil) {
        NSLog(@"Daemon telemetry teardown record failed (domain=%@ code=%ld)",
              spoolError.domain, (long)spoolError.code);
    }
}

static void SCSpoolUnexpectedBlockRemnants(uid_t uid,
                                           BOOL hostsRemnant,
                                           BOOL pfRemnant,
                                           BOOL appMonitoring,
                                           BOOL teardownVerified,
                                           NSUInteger settingsVersion) {
    if (uid == 0 || (!hostsRemnant && !pfRemnant && !appMonitoring)) return;
    NSUInteger layerCount = (hostsRemnant ? 1 : 0) + (pfRemnant ? 1 : 0) + (appMonitoring ? 1 : 0);
    NSString *remnants = layerCount > 1 ? @"multiple" :
        (hostsRemnant ? @"hosts" : (pfRemnant ? @"pf" : @"apps"));

    static BOOL recordedThisDaemonRun = NO;
    @synchronized (SCDaemonBlockMethods.class) {
        if (recordedThisDaemonRun) return;
    }
    NSError *spoolError = nil;
    BOOL recorded = [[[SCTelemetrySpool alloc] init] appendEventName:@"tamper.no_block_found"
                                                               level:teardownVerified
                                                                   ? SCTelemetryEventLevelWarning
                                                                   : SCTelemetryEventLevelError
                                                              fields:@{
        @"remnants": remnants,
        @"hosts_remnant": @(hostsRemnant),
        @"pf_remnant": @(pfRemnant),
        @"app_monitoring": @(appMonitoring),
        @"teardown_verified": @(teardownVerified),
        @"settings_version": @(settingsVersion),
    }
                                                              origin:SCTelemetryOriginDaemon
                                                              forUID:uid
                                                               error:&spoolError];
    if (recorded) {
        @synchronized (SCDaemonBlockMethods.class) {
            recordedThisDaemonRun = YES;
        }
    } else if (spoolError != nil) {
        NSLog(@"Daemon telemetry remnant record failed (domain=%@ code=%ld)",
              spoolError.domain, (long)spoolError.code);
    }
}

static BOOL SCRemoveBlockWithTelemetry(void) {
    uid_t uid = SCTelemetryUIDForCurrentBlock();
    NSDictionary<NSString *, id> *result = nil;
    BOOL verified = [SCHelperToolUtilities removeBlockWithResult:&result];
    if (!verified) SCSpoolBlockTeardownFailure(uid, result ?: @{});
    return verified;
}

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up

@implementation SCDaemonBlockMethods

+ (NSLock*)daemonMethodLock {
    static NSLock* lock = nil;
    if (lock == nil) {
        lock = [[NSLock alloc] init];
    }
    return lock;
}

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply timeout:(NSTimeInterval)timeout {
    // only run one request at a time, so we avoid weird situations like trying to run a checkup while we're starting a block
    if (![self.daemonMethodLock lockBeforeDate: [NSDate dateWithTimeIntervalSinceNow: timeout]]) {
        // if we couldn't get a lock within 10 seconds, something is weird
        // but we probably shouldn't still run, because that's just unexpected at that point
        // don't capture this error on Sentry because it's very usual for checkups to timeout
        NSError* err = [SCErr errorWithCode: 300];
        NSLog(@"ERROR: Timed out acquiring request lock (after %f seconds)", timeout);

        if (reply != nil) {
            reply(err);
        }
        return NO;
    }
    return YES;
}
+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply {
    return [self lockOrTimeout: reply timeout: METHOD_LOCK_TIMEOUT];
}

+ (BOOL)removeBlockWithTelemetry {
    return SCRemoveBlockWithTelemetry();
}

+ (NSArray<NSString *> *)sanitizedBlocklistEntries:(NSArray<NSString *> *)entries {
    NSMutableOrderedSet<NSString *> *sanitized = [NSMutableOrderedSet orderedSet];

    for (id entry in entries) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *canonical = [SCMiscUtilities canonicalBlockEntryFromString:(NSString*)entry];
        if (canonical != nil) [sanitized addObject:canonical];
    }

    return sanitized.array;
}

+ (NSArray<NSString*>*)comparableExistingBlocklistEntries:(NSArray*)entries {
    NSMutableOrderedSet<NSString*> *comparable = [NSMutableOrderedSet orderedSet];
    for (id rawEntry in entries ?: @[]) {
        if (![rawEntry isKindOfClass:[NSString class]]) continue;
        NSString *canonical = [SCMiscUtilities canonicalBlockEntryFromString:rawEntry];
        if (canonical != nil) {
            [comparable addObject:canonical];
            continue;
        }
        NSString *trimmed = [rawEntry stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0 &&
            [trimmed rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
            [comparable addObject:trimmed];
        }
    }
    return comparable.array;
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData * _Nullable)authData reply:(void(^)(NSError* _Nullable error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }

    // A corrupt or unreadable secured plist may be the only remaining record
    // of an active block. Never replace that unknown authoritative state with
    // a new request; preserve the file and physical layers for repair.
    SCSettings *settings = [SCSettings sharedSettings];
    if (!settings.settingsStateAvailableForEnforcement) {
        NSLog(@"ERROR: Refusing block start because secured settings are unavailable");
        NSError *err = [SCErr errorWithCode:SCSettingsStateUnavailableErrorCode];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // we reset at the _end_ of every method, but we'll also reset at the _start_ here
    // because startBlock can sometimes take a while, and it'd be a shame if the daemon killed itself
    // before we were done
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    
    [SCSentry addBreadcrumb: @"Daemon method startBlock called" category: @"daemon"];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"ERROR: Can't start block since a block is already running");
        NSError* err = [SCErr errorWithCode: 301];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray<NSString*> *canonicalBlocklist = [self sanitizedBlocklistEntries:blocklist ?: @[]];
    NSUInteger requestedEntryCount = [blocklist isKindOfClass:[NSArray class]] ? blocklist.count : 0;
    NSUInteger validInputCount = 0;
    for (id rawEntry in blocklist ?: @[]) {
        if ([rawEntry isKindOfClass:[NSString class]] &&
            [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] != nil) validInputCount += 1;
    }
    NSUInteger rejectedEntryCount = requestedEntryCount - MIN(requestedEntryCount, validInputCount);
    if (rejectedEntryCount > 0) {
        NSLog(@"ERROR: Refusing block start because %lu entries were invalid",
              (unsigned long)rejectedEntryCount);
        NSError *err = [SCErr errorWithCode:500 subDescription:@"Blocklist contained invalid entries"];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    if ((canonicalBlocklist.count == 0 && !isAllowlist) ||
        ![endDate isKindOfClass:[NSDate class]] || [endDate timeIntervalSinceNow] <= 0) {
        NSLog(@"ERROR: Refusing block start because the canonical list is empty or the end date is invalid");
        NSError* err = [SCErr errorWithCode:302];
        [SCSentry captureError:err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"];
    }

    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: canonicalBlocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: @(controllingUID) forKey:@"ActiveBlockControllingUID"];
    [settings setValue: endDate forKey: @"BlockEndDate"];
    
    // update all the settings for the block, which we're basically just copying from defaults to settings
    [settings setValue: blockSettings[@"ClearCaches"] forKey: @"ClearCaches"];
    [settings setValue: blockSettings[@"AllowLocalNetworks"] forKey: @"AllowLocalNetworks"];
    [settings setValue: blockSettings[@"EvaluateCommonSubdomains"] forKey: @"EvaluateCommonSubdomains"];
    [settings setValue: blockSettings[@"IncludeLinkedDomains"] forKey: @"IncludeLinkedDomains"];
    [settings setValue: blockSettings[@"BlockSoundShouldPlay"] forKey: @"BlockSoundShouldPlay"];
    [settings setValue: blockSettings[@"BlockSound"] forKey: @"BlockSound"];
    [settings setValue: blockSettings[@"EnableErrorReporting"] forKey: @"EnableErrorReporting"];

    // Track if this is a test block (can be stopped without emergency unlock)
    BOOL isTestBlock = [blockSettings[@"IsTestBlock"] boolValue];
    [settings setValue: @(isTestBlock) forKey: @"IsTestBlock"];

    NSUInteger appEntryCount = 0;
    for (NSString *entry in canonicalBlocklist) {
        if ([entry hasPrefix:@"app:"]) appEntryCount += 1;
    }
    NSLog(@"Starting block with %lu entries (%lu apps, %lu sites)",
          (unsigned long)canonicalBlocklist.count,
          (unsigned long)appEntryCount,
          (unsigned long)(canonicalBlocklist.count - appEntryCount));

    NSLog(@"Adding firewall rules...");
    SCBlockApplyResult *applyResult = [SCHelperToolUtilities installBlockRulesFromSettings];
    // Even a failed result may have installed a subset of stricter rules. Keep
    // the daemon state active so integrity repair can retry and expiry can
    // remove those rules; never orphan a partial physical block.
    [settings setValue: @YES forKey: @"BlockIsRunning"];

    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Settings sync failed after starting block (domain=%@ code=%ld)",
              syncErr.domain, (long)syncErr.code);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    NSError *resultError = nil;
    if (!applyResult.succeeded || syncErr != nil) {
        SCSpoolBlockApplyFailure(controllingUID, applyResult, isAllowlist, syncErr == nil);
        NSString *failureStage = !applyResult.succeeded ? @"physical apply verification failed" : @"settings persistence failed";
        resultError = [SCErr errorWithCode:500 subDescription:failureStage];
        NSLog(@"ERROR: Block start completed with an unverified result");
    } else {
        [SCSentry addBreadcrumb:@"Daemon added block successfully" category:@"daemon"];
        NSLog(@"INFO: Block successfully added and verified.");
    }
    reply(resultError);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlocklist called" category: @"daemon"];
    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
        
    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSLog(@"ERROR: Attempting to update active blocklist, but this is not possible with an allowlist block");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    NSArray<NSString*> *canonicalNewBlocklist = [self sanitizedBlocklistEntries:newBlocklist ?: @[]];
    NSUInteger requestedEntryCount = [newBlocklist isKindOfClass:[NSArray class]] ? newBlocklist.count : 0;
    NSUInteger validInputCount = 0;
    for (id rawEntry in newBlocklist ?: @[]) {
        if ([rawEntry isKindOfClass:[NSString class]] &&
            [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] != nil) validInputCount += 1;
    }
    if (validInputCount != requestedEntryCount) {
        NSLog(@"ERROR: Refusing blocklist update containing invalid entries");
        NSError *err = [SCErr errorWithCode:500 subDescription:@"Blocklist update contained invalid entries"];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray* activeBlocklist = [self comparableExistingBlocklistEntries:[settings valueForKey:@"ActiveBlocklist"] ?: @[]];
    NSMutableArray* added = [NSMutableArray arrayWithArray:canonicalNewBlocklist];
    [added removeObjectsInArray: activeBlocklist];
    NSMutableArray* removed = [NSMutableArray arrayWithArray: activeBlocklist];
    [removed removeObjectsInArray:canonicalNewBlocklist];
    
    // throw a warning if something got removed for some reason, since we ignore them
    if (removed.count > 0) {
        NSLog(@"WARNING: Ignoring %lu attempted removals from the active blocklist",
              (unsigned long)removed.count);
    }
    
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist:[settings boolForKey:@"ActiveBlockAsWhitelist"]
                                                            allowLocal:[settings boolForKey:@"AllowLocalNetworks"]
                                               includeCommonSubdomains:[settings boolForKey:@"EvaluateCommonSubdomains"]
                                                  includeLinkedDomains:[settings boolForKey:@"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings: added];
    SCBlockApplyResult *applyResult = [blockManager finishAppending];
    
    // Preserve removals during an active denylist block; only the strict
    // additions are allowed to change daemon state.
    NSMutableOrderedSet *strictList = [NSMutableOrderedSet orderedSetWithArray:activeBlocklist];
    [strictList addObjectsFromArray:added];
    [settings setValue:strictList.array forKey:@"ActiveBlocklist"];
    
    // make sure everyone knows about our new list
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Settings sync failed after updating blocklist (domain=%@ code=%ld)",
              syncErr.domain, (long)syncErr.code);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    NSError *resultError = nil;
    if (!applyResult.succeeded || syncErr != nil) {
        SCSpoolBlockApplyFailure(SCTelemetryUIDForCurrentBlock(),
                                 applyResult,
                                 [settings boolForKey:@"ActiveBlockAsWhitelist"],
                                 syncErr == nil);
        resultError = [SCErr errorWithCode:500 subDescription:(!applyResult.succeeded
            ? @"Blocklist physical apply verification failed"
            : @"Blocklist settings persistence failed")];
        NSLog(@"ERROR: Blocklist update completed with an unverified result");
    } else {
        [SCSentry addBreadcrumb:@"Daemon updated blocklist successfully" category:@"daemon"];
        NSLog(@"INFO: Blocklist update applied and verified.");
    }
    reply(resultError);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply {
    [self appendEntriesToActiveBlocklist:entries
               matchingExistingBlocklist:existingBlocklist
                              resultReply:^(NSDictionary<NSString *,id> *result, NSError *error) {
        reply(error);
    }];
}

+ (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString*, id>* result, NSError* error))reply {
    NSUInteger requestedCount = [entries isKindOfClass:[NSArray class]] ? entries.count : 0;
    __block NSMutableDictionary<NSString*, id> *result = [@{
        @"schema_version": @1,
        @"outcome": @"failed",
        @"failed_stage": @"precondition",
        @"requested_count": @(requestedCount),
        @"canonical_count": @0,
        @"rejected_count": @0,
        @"duplicate_count": @0,
        @"active_before_count": @0,
        @"active_after_count": @0,
        @"settings_persisted": @NO,
        @"active_verified": @NO,
        @"physical_reapply_attempted": @NO
    } mutableCopy];

    if (![SCDaemonBlockMethods lockOrTimeout:^(NSError *lockError) {
        result[@"failed_stage"] = @"lock";
        reply([result copy], lockError);
    }]) return;

    [SCSentry addBreadcrumb: @"Daemon method appendEntriesToActiveBlocklist called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't append entries because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't append entries since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];

    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSLog(@"ERROR: Attempting to append entries, but current block uses an allowlist");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray<NSString *> *sanitizedEntries = [self sanitizedBlocklistEntries:entries];
    NSArray<NSString *> *sanitizedExistingBlocklist = [self comparableExistingBlocklistEntries:existingBlocklist];
    NSUInteger validInputCount = 0;
    for (id rawEntry in entries ?: @[]) {
        if ([rawEntry isKindOfClass:[NSString class]] &&
            [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] != nil) validInputCount += 1;
    }
    NSUInteger rejectedCount = requestedCount - MIN(requestedCount, validInputCount);
    NSUInteger duplicateCount = validInputCount - MIN(validInputCount, sanitizedEntries.count);
    result[@"canonical_count"] = @(sanitizedEntries.count);
    result[@"rejected_count"] = @(rejectedCount);
    result[@"duplicate_count"] = @(duplicateCount);

    if (rejectedCount > 0) {
        NSLog(@"ERROR: Refusing active append containing %lu invalid entries", (unsigned long)rejectedCount);
        NSError *err = [SCErr errorWithCode:500 subDescription:@"Active append contained invalid entries"];
        result[@"failed_stage"] = @"canonicalize";
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    if (sanitizedEntries.count == 0) {
        result[@"outcome"] = @"verified";
        result[@"failed_stage"] = @"none";
        result[@"settings_persisted"] = @YES;
        result[@"active_verified"] = @YES;
        [self.daemonMethodLock unlock];
        reply([result copy], nil);
        return;
    }

    if (sanitizedExistingBlocklist.count == 0) {
        NSLog(@"ERROR: Refusing active append without an expected existing blocklist");
        NSError* err = [SCErr errorWithCode: 500 subDescription: @"Missing expected active blocklist"];
        [SCSentry captureError: err];
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray* activeBlocklist = [self comparableExistingBlocklistEntries:[settings valueForKey:@"ActiveBlocklist"] ?: @[]];
    result[@"active_before_count"] = @(activeBlocklist.count);
    result[@"active_after_count"] = @(activeBlocklist.count);
    NSSet *activeSet = [NSSet setWithArray:activeBlocklist];
    NSSet *expectedSet = [NSSet setWithArray:sanitizedExistingBlocklist];
    NSMutableOrderedSet<NSString *> *expectedAfterAppend =
        [NSMutableOrderedSet orderedSetWithArray:sanitizedExistingBlocklist];
    [expectedAfterAppend addObjectsFromArray:sanitizedEntries];
    NSSet *expectedAfterSet = [NSSet setWithArray:expectedAfterAppend.array];
    BOOL matchesOriginalPrecondition = activeSet.count == expectedSet.count &&
        [expectedSet isSubsetOfSet:activeSet];
    BOOL matchesPriorPartialAppend = activeSet.count == expectedAfterSet.count &&
        [expectedAfterSet isSubsetOfSet:activeSet];
    BOOL isRetryState = !matchesOriginalPrecondition && matchesPriorPartialAppend;
    if (!matchesOriginalPrecondition && !matchesPriorPartialAppend) {
        NSLog(@"ERROR: Refusing active append because active blocklist did not match expected blocklist");
        NSError* err = [SCErr errorWithCode: 500 subDescription: @"Active blocklist did not match expected schedule"];
        [SCSentry captureError: err];
        reply([result copy], err);
        [self.daemonMethodLock unlock];
        return;
    }

    // A prior attempt may have persisted the stricter settings but failed a
    // physical postcondition. In that exact union state, reapply the requested
    // rules instead of getting stuck on the old precondition forever.
    NSMutableArray* added = [NSMutableArray arrayWithArray:sanitizedEntries];
    if (!isRetryState) [added removeObjectsInArray:activeBlocklist];

    BOOL physicalReapplyAttempted = SCDaemonActiveStrictifyRequiresPhysicalReapply(
        sanitizedEntries.count, added.count, matchesOriginalPrecondition, isRetryState);
    if (physicalReapplyAttempted && added.count == 0) {
        // Settings already contain the request, but that is not a physical
        // postcondition. Exercise hosts/PF/apps again and return the same typed
        // apply result used for a newly-added entry.
        NSLog(@"SCDaemonBlockMethods: Reapplying entries already present in active blocklist");
        [added addObjectsFromArray:sanitizedEntries];
    }
    result[@"physical_reapply_attempted"] = @(physicalReapplyAttempted);

    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist:NO
                                                            allowLocal:[settings boolForKey:@"AllowLocalNetworks"]
                                               includeCommonSubdomains:[settings boolForKey:@"EvaluateCommonSubdomains"]
                                                  includeLinkedDomains:[settings boolForKey:@"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings:added];
    SCBlockApplyResult *applyResult = [blockManager finishAppending];
    result[@"apply_result"] = [applyResult dictionaryRepresentation];

    NSMutableOrderedSet *newActiveBlocklist = [NSMutableOrderedSet orderedSetWithArray:activeBlocklist];
    [newActiveBlocklist addObjectsFromArray:sanitizedEntries];
    [settings setValue:newActiveBlocklist.array forKey:@"ActiveBlocklist"];
    result[@"active_after_count"] = @(newActiveBlocklist.count);

    NSError* syncErr = [settings syncSettingsAndWait:5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Settings sync failed after active append (domain=%@ code=%ld)",
              syncErr.domain, (long)syncErr.code);
        [SCSentry captureError:syncErr];
    }
    result[@"settings_persisted"] = @(syncErr == nil);

    NSArray *persistedActiveBlocklist = [self comparableExistingBlocklistEntries:[settings valueForKey:@"ActiveBlocklist"] ?: @[]];
    NSSet *persistedSet = [NSSet setWithArray:persistedActiveBlocklist];
    NSSet *newSet = [NSSet setWithArray:newActiveBlocklist.array];
    BOOL activeVerified = persistedSet.count == newSet.count && [newSet isSubsetOfSet:persistedSet];
    result[@"active_verified"] = @(activeVerified);

    [SCHelperToolUtilities sendConfigurationChangedNotification];
    [SCHelperToolUtilities clearCachesIfRequested];

    NSError *resultError = nil;
    if (applyResult.succeeded && syncErr == nil && activeVerified) {
        result[@"outcome"] = @"verified";
        result[@"failed_stage"] = @"none";
        NSLog(@"INFO: Appended and verified %lu active blocklist entries.", (unsigned long)added.count);
    } else {
        SCSpoolBlockApplyFailure(SCTelemetryUIDForCurrentBlock(), applyResult, NO, syncErr == nil);
        result[@"outcome"] = @"failed";
        result[@"failed_stage"] = !applyResult.succeeded ? @"physical_apply" :
            (syncErr != nil ? @"settings_sync" : @"verification");
        resultError = [SCErr errorWithCode:500 subDescription:@"Active blocklist append did not verify"];
        NSLog(@"ERROR: Active blocklist append completed without verified postconditions");
    }

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    reply([result copy], resultError);
}

+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlockEndDate called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 306];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date since block isn't running");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    
    // this can only be used to *extend* the block end date - not shorten it!
    // and we also won't let them extend by more than 24 hours at a time, for safety...
    // TODO: they should be able to extend up to MaxBlockLength minutes, right?
    NSDate* currentEndDate = [settings valueForKey: @"BlockEndDate"];
    if ([newEndDate timeIntervalSinceDate: currentEndDate] < 0) {
        NSLog(@"ERROR: Can't update block end date to an earlier date");
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
    }
    if ([newEndDate timeIntervalSinceDate: currentEndDate] > 86400) { // 86400 seconds = 1 day
        NSLog(@"ERROR: Can't extend block end date by more than 1 day at a time");
        NSError* err = [SCErr errorWithCode: 309];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
    }
    
    [settings setValue: newEndDate forKey: @"BlockEndDate"];
    
    // make sure everyone knows about our new end date
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Settings sync failed after extending block (domain=%@ code=%ld)",
              syncErr.domain, (long)syncErr.code);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    [SCSentry addBreadcrumb: @"Daemon extended block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully extended.");
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)checkupBlock {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }

    [SCSentry addBreadcrumb: @"Daemon method checkupBlock called" category: @"daemon"];

    SCSettings *authoritativeSettings = [SCSettings sharedSettings];
    if (!authoritativeSettings.settingsStateAvailableForEnforcement) {
        // Physical remnants plus unavailable declared state are ambiguous. An
        // automatic teardown here could silently end a still-active committed
        // block. Keep the timer alive and retry after SCSettings recovers a
        // valid snapshot from disk; emergency/debug teardown remains explicit.
        NSLog(@"CHECKUP: Secured settings are unavailable; preserving physical block layers");
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [self.daemonMethodLock unlock];
        return;
    }

    NSTimeInterval integrityCheckIntervalSecs = 15.0;
    static NSDate* lastBlockIntegrityCheck;
    static NSDate* lastCheckupLog;
    if (lastBlockIntegrityCheck == nil) {
        lastBlockIntegrityCheck = [NSDate distantPast];
    }
    if (lastCheckupLog == nil) {
        lastCheckupLog = [NSDate distantPast];
    }

    // Log checkup state every 30 seconds to avoid log spam
    BOOL shouldLogCheckup = [[NSDate date] timeIntervalSinceDate:lastCheckupLog] > 30.0;
    if (shouldLogCheckup) {
        lastCheckupLog = [NSDate date];
        SCSettings* settings = [SCSettings sharedSettings];
        NSArray* blocklist = [settings valueForKey:@"ActiveBlocklist"];
        NSLog(@"CHECKUP: blockIsRunning=%d blockEndState=%@ blocklistCount=%lu",
              [SCBlockUtilities anyBlockIsRunning],
              [SCBlockUtilities currentBlockIsExpired] ? @"expired" : @"future",
              (unsigned long)blocklist.count);
    }

    BOOL shouldRunIntegrityCheck = NO;
    if(![SCBlockUtilities anyBlockIsRunning]) {
        // No block appears to be running at all in our settings.
        // Most likely, the user removed it trying to get around the block. Boo!
        // but for safety and to avoid permablocks (we no longer know when the block should end)
        // we should clear the block now.
        // but let them know that we noticed their (likely) cheating and we're not happy!
        NSLog(@"=== CHECKUP: NO BLOCK RUNNING ===");
        NSLog(@"CHECKUP: Clearing any remnant rules...");

        [SCSentry captureMessage: @"Checkup ran and no active block found! Removing block, tampering suspected..."];

        BOOL pfRemnant = [PacketFilter blockFoundInPF];
        BOOL hostsRemnant = [[HostFileBlockerSet new].defaultBlocker containsSelfControlBlock];
        BOOL appMonitoring = [AppBlocker sharedBlocker].isMonitoring;
        NSUInteger settingsVersion = [[[SCSettings sharedSettings] valueForKey:@"SettingsVersionNumber"] unsignedIntegerValue];
        uid_t telemetryUID = SCTelemetryUIDForCurrentBlock();
        BOOL teardownVerified = SCRemoveBlockWithTelemetry();
        SCSpoolUnexpectedBlockRemnants(telemetryUID, hostsRemnant, pfRemnant,
                                       appMonitoring, teardownVerified, settingsVersion);

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        // Temporarily disabled the TamperingDetection flag because it was sometimes causing false positives
        // (i.e. people having the background set repeatedly despite no attempts to cheat)
        // We will try to bring this feature back once we can debug it
        // GitHub issue: https://github.com/SelfControlApp/selfcontrol/issues/621
        // [settings setValue: @YES forKey: @"TamperingDetected"];
        //        [settings synchronizeSettings];
        //

        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        if (teardownVerified) {
            NSLog(@"CHECKUP: Stopping checkup timer");
            [[SCDaemon sharedDaemon] stopCheckupTimer];
        } else {
            NSLog(@"CHECKUP: Teardown incomplete; retaining timer for retry");
        }
    } else if ([SCBlockUtilities currentBlockIsExpired]) {
        SCSettings* settings = [SCSettings sharedSettings];
        NSArray* blocklist = [settings valueForKey:@"ActiveBlocklist"];

        NSLog(@"=== CHECKUP: BLOCK EXPIRED ===");
        NSLog(@"CHECKUP: expired block had %lu entries", (unsigned long)blocklist.count);
        NSLog(@"CHECKUP: Removing expired block...");

        BOOL teardownVerified = SCRemoveBlockWithTelemetry();

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        if (teardownVerified) {
            [SCSentry addBreadcrumb: @"Daemon found and cleared expired block" category: @"daemon"];
            // once the checkups stop, the daemon will clear itself in a while due to inactivity
            NSLog(@"CHECKUP: Stopping checkup timer (next segment should start via launchd job)");
            [[SCDaemon sharedDaemon] stopCheckupTimer];
        } else {
            NSLog(@"CHECKUP: Expired teardown incomplete; retaining timer for retry");
        }
    } else if ([[NSDate date] timeIntervalSinceDate: lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
        lastBlockIntegrityCheck = [NSDate date];
        // The block is still on.  Every once in a while, we should
        // check if anybody removed our rules, and if so
        // re-add them.
        shouldRunIntegrityCheck = YES;
    }

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];

    // if we need to run an integrity check, we need to do it at the very end after we give up our lock
    // because checkBlockIntegrity requests its own lock, and we don't want it to deadlock
    if (shouldRunIntegrityCheck) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    PacketFilter* pf = [[PacketFilter alloc] init];
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];

    // Check if network blocking is intact
    BOOL pfIntact = [pf containsSelfControlBlock];
    BOOL hostsIntact = [settings boolForKey: @"ActiveBlockAsWhitelist"] || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock];

    // Check if app blocking is intact (if there are app entries in settings, AppBlocker should be monitoring)
    AppBlocker* appBlocker = [AppBlocker sharedBlocker];
    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"];
    BOOL hasAppEntriesInSettings = NO;
    for (NSString* entry in activeBlocklist) {
        if ([entry hasPrefix:@"app:"]) {
            hasAppEntriesInSettings = YES;
            break;
        }
    }
    BOOL appBlockingIntact = !hasAppEntriesInSettings || appBlocker.isMonitoring;

    if(!pfIntact || !hostsIntact || !appBlockingIntact) {
        NSLog(@"INFO: Block integrity compromised (PF:%d hosts:%d apps:%d), re-adding...", pfIntact, hostsIntact, appBlockingIntact);
        // The firewall is missing at least the block header.  Let's clear everything
        // before we re-add to make sure everything goes smoothly.

        [pf stopBlock: false];

        [hostFileBlockerSet removeSelfControlBlock];
        BOOL success = [hostFileBlockerSet writeNewFileContents];
        // Revert the host file blocker's file contents to disk so we can check
        // whether or not it still contains the block after our write (aka we messed up).
        [hostFileBlockerSet revertFileContentsToDisk];
        if(!success || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock]) {
            NSLog(@"WARNING: Error removing host file block.  Attempting to restore backup.");

            if([hostFileBlockerSet restoreBackupHostsFile])
                NSLog(@"INFO: Host file backup restored.");
            else
                NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
        }

        // Get rid of the backup file since we're about to make a new one.
        [hostFileBlockerSet deleteBackupHostsFile];

        // Perform the re-add of the rules
        SCBlockApplyResult *integrityResult = [SCHelperToolUtilities installBlockRulesFromSettings];
        if (!integrityResult.succeeded) {
            SCSpoolBlockApplyFailure(SCTelemetryUIDForCurrentBlock(),
                                     integrityResult,
                                     [settings boolForKey:@"ActiveBlockAsWhitelist"],
                                     YES);
        }
        
        [SCHelperToolUtilities clearCachesIfRequested];

        [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        NSLog(@"INFO: Integrity check ran; readded block rules.");
    } else NSLog(@"INFO: Integrity check ran; no action needed.");

    [self.daemonMethodLock unlock];
}

+ (void)stopTestBlock:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }

    [SCSentry addBreadcrumb: @"Daemon method stopTestBlock called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];

    // Double-check that this is a test block (XPC handler already checked, but be safe)
    BOOL isTestBlock = [[settings valueForKey:@"IsTestBlock"] boolValue];
    if (!isTestBlock) {
        NSLog(@"ERROR: stopTestBlock called but IsTestBlock=NO");
        NSError* err = [SCErr errorWithCode: 401 subDescription: @"Not a test block"];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSLog(@"INFO: Stopping test block (user requested)");

    // Remove the block (same as removeBlock in other contexts)
    BOOL teardownVerified = SCRemoveBlockWithTelemetry();
    if (!teardownVerified) {
        NSError *teardownError = [SCErr errorWithCode:500 subDescription:@"Test block teardown did not verify"];
        reply(teardownError);
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [self.daemonMethodLock unlock];
        return;
    }

    // Clear the test block flag
    [settings setValue: @NO forKey: @"IsTestBlock"];

    // Synchronize settings
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Settings sync failed after stopping test block (domain=%@ code=%ld)",
              syncErr.domain, (long)syncErr.code);
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Stop the checkup timer since block is gone
    [[SCDaemon sharedDaemon] stopCheckupTimer];

    [SCSentry addBreadcrumb: @"Daemon stopped test block successfully" category: @"daemon"];
    NSLog(@"INFO: Test block stopped successfully.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

- (void)isPFBlockActiveWithReply:(void(^)(BOOL active))reply {
    // This runs in the daemon (as root), so pfctl queries work
    BOOL active = [PacketFilter blockFoundInPF];
    reply(active);
}

@end

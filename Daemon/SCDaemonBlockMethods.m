//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCSettings.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"
#import "AppBlocker.h"

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

+ (NSArray<NSString *> *)sanitizedBlocklistEntries:(NSArray<NSString *> *)entries {
    NSMutableOrderedSet<NSString *> *sanitized = [NSMutableOrderedSet orderedSet];

    for (id entry in entries) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *trimmed = [(NSString *)entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }

        [sanitized addObject:trimmed];
    }

    return sanitized.array;
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
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
    
    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"];
    }

    SCSettings* settings = [SCSettings sharedSettings];
    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: blocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
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

    if(([blocklist count] <= 0 && !isAllowlist) || [SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"ERROR: Blocklist is empty, or block end date is in the past");
        NSLog(@"Block End Date: %@ (%@), vs now is %@", [settings valueForKey: @"BlockEndDate"], [[settings valueForKey: @"BlockEndDate"] class], [NSDate date]);
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    // Log block summary for debugging
    NSMutableArray *appEntries = [NSMutableArray array];
    NSMutableArray *siteEntries = [NSMutableArray array];
    for (id entry in blocklist) {
        NSString *entryStr = nil;
        if ([entry isKindOfClass:[NSString class]]) {
            entryStr = entry;
        } else if ([entry isKindOfClass:[NSDictionary class]]) {
            entryStr = [entry objectForKey:@"HostName"];
        }
        if (entryStr) {
            if ([entryStr hasPrefix:@"app:"]) {
                [appEntries addObject:[entryStr substringFromIndex:4]];
            } else {
                [siteEntries addObject:entryStr];
            }
        }
    }
    NSLog(@"═══════════════════════════════════════════════════════════════");
    NSLog(@"BLOCK STARTING - End: %@", [settings valueForKey:@"BlockEndDate"]);
    NSLog(@"  Apps (%lu): %@", (unsigned long)appEntries.count,
          appEntries.count > 0 ? [appEntries componentsJoinedByString:@", "] : @"(none)");
    NSLog(@"  Sites (%lu): %@", (unsigned long)siteEntries.count,
          siteEntries.count > 0 ? [siteEntries componentsJoinedByString:@", "] : @"(none)");
    NSLog(@"═══════════════════════════════════════════════════════════════");

    NSLog(@"Adding firewall rules...");
    [SCHelperToolUtilities installBlockRulesFromSettings];
    [settings setValue: @YES forKey: @"BlockIsRunning"];

    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after starting block", syncErr);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon added block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully added.");
    reply(nil);

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
    
    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"];
    NSMutableArray* added = [NSMutableArray arrayWithArray: newBlocklist];
    [added removeObjectsInArray: activeBlocklist];
    NSMutableArray* removed = [NSMutableArray arrayWithArray: activeBlocklist];
    [removed removeObjectsInArray: newBlocklist];
    
    // throw a warning if something got removed for some reason, since we ignore them
    if (removed.count > 0) {
        NSLog(@"WARNING: Active blocklist has removed items; these will not be updated. Removed items are %@", removed);
    }
    
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: [settings boolForKey: @"ActiveBlockAsWhitelist"]
                                                            allowLocal: [settings boolForKey: @"EvaluateCommonSubdomains"]
                                               includeCommonSubdomains: [settings boolForKey: @"AllowLocalNetworks"]
                                                  includeLinkedDomains: [settings boolForKey: @"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings: added];
    [blockManager finishAppending];
    
    [settings setValue: newBlocklist forKey: @"ActiveBlocklist"];
    
    // make sure everyone knows about our new list
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after updating blocklist", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon updated blocklist successfully" category: @"daemon"];
    NSLog(@"INFO: Blocklist successfully updated.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }

    [SCSentry addBreadcrumb: @"Daemon method appendEntriesToActiveBlocklist called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't append entries because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't append entries since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];

    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSLog(@"ERROR: Attempting to append entries, but current block uses an allowlist");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray<NSString *> *sanitizedEntries = [self sanitizedBlocklistEntries:entries];
    NSArray<NSString *> *sanitizedExistingBlocklist = [self sanitizedBlocklistEntries:existingBlocklist];
    if (sanitizedEntries.count == 0) {
        NSLog(@"SCDaemonBlockMethods: No valid entries to append; treating as success");
        reply(nil);
        [self.daemonMethodLock unlock];
        return;
    }

    if (sanitizedExistingBlocklist.count == 0) {
        NSLog(@"ERROR: Refusing active append without an expected existing blocklist");
        NSError* err = [SCErr errorWithCode: 500 subDescription: @"Missing expected active blocklist"];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"] ?: @[];
    NSSet *activeSet = [NSSet setWithArray:activeBlocklist];
    NSSet *expectedSet = [NSSet setWithArray:sanitizedExistingBlocklist];
    if (activeSet.count != expectedSet.count || ![expectedSet isSubsetOfSet:activeSet]) {
        NSLog(@"ERROR: Refusing active append because active blocklist did not match expected blocklist");
        NSError* err = [SCErr errorWithCode: 500 subDescription: @"Active blocklist did not match expected schedule"];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSMutableArray* added = [NSMutableArray arrayWithArray:sanitizedEntries];
    [added removeObjectsInArray:activeBlocklist];

    if (added.count == 0) {
        NSLog(@"SCDaemonBlockMethods: Entries already present in active blocklist");
        reply(nil);
        [self.daemonMethodLock unlock];
        return;
    }

    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist:NO
                                                            allowLocal:[settings boolForKey:@"AllowLocalNetworks"]
                                               includeCommonSubdomains:[settings boolForKey:@"EvaluateCommonSubdomains"]
                                                  includeLinkedDomains:[settings boolForKey:@"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings:added];
    [blockManager finishAppending];

    NSMutableArray *newActiveBlocklist = [NSMutableArray arrayWithArray:activeBlocklist];
    [newActiveBlocklist addObjectsFromArray:added];
    [settings setValue:newActiveBlocklist forKey:@"ActiveBlocklist"];

    NSError* syncErr = [settings syncSettingsAndWait:5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after appending active blocklist entries", syncErr);
        [SCSentry captureError:syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];
    [SCHelperToolUtilities clearCachesIfRequested];

    NSLog(@"INFO: Appended %lu entries to active blocklist.", (unsigned long)added.count);
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
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
        NSLog(@"WARNING: Sync failed or timed out with error %@ after extending block", syncErr);
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
        NSDate* blockEndDate = [settings valueForKey:@"BlockEndDate"];
        NSArray* blocklist = [settings valueForKey:@"ActiveBlocklist"];
        NSLog(@"CHECKUP: blockIsRunning=%d, blockEndDate=%@, blocklist count=%lu",
              [SCBlockUtilities anyBlockIsRunning],
              blockEndDate,
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

        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        // Temporarily disabled the TamperingDetection flag because it was sometimes causing false positives
        // (i.e. people having the background set repeatedly despite no attempts to cheat)
        // We will try to bring this feature back once we can debug it
        // GitHub issue: https://github.com/SelfControlApp/selfcontrol/issues/621
        // [settings setValue: @YES forKey: @"TamperingDetected"];
        //        [settings synchronizeSettings];
        //

        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        NSLog(@"CHECKUP: Stopping checkup timer");
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else if ([SCBlockUtilities currentBlockIsExpired]) {
        SCSettings* settings = [SCSettings sharedSettings];
        NSDate* blockEndDate = [settings valueForKey:@"BlockEndDate"];
        NSArray* blocklist = [settings valueForKey:@"ActiveBlocklist"];

        NSLog(@"=== CHECKUP: BLOCK EXPIRED ===");
        NSLog(@"CHECKUP: blockEndDate was %@", blockEndDate);
        NSLog(@"CHECKUP: blocklist had %lu entries: %@", (unsigned long)blocklist.count, blocklist);
        NSLog(@"CHECKUP: Removing expired block...");

        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        [SCSentry addBreadcrumb: @"Daemon found and cleared expired block" category: @"daemon"];

        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        NSLog(@"CHECKUP: Stopping checkup timer (next segment should start via launchd job)");
        [[SCDaemon sharedDaemon] stopCheckupTimer];
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
        [SCHelperToolUtilities installBlockRulesFromSettings];
        
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
    [SCHelperToolUtilities removeBlock];

    // Clear the test block flag
    [settings setValue: @NO forKey: @"IsTestBlock"];

    // Synchronize settings
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after stopping test block", syncErr);
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

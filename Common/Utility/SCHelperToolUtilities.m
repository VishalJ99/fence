//
//  SCHelperToolUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import "SCHelperToolUtilities.h"
#import "BlockManager.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation SCHelperToolUtilities

+ (SCBlockApplyResult*)installBlockRulesFromSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    BOOL shouldEvaluateCommonSubdomains = [settings boolForKey: @"EvaluateCommonSubdomains"];
    BOOL allowLocalNetworks = [settings boolForKey: @"AllowLocalNetworks"];
    BOOL includeLinkedDomains = [settings boolForKey: @"IncludeLinkedDomains"];

    // get value for ActiveBlockAsWhitelist
    BOOL blockAsAllowlist = [settings boolForKey: @"ActiveBlockAsWhitelist"];

    // Fresh block starts set BlockIsRunning only after physical rules apply.
    // Reinstalls while it is already true are integrity repairs.
    SCBlockApplyOperation operation = [settings boolForKey:@"BlockIsRunning"]
        ? SCBlockApplyOperationIntegrity
        : SCBlockApplyOperationFresh;
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist:blockAsAllowlist
                                                            allowLocal:allowLocalNetworks
                                               includeCommonSubdomains:shouldEvaluateCommonSubdomains
                                                  includeLinkedDomains:includeLinkedDomains
                                                             operation:operation];

    NSLog(@"About to run BlockManager commands");
    
    [blockManager prepareToAddBlock];
    [blockManager addBlockEntriesFromStrings: [settings valueForKey: @"ActiveBlocklist"]];
    SCBlockApplyResult* result = [blockManager finalizeBlock];
    NSLog(@"Block rule application result: %@", [result dictionaryRepresentation]);
    return result;

}

+ (void)unloadDaemonJob {
    NSLog(@"Unloading SelfControl daemon...");
    [SCSentry addBreadcrumb: @"Daemon about to unload" category: @"daemon"];
    SCSettings* settings = [SCSettings sharedSettings];

    // we're about to unload the launchd job
    // this will kill this process, so we have to make sure
    // all settings are synced before we unload
    NSError* syncErr = [settings syncSettingsAndWait: 5.0];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ before unloading daemon job", syncErr);
        [SCSentry captureError: syncErr];
    }
    
    // uh-oh, looks like it's 5 seconds later and the sync hasn't completed yet. Bad news.
    CFErrorRef cfError;
    // this should block until the process is dead, so we should never get to the other side if it's successful
    SILENCE_OSX10_10_DEPRECATION(
    SMJobRemove(kSMDomainSystemLaunchd, CFSTR("org.eyebeam.selfcontrold"), NULL, YES, &cfError);
                                 );
    if (cfError) {
        NSLog(@"Failed to remove selfcontrold daemon with error %@", cfError);
    }
}

+ (void)clearCachesIfRequested {
    SCSettings* settings = [SCSettings sharedSettings];
    if(![settings boolForKey: @"ClearCaches"]) {
        return;
    }
    
    NSError* err = [SCHelperToolUtilities clearBrowserCaches];
    if (err) {
        NSLog(@"WARNING: Error clearing browser caches: %@", err);
        [SCSentry captureError: err];
    }

    [SCHelperToolUtilities clearOSDNSCache];
}

+ (NSError*)clearBrowserCaches {
    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSError* homeDirErr = nil;
    NSArray<NSURL *>* homeDirectoryURLs = [SCMiscUtilities allUserHomeDirectoryURLs: &homeDirErr];
    if (homeDirectoryURLs == nil) return homeDirErr;
    
    NSArray<NSString*>* cacheDirPathComponents = @[
        // chrome
        @"/Library/Caches/Google/Chrome/Default",
        @"/Library/Caches/Google/Chrome/com.google.Chrome",
        
        // firefox
        @"/Library/Caches/Firefox/Profiles",
        
        // safari
        @"/Library/Caches/com.apple.Safari",
        @"/Library/Containers/com.apple.Safari/Data/Library/Caches" // this one seems to fail due to permissions issues, but not sure how to fix
    ];
    
    
    NSMutableArray<NSURL*>* cacheDirURLs = [NSMutableArray arrayWithCapacity: cacheDirPathComponents.count * homeDirectoryURLs.count];
    for (NSURL* homeDirURL in homeDirectoryURLs) {
        for (NSString* cacheDirPathComponent in cacheDirPathComponents) {
            [cacheDirURLs addObject: [homeDirURL URLByAppendingPathComponent: cacheDirPathComponent isDirectory: YES]];
        }
    }
    
    NSUInteger attemptedCacheDirectoryCount = 0;
    for (NSURL* cacheDirURL in cacheDirURLs) {
        attemptedCacheDirectoryCount += 1;
        // removeItemAtURL will return errors if the file doesn't exist
        // so we don't track the errors - best effort is OK
        [fileManager removeItemAtURL: cacheDirURL error: nil];
    }
    NSLog(@"Attempted to clear %lu browser cache directories",
          (unsigned long)attemptedCacheDirectoryCount);
    
    return nil;
}

+ (void)clearOSDNSCache {
    // no error checks - if it works it works!
    NSTask* flushDsCacheUtil = [[NSTask alloc] init];
    [flushDsCacheUtil setLaunchPath: @"/usr/bin/dscacheutil"];
    [flushDsCacheUtil setArguments: @[@"-flushcache"]];
    [flushDsCacheUtil launch];
    [flushDsCacheUtil waitUntilExit];
    
    NSTask* killResponder = [[NSTask alloc] init];
    [killResponder setLaunchPath: @"/usr/bin/killall"];
    [killResponder setArguments: @[@"-HUP", @"mDNSResponder"]];
    [killResponder launch];
    [killResponder waitUntilExit];
    
    NSTask* killResponderHelper = [[NSTask alloc] init];
    [killResponderHelper setLaunchPath: @"/usr/bin/killall"];
    [killResponderHelper setArguments: @[@"mDNSResponderHelper"]];
    [killResponderHelper launch];
    [killResponderHelper waitUntilExit];
    
    NSLog(@"Cleared OS DNS caches");
}

+ (void)playBlockEndSound {
    SCSettings* settings = [SCSettings sharedSettings];
    if([settings boolForKey: @"BlockSoundShouldPlay"]) {
        // Map the tags used in interface builder to the sound
        NSArray* systemSoundNames = SCConstants.systemSoundNames;
        NSSound* alertSound = [NSSound soundNamed: systemSoundNames[(NSUInteger)[[settings valueForKey: @"BlockSound"] intValue]]];
        if(!alertSound)
            NSLog(@"WARNING: Alert sound not found.");
        else {
            [alertSound play];
        }
    }
}

+ (BOOL)removeBlock {
    return [self removeBlockWithResult:NULL];
}

+ (BOOL)removeBlockWithResult:(NSDictionary<NSString *, id> **)result {
    // Keep declared state until every physical layer verifies removal. This
    // lets the daemon retry a partial teardown instead of claiming the block
    // ended while PF or hosts rules remain installed.
    BlockManager *blockManager = [BlockManager new];
    BOOL teardownVerified = [blockManager clearBlock];
    NSDictionary<NSString *, id> *teardownResult = blockManager.lastTeardownResult ?: @{};
    if (result != NULL) *result = teardownResult;
    NSLog(@"Block teardown result: %@", teardownResult);
    
    [SCHelperToolUtilities clearCachesIfRequested];

    // play a sound letting
    if (teardownVerified) {
        [SCHelperToolUtilities playBlockEndSound];
    }

    // let the main app know things have changed so it can update the UI!
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    if (teardownVerified) {
        NSLog(@"INFO: Block teardown verified.");
        return YES;
    }

    NSLog(@"ERROR: Block teardown did not verify; declared state was retained for retry.");
    return NO;
}

+ (void)sendConfigurationChangedNotification {
    // if you don't include the NSNotificationPostToAllSessions option,
    // it will not deliver when run by launchd (root) to the main app being run by the user
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
                                                                   object: nil
                                                                 userInfo: nil
                                                                  options: NSNotificationDeliverImmediately | NSNotificationPostToAllSessions];
}

@end

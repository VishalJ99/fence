//
//  BlockManager.m
//  SelfControl
//
//  Created by Charles Stigler on 2/5/13.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "BlockManager.h"
#import "AllowlistScraper.h"
#import "SCBlockEntry.h"
#include <sys/socket.h>
#include <netdb.h>
#include <math.h>
#import "HostFileBlockerSet.h"
#import "AppBlocker.h"
#import "SCSettings.h"
#import "SCBlockUtilities.h"

SCBlockApplyOperation const SCBlockApplyOperationFresh = @"fresh";
SCBlockApplyOperation const SCBlockApplyOperationStrictify = @"strictify";
SCBlockApplyOperation const SCBlockApplyOperationIntegrity = @"integrity_reapply";

static NSString* SCApplyStatusForNumber(NSNumber* value) {
    if (value == nil) return @"not_attempted";
    return value.boolValue ? @"succeeded" : @"failed";
}

static BOOL SCOptionalApplyStatusSucceeded(NSNumber* value) {
    return value == nil || value.boolValue;
}

@interface SCBlockApplyResult ()

@property (nonatomic, copy, readwrite) SCBlockApplyOperation operation;
@property (nonatomic, readwrite) BOOL succeeded;
@property (nonatomic, readwrite) BOOL completed;
@property (nonatomic, strong) NSDate* startedAt;
@property (nonatomic, readwrite) NSUInteger durationMilliseconds;

@property (nonatomic, readwrite) NSUInteger inputEntryCount;
@property (nonatomic, readwrite) NSUInteger validEntryCount;
@property (nonatomic, readwrite) NSUInteger rejectedEntryCount;
@property (nonatomic, readwrite) NSUInteger appEntryCount;
@property (nonatomic, readwrite) NSUInteger siteEntryCount;
@property (nonatomic, readwrite) NSUInteger dnsLookupCount;
@property (nonatomic, readwrite) NSUInteger dnsResolvedHostCount;
@property (nonatomic, readwrite) NSUInteger dnsResolvedAddressCount;
@property (nonatomic, readwrite) NSUInteger dnsFailureCount;
@property (nonatomic, readwrite) NSUInteger unappliedEntryCount;

@property (nonatomic, strong, readwrite) NSNumber* hostsReady;
@property (nonatomic, strong, readwrite) NSNumber* hostsWriteSucceeded;
@property (nonatomic, strong, readwrite) NSNumber* hostsVerificationSucceeded;
@property (nonatomic, strong, readwrite) NSNumber* hostsErrorCode;

@property (nonatomic, strong, readwrite) NSNumber* pfAnchorOpenSucceeded;
@property (nonatomic, strong, readwrite) NSNumber* pfAnchorWriteSucceeded;
@property (nonatomic, strong, readwrite) NSNumber* pfMainConfigurationWriteSucceeded;
@property (nonatomic, copy, readwrite) NSString* pfCommand;
@property (nonatomic, strong, readwrite) NSNumber* pfExitCode;
@property (nonatomic, strong, readwrite) NSNumber* pfVerificationSucceeded;
@property (nonatomic, strong, readwrite) NSNumber* pfErrorCode;

@property (nonatomic, readwrite) NSUInteger blockedAppCount;
@property (nonatomic, readwrite) BOOL appMonitoringBefore;
@property (nonatomic, readwrite) BOOL appMonitoringAfter;
@property (nonatomic, readwrite) NSUInteger appKillAttemptCount;
@property (nonatomic, readwrite) NSUInteger appTerminateSuccessCount;
@property (nonatomic, readwrite) NSUInteger appForceKillCount;
@property (nonatomic, readwrite) NSUInteger appKillFailureCount;
@property (nonatomic, strong, readwrite) NSNumber* appScanErrorCode;
@property (nonatomic, strong, readwrite) NSNumber* appKillErrorCode;

- (void)complete;

@end

@implementation SCBlockApplyResult

- (instancetype)initWithOperation:(SCBlockApplyOperation)operation {
    if (self = [super init]) {
        _operation = [operation copy] ?: SCBlockApplyOperationFresh;
        _startedAt = [NSDate date];
    }
    return self;
}

- (void)complete {
    @synchronized (self) {
        NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:self.startedAt];
        self.durationMilliseconds = (NSUInteger)llround(MAX(0, duration) * 1000.0);

        BOOL statusLayersSucceeded =
            SCOptionalApplyStatusSucceeded(self.hostsReady) &&
            SCOptionalApplyStatusSucceeded(self.hostsWriteSucceeded) &&
            SCOptionalApplyStatusSucceeded(self.hostsVerificationSucceeded) &&
            SCOptionalApplyStatusSucceeded(self.pfAnchorOpenSucceeded) &&
            SCOptionalApplyStatusSucceeded(self.pfAnchorWriteSucceeded) &&
            SCOptionalApplyStatusSucceeded(self.pfMainConfigurationWriteSucceeded) &&
            SCOptionalApplyStatusSucceeded(self.pfVerificationSucceeded);
        BOOL commandSucceeded = self.pfExitCode == nil || self.pfExitCode.integerValue == 0;
        BOOL appLayerSucceeded = (self.blockedAppCount == 0 || self.appMonitoringAfter) &&
            self.appKillFailureCount == 0 && self.appScanErrorCode == nil;

        self.succeeded = self.rejectedEntryCount == 0 && self.unappliedEntryCount == 0 && statusLayersSucceeded &&
            commandSucceeded && appLayerSucceeded;
        self.completed = YES;
    }
}

- (NSDictionary<NSString*, id>*)dictionaryRepresentation {
    @synchronized (self) {
        NSMutableDictionary* hosts = [@{
            @"ready": SCApplyStatusForNumber(self.hostsReady),
            @"write": SCApplyStatusForNumber(self.hostsWriteSucceeded),
            @"verify": SCApplyStatusForNumber(self.hostsVerificationSucceeded),
        } mutableCopy];
        if (self.hostsErrorCode) hosts[@"error_code"] = self.hostsErrorCode;

        NSMutableDictionary* packetFilter = [@{
            @"anchor_open": SCApplyStatusForNumber(self.pfAnchorOpenSucceeded),
            @"anchor_write": SCApplyStatusForNumber(self.pfAnchorWriteSucceeded),
            @"main_config_write": SCApplyStatusForNumber(self.pfMainConfigurationWriteSucceeded),
            @"verify": SCApplyStatusForNumber(self.pfVerificationSucceeded),
        } mutableCopy];
        if (self.pfCommand) packetFilter[@"command"] = self.pfCommand;
        if (self.pfExitCode) packetFilter[@"exit_code"] = self.pfExitCode;
        if (self.pfErrorCode) packetFilter[@"error_code"] = self.pfErrorCode;

        NSMutableDictionary* apps = [@{
            @"blocked_count": @(self.blockedAppCount),
            @"monitoring_before": @(self.appMonitoringBefore),
            @"monitoring_after": @(self.appMonitoringAfter),
            @"kill_attempt_count": @(self.appKillAttemptCount),
            @"terminate_success_count": @(self.appTerminateSuccessCount),
            @"force_kill_count": @(self.appForceKillCount),
            @"kill_failure_count": @(self.appKillFailureCount),
        } mutableCopy];
        if (self.appScanErrorCode) apps[@"scan_error_code"] = self.appScanErrorCode;
        if (self.appKillErrorCode) apps[@"kill_error_code"] = self.appKillErrorCode;

        return @{
            @"schema_version": @1,
            @"operation": self.operation,
            @"status": self.completed ? (self.succeeded ? @"succeeded" : @"failed") : @"in_progress",
            @"duration_ms": @(self.durationMilliseconds),
            @"entries": @{
                @"input_count": @(self.inputEntryCount),
                @"valid_count": @(self.validEntryCount),
                @"rejected_count": @(self.rejectedEntryCount),
                @"app_count": @(self.appEntryCount),
                @"site_count": @(self.siteEntryCount),
                @"dns_lookup_count": @(self.dnsLookupCount),
                @"dns_resolved_host_count": @(self.dnsResolvedHostCount),
                @"dns_resolved_address_count": @(self.dnsResolvedAddressCount),
                @"dns_failure_count": @(self.dnsFailureCount),
                @"unapplied_count": @(self.unappliedEntryCount),
            },
            @"hosts": hosts,
            @"packet_filter": packetFilter,
            @"apps": apps,
        };
    }
}

@end

@interface BlockManager ()
@property (nonatomic, strong, readwrite) AppBlocker* appBlocker;
@property (nonatomic, strong, readwrite) SCBlockApplyResult* lastApplyResult;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id>* lastTeardownResult;
@end

@implementation BlockManager

- (BlockManager*)init {
	return [self initAsAllowlist: NO allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist {
	return [self initAsAllowlist: allowlist allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: YES];
}
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: blockCommon includeLinkedDomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked {
	return [self initAsAllowlist:allowlist
                     allowLocal:local
        includeCommonSubdomains:blockCommon
           includeLinkedDomains:includeLinked
                      operation:SCBlockApplyOperationFresh];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked operation:(SCBlockApplyOperation)operation {
	if(self = [super init]) {
		opQueue = [[NSOperationQueue alloc] init];
		[opQueue setMaxConcurrentOperationCount: 35];

		pf = [[PacketFilter alloc] initAsAllowlist: allowlist];
		hostBlockerSet = [[HostFileBlockerSet alloc] init];
		hostsBlockingEnabled = NO;

		isAllowlist = allowlist;
		allowLocal = local;
		includeCommonSubdomains = blockCommon;
        includeLinkedDomains = includeLinked;
        addedBlockEntries = [NSMutableSet set];
        appendMode = NO;

        // Initialize app blocker for blocking applications
        _appBlocker = [AppBlocker sharedBlocker];
        _lastApplyResult = [[SCBlockApplyResult alloc] initWithOperation:operation];
        _lastApplyResult.appMonitoringBefore = _appBlocker.isMonitoring;
	}

	return self;
}

- (void)recordHostsErrorIfNeeded:(NSError*)error {
    if (error == nil) return;
    @synchronized (self.lastApplyResult) {
        if (self.lastApplyResult.hostsErrorCode == nil) {
            self.lastApplyResult.hostsErrorCode = @(error.code);
        }
    }
}

- (void)recordPacketFilterErrorIfNeeded {
    NSError* error = pf.lastApplyError;
    if (error == nil) return;
    @synchronized (self.lastApplyResult) {
        if (self.lastApplyResult.pfErrorCode == nil) {
            self.lastApplyResult.pfErrorCode = @(error.code);
        }
    }
}

- (NSNumber*)statusByCombiningStatus:(NSNumber*)existing withSuccess:(BOOL)success {
    return @((existing == nil || existing.boolValue) && success);
}

- (void)recordAppScanResult:(NSDictionary<NSString*, NSNumber*>*)scanResult {
    @synchronized (self.lastApplyResult) {
        self.lastApplyResult.appKillAttemptCount += [scanResult[@"attempt_count"] unsignedIntegerValue];
        self.lastApplyResult.appTerminateSuccessCount += [scanResult[@"terminate_success_count"] unsignedIntegerValue];
        self.lastApplyResult.appForceKillCount += [scanResult[@"force_kill_count"] unsignedIntegerValue];
        self.lastApplyResult.appKillFailureCount += [scanResult[@"failure_count"] unsignedIntegerValue];

        NSInteger scanErrorCode = [scanResult[@"scan_error_code"] integerValue];
        if (scanErrorCode != 0 && self.lastApplyResult.appScanErrorCode == nil) {
            self.lastApplyResult.appScanErrorCode = @(scanErrorCode);
        }
        NSInteger killErrorCode = [scanResult[@"kill_error_code"] integerValue];
        if (killErrorCode != 0 && self.lastApplyResult.appKillErrorCode == nil) {
            self.lastApplyResult.appKillErrorCode = @(killErrorCode);
        }
    }
}

- (void)applyAppBlockingAndRecordResult {
    NSUInteger blockedAppCount = self.appBlocker.blockedBundleIDs.count;
    self.lastApplyResult.blockedAppCount = blockedAppCount;

    if (blockedAppCount > 0) {
        NSDictionary<NSString*, NSNumber*>* scanResult = nil;
        if (self.appBlocker.isMonitoring) {
            scanResult = [self.appBlocker findAndKillBlockedAppsResult];
        } else {
            // This is essential for strictification: adding the first app to an
            // active site-only block must start the monitor, not merely run a
            // one-shot process scan.
            scanResult = [self.appBlocker startMonitoring];
        }
        [self recordAppScanResult:scanResult];
    }
    self.lastApplyResult.appMonitoringAfter = self.appBlocker.isMonitoring;
}

- (SCBlockApplyResult*)prepareToAddBlock {
    BOOL cleanupAttempted = NO;
    BOOL cleanupSucceeded = YES;
    for (HostFileBlocker* blocker in hostBlockerSet.blockers) {
        if([blocker containsSelfControlBlock]) {
            cleanupAttempted = YES;
            [blocker removeSelfControlBlock];
            NSError* writeError = nil;
            BOOL writeSucceeded = [blocker writeNewFileContentsWithError:&writeError];
            NSError* verifyError = nil;
            BOOL verifySucceeded = writeSucceeded && [blocker verifyNewFileContentsWithError:&verifyError];
            cleanupSucceeded = cleanupSucceeded && writeSucceeded && verifySucceeded;
            [self recordHostsErrorIfNeeded:writeError ?: verifyError];
        }
    }

    if (cleanupAttempted) {
        self.lastApplyResult.hostsWriteSucceeded = @(cleanupSucceeded);
        self.lastApplyResult.hostsVerificationSucceeded = @(cleanupSucceeded);
    }

	if(!isAllowlist && ![hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
		NSError* backupError = nil;
        BOOL backupSucceeded = [hostBlockerSet createBackupHostsFileWithError:&backupError];
		[hostBlockerSet addSelfControlBlockHeader];
        BOOL headerReady = [hostBlockerSet.defaultBlocker containsSelfControlBlock];
		hostsBlockingEnabled = headerReady;
        self.lastApplyResult.hostsReady = @(cleanupSucceeded && backupSucceeded && headerReady);
        [self recordHostsErrorIfNeeded:backupError];
	} else {
		hostsBlockingEnabled = NO;
        if (!isAllowlist) {
            self.lastApplyResult.hostsReady = @NO;
        } else if (cleanupAttempted) {
            self.lastApplyResult.hostsReady = @(cleanupSucceeded);
        }
	}
    return self.lastApplyResult;
}

- (SCBlockApplyResult*)enterAppendMode {
    self.lastApplyResult = [[SCBlockApplyResult alloc] initWithOperation:SCBlockApplyOperationStrictify];
    self.lastApplyResult.appMonitoringBefore = self.appBlocker.isMonitoring;

    if (isAllowlist) {
        NSLog(@"ERROR: can't append to allowlist block");
        self.lastApplyResult.hostsReady = @NO;
        return self.lastApplyResult;
    }
    if(![hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
        NSLog(@"ERROR: can't append to hosts block that doesn't yet exist");
        self.lastApplyResult.hostsReady = @NO;
        return self.lastApplyResult;
    }

    BOOL hostsBlockComplete = [hostBlockerSet.defaultBlocker containsCompleteSelfControlBlock];
    if (!hostsBlockComplete) {
        NSLog(@"ERROR: hosts block is missing its footer; PF append will still be attempted");
        self.lastApplyResult.hostsErrorCode = @(SCHostFileBlockerErrorIncompleteBlock);
    }
    
    hostsBlockingEnabled = YES;
    appendMode = YES;
    self.lastApplyResult.hostsReady = @(hostsBlockComplete);
    BOOL anchorOpened = [pf enterAppendMode];
    self.lastApplyResult.pfAnchorOpenSucceeded = @(anchorOpened);
    [self recordPacketFilterErrorIfNeeded];
    return self.lastApplyResult;
}
- (SCBlockApplyResult*)finishAppending {
    NSLog(@"BlockManager: About to run operation queue for appending...");
    NSDate* startedRunning  = [NSDate date];
    [opQueue waitUntilAllOperationsAreFinished];
    NSDate* finishedRunning  = [NSDate date];
    NSTimeInterval runTime = [finishedRunning timeIntervalSinceDate: startedRunning];
    NSLog(@"BlockManager: Operation queue ran in %f seconds!", runTime);

    if (hostsBlockingEnabled) {
        NSError* writeError = nil;
        BOOL hostsWritten = [hostBlockerSet writeNewFileContentsWithError:&writeError];
        self.lastApplyResult.hostsWriteSucceeded = [self statusByCombiningStatus:self.lastApplyResult.hostsWriteSucceeded
                                                                      withSuccess:hostsWritten];
        NSError* verifyError = nil;
        BOOL hostsVerified = hostsWritten && [hostBlockerSet verifyNewFileContentsWithError:&verifyError];
        self.lastApplyResult.hostsVerificationSucceeded = [self statusByCombiningStatus:self.lastApplyResult.hostsVerificationSucceeded
                                                                              withSuccess:hostsVerified];
        [self recordHostsErrorIfNeeded:writeError ?: verifyError];
    }

    BOOL anchorWritten = [pf finishAppending];
    self.lastApplyResult.pfAnchorWriteSucceeded = @(anchorWritten);
    self.lastApplyResult.pfCommand = @"refresh";
    int pfExitCode = [pf refreshPFRules];
    self.lastApplyResult.pfExitCode = @(pfExitCode);
    self.lastApplyResult.pfVerificationSucceeded = @(pf.lastVerificationSucceeded);
    [self recordPacketFilterErrorIfNeeded];

    [self applyAppBlockingAndRecordResult];

    appendMode = NO;
    [self.lastApplyResult complete];
    return self.lastApplyResult;
}

- (SCBlockApplyResult*)finalizeBlock {
    NSLog(@"BlockManager: About to run operation queue...");
    NSDate* startedRunning  = [NSDate date];
	[opQueue waitUntilAllOperationsAreFinished];
    NSDate* finishedRunning  = [NSDate date];
    NSTimeInterval runTime = [finishedRunning timeIntervalSinceDate: startedRunning];
    NSLog(@"BlockManager: Operation queue ran in %f seconds!", runTime);

	if(hostsBlockingEnabled) {
		[hostBlockerSet addSelfControlBlockFooter];
		NSError* writeError = nil;
        BOOL hostsWritten = [hostBlockerSet writeNewFileContentsWithError:&writeError];
        self.lastApplyResult.hostsWriteSucceeded = [self statusByCombiningStatus:self.lastApplyResult.hostsWriteSucceeded
                                                                      withSuccess:hostsWritten];
        NSError* verifyError = nil;
        BOOL hostsVerified = hostsWritten && [hostBlockerSet verifyNewFileContentsWithError:&verifyError];
        self.lastApplyResult.hostsVerificationSucceeded = [self statusByCombiningStatus:self.lastApplyResult.hostsVerificationSucceeded
                                                                              withSuccess:hostsVerified];
        [self recordHostsErrorIfNeeded:writeError ?: verifyError];
	}

	self.lastApplyResult.pfCommand = @"load";
	int pfExitCode = [pf startBlock];
    self.lastApplyResult.pfAnchorWriteSucceeded = @(pf.lastConfigurationWriteSucceeded);
    self.lastApplyResult.pfMainConfigurationWriteSucceeded = @(pf.lastMainConfigurationWriteSucceeded);
    self.lastApplyResult.pfExitCode = @(pfExitCode);
    self.lastApplyResult.pfVerificationSucceeded = @(pf.lastVerificationSucceeded);
    [self recordPacketFilterErrorIfNeeded];

    // Start app blocker monitoring if any apps are blocked
    NSLog(@"BlockManager: finalizeBlock - appBlocker has %lu apps",
          (unsigned long)self.appBlocker.blockedBundleIDs.count);
    [self applyAppBlockingAndRecordResult];

    [self.lastApplyResult complete];
    return self.lastApplyResult;
}

- (void)enqueueBlockEntry:(SCBlockEntry*)entry {
	NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
        [self addBlockEntry: entry];
	}];
	[opQueue addOperation: op];
}

- (void)addBlockEntry:(SCBlockEntry*)entry {
    // nil entries = something didn't parse right
    if (entry == nil) return;

    // NSMutableSet is NOT thread-safe
    @synchronized (addedBlockEntries) {
        // don't try to block the same thing twice
        if ([addedBlockEntries containsObject: entry]) {
            return;
        }
        [addedBlockEntries addObject: entry];
    }

    // Handle app entries - add to app blocker instead of network blockers
    if ([entry isAppEntry]) {
        [self.appBlocker addBlockedApp:entry.appBundleID];
        return;
    }

	BOOL isIP = [entry.hostname isValidIPAddress];
    BOOL physicalRuleAdded = NO;

	if([entry.hostname isEqualToString: @"*"]) {
		[pf addRuleWithIP: nil port: entry.port maskLen: 0];
		physicalRuleAdded = YES;
	} else if(isIP) {
		[pf addRuleWithIP: entry.hostname port: entry.port maskLen: entry.maskLen];
		physicalRuleAdded = YES;
	} else if(!isIP) { // domain name
        // Google requires special handling
        if ([self domainIsGoogle: entry.hostname]) {
            if (isAllowlist) {
                // just add the whole Google IP range, it's way too error-prone to do an allowlist block of Google any other way
                // last updated: 9/23/21 from https://www.gstatic.com/ipranges/goog.json
                [self addGoogleIPsToPF];
                physicalRuleAdded = YES;
            }
            // for blocklist blocks, just skip blocking Google by IP
            // because we'd end up blocking more than the user wants (i.e. Search/Mail)
            // rely on the domain-level blocking instead
        } else {
            // non-Google domains just get looked up and blocked by IP
            @synchronized (self.lastApplyResult) {
                self.lastApplyResult.dnsLookupCount += 1;
            }
            NSArray* addresses = [BlockManager ipAddressesForDomainName: entry.hostname];

            @synchronized (self.lastApplyResult) {
                if (addresses.count > 0) {
                    self.lastApplyResult.dnsResolvedHostCount += 1;
                    self.lastApplyResult.dnsResolvedAddressCount += addresses.count;
                } else {
                    self.lastApplyResult.dnsFailureCount += 1;
                }
            }

            for(NSUInteger i = 0; i < [addresses count]; i++) {
                NSString* ip = addresses[i];

                [pf addRuleWithIP: ip port: entry.port maskLen: entry.maskLen];
                physicalRuleAdded = YES;
            }
        }
	}

	if(hostsBlockingEnabled && ![entry.hostname isEqualToString: @"*"] && !entry.port && !isIP) {
        if (appendMode) {
            BOOL hostsAppended = [hostBlockerSet appendExistingBlockWithRuleForDomain:entry.hostname];
            physicalRuleAdded = physicalRuleAdded || hostsAppended;
            if (!hostsAppended) {
                @synchronized (self.lastApplyResult) {
                    self.lastApplyResult.hostsReady = @NO;
                    if (self.lastApplyResult.hostsErrorCode == nil) {
                        self.lastApplyResult.hostsErrorCode = @(SCHostFileBlockerErrorIncompleteBlock);
                    }
                }
            }
        } else {
            [hostBlockerSet addRuleBlockingDomain: entry.hostname];
            physicalRuleAdded = YES;
        }
	}

    if (!physicalRuleAdded) {
        @synchronized (self.lastApplyResult) {
            self.lastApplyResult.unappliedEntryCount += 1;
        }
    }
}

- (void)addBlockEntryFromString:(NSString*)entryString {
    @synchronized (self.lastApplyResult) {
        self.lastApplyResult.inputEntryCount += 1;
    }

    SCBlockEntry* entry = [entryString isKindOfClass:[NSString class]]
        ? [SCBlockEntry entryFromString:entryString]
        : nil;

    // nil means that we don't have anything valid to block in this entry
    if (entry == nil) {
        @synchronized (self.lastApplyResult) {
            self.lastApplyResult.rejectedEntryCount += 1;
        }
        return;
    }

    @synchronized (self.lastApplyResult) {
        self.lastApplyResult.validEntryCount += 1;
        if ([entry isAppEntry]) {
            self.lastApplyResult.appEntryCount += 1;
        } else {
            self.lastApplyResult.siteEntryCount += 1;
        }
    }

    // App entries don't have hostnames - route directly to addBlockEntry
    if ([entry isAppEntry]) {
        NSLog(@"BlockManager: Processing one app entry");
        [self addBlockEntry: entry];
        return;
    }

    // enqueue new entries _before_ running this one, so they can happen in parallel
    NSArray<SCBlockEntry*>* relatedEntries = [self relatedBlockEntriesForEntry: entry];
    for (SCBlockEntry* relatedEntry in relatedEntries) {
        [self enqueueBlockEntry: relatedEntry];
    }

    [self addBlockEntry: entry];
}

- (void)addBlockEntriesFromStrings:(NSArray<NSString*>*)blockList {
	for(NSUInteger i = 0; i < [blockList count]; i++) {
		NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
			[self addBlockEntryFromString: blockList[i]];
		}];
		[opQueue addOperation: op];
	}
}

- (BOOL)clearBlock {
    NSDate *startedAt = [NSDate date];
    BOOL appMonitoringBefore = self.appBlocker.isMonitoring;
    // Stop app blocker monitoring
    [self.appBlocker stopMonitoring];
    [self.appBlocker clearAllBlockedApps];
    BOOL appsRemoved = !self.appBlocker.isMonitoring && self.appBlocker.blockedBundleIDs.count == 0;

	int pfStopCode = [pf stopBlock:false];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostBlockerSet removeSelfControlBlock];
	NSError *hostsWriteError = nil;
	BOOL hostSuccess = [hostBlockerSet writeNewFileContentsWithError:&hostsWriteError];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostBlockerSet revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostBlockerSet containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess && appsRemoved;
	BOOL forcePFRemovalAttempted = NO;
	BOOL hostsRestoreAttempted = NO;
	BOOL hostsRestoreSucceeded = NO;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"WARNING: Error clearing pf block. Tring to clear using force.");
			forcePFRemovalAttempted = YES;
			pfStopCode = [pf stopBlock:true];
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			hostsRestoreAttempted = YES;
			hostsRestoreSucceeded = [hostBlockerSet restoreBackupHostsFile];
		}

		pfSuccess = ![pf containsSelfControlBlock];
		hostSuccess = ![hostBlockerSet containsSelfControlBlock];
		clearedSuccessfully = pfSuccess && hostSuccess && appsRemoved;

		if ([hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if ([pf containsSelfControlBlock]) {
			NSLog(@"ERROR: Firewall rules could not be cleared.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	[hostBlockerSet deleteBackupHostsFile];

    // Clear all block settings to prevent stale data showing "Finishing" on next block
    NSError *settingsSyncError = nil;
    BOOL settingsCleared = NO;
    if (clearedSuccessfully) {
        [SCBlockUtilities removeBlockFromSettings];  // Clears BlockIsRunning, BlockEndDate, etc.
        settingsSyncError = [[SCSettings sharedSettings] syncSettingsAndWait:5.0];
        settingsCleared = settingsSyncError == nil &&
            ![[SCSettings sharedSettings] boolForKey:@"BlockIsRunning"];
        NSLog(@"INFO: Block settings clear verified=%@", settingsCleared ? @"YES" : @"NO");
    }

    NSUInteger durationMilliseconds = (NSUInteger)llround(
        MAX(0, [[NSDate date] timeIntervalSinceDate:startedAt]) * 1000.0);
    NSMutableDictionary<NSString *, id> *teardownResult = [@{
        @"schema_version": @1,
        @"outcome": (clearedSuccessfully && settingsCleared) ? @"verified" : @"failed",
        @"hosts_removed": @(hostSuccess),
        @"pf_removed": @(pfSuccess),
        @"app_monitoring_before": @(appMonitoringBefore),
        @"app_monitoring_stopped": @(appsRemoved),
        @"settings_cleared": @(settingsCleared),
        @"verified": @(clearedSuccessfully && settingsCleared),
        @"force_pf_removal_attempted": @(forcePFRemovalAttempted),
        @"hosts_restore_attempted": @(hostsRestoreAttempted),
        @"hosts_restore_succeeded": @(hostsRestoreSucceeded),
        @"pf_exit_code": @(pfStopCode),
        @"duration_milliseconds": @(durationMilliseconds),
    } mutableCopy];
    NSError *firstError = hostsWriteError ?: settingsSyncError ?: pf.lastApplyError;
    if (firstError != nil) teardownResult[@"error_code"] = @(firstError.code);
    self.lastTeardownResult = [teardownResult copy];

	return clearedSuccessfully && settingsCleared;
}

- (BOOL)forceClearBlock {
    // Stop app blocker monitoring
    [self.appBlocker stopMonitoring];
    [self.appBlocker clearAllBlockedApps];

	[pf stopBlock: YES];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostBlockerSet removeSelfControlBlock];
	BOOL hostSuccess = [hostBlockerSet writeNewFileContents];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostBlockerSet revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostBlockerSet containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"ERROR: Error clearing pf block. This may result in a permanent block.");
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			[hostBlockerSet restoreBackupHostsFile];
		}

		clearedSuccessfully = ![self blockIsActive];

		if ([hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	return clearedSuccessfully;
}

- (BOOL)blockIsActive {
	return [hostBlockerSet.defaultBlocker containsSelfControlBlock] || [pf containsSelfControlBlock];
}

- (NSArray*)commonSubdomainsForHostName:(NSString*)hostName {
	NSMutableSet* newHosts = [NSMutableSet set];

	// If the domain ends in facebook.com...  Special case for Facebook because
	// users will often forget to block some of its many mirror subdomains that resolve
	// to different IPs, i.e. hs.facebook.com.  Thanks to Danielle for raising this issue.
	if([hostName hasSuffix: @"facebook.com"]) {
		// pulled list of facebook IP ranges from https://developers.facebook.com/docs/sharing/webmasters/crawler
		// TODO: pull these automatically by running:
		// whois -h whois.radb.net -- '-i origin AS32934' | grep ^route
        // (looks like they now use 2 different AS numbers: https://www.facebook.com/peering/)
		NSArray* facebookIPs = @[@"31.13.24.0/21",
                                 @"31.13.64.0/18",
                                 @"45.64.40.0/22",
                                 @"66.220.144.0/20",
                                 @"69.63.176.0/20",
                                 @"69.171.224.0/19",
                                 @"74.119.76.0/22",
                                 @"102.132.96.0/20",
                                 @"103.4.96.0/22",
                                 @"129.134.0.0/16",
                                 @"147.75.208.0/20",
                                 @"157.240.0.0/16",
                                 @"173.252.64.0/18",
                                 @"179.60.192.0/22",
                                 @"185.60.216.0/22",
                                 @"185.89.216.0/22",
                                 @"199.201.64.0/22",
                                 @"204.15.20.0/22"];

		[newHosts addObjectsFromArray: facebookIPs];
	}
	if ([hostName hasSuffix: @"twitter.com"]) {
		[newHosts addObject: @"api.twitter.com"];
	}

    if ([hostName hasSuffix: @"netflix.com"]) {
        [newHosts addObject: @"assets.nflxext.com"];
        [newHosts addObject: @"codex.nflxext.com"];
        [newHosts addObject: @"nflxext.com"];
    }

	// Block the domain with no subdomains, if www.domain is blocked
	if([hostName rangeOfString: @"www."].location == 0) {
		[newHosts addObject: [hostName substringFromIndex: 4]];
	} else { // Or block www.domain otherwise
		[newHosts addObject: [@"www." stringByAppendingString: hostName]];
	}

	return [newHosts allObjects];
}

// by Jakob Egger, taken from: https://eggerapps.at/blog/2014/hostname-lookups.html
+ (NSString*)stringForAddress:(NSData*)addressData error:(NSError**)outError {
    char hbuf[NI_MAXHOST];
    int gai_error = getnameinfo(addressData.bytes, (socklen_t)addressData.length, hbuf, NI_MAXHOST, NULL, 0, NI_NUMERICHOST);
    if (gai_error) {
        if (outError) *outError = [NSError errorWithDomain:@"MyDomain" code:gai_error userInfo:@{NSLocalizedDescriptionKey:@(gai_strerror(gai_error))}];
        return nil;
    }
    return [NSString stringWithUTF8String:hbuf];
}
+ (NSArray*)ipAddressesForDomainName:(NSString*)domainName {
    if(domainName == nil) return @[];

	NSDate* startedResolving = [NSDate date];
    CFHostRef cfHost = CFHostCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)domainName);
    CFStreamError streamErr;
    // TODO: call CFHostsScheduleWithRunLoop to put this on a background thread, so we can cancel/timeout early
    CFHostStartInfoResolution(cfHost, kCFHostAddresses, &streamErr);
    if (streamErr.error) {
        NSLog(@"BlockManager: Warning: domain resolution stream failed");
        CFRelease(cfHost);
        return @[];
    }
    
    NSArray<NSData*>* addresses = (__bridge NSArray*)CFHostGetAddressing(cfHost, NULL);

    NSMutableArray* stringAddresses = [NSMutableArray array];
    if (addresses != NULL) {
        for (NSData* addrData in addresses) {
            NSError* parseErr;
            NSString* ipStr = [BlockManager stringForAddress: addrData error: &parseErr];
            if (ipStr) {
                [stringAddresses addObject: ipStr];
            } else {
                NSLog(@"BlockManager: Warning: resolved address parsing failed (domain=%@ code=%ld)",
                      parseErr.domain, (long)parseErr.code);
            }
        }
    } else {
        NSLog(@"BlockManager: Warning: domain resolution returned no addresses");
    }

	// log slow resolutions
	NSDate* finishedResolving  = [NSDate date];
	NSTimeInterval resolutionTime = [finishedResolving timeIntervalSinceDate: startedResolving];
	if (resolutionTime > 2.5) {
		NSLog(@"BlockManager: Warning: domain resolution took %.3f seconds", resolutionTime);
	}
    
    CFRelease(cfHost);

	return stringAddresses;
}

+ (NSPredicate*)googleTesterPredicate {
    static NSPredicate* pred = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* googleRegex = @"^([a-z0-9]+\\.)*(google|youtube|picasa|sketchup|blogger|blogspot)\\.([a-z]{1,3})(\\.[a-z]{1,3})?$";
        pred = [NSPredicate
                 predicateWithFormat: @"SELF MATCHES %@",
                 googleRegex
                 ];
    });
    
    return pred;
}
- (BOOL)domainIsGoogle:(NSString*)domainName {
	return [[BlockManager googleTesterPredicate] evaluateWithObject: domainName];
}

- (NSArray<SCBlockEntry*>*)relatedBlockEntriesForEntry:(SCBlockEntry*)entry {
    // nil means that we don't have anything valid to block in this entry, therefore no related entries either
    if (entry == nil) return @[];
    
    NSMutableArray<SCBlockEntry*>* relatedEntries = [NSMutableArray array];

    if (isAllowlist && includeLinkedDomains && ![entry.hostname isValidIPAddress]) {
        NSDate* startedScraping  = [NSDate date];
        NSArray<SCBlockEntry*>* scrapedEntries = [[AllowlistScraper relatedBlockEntries: entry.hostname] allObjects];
        NSDate* finishedScraping  = [NSDate date];
        NSTimeInterval resolutionTime = [finishedScraping timeIntervalSinceDate: startedScraping];
        if (resolutionTime > 5.0) {
            NSLog(@"BlockManager: Warning: allowlist scraper took %.3f seconds", resolutionTime);
        }
        [relatedEntries addObjectsFromArray: scrapedEntries];
    }

    if(![entry.hostname isValidIPAddress] && includeCommonSubdomains) {
        NSArray<NSString*>* commonSubdomains = [self commonSubdomainsForHostName: entry.hostname];

        for (NSString* subdomain in commonSubdomains) {
            // we do not pull port, we leave the port number the same as we got it
            SCBlockEntry* subdomainEntry = [SCBlockEntry entryFromString: subdomain];

            if (subdomainEntry == nil) continue;
            
            [relatedEntries addObject: subdomainEntry];
        }
    }
    
    return relatedEntries;
}

- (void)addGoogleIPsToPF {
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"8.34.208.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"8.35.192.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"23.236.48.0" port: 0 maskLen: 240];
    [pf addRuleWithIP: @"23.251.128.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"34.64.0.0" port: 0 maskLen: 10];
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"8.8.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"34.128.0.0" port: 0 maskLen: 10];
    [pf addRuleWithIP: @"35.184.0.0" port: 0 maskLen: 13];
    [pf addRuleWithIP: @"35.192.0.0" port: 0 maskLen: 14];
    [pf addRuleWithIP: @"35.196.0.0" port: 0 maskLen: 15];
    [pf addRuleWithIP: @"35.198.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"35.199.0.0" port: 0 maskLen: 17];
    [pf addRuleWithIP: @"35.199.128.0" port: 0 maskLen: 18];
    [pf addRuleWithIP: @"35.200.0.0" port: 0 maskLen: 13];
    [pf addRuleWithIP: @"35.208.0.0" port: 0 maskLen: 12];
    [pf addRuleWithIP: @"35.224.0.0" port: 0 maskLen: 12];
    [pf addRuleWithIP: @"35.240.0.0" port: 0 maskLen: 13];
    [pf addRuleWithIP: @"64.15.112.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"64.233.160.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"66.102.0.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"66.249.64.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"70.32.128.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"72.14.192.0" port: 0 maskLen: 18];
    [pf addRuleWithIP: @"74.114.24.0" port: 0 maskLen: 21];
    [pf addRuleWithIP: @"74.125.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"104.154.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"104.196.0.0" port: 0 maskLen: 14];
    [pf addRuleWithIP: @"104.237.160.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"107.167.160.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"107.178.192.0" port: 0 maskLen: 18];
    [pf addRuleWithIP: @"108.59.80.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"108.170.192.0" port: 0 maskLen: 18];
    [pf addRuleWithIP: @"108.177.0.0" port: 0 maskLen: 17];
    [pf addRuleWithIP: @"130.211.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"136.112.0.0" port: 0 maskLen: 12];
    [pf addRuleWithIP: @"142.250.0.0" port: 0 maskLen: 15];
    [pf addRuleWithIP: @"146.148.0.0" port: 0 maskLen: 17];
    [pf addRuleWithIP: @"162.216.148.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"162.222.176.0" port: 0 maskLen: 21];
    [pf addRuleWithIP: @"172.110.32.0" port: 0 maskLen: 21];
    [pf addRuleWithIP: @"172.217.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"172.253.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"173.194.0.0" port: 0 maskLen: 16];
    [pf addRuleWithIP: @"173.255.112.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"192.158.28.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"192.178.0.0" port: 0 maskLen: 15];
    [pf addRuleWithIP: @"193.186.4.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"199.36.154.0" port: 0 maskLen: 23];
    [pf addRuleWithIP: @"199.36.156.0" port: 0 maskLen: 24];
    [pf addRuleWithIP: @"199.192.112.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"199.223.232.0" port: 0 maskLen: 21];
    [pf addRuleWithIP: @"207.223.160.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"208.65.152.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"208.68.108.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"208.81.188.0" port: 0 maskLen: 22];
    [pf addRuleWithIP: @"208.117.224.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"209.85.128.0" port: 0 maskLen: 17];
    [pf addRuleWithIP: @"216.58.192.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"216.73.80.0" port: 0 maskLen: 20];
    [pf addRuleWithIP: @"216.239.32.0" port: 0 maskLen: 19];
    [pf addRuleWithIP: @"2001:4860::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2404:6800::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2404:f340::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2600:1900::" port: 0 maskLen: 28];
    [pf addRuleWithIP: @"2606:73c0::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2607:f8b0::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2620:11a:a000::" port: 0 maskLen: 40];
    [pf addRuleWithIP: @"2620:120:e000::" port: 0 maskLen: 40];
    [pf addRuleWithIP: @"2800:3f0::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2a00:1450::" port: 0 maskLen: 32];
    [pf addRuleWithIP: @"2c0f:fb50::" port: 0 maskLen: 32];
}

@end

//
//  BlockManager.h
//  SelfControl
//
//  Created by Charlie Stigler on 2/5/13.
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

#import <Foundation/Foundation.h>
#import "PacketFilter.h"
#import "NSString+IPAddress.h"

@class SCBlockEntry;
@class HostFileBlockerSet;
@class AppBlocker;

typedef NSString* SCBlockApplyOperation NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT SCBlockApplyOperation const SCBlockApplyOperationFresh;
FOUNDATION_EXPORT SCBlockApplyOperation const SCBlockApplyOperationStrictify;
FOUNDATION_EXPORT SCBlockApplyOperation const SCBlockApplyOperationIntegrity;

/// Privacy-safe summary of one attempt to apply block rules. This object is
/// created before work starts, updated as each physical layer is applied, and
/// retained by BlockManager after completion. It never stores block entries,
/// addresses, paths, or application identifiers.
@interface SCBlockApplyResult : NSObject

@property (nonatomic, copy, readonly) SCBlockApplyOperation operation;
@property (nonatomic, readonly) BOOL succeeded;
@property (nonatomic, readonly) NSUInteger durationMilliseconds;

@property (nonatomic, readonly) NSUInteger inputEntryCount;
@property (nonatomic, readonly) NSUInteger validEntryCount;
@property (nonatomic, readonly) NSUInteger rejectedEntryCount;
@property (nonatomic, readonly) NSUInteger appEntryCount;
@property (nonatomic, readonly) NSUInteger siteEntryCount;
@property (nonatomic, readonly) NSUInteger dnsLookupCount;
@property (nonatomic, readonly) NSUInteger dnsResolvedHostCount;
@property (nonatomic, readonly) NSUInteger dnsResolvedAddressCount;
@property (nonatomic, readonly) NSUInteger dnsFailureCount;
@property (nonatomic, readonly) NSUInteger unappliedEntryCount;

/// Nullable layer results mean that the layer was not applicable or was not
/// reached. NSNumber is used so the dictionary representation can distinguish
/// that state from a failed attempt.
@property (nonatomic, strong, readonly) NSNumber* hostsReady;
@property (nonatomic, strong, readonly) NSNumber* hostsWriteSucceeded;
@property (nonatomic, strong, readonly) NSNumber* hostsVerificationSucceeded;
@property (nonatomic, strong, readonly) NSNumber* hostsErrorCode;

@property (nonatomic, strong, readonly) NSNumber* pfAnchorOpenSucceeded;
@property (nonatomic, strong, readonly) NSNumber* pfAnchorWriteSucceeded;
@property (nonatomic, strong, readonly) NSNumber* pfMainConfigurationWriteSucceeded;
@property (nonatomic, copy, readonly) NSString* pfCommand;
@property (nonatomic, strong, readonly) NSNumber* pfExitCode;
@property (nonatomic, strong, readonly) NSNumber* pfVerificationSucceeded;
@property (nonatomic, strong, readonly) NSNumber* pfErrorCode;

@property (nonatomic, readonly) NSUInteger blockedAppCount;
@property (nonatomic, readonly) BOOL appMonitoringBefore;
@property (nonatomic, readonly) BOOL appMonitoringAfter;
@property (nonatomic, readonly) NSUInteger appKillAttemptCount;
@property (nonatomic, readonly) NSUInteger appTerminateSuccessCount;
@property (nonatomic, readonly) NSUInteger appForceKillCount;
@property (nonatomic, readonly) NSUInteger appKillFailureCount;
@property (nonatomic, strong, readonly) NSNumber* appScanErrorCode;
@property (nonatomic, strong, readonly) NSNumber* appKillErrorCode;

- (instancetype)initWithOperation:(SCBlockApplyOperation)operation;
- (NSDictionary<NSString*, id>*)dictionaryRepresentation;

@end

@interface BlockManager : NSObject {
	NSOperationQueue* opQueue;
	PacketFilter* pf;
	HostFileBlockerSet* hostBlockerSet;
	BOOL hostsBlockingEnabled;
	BOOL isAllowlist;
	BOOL allowLocal;
	BOOL includeCommonSubdomains;
	BOOL includeLinkedDomains;
    NSMutableSet* addedBlockEntries;
	BOOL appendMode;
}

/// App blocker instance for killing blocked applications
@property (nonatomic, strong, readonly) AppBlocker* appBlocker;
@property (nonatomic, strong, readonly) SCBlockApplyResult* lastApplyResult;
/// Privacy-safe postconditions from the most recent teardown attempt.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id>* lastTeardownResult;

- (BlockManager*)initAsAllowlist:(BOOL)allowlist;
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local;
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon;
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked;
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked operation:(SCBlockApplyOperation)operation;

- (SCBlockApplyResult*)enterAppendMode;
- (SCBlockApplyResult*)finishAppending;
- (SCBlockApplyResult*)prepareToAddBlock;
- (SCBlockApplyResult*)finalizeBlock;
- (void)addBlockEntryFromString:(NSString*)entry;
- (void)addBlockEntry:(SCBlockEntry*)entry;
- (void)addBlockEntriesFromStrings:(NSArray<NSString*>*)blockList;
- (BOOL)clearBlock;
- (BOOL)forceClearBlock;
- (BOOL)blockIsActive;

- (NSArray*)commonSubdomainsForHostName:(NSString*)hostName;
+ (NSArray*)ipAddressesForDomainName:(NSString*)domainName;
- (BOOL)domainIsGoogle:(NSString*)domainName;

@end

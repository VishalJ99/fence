//
//  PacketFilter.h
//  SelfControl
//
//  Created by Charles Stigler on 6/29/14.
//
//

#import <Foundation/Foundation.h>

@class SCBlockEntry;

FOUNDATION_EXPORT NSErrorDomain const SCPacketFilterErrorDomain;

typedef NS_ERROR_ENUM(SCPacketFilterErrorDomain, SCPacketFilterError) {
    SCPacketFilterErrorAnchorUnavailable = 1,
    SCPacketFilterErrorAnchorWriteFailed = 2,
    SCPacketFilterErrorMainConfigurationUnavailable = 3,
    SCPacketFilterErrorCommandLaunchFailed = 4,
    SCPacketFilterErrorCommandVerificationFailed = 5,
};

@interface PacketFilter : NSObject {
	NSMutableString* rules;
	BOOL isAllowlist;
}

/// Status retained from the most recent start or append operation. These are
/// consumed by BlockManager's privacy-safe SCBlockApplyResult.
@property (nonatomic, readonly) BOOL lastAnchorOpenSucceeded;
@property (nonatomic, readonly) BOOL lastConfigurationWriteSucceeded;
@property (nonatomic, readonly) BOOL lastMainConfigurationWriteSucceeded;
@property (nonatomic, readonly) NSInteger lastCommandExitCode;
@property (nonatomic, readonly) BOOL lastVerificationSucceeded;
@property (nonatomic, strong, readonly) NSError* lastApplyError;

+ (BOOL)blockFoundInPF;

- (PacketFilter*)initAsAllowlist: (BOOL)allowlist;
- (void)addBlockHeader:(NSMutableString*)configText;
- (void)addAllowlistFooter:(NSMutableString*)configText;
- (void)addRuleWithIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen;
- (BOOL)writeConfiguration;
- (int)startBlock;
- (int)stopBlock:(BOOL)force;
- (BOOL)addSelfControlConfig;
- (BOOL)containsSelfControlBlock;
- (BOOL)enterAppendMode;
- (BOOL)finishAppending;
- (int)refreshPFRules;

@end

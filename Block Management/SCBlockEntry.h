//
//  SCBlockEntry.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/20/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCBlockEntry : NSObject

@property (nonatomic) NSString* hostname;
@property (nonatomic) NSInteger port;
@property (nonatomic) NSInteger maskLen;
@property (nonatomic) NSString* appBundleID;  // For app blocking (e.g., "com.apple.Terminal")

+ (instancetype)entryWithHostname:(NSString*)hostname;
+ (instancetype)entryWithHostname:(NSString*)hostname port:(NSInteger)port maskLen:(NSInteger)maskLen;
+ (instancetype)entryWithAppBundleID:(NSString*)bundleID;
+ (nullable instancetype)entryFromString:(NSString*)domainString;

- (BOOL)isEqualToEntry:(SCBlockEntry*)otherEntry;
- (BOOL)isAppEntry;  // Returns YES if this is an app block entry

@end

NS_ASSUME_NONNULL_END

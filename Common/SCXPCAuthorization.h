//
//  SCXPCAuthorization.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/4/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCXPCAuthorization : NSObject

+ (NSError *)checkAuthorization:(NSData *)authData command:(SEL)command;

+ (NSString *)authorizationRightForCommand:(SEL)command;
    // For a given command selector, return the associated authorization right name.

/// The distinct Fence-managed rights, independent of how many commands share them.
+ (NSArray<NSString *> *)managedAuthorizationRightNames;

/// Returns YES when any installed Fence-managed rule is missing or stale.
+ (BOOL)authorizationRightsNeedRefresh;

/// Returns YES when the installed rule used by `command` is missing or stale.
+ (BOOL)authorizationRightNeedsRefreshForCommand:(SEL)command;

+ (void)setupAuthorizationRights:(AuthorizationRef)authRef;
    // Set up the default authorization rights in the authorization database.

+ (BOOL)refreshAuthorizationRights:(AuthorizationRef)authRef error:(NSError **)error;
    // Updates each stale Fence-managed authorization right once.

+ (BOOL)refreshAuthorizationRightForCommand:(SEL)command
                              authorization:(AuthorizationRef)authRef
                                      error:(NSError **)error;
    // Updates only the stale Fence-managed right used by command.

@end

NS_ASSUME_NONNULL_END

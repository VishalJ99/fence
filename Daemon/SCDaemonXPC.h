//
//  SCDaemonXPC.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>
#import "SCDaemonProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Implementations for SC XPC methods
// (see SCDaemonProtocol for all method prototypes)
@interface SCDaemonXPC : NSObject <SCDaemonProtocol>

- (instancetype)initWithClientUID:(uid_t)clientUID
                  clientIsFenceApp:(BOOL)clientIsFenceApp NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

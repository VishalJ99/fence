//
//  SCEmergencyExitWindowController.h
//  SelfControl
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCEmergencyExitWindowController : NSWindowController

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCompletionHandler:(dispatch_block_t)completionHandler
                       cancellationHandler:(dispatch_block_t)cancellationHandler;

/// Presents the window, enters native full screen, and starts the attempt once
/// the app, window focus, and full-screen requirements are all satisfied.
- (void)begin;

@end

NS_ASSUME_NONNULL_END

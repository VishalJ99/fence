//
//  SCCountdownWarningController.h
//  SelfControl
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Non-activating, top-centre warning pill with a 90-second progress ring.
@interface SCCountdownWarningController : NSObject

/// Called after the user dismisses the currently displayed event.
@property (nonatomic, copy, nullable) void (^onDismiss)(NSString *eventIdentifier);

/// Called when the displayed event reaches its target date.
@property (nonatomic, copy, nullable) void (^onExpire)(void);

/// Shows or updates a warning. The title contains no numeric countdown; the
/// ring alone communicates the remaining portion of the 90-second window.
- (void)showWarningWithTitle:(NSString *)title
                  targetDate:(NSDate *)targetDate
             eventIdentifier:(NSString *)eventIdentifier
                      screen:(nullable NSScreen *)screen;

- (void)hideWarning;

@end

NS_ASSUME_NONNULL_END


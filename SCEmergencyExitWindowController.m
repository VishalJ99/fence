//
//  SCEmergencyExitWindowController.m
//  SelfControl
//

#import "SCEmergencyExitWindowController.h"

#import "SCEmergencyExitAttempt.h"
#import "Block Management/SCScheduleManager.h"

@interface SCEmergencyExitWindowController ()

@property (nonatomic, copy, nullable) dispatch_block_t completionHandler;
@property (nonatomic, copy, nullable) dispatch_block_t cancellationHandler;
@property (nonatomic, strong) SCEmergencyExitAttempt *attempt;
@property (nonatomic, strong, nullable) NSTimer *updateTimer;
@property (nonatomic, strong) NSStackView *normalStack;
@property (nonatomic, strong) NSTextField *countdownLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSView *checkpointOverlay;
@property (nonatomic, strong) NSTextField *checkpointCountdownLabel;
@property (nonatomic, strong) NSButton *checkpointButton;
@property (nonatomic) BOOL monitoring;
@property (nonatomic) BOOL finishing;
@property (nonatomic) NSTimeInterval attemptDuration;

@end

@implementation SCEmergencyExitWindowController

- (instancetype)initWithCompletionHandler:(dispatch_block_t)completionHandler
                       cancellationHandler:(dispatch_block_t)cancellationHandler {
    NSRect frame = NSMakeRect(0, 0, 760, 520);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskResizable |
                                                              NSWindowStyleMaskFullSizeContentView)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Fence Emergency Exit";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    window.hidesOnDeactivate = NO;
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(600, 420);

    self = [super initWithWindow:window];
    if (self) {
        _completionHandler = [completionHandler copy];
        _cancellationHandler = [cancellationHandler copy];
        _attemptDuration = [SCScheduleManager sharedManager].emergencyUnlockWaitMinutes * 60.0;
        NSTimeInterval duration = _attemptDuration;
        _attempt = [[SCEmergencyExitAttempt alloc] initWithDuration:duration
                                                checkpointProvider:^NSTimeInterval{
            return SCEmergencyExitSampleCheckpointOffsetForDuration(duration);
        }];
        [self setupUI];
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
}

- (NSTimeInterval)currentUptime {
    return NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)isWindowFullScreen {
    return (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

- (NSTextField *)labelWithString:(NSString *)string
                            size:(CGFloat)size
                          weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField wrappingLabelWithString:string];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.alignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)setupUI {
    NSView *rootView = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    rootView.wantsLayer = YES;
    rootView.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    self.window.contentView = rootView;

    NSTextField *titleLabel = [self labelWithString:@"Emergency Exit" size:30 weight:NSFontWeightBold];
    self.countdownLabel = [self labelWithString:[self countdownStringForSeconds:self.attemptDuration]
                                           size:72
                                         weight:NSFontWeightBold];
    self.countdownLabel.font = [NSFont monospacedDigitSystemFontOfSize:72 weight:NSFontWeightBold];
    self.countdownLabel.accessibilityLabel = @"Emergency exit time remaining";

    self.statusLabel = [self labelWithString:[NSString stringWithFormat:
        @"Fence will enter full screen. The %@ timer begins only while this window stays foreground and focused.",
        [self durationDescription]]
                                               size:16
                                             weight:NSFontWeightMedium];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.maximumNumberOfLines = 3;
    [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:620].active = YES;

    NSTextField *checkpointExplanation = [self labelWithString:
        @"One surprise attention check will appear. Confirm it within three seconds or the timer restarts."
                                                        size:14
                                                      weight:NSFontWeightRegular];
    checkpointExplanation.textColor = NSColor.secondaryLabelColor;
    checkpointExplanation.maximumNumberOfLines = 2;
    [checkpointExplanation.widthAnchor constraintLessThanOrEqualToConstant:580].active = YES;

    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel emergency exit"
                                                target:self
                                                action:@selector(cancelClicked:)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    cancelButton.accessibilityHelp = @"Cancels this emergency exit attempt.";

    self.normalStack = [NSStackView stackViewWithViews:@[
        titleLabel,
        self.countdownLabel,
        self.statusLabel,
        checkpointExplanation,
        cancelButton,
    ]];
    self.normalStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.normalStack.alignment = NSLayoutAttributeCenterX;
    self.normalStack.spacing = 22;
    self.normalStack.translatesAutoresizingMaskIntoConstraints = NO;
    [rootView addSubview:self.normalStack];

    self.checkpointOverlay = [[NSView alloc] initWithFrame:rootView.bounds];
    self.checkpointOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.checkpointOverlay.wantsLayer = YES;
    self.checkpointOverlay.layer.backgroundColor = NSColor.systemGrayColor.CGColor;
    self.checkpointOverlay.hidden = YES;
    [rootView addSubview:self.checkpointOverlay];

    NSTextField *checkpointTitle = [self labelWithString:@"Attention check" size:34 weight:NSFontWeightBold];
    checkpointTitle.textColor = NSColor.whiteColor;
    self.checkpointCountdownLabel = [self labelWithString:@"Confirm within 3 seconds"
                                                     size:20
                                                   weight:NSFontWeightSemibold];
    self.checkpointCountdownLabel.textColor = NSColor.whiteColor;
    self.checkpointCountdownLabel.accessibilityLabel = @"Time remaining to confirm attention check";

    self.checkpointButton = [NSButton buttonWithTitle:@"I’m still here"
                                               target:self
                                               action:@selector(confirmCheckpointClicked:)];
    self.checkpointButton.bezelStyle = NSBezelStyleRounded;
    self.checkpointButton.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    self.checkpointButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.checkpointButton.accessibilityLabel = @"Confirm I am still here";
    self.checkpointButton.accessibilityHelp = @"Activate within three seconds to continue the emergency exit timer.";

    NSStackView *checkpointStack = [NSStackView stackViewWithViews:@[
        checkpointTitle,
        self.checkpointCountdownLabel,
        self.checkpointButton,
    ]];
    checkpointStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    checkpointStack.alignment = NSLayoutAttributeCenterX;
    checkpointStack.spacing = 24;
    checkpointStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.checkpointOverlay addSubview:checkpointStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.normalStack.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor],
        [self.normalStack.centerYAnchor constraintEqualToAnchor:rootView.centerYAnchor],
        [self.normalStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:rootView.leadingAnchor constant:40],
        [self.normalStack.trailingAnchor constraintLessThanOrEqualToAnchor:rootView.trailingAnchor constant:-40],

        [self.checkpointOverlay.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [self.checkpointOverlay.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [self.checkpointOverlay.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [self.checkpointOverlay.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
        [checkpointStack.centerXAnchor constraintEqualToAnchor:self.checkpointOverlay.centerXAnchor],
        [checkpointStack.centerYAnchor constraintEqualToAnchor:self.checkpointOverlay.centerYAnchor],
        [self.checkpointButton.widthAnchor constraintGreaterThanOrEqualToConstant:300],
        [self.checkpointButton.heightAnchor constraintEqualToConstant:64],
    ]];
}

- (NSString *)countdownStringForSeconds:(NSTimeInterval)seconds {
    NSInteger wholeSeconds = MAX(0, (NSInteger)ceil(seconds));
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)(wholeSeconds / 60), (long)(wholeSeconds % 60)];
}

- (NSString *)durationDescription {
    NSInteger minutes = MAX(1, (NSInteger)llround(self.attemptDuration / 60.0));
    return [NSString stringWithFormat:@"%ld-minute", (long)minutes];
}

- (void)begin {
    if (self.monitoring) return;
    [self startMonitoring];
    [self showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isWindowFullScreen]) {
            [self.window toggleFullScreen:nil];
        } else {
            [self processEligibilityWithFullScreen:YES];
        }
    });
}

- (void)startMonitoring {
    self.monitoring = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(eligibilityDidChange:)
                   name:NSApplicationDidResignActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(eligibilityDidChange:)
                   name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(eligibilityDidChange:)
                   name:NSWindowDidResignKeyNotification object:self.window];
    [center addObserver:self selector:@selector(eligibilityDidChange:)
                   name:NSWindowDidBecomeKeyNotification object:self.window];
    [center addObserver:self selector:@selector(windowDidEnterFullScreen:)
                   name:NSWindowDidEnterFullScreenNotification object:self.window];
    [center addObserver:self selector:@selector(windowWillExitFullScreen:)
                   name:NSWindowWillExitFullScreenNotification object:self.window];
    [center addObserver:self selector:@selector(windowWillClose:)
                   name:NSWindowWillCloseNotification object:self.window];

    self.updateTimer = [NSTimer timerWithTimeInterval:0.1
                                               target:self
                                             selector:@selector(updateTimerFired:)
                                             userInfo:nil
                                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopMonitoring {
    if (!self.monitoring) return;
    self.monitoring = NO;
    [self.updateTimer invalidate];
    self.updateTimer = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)eligibilityDidChange:(NSNotification *)notification {
    [self processEligibilityWithFullScreen:[self isWindowFullScreen]];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self processEligibilityWithFullScreen:YES];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    // The style mask can still contain FullScreen during the will-exit event.
    [self processEligibilityWithFullScreen:NO];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.finishing) return;
    [self finishCancelled];
}

- (void)updateTimerFired:(NSTimer *)timer {
    [self processEligibilityWithFullScreen:[self isWindowFullScreen]];
}

- (void)processEligibilityWithFullScreen:(BOOL)fullScreen {
    if (self.finishing) return;
    NSTimeInterval now = [self currentUptime];
    SCEmergencyExitAttemptTransition transition = [self.attempt updateAtUptime:now
                                                             applicationActive:NSApp.isActive
                                                                     windowKey:self.window.isKeyWindow
                                                                    fullScreen:fullScreen];
    [self renderAtUptime:now transition:transition];
    if (transition == SCEmergencyExitAttemptTransitionCompleted) {
        [self finishCompleted];
    }
}

- (void)renderAtUptime:(NSTimeInterval)uptime
             transition:(SCEmergencyExitAttemptTransition)transition {
    NSInteger remaining = [self.attempt wholeSecondsRemainingAtUptime:uptime];
    self.countdownLabel.stringValue = [self countdownStringForSeconds:remaining];

    BOOL checkpointPending = self.attempt.state == SCEmergencyExitAttemptStateCheckpointPending;
    self.checkpointOverlay.hidden = !checkpointPending;
    self.normalStack.alphaValue = checkpointPending ? 0.25 : 1.0;

    if (checkpointPending) {
        NSInteger responseSeconds = [self.attempt wholeCheckpointSecondsRemainingAtUptime:uptime];
        self.checkpointCountdownLabel.stringValue = [NSString stringWithFormat:
            @"Confirm within %ld second%@",
            (long)responseSeconds,
            responseSeconds == 1 ? @"" : @"s"];
    }

    switch (transition) {
        case SCEmergencyExitAttemptTransitionStarted:
            [self.window makeFirstResponder:nil];
            self.statusLabel.stringValue = @"Stay in this full-screen window and keep Fence in the foreground until the timer reaches zero.";
            break;
        case SCEmergencyExitAttemptTransitionCheckpointPresented:
            [self.window makeFirstResponder:self.checkpointButton];
            NSAccessibilityPostNotificationWithUserInfo(NSApp,
                NSAccessibilityAnnouncementRequestedNotification,
                @{ NSAccessibilityAnnouncementKey: @"Attention check. Confirm you are still here within three seconds.",
                   NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh) });
            break;
        case SCEmergencyExitAttemptTransitionCheckpointConfirmed:
            [self.window makeFirstResponder:nil];
            self.statusLabel.stringValue = @"Attention check confirmed. Stay here until the timer finishes.";
            break;
        case SCEmergencyExitAttemptTransitionReset:
            [self.window makeFirstResponder:nil];
            if (self.attempt.state == SCEmergencyExitAttemptStateWaitingForEligibility) {
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    @"Attempt reset. Return to this full-screen, focused window to start again from %@.",
                    [self countdownStringForSeconds:self.attemptDuration]];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    @"Attempt reset. Starting again from %@.",
                    [self countdownStringForSeconds:self.attemptDuration]];
            }
            NSAccessibilityPostNotificationWithUserInfo(NSApp,
                NSAccessibilityAnnouncementRequestedNotification,
                @{ NSAccessibilityAnnouncementKey: [NSString stringWithFormat:
                       @"Emergency exit attempt reset to %ld minutes.",
                       (long)MAX(1, (NSInteger)llround(self.attemptDuration / 60.0))],
                   NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh) });
            break;
        case SCEmergencyExitAttemptTransitionNone:
        case SCEmergencyExitAttemptTransitionCompleted:
            break;
    }
}

- (void)confirmCheckpointClicked:(id)sender {
    if (self.finishing) return;
    NSTimeInterval now = [self currentUptime];
    SCEmergencyExitAttemptTransition transition = [self.attempt confirmCheckpointAtUptime:now];
    [self renderAtUptime:now transition:transition];
}

- (void)cancelClicked:(id)sender {
    [self.window close];
}

- (void)finishCancelled {
    if (self.finishing) return;
    self.finishing = YES;
    [self stopMonitoring];
    dispatch_block_t cancellation = self.cancellationHandler;
    self.cancellationHandler = nil;
    self.completionHandler = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cancellation) cancellation();
    });
}

- (void)finishCompleted {
    if (self.finishing) return;
    self.finishing = YES;
    [self stopMonitoring];
    dispatch_block_t completion = self.completionHandler;
    self.completionHandler = nil;
    self.cancellationHandler = nil;
    [self.window close];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion();
    });
}

@end

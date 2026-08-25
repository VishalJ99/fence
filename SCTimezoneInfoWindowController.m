//
//  SCTimezoneInfoWindowController.m
//  SelfControl
//

#import "SCTimezoneInfoWindowController.h"
#import "SCTravelTimezoneManager.h"
#import "Block Management/SCScheduleManager.h"

#pragma mark - SCTimezoneInfoContentView (Private)

// Custom content view that handles Cmd+Q to quit even when sheet is modal
@interface SCTimezoneInfoContentView : NSView
@end

@implementation SCTimezoneInfoContentView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags];
    NSString *chars = [[event charactersIgnoringModifiers] lowercaseString];

    BOOL cmdPressed = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shiftPressed = (flags & NSEventModifierFlagShift) != 0;

    // Cmd+Q = Quit (close sheet first, then terminate to avoid bonk)
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"q"]) {
        NSWindow *sheet = self.window;
        NSWindow *parent = sheet.sheetParent;
        if (parent) {
            [parent endSheet:sheet];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return YES;
    }

    // ESC = Close sheet
    if (event.keyCode == 53) { // ESC key
        NSWindow *sheet = self.window;
        NSWindow *parent = sheet.sheetParent;
        if (parent) {
            [parent endSheet:sheet];
        }
        return YES;
    }

    return [super performKeyEquivalent:event];
}

@end

#pragma mark - SCTimezoneInfoWindowController

@interface SCTimezoneInfoWindowController ()
@property (nonatomic, strong) NSButton *okButton;
@property (nonatomic, strong) NSButton *travelModeCheckbox;
@property (nonatomic, strong) NSTextField *activeTitleLabel;
@property (nonatomic, strong) NSTextField *activeDetailLabel;
@property (nonatomic, strong) NSTextField *locationStatusLabel;
@property (nonatomic, strong) NSButton *openLocationSettingsButton;
@property (nonatomic, strong) id clickOutsideMonitor;
@property (nonatomic) BOOL refreshAfterOpeningLocationSettings;
@end

@implementation SCTimezoneInfoWindowController

+ (void)showAsSheetForWindow:(NSWindow *)parentWindow {
    SCTimezoneInfoWindowController *controller = [[SCTimezoneInfoWindowController alloc] init];
    [[SCTravelTimezoneManager sharedManager] requestAuthorizationFromUserInteraction];
    [parentWindow beginSheet:controller.window completionHandler:^(NSModalResponse __unused returnCode) {
        [controller removeClickOutsideMonitor];
    }];
    [controller setupClickOutsideMonitor];
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 500, 470);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Travelling";

    // Use custom content view that handles Cmd+Q
    SCTimezoneInfoContentView *customContentView = [[SCTimezoneInfoContentView alloc] initWithFrame:frame];
    window.contentView = customContentView;

    self = [super initWithWindow:window];
    if (self) {
        [self setupUI];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(travelTimezoneDidChange:)
                   name:SCTravelTimezoneManagerDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(travelTimezoneDidChange:)
                   name:SCScheduleManagerDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(applicationDidBecomeActiveAfterOpeningLocationSettings:)
                   name:NSApplicationDidBecomeActiveNotification
                 object:nil];
        [self refreshUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12.0;
    [contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24.0],
        [stack.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:22.0],
        [stack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-20.0],
    ]];

    NSTextField *titleLabel = [NSTextField labelWithString:@"Planning to travel?"];
    titleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    [stack addArrangedSubview:titleLabel];

    NSTextField *explainLabel = [NSTextField wrappingLabelWithString:
        @"Fence checks approximate location once at startup, wake, Commit, and when you open the schedule. It does not track location continuously, and changing your Mac's timezone cannot move your committed blocks."];
    explainLabel.font = [NSFont systemFontOfSize:13];
    [stack addArrangedSubview:explainLabel];
    [explainLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.travelModeCheckbox = [NSButton checkboxWithTitle:
        @"Automatically refresh my timezone at key moments"
                                                  target:self
                                                  action:@selector(travelModeChanged:)];
    [stack addArrangedSubview:self.travelModeCheckbox];
    [self.travelModeCheckbox.heightAnchor constraintGreaterThanOrEqualToConstant:40.0].active = YES;

    self.activeTitleLabel = [NSTextField labelWithString:@""];
    self.activeTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [stack addArrangedSubview:self.activeTitleLabel];

    self.activeDetailLabel = [NSTextField wrappingLabelWithString:@""];
    self.activeDetailLabel.font = [NSFont systemFontOfSize:12];
    self.activeDetailLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:self.activeDetailLabel];
    [self.activeDetailLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.locationStatusLabel = [NSTextField wrappingLabelWithString:@""];
    self.locationStatusLabel.font = [NSFont systemFontOfSize:12];
    self.locationStatusLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:self.locationStatusLabel];
    [self.locationStatusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.openLocationSettingsButton = [NSButton buttonWithTitle:@"Open Location Settings"
                                                         target:self
                                                         action:@selector(openLocationSettingsClicked:)];
    self.openLocationSettingsButton.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:self.openLocationSettingsButton];
    [self.openLocationSettingsButton.heightAnchor constraintGreaterThanOrEqualToConstant:40.0].active = YES;

    NSTextField *privacyLabel = [NSTextField wrappingLabelWithString:
        @"Fence uses Apple's Location Services only to resolve a timezone. It does not store coordinates or send them to Fence servers."];
    privacyLabel.font = [NSFont systemFontOfSize:11];
    privacyLabel.textColor = [NSColor tertiaryLabelColor];
    [stack addArrangedSubview:privacyLabel];
    [privacyLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    [stack addArrangedSubview:separator];
    [separator.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSTextField *manualTitle = [NSTextField labelWithString:@"Prefer not to use Location Services?"];
    manualTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    [stack addArrangedSubview:manualTitle];

    NSTextField *manualDetail = [NSTextField wrappingLabelWithString:
        @"Plan ahead before committing: shift your blocks to match your destination's local time. Without automatic travel mode, the schedule stays on the timezone used when you commit."];
    manualDetail.font = [NSFont systemFontOfSize:12];
    manualDetail.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:manualDetail];
    [manualDetail.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSView *buttonRow = [[NSView alloc] initWithFrame:NSZeroRect];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:buttonRow];
    [buttonRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [buttonRow.heightAnchor constraintEqualToConstant:40.0].active = YES;

    self.okButton = [NSButton buttonWithTitle:@"Got It"
                                       target:self
                                       action:@selector(okClicked:)];
    self.okButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.okButton.title = @"Got It";
    self.okButton.bezelStyle = NSBezelStyleRounded;
    self.okButton.keyEquivalent = @"\r"; // Enter key
    [buttonRow addSubview:self.okButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.okButton.trailingAnchor constraintEqualToAnchor:buttonRow.trailingAnchor],
        [self.okButton.topAnchor constraintEqualToAnchor:buttonRow.topAnchor],
        [self.okButton.bottomAnchor constraintEqualToAnchor:buttonRow.bottomAnchor],
        [self.okButton.widthAnchor constraintGreaterThanOrEqualToConstant:88.0],
    ]];
}

- (void)refreshUI {
    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    SCTravelTimezoneManager *travelManager = [SCTravelTimezoneManager sharedManager];
    BOOL hasCommitment = scheduleManager.hasRecurringCommitment;
    BOOL followsLocation = hasCommitment &&
        scheduleManager.recurringCommitmentFollowsLocationTimeZone;

    self.travelModeCheckbox.hidden = hasCommitment;
    self.travelModeCheckbox.state = travelManager.isEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.activeTitleLabel.hidden = !hasCommitment;
    self.activeDetailLabel.hidden = !hasCommitment;

    if (hasCommitment) {
        NSString *identifier = scheduleManager.recurringTimeZoneIdentifier;
        if (followsLocation) {
            self.activeTitleLabel.stringValue = @"Automatic timezone refresh is active";
            self.activeDetailLabel.stringValue = identifier.length > 0
                ? [NSString stringWithFormat:
                    @"Your schedule currently uses %@. Travel mode is locked until you end this commitment.",
                    identifier]
                : @"Travel mode is locked until you end this commitment.";
        } else {
            self.activeTitleLabel.stringValue = @"This commitment stays on its starting timezone";
            self.activeDetailLabel.stringValue = identifier.length > 0
                ? [NSString stringWithFormat:
                    @"Your schedule uses %@. Automatic travel mode cannot be turned on until you end this commitment.",
                    identifier]
                : @"Automatic travel mode cannot be turned on until you end this commitment.";
        }
    }

    BOOL showLocationStatus = followsLocation || (!hasCommitment && travelManager.isEnabled);
    self.locationStatusLabel.hidden = !showLocationStatus;
    self.openLocationSettingsButton.hidden = YES;
    self.openLocationSettingsButton.title = @"Open Location Settings";

    if (showLocationStatus) {
        NSString *identifier = travelManager.lastResolvedTimeZoneIdentifier;
        switch (travelManager.status) {
            case SCTravelTimezoneStatusReady:
                if (followsLocation && identifier.length > 0 &&
                    ![identifier isEqualToString:scheduleManager.recurringTimeZoneIdentifier]) {
                    self.locationStatusLabel.stringValue = [NSString stringWithFormat:
                        @"Location Services resolved %@. Fence is still using %@ until the helper can safely apply the update.",
                        identifier, scheduleManager.recurringTimeZoneIdentifier];
                } else {
                    if (identifier.length > 0) {
                        self.locationStatusLabel.stringValue = [NSString stringWithFormat:
                            @"Location Services resolved your timezone as %@.", identifier];
                    } else if (followsLocation) {
                        self.locationStatusLabel.stringValue = [NSString stringWithFormat:
                            @"Fence is using %@ while it waits for a fresh Location Services update.",
                            scheduleManager.recurringTimeZoneIdentifier];
                    } else {
                        self.locationStatusLabel.stringValue = @"Fence needs a fresh Location Services update before it can commit.";
                    }
                }
                break;
            case SCTravelTimezoneStatusNeedsAuthorization:
                self.locationStatusLabel.stringValue = @"Allow Location Services to let Fence resolve your timezone.";
                self.openLocationSettingsButton.title = @"Allow Location Access";
                self.openLocationSettingsButton.hidden = NO;
                break;
            case SCTravelTimezoneStatusUnavailable:
                if (followsLocation) {
                    identifier = scheduleManager.recurringTimeZoneIdentifier;
                    self.locationStatusLabel.stringValue = identifier.length > 0
                        ? [NSString stringWithFormat:
                            @"Location Services is unavailable. Fence will keep using %@ until it can resolve another timezone.",
                            identifier]
                        : @"Location Services is unavailable. Fence will retry at the next approved check.";
                    self.openLocationSettingsButton.hidden =
                        travelManager.failureReason != SCTravelTimezoneFailureReasonPermission;
                } else if (travelManager.failureReason == SCTravelTimezoneFailureReasonTransient &&
                           travelManager.timeZoneIdentifierForCommit.length > 0) {
                    NSString *candidate = travelManager.timeZoneIdentifierForCommit;
                    self.locationStatusLabel.stringValue = travelManager.usesTrustedTimeZoneForCommit
                        ? [NSString stringWithFormat:
                            @"Current location is unavailable. Fence can use your last verified timezone, %@, when you Commit.",
                            candidate]
                        : [NSString stringWithFormat:
                            @"The latest location check failed, but Fence can still use its recent verified timezone, %@, when you Commit.",
                            candidate];
                } else if (travelManager.failureReason == SCTravelTimezoneFailureReasonTransient) {
                    self.locationStatusLabel.stringValue = @"Fence couldn't determine your timezone and has no previously verified timezone.";
                } else {
                    self.locationStatusLabel.stringValue = @"Location Services is unavailable. Turn it on so Fence can resolve your timezone.";
                    self.openLocationSettingsButton.hidden = NO;
                }
                break;
            case SCTravelTimezoneStatusResolving:
                self.locationStatusLabel.stringValue = @"Resolving your timezone…";
                break;
            case SCTravelTimezoneStatusDisabled:
                self.locationStatusLabel.stringValue = @"";
                break;
        }
    }
}

- (void)travelModeChanged:(NSButton *)sender {
    SCTravelTimezoneManager *manager = [SCTravelTimezoneManager sharedManager];
    [manager setEnabled:sender.state == NSControlStateValueOn];
    [self refreshUI];
}

- (void)openLocationSettingsClicked:(id)sender {
    SCTravelTimezoneManager *manager = [SCTravelTimezoneManager sharedManager];
    if (manager.status == SCTravelTimezoneStatusNeedsAuthorization) {
        [manager requestAuthorizationFromUserInteraction];
        return;
    }
    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"];
    if (url != nil) {
        self.refreshAfterOpeningLocationSettings = YES;
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)applicationDidBecomeActiveAfterOpeningLocationSettings:(NSNotification *)notification {
    if (!self.refreshAfterOpeningLocationSettings) return;
    self.refreshAfterOpeningLocationSettings = NO;
    [[SCTravelTimezoneManager sharedManager] requestTimeZoneRefreshIfNeeded];
}

- (void)travelTimezoneDidChange:(NSNotification *)notification {
    [self refreshUI];
}

- (void)setupClickOutsideMonitor {
    __weak typeof(self) weakSelf = self;
    self.clickOutsideMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        NSWindow *sheet = weakSelf.window;

        // Check if click is outside the sheet
        if (event.window == sheet.sheetParent) {
            NSWindow *parent = sheet.sheetParent;
            if (parent) {
                [parent endSheet:sheet];
            }
        }
        return event;
    }];
}

- (void)removeClickOutsideMonitor {
    if (self.clickOutsideMonitor) {
        [NSEvent removeMonitor:self.clickOutsideMonitor];
        self.clickOutsideMonitor = nil;
    }
}

- (void)okClicked:(id)sender {
    NSWindow *sheet = self.window;
    NSWindow *parent = sheet.sheetParent;
    if (parent) {
        [parent endSheet:sheet];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeClickOutsideMonitor];
}

@end

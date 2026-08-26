//
//  SCMenuBarController.m
//  SelfControl
//

#import "SCMenuBarController.h"
#import "SCCountdownWarningController.h"
#import "Block Management/SCScheduleManager.h"
#import "Block Management/SCBlockBundle.h"
#import "Block Management/SCWeeklySchedule.h"
#import "Common/SCLicenseManager.h"
#import "Common/SCSentry.h"
#import "SCLicenseWindowController.h"
#import "SCTestBlockWindowController.h"
#import "SCSettings.h"
#import "Common/Utility/SCBlockUtilities.h"
#import "AppController.h"
#import <Sparkle/Sparkle.h>

static const NSTimeInterval SCWarningLeadTime = 90.0;

@interface SCMenuBarCountdownEvent : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSDate *targetDate;
@property (nonatomic, copy) NSString *eventIdentifier;
@end

@implementation SCMenuBarCountdownEvent
@end

@interface SCMenuBarController ()

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, strong, nullable) NSTimer *warningArmTimer;
@property (nonatomic, strong) SCCountdownWarningController *countdownWarningController;
@property (nonatomic, copy, nullable) NSString *dismissedWarningIdentifier;
@property (nonatomic, strong, nullable) SCLicenseWindowController *licenseWindowController;
@property (nonatomic, strong, nullable) SCTestBlockWindowController *testBlockWindowController;

- (void)refreshCountdownWarning;

@end

@implementation SCMenuBarController

+ (instancetype)sharedController {
    static SCMenuBarController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SCMenuBarController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isVisible = NO;
        _countdownWarningController = [[SCCountdownWarningController alloc] init];
        __weak typeof(self) weakSelf = self;
        _countdownWarningController.onDismiss = ^(NSString *eventIdentifier) {
            weakSelf.dismissedWarningIdentifier = eventIdentifier;
            [weakSelf refreshCountdownWarning];
        };
        _countdownWarningController.onExpire = ^{
            [weakSelf refreshCountdownWarning];
        };

        // Listen for schedule changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scheduleDidChange:)
                                                     name:SCScheduleManagerDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(systemClockDidChange:)
                                                     name:NSSystemClockDidChangeNotification
                                                   object:nil];

        // Listen for wake from sleep to refresh status
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                               selector:@selector(systemDidWake:)
                                                                   name:NSWorkspaceDidWakeNotification
                                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.updateTimer invalidate];
    [self.warningArmTimer invalidate];
    [self.countdownWarningController hideWarning];
}

#pragma mark - Visibility

- (void)setVisible:(BOOL)visible {
    if (_isVisible == visible) return;

    _isVisible = visible;

    if (visible) {
        [self createStatusItem];
        [self startUpdateTimer];
        [self refreshCountdownWarning];
    } else {
        [self.warningArmTimer invalidate];
        self.warningArmTimer = nil;
        [self.countdownWarningController hideWarning];
        [self removeStatusItem];
        [self stopUpdateTimer];
    }
}

- (void)createStatusItem {
    if (self.statusItem) return;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    // Set up button
    self.statusItem.button.image = [self statusImage];
    self.statusItem.button.imagePosition = NSImageLeft;

    // Create menu
    [self rebuildMenu];

    self.statusItem.menu = self.statusMenu;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshCountdownWarning];
    });
}

- (void)removeStatusItem {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}

#pragma mark - Menu Building

- (void)rebuildMenu {
    self.statusMenu = [[NSMenu alloc] init];
    self.statusMenu.delegate = self;

    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    // Only show bundle status pills when committed (like week schedule window).
    if (manager.isCommitted) {
        BOOL breakSuspendsEnforcement = manager.hasActiveTimedBreak &&
            !manager.protectedHoursActiveNow;
        if (manager.hasActiveTimedBreak) {
            NSString *breakText = breakSuspendsEnforcement
                ? @"● Break active"
                : @"● Break interrupted by Protected Hours";
            NSColor *breakColor = breakSuspendsEnforcement
                ? NSColor.systemGreenColor
                : NSColor.systemOrangeColor;
            NSMenuItem *breakItem = [[NSMenuItem alloc] initWithTitle:breakText
                                                               action:nil
                                                        keyEquivalent:@""];
            NSMutableAttributedString *breakTitle =
                [[NSMutableAttributedString alloc] initWithString:breakText];
            [breakTitle addAttributes:@{
                NSForegroundColorAttributeName: breakColor,
                NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
            } range:NSMakeRange(0, breakText.length)];
            breakItem.attributedTitle = breakTitle;
            breakItem.enabled = NO;
            [self.statusMenu addItem:breakItem];
        }

        NSUInteger renderedBundleCount = 0;
        for (SCBlockBundle *bundle in manager.bundles) {
            if (!bundle.enabled || bundle.entries.count == 0) continue;

            BOOL scheduleAllows = [manager wouldBundleBeAllowed:bundle.bundleID];
            NSString *statusStr = [manager statusStringForBundleID:bundle.bundleID];

            // Skip bundles with no schedule for current week
            if (statusStr.length == 0) continue;

            BOOL allowed = scheduleAllows || breakSuspendsEnforcement;
            NSString *statusWord = allowed ? @"allowed" : @"blocked";
            NSColor *statusColor = allowed ? [NSColor systemGreenColor] : [NSColor systemRedColor];

            NSString *fullText;
            if (breakSuspendsEnforcement && !scheduleAllows) {
                fullText = [NSString stringWithFormat:@"● %@ allowed during break", bundle.name];
            } else {
                fullText = [NSString stringWithFormat:@"● %@ %@ %@", bundle.name, statusWord, statusStr];
            }

            NSMenuItem *bundleItem = [[NSMenuItem alloc] initWithTitle:fullText
                                                                action:nil
                                                         keyEquivalent:@""];

            // Create attributed string with colored text
            NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc] initWithString:fullText];
            [attrTitle addAttribute:NSForegroundColorAttributeName value:statusColor range:NSMakeRange(0, fullText.length)];
            [attrTitle addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:13] range:NSMakeRange(0, fullText.length)];

            bundleItem.attributedTitle = attrTitle;
            bundleItem.enabled = NO;

            [self.statusMenu addItem:bundleItem];
            renderedBundleCount += 1;
        }

        if (renderedBundleCount == 0) {
            NSMenuItem *noBundlesItem = [[NSMenuItem alloc] initWithTitle:@"No active bundles configured"
                                                                   action:nil
                                                            keyEquivalent:@""];
            noBundlesItem.enabled = NO;
            [self.statusMenu addItem:noBundlesItem];
        }

        [self.statusMenu addItem:[NSMenuItem separatorItem]];
    }

    // Commitment / Test Block info
    BOOL blockIsRunning = [[SCSettings sharedSettings] boolForKey:@"BlockIsRunning"];
    BOOL isTestBlock = [[[SCSettings sharedSettings] valueForKey:@"IsTestBlock"] boolValue];

    if (manager.isCommitted) {
        NSString *commitmentText = @"Recurring commitment active";
        if (!manager.hasRecurringCommitment) {
            NSDate *legacyEnd = manager.commitmentEndDate;
            if (legacyEnd != nil) {
                NSDateFormatter *endFormatter = [[NSDateFormatter alloc] init];
                endFormatter.dateFormat = @"EEEE";
                commitmentText = [NSString stringWithFormat:@"Committed until %@",
                    [endFormatter stringFromDate:legacyEnd]];
            } else {
                commitmentText = @"Commitment active";
            }
        }

        NSMenuItem *commitItem = [[NSMenuItem alloc] initWithTitle:commitmentText
                                                            action:nil
                                                     keyEquivalent:@""];
        commitItem.enabled = NO;
        [self.statusMenu addItem:commitItem];
    } else if (blockIsRunning && isTestBlock) {
        // Test block active
        NSMenuItem *testBlockItem = [[NSMenuItem alloc] initWithTitle:@"Test Block Active"
                                                               action:nil
                                                        keyEquivalent:@""];
        testBlockItem.enabled = NO;
        [self.statusMenu addItem:testBlockItem];
    } else {
        // "No active commitment" - show when not committed and no test block
        NSMenuItem *noCommitItem = [[NSMenuItem alloc] initWithTitle:@"No active commitment"
                                                              action:nil
                                                       keyEquivalent:@""];
        noCommitItem.enabled = NO;
        [self.statusMenu addItem:noCommitItem];
    }

    // Show license/trial status (separate line, only when not licensed)
    SCLicenseStatus licenseStatus = [[SCLicenseManager sharedManager] currentStatus];
    if (licenseStatus != SCLicenseStatusValid) {
        NSString *trialText;
        NSColor *trialColor = nil;
        if (licenseStatus == SCLicenseStatusTrial) {
            NSInteger days = [[SCLicenseManager sharedManager] trialDaysRemaining];
            NSString *dayWord = (days == 1) ? @"day" : @"days";
            trialText = [NSString stringWithFormat:@"Free Trial (%ld %@ left)", (long)days, dayWord];
        } else {
            trialText = @"Trial Expired";
            trialColor = [NSColor systemRedColor];
        }

        NSMenuItem *trialItem = [[NSMenuItem alloc] initWithTitle:trialText
                                                           action:nil
                                                    keyEquivalent:@""];
        if (trialColor) {
            NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc] initWithString:trialText];
            [attrTitle addAttribute:NSForegroundColorAttributeName value:trialColor range:NSMakeRange(0, trialText.length)];
            trialItem.attributedTitle = attrTitle;
        }
        trialItem.enabled = NO;
        [self.statusMenu addItem:trialItem];
    }

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    // Show Week Schedule
    NSMenuItem *scheduleItem = [[NSMenuItem alloc] initWithTitle:@"Show Week Schedule"
                                                          action:@selector(showScheduleClicked:)
                                                   keyEquivalent:@""];
    scheduleItem.target = self;
    [self.statusMenu addItem:scheduleItem];

    // Try Test Block - always show when not committed, grey out if block active
    if (!manager.isCommitted) {
        NSMenuItem *testBlockMenuItem = [[NSMenuItem alloc] initWithTitle:@"Try Test Block"
                                                               action:@selector(tryTestBlockClicked:)
                                                        keyEquivalent:@""];
        testBlockMenuItem.target = self;
        testBlockMenuItem.enabled = !blockIsRunning;
        [self.statusMenu addItem:testBlockMenuItem];
    }

    // License option (reuse licenseStatus from above)
    if (licenseStatus != SCLicenseStatusValid) {
        [self.statusMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *licenseItem = [[NSMenuItem alloc] initWithTitle:@"Enter License"
                                                             action:@selector(enterLicenseClicked:)
                                                      keyEquivalent:@""];
        licenseItem.target = self;
        [self.statusMenu addItem:licenseItem];
    }

    // View Blocklist - when committed OR test block active
    if (manager.isCommitted || (blockIsRunning && isTestBlock)) {
        NSString *blocklistTitle;
        if (blockIsRunning && isTestBlock) {
            blocklistTitle = [self testBlockBlocklistMenuTitle];
        } else {
            blocklistTitle = [self blocklistMenuTitle];
        }
        NSMenuItem *blocklistItem = [[NSMenuItem alloc] initWithTitle:blocklistTitle
                                                               action:@selector(showBlocklistClicked:)
                                                        keyEquivalent:@""];
        blocklistItem.target = self;
        [self.statusMenu addItem:blocklistItem];
    }

#ifdef DEBUG
    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    // Debug submenu
    NSMenuItem *debugItem = [[NSMenuItem alloc] initWithTitle:@"Debug Options"
                                                       action:nil
                                                keyEquivalent:@""];
    NSMenu *debugMenu = [[NSMenu alloc] init];

    NSMenuItem *disableBlockingItem = [[NSMenuItem alloc] initWithTitle:@"Disable All Blocking"
                                                                 action:@selector(debugDisableBlocking:)
                                                          keyEquivalent:@""];
    disableBlockingItem.target = self;
    [debugMenu addItem:disableBlockingItem];

    NSMenuItem *triggerSafetyCheckItem = [[NSMenuItem alloc] initWithTitle:@"Trigger Safety Check"
                                                                    action:@selector(debugTriggerSafetyCheck:)
                                                             keyEquivalent:@""];
    triggerSafetyCheckItem.target = self;
    [debugMenu addItem:triggerSafetyCheckItem];

    NSMenuItem *resetTrialItem = [[NSMenuItem alloc] initWithTitle:@"Reset to Fresh Trial"
                                                            action:@selector(debugResetTrial:)
                                                     keyEquivalent:@""];
    resetTrialItem.target = self;
    [debugMenu addItem:resetTrialItem];

    NSMenuItem *expireTrialItem = [[NSMenuItem alloc] initWithTitle:@"Expire Trial"
                                                             action:@selector(debugExpireTrial:)
                                                      keyEquivalent:@""];
    expireTrialItem.target = self;
    [debugMenu addItem:expireTrialItem];

    debugItem.submenu = debugMenu;
    [self.statusMenu addItem:debugItem];
#endif

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    // Maintenance and privacy controls
    NSMenuItem *repairPermissionsItem = [[NSMenuItem alloc] initWithTitle:@"Repair Fence Permissions"
                                                                    action:@selector(repairPermissionsClicked:)
                                                             keyEquivalent:@""];
    repairPermissionsItem.target = self;
    [self.statusMenu addItem:repairPermissionsItem];

    NSMenuItem *errorReportingItem = [[NSMenuItem alloc] initWithTitle:@"Send Anonymized Error Reports"
                                                                action:@selector(toggleAnonymizedErrorReporting:)
                                                         keyEquivalent:@""];
    errorReportingItem.target = self;
    errorReportingItem.state = [SCSentry errorReportingEnabled]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [self.statusMenu addItem:errorReportingItem];

    NSMenuItem *diagnosticReportItem = [[NSMenuItem alloc] initWithTitle:@"Send Diagnostic Report Now…"
                                                                  action:@selector(sendDiagnosticReportClicked:)
                                                           keyEquivalent:@""];
    diagnosticReportItem.target = self;
    [self.statusMenu addItem:diagnosticReportItem];

    // Check for Updates
    NSMenuItem *updateItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates"
                                                        action:@selector(checkForUpdates:)
                                                 keyEquivalent:@""];
    updateItem.target = self;
    [self.statusMenu addItem:updateItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    // Quit
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Fence"
                                                      action:@selector(quitClicked:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [self.statusMenu addItem:quitItem];
}

- (NSString *)blocklistMenuTitle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];

    // Show the underlying committed policy even while a timed break temporarily
    // pauses enforcement.
    for (SCBlockBundle *bundle in manager.bundles) {
        if (!bundle.enabled || bundle.entries.count == 0) continue;
        if ([manager wouldBundleBeAllowed:bundle.bundleID]) {
            continue; // Skip bundles in allowed window
        }
        for (id entry in bundle.entries) {
            if ([entry isKindOfClass:[NSString class]] && [(NSString *)entry length] > 0) {
                [entries addObject:entry];
            }
        }
    }

    NSInteger siteCount = 0;
    NSInteger appCount = 0;
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"app:"]) {
            appCount++;
        } else {
            siteCount++;
        }
    }

    return [NSString stringWithFormat:@"View Blocklist (%ld sites, %ld apps)", (long)siteCount, (long)appCount];
}

- (NSString *)testBlockBlocklistMenuTitle {
    // For test blocks, count from ActiveBlocklist setting
    NSArray *activeBlocklist = [[SCSettings sharedSettings] valueForKey:@"ActiveBlocklist"];
    NSInteger siteCount = 0;
    NSInteger appCount = 0;

    for (id entry in activeBlocklist) {
        if ([entry isKindOfClass:[NSString class]]) {
            NSString *entryStr = (NSString *)entry;
            if ([entryStr hasPrefix:@"app:"]) {
                appCount++;
            } else {
                siteCount++;
            }
        }
    }

    return [NSString stringWithFormat:@"View Blocklist (%ld sites, %ld apps)", (long)siteCount, (long)appCount];
}

- (NSImage *)statusImage {
    // Load the fence image as a template (macOS will handle light/dark mode)
    NSImage *image = [NSImage imageNamed:@"MenuBarFence"];
    [image setTemplate:YES];
    return image;
}

- (NSImage *)circleImageWithColor:(NSColor *)color {
    CGFloat size = 16;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];

    [image lockFocus];
    [color setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 2, size - 4, size - 4)];
    [path fill];
    [image unlockFocus];

    return image;
}

#pragma mark - Countdown Warning

- (SCMenuBarCountdownEvent *)countdownEventAfterDate:(NSDate *)date {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (!self.isVisible || !manager.hasRecurringCommitment) return nil;
    NSString *commitmentGeneration = manager.recurringCommitmentGeneration ?: @"unknown";

    NSDate *breakEnd = manager.activeTimedBreakEndDate;
    NSArray<NSString *> *bundleIDs = nil;
    NSDate *blockStart = [manager nextRecurringBlockingStartAfterDate:date
                                                   affectedBundleIDs:&bundleIDs];
    BOOL breakEndsFirst = [breakEnd compare:date] == NSOrderedDescending &&
        (blockStart == nil || [breakEnd compare:blockStart] != NSOrderedDescending);
    if (breakEndsFirst) {
        SCMenuBarCountdownEvent *event = [[SCMenuBarCountdownEvent alloc] init];
        event.title = @"Break ending soon";
        event.targetDate = breakEnd;
        event.eventIdentifier = [NSString stringWithFormat:@"%@-break-%.3f",
            commitmentGeneration, breakEnd.timeIntervalSince1970];
        return event;
    }

    if (blockStart == nil || bundleIDs.count == 0) return nil;

    NSDictionary<NSString *, SCBlockBundle *> *bundlesByID = [NSDictionary dictionaryWithObjects:
        manager.bundles forKeys:[manager.bundles valueForKey:@"bundleID"]];
    NSMutableArray<NSString *> *bundleNames = [NSMutableArray array];
    for (NSString *bundleID in bundleIDs) {
        SCBlockBundle *bundle = bundlesByID[bundleID];
        if (bundle.name.length > 0) [bundleNames addObject:bundle.name];
    }
    if (bundleNames.count == 0) return nil;

    NSString *joinedNames = [NSListFormatter localizedStringByJoiningStrings:bundleNames];
    SCMenuBarCountdownEvent *event = [[SCMenuBarCountdownEvent alloc] init];
    event.title = [NSString stringWithFormat:@"%@ blocking starting soon", joinedNames];
    event.targetDate = blockStart;
    event.eventIdentifier = [NSString stringWithFormat:@"%@-block-%.0f-%@",
        commitmentGeneration, blockStart.timeIntervalSince1970,
        [bundleIDs componentsJoinedByString:@","]];
    return event;
}

- (void)refreshCountdownWarning {
    [self.warningArmTimer invalidate];
    self.warningArmTimer = nil;

    NSDate *now = [NSDate date];
    SCMenuBarCountdownEvent *event = [self countdownEventAfterDate:now];
    if (event == nil) {
        [self.countdownWarningController hideWarning];
        return;
    }

    NSTimeInterval remaining = [event.targetDate timeIntervalSinceDate:now];
    if (remaining <= 0.0) {
        [self.countdownWarningController hideWarning];
        return;
    }

    if (remaining <= SCWarningLeadTime) {
        if ([self.dismissedWarningIdentifier isEqualToString:event.eventIdentifier]) {
            [self.countdownWarningController hideWarning];
            return;
        }
        NSScreen *screen = self.statusItem.button.window.screen ?: NSScreen.mainScreen;
        [self.countdownWarningController showWarningWithTitle:event.title
                                                   targetDate:event.targetDate
                                              eventIdentifier:event.eventIdentifier
                                                       screen:screen];
        return;
    }

    [self.countdownWarningController hideWarning];
    NSDate *fireDate = [event.targetDate dateByAddingTimeInterval:-SCWarningLeadTime];
    self.warningArmTimer = [[NSTimer alloc] initWithFireDate:fireDate
                                                  interval:0.0
                                                    target:self
                                                  selector:@selector(warningArmTimerFired:)
                                                  userInfo:nil
                                                   repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.warningArmTimer forMode:NSRunLoopCommonModes];
}

- (void)warningArmTimerFired:(NSTimer *)timer {
    #pragma unused(timer)
    self.warningArmTimer = nil;
    [self refreshCountdownWarning];
}

#pragma mark - Update

- (void)updateStatus {
    if (!self.statusItem) return;

    self.statusItem.button.image = [self statusImage];
    [self rebuildMenu];
    self.statusItem.menu = self.statusMenu;
    [self refreshCountdownWarning];
}

- (void)startUpdateTimer {
    [self.updateTimer invalidate];

    // Update every 15 seconds to catch block state changes
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                        target:self
                                                      selector:@selector(timerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUpdateTimer {
    [self.updateTimer invalidate];
    self.updateTimer = nil;
}

- (void)timerFired:(NSTimer *)timer {
    [self updateStatus];
}

#pragma mark - Notifications

- (void)scheduleDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus];
    });
}

- (void)systemDidWake:(NSNotification *)note {
    // Refresh status after wake from sleep - block state may have changed
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus];
    });
}

- (void)systemClockDidChange:(NSNotification *)note {
    #pragma unused(note)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatus];
    });
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    // Rebuild menu fresh when opened to ensure latest state
    [self rebuildMenu];
    self.statusItem.menu = self.statusMenu;
    [self refreshCountdownWarning];
}

#pragma mark - Actions

- (void)openAppClicked:(id)sender {
    [self.delegate menuBarControllerDidRequestOpenApp:self];
}

- (void)showScheduleClicked:(id)sender {
    if (self.onShowSchedule) {
        self.onShowSchedule();
    } else {
        [self.delegate menuBarControllerDidRequestOpenApp:self];
    }
}

- (void)tryTestBlockClicked:(id)sender {
    // Don't open multiple windows
    if (self.testBlockWindowController) {
        [self.testBlockWindowController.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    self.testBlockWindowController = [[SCTestBlockWindowController alloc] init];
    self.testBlockWindowController.completionHandler = ^(BOOL didComplete) {
        self.testBlockWindowController = nil;
    };
    [self.testBlockWindowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showBlocklistClicked:(id)sender {
    if (self.onShowBlocklist) {
        self.onShowBlocklist();
    }
}

- (void)quitClicked:(id)sender {
    [NSApp terminate:nil];
}

- (void)toggleAnonymizedErrorReporting:(id)sender {
    BOOL enabled = ![SCSentry errorReportingEnabled];
    [SCSentry setUserErrorReportingEnabled:enabled];

    if ([sender isKindOfClass:[NSMenuItem class]]) {
        ((NSMenuItem *)sender).state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)sendDiagnosticReportClicked:(id)sender {
    if (self.onSendDiagnosticReport) {
        self.onSendDiagnosticReport();
    }
}

- (void)repairPermissionsClicked:(id)sender {
    if (self.onRepairPermissions) {
        self.onRepairPermissions();
    }
}

- (void)checkForUpdates:(id)sender {
    // Bring app to foreground so Sparkle dialogs are visible
    [NSApp activateIgnoringOtherApps:YES];

    AppController *appController = (AppController *)[NSApp delegate];
    [appController.updaterController checkForUpdates:sender];
}

#ifdef DEBUG
- (void)debugDisableBlocking:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SCDebugDisableBlockingRequested" object:nil];
}

- (void)debugTriggerSafetyCheck:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SCDebugTriggerSafetyCheckRequested" object:nil];
}

- (void)debugResetTrial:(id)sender {
    // Reset commit count and clear license from keychain
    [[SCLicenseManager sharedManager] resetTrialState];

    // Rebuild menu to reflect new state
    [self rebuildMenu];
}

- (void)debugExpireTrial:(id)sender {
    // Set expiry to today (expired) and clear license
    [[SCLicenseManager sharedManager] expireTrialState];

    // Rebuild menu to reflect new state
    [self rebuildMenu];
}
#endif

#pragma mark - License Actions

- (void)purchaseLicenseClicked:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://usefence.app/#pricing"]];
}

- (void)enterLicenseClicked:(id)sender {
    // Don't open multiple license windows - bring existing to front
    if (self.licenseWindowController) {
        NSWindow *parentWindow = self.licenseWindowController.window.sheetParent;
        if (parentWindow) {
            [parentWindow makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
        return;
    }

    // Get a window to present the sheet - use the schedule window if available
    NSWindow *parentWindow = nil;
    for (NSWindow *window in [NSApp windows]) {
        if (window.isVisible && window.canBecomeKeyWindow) {
            parentWindow = window;
            break;
        }
    }

    if (!parentWindow) {
        // No window available, open the app first
        if (self.delegate) {
            [self.delegate menuBarControllerDidRequestOpenApp:self];
        } else if (self.onEnterLicense) {
            self.onEnterLicense();
        }
        // Delay slightly to let window appear
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showLicenseWindow];
        });
    } else {
        [self showLicenseWindowWithParent:parentWindow];
    }
}

- (void)showLicenseWindow {
    // Guard handled in showLicenseWindowWithParent:
    NSWindow *parentWindow = nil;
    for (NSWindow *window in [NSApp windows]) {
        if (window.isVisible && window.canBecomeKeyWindow) {
            parentWindow = window;
            break;
        }
    }
    if (parentWindow) {
        [self showLicenseWindowWithParent:parentWindow];
    }
}

- (void)showLicenseWindowWithParent:(NSWindow *)parentWindow {
    // Don't open multiple license windows - bring existing to front
    if (self.licenseWindowController) {
        NSWindow *sheetParent = self.licenseWindowController.window.sheetParent;
        if (sheetParent) {
            [sheetParent makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
        return;
    }

    self.licenseWindowController = [[SCLicenseWindowController alloc] init];
    self.licenseWindowController.onLicenseActivated = ^{
        self.licenseWindowController = nil;
        [self updateStatus];  // Refresh menu to hide license options
    };
    self.licenseWindowController.onCancel = ^{
        self.licenseWindowController = nil;
    };
    [self.licenseWindowController beginSheetModalForWindow:parentWindow completionHandler:nil];
}

@end

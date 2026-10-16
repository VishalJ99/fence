//
//  SCMenuBarController.m
//  SelfControl
//

#import "SCMenuBarController.h"
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

@interface SCMenuBarController ()

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, strong, nullable) SCLicenseWindowController *licenseWindowController;
@property (nonatomic, strong, nullable) SCTestBlockWindowController *testBlockWindowController;

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

        // Listen for schedule changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scheduleDidChange:)
                                                     name:SCScheduleManagerDidChangeNotification
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
}

#pragma mark - Visibility

- (void)setVisible:(BOOL)visible {
    if (_isVisible == visible) return;

    _isVisible = visible;

    if (visible) {
        [self createStatusItem];
        [self startUpdateTimer];
    } else {
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

    // Only show bundle status pills when committed (like week schedule window)
    if (manager.isCommitted) {
        for (SCBlockBundle *bundle in manager.bundles) {
            BOOL allowed = [manager wouldBundleBeAllowed:bundle.bundleID];
            NSString *statusStr = [manager statusStringForBundleID:bundle.bundleID];

            // Skip bundles with no schedule for current week
            if (statusStr.length == 0) continue;

            NSString *statusWord = allowed ? @"allowed" : @"blocked";
            NSColor *statusColor = allowed ? [NSColor systemGreenColor] : [NSColor systemRedColor];

            // Format: "● noise allowed till 8:16pm"
            NSString *fullText = [NSString stringWithFormat:@"● %@ %@ %@", bundle.name, statusWord, statusStr];

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
        }

        if (manager.bundles.count == 0) {
            NSMenuItem *noBundlesItem = [[NSMenuItem alloc] initWithTitle:@"No bundles configured"
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
    NSDate *blockEndDate = [[SCSettings sharedSettings] valueForKey:@"BlockEndDate"];

    if (manager.isCommitted) {
        NSDateFormatter *endFormatter = [[NSDateFormatter alloc] init];
        endFormatter.dateFormat = @"EEEE";
        NSString *endDay = [endFormatter stringFromDate:manager.commitmentEndDate];

        NSMenuItem *commitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Committed until %@", endDay]
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

    NSMenuItem *resetCreditsItem = [[NSMenuItem alloc] initWithTitle:@"Reset Emergency Credits"
                                                              action:@selector(debugResetCredits:)
                                                       keyEquivalent:@""];
    resetCreditsItem.target = self;
    [debugMenu addItem:resetCreditsItem];

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
    NSInteger siteCount = 0;
    NSInteger appCount = 0;

    // Count entries from bundles currently blocking (not in allowed window)
    for (SCBlockBundle *bundle in manager.bundles) {
        if ([manager wouldBundleBeAllowed:bundle.bundleID]) {
            continue; // Skip bundles in allowed window
        }
        for (id entry in bundle.entries) {
            if ([entry isKindOfClass:[NSString class]]) {
                NSString *entryStr = (NSString *)entry;
                if ([entryStr hasPrefix:@"app:"]) {
                    appCount++;
                } else {
                    siteCount++;
                }
            }
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

#pragma mark - Update

- (void)updateStatus {
    if (!self.statusItem) return;

    self.statusItem.button.image = [self statusImage];
    [self rebuildMenu];
    self.statusItem.menu = self.statusMenu;
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

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    // Rebuild menu fresh when opened to ensure latest state
    [self rebuildMenu];
    self.statusItem.menu = self.statusMenu;
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

- (void)debugResetCredits:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SCDebugResetCreditsRequested" object:nil];
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

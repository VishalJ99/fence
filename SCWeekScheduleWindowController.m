//
//  SCWeekScheduleWindowController.m
//  SelfControl
//

#import "SCWeekScheduleWindowController.h"
#import "SCEmergencyExitWindowController.h"
#import "SCWeekGridView.h"
#import "SCBundleSidebarView.h"
#import "SCCalendarGridView.h"
#import "SCDayScheduleEditorController.h"
#import "SCBundleEditorController.h"
#import "SCTimezoneInfoWindowController.h"
#import "SCMenuBarController.h"
#import "SCUIUtilities.h"
#import "Block Management/SCScheduleManager.h"
#import "Block Management/SCBlockBundle.h"
#import "Block Management/SCWeeklySchedule.h"
#import "Common/SCLicenseManager.h"
#import "Common/SCSentry.h"
#import "SCMiscUtilities.h"
#import "SCLicenseWindowController.h"
#include <errno.h>

#pragma mark - SCHoverableLinkButton (Private)

/// A button that shows shadow on hover to indicate clickability
@interface SCHoverableLinkButton : NSButton
@end

@implementation SCHoverableLinkButton {
    NSTrackingArea *_trackingArea;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    self.layer.shadowOpacity = 0.3;
    self.layer.shadowColor = [NSColor.labelColor CGColor];
    self.layer.shadowOffset = CGSizeMake(0, 1);
    self.layer.shadowRadius = 3.0;
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    self.layer.shadowOpacity = 0;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end

// Feature flag to switch between old grid and new calendar UI
static BOOL const kUseCalendarUI = YES;

@interface SCWeekScheduleWindowController () <SCWeekGridViewDelegate,
                                               SCBundleSidebarViewDelegate,
                                               SCCalendarGridViewDelegate,
                                               SCDayScheduleEditorDelegate,
                                               SCBundleEditorDelegate,
                                               SCMenuBarControllerDelegate>

// UI Elements
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *weekLabel;
@property (nonatomic, strong) NSView *statusView;
@property (nonatomic, strong) NSStackView *statusStackView;
@property (nonatomic, strong) SCWeekGridView *weekGridView;
@property (nonatomic, strong) NSScrollView *gridScrollView;
@property (nonatomic, strong) NSButton *addBundleButton;
@property (nonatomic, strong) NSButton *breakButton;
@property (nonatomic, strong) NSButton *emergencyUnlockButton;
@property (nonatomic, strong) NSButton *commitButton;
@property (nonatomic, strong) NSTextField *commitmentLabel;

// New Calendar UI Elements
@property (nonatomic, strong) SCBundleSidebarView *bundleSidebar;
@property (nonatomic, strong) SCCalendarGridView *calendarGridView;
@property (nonatomic, strong) SCHoverableLinkButton *travelingButton;
@property (nonatomic, copy, nullable) NSString *focusedBundleID;  // nil = All-Up state

// Week navigation
@property (nonatomic, strong) NSButton *prevWeekButton;
@property (nonatomic, strong) NSButton *nextWeekButton;
@property (nonatomic, assign) NSInteger currentWeekOffset; // 0 = this week, 1 = next week
@property (nonatomic, assign) NSInteger editingWeekOffset; // Week offset when day editor was opened

// Child controllers
@property (nonatomic, strong, nullable) SCDayScheduleEditorController *dayEditorController;
@property (nonatomic, strong, nullable) SCBundleEditorController *bundleEditorController;
@property (nonatomic, strong, nullable) SCLicenseWindowController *licenseWindowController;
@property (nonatomic, strong, nullable) SCEmergencyExitWindowController *emergencyExitWindowController;

// Flag to prevent redundant reloadData when grid updates schedule
@property (nonatomic, assign) BOOL isUpdatingFromGrid;

// Event monitor for Cmd+Q during alert sheets
@property (nonatomic, strong) id cmdQMonitor;

// Periodic refresh timer for active break countdown and NOW/status updates
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) NSUInteger refreshTickCount;

// Prevent the migration choice sheet from being presented more than once at a time.
@property (nonatomic, assign) BOOL migrationChoiceAlertPresented;
@property (nonatomic, assign) BOOL migrationChoiceDeferred;

@end

@implementation SCWeekScheduleWindowController

static void SCEmitEmergencyUnlockResult(NSString *outcome,
                                        NSInteger creditsRemaining,
                                        BOOL settingsCleared,
                                        BOOL hostsClean,
                                        BOOL pfClean,
                                        NSDate *startedAt,
                                        NSNumber *appleScriptErrorCode) {
    NSUInteger durationMilliseconds = (NSUInteger)llround(
        MAX(0, [[NSDate date] timeIntervalSinceDate:startedAt]) * 1000.0);
    NSMutableDictionary<NSString *, id> *fields = [@{
        @"outcome": outcome,
        @"credits_remaining": @(MAX(0, creditsRemaining)),
        @"settings_cleared": @(settingsCleared),
        @"hosts_clean": @(hostsClean),
        @"pf_check": @(pfClean),
        @"duration_milliseconds": @(durationMilliseconds),
    } mutableCopy];
    if ([appleScriptErrorCode isKindOfClass:[NSNumber class]]) {
        fields[@"apple_script_error_code"] = appleScriptErrorCode;
    }
    SCTelemetryEventLevel level = [outcome isEqualToString:@"success"]
        ? SCTelemetryEventLevelInfo : SCTelemetryEventLevelError;
    [SCSentry captureTelemetryEvent:@"emergency.unlock_result" level:level fields:fields];
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 1440, 1116);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable |
                                                             NSWindowStyleMaskFullSizeContentView)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Fence - Week Schedule";
    window.minSize = NSMakeSize(600, 500);
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    self = [super initWithWindow:window];
    if (self) {
        [self setupUI];
        [self setupMenuBar];
        [self setupNotifications];
        [self reloadData];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.refreshTimer invalidate];
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;

    // Apply frosted glass styling
    [SCUIUtilities applyFrostedGlassStyleToWindow:self.window];

    // Create frosted glass background view
    NSVisualEffectView *frostedBackground = [SCUIUtilities createFrostedGlassViewWithFrame:contentView.bounds cornerRadius:16.0];
    frostedBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:frostedBackground positioned:NSWindowBelow relativeTo:nil];

    CGFloat padding = 16;
    CGFloat topPadding = 32; // Extra space below traffic lights
    CGFloat y = contentView.bounds.size.height - topPadding;

    // Title
    y -= 30;
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding, y, 200, 24)];
    self.titleLabel.stringValue = @"Fence";
    self.titleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightBold];
    self.titleLabel.bezeled = NO;
    self.titleLabel.editable = NO;
    self.titleLabel.drawsBackground = NO;
    self.titleLabel.autoresizingMask = NSViewMinYMargin; // Stay pinned to top
    [contentView addSubview:self.titleLabel];

    // The schedule is a date-independent seven-day template. Keep the existing
    // navigation controls allocated for layout compatibility, but hide them.
    CGFloat navX = contentView.bounds.size.width - 390 - padding;

    // Previous week button (This Week)
    self.prevWeekButton = [[NSButton alloc] initWithFrame:NSMakeRect(navX, y, 90, 24)];
    self.prevWeekButton.title = @"This Week";
    self.prevWeekButton.bezelStyle = NSBezelStyleRounded;
    self.prevWeekButton.font = [NSFont systemFontOfSize:11];
    self.prevWeekButton.target = self;
    self.prevWeekButton.action = @selector(navigateToPrevWeek:);
    self.prevWeekButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.prevWeekButton.enabled = NO; // Disabled when on current week
    self.prevWeekButton.hidden = YES;
    [contentView addSubview:self.prevWeekButton];

    // Week label (center of navigation)
    self.weekLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(navX + 95, y, 200, 24)];
    self.weekLabel.alignment = NSTextAlignmentCenter;
    self.weekLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.weekLabel.textColor = [NSColor labelColor];
    self.weekLabel.bezeled = NO;
    self.weekLabel.editable = NO;
    self.weekLabel.drawsBackground = NO;
    self.weekLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self updateWeekLabel];
    [contentView addSubview:self.weekLabel];

    // Next week button
    self.nextWeekButton = [[NSButton alloc] initWithFrame:NSMakeRect(navX + 300, y, 90, 24)];
    self.nextWeekButton.title = @"Next Week →";
    self.nextWeekButton.bezelStyle = NSBezelStyleRounded;
    self.nextWeekButton.font = [NSFont systemFontOfSize:11];
    self.nextWeekButton.target = self;
    self.nextWeekButton.action = @selector(navigateToNextWeek:);
    self.nextWeekButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.nextWeekButton.hidden = YES;
    [contentView addSubview:self.nextWeekButton];

    // Status view - use semi-transparent background to work with frosted glass
    y -= 66; // 50px height + 16px gap
    self.statusView = [[NSView alloc] initWithFrame:NSMakeRect(padding, y, contentView.bounds.size.width - padding * 2, 50)];
    self.statusView.wantsLayer = YES;
    self.statusView.layer.backgroundColor = [[NSColor.whiteColor colorWithAlphaComponent:0.1] CGColor];
    self.statusView.layer.cornerRadius = 8;
    self.statusView.layer.borderWidth = 1.0;
    self.statusView.layer.borderColor = [NSColor.whiteColor colorWithAlphaComponent:0.15].CGColor;
    self.statusView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin; // Stay pinned to top
    [contentView addSubview:self.statusView];

    self.statusStackView = [[NSStackView alloc] initWithFrame:NSMakeRect(12, 8, self.statusView.bounds.size.width - 24, 34)];
    self.statusStackView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.statusStackView.spacing = 8;
    self.statusStackView.alignment = NSLayoutAttributeCenterY;
    self.statusStackView.distribution = NSStackViewDistributionFill; // Pills size to content
    self.statusStackView.autoresizingMask = NSViewWidthSizable;
    [self.statusView addSubview:self.statusStackView];

    // Main content area - either old grid or new calendar UI
    CGFloat bottomControlsHeight = 85; // Space for buttons at bottom
    CGFloat gapBelowStatus = 16; // Space between status bar and content
    CGFloat mainAreaHeight = y - bottomControlsHeight - gapBelowStatus;
    CGFloat sidebarWidth = 180;

    if (kUseCalendarUI) {
        // NEW CALENDAR UI: Sidebar on left + Calendar on right

        // Bundle sidebar
        self.bundleSidebar = [[SCBundleSidebarView alloc] initWithFrame:NSMakeRect(padding, bottomControlsHeight, sidebarWidth, mainAreaHeight)];
        self.bundleSidebar.delegate = self;
        self.bundleSidebar.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
        [contentView addSubview:self.bundleSidebar];

        // "Traveling?" button below sidebar (positioned at bottom, above main controls)
        CGFloat travelingButtonY = 16; // Keep clear of the bottom action row at minimum width.
        self.travelingButton = [[SCHoverableLinkButton alloc] initWithFrame:NSMakeRect(padding, travelingButtonY, sidebarWidth, 20)];
        self.travelingButton.title = @"Traveling?";
        self.travelingButton.bezelStyle = NSBezelStyleInline;
        self.travelingButton.bordered = NO;
        self.travelingButton.wantsLayer = YES;
        self.travelingButton.layer.masksToBounds = NO; // Allow shadow to show
        self.travelingButton.font = [NSFont systemFontOfSize:11];
        self.travelingButton.contentTintColor = [NSColor secondaryLabelColor];
        self.travelingButton.alphaValue = 1.0;
        self.travelingButton.target = self;
        self.travelingButton.action = @selector(travelingButtonClicked:);
        self.travelingButton.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
        [contentView addSubview:self.travelingButton];

        // Calendar grid (to the right of sidebar)
        CGFloat calendarX = padding + sidebarWidth + padding;
        CGFloat calendarWidth = contentView.bounds.size.width - calendarX - padding;
        self.calendarGridView = [[SCCalendarGridView alloc] initWithFrame:NSMakeRect(calendarX, bottomControlsHeight, calendarWidth, mainAreaHeight)];
        self.calendarGridView.delegate = self;
        self.calendarGridView.showOnlyRemainingDays = NO;
        self.calendarGridView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [contentView addSubview:self.calendarGridView];

    } else {
        // OLD GRID UI: Week grid takes full width
        self.gridScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(padding, bottomControlsHeight, contentView.bounds.size.width - padding * 2, mainAreaHeight)];
        self.gridScrollView.hasVerticalScroller = YES;
        self.gridScrollView.hasHorizontalScroller = NO;
        self.gridScrollView.autohidesScrollers = YES;
        self.gridScrollView.borderType = NSNoBorder;
        self.gridScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        self.weekGridView = [[SCWeekGridView alloc] initWithFrame:NSMakeRect(0, 0, self.gridScrollView.bounds.size.width, 300)];
        self.weekGridView.delegate = self;
        self.weekGridView.showOnlyRemainingDays = NO;

        self.gridScrollView.documentView = self.weekGridView;
        [contentView addSubview:self.gridScrollView];
    }

    // Bottom buttons - positioned at fixed location above window bottom
    CGFloat buttonY = 45;

    // Add Bundle button (only in old UI, sidebar has its own in new UI)
    if (!kUseCalendarUI) {
        self.addBundleButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding, buttonY, 120, 30)];
        self.addBundleButton.title = @"+ Add Bundle";
        self.addBundleButton.bezelStyle = NSBezelStyleRounded;
        self.addBundleButton.target = self;
        self.addBundleButton.action = @selector(addBundleClicked:);
        self.addBundleButton.autoresizingMask = NSViewMaxYMargin;
        [contentView addSubview:self.addBundleButton];
    }

    // Break, emergency exit, and commitment controls.
    self.breakButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentView.bounds.size.width - padding - 150 - 10 - 160 - 10 - 150, buttonY, 150, 30)];
    self.breakButton.title = @"Take Break (0)";
    self.breakButton.bezelStyle = NSBezelStyleRounded;
    self.breakButton.target = self;
    self.breakButton.action = @selector(breakButtonClicked:);
    self.breakButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.breakButton.toolTip = @"Ending a break early does not refund its credit.";
    [contentView addSubview:self.breakButton];

    // Emergency Unlock button (red, next to commit button)
    self.emergencyUnlockButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentView.bounds.size.width - padding - 150 - 10 - 160, buttonY, 160, 30)];
    self.emergencyUnlockButton.bezelStyle = NSBezelStyleRounded;
    self.emergencyUnlockButton.target = self;
    self.emergencyUnlockButton.action = @selector(emergencyUnlockClicked:);
    self.emergencyUnlockButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; // Stay at bottom-right
    [self updateEmergencyButtonTitle:@"Emergency Unlock (5)"];
    [contentView addSubview:self.emergencyUnlockButton];

    self.commitButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentView.bounds.size.width - padding - 150, buttonY, 150, 30)];
    self.commitButton.title = @"Commit";
    self.commitButton.bezelStyle = NSBezelStyleRounded;
    self.commitButton.target = self;
    self.commitButton.action = @selector(commitClicked:);
    self.commitButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; // Stay at bottom-right
    [contentView addSubview:self.commitButton];

    // Commitment label - below the commit button
    self.commitmentLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(contentView.bounds.size.width - padding - 200, buttonY - 20, 200, 20)];
    self.commitmentLabel.alignment = NSTextAlignmentRight;
    self.commitmentLabel.font = [NSFont systemFontOfSize:11];
    self.commitmentLabel.textColor = [NSColor secondaryLabelColor];
    self.commitmentLabel.bezeled = NO;
    self.commitmentLabel.editable = NO;
    self.commitmentLabel.drawsBackground = NO;
    self.commitmentLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; // Stay at bottom-right
    [contentView addSubview:self.commitmentLabel];
}

- (void)setupMenuBar {
    SCMenuBarController *menuBar = [SCMenuBarController sharedController];
    menuBar.delegate = self;
    [menuBar setVisible:YES];
}

- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scheduleDidChange:)
                                                 name:SCScheduleManagerDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(strictifyDidComplete:)
                                                 name:SCScheduleStrictifyDidCompleteNotification
                                               object:nil];

    // Observe window resize to update grid layout
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification
                                               object:self.window];

    // Observe request to show this window (from test block completion)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showWeekScheduleWindowRequested:)
                                                 name:@"SCShowWeekScheduleWindow"
                                               object:nil];

    // Observe wake from sleep to refresh NOW line and status
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(systemDidWake:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];

    // The one-second tick keeps an active break countdown accurate. Full data
    // refreshes remain infrequent unless a manager notification arrives.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(refreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)strictifyDidComplete:(NSNotification *)notification {
    NSString *outcome = [notification.userInfo[SCScheduleStrictifyOutcomeKey]
        isKindOfClass:[NSString class]]
        ? notification.userInfo[SCScheduleStrictifyOutcomeKey] : @"failed";
    NSString *operationToken = [notification.userInfo[SCScheduleStrictifyOperationTokenKey]
        isKindOfClass:[NSString class]]
        ? notification.userInfo[SCScheduleStrictifyOperationTokenKey] : nil;
    if ([outcome isEqualToString:@"verified"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Current block update was not verified";
        if ([outcome isEqualToString:@"skipped"]) {
            alert.informativeText = @"Fence saved the website or app to the bundle, but could not match that bundle to the active committed schedule. Existing rules remain active; this addition may not be blocked.";
        } else {
            alert.informativeText = @"Fence saved the website or app, but one or more daemon, hosts, firewall, app-monitor, or persistence checks failed. Existing rules remain active; this addition may not be blocked.";
        }
        [alert addButtonWithTitle:@"Retry"];
        [alert addButtonWithTitle:@"OK"];

        void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                BOOL retryStarted = operationToken.length > 0
                    ? [[SCScheduleManager sharedManager] retryStrictifyUpdateForOperationToken:operationToken]
                    : [[SCScheduleManager sharedManager] retryLastStrictifyUpdate];
                if (!retryStarted) NSBeep();
            }
        };
        if (self.window.attachedSheet == nil) {
            [alert beginSheetModalForWindow:self.window completionHandler:completion];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.window.attachedSheet == nil) {
                    [alert beginSheetModalForWindow:self.window completionHandler:completion];
                }
            });
        }
    });
}

- (void)showWeekScheduleWindowRequested:(NSNotification*)note {
    self.currentWeekOffset = 0;
    [self.window makeKeyAndOrderFront:nil];
    [self reloadData];
    [self presentRecurringMigrationChoiceIfNeeded];
}

- (void)showWindow:(id)sender {
    self.currentWeekOffset = 0;
    [super showWindow:sender];
    [self reloadData];
    [self presentRecurringMigrationChoiceIfNeeded];
}

- (void)windowDidResize:(NSNotification *)note {
    // Update grid view height when window resizes (e.g., fullscreen)
    [self reloadData];
}

- (void)systemDidWake:(NSNotification *)note {
    // Refresh UI after wake from sleep - NOW line position and status may have changed
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadData];
        // Force calendar grid to redraw NOW line
        [self.calendarGridView setNeedsDisplay:YES];
    });
}

- (void)refreshTimerFired:(NSTimer *)timer {
    self.refreshTickCount++;
    [self updateCommitmentUI];
    if (self.refreshTickCount % 300 == 0) {
        [self updateStatusLabel];
    }
    [self.calendarGridView setNeedsDisplay:YES];
}

#pragma mark - Data

- (void)reloadData {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    self.currentWeekOffset = 0;
    BOOL editingLocked = manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice;

    if (kUseCalendarUI) {
        // Build the single recurring schedule dictionary used by both views.
        NSMutableDictionary *scheduleDict = [NSMutableDictionary dictionary];
        for (SCBlockBundle *bundle in manager.bundles) {
            SCWeeklySchedule *schedule = [manager recurringScheduleForBundleID:bundle.bundleID];
            if (schedule) {
                scheduleDict[bundle.bundleID] = schedule;
            }
        }

        self.bundleSidebar.bundles = manager.bundles;
        self.bundleSidebar.selectedBundleID = self.focusedBundleID;
        self.bundleSidebar.schedules = scheduleDict;
        self.bundleSidebar.isCommitted = editingLocked;
        [self.bundleSidebar reloadData];

        self.calendarGridView.bundles = manager.bundles;
        self.calendarGridView.schedules = scheduleDict;
        self.calendarGridView.focusedBundleID = self.focusedBundleID;
        self.calendarGridView.isCommitted = editingLocked;
        self.calendarGridView.showOnlyRemainingDays = NO;
        self.calendarGridView.weekOffset = 0;
        [self.calendarGridView reloadData];

    } else {
        // Old grid fallback, also backed by the recurring template.
        self.weekGridView.bundles = manager.bundles;
        self.weekGridView.schedules = manager.recurringSchedules;
        self.weekGridView.isCommitted = editingLocked;
        self.weekGridView.showOnlyRemainingDays = NO;
        self.weekGridView.weekOffset = 0;
        [self.weekGridView reloadData];
    }

    // Update status (only for current week)
    [self updateStatusLabel];

    // Update commitment UI
    [self updateCommitmentUI];

    // Update week label
    [self updateWeekLabel];

    // Update navigation buttons
    [self updateNavigationButtons];

    if (!kUseCalendarUI) {
        CGFloat contentHeight = 30 + manager.bundles.count * 60;
        CGFloat viewportHeight = self.gridScrollView.contentSize.height;
        CGFloat gridHeight = MAX(contentHeight, viewportHeight);
        NSRect gridFrame = self.weekGridView.frame;
        gridFrame.size.width = self.gridScrollView.contentSize.width;
        gridFrame.size.height = gridHeight;
        self.weekGridView.frame = gridFrame;
    }

    if (manager.recurringScheduleMigrationNeedsChoice && self.window.isVisible) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentRecurringMigrationChoiceIfNeeded];
        });
    }
}

- (NSDictionary<NSString *, NSNumber *> *)telemetryRenderSnapshot {
    BOOL windowLoaded = self.isWindowLoaded;
    BOOL windowVisible = windowLoaded && self.window.isVisible;
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSInteger selectedWeekOffset = 0;
    NSUInteger modelBundleCount = manager.bundles.count;
    NSUInteger modelScheduleCount = manager.recurringSchedules.count;

    BOOL calendarAttached = NO;
    BOOL calendarHasArea = NO;
    BOOL emptyStateVisible = NO;
    NSUInteger renderedBundleCount = 0;
    NSUInteger renderedScheduleCount = 0;
    NSUInteger dayColumnCount = 0;
    NSUInteger expectedAllowBlockCount = 0;
    NSUInteger renderedAllowBlockCount = 0;
    NSUInteger nonzeroAreaAllowBlockCount = 0;
    NSUInteger intersectingAllowBlockCount = 0;
    NSUInteger appearanceValidAllowBlockCount = 0;
    NSUInteger visibleAllowBlockCount = 0;

    if (windowLoaded && kUseCalendarUI && self.calendarGridView != nil) {
        calendarAttached = self.calendarGridView.superview != nil;
        calendarHasArea = NSWidth(self.calendarGridView.bounds) > 1 && NSHeight(self.calendarGridView.bounds) > 1;
        renderedBundleCount = self.calendarGridView.bundles.count;
        renderedScheduleCount = self.calendarGridView.schedules.count;
        dayColumnCount = [self.calendarGridView telemetryDayColumnCount];
        expectedAllowBlockCount = [self.calendarGridView telemetryExpectedAllowBlockCount];
        [self.calendarGridView layoutSubtreeIfNeeded];
        NSDictionary<NSString *, NSNumber *> *visibility =
            [self.calendarGridView telemetryAllowBlockVisibilitySnapshot];
        renderedAllowBlockCount = [visibility[@"rendered_count"] unsignedIntegerValue];
        nonzeroAreaAllowBlockCount = [visibility[@"nonzero_area_count"] unsignedIntegerValue];
        intersectingAllowBlockCount = [visibility[@"intersecting_count"] unsignedIntegerValue];
        appearanceValidAllowBlockCount = [visibility[@"appearance_valid_count"] unsignedIntegerValue];
        visibleAllowBlockCount = [visibility[@"visible_count"] unsignedIntegerValue];
        emptyStateVisible = [self.calendarGridView telemetryEmptyStateVisible];
    } else if (windowLoaded && !kUseCalendarUI && self.weekGridView != nil) {
        calendarAttached = self.weekGridView.superview != nil;
        calendarHasArea = NSWidth(self.weekGridView.bounds) > 1 && NSHeight(self.weekGridView.bounds) > 1;
        renderedBundleCount = self.weekGridView.bundles.count;
        renderedScheduleCount = self.weekGridView.schedules.count;
    }

    BOOL snapshotAvailable = windowLoaded && calendarAttached;
    BOOL bundleCountsMatch = snapshotAvailable && renderedBundleCount == modelBundleCount;
    BOOL scheduleCountsMatch = snapshotAvailable && renderedScheduleCount == modelScheduleCount;
    BOOL allowBlockCountsMatch = snapshotAvailable && renderedAllowBlockCount == expectedAllowBlockCount;
    BOOL blockGeometryCountsMatch = snapshotAvailable &&
        nonzeroAreaAllowBlockCount == expectedAllowBlockCount &&
        intersectingAllowBlockCount == expectedAllowBlockCount;
    BOOL blockAppearanceCountsMatch = snapshotAvailable &&
        appearanceValidAllowBlockCount == expectedAllowBlockCount;
    BOOL visibleAllowBlockCountsMatch = snapshotAvailable &&
        visibleAllowBlockCount == expectedAllowBlockCount;
    BOOL renderObjectsWithoutVisibleBlocks = snapshotAvailable &&
        renderedAllowBlockCount > 0 && visibleAllowBlockCount == 0;
    BOOL emptyDespiteModel = snapshotAvailable &&
        ((modelBundleCount > 0 && renderedBundleCount == 0) ||
         (modelScheduleCount > 0 && renderedScheduleCount == 0) ||
         (expectedAllowBlockCount > 0 && visibleAllowBlockCount == 0));
    BOOL windowOcclusionVisible = windowVisible &&
        (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;

    return @{
        @"week_window_initialized": @YES,
        @"week_window_loaded": @(windowLoaded),
        @"week_window_visible": @(windowVisible),
        @"ui_snapshot_available": @(snapshotAvailable),
        @"ui_calendar_attached": @(calendarAttached),
        @"ui_calendar_has_area": @(calendarHasArea),
        @"ui_empty_state_visible": @(emptyStateVisible),
        @"ui_bundle_counts_match": @(bundleCountsMatch),
        @"ui_schedule_counts_match": @(scheduleCountsMatch),
        @"ui_allow_block_counts_match": @(allowBlockCountsMatch),
        @"ui_block_geometry_counts_match": @(blockGeometryCountsMatch),
        @"ui_block_appearance_counts_match": @(blockAppearanceCountsMatch),
        @"ui_visible_allow_block_counts_match": @(visibleAllowBlockCountsMatch),
        @"ui_render_objects_without_visible_blocks": @(renderObjectsWithoutVisibleBlocks),
        @"ui_window_occlusion_visible": @(windowOcclusionVisible),
        @"ui_empty_despite_model": @(emptyDespiteModel),
        @"selected_week_offset": @(selectedWeekOffset),
        @"ui_model_bundle_count": @(modelBundleCount),
        @"ui_model_schedule_count": @(modelScheduleCount),
        @"ui_rendered_bundle_count": @(renderedBundleCount),
        @"ui_rendered_schedule_count": @(renderedScheduleCount),
        @"ui_day_column_count": @(dayColumnCount),
        @"ui_expected_allow_block_count": @(expectedAllowBlockCount),
        @"ui_rendered_allow_block_count": @(renderedAllowBlockCount),
        @"ui_nonzero_area_allow_block_count": @(nonzeroAreaAllowBlockCount),
        @"ui_intersecting_allow_block_count": @(intersectingAllowBlockCount),
        @"ui_appearance_valid_allow_block_count": @(appearanceValidAllowBlockCount),
        @"ui_visible_allow_block_count": @(visibleAllowBlockCount),
    };
}

- (void)updateStatusLabel {
    // Clear existing pills
    for (NSView *subview in [self.statusStackView.arrangedSubviews copy]) {
        [self.statusStackView removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }

    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    if (manager.hasActiveTimedBreak) {
        NSInteger remainingSeconds = (NSInteger)ceil(MAX(
            0, [manager.activeTimedBreakEndDate timeIntervalSinceNow]));
        NSString *message = manager.protectedHoursActiveNow
            ? [NSString stringWithFormat:
                @"Protected Hours are enforcing your schedule. Your break has %ld:%02ld remaining.",
                (long)(remainingSeconds / 60), (long)(remainingSeconds % 60)]
            : [NSString stringWithFormat:
                @"Break active — scheduled blocking resumes in %ld:%02ld.",
                (long)(remainingSeconds / 60), (long)(remainingSeconds % 60)];
        NSTextField *breakLabel = [NSTextField labelWithString:message];
        breakLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        breakLabel.textColor = manager.protectedHoursActiveNow
            ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
        [self.statusStackView addArrangedSubview:breakLabel];
        return;
    }

    // The recurring commitment record is the enforcement-session lifecycle.
    if (!manager.hasRecurringCommitment) {
        NSString *message = manager.hasUnexpiredLegacyCommitment
            ? @"Your legacy schedule remains enforced until its current commitment expires."
            : @"No active schedule - do you have the courage to commit?";
        NSTextField *uncommittedLabel = [NSTextField labelWithString:message];
        uncommittedLabel.font = [NSFont systemFontOfSize:12];
        uncommittedLabel.textColor = [NSColor secondaryLabelColor];
        [self.statusStackView addArrangedSubview:uncommittedLabel];
        return;
    }

    if (manager.bundles.count == 0) {
        NSTextField *emptyLabel = [NSTextField labelWithString:@"No bundles configured. Add a bundle to get started."];
        emptyLabel.font = [NSFont systemFontOfSize:12];
        emptyLabel.textColor = [NSColor secondaryLabelColor];
        [self.statusStackView addArrangedSubview:emptyLabel];
        return;
    }

    for (SCBlockBundle *bundle in manager.bundles) {
        BOOL allowed = [manager wouldBundleBeAllowed:bundle.bundleID];
        NSString *statusStr = [manager statusStringForBundleID:bundle.bundleID];

        // Skip bundles with no recurring schedule.
        if (statusStr.length == 0) continue;

        // Create pill container
        NSView *pill = [[NSView alloc] init];
        pill.wantsLayer = YES;
        pill.layer.cornerRadius = 6;

        // Set background color based on allowed/blocked state
        if (allowed) {
            pill.layer.backgroundColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.25].CGColor;
            pill.layer.borderColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.5].CGColor;
        } else {
            pill.layer.backgroundColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.25].CGColor;
            pill.layer.borderColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.5].CGColor;
        }
        pill.layer.borderWidth = 1.0;

        // Create horizontal stack inside pill
        NSStackView *pillStack = [[NSStackView alloc] init];
        pillStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        pillStack.spacing = 4;
        pillStack.edgeInsets = NSEdgeInsetsMake(4, 8, 4, 8);

        // Bundle color indicator (small circle)
        NSView *colorDot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
        colorDot.wantsLayer = YES;
        colorDot.layer.cornerRadius = 4;
        colorDot.layer.backgroundColor = bundle.color.CGColor;
        [colorDot setFrameSize:NSMakeSize(8, 8)];

        // Bundle name
        NSTextField *nameLabel = [NSTextField labelWithString:bundle.name];
        nameLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        nameLabel.textColor = [NSColor labelColor];

        // Status text (e.g., "blocked till 5pm" or "allowed till 8pm")
        NSString *statusWord = allowed ? @"allowed" : @"blocked";
        NSString *statusText = [NSString stringWithFormat:@"%@ %@", statusWord, statusStr];
        NSTextField *statusLabel = [NSTextField labelWithString:statusText];
        statusLabel.font = [NSFont systemFontOfSize:11];
        statusLabel.textColor = allowed ? [NSColor systemGreenColor] : [NSColor systemRedColor];

        [pillStack addArrangedSubview:colorDot];
        [pillStack addArrangedSubview:nameLabel];
        [pillStack addArrangedSubview:statusLabel];

        // Add constraints for the color dot
        [colorDot.widthAnchor constraintEqualToConstant:8].active = YES;
        [colorDot.heightAnchor constraintEqualToConstant:8].active = YES;

        pillStack.translatesAutoresizingMaskIntoConstraints = NO;
        [pill addSubview:pillStack];
        [NSLayoutConstraint activateConstraints:@[
            [pillStack.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor],
            [pillStack.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor],
            [pillStack.topAnchor constraintEqualToAnchor:pill.topAnchor],
            [pillStack.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor]
        ]];

        // Prevent pill from stretching - it should only be as wide as its content
        [pill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [pill setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        [self.statusStackView addArrangedSubview:pill];
    }

    // Add a flexible spacer at the end to push pills to the left
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.statusStackView addArrangedSubview:spacer];
}

- (void)updateEmergencyButtonTitle:(NSString *)title {
    NSMutableAttributedString *redTitle = [[NSMutableAttributedString alloc] initWithString:title];
    [redTitle addAttribute:NSForegroundColorAttributeName
                     value:[NSColor systemRedColor]
                     range:NSMakeRange(0, redTitle.length)];
    [redTitle addAttribute:NSFontAttributeName
                     value:[NSFont systemFontOfSize:13]
                     range:NSMakeRange(0, redTitle.length)];
    self.emergencyUnlockButton.attributedTitle = redTitle;
}

- (void)updateCommitmentUI {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    BOOL hasRecurringCommitment = manager.hasRecurringCommitment;

    NSInteger emergencyCredits = [manager emergencyUnlockCreditsRemaining];
    [self updateEmergencyButtonTitle:[NSString stringWithFormat:@"Emergency Unlock (%ld)", (long)emergencyCredits]];
    self.emergencyUnlockButton.enabled =
        (hasRecurringCommitment || manager.hasUnexpiredLegacyCommitment) && emergencyCredits > 0;

    NSInteger breakCredits = manager.breakCreditsRemainingToday;
    if (manager.hasActiveTimedBreak) {
        NSTimeInterval remaining = MAX(0, [manager.activeTimedBreakEndDate timeIntervalSinceNow]);
        NSInteger remainingSeconds = (NSInteger)ceil(remaining);
        NSString *breakAction = manager.protectedHoursActiveNow ? @"End Paused Break" : @"End Break";
        self.breakButton.title = [NSString stringWithFormat:@"%@ · %ld:%02ld", breakAction,
                                  (long)(remainingSeconds / 60),
                                  (long)(remainingSeconds % 60)];
        self.breakButton.enabled = YES;
    } else {
        self.breakButton.title = [NSString stringWithFormat:@"Take Break (%ld)", (long)breakCredits];
        self.breakButton.enabled = hasRecurringCommitment &&
            breakCredits > 0 &&
            !manager.protectedHoursActiveNow &&
            [self hasCurrentlyBlockedRecurringBundle];
    }

    if (hasRecurringCommitment && manager.isRecurringCommitmentLockActive) {
        self.commitButton.title = @"Committed ✓";
        self.commitButton.enabled = NO;
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"EEE, MMM d 'at' h:mm a";
        NSDate *endDate = manager.recurringCommitmentLockEndDate;
        self.commitmentLabel.stringValue = endDate
            ? [NSString stringWithFormat:@"End available %@; editing stays locked until you end it", [formatter stringFromDate:endDate]]
            : @"Editing is locked";
        self.commitmentLabel.textColor = [NSColor secondaryLabelColor];
    } else if (hasRecurringCommitment) {
        self.commitButton.title = @"End Commitment";
        self.commitButton.enabled = !manager.protectedHoursActiveNow;
        self.commitmentLabel.stringValue = manager.protectedHoursActiveNow
            ? @"Protected Hours active"
            : @"Schedule repeats until you end it";
        self.commitmentLabel.textColor = manager.protectedHoursActiveNow
            ? [NSColor systemOrangeColor]
            : [NSColor secondaryLabelColor];
    } else {
        self.commitButton.title = @"Commit";
        self.commitButton.enabled = manager.bundles.count > 0 &&
            !manager.hasUnexpiredLegacyCommitment &&
            !manager.recurringScheduleMigrationNeedsChoice;
        if (manager.recurringScheduleMigrationNeedsChoice) {
            self.commitmentLabel.stringValue = @"Choose a legacy schedule to continue";
        } else if (manager.hasUnexpiredLegacyCommitment) {
            self.commitmentLabel.stringValue = @"Current legacy commitment must finish first";
        } else {
            self.commitmentLabel.stringValue = @"Repeats until explicitly ended";
        }
        self.commitmentLabel.textColor = [NSColor secondaryLabelColor];
    }
}

- (BOOL)hasCurrentlyBlockedRecurringBundle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    for (SCBlockBundle *bundle in manager.bundles) {
        if (!bundle.enabled || bundle.entries.count == 0) continue;
        if (![manager wouldBundleBeAllowed:bundle.bundleID]) return YES;
    }
    return NO;
}

- (void)updateWeekLabel {
    self.currentWeekOffset = 0;
    self.weekLabel.stringValue = @"Repeats every week";
}

#pragma mark - Actions

- (void)presentRecurringMigrationChoiceIfNeeded {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (!manager.recurringScheduleMigrationNeedsChoice ||
        self.migrationChoiceAlertPresented ||
        self.migrationChoiceDeferred ||
        !self.window.isVisible ||
        self.window.attachedSheet != nil) {
        return;
    }

    self.migrationChoiceAlertPresented = YES;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Choose Your Recurring Schedule";
    alert.informativeText = @"Fence found different schedules for this week and next week. Choose which one should become the seven-day schedule that repeats every week.";
    [alert addButtonWithTitle:@"Use This Week"];
    [alert addButtonWithTitle:@"Use Next Week"];
    [alert addButtonWithTitle:@"Not Now"];

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.migrationChoiceAlertPresented = NO;

        if (response == NSAlertFirstButtonReturn) {
            [manager resolveRecurringScheduleMigrationUsingNextWeek:NO];
        } else if (response == NSAlertSecondButtonReturn) {
            [manager resolveRecurringScheduleMigrationUsingNextWeek:YES];
        } else {
            strongSelf.migrationChoiceDeferred = YES;
        }
        [strongSelf reloadData];
    }];
}

- (void)addBundleClicked:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Schedule Locked";
        alert.informativeText = manager.recurringScheduleMigrationNeedsChoice
            ? @"Choose which legacy schedule should repeat before editing bundles."
            : @"Bundles cannot be added or edited while a recurring commitment exists.";
        [alert runModal];
        return;
    }

    self.bundleEditorController = [[SCBundleEditorController alloc] initForNewBundle];
    self.bundleEditorController.delegate = self;
    self.bundleEditorController.isCommitted = NO;
    [self.bundleEditorController beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)travelingButtonClicked:(id)sender {
    [SCTimezoneInfoWindowController showAsSheetForWindow:self.window];
}

- (void)navigateToPrevWeek:(id)sender {
    self.currentWeekOffset = 0;
}

- (void)navigateToNextWeek:(id)sender {
    self.currentWeekOffset = 0;
}

- (void)updateNavigationButtons {
    self.currentWeekOffset = 0;
    self.prevWeekButton.enabled = NO;
    self.nextWeekButton.enabled = NO;
    self.prevWeekButton.hidden = YES;
    self.nextWeekButton.hidden = YES;
}

- (void)commitClicked:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    if (manager.hasRecurringCommitment) {
        if (manager.isRecurringCommitmentLockActive || manager.protectedHoursActiveNow) return;
        [self endRecurringCommitment];
        return;
    }

    if (manager.recurringScheduleMigrationNeedsChoice) {
        self.migrationChoiceDeferred = NO;
        [self presentRecurringMigrationChoiceIfNeeded];
        return;
    }

    if (manager.hasUnexpiredLegacyCommitment) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Legacy Commitment Still Active";
        alert.informativeText = @"Your current legacy commitment must finish before you can start a recurring commitment.";
        [alert runModal];
        return;
    }

    if (manager.bundles.count == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Bundles";
        alert.informativeText = @"Please add at least one bundle before committing.";
        [alert runModal];
        return;
    }

    // Preserve the existing license gate for starting a commitment.
    if (![[SCLicenseManager sharedManager] canCommit]) {
        [self showLicenseModalWithCompletion:^{
            // License now valid, show the confirmation dialog
            [self showCommitConfirmationDialog];
        }];
        return;
    }

    // Trial still valid or license valid - show confirmation dialog
    [self showCommitConfirmationDialog];
}

- (void)showCommitConfirmationDialog {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Start Recurring Commitment?";

    // Check for bundles with no allow blocks (will be blocked all week)
    NSMutableArray<NSString *> *bundlesWithNoAllowBlocks = [NSMutableArray array];
    for (SCBlockBundle *bundle in manager.bundles) {
        if (!bundle.enabled) continue;
        SCWeeklySchedule *schedule = [manager recurringScheduleForBundleID:bundle.bundleID];
        // No schedule OR schedule with no allowed windows = blocked all week
        BOOL hasAnyAllowWindows = NO;
        if (schedule) {
            for (NSString *dayKey in schedule.daySchedules) {
                if ([schedule.daySchedules[dayKey] count] > 0) {
                    hasAnyAllowWindows = YES;
                    break;
                }
            }
        }
        if (!hasAnyAllowWindows) {
            [bundlesWithNoAllowBlocks addObject:bundle.name];
        }
    }

    alert.informativeText = @"Your seven-day schedule repeats every week and stays enforced until you explicitly end the commitment. Editing and bundle changes stay locked until you end it; the selected period controls when End first becomes available.";

    CGFloat accessoryHeight = bundlesWithNoAllowBlocks.count > 0 ? 78 : 30;
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, accessoryHeight)];
    NSTextField *durationLabel = [NSTextField labelWithString:@"End available after:"];
    durationLabel.frame = NSMakeRect(0, accessoryHeight - 24, 130, 20);
    [accessory addSubview:durationLabel];

    NSPopUpButton *durationPopUp = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(135, accessoryHeight - 28, 130, 26)
        pullsDown:NO];
    for (NSInteger dayCount = 1; dayCount <= 7; dayCount++) {
        [durationPopUp addItemWithTitle:[NSString stringWithFormat:@"%ld day%@",
                                         (long)dayCount,
                                         dayCount == 1 ? @"" : @"s"]];
    }
    [durationPopUp selectItemAtIndex:2];
    [accessory addSubview:durationPopUp];

    if (bundlesWithNoAllowBlocks.count > 0) {
        NSString *bundleList = [bundlesWithNoAllowBlocks componentsJoinedByString:@", "];
        NSString *warningText = [NSString stringWithFormat:@"Warning: %@ will always be blocked because no allow windows are scheduled.", bundleList];
        NSTextField *warningLabel = [NSTextField wrappingLabelWithString:warningText];
        warningLabel.textColor = [NSColor systemRedColor];
        warningLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        warningLabel.frame = NSMakeRect(0, 0, 360, 42);
        [accessory addSubview:warningLabel];
    }
    alert.accessoryView = accessory;

    [alert addButtonWithTitle:@"Commit"];
    [alert addButtonWithTitle:@"Cancel"];

    // Setup Cmd+Q monitor so user can quit during alert
    [self setupCmdQMonitor];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        [self removeCmdQMonitor];

        if (returnCode == NSAlertFirstButtonReturn) {
            self.commitButton.title = @"Committing…";
            self.commitButton.enabled = NO;
            self.commitmentLabel.stringValue = @"Saving with the Fence helper";
            NSInteger days = durationPopUp.indexOfSelectedItem + 1;
            __weak typeof(self) weakSelf = self;
            [manager commitRecurringScheduleForDays:days completion:^(BOOL verified, NSError *error) {
                typeof(self) strongSelf = weakSelf;
                if (strongSelf == nil) return;

                [strongSelf reloadData];
                [strongSelf.window makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES];
                if (verified || [SCMiscUtilities errorIsAuthCanceled:error]) return;

                BOOL rootStorePersisted = manager.hasRecurringCommitment;
                NSAlert *failureAlert = [[NSAlert alloc] init];
                failureAlert.messageText = rootStorePersisted
                    ? @"Schedule Saved; Verification Incomplete"
                    : @"Schedule Was Not Committed";
                failureAlert.informativeText = rootStorePersisted
                    ? (error.localizedDescription ?: @"Fence saved the recurring commitment, but immediate enforcement verification did not finish. The daemon will continue retrying.")
                    : (error.localizedDescription ?: @"Fence could not verify the recurring commitment. Your schedule remains editable and existing active blocks are unchanged.");
                failureAlert.alertStyle = NSAlertStyleCritical;
                [failureAlert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            }];
        }
    }];
}

- (void)endRecurringCommitment {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    self.commitButton.title = @"Ending…";
    self.commitButton.enabled = NO;
    [manager endExpiredRecurringCommitmentWithCompletion:^(BOOL ended, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadData];
            [self.window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            if (ended || [SCMiscUtilities errorIsAuthCanceled:error]) return;

            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Commitment Was Not Ended";
            alert.informativeText = error.localizedDescription ?: @"Fence could not end the recurring commitment.";
            alert.alertStyle = NSAlertStyleCritical;
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        });
    }];
}

- (void)breakButtonClicked:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (manager.hasActiveTimedBreak) {
        self.breakButton.title = @"Ending Break…";
        self.breakButton.enabled = NO;
        [manager endTimedBreakWithCompletion:^(BOOL ended, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadData];
                if (ended || [SCMiscUtilities errorIsAuthCanceled:error]) return;

                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Break Was Not Ended";
                alert.informativeText = error.localizedDescription ?: @"Fence could not end the active break.";
                alert.alertStyle = NSAlertStyleCritical;
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
            });
        }];
        return;
    }

    if (!manager.hasRecurringCommitment ||
        manager.breakCreditsRemainingToday <= 0 ||
        manager.protectedHoursActiveNow ||
        ![self hasCurrentlyBlockedRecurringBundle]) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Take a Break";
    alert.informativeText = @"Choose a break length. This uses one credit; ending the break early does not refund it.";
    [alert addButtonWithTitle:@"5 minutes"];
    [alert addButtonWithTitle:@"15 minutes"];
    [alert addButtonWithTitle:@"30 minutes"];
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSInteger minutes = 0;
        if (response == NSAlertFirstButtonReturn) minutes = 5;
        else if (response == NSAlertSecondButtonReturn) minutes = 15;
        else if (response == NSAlertThirdButtonReturn) minutes = 30;
        if (minutes == 0) return;

        self.breakButton.title = @"Starting Break…";
        self.breakButton.enabled = NO;
        [manager beginTimedBreakForMinutes:minutes completion:^(BOOL started, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadData];
                if (started || [SCMiscUtilities errorIsAuthCanceled:error]) return;

                NSAlert *failureAlert = [[NSAlert alloc] init];
                failureAlert.messageText = @"Break Did Not Start";
                failureAlert.informativeText = error.localizedDescription ?: @"Fence could not start the timed break.";
                failureAlert.alertStyle = NSAlertStyleCritical;
                [failureAlert beginSheetModalForWindow:self.window completionHandler:nil];
            });
        }];
    }];
}

#pragma mark - Cmd+Q Monitor for Alert Sheets

- (void)setupCmdQMonitor {
    if (self.cmdQMonitor) return;  // Already set up

    __weak typeof(self) weakSelf = self;
    self.cmdQMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                             handler:^NSEvent *(NSEvent *event) {
        NSEventModifierFlags flags = [event modifierFlags];
        NSString *chars = [[event charactersIgnoringModifiers] lowercaseString];

        BOOL cmdPressed = (flags & NSEventModifierFlagCommand) != 0;
        BOOL shiftPressed = (flags & NSEventModifierFlagShift) != 0;

        // Cmd+Q = Quit (close sheet first, then terminate)
        if (cmdPressed && !shiftPressed && [chars isEqualToString:@"q"]) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf.window.attachedSheet) {
                [strongSelf.window endSheet:strongSelf.window.attachedSheet];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
            return nil;  // Consume the event
        }
        return event;
    }];
}

- (void)removeCmdQMonitor {
    if (self.cmdQMonitor) {
        [NSEvent removeMonitor:self.cmdQMonitor];
        self.cmdQMonitor = nil;
    }
}

#pragma mark - License

- (void)showLicenseModalWithCompletion:(void(^)(void))completion {
    self.licenseWindowController = [[SCLicenseWindowController alloc] init];
    self.licenseWindowController.onLicenseActivated = ^{
        self.licenseWindowController = nil;
        if (completion) {
            completion();
        }
    };
    self.licenseWindowController.onCancel = ^{
        self.licenseWindowController = nil;
        // User cancelled - they can't proceed without a license
    };
    [self.licenseWindowController beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)emergencyUnlockClicked:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSInteger credits = [manager emergencyUnlockCreditsRemaining];

    if (self.emergencyExitWindowController != nil) {
        [self.emergencyExitWindowController.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    if (!manager.hasRecurringCommitment && !manager.hasUnexpiredLegacyCommitment) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Active Commitment";
        alert.informativeText = @"Emergency Exit is available while a recurring or legacy commitment is active.";
        [alert runModal];
        return;
    }

    if (credits <= 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Credits Remaining";
        alert.informativeText = @"You have used all your emergency unlock credits.";
        [alert runModal];
        return;
    }

    // Confirmation dialog
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Begin Emergency Exit?";
    alert.informativeText = [NSString stringWithFormat:
        @"This starts a three-minute attention check. Fence must remain full screen, foreground, and focused for the entire timer. "
        @"One surprise prompt must be confirmed within three seconds or the timer restarts.\n\n"
        @"Completing the timer ends all blocking and uses 1 of your %ld remaining emergency unlock%@. The credit is used only after cleanup succeeds.",
        (long)credits, credits == 1 ? @"" : @"s"];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Begin"];
    [alert addButtonWithTitle:@"Cancel"];

    // Setup Cmd+Q monitor so user can quit during alert
    [self setupCmdQMonitor];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        [self removeCmdQMonitor];

        if (returnCode == NSAlertFirstButtonReturn) {
            __weak typeof(self) weakSelf = self;
            self.emergencyExitWindowController = [[SCEmergencyExitWindowController alloc]
                initWithCompletionHandler:^{
                    typeof(self) strongSelf = weakSelf;
                    if (strongSelf == nil) return;
                    strongSelf.emergencyExitWindowController = nil;
                    [strongSelf.window makeKeyAndOrderFront:nil];
                    [NSApp activateIgnoringOtherApps:YES];
                    [strongSelf performEmergencyUnlock];
                }
                cancellationHandler:^{
                    typeof(self) strongSelf = weakSelf;
                    if (strongSelf == nil) return;
                    strongSelf.emergencyExitWindowController = nil;
                    [strongSelf.window makeKeyAndOrderFront:nil];
                    [NSApp activateIgnoringOtherApps:YES];
                }];
            [self.emergencyExitWindowController begin];
        }
    }];
}

- (void)performEmergencyUnlock {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSDate *startedAt = [NSDate date];

    // Get path to emergency.sh in the app bundle or project directory
    NSString *scriptPath = [[NSBundle mainBundle] pathForResource:@"emergency" ofType:@"sh"];

    // Fallback: check project directory (for development)
    if (!scriptPath) {
        NSString *projectPath = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
        scriptPath = [projectPath stringByAppendingPathComponent:@"emergency.sh"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:scriptPath]) {
            // Try one more level up (in case we're in build/Release)
            projectPath = [[projectPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            scriptPath = [projectPath stringByAppendingPathComponent:@"emergency.sh"];
        }
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptPath]) {
        SCEmitEmergencyUnlockResult(@"script_error",
                                    [manager emergencyUnlockCreditsRemaining],
                                    NO, NO, NO, startedAt, @(ENOENT));
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Script Not Found";
        alert.informativeText = @"Could not find emergency.sh script.";
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return;
    }

    // Run script with admin privileges using AppleScript
    NSString *appleScriptSource = [NSString stringWithFormat:
        @"do shell script \"/bin/bash '%@'\" with administrator privileges", scriptPath];

    NSDictionary *errorInfo = nil;
    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:appleScriptSource];
    NSAppleEventDescriptor *result = [appleScript executeAndReturnError:&errorInfo];

    if (!result && errorInfo) {
        // User cancelled or error occurred
        NSNumber *errorNumber = errorInfo[NSAppleScriptErrorNumber];
        if (errorNumber && [errorNumber integerValue] == -128) {
            // User cancelled - don't show error, don't use credit
            return;
        }

        SCEmitEmergencyUnlockResult(@"script_error",
                                    [manager emergencyUnlockCreditsRemaining],
                                    NO, NO, NO, startedAt,
                                    [errorNumber isKindOfClass:[NSNumber class]] ? errorNumber : @(-1));

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Emergency Unlock Failed";
        alert.informativeText = [NSString stringWithFormat:@"Error: %@",
            errorInfo[NSAppleScriptErrorMessage] ?: @"Unknown error"];
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return;
    }

    // emergency.sh performs these checks while it still has administrator
    // privileges. Treat its fixed-format token as the postcondition contract;
    // arbitrary script output never enters telemetry.
    NSString *verification = [result.stringValue isKindOfClass:[NSString class]]
        ? result.stringValue : @"";
    BOOL settingsCleared = [verification containsString:@"settings=1"];
    BOOL hostsClean = [verification containsString:@"hosts=1"];
    BOOL pfClean = [verification containsString:@"pf=1"];
    if (!settingsCleared || !hostsClean || !pfClean) {
        SCEmitEmergencyUnlockResult(@"verify_failed",
                                    [manager emergencyUnlockCreditsRemaining],
                                    settingsCleared, hostsClean, pfClean, startedAt, nil);
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Emergency Unlock Could Not Be Verified";
        alert.informativeText = @"Fence did not consume an unlock credit because one or more blocking layers may still be active. Restart Fence and try again or contact support.";
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return;
    }

    // Consume a credit only after the root-side teardown postconditions pass.
    if (![manager useEmergencyUnlockCredit]) {
        [SCSentry captureTelemetryEvent:@"emergency.failed"
                                  level:SCTelemetryEventLevelError
                                 fields:@{@"stage": @"credit", @"credits_remaining": @0, @"error_code": @1}];
    }

    // Clear commitment from NSUserDefaults (script clears daemon state, we clear app state)
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults.allKeys) {
        if ([key hasPrefix:@"SCWeekCommitment_"] || [key hasPrefix:@"SCWeekSchedules_"]) {
            [defaults removeObjectForKey:key];
        }
    }
    [defaults removeObjectForKey:@"SCIsCommitted"];
    [defaults removeObjectForKey:@"SCRecurringCommitment"];
    [defaults removeObjectForKey:@"SCActiveTimedBreak"];
    [defaults synchronize];

    // Post notification to refresh UI
    [[NSNotificationCenter defaultCenter] postNotificationName:SCScheduleManagerDidChangeNotification object:nil];

    // Show success message
    NSInteger remaining = [manager emergencyUnlockCreditsRemaining];
    SCEmitEmergencyUnlockResult(@"success", remaining, YES, YES, YES, startedAt, nil);
    NSAlert *successAlert = [[NSAlert alloc] init];
    successAlert.messageText = @"Emergency Unlock Complete";
    successAlert.informativeText = [NSString stringWithFormat:
        @"All blocking has been removed.\n\nYou have %ld emergency unlock%@ remaining.",
        (long)remaining, remaining == 1 ? @"" : @"s"];
    [successAlert runModal];
}

#pragma mark - Notifications

- (void)scheduleDidChange:(NSNotification *)note {
    // Skip redundant reload when the grid itself triggered the update
    // (the grid already refreshes via handleScheduleUpdate)
    if (self.isUpdatingFromGrid) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadData];
    });
}

#pragma mark - SCWeekGridViewDelegate

- (void)weekGridView:(SCWeekGridView *)gridView didSelectBundle:(SCBlockBundle *)bundle forDay:(SCDayOfWeek)day {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    self.editingWeekOffset = 0;

    if (manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Schedule Locked";
        alert.informativeText = manager.recurringScheduleMigrationNeedsChoice
            ? @"Choose which legacy schedule should repeat before editing."
            : @"The recurring schedule cannot be modified while a commitment exists.";
        [alert runModal];
        return;
    }

    SCWeeklySchedule *schedule = [manager recurringScheduleForBundleID:bundle.bundleID];

    if (!schedule) {
        schedule = [manager createRecurringScheduleForBundle:bundle];
    }

    self.dayEditorController = [[SCDayScheduleEditorController alloc] initWithBundle:bundle
                                                                            schedule:schedule
                                                                                 day:day];
    self.dayEditorController.delegate = self;
    self.dayEditorController.isCommitted = NO;

    [self.dayEditorController beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)weekGridView:(SCWeekGridView *)gridView didRequestEditBundle:(SCBlockBundle *)bundle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Bundles Locked";
        alert.informativeText = manager.recurringScheduleMigrationNeedsChoice
            ? @"Choose which legacy schedule should repeat before editing bundles."
            : @"Bundle changes stay locked until you end the recurring commitment.";
        [alert runModal];
        return;
    }
    self.bundleEditorController = [[SCBundleEditorController alloc] initWithBundle:bundle];
    self.bundleEditorController.delegate = self;

    self.bundleEditorController.isCommitted =
        manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice;

    [self.bundleEditorController beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)weekGridViewDidRequestAddBundle:(SCWeekGridView *)gridView {
    [self addBundleClicked:nil];
}

#pragma mark - SCBundleSidebarViewDelegate

- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didSelectBundle:(nullable SCBlockBundle *)bundle {
    // Update focus state
    self.focusedBundleID = bundle.bundleID;

    // Update calendar grid with new focus
    self.calendarGridView.focusedBundleID = self.focusedBundleID;
    [self.calendarGridView reloadData];
}

- (void)bundleSidebarDidRequestAddBundle:(SCBundleSidebarView *)sidebar {
    [self addBundleClicked:nil];
}

- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didRequestEditBundle:(SCBlockBundle *)bundle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Bundles Locked";
        alert.informativeText = manager.recurringScheduleMigrationNeedsChoice
            ? @"Choose which legacy schedule should repeat before editing bundles."
            : @"Bundle changes stay locked until you end the recurring commitment.";
        [alert runModal];
        return;
    }
    self.bundleEditorController = [[SCBundleEditorController alloc] initWithBundle:bundle];
    self.bundleEditorController.delegate = self;

    self.bundleEditorController.isCommitted =
        manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice;

    [self.bundleEditorController beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - SCCalendarGridViewDelegate

- (void)calendarGrid:(SCCalendarGridView *)grid didUpdateSchedule:(SCWeeklySchedule *)schedule forBundleID:(NSString *)bundleID {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    SCWeeklySchedule *oldSchedule = [manager recurringScheduleForBundleID:bundleID];

    // Register undo action
    [[grid.undoManager prepareWithInvocationTarget:self] restoreSchedule:oldSchedule
                                                             forBundleID:bundleID
                                                              weekOffset:0
                                                            calendarGrid:grid];

    // Save the updated schedule to the manager
    // Set flag to prevent redundant reloadData (grid already updated itself)
    self.isUpdatingFromGrid = YES;
    [manager updateRecurringSchedule:schedule];
    self.isUpdatingFromGrid = NO;
}

- (void)restoreSchedule:(SCWeeklySchedule *)schedule
            forBundleID:(NSString *)bundleID
             weekOffset:(NSInteger)weekOffset
           calendarGrid:(SCCalendarGridView *)grid {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    // Capture current state for redo
    SCWeeklySchedule *currentSchedule = [manager recurringScheduleForBundleID:bundleID];
    [[grid.undoManager prepareWithInvocationTarget:self] restoreSchedule:currentSchedule
                                                             forBundleID:bundleID
                                                              weekOffset:weekOffset
                                                            calendarGrid:grid];

    // Restore the old schedule
    [manager updateRecurringSchedule:schedule];

    // Refresh the UI
    [self reloadData];
}

- (void)calendarGridDidClickEmptyArea:(SCCalendarGridView *)grid {
    // Clear focus - return to All-Up state
    self.focusedBundleID = nil;
    self.bundleSidebar.selectedBundleID = nil;
    [self.bundleSidebar reloadData];
    self.calendarGridView.focusedBundleID = nil;
    [self.calendarGridView reloadData];
}

- (void)calendarGrid:(SCCalendarGridView *)grid didRequestEditBundle:(SCBlockBundle *)bundle forDay:(SCDayOfWeek)day {
    // Open the day editor sheet for detailed editing
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    self.editingWeekOffset = 0;

    if (manager.hasRecurringCommitment || manager.recurringScheduleMigrationNeedsChoice) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Schedule Locked";
        alert.informativeText = manager.recurringScheduleMigrationNeedsChoice
            ? @"Choose which legacy schedule should repeat before editing."
            : @"The recurring schedule cannot be modified while a commitment exists.";
        [alert runModal];
        return;
    }

    SCWeeklySchedule *schedule = [manager recurringScheduleForBundleID:bundle.bundleID];
    if (!schedule) {
        schedule = [manager createRecurringScheduleForBundle:bundle];
    }

    self.dayEditorController = [[SCDayScheduleEditorController alloc] initWithBundle:bundle
                                                                            schedule:schedule
                                                                                 day:day];
    self.dayEditorController.delegate = self;
    self.dayEditorController.isCommitted = NO;

    [self.dayEditorController beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)calendarGridDidAttemptInteractionWithoutFocus:(SCCalendarGridView *)grid {
    [self showSelectBundleWarning];
}

#pragma mark - Warning UI

- (void)showSelectBundleWarning {
    // Don't show multiple warnings at once
    static BOOL isShowingWarning = NO;
    if (isShowingWarning) return;
    isShowingWarning = YES;

    // Create frosted glass toast (like status pills but grey)
    CGFloat toastWidth = 420;
    CGFloat toastHeight = 42;

    // Container view holds the shadow (decoupled from blur clipping)
    NSView *toastContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, toastWidth, toastHeight)];
    toastContainer.wantsLayer = YES;
    toastContainer.layer.backgroundColor = [NSColor clearColor].CGColor;
    toastContainer.layer.masksToBounds = NO;  // Allow shadow to render outside bounds

    // Pill-shaped shadow on container
    toastContainer.layer.shadowColor = [NSColor blackColor].CGColor;
    toastContainer.layer.shadowOpacity = 0.5;
    toastContainer.layer.shadowOffset = CGSizeMake(0, -4);
    toastContainer.layer.shadowRadius = 15;
    CGPathRef shadowPath = CGPathCreateWithRoundedRect(toastContainer.bounds, toastHeight / 2, toastHeight / 2, NULL);
    toastContainer.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);

    toastContainer.alphaValue = 0;

    // Visual effect view (the pill itself) - clips blur to rounded corners
    NSVisualEffectView *toast = [[NSVisualEffectView alloc] initWithFrame:toastContainer.bounds];
    toast.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    toast.material = NSVisualEffectMaterialToolTip;
    toast.state = NSVisualEffectStateActive;
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = toastHeight / 2;
    toast.layer.masksToBounds = YES;  // Clip blur to pill shape

    // Add subtle border for definition
    toast.layer.borderWidth = 1.0;
    toast.layer.borderColor = [[NSColor grayColor] colorWithAlphaComponent:0.3].CGColor;

    [toastContainer addSubview:toast];

    // Add label with contextual message
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSString *message = (manager.bundles.count == 0)
        ? @"To create allow block — create a bundle first"
        : @"To create allow block — select a bundle first";
    NSTextField *label = [NSTextField labelWithString:message];
    label.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    label.alignment = NSTextAlignmentCenter;
    label.frame = NSMakeRect(0, (toastHeight - 24) / 2, toastWidth, 24);
    [toast addSubview:label];

    // Position toast near top center of calendar grid
    NSRect gridFrame = self.calendarGridView.frame;
    toastContainer.frame = NSMakeRect(
        gridFrame.origin.x + (gridFrame.size.width - toastWidth) / 2,
        gridFrame.origin.y + gridFrame.size.height - 50,
        toastWidth, toastHeight
    );
    [self.calendarGridView.superview addSubview:toastContainer positioned:NSWindowAbove relativeTo:self.calendarGridView];

    // Flash calendar border red
    CALayer *flashLayer = [CALayer layer];
    flashLayer.frame = self.calendarGridView.layer.bounds;
    flashLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    flashLayer.zPosition = 1000;  // Stay on top of grid content
    flashLayer.borderColor = [NSColor systemRedColor].CGColor;
    flashLayer.borderWidth = 2.0;
    flashLayer.cornerRadius = 4.0;
    flashLayer.opacity = 0;
    [self.calendarGridView.layer addSublayer:flashLayer];

    // Animate toast in, hold, then out
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        toastContainer.animator.alphaValue = 1.0;
        flashLayer.opacity = 0.8;
    } completionHandler:^{
        // Flash out
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.6;
            flashLayer.opacity = 0;
        } completionHandler:nil];

        // Hold then fade out toast
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.3;
                toastContainer.animator.alphaValue = 0;
            } completionHandler:^{
                [toastContainer removeFromSuperview];
                [flashLayer removeFromSuperlayer];
                isShowingWarning = NO;
            }];
        });
    }];
}

#pragma mark - SCDayScheduleEditorDelegate

- (void)dayScheduleEditor:(SCDayScheduleEditorController *)editor
         didSaveSchedule:(SCWeeklySchedule *)schedule
                  forDay:(SCDayOfWeek)day {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    [manager updateRecurringSchedule:schedule];
    self.dayEditorController = nil;
}

- (void)dayScheduleEditorDidCancel:(SCDayScheduleEditorController *)editor {
    self.dayEditorController = nil;
}

#pragma mark - SCBundleEditorDelegate

- (void)bundleEditor:(SCBundleEditorController *)editor didSaveBundle:(SCBlockBundle *)bundle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];

    if (editor.isNewBundle) {
        [manager addBundle:bundle];
    } else {
        [manager updateBundle:bundle];
    }

    self.bundleEditorController = nil;
}

- (void)bundleEditorDidCancel:(SCBundleEditorController *)editor {
    self.bundleEditorController = nil;
}

- (void)bundleEditor:(SCBundleEditorController *)editor didDeleteBundle:(SCBlockBundle *)bundle {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    [manager removeBundleWithID:bundle.bundleID];
    self.bundleEditorController = nil;
}

#pragma mark - SCMenuBarControllerDelegate

- (void)menuBarControllerDidRequestOpenApp:(SCMenuBarController *)controller {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - Keyboard Handling

- (void)cancelOperation:(id)sender {
    // Escape key - progressive: first clear selection, then clear focus
    if ([self.calendarGridView hasSelectedBlock]) {
        [self.calendarGridView clearAllSelections];
    } else if (self.focusedBundleID) {
        [self calendarGridDidClickEmptyArea:self.calendarGridView];
    }
}

@end

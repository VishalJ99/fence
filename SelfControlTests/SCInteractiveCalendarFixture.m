// PER-579: disposable AppKit harness using production calendar/sidebar/editor.
// Compiled only by work/build-fence-qa.py, never linked into the shipped app.
#import <Cocoa/Cocoa.h>
#import "SCBundleSidebarView.h"
#import "SCCalendarGridView.h"
#import "SCBundleEditorController.h"

@interface SCInteractiveCalendarFixture : NSObject <NSApplicationDelegate, SCBundleSidebarViewDelegate, SCCalendarGridViewDelegate, SCBundleEditorDelegate>
@property NSWindow *window;
@property SCBundleSidebarView *sidebar;
@property SCCalendarGridView *grid;
@property SCBundleEditorController *editor;
@property NSMutableArray<SCBlockBundle *> *bundles;
@property NSMutableDictionary<NSString *, SCWeeklySchedule *> *schedules;
@property NSDictionary<NSString *, SCWeeklySchedule *> *baseline;
@property NSSet<NSString *> *protectedIDs;
@property NSTextField *status;
@property NSSegmentedControl *mode;
@end

@implementation SCInteractiveCalendarFixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (self.window) return;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1200, 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Fence QA — synthetic data, no daemon";
    self.window.releasedWhenClosed = NO;
    NSView *content = self.window.contentView;
    self.mode = [NSSegmentedControl segmentedControlWithLabels:@[@"Active edit", @"Draft"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    self.mode.frame = NSMakeRect(16, 777, 220, 28);
    self.mode.autoresizingMask = NSViewMinYMargin;
    self.mode.selectedSegment = 0;
    [content addSubview:self.mode];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset fixture" target:self action:@selector(reset:)];
    reset.frame = NSMakeRect(250, 777, 140, 28);
    reset.autoresizingMask = NSViewMinYMargin;
    [content addSubview:reset];
    self.status = [NSTextField labelWithString:@"Synthetic fixture only. Changes stay in memory."];
    self.status.frame = NSMakeRect(16, 14, 1168, 26);
    self.status.autoresizingMask = NSViewWidthSizable;
    [content addSubview:self.status];
    self.sidebar = [[SCBundleSidebarView alloc] initWithFrame:NSMakeRect(16, 50, 210, 710)];
    self.sidebar.autoresizingMask = NSViewHeightSizable;
    self.sidebar.delegate = self;
    [content addSubview:self.sidebar];
    self.grid = [[SCCalendarGridView alloc] initWithFrame:NSMakeRect(242, 50, 942, 710)];
    self.grid.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.grid.delegate = self;
    self.grid.undoManager = [NSUndoManager new];
    self.grid.weekOffset = 1;
    self.grid.showOnlyRemainingDays = NO;
    [content addSubview:self.grid];
    [self reset:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"Fence QA ready pid=%d window=%ld", getpid(), (long)self.window.windowNumber);
}
- (void)reset:(id)sender {
    SCBlockBundle *allow = [SCBlockBundle bundleWithName:@"Protected Allow" color:NSColor.systemBlueColor];
    allow.entries = [@[@"work.example.com"] mutableCopy];
    SCBlockBundle *block = [SCBlockBundle bundleWithName:@"Protected Block" color:NSColor.systemRedColor];
    block.policy = SCBundlePolicyBlock;
    block.entries = [@[@"social.example.com"] mutableCopy];
    SCBlockBundle *draft = [SCBlockBundle bundleWithName:@"New draft" color:NSColor.systemGreenColor];
    draft.entries = [@[@"draft.example.com"] mutableCopy];
    self.bundles = [@[allow, block, draft] mutableCopy];
    self.protectedIDs = [NSSet setWithObjects:allow.bundleID, block.bundleID, nil];
    self.schedules = [NSMutableDictionary dictionary];
    for (SCBlockBundle *bundle in self.bundles) {
        SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
        for (NSInteger day = 1; day <= 5; day++) {
            [schedule addAllowedWindow:[SCTimeRange rangeWithStart:@"09:00" end:@"12:00"] toDay:day];
            [schedule addAllowedWindow:[SCTimeRange rangeWithStart:@"14:00" end:@"17:00"] toDay:day];
        }
        self.schedules[bundle.bundleID] = schedule;
    }
    NSMutableDictionary *baseline = [NSMutableDictionary dictionary];
    for (NSString *key in self.schedules) baseline[key] = [self.schedules[key] copy];
    self.baseline = baseline;
    self.sidebar.selectedBundleID = draft.bundleID;
    self.grid.focusedBundleID = draft.bundleID;
    [self.grid.undoManager removeAllActions];
    [self reload];
    self.status.stringValue = @"Fixture reset. Focus New draft for unrestricted creation, move, resize and selection.";
}
- (void)modeChanged:(id)sender { [self reload]; }
- (void)reload {
    BOOL active = self.mode.selectedSegment == 0;
    self.grid.activeEditBaselineSchedules = nil;
    self.grid.isCommitted = active;
    self.grid.protectedBundleIDs = active ? self.protectedIDs : [NSSet set];
    self.grid.bundles = self.bundles;
    self.grid.schedules = self.schedules;
    self.grid.activeEditBaselineSchedules = active ? self.baseline : nil;
    self.sidebar.bundles = self.bundles;
    self.sidebar.schedules = self.schedules;
    self.sidebar.protectedBundleIDs = active ? self.protectedIDs : [NSSet set];
    self.sidebar.isCommitted = active;
    [self.sidebar reloadData];
    [self.grid reloadData];
}
- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didSelectBundle:(SCBlockBundle *)bundle {
    self.grid.focusedBundleID = bundle.bundleID;
    self.status.stringValue = bundle ? [@"Focused: " stringByAppendingString:bundle.name] : @"All-Up: Shift marquee does not select calendar entries.";
}
- (void)bundleSidebarDidRequestAddBundle:(SCBundleSidebarView *)sidebar {
    self.editor = [[SCBundleEditorController alloc] initForNewBundle];
    self.editor.delegate = self;
    [self.editor beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didRequestEditBundle:(SCBlockBundle *)bundle {
    self.editor = [[SCBundleEditorController alloc] initWithBundle:bundle];
    self.editor.isCommitted = self.mode.selectedSegment == 0 && [self.protectedIDs containsObject:bundle.bundleID];
    self.editor.delegate = self;
    [self.editor beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)calendarGrid:(SCCalendarGridView *)grid didUpdateSchedule:(SCWeeklySchedule *)schedule forBundleID:(NSString *)bundleID {
    self.schedules[bundleID] = schedule;
    self.sidebar.schedules = self.schedules;
    self.status.stringValue = [NSString stringWithFormat:@"In-memory schedule updated: %@", [grid bundleForID:bundleID].name];
}
- (void)calendarGridDidClickEmptyArea:(SCCalendarGridView *)grid { [self.sidebar clearSelection]; }
- (void)calendarGridDidAttemptInteractionWithoutFocus:(SCCalendarGridView *)grid { self.status.stringValue = @"Grid callback: select a bundle first."; }
- (void)calendarGridDidAttemptRestrictedEdit:(SCCalendarGridView *)grid { self.status.stringValue = @"Grid callback: restricted active edit."; }
- (void)calendarGrid:(SCCalendarGridView *)grid didRequestEditBundle:(SCBlockBundle *)bundle forDay:(SCDayOfWeek)day {
    [self bundleSidebar:self.sidebar didRequestEditBundle:bundle];
}
- (void)bundleEditor:(SCBundleEditorController *)editor didSaveBundle:(SCBlockBundle *)bundle {
    NSUInteger index = [self.bundles indexOfObjectPassingTest:^BOOL(SCBlockBundle *item, NSUInteger idx, BOOL *stop) {
        return [item.bundleID isEqualToString:bundle.bundleID];
    }];
    if (index == NSNotFound) {
        [self.bundles addObject:bundle];
        self.schedules[bundle.bundleID] = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
    } else self.bundles[index] = bundle;
    [self reload];
    self.status.stringValue = @"Editor Save reached fixture delegate; no persistence or admission attempted.";
}
- (void)bundleEditorDidCancel:(SCBundleEditorController *)editor { self.status.stringValue = @"Editor canceled."; }
- (void)bundleEditor:(SCBundleEditorController *)editor didDeleteBundle:(SCBlockBundle *)bundle {
    [self.bundles removeObject:[self.sidebar bundleForID:bundle.bundleID]];
    [self.schedules removeObjectForKey:bundle.bundleID];
    self.grid.focusedBundleID = nil;
    self.sidebar.selectedBundleID = nil;
    [self reload];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

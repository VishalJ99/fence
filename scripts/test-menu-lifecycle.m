// PER-444: isolated regression harness for the real status-menu controller.
// No Fence app launch, status-bar item, defaults, Keychain, helper or network.
// All application dependencies below are inert test implementations. AppKit's
// real NSMenu/NSMenuItem are used; delegate callbacks are invoked explicitly.
// From the repository root:
//   xcrun clang -fobjc-arc -fmodules -Wno-incomplete-implementation \
//     -Wno-objc-property-implementation -Wno-nullability-completeness \
//     -Wno-arc-retain-cycles -I. -ICommon -ICommon/Utility \
//     -I'Block Management' -F. -framework Cocoa \
//     scripts/test-menu-lifecycle.m -o /tmp/fence-menu-lifecycle-test
//   LLVM_PROFILE_FILE=/tmp/fence-menu-lifecycle-%p.profraw /tmp/fence-menu-lifecycle-test
// Optional negative control: compile with -DFENCE_MENU_LIFECYCLE_NEGATIVE_CONTROL.
// It reintroduces the old will-open rebuild and must fail at removeAllItems.

#import "../SCMenuBarController.m"

static BOOL recurring = YES;
static BOOL protectedHours = NO;
static BOOL mutationPending = NO;
static NSDate *breakEnd;
static NSUInteger beginRequests;
static NSUInteger endRequests;
static NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

NSNotificationName const SCScheduleManagerDidChangeNotification = @"FenceMenuHarnessScheduleChanged";

#define TEST_SINGLETON(method) \
+ (instancetype)method { static id instance; if (!instance) instance = [self new]; return instance; }

@implementation SCScheduleManager
TEST_SINGLETON(sharedManager)
- (BOOL)isCommitted { return recurring; }
- (BOOL)hasRecurringCommitment { return recurring; }
- (NSArray *)bundles { return @[]; }
- (NSDate *)recurringCommitmentLockEndDate { return nil; }
- (BOOL)hasActiveTimedBreak { return [breakEnd timeIntervalSinceNow] > 0; }
- (NSDate *)activeTimedBreakEndDate { return breakEnd; }
- (BOOL)protectedHoursActiveNow { return protectedHours; }
- (BOOL)timedBreakMutationInFlight { return mutationPending; }
- (NSInteger)breakCreditsRemainingToday { return 3; }
- (BOOL)canBeginTimedBreak {
    return recurring && !self.hasActiveTimedBreak && !protectedHours && !mutationPending;
}
- (void)beginTimedBreakForMinutes:(NSInteger)minutes completion:(void (^)(BOOL, NSError *))completion {
    beginRequests++;
}
- (void)endTimedBreakWithCompletion:(void (^)(BOOL, NSError *))completion { endRequests++; }
@end

@implementation SCSettings
TEST_SINGLETON(sharedSettings)
- (BOOL)boolForKey:(NSString *)key { return NO; }
- (id)valueForKey:(NSString *)key { return @NO; }
@end

@implementation SCLicenseManager
TEST_SINGLETON(sharedManager)
- (SCLicenseStatus)currentStatus { return SCLicenseStatusValid; }
@end

@implementation SCSentry
+ (BOOL)errorReportingEnabled { return NO; }
@end

@implementation SCCountdownWarningController
- (void)hideWarning {}
@end
@implementation SCLicenseWindowController
@end
@implementation SCTestBlockWindowController
@end
@implementation SCMiscUtilities
@end
@implementation SCUIUtilities
@end

@interface GuardedMenu : NSMenu
@property BOOL forbidStructureChanges;
@property NSUInteger rebuilds;
@end
@implementation GuardedMenu
- (void)removeAllItems {
    Check(!self.forbidStructureChanges, @"removeAllItems while tracking/in close callback");
    self.rebuilds++;
    [super removeAllItems];
}
- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index {
    Check(!self.forbidStructureChanges, @"insertItem while tracking/in close callback");
    [super insertItem:item atIndex:index];
}
- (void)removeItemAtIndex:(NSInteger)index {
    Check(!self.forbidStructureChanges, @"removeItem while tracking/in close callback");
    [super removeItemAtIndex:index];
}
@end

@interface FakeStatusItem : NSObject
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, readonly) NSStatusBarButton *button;
@property NSUInteger menuAssignments;
@end
@implementation FakeStatusItem
- (NSStatusBarButton *)button { return nil; }
- (void)setMenu:(NSMenu *)menu { _menu = menu; self.menuAssignments++; }
@end

@interface HarnessController : SCMenuBarController
@end
@implementation HarnessController
- (void)refreshCountdownWarning {} // Keep window/timer warnings outside this test.
#ifdef FENCE_MENU_LIFECYCLE_NEGATIVE_CONTROL
- (void)menuWillOpen:(NSMenu *)menu {
    [self populateMenu:menu];
    [super menuWillOpen:menu];
}
#endif
@end

static NSArray *MenuSnapshot(NSMenu *menu, BOOL includeContent) {
    NSMutableArray *snapshot = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        [snapshot addObject:@[
            [NSValue valueWithNonretainedObject:item],
            NSStringFromSelector(item.action) ?: @"",
            [NSValue valueWithNonretainedObject:item.submenu],
            item.submenu ? MenuSnapshot(item.submenu, includeContent) : @[],
            includeContent ? item.title : @"",
            includeContent ? item.attributedTitle.string ?: @"" : @"",
            includeContent ? @(item.enabled) : @NO,
        ]];
    }
    return snapshot;
}

static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Check(drained, @"deferred close refresh ran");
}

static void Open(HarnessController *controller, GuardedMenu *menu) {
    [controller menuNeedsUpdate:menu];
    NSArray *before = MenuSnapshot(menu, YES);
    menu.forbidStructureChanges = YES;
    [controller menuWillOpen:menu];
    Check([before isEqual:MenuSnapshot(menu, YES)], @"menuWillOpen changed items");
    Check(controller.menuIsTracking, @"explicit tracking state entered");
}

static void Close(HarnessController *controller, GuardedMenu *menu) {
    NSArray *before = MenuSnapshot(menu, YES);
    [controller menuDidClose:menu];
    Check([before isEqual:MenuSnapshot(menu, YES)], @"menuDidClose changed items");
    Check(controller.breakCountdownTimer == nil, @"close invalidated timer");
    Check(controller.menuCloseRefreshScheduled, @"close refresh deferred");
    menu.forbidStructureChanges = NO;
    DrainMainQueue();
    Check(!controller.menuCloseRefreshScheduled, @"deferred guard cleared");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        HarnessController *controller = [HarnessController new];
        GuardedMenu *menu = [GuardedMenu new];
        FakeStatusItem *statusItem = [FakeStatusItem new];
        controller.statusItem = (NSStatusItem *)statusItem;
        [controller populateMenu:menu];
        statusItem.menu = menu;

        // No break row/timer must never be interpreted as a closed menu.
        recurring = NO;
        Open(controller, menu);
        Check(controller.breakCountdownTimer == nil, @"uncommitted menu has no countdown timer");
        NSArray *identity = MenuSnapshot(menu, NO);
        [controller timerFired:nil];
        [controller menuNeedsUpdate:menu];
        Check([identity isEqual:MenuSnapshot(menu, NO)], @"no-break tracking structure preserved");
        Close(controller, menu);

        // Take Break submenu eligibility updates in place; AppKit cannot
        // auto-enable stale durations after Protected Hours begin.
        recurring = YES;
        Open(controller, menu);
        NSMenuItem *takeAction = controller.timedBreakActionItem;
        NSMenu *durations = takeAction.submenu;
        Check(durations.numberOfItems == 3 && takeAction.enabled, @"eligible break submenu built");
        identity = MenuSnapshot(menu, NO);
        protectedHours = YES;
        [controller breakCountdownTimerFired:controller.breakCountdownTimer];
        [menu update];
        [durations update];
        Check(!takeAction.enabled, @"take-break stays disabled after menu validation");
        for (NSMenuItem *duration in durations.itemArray) {
            Check(!duration.enabled, @"duration stays disabled after submenu validation");
            [controller beginTimedBreakClicked:duration];
        }
        Check(beginRequests == 0, @"stale duration actions cannot request a break");
        Check([identity isEqual:MenuSnapshot(menu, NO)], @"submenu identities preserved");
        protectedHours = NO;
        [controller timerFired:nil];
        Check(takeAction.enabled, @"eligible existing submenu restored in place");
        Close(controller, menu);

        // Active-break countdown, Protected Hours, expiry and the 15-second
        // update all preserve the tracked menu. Expiry must not clear tracking.
        breakEnd = [NSDate dateWithTimeIntervalSinceNow:125];
        Open(controller, menu);
        NSMenuItem *breakRow = controller.activeBreakStatusItem;
        NSMenuItem *endAction = controller.timedBreakActionItem;
        Check([breakRow.title containsString:@"2:05"], @"live break countdown rendered");
        identity = MenuSnapshot(menu, NO);
        NSTimer *firstTimer = controller.breakCountdownTimer;
        NSArray *before = MenuSnapshot(menu, YES);
        [controller menuWillOpen:menu];
        Check(!firstTimer.valid && controller.breakCountdownTimer.valid, @"repeated open leaves one timer");
        Check([before isEqual:MenuSnapshot(menu, YES)], @"repeated open cannot alter item properties");
        protectedHours = YES;
        [controller breakCountdownTimerFired:controller.breakCountdownTimer];
        Check([breakRow.title containsString:@"Protected Hours"], @"protected break state updated in place");
        Check([endAction.title isEqual:@"End Paused Break"], @"protected break end action updated");
        protectedHours = NO;
        [controller breakCountdownTimerFired:controller.breakCountdownTimer];
        Check([breakRow.title containsString:@"Break active"], @"break countdown resumes in place");
        breakEnd = [NSDate dateWithTimeIntervalSinceNow:-1];
        [controller breakCountdownTimerFired:controller.breakCountdownTimer];
        Check(controller.menuIsTracking, @"break expiry retains explicit tracking state");
        Check([breakRow.title isEqual:@"● Break ended"], @"expired break row is truthful");
        [controller timerFired:nil];
        [menu update];
        Check(!endAction.enabled, @"expired End Break remains disabled after validation");
        [controller endTimedBreakClicked:endAction];
        Check(endRequests == 0, @"stale end action cannot send a helper request");
        Check([identity isEqual:MenuSnapshot(menu, NO)], @"expiry does not rebuild tracked menu");
        Close(controller, menu);
        Check(controller.timedBreakActionItem.submenu.numberOfItems == 3, @"closed menu rebuilt as Take Break");

        // A pending placeholder cannot gain an action/submenu during tracking.
        mutationPending = YES;
        Open(controller, menu);
        NSMenuItem *pendingAction = controller.timedBreakActionItem;
        identity = MenuSnapshot(menu, NO);
        mutationPending = NO;
        breakEnd = [NSDate dateWithTimeIntervalSinceNow:300];
        [controller updateStatus];
        Check(!pendingAction.enabled && pendingAction.action == nil && pendingAction.submenu == nil,
              @"resolved pending row is disabled until a safe rebuild");
        Check([identity isEqual:MenuSnapshot(menu, NO)], @"pending resolution preserves structure");

        // Rapid reopen before the deferred close block must protect the new
        // tracking session, and updates in the close-deferral gap cannot build.
        [controller menuDidClose:menu];
        NSUInteger rebuilds = menu.rebuilds;
        [controller updateStatus];
        Check(menu.rebuilds == rebuilds, @"close-deferral gap cannot rebuild");
        [controller menuWillOpen:menu];
        DrainMainQueue();
        Check(menu.rebuilds == rebuilds && controller.menuIsTracking,
              @"old deferred close does not rebuild reopened menu");
        Close(controller, menu);
        Check(controller.timedBreakActionItem.action == @selector(endTimedBreakClicked:),
              @"safe close rebuild installs current End Break action");

        Check(controller.statusMenu == menu && statusItem.menu == menu && statusItem.menuAssignments == 1,
              @"status menu identity never replaced");
        Check(beginRequests == 0 && endRequests == 0, @"no enforcement mutations occurred");
        printf("PASS: %lu menu lifecycle checks (isolated real-controller/AppKit harness)\n", (unsigned long)checks);
    }
    return 0;
}

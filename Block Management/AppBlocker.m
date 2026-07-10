//
//  AppBlocker.m
//  SelfControl
//
//  Monitors running applications and terminates blocked apps.
//  Uses low-level libproc APIs to work in daemon context (no NSWorkspace).
//

#import "AppBlocker.h"
#import "SCSentry.h"
#import "SCDebugUtilities.h"
#import <libproc.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>

// Poll interval in milliseconds
static const uint64_t APP_BLOCK_POLL_INTERVAL_MS = 500;
static const uint64_t APP_BLOCK_POLL_LEEWAY_MS = 50;
static const useconds_t APP_BLOCK_EXIT_POLL_INTERVAL_US = 20000;
static const NSUInteger APP_BLOCK_TERM_POLL_ATTEMPTS = 13;
static const NSUInteger APP_BLOCK_KILL_POLL_ATTEMPTS = 5;

/// Returns NO once the original executable is no longer running at this PID.
/// Comparing the path avoids treating a rapidly reused PID as the process we
/// attempted to terminate. This helper intentionally never records the path.
static BOOL SCBlockedProcessIsStillRunning(pid_t pid, NSString* expectedExecutablePath) {
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    int pathLen = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if (pathLen <= 0) return NO;

    NSString* currentPath = [[NSString alloc] initWithBytes:pathBuffer
                                                     length:(NSUInteger)pathLen
                                                   encoding:NSUTF8StringEncoding];
    return currentPath != nil && [currentPath isEqualToString:expectedExecutablePath];
}

static BOOL SCWaitForBlockedProcessExit(pid_t pid,
                                        NSString* expectedExecutablePath,
                                        NSUInteger attempts) {
    for (NSUInteger attempt = 0; attempt < attempts; attempt++) {
        if (!SCBlockedProcessIsStillRunning(pid, expectedExecutablePath)) return YES;
        usleep(APP_BLOCK_EXIT_POLL_INTERVAL_US);
    }
    return !SCBlockedProcessIsStillRunning(pid, expectedExecutablePath);
}

static NSDictionary<NSString*, NSNumber*>* SCEmptyAppBlockerScanResult(void) {
    return @{
        @"attempt_count": @0,
        @"terminate_success_count": @0,
        @"force_kill_count": @0,
        @"failure_count": @0,
        @"scan_error_code": @0,
        @"kill_error_code": @0,
    };
}

@interface AppBlocker ()

@property (nonatomic, strong) NSMutableSet<NSString*>* mutableBlockedBundleIDs;
@property (nonatomic, strong) dispatch_source_t monitorTimer;
@property (nonatomic, strong) NSLock* blockLock;
@property (nonatomic, readwrite) BOOL isMonitoring;

@end

@implementation AppBlocker

+ (instancetype)sharedBlocker {
    static AppBlocker* shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AppBlocker alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _mutableBlockedBundleIDs = [NSMutableSet set];
        _blockLock = [[NSLock alloc] init];
        _isMonitoring = NO;
    }
    return self;
}

- (NSSet<NSString*>*)blockedBundleIDs {
    [self.blockLock lock];
    NSSet* copy = [self.mutableBlockedBundleIDs copy];
    [self.blockLock unlock];
    return copy;
}

- (void)addBlockedApp:(NSString*)bundleID {
    if (!bundleID || bundleID.length == 0) return;

    [self.blockLock lock];
    [self.mutableBlockedBundleIDs addObject:bundleID];
    [self.blockLock unlock];

    NSLog(@"AppBlocker: Added blocked app (blockedCount=%lu)",
          (unsigned long)self.blockedBundleIDs.count);
}

- (void)removeBlockedApp:(NSString*)bundleID {
    if (!bundleID) return;

    [self.blockLock lock];
    [self.mutableBlockedBundleIDs removeObject:bundleID];
    [self.blockLock unlock];

    NSLog(@"AppBlocker: Removed blocked app (blockedCount=%lu)",
          (unsigned long)self.blockedBundleIDs.count);
}

- (void)clearAllBlockedApps {
    [self.blockLock lock];
    [self.mutableBlockedBundleIDs removeAllObjects];
    [self.blockLock unlock];

    NSLog(@"AppBlocker: Cleared all blocked apps");
}

- (NSDictionary<NSString*, NSNumber*>*)startMonitoring {
    if (self.isMonitoring) return SCEmptyAppBlockerScanResult();

    // First kill any currently running blocked apps
    NSDictionary<NSString*, NSNumber*>* initialScanResult = [self findAndKillBlockedAppsResult];

    // Create timer on global queue
    self.monitorTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
    );

    dispatch_source_set_timer(
        self.monitorTimer,
        dispatch_time(DISPATCH_TIME_NOW, APP_BLOCK_POLL_INTERVAL_MS * NSEC_PER_MSEC),
        APP_BLOCK_POLL_INTERVAL_MS * NSEC_PER_MSEC,
        APP_BLOCK_POLL_LEEWAY_MS * NSEC_PER_MSEC
    );

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.monitorTimer, ^{
        [weakSelf findAndKillBlockedAppsResult];
    });

    dispatch_resume(self.monitorTimer);
    self.isMonitoring = YES;

    NSLog(@"AppBlocker: Started monitoring with %lu blocked apps",
          (unsigned long)self.blockedBundleIDs.count);
    return initialScanResult;
}

- (void)stopMonitoring {
    if (!self.isMonitoring) return;

    if (self.monitorTimer) {
        dispatch_source_cancel(self.monitorTimer);
        self.monitorTimer = nil;
    }

    self.isMonitoring = NO;
    NSLog(@"AppBlocker: Stopped monitoring");
}

/// Extract bundle identifier from an executable path by finding the .app bundle
- (NSString*)bundleIDFromExecutablePath:(NSString*)execPath {
    if (!execPath || execPath.length == 0) return nil;

    // Walk up directories to find .app bundle
    NSString* path = execPath;
    while (path.length > 1) {
        if ([path hasSuffix:@".app"]) {
            // Found app bundle, read Info.plist
            NSString* plistPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
            NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSString* bundleID = info[@"CFBundleIdentifier"];
            // Debug: log only if this looks like a user app (not system)
            if (bundleID && ![path hasPrefix:@"/System"] && ![path hasPrefix:@"/usr"]) {
                // NSLog(@"AppBlocker: Path %@ -> bundleID %@", path, bundleID);
            }
            return bundleID;
        }
        path = [path stringByDeletingLastPathComponent];
    }
    return nil;
}

/// Find and kill blocked apps using daemon-safe libproc APIs (no NSWorkspace)
- (NSDictionary<NSString*, NSNumber*>*)performBlockedAppScanWithKilledPIDs:(NSMutableArray<NSNumber*>*)killedPIDs {
    NSUInteger attemptCount = 0;
    NSUInteger terminateSuccessCount = 0;
    NSUInteger forceKillCount = 0;
    NSUInteger failureCount = 0;
    NSInteger scanErrorCode = 0;
    NSInteger killErrorCode = 0;

#ifdef DEBUG
    // Check debug override - if blocking is disabled, don't kill any apps
    if ([SCDebugUtilities isDebugBlockingDisabled]) {
        return SCEmptyAppBlockerScanResult();
    }
#endif

    [self.blockLock lock];
    NSSet<NSString*>* currentBlockedIDs = [self.mutableBlockedBundleIDs copy];
    [self.blockLock unlock];

    if (currentBlockedIDs.count == 0) {
        return SCEmptyAppBlockerScanResult();
    }

    // Get number of processes
    int requiredBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (requiredBytes <= 0) {
        NSLog(@"AppBlocker: Failed to get process count");
        scanErrorCode = errno != 0 ? errno : EIO;
        return @{
            @"attempt_count": @0,
            @"terminate_success_count": @0,
            @"force_kill_count": @0,
            @"failure_count": @0,
            @"scan_error_code": @(scanErrorCode),
            @"kill_error_code": @0,
        };
    }

    // Allocate buffer for PIDs
    pid_t* pids = (pid_t*)malloc((size_t)requiredBytes);
    if (!pids) {
        NSLog(@"AppBlocker: Failed to allocate PID buffer");
        return @{
            @"attempt_count": @0,
            @"terminate_success_count": @0,
            @"force_kill_count": @0,
            @"failure_count": @0,
            @"scan_error_code": @(ENOMEM),
            @"kill_error_code": @0,
        };
    }

    // Get actual list of PIDs
    int actualBytes = proc_listpids(PROC_ALL_PIDS, 0, pids, requiredBytes);
    if (actualBytes <= 0) {
        scanErrorCode = errno != 0 ? errno : EIO;
        free(pids);
        return @{
            @"attempt_count": @0,
            @"terminate_success_count": @0,
            @"force_kill_count": @0,
            @"failure_count": @0,
            @"scan_error_code": @(scanErrorCode),
            @"kill_error_code": @0,
        };
    }
    int actualCount = actualBytes / (int)sizeof(pid_t);

    for (int i = 0; i < actualCount; i++) {
        pid_t pid = pids[i];
        if (pid == 0) continue;

        // Get executable path for this process
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        int pathLen = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));

        if (pathLen <= 0) continue;

        NSString* execPath = [[NSString alloc] initWithBytes:pathBuffer
                                                      length:(NSUInteger)pathLen
                                                    encoding:NSUTF8StringEncoding];

        // Get bundle ID from executable path
        NSString* bundleID = [self bundleIDFromExecutablePath:execPath];
        if (!bundleID) continue;

        // Check if this app should be blocked
        if ([currentBlockedIDs containsObject:bundleID]) {
            attemptCount += 1;
            BOOL exited = NO;
            int termResult = kill(pid, SIGTERM);
            int termError = termResult == 0 ? 0 : errno;

            if (termResult == 0) {
                exited = SCWaitForBlockedProcessExit(pid, execPath, APP_BLOCK_TERM_POLL_ATTEMPTS);
            } else if (termError == ESRCH) {
                exited = YES;
            }

            if (!exited) {
                // A successful kill(2) call only means the signal was queued.
                // Escalate and verify disappearance before reporting success.
                int forceResult = kill(pid, SIGKILL);
                int forceError = forceResult == 0 ? 0 : errno;
                forceKillCount += 1;
                if (forceResult == 0) {
                    exited = SCWaitForBlockedProcessExit(pid, execPath, APP_BLOCK_KILL_POLL_ATTEMPTS);
                } else if (forceError == ESRCH) {
                    exited = YES;
                } else {
                    killErrorCode = forceError;
                }
            }

            if (exited) {
                terminateSuccessCount += 1;
                if (killedPIDs) [killedPIDs addObject:@(pid)];
                NSLog(@"AppBlocker: Verified termination of a blocked app");
                [SCSentry addBreadcrumb:@"Blocked app termination verified" category:@"appblocker"];
            } else {
                failureCount += 1;
                if (killErrorCode == 0) {
                    killErrorCode = termError != 0 ? termError : EBUSY;
                }
                NSLog(@"AppBlocker: Blocked app remained running (errno=%ld)", (long)killErrorCode);
            }
        }
    }

    free(pids);
    return @{
        @"attempt_count": @(attemptCount),
        @"terminate_success_count": @(terminateSuccessCount),
        @"force_kill_count": @(forceKillCount),
        @"failure_count": @(failureCount),
        @"scan_error_code": @(scanErrorCode),
        @"kill_error_code": @(killErrorCode),
    };
}

- (NSArray<NSNumber*>*)findAndKillBlockedApps {
    NSMutableArray<NSNumber*>* killedPIDs = [NSMutableArray array];
    [self performBlockedAppScanWithKilledPIDs:killedPIDs];
    return killedPIDs;
}

- (NSDictionary<NSString*, NSNumber*>*)findAndKillBlockedAppsResult {
    return [self performBlockedAppScanWithKilledPIDs:nil];
}

- (void)dealloc {
    [self stopMonitoring];
}

@end

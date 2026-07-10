//
//  SCDaemon.m
//  SelfControl
//
//  Created by Charlie Stigler on 5/28/20.
//

#import "SCDaemon.h"
#import "SCDaemonProtocol.h"
#import "SCDaemonXPC.h"
#import "SCDaemonBlockMethods.h"
#import "SCFileWatcher.h"
#import "SCScheduleManager.h"
#import "SCSettings.h"
#import "SCMiscUtilities.h"
#import "SCTelemetrySpool.h"
#import <bsm/libbsm.h>
#include <pwd.h>
#include <math.h>

static NSString* serviceName = @"org.eyebeam.selfcontrold";
float const INACTIVITY_LIMIT_SECS = 60 * 2; // 2 minutes

static void SCDaemonLogError(NSString* message, NSError* error) {
    NSLog(@"SCDaemon: %@ (domain=%@ code=%ld)",
          message,
          error.domain ?: @"unknown",
          (long)error.code);
}

static NSString *SCDaemonSafeClientVersion(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 || [value length] > 64) {
        return @"unknown";
    }
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._+-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? value : @"unknown";
}

static BOOL SCDaemonCodeSatisfiesRequirement(SecCodeRef code, CFStringRef requirementText) {
    if (code == NULL || requirementText == NULL) return NO;
    SecRequirementRef requirement = NULL;
    OSStatus createStatus = SecRequirementCreateWithString(requirementText, kSecCSDefaultFlags, &requirement);
    if (createStatus != errSecSuccess || requirement == NULL) return NO;
    OSStatus validityStatus = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(requirement);
    return validityStatus == errSecSuccess;
}

static void SCDaemonRecordXPCConnectionRejection(uid_t uid,
                                                 NSString *stage,
                                                 OSStatus status,
                                                 SecCodeRef _Nullable guest) {
    if (uid == 0) return;

    NSString *clientID = @"unknown";
    NSString *clientVersion = @"unknown";
    if (guest != NULL) {
        CFDictionaryRef signingInformation = NULL;
        if (SecCodeCopySigningInformation(guest, kSecCSSigningInformation, &signingInformation) == errSecSuccess &&
            signingInformation != NULL) {
            NSDictionary *info = CFBridgingRelease(signingInformation);
            NSString *identifier = [info[(__bridge id)kSecCodeInfoIdentifier] isKindOfClass:[NSString class]]
                ? info[(__bridge id)kSecCodeInfoIdentifier] : nil;
            if ([identifier isEqualToString:@"org.eyebeam.Fence"]) clientID = @"app";
            if ([identifier isEqualToString:@"org.eyebeam.selfcontrol-cli"]) clientID = @"cli";
            NSDictionary *plist = [info[(__bridge id)kSecCodeInfoPList] isKindOfClass:[NSDictionary class]]
                ? info[(__bridge id)kSecCodeInfoPList] : nil;
            clientVersion = SCDaemonSafeClientVersion(plist[@"CFBundleVersion"]);
        }
    }

    static NSMutableSet<NSString *> *recordedClients;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ recordedClients = [NSMutableSet set]; });
    NSString *dedupKey = [NSString stringWithFormat:@"%u:%@", uid, clientID];
    @synchronized (recordedClients) {
        if ([recordedClients containsObject:dedupKey]) return;
        [recordedClients addObject:dedupKey];
    }

    BOOL identifierOK = SCDaemonCodeSatisfiesRequirement(
        guest, CFSTR("anchor apple generic and (identifier \"org.eyebeam.Fence\" or identifier \"org.eyebeam.selfcontrol-cli\")"));
    BOOL teamOK = SCDaemonCodeSatisfiesRequirement(
        guest, CFSTR("anchor apple generic and certificate leaf[subject.OU] = L5YX8CH3F5"));
    BOOL versionOK = SCDaemonCodeSatisfiesRequirement(
        guest, CFSTR("anchor apple generic and info [CFBundleVersion] >= \"407\""));

    SCTelemetrySpool *spool = [[SCTelemetrySpool alloc] init];
    NSError *spoolError = nil;
    [spool appendEventName:@"xpc.connection_rejected"
                     level:SCTelemetryEventLevelError
                    fields:@{
        @"stage": stage,
        @"client_id": clientID,
        @"identifier_ok": @(identifierOK),
        @"team_ok": @(teamOK),
        @"version_ok": @(versionOK),
        @"os_status": @(status),
        @"client_version": clientVersion,
    }
                    origin:SCTelemetryOriginDaemon
                    forUID:uid
                     error:&spoolError];
    if (spoolError != nil) {
        NSLog(@"SCDaemon: XPC rejection telemetry skipped (domain=%@ code=%ld)",
              spoolError.domain, (long)spoolError.code);
    }
}

static NSUInteger SCDaemonScheduleMinutesLateBucket(NSDate *approvedStartDate) {
    if (![approvedStartDate isKindOfClass:[NSDate class]]) return 0;
    NSUInteger minutes = (NSUInteger)floor(MAX(0, -[approvedStartDate timeIntervalSinceNow]) / 60.0);
    if (minutes == 0) return 0;
    if (minutes < 5) return 1;
    if (minutes < 15) return 5;
    if (minutes < 60) return 15;
    if (minutes < 360) return 60;
    if (minutes < 1440) return 360;
    return 1440;
}

static NSUInteger SCDaemonOwnedApprovalCount(NSDictionary *approvedSchedules, uid_t uid) {
    NSUInteger count = 0;
    for (id candidate in approvedSchedules.allValues) {
        NSDictionary *schedule = [candidate isKindOfClass:[NSDictionary class]] ? candidate : nil;
        NSNumber *owner = schedule[@"controllingUID"];
        if ([owner isKindOfClass:[NSNumber class]] && owner.unsignedIntValue == uid) count += 1;
    }
    return count;
}

@interface NSXPCConnection(PrivateAuditToken)

// This property exists, but it's private. Make it available:
@property (nonatomic, readonly) audit_token_t auditToken;

@end

@interface SCDaemon () <NSXPCListenerDelegate>

@property (nonatomic, strong, readwrite) NSXPCListener* listener;
@property (strong, readwrite) NSTimer* checkupTimer;
@property (strong, readwrite) NSTimer* inactivityTimer;
@property (strong, readwrite) NSTimer* scheduleCheckTimer;
@property (nonatomic, strong, readwrite) NSDate* lastActivityDate;

@property (nonatomic, strong) SCFileWatcher* hostsFileWatcher;
@property (nonatomic, strong) id settingsLoadFailureObserver;

- (void)recordSettingsLoadFailure:(NSDictionary<NSString *, id> *)fields;

@end

@implementation SCDaemon

+ (instancetype)sharedDaemon {
    static SCDaemon* daemon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        daemon = [SCDaemon new];
    });
    return daemon;
}

- (id) init {
    _listener = [[NSXPCListener alloc] initWithMachServiceName: serviceName];
    _listener.delegate = self;
    
    return self;
}

- (void)start {
    if (self.settingsLoadFailureObserver == nil) {
        __weak typeof(self) weakSelf = self;
        self.settingsLoadFailureObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:SCSettingsLoadFailedNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *notification) {
            [weakSelf recordSettingsLoadFailure:notification.userInfo];
        }];
    }
    [self.listener resume];

    // if there's any evidence of a block (i.e. an official one running,
    // OR just block remnants remaining in hosts), we should start
    // running checkup regularly so the block gets found/removed
    // at the proper time.
    // we do NOT run checkup if there's no block, because it can result
    // in the daemon actually unloading itself before the app has a chance
    // to start the block
    if ([SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities blockRulesFoundOnSystem]) {
        [self startCheckupTimer];
    }

    // Check for missed scheduled blocks (e.g., after reboot during scheduled window)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self startMissedBlockIfNeeded];
    });

    // Periodic check for scheduled blocks (handles launchd permission bypass, sleep/wake)
    NSLog(@"SCDaemon: Starting schedule check timer (every 1 minute)");
    self.scheduleCheckTimer = [NSTimer scheduledTimerWithTimeInterval: 60 // 1 minute
                                                              repeats: YES
                                                                block:^(NSTimer * _Nonnull timer) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self startMissedBlockIfNeeded];
        });
    }];

    [self startInactivityTimer];
    [self resetInactivityTimer];

    self.hostsFileWatcher = [SCFileWatcher watcherWithFile: @"/etc/hosts" block:^(NSError * _Nonnull error) {
        if ([SCBlockUtilities anyBlockIsRunning]) {
            [SCDaemonBlockMethods checkBlockIntegrity];
        }
    }];
}

- (void)startCheckupTimer {
    // this method must always be called on the main thread, so the timer will work properly
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self startCheckupTimer];
        });
        return;
    }

    // if the timer's already running, don't stress it!
    if (self.checkupTimer != nil) {
        return;
    }
    
    self.checkupTimer = [NSTimer scheduledTimerWithTimeInterval: 1 repeats: YES block:^(NSTimer * _Nonnull timer) {
       [SCDaemonBlockMethods checkupBlock];
    }];

    // run the first checkup immediately!
    [SCDaemonBlockMethods checkupBlock];
}
- (void)stopCheckupTimer {
    if (self.checkupTimer == nil) {
        return;
    }
    
    [self.checkupTimer invalidate];
    self.checkupTimer = nil;
}


- (void)startInactivityTimer {
    // Daemon now runs permanently after first install for:
    // 1. Scheduled blocks (no password prompts for each segment)
    // 2. Jailbreak resistance (KeepAlive=true restarts if killed)
    // 3. Reboot persistence (RunAtLoad=true auto-starts)
    // Resource usage is negligible (~5-10MB, zero CPU when idle)
}
- (void)resetInactivityTimer {
    self.lastActivityDate = [NSDate date];
}

- (void)dealloc {
    if (self.settingsLoadFailureObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.settingsLoadFailureObserver];
        self.settingsLoadFailureObserver = nil;
    }
    if (self.checkupTimer) {
        [self.checkupTimer invalidate];
        self.checkupTimer = nil;
    }
    if (self.inactivityTimer) {
        [self.inactivityTimer invalidate];
        self.inactivityTimer = nil;
    }
    if (self.hostsFileWatcher) {
        [self.hostsFileWatcher stopWatching];
        self.hostsFileWatcher = nil;
    }
}

- (void)recordSettingsLoadFailure:(NSDictionary<NSString *, id> *)fields {
    NSDictionary *safeFields = [SCSentry sanitizedTelemetryFields:fields
                                                     forEventName:@"daemon.settings_load_failed"];
    if (safeFields == nil) return;

    NSNumber *owner = [[SCSettings sharedSettings] valueForKey:@"ActiveBlockControllingUID"];
    uid_t telemetryUID = [owner isKindOfClass:[NSNumber class]] ? owner.unsignedIntValue : 0;
    if (telemetryUID == 0) telemetryUID = [SCMiscUtilities consoleUserUID];
    if (telemetryUID == 0) return;

    NSError *spoolError = nil;
    [[[SCTelemetrySpool alloc] init] appendEventName:@"daemon.settings_load_failed"
                                               level:SCTelemetryEventLevelError
                                              fields:safeFields
                                              origin:SCTelemetryOriginDaemon
                                              forUID:telemetryUID
                                               error:&spoolError];
    if (spoolError != nil) {
        SCDaemonLogError(@"Could not spool settings-load failure", spoolError);
    }
}

#pragma mark - Missed Block Recovery

/// Checks if we're inside a scheduled block window but no block is running.
/// If so, starts the block immediately. Called on daemon startup to recover
/// from missed launchd triggers (e.g., after reboot during scheduled block).
- (void)startMissedBlockIfNeeded {
    NSLog(@"SCDaemon: Checking for missed scheduled blocks...");

    // Don't check if a block is already running
    BOOL blockRunning = [SCBlockUtilities anyBlockIsRunning];
    if (blockRunning) {
        NSLog(@"SCDaemon: Block already running, skipping missed block check");
        return;
    }

    // ApprovedSchedules is root-owned and is the only authority for timing.
    // LaunchAgent plists live in the user's home directory and may be removed
    // or edited, so recovery must not use their dates to extend, shorten, or
    // suppress a committed block.

    SCSettings *settings = [SCSettings sharedSettings];
    NSDictionary *approvedSchedules = [settings valueForKey:@"ApprovedSchedules"];

    if (![approvedSchedules isKindOfClass:[NSDictionary class]] || approvedSchedules.count == 0) {
        NSLog(@"SCDaemon: No approved schedules found");
        return;
    }

    // Get console user's home directory to find launchd jobs
    uid_t consoleUID = [SCMiscUtilities consoleUserUID];

    // If no console user, try to get controllingUID from any approved schedule
    if (consoleUID == 0) {
        for (NSString *schedId in approvedSchedules) {
            NSDictionary *sched = approvedSchedules[schedId];
            NSNumber *ctrlUID = sched[@"controllingUID"];
            if (ctrlUID && [ctrlUID unsignedIntValue] != 0) {
                consoleUID = [ctrlUID unsignedIntValue];
                break;
            }
        }
    }

    if (consoleUID == 0) {
        NSLog(@"SCDaemon: No console user found and no controllingUID in ApprovedSchedules");
        return;
    }

    NSDate *now = [NSDate date];
    NSString *activeSegmentID = nil;
    NSDate *activeEndDate = nil;
    NSDate *activeStartDate = nil;
    NSUInteger inspectedScheduleCount = 0;
    NSUInteger expiredScheduleCount = 0;

    for (id candidateID in approvedSchedules) {
        if (![candidateID isKindOfClass:[NSString class]] ||
            [[NSUUID alloc] initWithUUIDString:candidateID] == nil) {
            continue;
        }
        NSDictionary *schedule = [approvedSchedules[candidateID] isKindOfClass:[NSDictionary class]]
            ? approvedSchedules[candidateID] : nil;
        if (schedule == nil) continue;
        inspectedScheduleCount += 1;

        NSNumber *owner = schedule[@"controllingUID"];
        NSDate *approvedStartDate = schedule[@"approvedStartDate"];
        NSDate *approvedEndDate = schedule[@"approvedEndDate"];
        NSArray *blocklist = schedule[@"blocklist"];
        NSDictionary *blockSettings = schedule[@"blockSettings"];
        if (!SCDaemonClientOwnsSchedule(consoleUID, owner) ||
            ![approvedStartDate isKindOfClass:[NSDate class]] ||
            ![approvedEndDate isKindOfClass:[NSDate class]] ||
            ![blocklist isKindOfClass:[NSArray class]] ||
            ![blockSettings isKindOfClass:[NSDictionary class]] ||
            [approvedEndDate compare:approvedStartDate] != NSOrderedDescending) {
            continue;
        }

        if ([approvedEndDate compare:now] != NSOrderedDescending) {
            expiredScheduleCount += 1;
            [self cleanupStaleScheduleWithID:candidateID controllingUID:consoleUID];
            continue;
        }
        if ([approvedStartDate compare:now] == NSOrderedDescending) continue;

        // If windows overlap, recover the segment that began most recently.
        if (activeStartDate == nil ||
            [approvedStartDate compare:activeStartDate] == NSOrderedDescending) {
            activeSegmentID = candidateID;
            activeStartDate = approvedStartDate;
            activeEndDate = approvedEndDate;
        }
    }

    if (!activeSegmentID) {
        NSLog(@"SCDaemon: No approved segment active (inspected=%lu expired=%lu)",
              (unsigned long)inspectedScheduleCount,
              (unsigned long)expiredScheduleCount);
        return;
    }

    NSLog(@"SCDaemon: Found missed block; starting approved segment");

    // Start the block using the approved schedule
    NSDictionary *schedule = approvedSchedules[activeSegmentID];
    NSArray *blocklist = schedule[@"blocklist"];
    BOOL isAllowlist = [schedule[@"isAllowlist"] boolValue];
    NSDictionary *blockSettings = schedule[@"blockSettings"];
    uid_t controllingUID = [schedule[@"controllingUID"] unsignedIntValue];

    NSLog(@"SCDaemon: Starting approved segment (entryCount=%lu)",
          (unsigned long)blocklist.count);

    [SCDaemonBlockMethods startBlockWithControllingUID:controllingUID
                                             blocklist:blocklist
                                           isAllowlist:isAllowlist
                                               endDate:activeEndDate
                                         blockSettings:blockSettings
                                         authorization:nil
                                                 reply:^(NSError *error) {
        if (error) {
            SCDaemonLogError(@"Failed to start approved segment", error);
            NSDictionary *fields = @{
                @"path": @"daemon_recovery",
                @"block_already_running": @([SCBlockUtilities anyBlockIsRunning]),
                @"minutes_late_bucket": @(SCDaemonScheduleMinutesLateBucket(activeStartDate)),
                @"approved_count": @(SCDaemonOwnedApprovalCount(approvedSchedules, controllingUID)),
                @"list_count": @(blocklist.count),
                @"error_code": @(error.code),
            };
            NSError *spoolError = nil;
            [[[SCTelemetrySpool alloc] init] appendEventName:@"schedule.exec_failed"
                                                       level:SCTelemetryEventLevelError
                                                      fields:fields
                                                      origin:SCTelemetryOriginDaemon
                                                      forUID:controllingUID
                                                       error:&spoolError];
            if (spoolError != nil) {
                SCDaemonLogError(@"Could not spool missed-schedule execution failure", spoolError);
            }
        } else {
            NSLog(@"SCDaemon: Successfully started approved segment");
        }
    }];
}

#pragma mark - Schedule Cleanup

/// Cleans up a stale schedule by removing it from ApprovedSchedules and deleting the launchd job.
/// Called when a job fires with an expired endDate.
- (void)cleanupStaleScheduleWithID:(NSString *)scheduleId {
    SCSettings *settings = [SCSettings sharedSettings];
    NSDictionary *approved = [settings valueForKey:@"ApprovedSchedules"];
    NSDictionary *schedule = [approved[scheduleId] isKindOfClass:[NSDictionary class]]
        ? approved[scheduleId] : nil;
    NSNumber *owner = schedule[@"controllingUID"];
    uid_t controllingUID = [owner isKindOfClass:[NSNumber class]] ? owner.unsignedIntValue : 0;
    if (controllingUID == 0) controllingUID = [SCMiscUtilities consoleUserUID];
    [self cleanupStaleScheduleWithID:scheduleId controllingUID:controllingUID];
}

- (void)cleanupStaleScheduleWithID:(NSString *)scheduleId controllingUID:(uid_t)controllingUID {
    NSLog(@"SCDaemon: Cleaning up stale schedule");

    // 1. Remove from ApprovedSchedules
    SCSettings *settings = [SCSettings sharedSettings];
    NSMutableDictionary *approved = [[settings valueForKey:@"ApprovedSchedules"] mutableCopy];
    NSDictionary *schedule = [approved[scheduleId] isKindOfClass:[NSDictionary class]]
        ? approved[scheduleId] : nil;
    NSNumber *storedOwner = schedule[@"controllingUID"];
    if ([storedOwner isKindOfClass:[NSNumber class]] && storedOwner.unsignedIntValue != controllingUID) {
        NSLog(@"SCDaemon: Refusing stale cleanup with an owner mismatch");
        return;
    }
    if (approved && approved[scheduleId]) {
        [approved removeObjectForKey:scheduleId];
        [settings setValue:approved forKey:@"ApprovedSchedules"];
        [settings synchronizeSettings];
        NSLog(@"SCDaemon: Removed stale schedule from approved schedules");
    }

    // 2. Find and remove launchd job plist
    if (controllingUID == 0) {
        NSLog(@"SCDaemon: No controlling user, skipping launchd cleanup");
        return;
    }

    struct passwd *pw = getpwuid(controllingUID);
    if (!pw) {
        NSLog(@"SCDaemon: Could not resolve controlling user home directory");
        return;
    }

    NSString *homeDir = [NSString stringWithUTF8String:pw->pw_dir];
    NSString *launchAgentsDir = [homeDir stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *pattern = [NSString stringWithFormat:@"org.eyebeam.selfcontrol.schedule.merged-%@.", scheduleId];

    for (NSString *file in [fm contentsOfDirectoryAtPath:launchAgentsDir error:nil]) {
        if ([file hasPrefix:pattern] && [file hasSuffix:@".plist"]) {
            NSString *fullPath = [launchAgentsDir stringByAppendingPathComponent:file];
            NSString *label = [file stringByDeletingPathExtension];

            // Unload from launchctl (run as console user)
            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
            task.arguments = @[@"bootout", [NSString stringWithFormat:@"gui/%d/%@", controllingUID, label]];
            [task launchAndReturnError:nil];
            [task waitUntilExit];

            // Delete plist file
            NSError *removeError = nil;
            if ([fm removeItemAtPath:fullPath error:&removeError]) {
                NSLog(@"SCDaemon: Deleted stale launchd job");
            } else {
                SCDaemonLogError(@"Failed to delete stale launchd job", removeError);
            }
        }
    }
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // There is a potential security issue / race condition with matching based on PID, so we use the (technically private) auditToken instead
    audit_token_t auditToken = newConnection.auditToken;
    uid_t clientUID = audit_token_to_euid(auditToken);
    NSDictionary* guestAttributes = @{
        (id)kSecGuestAttributeAudit: [NSData dataWithBytes: &auditToken length: sizeof(audit_token_t)]
    };
    SecCodeRef guest = NULL;
    OSStatus copyStatus = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef _Nullable)(guestAttributes), kSecCSDefaultFlags, &guest);
    if (copyStatus != errSecSuccess) {
        SCDaemonRecordXPCConnectionRejection(clientUID, @"guest_lookup", copyStatus, NULL);
        return NO;
    }
    
    SecRequirementRef isSelfControlApp = NULL;
    // versions before 4.0 didn't have hardened code signing, so aren't trustworthy to talk to the daemon
    // (plus the daemon didn't exist before 4.0 so there's really no reason they should want to run it!)
    OSStatus requirementStatus = SecRequirementCreateWithString(CFSTR("anchor apple generic and (identifier \"org.eyebeam.Fence\" or identifier \"org.eyebeam.selfcontrol-cli\") and info [CFBundleVersion] >= \"407\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate leaf[field.1.2.840.113635.100.6.1.12] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */) and certificate leaf[subject.OU] = L5YX8CH3F5"), kSecCSDefaultFlags, &isSelfControlApp);
    if (requirementStatus != errSecSuccess || isSelfControlApp == NULL) {
        SCDaemonRecordXPCConnectionRejection(clientUID, @"requirement_create", requirementStatus, guest);
        CFRelease(guest);
        return NO;
    }
    OSStatus clientValidityStatus = SecCodeCheckValidity(guest, kSecCSDefaultFlags, isSelfControlApp);

    if (clientValidityStatus) {
        SCDaemonRecordXPCConnectionRejection(clientUID, @"validity", clientValidityStatus, guest);
        CFRelease(guest);
        CFRelease(isSelfControlApp);
        return NO;
    }

    CFRelease(guest);
    CFRelease(isSelfControlApp);

    // The same immutable audit token used for signature validation is also the
    // authority for per-user telemetry isolation. No XPC argument can select
    // or impersonate a different UID.
    SCDaemonXPC* scdXPC = [[SCDaemonXPC alloc] initWithClientUID:clientUID];
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(SCDaemonProtocol)];
    newConnection.exportedObject = scdXPC;

    [newConnection resume];

    [SCSentry addBreadcrumb: @"Daemon accepted new connection" category: @"daemon"];

    return YES;
}

@end

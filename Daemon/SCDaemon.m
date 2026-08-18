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
#import "SCDaemonScheduler.h"
#import "SCFileWatcher.h"
#import "SCScheduleManager.h"
#import "SCSettings.h"
#import "SCMiscUtilities.h"
#import "SCTelemetrySpool.h"
#import <AppKit/AppKit.h>
#import <bsm/libbsm.h>
#include <pwd.h>

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

@interface NSXPCConnection(PrivateAuditToken)

// This property exists, but it's private. Make it available:
@property (nonatomic, readonly) audit_token_t auditToken;

@end

@interface SCDaemon () <NSXPCListenerDelegate>

@property (nonatomic, strong, readwrite) NSXPCListener* listener;
@property (strong, readwrite) NSTimer* checkupTimer;
@property (strong, readwrite) NSTimer* inactivityTimer;
@property (nonatomic, strong, readwrite) NSDate* lastActivityDate;
@property (nonatomic, strong) SCDaemonScheduler *scheduler;
@property (nonatomic, strong) id wakeObserver;
@property (nonatomic, strong) id sessionObserver;
@property (nonatomic, strong) id clockObserver;
@property (nonatomic, strong) id timezoneObserver;

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

    __weak typeof(self) weakSelf = self;
    _scheduler = [[SCDaemonScheduler alloc]
        initWithStateProvider:^NSDictionary<NSString *,id> *{
            SCSettings *settings = [SCSettings sharedSettings];
            id approved = [settings valueForKey:@"ApprovedSchedules"];
            id recurring = [settings valueForKey:@"ApprovedRecurringScheduleCommitments"];
            id activeBreaks = [settings valueForKey:@"ActiveScheduleBreaks"];
            return @{
                @"settings_available": @(settings.settingsStateAvailableForEnforcement),
                @"approved_schedules": [approved isKindOfClass:[NSDictionary class]] ? approved : @{},
                @"approved_recurring_commitments": [recurring isKindOfClass:[NSDictionary class]] ? recurring : @{},
                @"active_schedule_breaks": [activeBreaks isKindOfClass:[NSDictionary class]] ? activeBreaks : @{},
                @"block_running": @([SCBlockUtilities modernBlockIsRunning]),
                @"block_end_date": [settings valueForKey:@"BlockEndDate"] ?: [NSNull null],
                @"active_block_source": [settings valueForKey:@"ActiveBlockSource"] ?: @"unknown",
                @"active_schedule_id": [settings valueForKey:@"ActiveScheduleID"] ?: @"",
                @"active_commitment_id": [settings valueForKey:@"ActiveScheduleCommitmentID"] ?: @"",
                @"active_generation": [settings valueForKey:@"ActiveScheduleGeneration"] ?: @"",
                @"active_policy_revision": [settings valueForKey:@"ActiveSchedulePolicyRevision"] ?: @"",
                @"active_blocklist": [settings valueForKey:@"ActiveBlocklist"] ?: @[],
                @"active_is_allowlist": @([settings boolForKey:@"ActiveBlockAsWhitelist"]),
                @"active_owner_uid": [settings valueForKey:@"ActiveBlockControllingUID"] ?: @0,
                @"console_uid": @([SCMiscUtilities consoleUserUID]),
                @"now": [NSDate date],
            };
        }
        reconcileHandler:^(NSString *scheduleID, NSDictionary<NSString *,id> *record, void (^completion)(NSError *)) {
            [SCDaemonBlockMethods startScheduledBlockWithID:scheduleID record:record reply:completion];
        }
        endHandler:^(void (^completion)(NSError *)) {
            [SCDaemonBlockMethods endScheduledBlockWithReply:completion];
        }
        anomalyHandler:^(NSDictionary<NSString *,id> *fields) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            NSDictionary *safeFields = [SCSentry sanitizedTelemetryFields:fields
                                                              forEventName:@"schedule.reconcile_anomaly"];
            if (safeFields == nil) return;
            NSNumber *owner = [[SCSettings sharedSettings] valueForKey:@"ActiveBlockControllingUID"];
            uid_t uid = [owner isKindOfClass:[NSNumber class]] ? owner.unsignedIntValue : 0;
            if (uid == 0) uid = [SCMiscUtilities consoleUserUID];
            if (uid == 0) return;
            NSError *spoolError = nil;
            [[[SCTelemetrySpool alloc] init] appendEventName:@"schedule.reconcile_anomaly"
                                                       level:SCTelemetryEventLevelError
                                                      fields:safeFields
                                                      origin:SCTelemetryOriginDaemon
                                                      forUID:uid
                                                       error:&spoolError];
            if (spoolError != nil) SCDaemonLogError(@"Could not spool scheduler anomaly", spoolError);
        }];
    
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

    if ([SCBlockUtilities modernBlockIsRunning] && ![SCBlockUtilities currentBlockIsExpired]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [SCDaemonBlockMethods checkBlockIntegrity];
        });
    }

    __weak typeof(self) weakSelf = self;
    self.wakeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [weakSelf scheduleStateDidChangeWithTrigger:@"wake"];
        }];
    self.sessionObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [weakSelf scheduleStateDidChangeWithTrigger:@"session_change"];
        }];
    self.clockObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSSystemClockDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [weakSelf scheduleStateDidChangeWithTrigger:@"clock_change"];
        }];
    self.timezoneObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSSystemTimeZoneDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [weakSelf scheduleStateDidChangeWithTrigger:@"clock_change"];
        }];
    [self.scheduler start];

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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopCheckupTimer];
        });
        return;
    }
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
    if (self.wakeObserver != nil) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.wakeObserver];
        self.wakeObserver = nil;
    }
    if (self.sessionObserver != nil) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.sessionObserver];
        self.sessionObserver = nil;
    }
    if (self.clockObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.clockObserver];
        self.clockObserver = nil;
    }
    if (self.timezoneObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.timezoneObserver];
        self.timezoneObserver = nil;
    }
    [self.scheduler stop];
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

- (void)scheduleStateDidChangeWithTrigger:(NSString *)trigger {
    [self.scheduler evaluateForTrigger:trigger];
}

- (void)scheduleStateDidChangeWithTrigger:(NSString *)trigger
                                completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    [self.scheduler evaluateForTrigger:trigger completion:completion];
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

#pragma mark - Schedule Cleanup

- (void)cleanupLegacyScheduleArtifactsWithID:(NSString *)scheduleId
                               controllingUID:(uid_t)controllingUID {
    // Find and remove only the draining V1 LaunchAgent. Keeping this separate
    // prevents post-commit artifact cleanup from racing a newer root record.
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

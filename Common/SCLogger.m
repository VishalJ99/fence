//
//  SCLogger.m
//  SelfControl
//
//  Log export utility for user support
//

#import "SCLogger.h"
#import "SCLogExportWindowController.h"
#import "SCSentry.h"
#import "SCXPCClient.h"
#import "SCScheduleManager.h"

static NSString* SCStringByReplacingPattern(NSString* input, NSString* pattern, NSString* replacement) {
    NSError* regexError = nil;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                            options:0
                                                                              error:&regexError];
    if (regex == nil || regexError != nil) {
        return input;
    }
    return [regex stringByReplacingMatchesInString:input
                                            options:0
                                              range:NSMakeRange(0, input.length)
                                       withTemplate:replacement];
}

@implementation SCLogger

+ (NSString*)logsDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".fence/logs"];
}

+ (BOOL)prepareProtectedLogsDirectory {
    NSString* logsDir = [self logsDirectory];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSDictionary* privateDirectoryAttributes = @{NSFilePosixPermissions: @0700};
    NSDictionary* existingAttributes = [fileManager attributesOfItemAtPath:logsDir error:nil];
    if ([existingAttributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink] ||
        (existingAttributes != nil && ![existingAttributes[NSFileType] isEqualToString:NSFileTypeDirectory])) {
        return NO;
    }
    if (existingAttributes == nil) {
        BOOL created = [fileManager createDirectoryAtPath:logsDir
                              withIntermediateDirectories:YES
                                               attributes:privateDirectoryAttributes
                                                    error:nil];
        if (!created) {
            return NO;
        }
    }
    // Repair permissions for directories created by older Fence versions.
    return [fileManager setAttributes:privateDirectoryAttributes ofItemAtPath:logsDir error:nil];
}

+ (void)ensureDirectoriesExist {
    [self prepareProtectedLogsDirectory];
}

+ (NSString*)sanitizedSupportLogContent:(NSString*)content {
    if (content.length == 0) {
        return @"";
    }

    // Lines naming these fields are dropped instead of trying to infer where a
    // private value ends. Structural state is appended separately by collectLogs.
    NSArray<NSString*>* deniedMarkers = @[
        @"blocklist", @"activeblocklist", @"approvedschedules", @"scheduleid",
        @"segmentid", @"bundleid", @"bundle identifier", @"authorization",
        @"authdata", @"bearer ", @"license", @"deviceidentifier", @"device id",
        @"fallbackidentifier", @"refresh_token", @"access_token"
    ];

    NSMutableArray<NSString*>* sanitizedLines = [NSMutableArray array];
    __block NSUInteger omittedLineCount = 0;
    [content enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
        NSString* lowercaseLine = line.lowercaseString;
        if ([lowercaseLine containsString:@"/users/"] || [lowercaseLine containsString:@"/home/"]) {
            omittedLineCount += 1;
            return;
        }
        for (NSString* marker in deniedMarkers) {
            if ([lowercaseLine containsString:marker]) {
                omittedLineCount += 1;
                return;
            }
        }

        NSString* sanitized = line;
        // URLs and email addresses can contain user-entered hostnames, query
        // strings, license keys, or device tokens.
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)\\b(?:https?|ftp)://[^\\s<>()]+",
                                               @"[redacted-url]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
                                               @"[redacted-email]");

        // Never export user home paths or arbitrary absolute filesystem paths.
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)(?:file://)?/(?:Users|home)/[^\\s\\\"'<>]+",
                                               @"[redacted-path]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?<![A-Za-z0-9])/(?!/)[^\\s\\\"'<>\\]\\[\\)\\(,;]+",
                                               @"[redacted-path]");

        // Website entries and reverse-DNS app identifiers share the same dotted
        // shape. Redact ASCII, punycode, and Unicode domain labels alike.
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?iu)(?<![\\p{L}\\p{N}_-])(?:[\\p{L}\\p{N}](?:[\\p{L}\\p{N}-]{0,62})\\.)+[\\p{L}]{2,63}(?::[0-9]{1,5})?(?:[/\\?#][^\\s<>()]*)?(?![\\p{L}\\p{N}_-])",
                                               @"[redacted-domain]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?<![0-9])(?:25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])(?:\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])){3}(?![0-9])",
                                               @"[redacted-address]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])",
                                               @"[redacted-address]");

        // Common serialized identifiers and credential/blob representations.
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\b",
                                               @"[redacted-id]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?i)<[0-9a-f\\s]{16,}>",
                                               @"[redacted-blob]");
        sanitized = SCStringByReplacingPattern(sanitized,
                                               @"(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{24,}={0,2}(?![A-Za-z0-9+/_=-])",
                                               @"[redacted-token]");

        [sanitizedLines addObject:sanitized];
    }];

    if (omittedLineCount > 0) {
        [sanitizedLines addObject:[NSString stringWithFormat:@"[Private log lines omitted: %lu]",
                                   (unsigned long)omittedLineCount]];
    }
    return [sanitizedLines componentsJoinedByString:@"\n"];
}

+ (void)exportLogsForSupport {
    NSLog(@"SCLogger: exportLogsForSupport called");
    [SCSentry logMessage:@"Support log export requested" category:@"support-logs"];

    // Show loading window immediately (on main thread)
    [[SCLogExportWindowController sharedController] show];

    [self collectSupportReferenceWithCompletion:^(NSString *supportReference) {
      // Run log collection on background thread
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"SCLogger: Starting log collection on background thread");
        [SCSentry logMessage:@"Support log collection started" level:SCSentryLogLevelDebug category:@"support-logs" attributes:nil];
        NSString* logOutput = [self collectLogs];
        NSLog(@"SCLogger: Log collection complete, length=%lu", (unsigned long)logOutput.length);
        [SCSentry logMessage:@"Support log collection completed"
                       level:SCSentryLogLevelInfo
                    category:@"support-logs"
                  attributes:@{@"contentLength": @(logOutput.length)}];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"SCLogger: Back on main thread, closing loading window");

            // Close loading window
            [[SCLogExportWindowController sharedController] close];

            NSLog(@"SCLogger: Calling saveLogsAndComposeEmail");
            [self saveLogsAndComposeEmail:logOutput reference:supportReference];
        });
      });
    }];
}

+ (BOOL)legacyDefaultsContainScheduleState {
    NSDictionary *legacyDomain = [[NSUserDefaults standardUserDefaults]
        persistentDomainForName:@"org.eyebeam.SelfControl"] ?: @{};
    id bundles = legacyDomain[@"SCScheduleBundles"];
    if ([bundles isKindOfClass:[NSArray class]] && [bundles count] > 0) return YES;
    for (id candidateKey in legacyDomain) {
        if (![candidateKey isKindOfClass:[NSString class]]) continue;
        NSString *key = candidateKey;
        id value = legacyDomain[key];
        if ([key hasPrefix:@"SCWeekSchedules_"] && [value isKindOfClass:[NSArray class]] && [value count] > 0) {
            return YES;
        }
        if ([key hasPrefix:@"SCWeekCommitment_"] && [value isKindOfClass:[NSDate class]]) return YES;
    }
    return NO;
}

+ (void)collectSupportReferenceWithCompletion:(void(^)(NSString * _Nullable reference))completion {
    if (![SCSentry errorReportingEnabled]) {
        completion(nil);
        return;
    }

    SCXPCClient *xpc = [[SCXPCClient alloc] init];
    NSDictionary<NSString *, NSNumber *> *appSnapshot =
        [[SCScheduleManager sharedManager] telemetryStructuralSnapshot];
    __block BOOL completed = NO;
    void (^finish)(NSDictionary<NSString *, id> *, NSError *) =
        ^(NSDictionary<NSString *, id> *daemonSnapshot, NSError *error) {
        @synchronized (xpc) {
            if (completed) return;
            completed = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL daemonReachable = error == nil && daemonSnapshot.count > 0;
            BOOL settingsAvailable = daemonReachable && [daemonSnapshot[@"settings_available"] boolValue];
            BOOL blockRunning = daemonReachable && [daemonSnapshot[@"block_running"] boolValue];
            BOOL pfActive = daemonReachable && [daemonSnapshot[@"pf_active"] boolValue];
            BOOL hostsActive = daemonReachable && [daemonSnapshot[@"hosts_active"] boolValue];
            BOOL appMonitoring = daemonReachable && [daemonSnapshot[@"app_monitoring"] boolValue];
            NSUInteger expectedActiveCount = [appSnapshot[@"expected_active_entry_count"] unsignedIntegerValue];
            NSUInteger daemonActiveCount = [daemonSnapshot[@"active_entry_count"] unsignedIntegerValue];
            BOOL projectionAvailable = [appSnapshot[@"active_projection_available"] boolValue];
            BOOL requiresHosts = [appSnapshot[@"expected_requires_hosts"] boolValue];
            BOOL requiresPF = [appSnapshot[@"expected_requires_packet_filter"] boolValue];
            NSUInteger expectedAppCount = [appSnapshot[@"expected_active_app_entry_count"] unsignedIntegerValue];
            BOOL physicalLayersMatch = daemonReachable && (blockRunning
                ? ((!requiresHosts || hostsActive) && (!requiresPF || pfActive) &&
                   (expectedAppCount == 0 || appMonitoring))
                : !(pfActive || hostsActive || appMonitoring));
            BOOL activeCountsMatch = daemonReachable && projectionAvailable &&
                daemonActiveCount == expectedActiveCount &&
                blockRunning == (expectedActiveCount > 0) && physicalLayersMatch;
            NSUInteger localJobCount = [appSnapshot[@"installed_schedule_job_count"] unsignedIntegerValue];
            NSUInteger daemonApprovalCount = [daemonSnapshot[@"approved_schedule_count"] unsignedIntegerValue];
            BOOL approvalCountsMatch = daemonReachable && localJobCount == daemonApprovalCount;

            NSString *lastStrictifyOutcome = [[NSUserDefaults standardUserDefaults]
                stringForKey:@"SCLastStrictifyTelemetryOutcome"] ?: @"none";
            if (![@[@"none", @"verified", @"partial", @"failed", @"skipped"]
                    containsObject:lastStrictifyOutcome]) {
                lastStrictifyOutcome = @"none";
            }

            NSString *eventID = [SCSentry captureTelemetryEvent:@"support.diagnostic_snapshot"
                                                          level:SCTelemetryEventLevelInfo
                                                         fields:@{
                @"collector_status": daemonReachable ? @"complete" : @"failed",
                @"last_strictify_outcome": lastStrictifyOutcome,
                @"settings_available": @(settingsAvailable),
                @"block_running": @(blockRunning),
                @"app_has_schedule_state": appSnapshot[@"app_has_schedule_state"] ?: @NO,
                @"legacy_domain_has_state": @([self legacyDefaultsContainScheduleState]),
                @"daemon_reachable": @(daemonReachable),
                @"pf_active": @(pfActive),
                @"hosts_active": @(hostsActive),
                @"app_monitoring": @(appMonitoring),
                @"physical_layers_match": @(physicalLayersMatch),
                @"active_counts_match": @(activeCountsMatch),
                @"approval_counts_match": @(approvalCountsMatch),
                @"app_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
                @"app_week_count": appSnapshot[@"decoded_schedule_count"] ?: @0,
                @"app_commitment_count": appSnapshot[@"commitment_count"] ?: @0,
                @"daemon_active_entry_count": @(daemonActiveCount),
                @"daemon_approval_count": @(daemonApprovalCount),
                @"daemon_job_count": daemonSnapshot[@"schedule_job_count"] ?: @0,
                @"collector_error_count": @(daemonReachable ? 0 : 1),
                @"daemon_protocol": daemonSnapshot[@"daemon_protocol"] ?: @0,
            }];
            NSString *reference = eventID.length >= 8
                ? [NSString stringWithFormat:@"FENCE-%@", [[eventID substringToIndex:8] uppercaseString]]
                : nil;
            completion(reference);
        });
    };

    [xpc getSanitizedDaemonSnapshot:^(NSDictionary<NSString *,id> *snapshot, NSError *error) {
        finish(snapshot ?: @{}, error);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *timeout = [NSError errorWithDomain:@"SCLoggerSnapshotError" code:1 userInfo:nil];
        finish(@{}, timeout);
    });
}

+ (NSString*)collectLogs {
    NSMutableString* output = [NSMutableString string];

    // Header with system info
    [output appendFormat:@"=== Fence Support Logs ===\n"];
    [output appendFormat:@"Exported: %@\n", [NSDate date]];
    [output appendFormat:@"App Version: %@\n", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
    [output appendFormat:@"Build: %@\n", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]];
    [output appendFormat:@"macOS: %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [output appendFormat:@"\n"];

    // Collect logs from unified logging system
    // Captures: main app, daemon, CLI (launchd jobs), app blocker helper, and launchd job events
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/log";
    task.arguments = @[
        @"show",
        @"--predicate", @"process == \"Fence\" OR process == \"SelfControl\" OR process == \"selfcontrold\" OR process == \"selfcontrol-cli\" OR process == \"SCKillerHelper\" OR (process == \"launchd\" AND eventMessage CONTAINS \"eyebeam\")",
        @"--last", @"24h",
        @"--style", @"compact"
    ];

    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        NSLog(@"SCLogger: log command launched");

        // IMPORTANT: Read data BEFORE waitUntilExit to avoid deadlock
        // If the pipe buffer fills, the task blocks waiting to write,
        // but we'd be blocked waiting for exit - classic deadlock
        NSData* data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];

        NSLog(@"SCLogger: log command finished with status %d, data length=%lu",
              task.terminationStatus, (unsigned long)data.length);
        [SCSentry logMessage:@"Unified log command completed"
                       level:(task.terminationStatus == 0 ? SCSentryLogLevelInfo : SCSentryLogLevelWarning)
                    category:@"support-logs"
                  attributes:@{
                      @"terminationStatus": @(task.terminationStatus),
                      @"outputLength": @(data.length)
                  }];
        NSString* logContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        logContent = [self sanitizedSupportLogContent:logContent ?: @""];

        if (logContent.length > 0) {
            [output appendFormat:@"=== System Logs (last 24 hours) ===\n\n"];
            [output appendString:logContent];
        } else {
            [output appendFormat:@"=== System Logs ===\n"];
            [output appendFormat:@"No log entries found for Fence processes in the last 24 hours.\n"];
            [output appendFormat:@"This may be normal if the app was recently installed.\n"];
        }
    } @catch (NSException* exception) {
        [output appendFormat:@"=== Error Collecting Logs ===\n"];
        [output appendFormat:@"Failed to collect system logs (exception type: %@).\n", exception.name ?: @"unknown"];
        [SCSentry logMessage:@"Unified log command failed"
                       level:SCSentryLogLevelError
                    category:@"support-logs"
                  attributes:@{@"exceptionName": exception.name ?: @"unknown"}];
    }

    // Add current block status
    [output appendFormat:@"\n=== Current State ===\n"];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    NSDate* blockEndDate = [defaults objectForKey:@"BlockEndDate"];
    if (blockEndDate) {
        [output appendFormat:@"Block Active: %@\n", ([blockEndDate timeIntervalSinceNow] > 0) ? @"YES" : @"NO (expired)"];
    } else {
        [output appendFormat:@"Block Active: NO\n"];
    }

    NSArray* blocklist = [defaults arrayForKey:@"Blocklist"];
    [output appendFormat:@"Blocklist entries: %lu\n", (unsigned long)(blocklist ? blocklist.count : 0)];

    return output;
}

+ (void)saveLogsAndComposeEmail:(NSString*)logContent reference:(NSString * _Nullable)supportReference {
    NSLog(@"SCLogger: saveLogsAndComposeEmail called with content length=%lu", (unsigned long)logContent.length);
    // Save to ~/.fence/logs/
    NSString* logsDir = [self logsDirectory];
    // Create directory if it doesn't exist (backup - should be created on app launch)
    BOOL directoryReady = [self prepareProtectedLogsDirectory];
    NSFileManager* fileManager = [NSFileManager defaultManager];

    // Generate filename with timestamp
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd-HHmmss-SSS";
    NSString* timestamp = [formatter stringFromDate:[NSDate date]];
    NSString* filename = [NSString stringWithFormat:@"fence-logs-%@.txt", timestamp];

    NSString* filePath = [logsDir stringByAppendingPathComponent:filename];

    NSString *referencedLogContent = supportReference.length > 0
        ? [NSString stringWithFormat:@"Support Reference: %@\n%@", supportReference, logContent]
        : logContent;
    NSData* logData = [referencedLogContent dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* privateFileAttributes = @{NSFilePosixPermissions: @0600};
    BOOL success = directoryReady && logData != nil && [fileManager createFileAtPath:filePath
                                                          contents:logData
                                                        attributes:privateFileAttributes];
    NSError* error = success ? nil : [NSError errorWithDomain:@"SCLoggerErrorDomain"
                                                         code:1
                                                     userInfo:nil];

    if (!success) {
        NSLog(@"SCLogger: Failed to write file (domain=%@ code=%ld)",
              error.domain ?: @"unknown", (long)error.code);
        [SCSentry logMessage:@"Support log export write failed"
                       level:SCSentryLogLevelError
                    category:@"support-logs"
                  attributes:@{
                      @"errorName": error.domain ?: @"unknown",
                      @"errorCode": @(error.code),
                      @"contentLength": @(logContent.length)
                  }];
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Export Failed", @"Error alert title");
        alert.informativeText = [NSString stringWithFormat:@"Could not save logs: %@", error.localizedDescription];
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        return;
    }

    // Enforce least privilege even if an existing installation had a permissive umask.
    [fileManager setAttributes:privateFileAttributes ofItemAtPath:filePath error:nil];
    NSLog(@"SCLogger: Support log file written successfully");
    [SCSentry logMessage:@"Support log export file saved"
                   level:SCSentryLogLevelInfo
                category:@"support-logs"
              attributes:@{
                  @"contentLength": @(logContent.length)
              }];

    // Reveal in Finder
    NSLog(@"SCLogger: Revealing in Finder...");
    [[NSWorkspace sharedWorkspace] selectFile:filePath inFileViewerRootedAtPath:@""];

    // Compose email with mailto:
    NSString* subject = supportReference.length > 0
        ? [NSString stringWithFormat:@"Fence Support Request [%@]", supportReference]
        : @"Fence Support Request";
    NSString* body = [NSString stringWithFormat:
        @"Please describe your issue below:\n\n\n\n"
        @"---\n"
        @"Diagnostic reference: %@\n"
        @"Log file saved to: ~/.fence/logs/%@\n\n"
        @"A Finder window should have opened showing the file.\n"
        @"If you don't see it, press Cmd+Shift+. to reveal hidden folders.\n\n"
        @"Please drag the log file into this email before sending.",
        supportReference ?: @"local-only", filename];

    NSString* encodedSubject = [subject stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString* encodedBody = [body stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    NSString* mailtoURL = [NSString stringWithFormat:@"mailto:support@usefence.app?subject=%@&body=%@", encodedSubject, encodedBody];

    NSLog(@"SCLogger: Opening mailto URL...");
    BOOL opened = [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:mailtoURL]];
    NSLog(@"SCLogger: mailto openURL returned %@", opened ? @"YES" : @"NO");
    [SCSentry logMessage:@"Support mail compose requested"
                   level:(opened ? SCSentryLogLevelInfo : SCSentryLogLevelWarning)
                category:@"support-logs"
              attributes:@{@"opened": @(opened)}];
}

@end

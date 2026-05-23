//
//  SCLogger.m
//  SelfControl
//
//  Log export utility for user support
//

#import "SCLogger.h"
#import "SCLogExportWindowController.h"
#import "SCSentry.h"

@implementation SCLogger

+ (NSString*)logsDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".fence/logs"];
}

+ (void)ensureDirectoriesExist {
    NSString* logsDir = [self logsDirectory];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:logsDir]) {
        [fileManager createDirectoryAtPath:logsDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }
}

+ (void)exportLogsForSupport {
    NSLog(@"SCLogger: exportLogsForSupport called");
    [SCSentry logMessage:@"Support log export requested" category:@"support-logs"];

    // Show loading window immediately (on main thread)
    [[SCLogExportWindowController sharedController] show];

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
            [self saveLogsAndComposeEmail:logOutput];
        });
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
        [output appendFormat:@"Failed to collect system logs: %@\n", exception.reason];
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
        [output appendFormat:@"Block End Date: %@\n", blockEndDate];
        [output appendFormat:@"Block Active: %@\n", ([blockEndDate timeIntervalSinceNow] > 0) ? @"YES" : @"NO (expired)"];
    } else {
        [output appendFormat:@"Block Active: NO\n"];
    }

    NSArray* blocklist = [defaults arrayForKey:@"Blocklist"];
    [output appendFormat:@"Blocklist entries: %lu\n", (unsigned long)(blocklist ? blocklist.count : 0)];

    return output;
}

+ (void)saveLogsAndComposeEmail:(NSString*)logContent {
    NSLog(@"SCLogger: saveLogsAndComposeEmail called with content length=%lu", (unsigned long)logContent.length);
    // Save to ~/.fence/logs/
    NSString* logsDir = [self logsDirectory];
    NSLog(@"SCLogger: logsDir=%@", logsDir);

    // Create directory if it doesn't exist (backup - should be created on app launch)
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:logsDir]) {
        [fileManager createDirectoryAtPath:logsDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }

    // Generate filename with timestamp
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd-HHmmss";
    NSString* timestamp = [formatter stringFromDate:[NSDate date]];
    NSString* filename = [NSString stringWithFormat:@"fence-logs-%@.txt", timestamp];

    NSString* filePath = [logsDir stringByAppendingPathComponent:filename];

    NSError* error = nil;
    BOOL success = [logContent writeToFile:filePath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&error];

    if (!success) {
        NSLog(@"SCLogger: Failed to write file: %@", error);
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

    NSLog(@"SCLogger: File written successfully to %@", filePath);
    [SCSentry logMessage:@"Support log export file saved"
                   level:SCSentryLogLevelInfo
                category:@"support-logs"
              attributes:@{
                  @"filename": filename,
                  @"contentLength": @(logContent.length)
              }];

    // Reveal in Finder
    NSLog(@"SCLogger: Revealing in Finder...");
    [[NSWorkspace sharedWorkspace] selectFile:filePath inFileViewerRootedAtPath:@""];

    // Compose email with mailto:
    NSString* subject = @"Fence Support Request";
    NSString* body = [NSString stringWithFormat:
        @"Please describe your issue below:\n\n\n\n"
        @"---\n"
        @"Log file saved to: ~/.fence/logs/%@\n\n"
        @"A Finder window should have opened showing the file.\n"
        @"If you don't see it, press Cmd+Shift+. to reveal hidden folders.\n\n"
        @"Please drag the log file into this email before sending.",
        filename];

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

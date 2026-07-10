//
//  SCScheduleLaunchdBridge.m
//  SelfControl
//
//  Bridge between Weekly Schedule UX and selfcontrol-cli via launchd.
//

#import "SCScheduleLaunchdBridge.h"
#import "SCBlockFileReaderWriter.h"
#import "SCXPCClient.h"
#import "SCMiscUtilities.h"

NSString * const SCScheduleLaunchdBridgeFailureStageKey = @"SCScheduleLaunchdBridgeFailureStage";

static void SCBridgeLogError(NSString* message, NSError* error) {
    NSLog(@"SCScheduleLaunchdBridge: %@ (domain=%@ code=%ld)",
          message,
          error.domain ?: @"unknown",
          (long)error.code);
}

#pragma mark - SCBlockWindow Implementation

@implementation SCBlockWindow

+ (instancetype)windowWithStartDate:(NSDate *)start endDate:(NSDate *)end day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes {
    SCBlockWindow *window = [[SCBlockWindow alloc] init];
    window.startDate = start;
    window.endDate = end;
    window.day = day;
    window.startMinutes = minutes;
    return window;
}

- (NSInteger)durationMinutes {
    return (NSInteger)([self.endDate timeIntervalSinceDate:self.startDate] / 60.0);
}

- (NSString *)description {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"EEE HH:mm";
    return [NSString stringWithFormat:@"<SCBlockWindow %@ - %@ (%ld min)>",
            [fmt stringFromDate:self.startDate],
            [fmt stringFromDate:self.endDate],
            (long)[self durationMinutes]];
}

@end


#pragma mark - SCScheduleLaunchdBridge Implementation

@implementation SCScheduleLaunchdBridge

#pragma mark - Directory Paths

+ (NSURL *)schedulesDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:YES
                                      error:nil];
    NSURL *selfControlDir = [appSupport URLByAppendingPathComponent:@"SelfControl"];
    NSURL *schedulesDir = [selfControlDir URLByAppendingPathComponent:@"Schedules"];

    // Create if doesn't exist
    if (![fm fileExistsAtPath:schedulesDir.path]) {
        [fm createDirectoryAtURL:schedulesDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    return schedulesDir;
}

+ (NSURL *)launchAgentsDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *library = [fm URLForDirectory:NSLibraryDirectory
                                inDomain:NSUserDomainMask
                       appropriateForURL:nil
                                  create:NO
                                   error:nil];
    NSURL *launchAgents = [library URLByAppendingPathComponent:@"LaunchAgents"];

    // Create if doesn't exist (should exist, but just in case)
    if (![fm fileExistsAtPath:launchAgents.path]) {
        [fm createDirectoryAtURL:launchAgents withIntermediateDirectories:YES attributes:nil error:nil];
    }

    return launchAgents;
}

+ (nullable NSString *)cliPath {
    // CLI is inside the app bundle at Contents/MacOS/selfcontrol-cli
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *cliPath = [bundle pathForAuxiliaryExecutable:@"selfcontrol-cli"];

    if (cliPath && [[NSFileManager defaultManager] isExecutableFileAtPath:cliPath]) {
        return cliPath;
    }

    // Fallback: try relative to bundle executable
    NSString *execPath = bundle.executablePath;
    NSString *macosDir = [execPath stringByDeletingLastPathComponent];
    cliPath = [macosDir stringByAppendingPathComponent:@"selfcontrol-cli"];

    if ([[NSFileManager defaultManager] isExecutableFileAtPath:cliPath]) {
        return cliPath;
    }

    NSLog(@"ERROR: Could not find selfcontrol-cli in app bundle");
    return nil;
}

#pragma mark - Blocklist File Management

+ (NSURL *)blocklistFileURLForBundleID:(NSString *)bundleID {
    NSString *filename = [NSString stringWithFormat:@"%@.selfcontrol", bundleID];
    return [[self schedulesDirectory] URLByAppendingPathComponent:filename];
}

- (nullable NSURL *)writeBlocklistFileForBundle:(SCBlockBundle *)bundle error:(NSError **)error {
    NSURL *fileURL = [SCScheduleLaunchdBridge blocklistFileURLForBundleID:bundle.bundleID];

    // Build block info dictionary in the format SCBlockFileReaderWriter expects
    NSDictionary *blockInfo = @{
        @"Blocklist": bundle.entries ?: @[],
        @"BlockAsWhitelist": @NO  // Schedules always use blocklist mode
    };

    BOOL success = [SCBlockFileReaderWriter writeBlocklistToFileURL:fileURL
                                                          blockInfo:blockInfo
                                                              error:error];
    if (!success) {
        SCBridgeLogError(@"Failed to write blocklist file", error ? *error : nil);
        return nil;
    }

    NSLog(@"SCScheduleLaunchdBridge: Wrote blocklist file (entryCount=%lu)",
          (unsigned long)bundle.entries.count);
    return fileURL;
}

- (BOOL)deleteBlocklistFileForBundleID:(NSString *)bundleID error:(NSError **)error {
    NSURL *fileURL = [SCScheduleLaunchdBridge blocklistFileURLForBundleID:bundleID];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:fileURL.path]) {
        return [fm removeItemAtURL:fileURL error:error];
    }
    return YES; // File didn't exist, that's fine
}

#pragma mark - Block Window Calculation

- (NSArray<SCBlockWindow *> *)blockWindowsForSchedule:(SCWeeklySchedule *)schedule
                                                  day:(SCDayOfWeek)day
                                           weekOffset:(NSInteger)weekOffset {
    NSMutableArray<SCBlockWindow *> *blockWindows = [NSMutableArray array];

    // Get allowed windows for this day (sorted by start time)
    NSArray<SCTimeRange *> *allowedWindows = [schedule allowedWindowsForDay:day];
    allowedWindows = [allowedWindows sortedArrayUsingComparator:^NSComparisonResult(SCTimeRange *a, SCTimeRange *b) {
        return [@([a startMinutes]) compare:@([b startMinutes])];
    }];

    // Calculate the absolute date for this day
    NSDate *weekStart = (weekOffset == 0) ? [SCWeeklySchedule startOfCurrentWeek] : [SCWeeklySchedule startOfNextWeek];
    NSCalendar *calendar = [NSCalendar currentCalendar];

    // Week starts on Monday (day 1), so adjust: Sunday=6, Mon=0, Tue=1, etc.
    NSInteger daysFromMonday = (day == SCDayOfWeekSunday) ? 6 : (day - 1);
    NSDate *dayDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:daysFromMonday toDate:weekStart options:0];

    // If no allowed windows, entire day is blocked
    if (allowedWindows.count == 0) {
        NSDate *startOfDay = [calendar startOfDayForDate:dayDate];
        NSDate *endOfDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:startOfDay options:0];
        endOfDay = [endOfDay dateByAddingTimeInterval:-1]; // 23:59:59

        SCBlockWindow *window = [SCBlockWindow windowWithStartDate:startOfDay
                                                           endDate:endOfDay
                                                               day:day
                                                      startMinutes:0];
        [blockWindows addObject:window];
        return blockWindows;
    }

    // Invert allowed windows to get blocked windows
    // Walk through the day, creating block windows for gaps between allowed windows

    NSInteger currentMinute = 0; // Start of day
    NSDate *startOfDay = [calendar startOfDayForDate:dayDate];

    for (SCTimeRange *allowedWindow in allowedWindows) {
        NSInteger allowStart = [allowedWindow startMinutes];
        NSInteger allowEnd = [allowedWindow endMinutes];

        // If there's a gap before this allowed window, it's a block window
        if (currentMinute < allowStart) {
            NSDate *blockStart = [startOfDay dateByAddingTimeInterval:currentMinute * 60];
            NSDate *blockEnd = [startOfDay dateByAddingTimeInterval:allowStart * 60];

            SCBlockWindow *window = [SCBlockWindow windowWithStartDate:blockStart
                                                               endDate:blockEnd
                                                                   day:day
                                                          startMinutes:currentMinute];
            [blockWindows addObject:window];
        }

        // Move past this allowed window
        currentMinute = allowEnd;
    }

    // If there's time remaining after the last allowed window, it's a block window
    if (currentMinute < 24 * 60) {
        NSDate *blockStart = [startOfDay dateByAddingTimeInterval:currentMinute * 60];
        NSDate *endOfDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:startOfDay options:0];

        SCBlockWindow *window = [SCBlockWindow windowWithStartDate:blockStart
                                                           endDate:endOfDay
                                                               day:day
                                                      startMinutes:currentMinute];
        [blockWindows addObject:window];
    }

    return blockWindows;
}

- (NSArray<SCBlockWindow *> *)allBlockWindowsForSchedule:(SCWeeklySchedule *)schedule
                                              weekOffset:(NSInteger)weekOffset {
    NSMutableArray<SCBlockWindow *> *allWindows = [NSMutableArray array];

    for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
        NSArray<SCBlockWindow *> *dayWindows = [self blockWindowsForSchedule:schedule day:day weekOffset:weekOffset];
        [allWindows addObjectsFromArray:dayWindows];
    }

    return allWindows;
}

#pragma mark - Job Label Convention

+ (NSString *)jobLabelPrefix {
    return @"org.eyebeam.selfcontrol.schedule";
}

+ (NSString *)jobLabelForBundleID:(NSString *)bundleID day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes {
    NSString *dayStr = [[SCWeeklySchedule stringForDay:day] lowercaseString];
    NSString *timeStr = [NSString stringWithFormat:@"%02ld%02ld", (long)(minutes / 60), (long)(minutes % 60)];
    return [NSString stringWithFormat:@"%@.%@.%@.%@", [self jobLabelPrefix], bundleID, dayStr, timeStr];
}

#pragma mark - Plist Generation

- (NSDictionary *)launchdPlistForBundle:(SCBlockBundle *)bundle
                            blockWindow:(SCBlockWindow *)window {
    NSString *cliPath = [SCScheduleLaunchdBridge cliPath];
    if (!cliPath) {
        NSLog(@"ERROR: Cannot create plist without CLI path");
        return nil;
    }

    NSURL *blocklistURL = [SCScheduleLaunchdBridge blocklistFileURLForBundleID:bundle.bundleID];

    // Format end date as ISO8601
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSString *endDateStr = [isoFormatter stringFromDate:window.endDate];

    // Job label
    NSString *label = [SCScheduleLaunchdBridge jobLabelForBundleID:bundle.bundleID
                                                               day:window.day
                                                      startMinutes:window.startMinutes];

    // Calculate StartCalendarInterval
    // launchd weekday: 0 = Sunday, 1 = Monday, etc. (matches SCDayOfWeek)
    NSInteger hour = window.startMinutes / 60;
    NSInteger minute = window.startMinutes % 60;

    NSDictionary *calendarInterval = @{
        @"Weekday": @(window.day),
        @"Hour": @(hour),
        @"Minute": @(minute)
    };

    // Build the plist
    NSDictionary *plist = @{
        @"Label": label,
        @"ProgramArguments": @[
            cliPath,
            @"start",
            @"--blocklist", blocklistURL.path,
            @"--enddate", endDateStr
        ],
        @"StartCalendarInterval": calendarInterval,
        @"RunAtLoad": @NO,  // Don't run immediately when loaded
        @"StandardOutPath": @"/dev/null",
        @"StandardErrorPath": @"/dev/null"
    };

    return plist;
}

- (BOOL)writeLaunchdPlist:(NSDictionary *)plist
                  toLabel:(NSString *)label
                    error:(NSError **)error {
    NSString *filename = [NSString stringWithFormat:@"%@.plist", label];
    NSURL *plistURL = [[SCScheduleLaunchdBridge launchAgentsDirectory] URLByAppendingPathComponent:filename];

    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:error];
    if (!plistData) {
        SCBridgeLogError(@"Failed to serialize launchd plist", error ? *error : nil);
        return NO;
    }

    BOOL success = [plistData writeToURL:plistURL options:NSDataWritingAtomic error:error];
    if (!success) {
        SCBridgeLogError(@"Failed to write launchd plist", error ? *error : nil);
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Wrote launchd plist");
    return YES;
}

#pragma mark - launchctl Operations

- (BOOL)loadJobWithLabel:(NSString *)label error:(NSError **)error {
    NSString *filename = [NSString stringWithFormat:@"%@.plist", label];
    NSURL *plistURL = [[SCScheduleLaunchdBridge launchAgentsDirectory] URLByAppendingPathComponent:filename];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"load", plistURL.path];

    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    NSError *taskError = nil;
    [task launchAndReturnError:&taskError];
    if (taskError) {
        if (error) *error = taskError;
        SCBridgeLogError(@"Failed to launch launchctl load", taskError);
        return NO;
    }

    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        (void)errorData;
        NSLog(@"SCScheduleLaunchdBridge: launchctl load failed (exitStatus=%d)", task.terminationStatus);
        if (error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:task.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: @"launchctl load failed"}];
        }
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Loaded launchd job");
    return YES;
}

- (BOOL)unloadJobWithLabel:(NSString *)label error:(NSError **)error {
    NSString *filename = [NSString stringWithFormat:@"%@.plist", label];
    NSURL *plistURL = [[SCScheduleLaunchdBridge launchAgentsDirectory] URLByAppendingPathComponent:filename];

    // First unload the job (ignore errors - job might not be loaded)
    NSTask *unloadTask = [[NSTask alloc] init];
    unloadTask.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    unloadTask.arguments = @[@"unload", plistURL.path];

    [unloadTask launchAndReturnError:nil];
    [unloadTask waitUntilExit];
    // Ignore unload errors - job might not be loaded

    NSFileManager *fm = [NSFileManager defaultManager];

    // Delete associated blocklist file for merged segment jobs
    // Label format: org.eyebeam.selfcontrol.schedule.merged-{UUID}.{day}.{time}
    if ([label containsString:@".merged-"]) {
        NSArray *parts = [label componentsSeparatedByString:@".merged-"];
        if (parts.count > 1) {
            NSString *remainder = parts[1];  // {UUID}.{day}.{time}
            NSString *segmentID = [remainder componentsSeparatedByString:@"."].firstObject;
            if (segmentID.length > 0) {
                NSURL *blocklistURL = [[SCScheduleLaunchdBridge schedulesDirectory]
                                       URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.selfcontrol", segmentID]];
                if ([fm fileExistsAtPath:blocklistURL.path]) {
                    [fm removeItemAtURL:blocklistURL error:nil];
                    NSLog(@"SCScheduleLaunchdBridge: Removed merged blocklist file");
                }
            }
        }
    }

    // Then delete the plist file
    if ([fm fileExistsAtPath:plistURL.path]) {
        NSError *removeError = nil;
        if (![fm removeItemAtURL:plistURL error:&removeError]) {
            if (error) *error = removeError;
            SCBridgeLogError(@"Failed to remove launchd plist", removeError);
            return NO;
        }
    }

    NSLog(@"SCScheduleLaunchdBridge: Unloaded and removed launchd job");
    return YES;
}

#pragma mark - Immediate Block Start

- (BOOL)startBlockImmediatelyForBundle:(SCBlockBundle *)bundle
                               endDate:(NSDate *)endDate
                                 error:(NSError **)error {
    NSString *cliPath = [SCScheduleLaunchdBridge cliPath];
    if (!cliPath) {
        NSLog(@"ERROR: Cannot start block - CLI path not found");
        if (error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"CLI executable not found"}];
        }
        return NO;
    }

    NSURL *blocklistURL = [SCScheduleLaunchdBridge blocklistFileURLForBundleID:bundle.bundleID];

    // Format end date as ISO8601
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSString *endDateStr = [isoFormatter stringFromDate:endDate];

    NSLog(@"SCScheduleLaunchdBridge: Starting block immediately (entryCount=%lu)",
          (unsigned long)bundle.entries.count);

    // Run the CLI directly
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:cliPath];
    task.arguments = @[@"start", @"--blocklist", blocklistURL.path, @"--enddate", endDateStr];

    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    NSError *taskError = nil;
    [task launchAndReturnError:&taskError];
    if (taskError) {
        SCBridgeLogError(@"Failed to launch CLI", taskError);
        if (error) *error = taskError;
        return NO;
    }

    [task waitUntilExit];

    NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];

    if (task.terminationStatus != 0) {
        NSLog(@"SCScheduleLaunchdBridge: CLI failed (exitStatus=%d outputBytes=%lu errorBytes=%lu)",
              task.terminationStatus,
              (unsigned long)outputData.length,
              (unsigned long)errorData.length);
        if (error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:task.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: @"CLI failed"}];
        }
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Block started successfully");
    return YES;
}

#pragma mark - launchd Job Management

- (BOOL)installJobsForBundle:(SCBlockBundle *)bundle
                    schedule:(SCWeeklySchedule *)schedule
                  weekOffset:(NSInteger)weekOffset
                       error:(NSError **)error {
    // First, uninstall any existing jobs for this bundle
    [self uninstallJobsForBundleID:bundle.bundleID error:nil];

    // Calculate all block windows
    NSArray<SCBlockWindow *> *blockWindows = [self allBlockWindowsForSchedule:schedule weekOffset:weekOffset];

    NSLog(@"SCScheduleLaunchdBridge: Installing jobs (jobCount=%lu weekOffset=%ld entryCount=%lu)",
          (unsigned long)blockWindows.count, (long)weekOffset, (unsigned long)bundle.entries.count);

    // Create and install a job for each block window
    for (SCBlockWindow *window in blockWindows) {
        // Skip windows that have already passed (for current week)
        if (weekOffset == 0 && [window.startDate timeIntervalSinceNow] < 0) {
            // Check if we're currently within this block window
            if ([window.endDate timeIntervalSinceNow] > 0) {
                // We're in the middle of this block - start it immediately!
                NSLog(@"SCScheduleLaunchdBridge: Starting in-progress block window");
                NSError *startError = nil;
                if (![self startBlockImmediatelyForBundle:bundle endDate:window.endDate error:&startError]) {
                    SCBridgeLogError(@"Failed to start in-progress block", startError);
                    // Continue anyway - don't fail the whole installation
                }
            } else {
                NSLog(@"SCScheduleLaunchdBridge: Skipping past block window");
            }
            continue;
        }

        // Generate plist
        NSDictionary *plist = [self launchdPlistForBundle:bundle blockWindow:window];
        if (!plist) {
            NSLog(@"SCScheduleLaunchdBridge: Failed to generate launchd plist for block window");
            continue;
        }

        NSString *label = plist[@"Label"];

        // Write plist
        if (![self writeLaunchdPlist:plist toLabel:label error:error]) {
            return NO;
        }

        // Load job
        if (![self loadJobWithLabel:label error:error]) {
            return NO;
        }
    }

    return YES;
}

- (BOOL)uninstallJobsForBundleID:(NSString *)bundleID error:(NSError **)error {
    NSArray<NSString *> *labels = [self installedJobLabelsForBundleID:bundleID];

    for (NSString *label in labels) {
        if (![self unloadJobWithLabel:label error:error]) {
            // Log but continue trying to unload others
            SCBridgeLogError(@"Failed to unload launchd job", error ? *error : nil);
        }
    }

    return YES;
}

- (BOOL)uninstallAllScheduleJobs:(NSError **)error {
    NSArray<NSString *> *labels = [self allInstalledScheduleJobLabels];

    for (NSString *label in labels) {
        if (![self unloadJobWithLabel:label error:error]) {
            SCBridgeLogError(@"Failed to unload launchd job", error ? *error : nil);
        }
    }

    return YES;
}

- (BOOL)uninstallJobForSegmentID:(NSString *)segmentID error:(NSError **)error {
    BOOL success = YES;
    for (NSString *label in [self installedJobLabelsForSegmentID:segmentID]) {
        NSError *unloadError = nil;
        if (![self unloadJobWithLabel:label error:&unloadError]) {
            success = NO;
            if (error != NULL && *error == nil) *error = unloadError;
        }
    }
    return success;
}

- (NSArray<NSString *> *)installedJobLabelsForBundleID:(NSString *)bundleID {
    NSString *prefix = [NSString stringWithFormat:@"%@.%@.", [SCScheduleLaunchdBridge jobLabelPrefix], bundleID];
    return [self jobLabelsWithPrefix:prefix];
}

- (NSArray<NSString *> *)installedJobLabelsForSegmentID:(NSString *)segmentID {
    NSString *prefix = [NSString stringWithFormat:@"%@.merged-%@.",
                        [SCScheduleLaunchdBridge jobLabelPrefix], segmentID];
    return [self jobLabelsWithPrefix:prefix];
}

- (NSArray<NSString *> *)allInstalledScheduleJobLabels {
    NSString *prefix = [NSString stringWithFormat:@"%@.", [SCScheduleLaunchdBridge jobLabelPrefix]];
    return [self jobLabelsWithPrefix:prefix];
}

- (NSArray<NSString *> *)jobLabelsWithPrefix:(NSString *)prefix {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];

    NSURL *launchAgentsDir = [SCScheduleLaunchdBridge launchAgentsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:launchAgentsDir
                                   includingPropertiesForKeys:nil
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        error:nil];

    for (NSURL *fileURL in contents) {
        NSString *filename = [fileURL lastPathComponent];
        if ([filename hasPrefix:prefix] && [filename hasSuffix:@".plist"]) {
            // Extract label from filename (remove .plist extension)
            NSString *label = [filename stringByDeletingPathExtension];
            [labels addObject:label];
        }
    }

    return labels;
}

#pragma mark - Segment-Based Merged Job Installation

- (nullable NSURL *)writeMergedBlocklistForBundles:(NSArray<SCBlockBundle *> *)bundles
                                         segmentID:(NSString *)segmentID
                                             error:(NSError **)error {
    // Merge all entries from all bundles, deduplicating
    NSMutableOrderedSet *mergedEntries = [NSMutableOrderedSet orderedSet];
    for (SCBlockBundle *bundle in bundles) {
        [mergedEntries addObjectsFromArray:bundle.entries];
    }

    NSURL *fileURL = [[SCScheduleLaunchdBridge schedulesDirectory]
                      URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.selfcontrol", segmentID]];

    NSDictionary *blockInfo = @{
        @"Blocklist": mergedEntries.array,
        @"BlockAsWhitelist": @NO
    };

    BOOL success = [SCBlockFileReaderWriter writeBlocklistToFileURL:fileURL
                                                          blockInfo:blockInfo
                                                              error:error];

    if (!success) {
        SCBridgeLogError(@"Failed to write merged blocklist", error ? *error : nil);
        return nil;
    }

    NSLog(@"SCScheduleLaunchdBridge: Wrote merged blocklist (entryCount=%lu bundleCount=%lu)",
          (unsigned long)mergedEntries.count, (unsigned long)bundles.count);

    return fileURL;
}

- (BOOL)installJobForSegmentWithBundles:(NSArray<SCBlockBundle *> *)bundles
                              segmentID:(NSString *)segmentID
                              startDate:(NSDate *)startDate
                                endDate:(NSDate *)endDate
                                    day:(SCDayOfWeek)day
                           startMinutes:(NSInteger)startMinutes
                             weekOffset:(NSInteger)weekOffset
                                  error:(NSError **)error {
    NSString *cliPath = [SCScheduleLaunchdBridge cliPath];
    if (!cliPath) {
        NSLog(@"ERROR: Cannot create plist without CLI path");
        if (error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"CLI path not found"}];
        }
        return NO;
    }

    // Merge blocklists from all bundles
    NSMutableArray *mergedEntries = [NSMutableArray array];
    for (SCBlockBundle *bundle in bundles) {
        [mergedEntries addObjectsFromArray:bundle.entries ?: @[]];
    }

    // Get block settings from user defaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL telemetryConsent = [defaults boolForKey:@"ErrorReportingPromptDismissed"] &&
                            [defaults boolForKey:@"EnableErrorReporting"];
    NSDictionary *blockSettings = @{
        @"ClearCaches": [defaults objectForKey:@"ClearCaches"] ?: @NO,
        @"AllowLocalNetworks": [defaults objectForKey:@"AllowLocalNetworks"] ?: @YES,
        @"EvaluateCommonSubdomains": [defaults objectForKey:@"EvaluateCommonSubdomains"] ?: @YES,
        @"IncludeLinkedDomains": [defaults objectForKey:@"IncludeLinkedDomains"] ?: @YES,
        @"BlockSoundShouldPlay": [defaults objectForKey:@"BlockSoundShouldPlay"] ?: @NO,
        @"BlockSound": [defaults objectForKey:@"BlockSound"] ?: @5,
        @"EnableErrorReporting": @(telemetryConsent)
    };

    // Register the schedule with the daemon (daemon must already be installed by caller)
    // The schedule is stored in root-owned settings, so future triggers don't need password
    SCXPCClient *xpc = [SCXPCClient new];
    dispatch_semaphore_t registerSema = dispatch_semaphore_create(0);
    __block NSError *registerError = nil;

    [xpc registerScheduleWithID:segmentID
                      blocklist:mergedEntries
                    isAllowlist:NO
                  blockSettings:blockSettings
              controllingUID:getuid()
                    startDate:startDate
                      endDate:endDate
                          reply:^(NSError *err) {
        registerError = err;
        dispatch_semaphore_signal(registerSema);
    }];

    // Wait for registration
    // Use run loop-based wait to avoid deadlock when called from main thread
    if (![NSThread isMainThread]) {
        dispatch_semaphore_wait(registerSema, DISPATCH_TIME_FOREVER);
    } else {
        while (dispatch_semaphore_wait(registerSema, DISPATCH_TIME_NOW)) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (registerError) {
        SCBridgeLogError(@"Failed to register schedule with daemon", registerError);
        if (error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:registerError.code
                                     userInfo:@{SCScheduleLaunchdBridgeFailureStageKey: @"schedule_register"}];
        }
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Registered schedule with daemon (entryCount=%lu)",
          (unsigned long)mergedEntries.count);

    // Format start and end dates as ISO8601
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSString *startDateStr = [isoFormatter stringFromDate:startDate];
    NSString *endDateStr = [isoFormatter stringFromDate:endDate];

    // Job label: org.eyebeam.selfcontrol.schedule.merged-{segmentID}.{day}.{time}
    NSString *dayStr = [[SCWeeklySchedule stringForDay:day] lowercaseString];
    NSString *timeStr = [NSString stringWithFormat:@"%02ld%02ld", (long)(startMinutes / 60), (long)(startMinutes % 60)];
    NSString *label = [NSString stringWithFormat:@"%@.merged-%@.%@.%@",
                       [SCScheduleLaunchdBridge jobLabelPrefix], segmentID, dayStr, timeStr];

    // Calculate StartCalendarInterval
    NSInteger hour = startMinutes / 60;
    NSInteger minute = startMinutes % 60;

    NSDictionary *calendarInterval = @{
        @"Weekday": @(day),
        @"Hour": @(hour),
        @"Minute": @(minute)
    };

    // Build the plist - use --schedule-id instead of --blocklist for pre-authorized blocks
    // Note: XPMArgumentParser requires --flag=value format (not --flag value)
    // startdate is used to validate the job hasn't fired prematurely (e.g., next week's Sunday job firing this week)
    NSDictionary *plist = @{
        @"Label": label,
        @"ProgramArguments": @[
            cliPath,
            @"start",
            [NSString stringWithFormat:@"--schedule-id=%@", segmentID],
            [NSString stringWithFormat:@"--startdate=%@", startDateStr],
            [NSString stringWithFormat:@"--enddate=%@", endDateStr]
        ],
        @"StartCalendarInterval": calendarInterval,
        @"RunAtLoad": @NO,
        @"StandardOutPath": @"/dev/null",
        @"StandardErrorPath": @"/dev/null"
    };

    // Write plist
    if (![self writeLaunchdPlist:plist toLabel:label error:error]) {
        if (error && *error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:(*error).code
                                     userInfo:@{SCScheduleLaunchdBridgeFailureStageKey: @"job_install"}];
        }
        return NO;
    }

    // Load job
    if (![self loadJobWithLabel:label error:error]) {
        if (error && *error) {
            *error = [NSError errorWithDomain:@"SCScheduleLaunchdBridge"
                                         code:(*error).code
                                     userInfo:@{SCScheduleLaunchdBridgeFailureStageKey: @"job_install"}];
        }
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Installed merged segment job (bundleCount=%lu)",
          (unsigned long)bundles.count);

    return YES;
}

- (BOOL)startMergedBlockImmediatelyForBundles:(NSArray<SCBlockBundle *> *)bundles
                                    segmentID:(NSString *)segmentID
                                      endDate:(NSDate *)endDate
                                        error:(NSError **)error {
    NSLog(@"SCScheduleLaunchdBridge: Starting merged block immediately (bundleCount=%lu)",
          (unsigned long)bundles.count);

    // Merge blocklists from all bundles
    NSMutableArray *mergedEntries = [NSMutableArray array];
    for (SCBlockBundle *bundle in bundles) {
        [mergedEntries addObjectsFromArray:bundle.entries ?: @[]];
    }
    NSLog(@"SCScheduleLaunchdBridge: Prepared merged block (entryCount=%lu)",
          (unsigned long)mergedEntries.count);

    // Get the controlling UID - use console user if running as root (daemon)
    uid_t controllingUID = getuid();
    if (geteuid() == 0) {
        controllingUID = [SCMiscUtilities consoleUserUID];
    }

    // Get block settings from user defaults (use console user's defaults if running as root)
    NSDictionary *userDefaults = nil;
    if (geteuid() == 0) {
        userDefaults = [SCMiscUtilities defaultsDictForUser:controllingUID];
    }
    BOOL telemetryConsent = userDefaults
        ? ([userDefaults[@"ErrorReportingPromptDismissed"] boolValue] && [userDefaults[@"EnableErrorReporting"] boolValue])
        : ([[NSUserDefaults standardUserDefaults] boolForKey:@"ErrorReportingPromptDismissed"] &&
           [[NSUserDefaults standardUserDefaults] boolForKey:@"EnableErrorReporting"]);
    NSDictionary *blockSettings = @{
        @"ClearCaches": (userDefaults ? userDefaults[@"ClearCaches"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"ClearCaches"]) ?: @NO,
        @"AllowLocalNetworks": (userDefaults ? userDefaults[@"AllowLocalNetworks"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"AllowLocalNetworks"]) ?: @YES,
        @"EvaluateCommonSubdomains": (userDefaults ? userDefaults[@"EvaluateCommonSubdomains"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"EvaluateCommonSubdomains"]) ?: @YES,
        @"IncludeLinkedDomains": (userDefaults ? userDefaults[@"IncludeLinkedDomains"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"IncludeLinkedDomains"]) ?: @YES,
        @"BlockSoundShouldPlay": (userDefaults ? userDefaults[@"BlockSoundShouldPlay"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"BlockSoundShouldPlay"]) ?: @NO,
        @"BlockSound": (userDefaults ? userDefaults[@"BlockSound"] : [[NSUserDefaults standardUserDefaults] objectForKey:@"BlockSound"]) ?: @5,
        @"EnableErrorReporting": @(telemetryConsent)
    };

    // If running as daemon (euid == 0), bypass XPC and call SCDaemonBlockMethods directly
    // XPC doesn't work when a process tries to connect to its own Mach service
    if (geteuid() == 0) {
        NSLog(@"SCScheduleLaunchdBridge: Using direct daemon block method");

        // Use dynamic invocation since SCDaemonBlockMethods is only in daemon target
        Class daemonBlockMethods = NSClassFromString(@"SCDaemonBlockMethods");
        if (!daemonBlockMethods) {
            NSLog(@"SCScheduleLaunchdBridge: Direct daemon block class unavailable");
            if (error) *error = [NSError errorWithDomain:@"SelfControl" code:500 userInfo:@{NSLocalizedDescriptionKey: @"SCDaemonBlockMethods class not available"}];
            return NO;
        }

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSError *blockError = nil;

        // Call: +[SCDaemonBlockMethods startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:]
        SEL startBlockSel = NSSelectorFromString(@"startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:");
        if (![daemonBlockMethods respondsToSelector:startBlockSel]) {
            NSLog(@"SCScheduleLaunchdBridge: Direct daemon block selector unavailable");
            if (error) *error = [NSError errorWithDomain:@"SelfControl" code:500 userInfo:@{NSLocalizedDescriptionKey: @"startBlock method not found"}];
            return NO;
        }

        // Use NSInvocation for the complex method signature
        NSMethodSignature *sig = [daemonBlockMethods methodSignatureForSelector:startBlockSel];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setSelector:startBlockSel];
        [invocation setTarget:daemonBlockMethods];

        uid_t uidArg = controllingUID;
        BOOL isAllowlist = NO;
        NSData *authData = nil;
        void (^replyBlock)(NSError *) = ^(NSError *err) {
            blockError = err;
            dispatch_semaphore_signal(sema);
        };

        [invocation setArgument:&uidArg atIndex:2];
        [invocation setArgument:&mergedEntries atIndex:3];
        [invocation setArgument:&isAllowlist atIndex:4];
        [invocation setArgument:&endDate atIndex:5];
        [invocation setArgument:&blockSettings atIndex:6];
        [invocation setArgument:&authData atIndex:7];
        [invocation setArgument:&replyBlock atIndex:8];

        [invocation invoke];

        // Wait for completion with timeout
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
        long result = dispatch_semaphore_wait(sema, timeout);

        if (result != 0) {
            NSLog(@"SCScheduleLaunchdBridge: Direct block call timed out");
            if (error) *error = [NSError errorWithDomain:@"SelfControl" code:408 userInfo:@{NSLocalizedDescriptionKey: @"Direct block call timed out"}];
            return NO;
        }

        if (blockError) {
            SCBridgeLogError(@"Direct block call failed", blockError);
            if (error) *error = blockError;
            return NO;
        }

        NSLog(@"SCScheduleLaunchdBridge: Merged block started successfully (direct)");
        return YES;
    }

    // Not running as daemon - use XPC as normal
    NSLog(@"SCScheduleLaunchdBridge: Using XPC block method");

    SCXPCClient *xpc = [SCXPCClient new];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSError *xpcError = nil;

    // First register the schedule
    [xpc registerScheduleWithID:segmentID
                      blocklist:mergedEntries
                    isAllowlist:NO
                  blockSettings:blockSettings
              controllingUID:controllingUID
                    startDate:[NSDate date]
                      endDate:endDate
                          reply:^(NSError *err) {
        if (err) {
            xpcError = err;
            dispatch_semaphore_signal(sema);
            return;
        }

        // Then start it immediately
        [xpc startScheduledBlockWithID:segmentID
                               endDate:endDate
                                 reply:^(NSError *startErr) {
            xpcError = startErr;
            dispatch_semaphore_signal(sema);
        }];
    }];

    // Use run loop-based wait to avoid deadlock when called from main thread
    if (![NSThread isMainThread]) {
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
        long result = dispatch_semaphore_wait(sema, timeout);
        if (result != 0) {
            if (error) *error = [NSError errorWithDomain:@"SelfControl" code:408 userInfo:@{NSLocalizedDescriptionKey: @"XPC call timed out"}];
            return NO;
        }
    } else {
        while (dispatch_semaphore_wait(sema, DISPATCH_TIME_NOW)) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (xpcError) {
        SCBridgeLogError(@"Failed to start immediate merged block", xpcError);
        if (error) *error = xpcError;
        return NO;
    }

    NSLog(@"SCScheduleLaunchdBridge: Merged block started successfully (bundleCount=%lu)",
          (unsigned long)bundles.count);
    return YES;
}

@end

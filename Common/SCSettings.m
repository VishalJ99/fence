//
//  SCLockFileUtilities.m
//  SelfControl
//
//  Created by Charles Stigler on 20/10/2018.
//

#import "SCSettings.h"
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <math.h>
#import <sys/stat.h>

// Only include Sentry if available and not testing
#if !defined(TESTING) && __has_include(<Sentry/Sentry.h>)
#define SENTRY_ENABLED 1
#import <Sentry/Sentry.h>
#import <Sentry/Sentry-Swift.h>
#else
#define SENTRY_ENABLED 0
#endif

float const SYNC_INTERVAL_SECS = 30;
float const SYNC_LEEWAY_SECS = 30;
NSString* const SETTINGS_FILE_DIR = @"/usr/local/etc/";
NSString * const SCSettingsLoadFailedNotification = @"org.eyebeam.Fence.SCSettingsLoadFailed";
NSInteger const SCSettingsStateUnavailableErrorCode = 602;

static BOOL SCSettingsIntegerNumberInRange(id candidate, unsigned long long maximum) {
    if (![candidate isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)candidate) == CFBooleanGetTypeID()) {
        return NO;
    }
    double value = [candidate doubleValue];
    return isfinite(value) && floor(value) == value && value >= 0 && value <= maximum;
}

static BOOL SCSettingsNumberIsBoolean(id candidate) {
    return [candidate isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)candidate) == CFBooleanGetTypeID();
}

static BOOL SCSettingsWeekKeyIsValid(id candidate) {
    if (![candidate isKindOfClass:[NSString class]] || [candidate length] != 10) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger index = 0; index < 10; index++) {
        unichar character = [candidate characterAtIndex:index];
        if (index == 4 || index == 7) {
            if (character != '-') return NO;
        } else if (![digits characterIsMember:character]) {
            return NO;
        }
    }
    return YES;
}

static BOOL SCSettingsUUIDString(id candidate) {
    return [candidate isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:candidate] != nil;
}

static BOOL SCSettingsStringArrayIsValid(id candidate, BOOL requireUUIDs, BOOL requireNonempty) {
    if (![candidate isKindOfClass:[NSArray class]] || (requireNonempty && [candidate count] == 0)) return NO;
    for (id value in candidate) {
        if (![value isKindOfClass:[NSString class]] || (requireUUIDs && !SCSettingsUUIDString(value))) return NO;
    }
    return YES;
}

static BOOL SCSettingsProtectedHoursAreValid(id candidate) {
    if (![candidate isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *hours = candidate;
    return SCSettingsNumberIsBoolean(hours[@"enabled"]) &&
        SCSettingsIntegerNumberInRange(hours[@"startMinute"], 1439) &&
        SCSettingsIntegerNumberInRange(hours[@"endMinute"], 1439) &&
        [hours[@"startMinute"] integerValue] != [hours[@"endMinute"] integerValue];
}

@interface SCSettings ()

// Private vars
@property (readonly) NSMutableDictionary* settingsDict;
@property NSDate* lastSynchronizedWithDisk;
@property dispatch_source_t syncTimer;
@property dispatch_source_t debouncedChangeTimer;
@property (nullable, copy) NSString* lastReportedLoadFailureSignature;
@property (nonatomic, readwrite) BOOL settingsStateAvailableForEnforcement;
@property (nullable, copy) NSString* settingsFilePathOverride;

- (NSError *)settingsStateUnavailableError;
- (void)writeSettingsAllowingUnavailableBootstrapWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock;
- (void)writeSettingsWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock
        allowingUnavailableBootstrap:(BOOL)allowUnavailableBootstrap;

@end

@implementation SCSettings

- (NSError *)settingsStateUnavailableError {
    return [SCErr errorWithCode:SCSettingsStateUnavailableErrorCode];
}

+ (instancetype)sharedSettings {
    static SCSettings* globalSettings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        globalSettings = [SCSettings new];
    });
    return globalSettings;
}

- (instancetype)init {
    if (self = [super init]) {
        // we will only write out settings if we have root permissions (i.e. the EUID is 0)
        // otherwise, we won't/shouldn't have permissions to write to the settings file
        // in practice, what this means is that the daemon writes settings, and the app/CLI only read
        _readOnly = (geteuid() != 0);

#if TESTING
        NSLog(@"SCSettings: Running in TESTING mode - disk writes are DISABLED");
#else
        if (_readOnly) {
            NSLog(@"SCSettings: Read-only mode (non-root process)");
        } else {
            NSLog(@"SCSettings: Persistence enabled");
        }
#endif

        _settingsDict = nil;
        
        [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                            selector: @selector(onSettingChanged:)
                                                                name: @"org.eyebeam.SelfControl.SCSettingsValueChanged"
                                                              object: nil
                                                  suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
    }
    return self;
}

#if defined(TESTING)
- (instancetype)initWithSettingsFilePathForTesting:(NSString *)settingsFilePath {
    self = [self init];
    if (self) _settingsFilePathOverride = [settingsFilePath copy];
    return self;
}
#endif

- (NSString *)settingsFilePath {
    return self.settingsFilePathOverride ?: SCSettings.securedSettingsFilePath;
}

+ (NSString*)settingsFileName {
    static NSString* fileName = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fileName = [NSString stringWithFormat: @".%@.plist", [SCMiscUtilities sha1: [NSString stringWithFormat: @"SelfControlUserPreferences%@", [SCMiscUtilities getSerialNumber]]]];
    });

    return fileName;
}
+ (NSString*)securedSettingsFilePath {
    static NSString* filePath = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        filePath = [NSString stringWithFormat: @"%@%@", SETTINGS_FILE_DIR, SCSettings.settingsFileName];
    });

    return filePath;
}

// NOTE: there should be a default setting for each valid setting, even if it's nil/zero/etc
- (NSDictionary*)defaultSettingsDict {
    return @{
        @"BlockEndDate": [NSDate distantPast],
        @"ActiveBlocklist": @[],
        @"ActiveBlockAsWhitelist": @NO,
        @"ActiveBlockControllingUID": @0,
        @"ActiveBlockSource": @"none",
        @"ActiveScheduleID": @"",
        @"ActiveScheduleCommitmentID": @"",
        @"ActiveScheduleGeneration": @"",
        @"ActiveSchedulePolicyRevision": @"",
        @"ActiveScheduleWeekKey": @"",

        @"BlockIsRunning": @NO, // tells us whether a block is actually running on the system (to the best of our knowledge)
        @"TamperingDetected": @NO,
        @"IsTestBlock": @NO,
        @"ApprovedSchedules": @{},
        // V2 commitments are kept separately from their segment records so
        // even an intentionally empty week remains immutable at the root
        // authority until its absolute window expires.
        @"ApprovedScheduleCommitments": @{},
        // One indefinite recurring envelope per owner. The edit-lock deadline
        // is metadata; record existence remains enforcement authority.
        @"ApprovedRecurringScheduleCommitments": @{},
        // Temporary scheduler pauses keyed by recurring commitment ID.
        @"ActiveScheduleBreaks": @{},

        // block settings
        // the user sets these in defaults, then when a block is started they're copied over to settings
        @"EvaluateCommonSubdomains": @YES,
        @"IncludeLinkedDomains": @YES,
        @"BlockSoundShouldPlay": @NO,
        @"BlockSound": @5,
        @"ClearCaches": @YES,
        @"AllowLocalNetworks": @YES,

        @"EnableErrorReporting": @NO,

        @"SettingsVersionNumber": @0,
        @"LastSettingsUpdate": [NSDate distantPast], // special value that keeps track of when we last updated our settings

        // Debug mode setting - only respected in DEBUG builds
        // Allows disabling ALL blocking for safe development
        @"DebugBlockingDisabled": @NO
    };
}

- (nullable NSDictionary*)validatedSettingsDictionaryFromDiskWithReason:(NSString * _Nullable * _Nullable)reason
                                                               errorCode:(NSInteger * _Nullable)errorCode {
    if (reason != NULL) *reason = nil;
    if (errorCode != NULL) *errorCode = 0;

    NSString *settingsFilePath = [self settingsFilePath];
    const char *path = settingsFilePath.fileSystemRepresentation;
    struct stat status;
    if (lstat(path, &status) != 0) {
        int statusError = errno;
        if (reason != NULL) {
            *reason = statusError == ENOENT ? @"missing" :
                ((statusError == EACCES || statusError == EPERM) ? @"permissions" : @"decode_failed");
        }
        if (errorCode != NULL) *errorCode = statusError;
        return nil;
    }
    if (!S_ISREG(status.st_mode) || S_ISLNK(status.st_mode)) {
        if (reason != NULL) *reason = @"schema_invalid";
        return nil;
    }

    NSError *readError = nil;
    NSData *plistData = [NSData dataWithContentsOfFile:settingsFilePath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readError];
    if (plistData == nil) {
        BOOL permissionFailure = readError.code == NSFileReadNoPermissionError || errno == EACCES || errno == EPERM;
        if (reason != NULL) {
            *reason = readError.code == NSFileReadNoSuchFileError ? @"missing" :
                (permissionFailure ? @"permissions" : @"decode_failed");
        }
        if (errorCode != NULL) *errorCode = readError.code;
        return nil;
    }

    NSError *decodeError = nil;
    id decoded = [NSPropertyListSerialization propertyListWithData:plistData
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:&decodeError];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        if (reason != NULL) *reason = @"decode_failed";
        if (errorCode != NULL) *errorCode = decodeError.code;
        return nil;
    }

    id version = decoded[@"SettingsVersionNumber"];
    if (version != nil && !SCSettingsIntegerNumberInRange(version, NSIntegerMax)) {
        if (reason != NULL) *reason = @"version_invalid";
        return nil;
    }
    if (![SCSettings settingsDictionaryHasValidSchema:decoded]) {
        if (reason != NULL) *reason = @"schema_invalid";
        return nil;
    }
    return decoded;
}

+ (BOOL)settingsDictionaryHasValidSchema:(id)settingsDictionary {
    if (![settingsDictionary isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *settings = settingsDictionary;

    id version = settings[@"SettingsVersionNumber"];
    if (version != nil && !SCSettingsIntegerNumberInRange(version, NSIntegerMax)) return NO;

    id controllingUID = settings[@"ActiveBlockControllingUID"];
    if (controllingUID != nil && !SCSettingsIntegerNumberInRange(controllingUID, UINT_MAX)) return NO;

    NSArray<NSString *> *activeStringKeys = @[
        @"ActiveBlockSource", @"ActiveScheduleID", @"ActiveScheduleCommitmentID",
        @"ActiveScheduleGeneration", @"ActiveSchedulePolicyRevision", @"ActiveScheduleWeekKey"
    ];
    for (NSString *key in activeStringKeys) {
        id value = settings[key];
        if (value != nil && ![value isKindOfClass:[NSString class]]) return NO;
    }

    NSArray<NSString *> *dateKeys = @[@"BlockEndDate", @"LastSettingsUpdate"];
    for (NSString *key in dateKeys) {
        id value = settings[key];
        if (value != nil && ![value isKindOfClass:[NSDate class]]) return NO;
    }

    NSArray<NSString *> *booleanKeys = @[
        @"ActiveBlockAsWhitelist", @"BlockIsRunning", @"TamperingDetected",
        @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay",
        @"ClearCaches", @"AllowLocalNetworks", @"EnableErrorReporting",
        @"DebugBlockingDisabled", @"IsTestBlock"
    ];
    for (NSString *key in booleanKeys) {
        id value = settings[key];
        if (value != nil && !SCSettingsNumberIsBoolean(value)) return NO;
    }
    id blockSound = settings[@"BlockSound"];
    if (blockSound != nil && !SCSettingsIntegerNumberInRange(blockSound, NSIntegerMax)) return NO;

    id activeBlocklist = settings[@"ActiveBlocklist"];
    if (activeBlocklist != nil) {
        if (![activeBlocklist isKindOfClass:[NSArray class]]) return NO;
        for (id entry in activeBlocklist) {
            if (![entry isKindOfClass:[NSString class]]) return NO;
        }
    }

    id approvedSchedules = settings[@"ApprovedSchedules"];
    if (approvedSchedules != nil) {
        if (![approvedSchedules isKindOfClass:[NSDictionary class]]) return NO;
        for (id scheduleID in approvedSchedules) {
            if (![scheduleID isKindOfClass:[NSString class]]) return NO;
            id schedule = approvedSchedules[scheduleID];
            if (![schedule isKindOfClass:[NSDictionary class]]) return NO;
            NSDictionary *scheduleDictionary = schedule;
            id schemaVersion = scheduleDictionary[@"schemaVersion"];
            if (schemaVersion != nil &&
                (!SCSettingsIntegerNumberInRange(schemaVersion, 2) || [schemaVersion integerValue] < 1)) return NO;
            id blocklist = scheduleDictionary[@"blocklist"];
            if (blocklist != nil) {
                if (![blocklist isKindOfClass:[NSArray class]]) return NO;
                for (id entry in blocklist) {
                    if (![entry isKindOfClass:[NSString class]]) return NO;
                }
            }
            NSDictionary<NSString *, Class> *knownTypes = @{
                @"isAllowlist": NSNumber.class,
                @"blockSettings": NSDictionary.class,
                @"controllingUID": NSNumber.class,
                @"approvedStartDate": NSDate.class,
                @"approvedEndDate": NSDate.class,
                @"registeredAt": NSDate.class,
                @"weekKey": NSString.class,
                @"commitmentID": NSString.class,
                @"generation": NSString.class,
                @"policyRevision": NSString.class,
                @"sourceBundleIDs": NSArray.class,
            };
            for (NSString *key in knownTypes) {
                id value = scheduleDictionary[key];
                if (value != nil && ![value isKindOfClass:knownTypes[key]]) return NO;
            }
            id scheduleUID = scheduleDictionary[@"controllingUID"];
            if (scheduleUID != nil && !SCSettingsIntegerNumberInRange(scheduleUID, UINT_MAX)) return NO;
            id isAllowlist = scheduleDictionary[@"isAllowlist"];
            if (isAllowlist != nil && !SCSettingsNumberIsBoolean(isAllowlist)) return NO;
            NSDate *startDate = scheduleDictionary[@"approvedStartDate"];
            NSDate *endDate = scheduleDictionary[@"approvedEndDate"];
            if (startDate != nil && endDate != nil && [endDate compare:startDate] != NSOrderedDescending) {
                return NO;
            }
            if ([schemaVersion integerValue] == 2) {
                NSString *weekKey = scheduleDictionary[@"weekKey"];
                NSArray *sourceBundleIDs = scheduleDictionary[@"sourceBundleIDs"];
                if ([[NSUUID alloc] initWithUUIDString:scheduleID] == nil ||
                    !SCSettingsWeekKeyIsValid(weekKey) ||
                    [[NSUUID alloc] initWithUUIDString:scheduleDictionary[@"commitmentID"]] == nil ||
                    [[NSUUID alloc] initWithUUIDString:scheduleDictionary[@"generation"]] == nil ||
                    [[NSUUID alloc] initWithUUIDString:scheduleDictionary[@"policyRevision"]] == nil ||
                    startDate == nil || endDate == nil ||
                    ![blocklist isKindOfClass:[NSArray class]] || [blocklist count] == 0 ||
                    ![scheduleDictionary[@"blockSettings"] isKindOfClass:[NSDictionary class]] ||
                    !SCSettingsIntegerNumberInRange(scheduleDictionary[@"controllingUID"], UINT_MAX) ||
                    [scheduleDictionary[@"controllingUID"] unsignedIntValue] == 0 ||
                    !SCSettingsNumberIsBoolean(scheduleDictionary[@"isAllowlist"]) ||
                    [scheduleDictionary[@"isAllowlist"] boolValue] ||
                    ![sourceBundleIDs isKindOfClass:[NSArray class]] || sourceBundleIDs.count == 0) return NO;
                for (id bundleID in sourceBundleIDs) {
                    if (![bundleID isKindOfClass:[NSString class]] ||
                        [[NSUUID alloc] initWithUUIDString:bundleID] == nil) return NO;
                }
            }
        }
    }

    id approvedCommitments = settings[@"ApprovedScheduleCommitments"];
    if (approvedCommitments != nil) {
        if (![approvedCommitments isKindOfClass:[NSDictionary class]] ||
            [approvedCommitments count] > 512) return NO;
        for (id commitmentKey in approvedCommitments) {
            if (![commitmentKey isKindOfClass:[NSString class]] ||
                [[NSUUID alloc] initWithUUIDString:commitmentKey] == nil) return NO;
            id value = approvedCommitments[commitmentKey];
            if (![value isKindOfClass:[NSDictionary class]]) return NO;
            NSDictionary *commitment = value;
            id schemaVersion = commitment[@"schemaVersion"];
            id owner = commitment[@"controllingUID"];
            id weekKey = commitment[@"weekKey"];
            id weekStart = commitment[@"weekStartDate"];
            id weekEnd = commitment[@"weekEndDate"];
            id commitmentID = commitment[@"commitmentID"];
            id generation = commitment[@"generation"];
            id scheduleIDs = commitment[@"scheduleIDs"];
            id registeredAt = commitment[@"registeredAt"];
            if (!SCSettingsIntegerNumberInRange(schemaVersion, 1) ||
                [schemaVersion integerValue] != 1 ||
                !SCSettingsIntegerNumberInRange(owner, UINT_MAX) ||
                [owner unsignedIntValue] == 0 ||
                !SCSettingsWeekKeyIsValid(weekKey) ||
                ![weekStart isKindOfClass:[NSDate class]] ||
                ![weekEnd isKindOfClass:[NSDate class]] ||
                [weekEnd compare:weekStart] != NSOrderedDescending ||
                ![commitmentID isKindOfClass:[NSString class]] ||
                ![commitmentID isEqual:commitmentKey] ||
                [[NSUUID alloc] initWithUUIDString:commitmentID] == nil ||
                ![generation isKindOfClass:[NSString class]] ||
                [[NSUUID alloc] initWithUUIDString:generation] == nil ||
                ![scheduleIDs isKindOfClass:[NSArray class]] ||
                [scheduleIDs count] > 512 ||
                ![registeredAt isKindOfClass:[NSDate class]]) return NO;
            NSMutableSet<NSString *> *uniqueScheduleIDs = [NSMutableSet set];
            for (id scheduleID in scheduleIDs) {
                if (![scheduleID isKindOfClass:[NSString class]] ||
                    [[NSUUID alloc] initWithUUIDString:scheduleID] == nil ||
                    [uniqueScheduleIDs containsObject:scheduleID]) return NO;
                [uniqueScheduleIDs addObject:scheduleID];
            }
        }
    }

    id recurringValue = settings[@"ApprovedRecurringScheduleCommitments"];
    NSMutableDictionary<NSString *, NSDictionary *> *recurringByID = [NSMutableDictionary dictionary];
    if (recurringValue != nil) {
        if (![recurringValue isKindOfClass:[NSDictionary class]] || [recurringValue count] > 512) return NO;
        NSMutableSet<NSNumber *> *owners = [NSMutableSet set];
        for (id commitmentKey in recurringValue) {
            NSDictionary *commitment = [recurringValue[commitmentKey] isKindOfClass:[NSDictionary class]]
                ? recurringValue[commitmentKey] : nil;
            NSNumber *owner = commitment[@"controllingUID"];
            NSDate *startedAt = commitment[@"startedAt"];
            NSDate *lockEndsAt = commitment[@"lockEndsAt"];
            NSArray *segments = commitment[@"segments"];
            if (!SCSettingsUUIDString(commitmentKey) || commitment == nil ||
                !SCSettingsIntegerNumberInRange(commitment[@"schemaVersion"], 1) ||
                [commitment[@"schemaVersion"] integerValue] != 1 ||
                ![commitment[@"commitmentID"] isEqual:commitmentKey] ||
                !SCSettingsUUIDString(commitment[@"generation"]) ||
                !SCSettingsIntegerNumberInRange(owner, UINT_MAX) || owner.unsignedIntValue == 0 ||
                [owners containsObject:owner] ||
                ![startedAt isKindOfClass:[NSDate class]] || ![lockEndsAt isKindOfClass:[NSDate class]] ||
                [lockEndsAt compare:startedAt] != NSOrderedDescending ||
                !SCSettingsProtectedHoursAreValid(commitment[@"protectedHours"]) ||
                ![commitment[@"blockSettings"] isKindOfClass:[NSDictionary class]] ||
                ![segments isKindOfClass:[NSArray class]] || segments.count == 0 || segments.count > 512) return NO;
            [owners addObject:owner];
            NSMutableSet<NSString *> *segmentIDs = [NSMutableSet set];
            NSInteger previousEnd = 0;
            BOOL first = YES;
            NSUInteger aggregateEntries = 0;
            for (id rawSegment in segments) {
                NSDictionary *segment = [rawSegment isKindOfClass:[NSDictionary class]] ? rawSegment : nil;
                NSNumber *start = segment[@"startMinuteOfWeek"];
                NSNumber *end = segment[@"endMinuteOfWeek"];
                NSArray *blocklist = segment[@"blocklist"];
                NSArray *bundleIDs = segment[@"sourceBundleIDs"];
                id isAllowlist = segment[@"isAllowlist"];
                if (segment == nil || !SCSettingsUUIDString(segment[@"segmentID"]) ||
                    [segmentIDs containsObject:segment[@"segmentID"]] ||
                    !SCSettingsIntegerNumberInRange(start, 10079) ||
                    !SCSettingsIntegerNumberInRange(end, 10080) ||
                    end.integerValue <= start.integerValue ||
                    (!first && start.integerValue < previousEnd) ||
                    !SCSettingsStringArrayIsValid(blocklist, NO, YES) ||
                    !SCSettingsStringArrayIsValid(bundleIDs, YES, YES) ||
                    !SCSettingsUUIDString(segment[@"policyRevision"]) ||
                    !SCSettingsNumberIsBoolean(isAllowlist) || [isAllowlist boolValue] ||
                    blocklist.count > 4096 || aggregateEntries > 4096 - blocklist.count) return NO;
                aggregateEntries += blocklist.count;
                first = NO;
                previousEnd = end.integerValue;
                [segmentIDs addObject:segment[@"segmentID"]];
            }
            recurringByID[commitmentKey] = commitment;
        }
    }

    id breaksValue = settings[@"ActiveScheduleBreaks"];
    if (breaksValue != nil) {
        if (![breaksValue isKindOfClass:[NSDictionary class]] || [breaksValue count] > 512) return NO;
        for (id breakKey in breaksValue) {
            NSDictionary *activeBreak = [breaksValue[breakKey] isKindOfClass:[NSDictionary class]]
                ? breaksValue[breakKey] : nil;
            NSDictionary *commitment = recurringByID[breakKey];
            NSDate *startedAt = activeBreak[@"startedAt"];
            NSDate *endsAt = activeBreak[@"endsAt"];
            if (!SCSettingsUUIDString(breakKey) || activeBreak == nil || commitment == nil ||
                !SCSettingsIntegerNumberInRange(activeBreak[@"schemaVersion"], 1) ||
                [activeBreak[@"schemaVersion"] integerValue] != 1 ||
                ![activeBreak[@"commitmentID"] isEqual:breakKey] ||
                ![activeBreak[@"generation"] isEqual:commitment[@"generation"]] ||
                ![activeBreak[@"controllingUID"] isEqual:commitment[@"controllingUID"]] ||
                ![startedAt isKindOfClass:[NSDate class]] || ![endsAt isKindOfClass:[NSDate class]] ||
                [endsAt compare:startedAt] != NSOrderedDescending) return NO;
        }
    }

    if ([settings[@"BlockIsRunning"] boolValue]) {
        if (![settings[@"BlockEndDate"] isKindOfClass:[NSDate class]] ||
            ![settings[@"ActiveBlocklist"] isKindOfClass:[NSArray class]] ||
            !SCSettingsNumberIsBoolean(settings[@"ActiveBlockAsWhitelist"])) {
            return NO;
        }
        // An empty allowlist intentionally blocks everything. An empty
        // denylist blocks nothing, so treating it as authoritative active
        // state could let integrity repair remove real rules and reinstall an
        // empty block after a damaged plist load.
        if (![settings[@"ActiveBlockAsWhitelist"] boolValue] &&
            [settings[@"ActiveBlocklist"] count] == 0) {
            return NO;
        }
        NSString *source = settings[@"ActiveBlockSource"];
        NSSet *validSources = [NSSet setWithArray:@[
            @"manual", @"test", @"legacy_schedule", @"scheduler_v2", @"scheduler_recurring", @"unknown"
        ]];
        // Source/provenance was added after the original active-block schema.
        // An absent value remains valid and is treated as unknown so an upgrade
        // never discards the only declared record of an already-running block.
        if (source != nil && (![source isKindOfClass:[NSString class]] || ![validSources containsObject:source])) return NO;
        if ([source isEqualToString:@"legacy_schedule"] || [source isEqualToString:@"scheduler_v2"] ||
            [source isEqualToString:@"scheduler_recurring"]) {
            if ([[NSUUID alloc] initWithUUIDString:settings[@"ActiveScheduleID"]] == nil) return NO;
        }
    }

    return YES;
}

- (void)reportSettingsLoadFailureWithReason:(NSString*)reason
                           recoveryAttempted:(BOOL)recoveryAttempted
                           recoverySucceeded:(BOOL)recoverySucceeded
                                   errorCode:(NSInteger)errorCode {
    if (geteuid() != 0 || reason.length == 0) return;
    NSNumber *settingsVersion = [_settingsDict[@"SettingsVersionNumber"] isKindOfClass:[NSNumber class]]
        ? _settingsDict[@"SettingsVersionNumber"] : @0;
    NSString *signature = [NSString stringWithFormat:@"%@:%ld:%@:%d:%d",
                           reason, (long)errorCode, settingsVersion,
                           recoveryAttempted, recoverySucceeded];
    if ([self.lastReportedLoadFailureSignature isEqualToString:signature]) return;
    self.lastReportedLoadFailureSignature = signature;

    NSMutableDictionary *fields = [@{
        @"reason": reason,
        @"recovery_attempted": @(recoveryAttempted),
        @"recovery_succeeded": @(recoverySucceeded),
        @"settings_version": @([settingsVersion unsignedIntegerValue]),
    } mutableCopy];
    if (errorCode != 0) fields[@"error_code"] = @(errorCode);
    [[NSNotificationCenter defaultCenter] postNotificationName:SCSettingsLoadFailedNotification
                                                        object:self
                                                      userInfo:fields];
}

- (void)initializeSettingsDict {
    // This is deliberately per-instance rather than dispatch_once. A force
    // reload must be able to recover after a transient read failure, and a
    // failed reload must never strand `_settingsDict` at nil.
    @synchronized (self) {
        if (_settingsDict != nil) return;

        BOOL isTest = [[NSUserDefaults standardUserDefaults] boolForKey:@"isTest"];
        NSString *failureReason = nil;
        NSInteger errorCode = 0;
        NSDictionary *settingsFromDisk = isTest ? nil :
            [self validatedSettingsDictionaryFromDiskWithReason:&failureReason errorCode:&errorCode];
        if (isTest) NSLog(@"Ignoring settings on disk because we're unit-testing");

        if (settingsFromDisk != nil) {
            _settingsDict = [settingsFromDisk mutableCopy];
            self.settingsStateAvailableForEnforcement = YES;
            self.lastReportedLoadFailureSignature = nil;
        } else {
            _settingsDict = [[self defaultSettingsDict] mutableCopy];
            self.settingsStateAvailableForEnforcement = isTest;
            BOOL recoveryAttempted = NO;
            BOOL recoverySucceeded = NO;

            // A genuinely absent file on first root initialization is normal.
            // Create it once. Corrupt, unreadable, or schema-invalid files are
            // not overwritten: they may contain the only recoverable record of
            // an active block, so retain them for support/manual recovery.
            if (!isTest && !self.readOnly && [failureReason isEqualToString:@"missing"]) {
                recoveryAttempted = YES;
                __block NSError *writeError = nil;
                [self writeSettingsAllowingUnavailableBootstrapWithCompletion:^(NSError *error) {
                    writeError = error;
                }];
                recoverySucceeded = (writeError == nil);
                self.settingsStateAvailableForEnforcement = recoverySucceeded;
                if (!recoverySucceeded) {
                    errorCode = writeError.code;
                    [self reportSettingsLoadFailureWithReason:@"permissions"
                                            recoveryAttempted:YES
                                            recoverySucceeded:NO
                                                    errorCode:errorCode];
                }
            } else if (!isTest) {
                [self reportSettingsLoadFailureWithReason:failureReason ?: @"decode_failed"
                                        recoveryAttempted:recoveryAttempted
                                        recoverySucceeded:recoverySucceeded
                                                errorCode:errorCode];
            }
            [SCSentry addBreadcrumb:@"Initialized SCSettings to safe in-memory defaults" category:@"settings"];
        }

        self.lastSynchronizedWithDisk = [NSDate date];
        [self startSyncTimer];
    }
}

- (NSDictionary*)settingsDict {
    if (_settingsDict == nil) {
        [self initializeSettingsDict];
    }
    return _settingsDict;
}

- (NSDictionary*)dictionaryRepresentation {
    NSMutableDictionary* dictCopy = [self.settingsDict mutableCopy];
    
    // fill in any gaps with default values (like we did if they called valueForKey:)
    for (NSString* key in [[self defaultSettingsDict] allKeys]) {
        if (dictCopy[key] == nil) {
            dictCopy[key] = [self defaultSettingsDict][key];
        }
    }

    return dictCopy;
}

// both reloadSettings and writeSettings are synchronized with the same object, so
// at any given time we are running a maximum of one of these methods, on one thread.
// we don't want to be reading the file on one thread and writing out two different versions
// on two other threads

- (void)reloadSettings {
    // if the settings dictionary hasn't been loaded the first time, do that instead of reloading
    if (_settingsDict == nil) {
        [self initializeSettingsDict];
        return;
    }

    @synchronized (self) {
        NSString *failureReason = nil;
        NSInteger errorCode = 0;
        NSDictionary* settingsFromDisk =
            [self validatedSettingsDictionaryFromDiskWithReason:&failureReason errorCode:&errorCode];
        if (settingsFromDisk == nil) {
            // Keep the last-known-good in-memory state. Replacing it with
            // defaults here can make the UI claim no block is active while the
            // physical hosts/PF/app layers remain enforced.
            [self reportSettingsLoadFailureWithReason:failureReason ?: @"decode_failed"
                                    recoveryAttempted:NO
                                    recoverySucceeded:NO
                                            errorCode:errorCode];
            NSLog(@"SCSettings: Reload rejected unsafe disk state (reason=%@ code=%ld); retaining memory version",
                  failureReason, (long)errorCode);
            return;
        }
        if (!self.settingsStateAvailableForEnforcement) {
            _settingsDict = [settingsFromDisk mutableCopy];
            self.settingsStateAvailableForEnforcement = YES;
            self.lastReportedLoadFailureSignature = nil;
            self.lastSynchronizedWithDisk = [NSDate date];
            NSLog(@"SCSettings: Recovered a valid authoritative settings snapshot");
            return;
        }
        self.lastReportedLoadFailureSignature = nil;
        
        int diskSettingsVersion = [settingsFromDisk[@"SettingsVersionNumber"] intValue];
        int memorySettingsVersion = [_settingsDict[@"SettingsVersionNumber"] intValue];
        NSDate* diskSettingsLastUpdated = settingsFromDisk[@"LastSettingsUpdate"];
        NSDate* memorySettingsLastUpdated = [_settingsDict[@"LastSettingsUpdate"] isKindOfClass:[NSDate class]]
            ? _settingsDict[@"LastSettingsUpdate"] : [NSDate distantPast];
        
        // occasionally we can end up with timestamps from the future
        // (usually because the user moved their system clock forward, then back again)
        // it's a weird edge case and we should just fix that when we see it
        if ([diskSettingsLastUpdated timeIntervalSinceNow] > 0) {
            // we'll pretend the disk was written 1 second ago in this case to avoid weird edge conditions
            diskSettingsLastUpdated = [[NSDate date] dateByAddingTimeInterval: 1.0];
        }
        if ([memorySettingsLastUpdated timeIntervalSinceNow] > 0) {
            memorySettingsLastUpdated = [NSDate date];
            [self setValue: memorySettingsLastUpdated forKey: @"LastSettingsUpdate"];
        }

        if (diskSettingsLastUpdated == nil) diskSettingsLastUpdated = [NSDate distantPast];
        
        // try to decide which is more recent by version number, tiebreak by date
        BOOL diskMoreRecentThanMemory = NO;
        if (diskSettingsVersion == memorySettingsVersion) {
            diskMoreRecentThanMemory = ([diskSettingsLastUpdated timeIntervalSinceDate: memorySettingsLastUpdated] > 0);
        } else {
            diskMoreRecentThanMemory = (diskSettingsVersion > memorySettingsVersion);
        }

        if (diskMoreRecentThanMemory) {
            _settingsDict = [settingsFromDisk mutableCopy];
            self.lastSynchronizedWithDisk = [NSDate date];
            NSLog(@"Newer SCSettings found on disk (version %d vs %d with time interval %f), updating...", diskSettingsVersion, memorySettingsVersion, [diskSettingsLastUpdated timeIntervalSinceDate: memorySettingsLastUpdated]);
            [SCSentry addBreadcrumb: @"Updated SCSettings to newer settings found on disk" category: @"settings"];
        }
    }
}

- (void)forceReloadFromDisk {
    // Bypasses version number checking - always reloads from disk.
    // Use this when you KNOW the disk has authoritative data (e.g., after clearBlockForDebug).
    @synchronized (self) {
        NSString *failureReason = nil;
        NSInteger errorCode = 0;
        NSDictionary* settingsFromDisk =
            [self validatedSettingsDictionaryFromDiskWithReason:&failureReason errorCode:&errorCode];
        if (settingsFromDisk != nil) {
            _settingsDict = [settingsFromDisk mutableCopy];
            self.settingsStateAvailableForEnforcement = YES;
            self.lastReportedLoadFailureSignature = nil;
            NSLog(@"SCSettings: Force-reloaded from disk (version %d)", [settingsFromDisk[@"SettingsVersionNumber"] intValue]);
        } else {
            // Never discard the last-known-good state on a transient or
            // malicious disk failure. If this instance has not initialized,
            // establish non-nil safe defaults without recursive initialization.
            if (_settingsDict == nil) _settingsDict = [[self defaultSettingsDict] mutableCopy];
            [self reportSettingsLoadFailureWithReason:failureReason ?: @"decode_failed"
                                    recoveryAttempted:NO
                                    recoverySucceeded:NO
                                            errorCode:errorCode];
            NSLog(@"SCSettings: Force-reload rejected unsafe disk state (reason=%@ code=%ld); retaining memory version",
                  failureReason, (long)errorCode);
        }
        self.lastSynchronizedWithDisk = [NSDate date];
    }
}

- (void)writeSettingsAllowingUnavailableBootstrapWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock {
    [self writeSettingsWithCompletion:completionBlock allowingUnavailableBootstrap:YES];
}

- (void)writeSettingsWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock {
    [self writeSettingsWithCompletion:completionBlock allowingUnavailableBootstrap:NO];
}

- (void)writeSettingsWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock
        allowingUnavailableBootstrap:(BOOL)allowUnavailableBootstrap {
    @synchronized (self) {
        if (self.readOnly) {
            NSLog(@"WARNING: Read-only SCSettings instance can't write out settings");
            NSError* err = [SCErr errorWithCode: 600];
            [SCSentry captureError: err];
            if (completionBlock != nil) {
                completionBlock(err);
            }
            return;
        }

        if (_settingsDict == nil) [self initializeSettingsDict];
        if (!self.settingsStateAvailableForEnforcement && !allowUnavailableBootstrap) {
            NSLog(@"WARNING: Refusing to persist unavailable SCSettings safe defaults");
            NSError *err = [self settingsStateUnavailableError];
            if (completionBlock != nil) completionBlock(err);
            return;
        }

#if TESTING
        // no writing to disk during unit tests
        NSLog(@"Would write settings to disk now (but no writing during unit tests)");
        if (completionBlock != nil) completionBlock(nil);
#else
        // don't spend time on the main thread writing out files - it's OK for this to happen without blocking other things
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError* serializationErr;
            NSData* plistData = [NSPropertyListSerialization dataWithPropertyList: self.settingsDict
                                                                           format: NSPropertyListBinaryFormat_v1_0
                                                                          options: kNilOptions
                                                                            error: &serializationErr];
                            
            if (plistData == nil) {
                NSLog(@"NSPropertyListSerialization failed (domain=%@ code=%ld)",
                      serializationErr.domain, (long)serializationErr.code);
                if (completionBlock != nil) completionBlock(serializationErr);
                return;
            }
            
            NSError* createDirectoryErr;
            BOOL createDirectorySuccessful = [[NSFileManager defaultManager] createDirectoryAtURL: [NSURL fileURLWithPath: SETTINGS_FILE_DIR]
                                                                      withIntermediateDirectories: YES
                                                                                       attributes: @{
                                                                                           NSFileOwnerAccountID: [NSNumber numberWithUnsignedLong: 0],
                                                                                           NSFileGroupOwnerAccountID: [NSNumber numberWithUnsignedLong: 0],
                                                                                           NSFilePosixPermissions: [NSNumber numberWithShort: 0755]
                                                                                       }
                                                                                            error: &createDirectoryErr];
            if (!createDirectorySuccessful) {
                NSLog(@"WARNING: Failed to create SCSettings directory (domain=%@ code=%ld)",
                      createDirectoryErr.domain, (long)createDirectoryErr.code);
                [SCSentry addBreadcrumb: [NSString stringWithFormat: @"Failed to create directory for SCSettings with error %@", createDirectoryErr] category:@"settings"];
            }

            NSError* chmodDirectoryErr;
            BOOL chmodDirectorySuccessful = [[NSFileManager defaultManager]
                                             setAttributes: @{
                                                 NSFilePosixPermissions: [NSNumber numberWithShort: 0755]
                                             }
                                             ofItemAtPath: SETTINGS_FILE_DIR
                                             error: &chmodDirectoryErr];
            if (!chmodDirectorySuccessful) {
                NSLog(@"WARNING: Failed to set SCSettings directory permissions (domain=%@ code=%ld)",
                      chmodDirectoryErr.domain, (long)chmodDirectoryErr.code);
                [SCSentry addBreadcrumb: [NSString stringWithFormat: @"Failed to set directory permissions for SCSettings with error %@", chmodDirectoryErr] category:@"settings"];
            }

            NSError* writeErr;
            BOOL writeSuccessful = [plistData writeToFile: [self settingsFilePath]
                                                  options: NSDataWritingAtomic
                                                    error: &writeErr
                                    ];
            
            NSError* chmodErr;
            BOOL chmodSuccessful = [[NSFileManager defaultManager]
                                    setAttributes: @{
                                        NSFileOwnerAccountID: [NSNumber numberWithUnsignedLong: 0],
                                        NSFileGroupOwnerAccountID: [NSNumber numberWithUnsignedLong: 0],
                                        NSFilePosixPermissions: [NSNumber numberWithShort: 0755]
                                    }
                                    ofItemAtPath: [self settingsFilePath]
                                    error: &chmodErr];

            if (writeSuccessful) {
                self.lastSynchronizedWithDisk = [NSDate date];
                // Ordinary writes only reach this point from a valid
                // authoritative snapshot. The one explicit exception is the
                // first-run path where the secured file was genuinely absent.
                if (allowUnavailableBootstrap) {
                    self.settingsStateAvailableForEnforcement = YES;
                }
            }

            if (!writeSuccessful) {
                NSLog(@"Failed to write secured settings (domain=%@ code=%ld)", writeErr.domain, (long)writeErr.code);
                [SCSentry captureError: writeErr];
                if (completionBlock != nil) completionBlock(writeErr);
            } else if (!chmodSuccessful) {
                NSLog(@"Failed to set secured settings permissions (domain=%@ code=%ld)",
                      chmodErr.domain, (long)chmodErr.code);
                [SCSentry captureError: chmodErr];
                if (completionBlock != nil) completionBlock(chmodErr);
            } else {
                [SCSentry addBreadcrumb: @"Successfully wrote SCSettings out to file" category: @"settings"];
                if (completionBlock != nil) completionBlock(nil);
            }
        });
#endif
    }
}
- (void)writeSettings {
    // by default, just log all errors
    [self writeSettingsWithCompletion:^(NSError * _Nullable err) {
        if (err != nil) {
            NSLog(@"Error writing SCSettings (domain=%@ code=%ld)", err.domain, (long)err.code);
        }
    }];
}
- (void)synchronizeSettingsWithCompletion:(nullable void (^)(NSError * _Nullable))completionBlock {
    [self reloadSettings];

    if (!self.settingsStateAvailableForEnforcement) {
        NSLog(@"WARNING: Refusing to synchronize unavailable SCSettings safe defaults");
        if (completionBlock != nil) completionBlock([self settingsStateUnavailableError]);
        return;
    }
    
    NSDate* lastSettingsUpdate = [self valueForKey: @"LastSettingsUpdate"];
    
    // occasionally we can end up with timestamps from the future
    // (usually because the user moved their system clock forward, then back again)
    // it's a weird edge case and we should just fix that when we see it
    if ([lastSettingsUpdate timeIntervalSinceNow] > 0) {
        [self setValue: [NSDate date] forKey: @"LastSettingsUpdate"];
    }
    
    if ([lastSettingsUpdate timeIntervalSinceDate: self.lastSynchronizedWithDisk] > 0 && !self.readOnly) {
        NSLog(@" --> Writing settings to disk (haven't been written since %@)", self.lastSynchronizedWithDisk);
        [self writeSettingsWithCompletion: completionBlock];
    } else {
        if(completionBlock != nil) {
            // don't just run the callback asynchronously, since it makes this method harder to reason about
            // (it'd sometimes call back synchronously and sometimes async)
//            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completionBlock(nil);
//            });
        }
    }
}
- (void)synchronizeSettings {
    [self synchronizeSettingsWithCompletion:^(NSError *error) {
        if (error != nil) {
            NSLog(@"SCSettings synchronization refused (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
        }
    }];
}

- (NSError*)syncSettingsAndWait:(NSInteger)timeoutSecs {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSError* retErr = nil;

    // do this on another thread so it doesn't deadlock our semaphore
    // (also dispatch_async ensures correct behavior even if synchronizeSettingsWithCompletion itself returns synchronously)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self synchronizeSettingsWithCompletion:^(NSError* err) {
            retErr = err;
            
            dispatch_semaphore_signal(sema);
        }];
    });
    
    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSecs * (int64_t)NSEC_PER_SEC))) {
        retErr = [SCErr errorWithCode: 601];
    }
    
    return retErr;
}

- (void)setValue:(id)value forKey:(NSString*)key stopPropagation:(BOOL)stopPropagation {
    // if we're a readonly instance, we generally shouldn't be allowing values to be set
    // the only exception is receiving value updates (via notification) from other processes
    // in which case stopPropagation will be true
    if (self.readOnly && !stopPropagation) {
        NSLog(@"WARNING: Read-only SCSettings instance can't update key %@", key);
        return;
    }

    if (_settingsDict == nil) [self initializeSettingsDict];
    if (!self.settingsStateAvailableForEnforcement) {
        // Safe defaults exist only so reads and diagnostics remain total after
        // a corrupt initial load. Mutating them would let a later sync replace
        // the only record of an active block with fabricated default state.
        NSLog(@"WARNING: Refusing SCSettings mutation while authoritative state is unavailable");
        return;
    }
    
    // we can't store nils in a dictionary
    // so we sneak around it
    if (value == nil) {
        value = [NSNull null];
    }
    
    // locking everything on self is kinda inefficient/unnecessary
    // since it means we can only set one value at a time, and never when reading/writing from disk
    // but it seems to be OK for now - we'll improve later
    @synchronized (self) {
        // if we're about to insert NSNull anyway, may as well just unset the value
        if ([value isEqual: [NSNull null]]) {
            [self.settingsDict removeObjectForKey: key];
        } else {
            [self.settingsDict setValue: value forKey: key];
        }
        
        // record the update
        int newVersionNumber = [[self valueForKey: @"SettingsVersionNumber"] intValue] + 1;
        [self.settingsDict setValue: [NSNumber numberWithInt: newVersionNumber] forKey: @"SettingsVersionNumber"];
        [self.settingsDict setValue: [NSDate date] forKey: @"LastSettingsUpdate"];
    }
    
    // notify other instances (presumably in other processes)
    // stopPropagation is a flag that stops one setting change from bouncing back and forth for ages
    // between two processes. It indicates that the change started in another process
    if (!stopPropagation) {
        // Never broadcast setting values across sessions. ActiveBlocklist,
        // ApprovedSchedules, and ApprovedScheduleCommitments are private;
        // receivers reload the authoritative file after this version-only
        // invalidation signal.
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"org.eyebeam.SelfControl.SCSettingsValueChanged"
                                                                       object: self.description
                                                                     userInfo: @{
                                                                                 @"key": key,
                                                                                 @"versionNumber": self.settingsDict[@"SettingsVersionNumber"],
                                                                                 @"date": [NSDate date]
                                                                                 }
                                                                      options: NSNotificationDeliverImmediately | NSNotificationPostToAllSessions
         ];
    }
}

- (void)setValue:(id)value forKey:(NSString*)key {
    [self setValue: value forKey: key stopPropagation: NO];
}

- (id)valueForKey:(NSString*)key {
    id value = [self.settingsDict valueForKey: key];
    
    // when we get an NSNull we have to unwrap it and remember that means nil
    if ([value isEqual: [NSNull null]]) {
        value = nil;
    }
    
    // if we don't have a value in our dictionary but we do have a default value, use that instead!
    if (value == nil && [self defaultSettingsDict][key] != nil) {
        value = [self defaultSettingsDict][key];
    }

    return value;
}
- (BOOL)boolForKey:(NSString*)key {
    return [[self valueForKey: key] boolValue];
}

- (void)startSyncTimer {
    if (self.syncTimer != nil) {
        // we already have a timer, so no need to start another
        return;
    }
    
    // set up a timer so values get synchronized to disk on a regular basis
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    self.syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (self.syncTimer) {
        dispatch_source_set_timer(self.syncTimer, dispatch_time(DISPATCH_TIME_NOW, SYNC_INTERVAL_SECS * NSEC_PER_SEC), SYNC_INTERVAL_SECS * NSEC_PER_SEC, SYNC_LEEWAY_SECS * NSEC_PER_SEC);
        dispatch_source_set_event_handler(self.syncTimer, ^{
            [self synchronizeSettings];
        });
        dispatch_resume(self.syncTimer);
    }
}
- (void)cancelSyncTimers {
    if (self.syncTimer != nil) {
        dispatch_source_cancel(self.syncTimer);
        self.syncTimer = nil;
    }
    
    if (self.debouncedChangeTimer != nil) {
        dispatch_source_cancel(self.debouncedChangeTimer);
        self.debouncedChangeTimer = nil;
    }
}

- (void)updateSentryContext {
    if (![SCSentry errorReportingEnabled]) {
        return;
    }

    // Never attach a settings dump. In particular, ApprovedSchedules contains
    // every committed segment's complete blocklist. The shared sanitizer copies
    // only known-safe scalars and derived counts/states.
    NSMutableDictionary* settingsWithDefaults = [[self defaultSettingsDict] mutableCopy];
    [settingsWithDefaults addEntriesFromDictionary:self.settingsDict ?: @{}];
    NSDictionary* safeContext = [SCSentry sanitizedSettingsContextFromDictionary:settingsWithDefaults];

#if SENTRY_ENABLED
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setContextValue:safeContext forKey:@"SCSettings"];
    }];
#endif
}

- (void)onSettingChanged:(NSNotification*)note {
    // note.object is a string, so we can't just do a simple == to see if the object is self
    // but if we check our description against it, that will do the same thing because description
    // includes the memory address. Don't override description or this logic will break!!
    if ([note.object isEqualToString: [self description]]) {
        // we don't need to listen to our own notifications
        return;
    }
    
    if (note.userInfo[@"key"] == nil) {
        // something's wrong - we don't have a key to set
        return;
    }
    
    // if this change happened before our latest update, it's kinda unclear what the end state should be
    // so ignore it and just queue up a sync instead
    int noteVersionNumber = [note.userInfo[@"versionNumber"] intValue];
    NSDate* noteSettingUpdated = note.userInfo[@"date"];
    int ourSettingsVersionNumber = [[self valueForKey: @"SettingsVersionNumber"] intValue];
    NSDate* ourSettingsLastUpdated = [self valueForKey: @"LastSettingsUpdate"];

    // check by version number, tiebreak by last updated date
    BOOL noteMoreRecentThanSettings = NO;
    if (noteVersionNumber == ourSettingsVersionNumber) {
        noteMoreRecentThanSettings = ([noteSettingUpdated timeIntervalSinceDate: ourSettingsLastUpdated] > 0);
    } else {
        noteMoreRecentThanSettings = (noteVersionNumber > ourSettingsVersionNumber);
    }

    if (!noteMoreRecentThanSettings) {
        NSLog(@"Ignoring setting change notification as %@ is older than %@", noteSettingUpdated, ourSettingsLastUpdated);
    } else {
        NSLog(@"Accepting propagated invalidation for key %@ (version %d newer than %d)",
              note.userInfo[@"key"], noteVersionNumber, ourSettingsVersionNumber);
    }
    
    // regardless of which is more recent, we should really go get the new deal from disk
    // in the near future (but debounce so we don't do this a million times for rapid changes)
    if (self.debouncedChangeTimer != nil) {
        dispatch_source_cancel(self.debouncedChangeTimer);
        self.debouncedChangeTimer = nil;
    }
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    double throttleSecs = 0.25f;
    self.debouncedChangeTimer = [SCMiscUtilities createDebounceDispatchTimer: throttleSecs
                                                                   queue: queue
                                                                   block: ^{
        NSLog(@"Syncing settings due to propagated changes");
        [self synchronizeSettings];
    }];
}

- (void)resetAllSettingsToDefaults {
    // we _basically_ just copy the default settings dict in,
    // except we leave the settings version number and last settings update
    // intact - that helps keep us in sync with any other instances
    NSDictionary* defaultSettings = [self defaultSettingsDict];
    for (NSString* key in defaultSettings) {
        if ([key isEqualToString: @"SettingsVersionNumber"] || [key isEqualToString: @"LastSettingsUpdate"]) {
            continue;
        }
        
        [self setValue: defaultSettings[key] forKey: key];
    }
}

- (void)dealloc {
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [self cancelSyncTimers];
}

@synthesize settingsDict = _settingsDict, lastSynchronizedWithDisk;

@end

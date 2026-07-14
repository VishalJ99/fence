//
//  SCScheduleManager.m
//  SelfControl
//

#import "SCScheduleManager.h"
#import "SCScheduleLaunchdBridge.h"
#import "SCBlockUtilities.h"
#import "SCXPCClient.h"
#import "SCMiscUtilities.h"
#import "SCSettings.h"
#import "SCVersionTracker.h"
#import "SCDaemonProtocol.h"
#import "SCBlockEntry.h"
#import "NSString+IPAddress.h"
#import "SCSentry.h"

NSNotificationName const SCScheduleManagerDidChangeNotification = @"SCScheduleManagerDidChangeNotification";
NSNotificationName const SCScheduleStrictifyDidCompleteNotification = @"SCScheduleStrictifyDidCompleteNotification";
NSString * const SCScheduleStrictifyOutcomeKey = @"outcome";
NSString * const SCScheduleStrictifyFailedStageKey = @"failed_stage";
NSString * const SCScheduleStrictifyOperationTokenKey = @"operation_token";

static BOOL SCStrictifyStatusSucceeded(id value) {
    return [value isKindOfClass:[NSString class]] && [value isEqualToString:@"succeeded"];
}

static NSUInteger SCNextStrictifyOperationSequence(void) {
    static NSUInteger sequence = 0;
    @synchronized ([SCScheduleManager class]) {
        sequence += 1;
        return sequence;
    }
}

static NSString *SCStrictifyFailureStageFromDaemonStage(NSString *stage, BOOL activePath) {
    if ([stage isEqualToString:@"none"]) return @"none";
    if ([stage isEqualToString:@"lock"]) return @"lock";
    if ([stage isEqualToString:@"canonicalize"]) return @"canonicalize";
    if ([stage isEqualToString:@"settings_sync"]) return @"settings_sync";
    if ([stage isEqualToString:@"verification"]) return @"verification";
    if ([stage isEqualToString:@"physical_apply"]) return @"active_apply";
    if ([stage isEqualToString:@"job_verification"]) return @"future_apply";
    if ([stage isEqualToString:@"resolution"]) return @"future_resolution";
    if ([stage isEqualToString:@"precondition"]) {
        return activePath ? @"active_precondition" : @"future_resolution";
    }
    return activePath ? @"active_apply" : @"future_apply";
}

// NSUserDefaults keys (app-layer only, not in SCSettings)
static NSString * const kBundlesKey = @"SCScheduleBundles";
static NSString * const kWeekSchedulesPrefix = @"SCWeekSchedules_"; // + week key (e.g., "2024-12-23")
static NSString * const kWeekCommitmentPrefix = @"SCWeekCommitment_"; // + week key
static NSString * const kWeekScheduleManifestPrefix = @"SCScheduleManifest_"; // local V2 ID/source mapping
static NSString * const kCommitmentEndDateKey = @"SCCommitmentEndDate";
static NSString * const kIsCommittedKey = @"SCIsCommitted";
static NSString * const kEmergencyUnlockCreditsKey = @"SCEmergencyUnlockCredits";
static NSString * const kEmergencyUnlockCreditsInitializedKey = @"SCEmergencyUnlockCreditsInitialized";
static const NSInteger kDefaultEmergencyUnlockCredits = 5;
static NSString * const kLastScheduleCommitOutcomeKey = @"SCLastScheduleCommitOutcome";
static NSString * const kLastScheduleCommitFailureStageKey = @"SCLastScheduleCommitFailureStage";
static NSString * const SCScheduleCommitErrorDomain = @"org.eyebeam.Fence.ScheduleCommit";
static const NSUInteger SCScheduleMaximumCommitmentEntries = 4096;
static const NSUInteger SCScheduleMaximumCommitmentSegments = 512;

static BOOL SCScheduleWaitForSemaphore(dispatch_semaphore_t semaphore,
                                       NSTimeInterval timeout) {
    BOOL hasDeadline = timeout > 0;
    NSDate *deadline = hasDeadline ? [NSDate dateWithTimeIntervalSinceNow:timeout] : nil;
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
        if (hasDeadline && [deadline timeIntervalSinceNow] <= 0) return NO;
        if ([NSThread isMainThread]) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        } else {
            dispatch_time_t waitDeadline = hasDeadline
                ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
                : DISPATCH_TIME_FOREVER;
            return dispatch_semaphore_wait(semaphore, waitDeadline) == 0;
        }
    }
    return YES;
}

static void SCEmitScheduleCommitStoreFailure(NSString *stage,
                                             NSUInteger segmentsPlanned,
                                             NSUInteger segmentsStored,
                                             NSInteger weekOffset,
                                             NSInteger errorCode,
                                             BOOL storePersisted,
                                             BOOL postWriteMatch,
                                             BOOL reconcileSucceeded) {
    [SCSentry captureTelemetryEvent:@"schedule.commit_store_failed"
                              level:SCTelemetryEventLevelError
                             fields:@{
        @"stage": stage,
        @"segments_planned": @(segmentsPlanned),
        @"segments_stored": @(segmentsStored),
        @"week_offset": @(MAX(0, weekOffset)),
        @"error_code": @(MAX(-1000000000, MIN(1000000000, errorCode))),
        @"store_persisted": @(storePersisted),
        @"post_write_match": @(postWriteMatch),
        @"reconcile_succeeded": @(reconcileSucceeded),
    }];
}

static NSError *SCScheduleCommitError(NSInteger code,
                                      NSString *stage,
                                      NSString *description,
                                      BOOL storePersisted) {
    return [NSError errorWithDomain:SCScheduleCommitErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
        @"stage": stage,
        @"store_persisted": @(storePersisted),
    }];
}

@class SCBlockSegment;

@interface SCStrictifyRetryState : NSObject
@property (nonatomic, copy) NSArray<NSString *> *addedEntries;
@property (nonatomic, copy) SCBlockBundle *bundle;
@property (nonatomic, assign) BOOL bundleSaved;
@end

@implementation SCStrictifyRetryState
@end

@interface SCScheduleManager ()

@property (nonatomic, strong) NSMutableArray<SCBlockBundle *> *mutableBundles;
// Cache for week-specific schedules: weekKey -> array of schedules
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<SCWeeklySchedule *> *> *weekSchedulesCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SCStrictifyRetryState *> *strictifyRetryStatesByToken;
@property (nonatomic, strong) NSMutableArray<NSString *> *strictifyRetryTokenOrder;
@property (nonatomic, copy, nullable) NSString *lastStrictifyOperationToken;

// Forward declaration for segment-based merging
- (NSArray<SCBlockSegment *> *)calculateBlockSegmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                     weekOffset:(NSInteger)weekOffset
                                                         bridge:(SCScheduleLaunchdBridge *)bridge;

// Variant that accepts schedules directly (for daemon use when reading user's defaults)
- (NSArray<SCBlockSegment *> *)calculateBlockSegmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                      schedules:(NSArray<SCWeeklySchedule *> *)schedules
                                                     weekOffset:(NSInteger)weekOffset
                                                         bridge:(SCScheduleLaunchdBridge *)bridge;

- (NSArray<NSString *> *)entriesInArray:(NSArray<NSString *> *)entries notInArray:(NSArray<NSString *> *)otherEntries;
- (BOOL)bundleIsUsedInCommittedSchedule:(NSString *)bundleID;
- (NSArray<SCBlockBundle *> *)enabledBundlesForCommittedBlockCalculations;
- (NSArray<NSString *> *)expectedBlocklistForSegment:(SCBlockSegment *)segment oldBundle:(SCBlockBundle *)oldBundle;
- (NSDictionary<NSString *, NSArray<NSString *> *> *)installedMergedScheduleIDsByStartKey;
- (nullable NSDictionary<NSString *, id> *)v2ManifestForWeekOffset:(NSInteger)weekOffset;
- (NSDictionary<NSString *, NSArray<NSString *> *> *)v2ExpectedApprovedScheduleBlocklistsForBundle:(SCBlockBundle *)bundle
                                                                                          oldBundle:(SCBlockBundle *)oldBundle;
- (nullable NSArray<NSString *> *)expectedActiveBlocklistForBundle:(SCBlockBundle *)bundle oldBundle:(SCBlockBundle *)oldBundle;
- (NSDictionary<NSString *, NSArray<NSString *> *> *)expectedApprovedScheduleBlocklistsForBundle:(SCBlockBundle *)bundle oldBundle:(SCBlockBundle *)oldBundle;
- (void)appendCommittedAdditions:(NSArray<NSString *> *)addedEntries
                       oldBundle:(SCBlockBundle *)oldBundle
                        toBundle:(SCBlockBundle *)bundle
                     bundleSaved:(BOOL)bundleSaved
          blocklistFilePersisted:(BOOL)blocklistFilePersisted
                  operationToken:(nullable NSString *)operationToken;
- (void)emitStrictifyResultForEntries:(NSArray<NSString *> *)addedEntries
                            oldBundle:(SCBlockBundle *)oldBundle
                             toBundle:(SCBlockBundle *)bundle
                          bundleSaved:(BOOL)bundleSaved
               blocklistFilePersisted:(BOOL)blocklistFilePersisted
                       activeExpected:(BOOL)activeExpected
                       futureExpected:(BOOL)futureExpected
                         activeResult:(NSDictionary<NSString *, id> *)activeResult
                         activeError:(nullable NSError *)activeError
                         futureResult:(NSDictionary<NSString *, id> *)futureResult
                         futureError:(nullable NSError *)futureError
                             timedOut:(BOOL)timedOut
                            startedAt:(NSDate *)startedAt
                       operationToken:(NSString *)operationToken;
- (NSString *)storeStrictifyRetryStateForEntries:(NSArray<NSString *> *)addedEntries
                                        toBundle:(SCBlockBundle *)bundle
                                     bundleSaved:(BOOL)bundleSaved
                                  operationToken:(nullable NSString *)operationToken;
- (void)clearStrictifyRetryStateForOperationToken:(NSString *)operationToken;

@end

#pragma mark - SCBlockSegment (Internal Helper Class)

/// A segment represents a time period with a specific set of active bundles
@interface SCBlockSegment : NSObject
@property (nonatomic, strong) NSDate *startDate;
@property (nonatomic, strong) NSDate *endDate;
@property (nonatomic, assign) SCDayOfWeek day;
@property (nonatomic, assign) NSInteger startMinutes;
@property (nonatomic, strong) NSMutableArray<SCBlockBundle *> *activeBundles;
@property (nonatomic, strong) NSString *segmentID;
+ (instancetype)segmentWithStart:(NSDate *)start end:(NSDate *)end day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes;
@end

@implementation SCBlockSegment
+ (instancetype)segmentWithStart:(NSDate *)start end:(NSDate *)end day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes {
    SCBlockSegment *seg = [[SCBlockSegment alloc] init];
    seg.startDate = start;
    seg.endDate = end;
    seg.day = day;
    seg.startMinutes = minutes;
    seg.activeBundles = [NSMutableArray array];
    seg.segmentID = [[NSUUID UUID] UUIDString];
    return seg;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<SCBlockSegment bundles=%lu>",
            (unsigned long)self.activeBundles.count];
}
@end

#pragma mark - SCScheduleManager Implementation

@implementation SCScheduleManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static SCScheduleManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SCScheduleManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableBundles = [NSMutableArray array];
        _weekSchedulesCache = [NSMutableDictionary dictionary];
        _strictifyRetryStatesByToken = [NSMutableDictionary dictionary];
        _strictifyRetryTokenOrder = [NSMutableArray array];
        [self reload];
    }
    return self;
}

#pragma mark - Bundles

- (NSArray<SCBlockBundle *> *)bundles {
    return [self.mutableBundles copy];
}

- (void)addBundle:(SCBlockBundle *)bundle {
    if (!bundle || [self bundleWithID:bundle.bundleID]) {
        return; // Already exists or invalid
    }

    bundle.displayOrder = self.mutableBundles.count;
    [self.mutableBundles addObject:bundle];

    // Schedule is created when user edits it in the week view

    [self save];
    [self postChangeNotification];
}

- (void)removeBundleWithID:(NSString *)bundleID {
    // Cannot delete bundles while committed - this would loosen restrictions
    if ([self isCommittedForWeekOffset:0]) {
        NSLog(@"SCScheduleManager: Cannot delete bundle while committed - would loosen restrictions");
        return;
    }

    SCBlockBundle *bundle = [self bundleWithID:bundleID];
    if (!bundle) return;

    // 1. Remove from bundles array
    [self.mutableBundles removeObject:bundle];

    // 2. Clean weekSchedulesCache and SCWeekSchedules_* for all weeks
    [self removeSchedulesForBundleID:bundleID];

    // 3. Save
    [self save];

    [self postChangeNotification];
}

- (void)updateBundle:(SCBlockBundle *)bundle {
    NSInteger index = [self indexOfBundleWithID:bundle.bundleID];
    if (index != NSNotFound) {
        SCBlockBundle *oldBundle = [self.mutableBundles[index] copy];
        BOOL usedInCommittedSchedule = [self bundleIsUsedInCommittedSchedule:bundle.bundleID];
        NSArray<NSString *> *removedEntries = [self entriesInArray:oldBundle.entries notInArray:bundle.entries];

        if (usedInCommittedSchedule && removedEntries.count > 0) {
            NSLog(@"SCScheduleManager: Preserving %lu removed entries for a committed bundle",
                  (unsigned long)removedEntries.count);
            for (NSString *entry in removedEntries) {
                if (![bundle.entries containsObject:entry]) {
                    [bundle.entries addObject:entry];
                }
            }
        }

        NSArray<NSString *> *addedEntries = [self entriesInArray:bundle.entries notInArray:oldBundle.entries];

        self.mutableBundles[index] = bundle;
        [self save];

        BOOL bundleSaved = NO;
        id persistedBundles = [[NSUserDefaults standardUserDefaults] objectForKey:kBundlesKey];
        if ([persistedBundles isKindOfClass:[NSArray class]]) {
            for (id persistedBundle in persistedBundles) {
                if ([persistedBundle isKindOfClass:[NSDictionary class]] &&
                    [persistedBundle[@"bundleID"] isEqualToString:bundle.bundleID]) {
                    bundleSaved = YES;
                    break;
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // Live strictify: If committed and a block is running, update the active block
        // ═══════════════════════════════════════════════════════════════════════════

        BOOL legacyCommittedJobUsesBundle = NO;
        for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
            if ([self isCommittedForWeekOffset:weekOffset] &&
                [self v2ManifestForWeekOffset:weekOffset] == nil &&
                [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset] != nil) {
                legacyCommittedJobUsesBundle = YES;
                break;
            }
        }
        BOOL blocklistFilePersisted = !legacyCommittedJobUsesBundle;
        if (legacyCommittedJobUsesBundle) {
            // Only draining V1 LaunchAgents read bundle blocklist files.
            SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
            NSError *error = nil;
            blocklistFilePersisted = [bridge writeBlocklistFileForBundle:bundle error:&error];
            if (error) {
                NSLog(@"WARNING: Failed to update one blocklist file (domain=%@ code=%ld)",
                      error.domain, (long)error.code);
            }
        }

        BOOL shouldDiagnoseAdditions = addedEntries.count > 0 &&
            (usedInCommittedSchedule || [SCBlockUtilities anyBlockIsRunning] ||
             [self isCommittedForWeekOffset:0] || [self isCommittedForWeekOffset:1]);
        if (shouldDiagnoseAdditions) {
            [self appendCommittedAdditions:addedEntries
                                 oldBundle:oldBundle
                                  toBundle:bundle
                               bundleSaved:bundleSaved
                    blocklistFilePersisted:blocklistFilePersisted
                            operationToken:nil];
        }

        // ═══════════════════════════════════════════════════════════════════════════

        [self postChangeNotification];
    }
}

- (NSArray<NSString *> *)entriesInArray:(NSArray<NSString *> *)entries notInArray:(NSArray<NSString *> *)otherEntries {
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    NSSet<NSString *> *otherSet = [NSSet setWithArray:otherEntries ?: @[]];

    for (NSString *entry in entries ?: @[]) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }

        if (![otherSet containsObject:entry]) {
            [result addObject:entry];
        }
    }

    return result.array;
}

- (BOOL)bundleIsUsedInCommittedSchedule:(NSString *)bundleID {
    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        if ([self isCommittedForWeekOffset:weekOffset] &&
            [self scheduleForBundleID:bundleID weekOffset:weekOffset] != nil) {
            return YES;
        }
    }

    return NO;
}

- (NSArray<SCBlockBundle *> *)enabledBundlesForCommittedBlockCalculations {
    NSMutableArray<SCBlockBundle *> *enabledBundles = [NSMutableArray array];

    for (SCBlockBundle *bundle in self.mutableBundles) {
        if (bundle.enabled) {
            [enabledBundles addObject:bundle];
        }
    }

    return enabledBundles;
}

- (NSArray<NSString *> *)expectedBlocklistForSegment:(SCBlockSegment *)segment oldBundle:(SCBlockBundle *)oldBundle {
    NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];

    for (SCBlockBundle *activeBundle in segment.activeBundles) {
        if ([activeBundle.bundleID isEqualToString:oldBundle.bundleID]) {
            [entries addObjectsFromArray:oldBundle.entries ?: @[]];
        } else {
            [entries addObjectsFromArray:activeBundle.entries ?: @[]];
        }
    }

    return entries.array;
}

- (nullable NSArray<NSString *> *)expectedActiveBlocklistForBundle:(SCBlockBundle *)bundle oldBundle:(SCBlockBundle *)oldBundle {
    if (![self isCommittedForWeekOffset:0] || ![SCBlockUtilities anyBlockIsRunning]) {
        return nil;
    }

    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    NSArray<SCBlockSegment *> *segments = [self calculateBlockSegmentsForBundles:[self enabledBundlesForCommittedBlockCalculations]
                                                                      weekOffset:0
                                                                          bridge:bridge];
    NSDate *now = [NSDate date];

    for (SCBlockSegment *segment in segments) {
        BOOL startsBeforeOrNow = ([segment.startDate compare:now] != NSOrderedDescending);
        BOOL endsAfterOrNow = ([segment.endDate compare:now] != NSOrderedAscending);
        if (!startsBeforeOrNow || !endsAfterOrNow) {
            continue;
        }

        for (SCBlockBundle *activeBundle in segment.activeBundles) {
            if ([activeBundle.bundleID isEqualToString:bundle.bundleID]) {
                return [self expectedBlocklistForSegment:segment oldBundle:oldBundle];
            }
        }
    }

    return nil;
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)installedMergedScheduleIDsByStartKey {
    NSString *launchAgentsDir = [SCScheduleLaunchdBridge launchAgentsDirectory].path;
    NSString *prefix = [NSString stringWithFormat:@"%@.merged-", [SCScheduleLaunchdBridge jobLabelPrefix]];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:launchAgentsDir error:nil];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *scheduleIDsByStartKey = [NSMutableDictionary dictionary];

    for (NSString *file in files) {
        if (![file hasPrefix:prefix] || ![file hasSuffix:@".plist"]) {
            continue;
        }

        NSString *path = [launchAgentsDir stringByAppendingPathComponent:file];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *label = plist[@"Label"];
        NSArray *args = plist[@"ProgramArguments"];
        if (![label isKindOfClass:[NSString class]] || ![args isKindOfClass:[NSArray class]]) {
            continue;
        }

        NSArray *labelParts = [label componentsSeparatedByString:@".merged-"];
        if (labelParts.count < 2) {
            continue;
        }

        NSArray *remainderParts = [labelParts[1] componentsSeparatedByString:@"."];
        if (remainderParts.count < 3) {
            continue;
        }

        NSString *segmentID = remainderParts[0];
        NSString *day = remainderParts[1];
        NSString *time = remainderParts[2];
        NSString *startDateString = nil;
        for (NSString *arg in args) {
            if ([arg hasPrefix:@"--startdate="]) {
                startDateString = [arg substringFromIndex:@"--startdate=".length];
                break;
            }
        }

        if (segmentID.length == 0 || startDateString.length == 0) {
            continue;
        }

        NSString *startKey = [NSString stringWithFormat:@"%@.%@.%@", startDateString, day, time];
        if (scheduleIDsByStartKey[startKey] == nil) {
            scheduleIDsByStartKey[startKey] = [NSMutableArray array];
        }
        [scheduleIDsByStartKey[startKey] addObject:segmentID];
    }

    return scheduleIDsByStartKey;
}

- (nullable NSDictionary<NSString *, id> *)v2ManifestForWeekOffset:(NSInteger)weekOffset {
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    id value = [[NSUserDefaults standardUserDefaults]
        objectForKey:[kWeekScheduleManifestPrefix stringByAppendingString:weekKey]];
    NSDictionary *manifest = [value isKindOfClass:[NSDictionary class]] ? value : nil;
    if ([manifest[@"schemaVersion"] integerValue] != 2 ||
        ![manifest[@"weekKey"] isEqualToString:weekKey] ||
        ![manifest[@"schedules"] isKindOfClass:[NSArray class]]) {
        return nil;
    }
    return manifest;
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)v2ExpectedApprovedScheduleBlocklistsForBundle:(SCBlockBundle *)bundle
                                                                                          oldBundle:(SCBlockBundle *)oldBundle {
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *expected = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];

    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        if (![self isCommittedForWeekOffset:weekOffset]) continue;
        NSDictionary *manifest = [self v2ManifestForWeekOffset:weekOffset];
        for (id rawRecord in manifest[@"schedules"] ?: @[]) {
            NSDictionary *record = [rawRecord isKindOfClass:[NSDictionary class]] ? rawRecord : nil;
            NSString *scheduleID = record[@"scheduleID"];
            NSDate *approvedEndDate = record[@"approvedEndDate"];
            NSArray<NSString *> *sourceBundleIDs = record[@"sourceBundleIDs"];
            if (![[NSUUID alloc] initWithUUIDString:scheduleID] ||
                ![approvedEndDate isKindOfClass:[NSDate class]] ||
                [approvedEndDate compare:now] != NSOrderedDescending ||
                ![sourceBundleIDs isKindOfClass:[NSArray class]] ||
                ![sourceBundleIDs containsObject:bundle.bundleID]) {
                continue;
            }

            NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];
            BOOL allSourcesResolved = YES;
            for (NSString *sourceBundleID in sourceBundleIDs) {
                SCBlockBundle *sourceBundle = [sourceBundleID isEqualToString:oldBundle.bundleID]
                    ? oldBundle : [self bundleWithID:sourceBundleID];
                if (sourceBundle == nil) {
                    allSourcesResolved = NO;
                    break;
                }
                for (id rawEntry in sourceBundle.entries ?: @[]) {
                    NSString *canonical = [rawEntry isKindOfClass:[NSString class]]
                        ? [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] : nil;
                    if (canonical == nil) {
                        allSourcesResolved = NO;
                        break;
                    }
                    [entries addObject:canonical];
                }
                if (!allSourcesResolved) break;
            }
            if (allSourcesResolved && entries.count > 0) {
                expected[scheduleID] = entries.array;
            }
        }
    }
    return expected;
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)expectedApprovedScheduleBlocklistsForBundle:(SCBlockBundle *)bundle oldBundle:(SCBlockBundle *)oldBundle {
    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    NSDictionary<NSString *, NSArray<NSString *> *> *installedScheduleIDsByStartKey = [self installedMergedScheduleIDsByStartKey];
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *expectedBlocklistsByScheduleID =
        [[self v2ExpectedApprovedScheduleBlocklistsForBundle:bundle oldBundle:oldBundle] mutableCopy];

    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        if (![self isCommittedForWeekOffset:weekOffset] ||
            [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset] == nil ||
            [self v2ManifestForWeekOffset:weekOffset] != nil) {
            continue;
        }

        NSArray<SCBlockSegment *> *segments = [self calculateBlockSegmentsForBundles:[self enabledBundlesForCommittedBlockCalculations]
                                                                          weekOffset:weekOffset
                                                                              bridge:bridge];
        for (SCBlockSegment *segment in segments) {
            BOOL targetBundleIsActive = NO;
            for (SCBlockBundle *activeBundle in segment.activeBundles) {
                if ([activeBundle.bundleID isEqualToString:bundle.bundleID]) {
                    targetBundleIsActive = YES;
                    break;
                }
            }

            if (!targetBundleIsActive) {
                continue;
            }

            NSString *day = [[SCWeeklySchedule stringForDay:segment.day] lowercaseString];
            NSString *time = [NSString stringWithFormat:@"%02ld%02ld",
                              (long)(segment.startMinutes / 60),
                              (long)(segment.startMinutes % 60)];
            NSString *startDateString = [isoFormatter stringFromDate:segment.startDate];
            NSString *startKey = [NSString stringWithFormat:@"%@.%@.%@", startDateString, day, time];
            NSArray<NSString *> *matchingSegmentIDs = installedScheduleIDsByStartKey[startKey] ?: @[];

            if (matchingSegmentIDs.count != 1) {
                NSLog(@"SCScheduleManager: Skipping one approved schedule append because %lu matching jobs were found",
                      (unsigned long)matchingSegmentIDs.count);
                continue;
            }

            expectedBlocklistsByScheduleID[matchingSegmentIDs.firstObject] = [self expectedBlocklistForSegment:segment oldBundle:oldBundle];
        }
    }

    return expectedBlocklistsByScheduleID;
}

- (void)appendCommittedAdditions:(NSArray<NSString *> *)addedEntries
                       oldBundle:(SCBlockBundle *)oldBundle
                        toBundle:(SCBlockBundle *)bundle
                     bundleSaved:(BOOL)bundleSaved
          blocklistFilePersisted:(BOOL)blocklistFilePersisted
                  operationToken:(NSString *)operationToken {
    NSString *scopedOperationToken =
        [self storeStrictifyRetryStateForEntries:addedEntries
                                        toBundle:bundle
                                     bundleSaved:bundleSaved
                                  operationToken:operationToken];

    NSDate *startedAt = [NSDate date];
    BOOL usedInCommittedSchedule = [self bundleIsUsedInCommittedSchedule:bundle.bundleID];
    if (!usedInCommittedSchedule) {
        [self emitStrictifyResultForEntries:addedEntries
                                  oldBundle:oldBundle
                                   toBundle:bundle
                                bundleSaved:bundleSaved
                     blocklistFilePersisted:blocklistFilePersisted
                             activeExpected:NO
                             futureExpected:NO
                               activeResult:@{}
                                activeError:nil
                               futureResult:@{}
                                futureError:nil
                                   timedOut:NO
                                  startedAt:startedAt
                             operationToken:scopedOperationToken];
        return;
    }

    NSArray<NSString *> *expectedActiveBlocklist =
        [self expectedActiveBlocklistForBundle:bundle oldBundle:oldBundle];
    NSDictionary<NSString *, NSArray<NSString *> *> *expectedApprovedBlocklists =
        [self expectedApprovedScheduleBlocklistsForBundle:bundle oldBundle:oldBundle];
    BOOL activeExpected = expectedActiveBlocklist != nil;
    BOOL futureExpected = expectedApprovedBlocklists.count > 0;

    if (!activeExpected && !futureExpected) {
        [self emitStrictifyResultForEntries:addedEntries
                                  oldBundle:oldBundle
                                   toBundle:bundle
                                bundleSaved:bundleSaved
                     blocklistFilePersisted:blocklistFilePersisted
                             activeExpected:NO
                             futureExpected:NO
                               activeResult:@{}
                                activeError:nil
                               futureResult:@{}
                                futureError:nil
                                   timedOut:NO
                                  startedAt:startedAt
                             operationToken:scopedOperationToken];
        return;
    }

    SCXPCClient *xpc = [[SCXPCClient alloc] init];
    dispatch_queue_t resultQueue = dispatch_queue_create("org.eyebeam.Fence.strictify-result", DISPATCH_QUEUE_SERIAL);
    __block NSInteger pendingReplies = (activeExpected ? 1 : 0) + (futureExpected ? 1 : 0);
    __block BOOL finalized = NO;
    __block NSDictionary<NSString *, id> *activeResult = @{};
    __block NSDictionary<NSString *, id> *futureResult = @{};
    __block NSError *activeError = nil;
    __block NSError *futureError = nil;

    void (^finish)(BOOL) = ^(BOOL timedOut) {
        NSDictionary *capturedActiveResult = activeResult ?: @{};
        NSDictionary *capturedFutureResult = futureResult ?: @{};
        NSError *capturedActiveError = activeError;
        NSError *capturedFutureError = futureError;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self emitStrictifyResultForEntries:addedEntries
                                      oldBundle:oldBundle
                                       toBundle:bundle
                                    bundleSaved:bundleSaved
                         blocklistFilePersisted:blocklistFilePersisted
                                 activeExpected:activeExpected
                                 futureExpected:futureExpected
                                   activeResult:capturedActiveResult
                                    activeError:capturedActiveError
                                   futureResult:capturedFutureResult
                                    futureError:capturedFutureError
                                       timedOut:timedOut
                                      startedAt:startedAt
                                 operationToken:scopedOperationToken];
        });
    };

    void (^recordReply)(BOOL, NSDictionary<NSString *, id> *, NSError *) =
        ^(BOOL isActive, NSDictionary<NSString *, id> *result, NSError *error) {
        dispatch_async(resultQueue, ^{
            if (finalized) return;
            if (isActive) {
                activeResult = [result copy] ?: @{};
                activeError = error;
            } else {
                futureResult = [result copy] ?: @{};
                futureError = error;
            }
            pendingReplies -= 1;
            if (pendingReplies == 0) {
                finalized = YES;
                finish(NO);
            }
        });
    };

    if (activeExpected) {
        [xpc appendEntriesToActiveBlocklist:addedEntries
                  matchingExistingBlocklist:expectedActiveBlocklist
                                 resultReply:^(NSDictionary<NSString *,id> *result, NSError *error) {
            recordReply(YES, result, error);
        }];
    }
    if (futureExpected) {
        [xpc appendEntriesToApprovedSchedules:expectedApprovedBlocklists
                                       entries:addedEntries
                                   resultReply:^(NSDictionary<NSString *,id> *result, NSError *error) {
            recordReply(NO, result, error);
        }];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), resultQueue, ^{
        if (finalized) return;
        finalized = YES;
        finish(YES);
    });
}

- (void)emitStrictifyResultForEntries:(NSArray<NSString *> *)addedEntries
                            oldBundle:(SCBlockBundle *)oldBundle
                             toBundle:(SCBlockBundle *)bundle
                          bundleSaved:(BOOL)bundleSaved
               blocklistFilePersisted:(BOOL)blocklistFilePersisted
                       activeExpected:(BOOL)activeExpected
                       futureExpected:(BOOL)futureExpected
                         activeResult:(NSDictionary<NSString *, id> *)activeResult
                          activeError:(NSError *)activeError
                         futureResult:(NSDictionary<NSString *, id> *)futureResult
                          futureError:(NSError *)futureError
                             timedOut:(BOOL)timedOut
                            startedAt:(NSDate *)startedAt
                       operationToken:(NSString *)operationToken {
    BOOL usedInCommittedSchedule = [self bundleIsUsedInCommittedSchedule:bundle.bundleID];
    BOOL blockRunning = [SCBlockUtilities anyBlockIsRunning];

    NSUInteger validInputCount = 0;
    NSUInteger appEntryCount = 0;
    NSUInteger siteEntryCount = 0;
    NSMutableOrderedSet<NSString *> *canonicalEntries = [NSMutableOrderedSet orderedSet];
    for (id rawEntry in addedEntries ?: @[]) {
        if (![rawEntry isKindOfClass:[NSString class]]) continue;
        NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:rawEntry];
        if (canonicalEntry == nil) continue;
        validInputCount += 1;
        [canonicalEntries addObject:canonicalEntry];
    }
    for (NSString *canonicalEntry in canonicalEntries) {
        if ([canonicalEntry hasPrefix:@"app:"]) appEntryCount += 1;
        else siteEntryCount += 1;
    }
    NSUInteger requestedCount = addedEntries.count;
    NSUInteger rejectedCount = requestedCount - MIN(requestedCount, validInputCount);
    NSUInteger duplicateCount = validInputCount - MIN(validInputCount, canonicalEntries.count);

    NSString *activeOutcome = [activeResult[@"outcome"] isKindOfClass:[NSString class]]
        ? activeResult[@"outcome"] : @"failed";
    NSString *futureOutcome = [futureResult[@"outcome"] isKindOfClass:[NSString class]]
        ? futureResult[@"outcome"] : @"failed";
    BOOL activeVerified = !activeExpected ||
        (activeError == nil && [activeOutcome isEqualToString:@"verified"] &&
         [activeResult[@"active_verified"] boolValue]);
    BOOL futureVerified = !futureExpected ||
        (futureError == nil && [futureOutcome isEqualToString:@"verified"] &&
         [futureResult[@"future_verified"] boolValue]);
    BOOL activePathSucceeded = activeExpected && activeVerified;
    BOOL futurePathSucceeded = futureExpected && futureVerified;
    BOOL activeSettingsPersisted = !activeExpected || [activeResult[@"settings_persisted"] boolValue];
    BOOL futureSettingsPersisted = !futureExpected || [futureResult[@"settings_persisted"] boolValue];
    BOOL settingsPersisted = blocklistFilePersisted && activeSettingsPersisted && futureSettingsPersisted;

    NSString *target = activeExpected && futureExpected ? @"active_and_future" :
        (activeExpected ? @"active" : (futureExpected ? @"future" : @"none"));
    NSString *skipReason = @"none";
    NSString *outcome = @"failed";
    NSString *failedStage = @"none";
    if (!usedInCommittedSchedule) {
        outcome = @"skipped";
        skipReason = blockRunning ? @"bundle_not_in_committed_schedule" : @"not_committed";
        failedStage = @"commitment_resolution";
    } else if (!activeExpected && !futureExpected) {
        outcome = @"skipped";
        skipReason = blockRunning ? @"no_active_segment" : @"no_matching_future_jobs";
        failedStage = @"future_resolution";
    } else if (!bundleSaved || !blocklistFilePersisted) {
        outcome = @"failed";
        failedStage = @"persist";
    } else if (timedOut) {
        outcome = (activePathSucceeded || futurePathSucceeded) ? @"partial" : @"failed";
        failedStage = activeExpected && !activeVerified ? @"active_apply" : @"future_apply";
    } else if (activeVerified && futureVerified && settingsPersisted) {
        outcome = @"verified";
    } else {
        outcome = (activePathSucceeded || futurePathSucceeded) ? @"partial" : @"failed";
        NSString *activeStage = [activeResult[@"failed_stage"] isKindOfClass:[NSString class]]
            ? activeResult[@"failed_stage"] : @"precondition";
        NSString *futureStage = [futureResult[@"failed_stage"] isKindOfClass:[NSString class]]
            ? futureResult[@"failed_stage"] : @"precondition";
        if (activeExpected && !activeVerified) {
            failedStage = SCStrictifyFailureStageFromDaemonStage(activeStage, YES);
        } else if (futureExpected && !futureVerified) {
            failedStage = SCStrictifyFailureStageFromDaemonStage(futureStage, NO);
        } else {
            failedStage = @"settings_sync";
        }
    }

    NSDictionary *applyResult = [activeResult[@"apply_result"] isKindOfClass:[NSDictionary class]]
        ? activeResult[@"apply_result"] : @{};
    NSDictionary *entryCounts = [applyResult[@"entry_counts"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"entry_counts"] : @{};
    NSDictionary *hosts = [applyResult[@"hosts"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"hosts"] : @{};
    NSDictionary *packetFilter = [applyResult[@"packet_filter"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"packet_filter"] : @{};
    NSDictionary *apps = [applyResult[@"apps"] isKindOfClass:[NSDictionary class]]
        ? applyResult[@"apps"] : @{};
    BOOL hasPhysicalApplyResult = activeExpected && applyResult.count > 0;

    NSString *layer = @"unknown";
    if (hasPhysicalApplyResult &&
        (!SCStrictifyStatusSucceeded(hosts[@"ready"]) ||
        !SCStrictifyStatusSucceeded(hosts[@"write"]) ||
         !SCStrictifyStatusSucceeded(hosts[@"verify"]))) {
        layer = @"hosts";
    } else if (hasPhysicalApplyResult &&
               (!SCStrictifyStatusSucceeded(packetFilter[@"anchor_open"]) ||
               !SCStrictifyStatusSucceeded(packetFilter[@"anchor_write"]) ||
                !SCStrictifyStatusSucceeded(packetFilter[@"verify"]))) {
        layer = @"pf";
    } else if (hasPhysicalApplyResult &&
               ([apps[@"kill_failure_count"] unsignedIntegerValue] > 0 ||
                (appEntryCount > 0 && ![apps[@"monitoring_after"] boolValue]))) {
        layer = @"apps";
    } else if (!settingsPersisted) {
        layer = @"settings";
    } else if (![outcome isEqualToString:@"verified"]) {
        layer = @"verification";
    }

    NSString *pfCommand = [packetFilter[@"command"] isKindOfClass:[NSString class]]
        ? packetFilter[@"command"] : @"none";
    if ([pfCommand isEqualToString:@"start"]) pfCommand = @"load";
    if (![@[@"none", @"load", @"refresh", @"append"] containsObject:pfCommand]) pfCommand = @"none";

    NSUInteger durationMilliseconds = (NSUInteger)llround(
        MAX(0, [[NSDate date] timeIntervalSinceDate:startedAt]) * 1000.0);
    NSMutableDictionary<NSString *, id> *fields = [@{
        @"operation": @"strictify",
        @"outcome": outcome,
        @"target": target,
        @"failed_stage": failedStage,
        @"skip_reason": skipReason,
        @"layer": layer,
        @"pf_command": pfCommand,
        @"is_allowlist": @NO,
        @"bundle_saved": @(bundleSaved),
        @"blocklist_file_persisted": @(blocklistFilePersisted),
        @"used_in_committed_schedule": @(usedInCommittedSchedule),
        @"block_running": @(blockRunning),
        @"active_expected": @(activeExpected),
        @"active_precondition_matched": @(activeExpected &&
            ![failedStage isEqualToString:@"active_precondition"] &&
            ![failedStage isEqualToString:@"canonicalize"] &&
            ![failedStage isEqualToString:@"lock"]),
        @"active_verified": @(activeVerified),
        @"active_physical_reapply_attempted": @([activeResult[@"physical_reapply_attempted"] boolValue]),
        @"future_verified": @(futureVerified),
        @"xpc_completed": @(!timedOut),
        @"settings_persisted": @(settingsPersisted),
        @"hosts_ready": @(SCStrictifyStatusSucceeded(hosts[@"ready"])),
        @"hosts_write_succeeded": @(SCStrictifyStatusSucceeded(hosts[@"write"])),
        @"hosts_verification_succeeded": @(SCStrictifyStatusSucceeded(hosts[@"verify"])),
        @"pf_anchor_open_succeeded": @(SCStrictifyStatusSucceeded(packetFilter[@"anchor_open"])),
        @"pf_anchor_write_succeeded": @(SCStrictifyStatusSucceeded(packetFilter[@"anchor_write"])),
        @"pf_main_configuration_write_succeeded": @(SCStrictifyStatusSucceeded(packetFilter[@"main_config_write"])),
        @"pf_verification_succeeded": @(SCStrictifyStatusSucceeded(packetFilter[@"verify"])),
        @"app_monitoring_before": @([apps[@"monitoring_before"] boolValue]),
        @"app_monitoring_after": @([apps[@"monitoring_after"] boolValue]),
        @"operation_sequence": @(SCNextStrictifyOperationSequence()),
        @"requested_addition_count": @(requestedCount),
        @"canonical_addition_count": @(canonicalEntries.count),
        @"duplicate_addition_count": @(duplicateCount),
        @"input_entry_count": @(requestedCount),
        @"valid_entry_count": @(validInputCount),
        @"rejected_entry_count": @(rejectedCount),
        @"app_entry_count": @(appEntryCount),
        @"site_entry_count": @(siteEntryCount),
        @"dns_lookup_count": @([entryCounts[@"dns_lookup_count"] unsignedIntegerValue]),
        @"dns_resolved_host_count": @([entryCounts[@"dns_resolved_host_count"] unsignedIntegerValue]),
        @"dns_resolved_address_count": @([entryCounts[@"dns_resolved_address_count"] unsignedIntegerValue]),
        @"dns_failure_count": @([entryCounts[@"dns_failure_count"] unsignedIntegerValue]),
        @"unapplied_entry_count": @([entryCounts[@"unapplied_count"] unsignedIntegerValue]),
        @"blocked_app_count": @([apps[@"blocked_count"] unsignedIntegerValue]),
        @"app_kill_attempt_count": @([apps[@"kill_attempt_count"] unsignedIntegerValue]),
        @"app_terminate_success_count": @([apps[@"terminate_success_count"] unsignedIntegerValue]),
        @"app_force_kill_count": @([apps[@"force_kill_count"] unsignedIntegerValue]),
        @"app_kill_failure_count": @([apps[@"kill_failure_count"] unsignedIntegerValue]),
        @"duration_milliseconds": @(durationMilliseconds),
        @"pf_exit_code": @([packetFilter[@"exit_code"] integerValue]),
        @"future_candidate_count": @([futureResult[@"candidate_count"] unsignedIntegerValue]),
        @"future_job_count": @([futureResult[@"legacy_candidate_count"] isKindOfClass:[NSNumber class]]
            ? [futureResult[@"legacy_candidate_count"] unsignedIntegerValue]
            : [futureResult[@"candidate_count"] unsignedIntegerValue]),
        @"future_loaded_job_count": @([futureResult[@"loaded_job_count"] unsignedIntegerValue]),
        @"future_launchd_probe_failure_count": @([futureResult[@"launchd_probe_failure_count"] unsignedIntegerValue]),
        @"approval_requested_count": @([futureResult[@"candidate_count"] unsignedIntegerValue]),
        @"approval_matched_count": @([futureResult[@"matched_count"] unsignedIntegerValue]),
        @"approval_updated_count": @([futureResult[@"updated_count"] unsignedIntegerValue]),
        @"approval_skipped_count": @([futureResult[@"skipped_count"] unsignedIntegerValue]),
        @"active_before_count": @([activeResult[@"active_before_count"] unsignedIntegerValue]),
        @"active_after_count": @([activeResult[@"active_after_count"] unsignedIntegerValue]),
        @"daemon_protocol": @(SCDaemonProtocolVersionCurrent),
    } mutableCopy];

    for (NSArray *pair in @[
        @[@"hosts_error_code", hosts[@"error_code"] ?: NSNull.null],
        @[@"pf_error_code", packetFilter[@"error_code"] ?: NSNull.null],
        @[@"app_scan_error_code", apps[@"scan_error_code"] ?: NSNull.null],
    ]) {
        if ([pair[1] isKindOfClass:[NSNumber class]]) fields[pair[0]] = pair[1];
    }

    SCTelemetryEventLevel level = [outcome isEqualToString:@"verified"]
        ? SCTelemetryEventLevelInfo : SCTelemetryEventLevelError;
    [SCSentry captureTelemetryEvent:@"block.strictify_result" level:level fields:fields];
    [[NSUserDefaults standardUserDefaults] setObject:outcome forKey:@"SCLastStrictifyTelemetryOutcome"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([outcome isEqualToString:@"verified"]) {
        [self clearStrictifyRetryStateForOperationToken:operationToken];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:SCScheduleStrictifyDidCompleteNotification
                                                        object:self
                                                      userInfo:@{
        SCScheduleStrictifyOutcomeKey: outcome,
        SCScheduleStrictifyFailedStageKey: failedStage,
        SCScheduleStrictifyOperationTokenKey: operationToken,
    }];
}

- (BOOL)retryLastStrictifyUpdate {
    NSString *operationToken = nil;
    @synchronized (self) {
        operationToken = [self.lastStrictifyOperationToken copy];
    }
    if (operationToken.length == 0) return NO;
    return [self retryStrictifyUpdateForOperationToken:operationToken];
}

- (BOOL)retryStrictifyUpdateForOperationToken:(NSString *)operationToken {
    if (operationToken.length == 0) return NO;

    SCStrictifyRetryState *state = nil;
    @synchronized (self) {
        state = self.strictifyRetryStatesByToken[operationToken];
    }
    if (state.addedEntries.count == 0 || state.bundle.bundleID.length == 0) return NO;

    // Rebase the operation onto the latest saved bundle. A retry must never
    // write an older bundle snapshot over an edit that completed while this
    // operation was in flight.
    SCBlockBundle *currentBundle = [[self bundleWithID:state.bundle.bundleID] copy];
    if (currentBundle == nil) return NO;
    for (NSString *entry in state.addedEntries) {
        if (![currentBundle.entries containsObject:entry]) return NO;
    }

    SCBlockBundle *currentBundleWithoutThisOperation = [currentBundle copy];
    [currentBundleWithoutThisOperation.entries removeObjectsInArray:state.addedEntries];

    BOOL usedInCommittedSchedule =
        [self bundleIsUsedInCommittedSchedule:currentBundle.bundleID];
    BOOL blocklistFilePersisted = !usedInCommittedSchedule;
    if (usedInCommittedSchedule) {
        NSError *error = nil;
        SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
        blocklistFilePersisted = [bridge writeBlocklistFileForBundle:currentBundle error:&error];
        if (error != nil) {
            NSLog(@"SCScheduleManager: Strictify retry file write failed (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
        }
    }

    [self appendCommittedAdditions:state.addedEntries
                         oldBundle:currentBundleWithoutThisOperation
                          toBundle:currentBundle
                       bundleSaved:state.bundleSaved
            blocklistFilePersisted:blocklistFilePersisted
                    operationToken:operationToken];
    return YES;
}

- (NSString *)storeStrictifyRetryStateForEntries:(NSArray<NSString *> *)addedEntries
                                        toBundle:(SCBlockBundle *)bundle
                                     bundleSaved:(BOOL)bundleSaved
                                  operationToken:(NSString *)operationToken {
    NSString *token = operationToken.length > 0 ? [operationToken copy] : NSUUID.UUID.UUIDString;
    SCStrictifyRetryState *state = [[SCStrictifyRetryState alloc] init];
    state.addedEntries = [addedEntries copy] ?: @[];
    state.bundle = [bundle copy];
    state.bundleSaved = bundleSaved;

    @synchronized (self) {
        if (self.strictifyRetryStatesByToken[token] == nil) {
            [self.strictifyRetryTokenOrder addObject:token];
        }
        self.strictifyRetryStatesByToken[token] = state;
        self.lastStrictifyOperationToken = token;

        // Completion sheets are short lived. Keep a small bounded set so a
        // long-running app session cannot accumulate retry snapshots forever.
        while (self.strictifyRetryTokenOrder.count > 16) {
            NSString *oldestToken = self.strictifyRetryTokenOrder.firstObject;
            [self.strictifyRetryTokenOrder removeObjectAtIndex:0];
            [self.strictifyRetryStatesByToken removeObjectForKey:oldestToken];
        }
    }
    return token;
}

- (void)clearStrictifyRetryStateForOperationToken:(NSString *)operationToken {
    if (operationToken.length == 0) return;
    @synchronized (self) {
        [self.strictifyRetryStatesByToken removeObjectForKey:operationToken];
        [self.strictifyRetryTokenOrder removeObject:operationToken];
        if ([self.lastStrictifyOperationToken isEqualToString:operationToken]) {
            self.lastStrictifyOperationToken = self.strictifyRetryTokenOrder.lastObject;
        }
    }
}

- (nullable SCBlockBundle *)bundleWithID:(NSString *)bundleID {
    for (SCBlockBundle *bundle in self.mutableBundles) {
        if ([bundle.bundleID isEqualToString:bundleID]) {
            return bundle;
        }
    }
    return nil;
}

- (NSInteger)indexOfBundleWithID:(NSString *)bundleID {
    for (NSUInteger i = 0; i < self.mutableBundles.count; i++) {
        if ([self.mutableBundles[i].bundleID isEqualToString:bundleID]) {
            return i;
        }
    }
    return NSNotFound;
}

- (void)reorderBundles:(NSArray<SCBlockBundle *> *)bundles {
    [self.mutableBundles removeAllObjects];
    [self.mutableBundles addObjectsFromArray:bundles];

    // Update display order
    for (NSUInteger i = 0; i < self.mutableBundles.count; i++) {
        self.mutableBundles[i].displayOrder = i;
    }

    [self save];
    [self postChangeNotification];
}

#pragma mark - Week Settings

- (NSArray<NSNumber *> *)daysToDisplay {
    return [self daysToDisplayForWeekOffset:0];
}

- (NSArray<NSNumber *> *)daysToDisplayForWeekOffset:(NSInteger)weekOffset {
    if (weekOffset == 0) {
        // Current week - show remaining days from today
        return [SCWeeklySchedule remainingDaysInWeekStartingMonday:YES];
    } else {
        // Future weeks - show all days
        return [SCWeeklySchedule allDaysStartingMonday:YES];
    }
}

- (NSArray<NSNumber *> *)allDaysInOrder {
    return [SCWeeklySchedule allDaysStartingMonday:YES];
}

#pragma mark - Multi-Week Schedules

- (NSString *)weekKeyForOffset:(NSInteger)weekOffset {
    NSDate *weekStart;
    if (weekOffset == 0) {
        weekStart = [SCWeeklySchedule startOfCurrentWeek];
    } else {
        NSCalendar *calendar = [NSCalendar currentCalendar];
        weekStart = [calendar dateByAddingUnit:NSCalendarUnitDay
                                         value:weekOffset * 7
                                        toDate:[SCWeeklySchedule startOfCurrentWeek]
                                       options:0];
    }
    return [SCWeeklySchedule weekKeyForDate:weekStart];
}

- (NSArray<SCWeeklySchedule *> *)schedulesForWeekOffset:(NSInteger)weekOffset {
    NSString *weekKey = [self weekKeyForOffset:weekOffset];

    // Check cache first
    if (self.weekSchedulesCache[weekKey]) {
        return [self.weekSchedulesCache[weekKey] copy];
    }

    // Load from NSUserDefaults
    NSString *storageKey = [kWeekSchedulesPrefix stringByAppendingString:weekKey];
    NSArray *scheduleDicts = [[NSUserDefaults standardUserDefaults] objectForKey:storageKey];

    NSMutableArray<SCWeeklySchedule *> *schedules = [NSMutableArray array];
    for (NSDictionary *dict in scheduleDicts) {
        SCWeeklySchedule *schedule = [SCWeeklySchedule scheduleFromDictionary:dict];
        if (schedule) {
            [schedules addObject:schedule];
        }
    }

    // Cache the result
    self.weekSchedulesCache[weekKey] = schedules;

    return [schedules copy];
}

- (nullable SCWeeklySchedule *)scheduleForBundleID:(NSString *)bundleID weekOffset:(NSInteger)weekOffset {
    NSArray<SCWeeklySchedule *> *schedules = [self schedulesForWeekOffset:weekOffset];
    for (SCWeeklySchedule *schedule in schedules) {
        if ([schedule.bundleID isEqualToString:bundleID]) {
            return schedule;
        }
    }
    return nil;
}

- (void)updateSchedule:(SCWeeklySchedule *)schedule forWeekOffset:(NSInteger)weekOffset {
    // Check commitment constraint
    if ([self isCommittedForWeekOffset:weekOffset]) {
        SCWeeklySchedule *oldSchedule = [self scheduleForBundleID:schedule.bundleID weekOffset:weekOffset];
        if (oldSchedule) {
            for (SCDayOfWeek day = SCDayOfWeekSunday; day <= SCDayOfWeekSaturday; day++) {
                if ([self changeWouldLoosenSchedule:oldSchedule toSchedule:schedule forDay:day]) {
                    NSLog(@"Rejecting schedule change that would loosen restrictions while committed");
                    return;
                }
            }
        }
    }

    NSString *weekKey = [self weekKeyForOffset:weekOffset];

    // Ensure cache is loaded
    [self schedulesForWeekOffset:weekOffset];

    NSMutableArray<SCWeeklySchedule *> *schedules = self.weekSchedulesCache[weekKey];
    if (!schedules) {
        schedules = [NSMutableArray array];
        self.weekSchedulesCache[weekKey] = schedules;
    }

    // Find and update or add
    NSInteger index = NSNotFound;
    for (NSUInteger i = 0; i < schedules.count; i++) {
        if ([schedules[i].bundleID isEqualToString:schedule.bundleID]) {
            index = i;
            break;
        }
    }

    if (index != NSNotFound) {
        schedules[index] = schedule;
    } else {
        [schedules addObject:schedule];
    }

    // Save to NSUserDefaults
    [self saveSchedulesForWeekOffset:weekOffset];
    [self postChangeNotification];
}

- (SCWeeklySchedule *)createScheduleForBundle:(SCBlockBundle *)bundle weekOffset:(NSInteger)weekOffset {
    SCWeeklySchedule *schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];

    NSString *weekKey = [self weekKeyForOffset:weekOffset];

    // Ensure cache exists
    if (!self.weekSchedulesCache[weekKey]) {
        self.weekSchedulesCache[weekKey] = [NSMutableArray array];
    }

    [self.weekSchedulesCache[weekKey] addObject:schedule];
    [self saveSchedulesForWeekOffset:weekOffset];

    return schedule;
}

- (void)saveSchedulesForWeekOffset:(NSInteger)weekOffset {
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    NSString *storageKey = [kWeekSchedulesPrefix stringByAppendingString:weekKey];

    NSMutableArray *scheduleDicts = [NSMutableArray array];
    for (SCWeeklySchedule *schedule in self.weekSchedulesCache[weekKey]) {
        [scheduleDicts addObject:[schedule toDictionary]];
    }

    [[NSUserDefaults standardUserDefaults] setObject:scheduleDicts forKey:storageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)removeSchedulesForBundleID:(NSString *)bundleID {
    // Clean weekSchedulesCache for all cached weeks
    for (NSString *weekKey in [self.weekSchedulesCache.allKeys copy]) {
        NSMutableArray *schedules = self.weekSchedulesCache[weekKey];
        NSMutableArray *toRemove = [NSMutableArray array];
        for (SCWeeklySchedule *s in schedules) {
            if ([s.bundleID isEqualToString:bundleID]) {
                [toRemove addObject:s];
            }
        }
        [schedules removeObjectsInArray:toRemove];
    }

    // Clean all SCWeekSchedules_* keys in NSUserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults.allKeys) {
        if ([key hasPrefix:kWeekSchedulesPrefix]) {
            NSArray *scheduleDicts = [defaults objectForKey:key];
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSDictionary *dict in scheduleDicts) {
                if (![dict[@"bundleID"] isEqualToString:bundleID]) {
                    [filtered addObject:dict];
                }
            }
            [defaults setObject:filtered forKey:key];
        }
    }
    [defaults synchronize];
}

#pragma mark - Commitment

- (BOOL)isCommitted {
    return [self isCommittedForWeekOffset:0];
}

- (nullable NSDate *)commitmentEndDate {
    return [self commitmentEndDateForWeekOffset:0];
}

- (BOOL)isCommittedForWeekOffset:(NSInteger)weekOffset {
    NSDate *endDate = [self commitmentEndDateForWeekOffset:weekOffset];
    if (!endDate) return NO;
    return [endDate timeIntervalSinceNow] > 0;
}

- (nullable NSDate *)commitmentEndDateForWeekOffset:(NSInteger)weekOffset {
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    NSString *storageKey = [kWeekCommitmentPrefix stringByAppendingString:weekKey];
    return [[NSUserDefaults standardUserDefaults] objectForKey:storageKey];
}

- (BOOL)commitToWeek {
    return [self commitToWeekWithOffset:0];
}

- (BOOL)commitToWeekWithOffset:(NSInteger)weekOffset {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL verified = NO;
    [self commitToWeekWithOffset:weekOffset completion:^(BOOL didVerify, NSError *error) {
        #pragma unused(error)
        verified = didVerify;
        dispatch_semaphore_signal(semaphore);
    }];
    SCScheduleWaitForSemaphore(semaphore, 0);
    return verified;
}

- (void)commitToWeekWithOffset:(NSInteger)weekOffset
                    completion:(void (^)(BOOL, NSError *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self commitToWeekWithOffset:weekOffset completion:completion];
        });
        return;
    }

    void (^finish)(BOOL, NSError *) = ^(BOOL verified, NSError *error) {
        if (completion != nil) completion(verified, error);
    };
    if (weekOffset < 0 || weekOffset > 1) {
        finish(NO, SCScheduleCommitError(1, @"validate", @"Fence can commit only this week or next week.", NO));
        return;
    }

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *weekStart = [calendar dateByAddingUnit:NSCalendarUnitDay
                                              value:weekOffset * 7
                                             toDate:[SCWeeklySchedule startOfCurrentWeek]
                                            options:0];
    NSDate *weekEnd = [calendar dateByAddingUnit:NSCalendarUnitDay value:7 toDate:weekStart options:0];
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    if (weekStart == nil || weekEnd == nil || weekKey.length != 10) {
        finish(NO, SCScheduleCommitError(2, @"validate", @"Fence could not resolve the selected week.", NO));
        return;
    }

    NSMutableArray<SCBlockBundle *> *enabledBundles = [NSMutableArray array];
    for (SCBlockBundle *bundle in self.mutableBundles) {
        if (!bundle.enabled) continue;
        [enabledBundles addObject:bundle];
        if ([self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset] == nil) {
            [self createScheduleForBundle:bundle weekOffset:weekOffset];
        }
    }

    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    NSArray<SCBlockSegment *> *calculatedSegments =
        [self calculateBlockSegmentsForBundles:enabledBundles weekOffset:weekOffset bridge:bridge];
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
        @"EnableErrorReporting": @(telemetryConsent),
    };

    NSString *commitmentID = NSUUID.UUID.UUIDString;
    NSString *generation = NSUUID.UUID.UUIDString;
    NSDate *now = [NSDate date];
    NSMutableArray<NSDictionary<NSString *, id> *> *requestSegments = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *manifestRecords = [NSMutableArray array];
    NSUInteger aggregateEntryCount = 0;
    NSError *preflightError = nil;

    for (SCBlockSegment *segment in calculatedSegments) {
        if ([segment.endDate compare:now] != NSOrderedDescending ||
            [segment.endDate compare:segment.startDate] != NSOrderedDescending) {
            continue;
        }

        NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];
        NSMutableOrderedSet<NSString *> *sourceBundleIDs = [NSMutableOrderedSet orderedSet];
        for (SCBlockBundle *bundle in segment.activeBundles) {
            if ([[NSUUID alloc] initWithUUIDString:bundle.bundleID] == nil) {
                preflightError = SCScheduleCommitError(3, @"validate", @"A scheduled bundle has an invalid local identifier.", NO);
                break;
            }
            [sourceBundleIDs addObject:bundle.bundleID];
            for (id rawEntry in bundle.entries ?: @[]) {
                NSString *canonical = [rawEntry isKindOfClass:[NSString class]]
                    ? [SCMiscUtilities canonicalBlockEntryFromString:rawEntry] : nil;
                if (canonical == nil) {
                    preflightError = SCScheduleCommitError(4, @"validate", @"A scheduled bundle contains an invalid block entry.", NO);
                    break;
                }
                [entries addObject:canonical];
            }
            if (preflightError != nil) break;
        }
        if (preflightError != nil) break;
        if (entries.count == 0) continue;
        BOOL exceedsAggregateEntryLimit = entries.count > SCScheduleMaximumCommitmentEntries ||
            aggregateEntryCount > SCScheduleMaximumCommitmentEntries - entries.count;
        if (exceedsAggregateEntryLimit ||
            requestSegments.count >= SCScheduleMaximumCommitmentSegments) {
            preflightError = SCScheduleCommitError(5, @"validate", @"The selected week is too large to commit safely.", NO);
            break;
        }
        aggregateEntryCount += entries.count;

        NSString *policyRevision = NSUUID.UUID.UUIDString;
        NSDictionary<NSString *, id> *requestRecord = @{
            @"scheduleID": segment.segmentID,
            @"approvedStartDate": segment.startDate,
            @"approvedEndDate": segment.endDate,
            @"blocklist": entries.array,
            @"isAllowlist": @NO,
            @"blockSettings": blockSettings,
            @"sourceBundleIDs": sourceBundleIDs.array,
            @"policyRevision": policyRevision,
        };
        [requestSegments addObject:requestRecord];
        [manifestRecords addObject:@{
            @"scheduleID": segment.segmentID,
            @"approvedStartDate": segment.startDate,
            @"approvedEndDate": segment.endDate,
            @"sourceBundleIDs": sourceBundleIDs.array,
            @"policyRevision": policyRevision,
        }];
    }

    if (preflightError != nil) {
        [defaults setObject:@"failed" forKey:kLastScheduleCommitOutcomeKey];
        [defaults setObject:@"validate" forKey:kLastScheduleCommitFailureStageKey];
        [defaults synchronize];
        SCEmitScheduleCommitStoreFailure(@"validate", requestSegments.count, 0, weekOffset,
                                         preflightError.code, NO, NO, NO);
        finish(NO, preflightError);
        return;
    }

    SCXPCClient *xpc = [SCXPCClient new];
    [xpc replaceScheduledCommitmentForWeekKey:weekKey
                                weekStartDate:weekStart
                                  weekEndDate:weekEnd
                                 commitmentID:commitmentID
                                   generation:generation
                                     segments:requestSegments
                                        reply:^(NSDictionary<NSString *,id> *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger storedCount = [result[@"segments_stored"] unsignedIntegerValue];
            BOOL storePersisted = [result[@"store_persisted"] boolValue];
            BOOL postWriteMatch = [result[@"post_write_match"] boolValue];
            BOOL reconcileSucceeded = [result[@"reconcile_succeeded"] boolValue];
            BOOL storeVerified = storePersisted && postWriteMatch && storedCount == requestSegments.count;

            NSString *stage = [result[@"failed_stage"] isKindOfClass:[NSString class]]
                ? result[@"failed_stage"] : nil;
            NSSet<NSString *> *allowedStages = [NSSet setWithArray:@[
                @"authorize", @"validate", @"lock", @"persist", @"evaluate"
            ]];
            if (![allowedStages containsObject:stage]) {
                if ([error.domain isEqualToString:NSOSStatusErrorDomain]) {
                    stage = @"authorize";
                } else if ([error.domain isEqualToString:@"org.eyebeam.Fence.DaemonCompatibility.Handshake"]) {
                    stage = @"compatibility";
                } else {
                    stage = @"transport";
                }
            }

            if (!storeVerified) {
                [defaults setObject:@"failed" forKey:kLastScheduleCommitOutcomeKey];
                [defaults setObject:stage forKey:kLastScheduleCommitFailureStageKey];
                [defaults synchronize];
                if (![SCMiscUtilities errorIsAuthCanceled:error]) {
                    SCEmitScheduleCommitStoreFailure(stage, requestSegments.count, storedCount,
                                                     weekOffset, error.code, storePersisted,
                                                     postWriteMatch, reconcileSucceeded);
                }
                NSError *reportedError = error ?: SCScheduleCommitError(
                    6, stage, @"Fence could not verify the root-owned schedule store.", storePersisted);
                finish(NO, reportedError);
                return;
            }

            NSDictionary<NSString *, id> *manifest = @{
                @"schemaVersion": @2,
                @"weekKey": weekKey,
                @"commitmentID": commitmentID,
                @"generation": generation,
                @"weekStartDate": weekStart,
                @"weekEndDate": weekEnd,
                @"schedules": manifestRecords,
            };
            [defaults setObject:weekEnd forKey:[kWeekCommitmentPrefix stringByAppendingString:weekKey]];
            [defaults setObject:manifest forKey:[kWeekScheduleManifestPrefix stringByAppendingString:weekKey]];
            [defaults setObject:(reconcileSucceeded ? @"verified" : @"stored")
                         forKey:kLastScheduleCommitOutcomeKey];
            if (reconcileSucceeded) {
                [defaults removeObjectForKey:kLastScheduleCommitFailureStageKey];
            } else {
                [defaults setObject:@"evaluate" forKey:kLastScheduleCommitFailureStageKey];
            }
            BOOL localPersisted = [defaults synchronize];

            [SCVersionTracker markHasEverCommitted];
            [self postChangeNotification];
            if (!localPersisted) {
                NSError *manifestError = SCScheduleCommitError(
                    7, @"manifest", @"The root schedule was saved, but Fence could not verify its local schedule index.", YES);
                SCEmitScheduleCommitStoreFailure(@"manifest", requestSegments.count, storedCount,
                                                 weekOffset, manifestError.code, YES, YES,
                                                 reconcileSucceeded);
                finish(NO, manifestError);
                return;
            }
            if (!reconcileSucceeded) {
                NSError *evaluationError = SCScheduleCommitError(
                    8, @"evaluate", @"The root schedule was saved and locked, but immediate enforcement verification did not finish.", YES);
                SCEmitScheduleCommitStoreFailure(@"evaluate", requestSegments.count, storedCount,
                                                 weekOffset, evaluationError.code, YES, YES, NO);
                finish(NO, evaluationError);
                return;
            }
            finish(YES, nil);
        });
    }];
}

- (BOOL)changeWouldLoosenSchedule:(SCWeeklySchedule *)oldSchedule
                      toSchedule:(SCWeeklySchedule *)newSchedule
                          forDay:(SCDayOfWeek)day {
    NSArray<SCTimeRange *> *oldWindows = [oldSchedule allowedWindowsForDay:day];
    NSArray<SCTimeRange *> *newWindows = [newSchedule allowedWindowsForDay:day];

    // Calculate total allowed minutes
    NSInteger oldTotal = 0;
    for (SCTimeRange *range in oldWindows) {
        oldTotal += [range durationMinutes];
    }

    NSInteger newTotal = 0;
    for (SCTimeRange *range in newWindows) {
        newTotal += [range durationMinutes];
    }

    // If new has MORE allowed time, it's looser
    if (newTotal > oldTotal) {
        return YES;
    }

    // Check if any new window extends beyond old windows
    // (More sophisticated check for partial overlap)
    for (SCTimeRange *newRange in newWindows) {
        BOOL coveredByOld = NO;
        for (SCTimeRange *oldRange in oldWindows) {
            // Check if new range is fully contained within old range
            if ([newRange startMinutes] >= [oldRange startMinutes] &&
                [newRange endMinutes] <= [oldRange endMinutes]) {
                coveredByOld = YES;
                break;
            }
        }
        if (!coveredByOld && newRange.durationMinutes > 0) {
            return YES; // New window not covered by any old window
        }
    }

    return NO;
}

#pragma mark - Segment-Based Block Merging

- (NSArray<SCBlockSegment *> *)calculateBlockSegmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                     weekOffset:(NSInteger)weekOffset
                                                         bridge:(SCScheduleLaunchdBridge *)bridge {
    // Delegate to the variant that accepts schedules, using self's schedules
    return [self calculateBlockSegmentsForBundles:bundles
                                        schedules:nil
                                       weekOffset:weekOffset
                                           bridge:bridge];
}

- (NSArray<SCBlockSegment *> *)calculateBlockSegmentsForBundles:(NSArray<SCBlockBundle *> *)bundles
                                                      schedules:(NSArray<SCWeeklySchedule *> *)schedules
                                                     weekOffset:(NSInteger)weekOffset
                                                         bridge:(SCScheduleLaunchdBridge *)bridge {
    // Step 1: Collect all block windows for all bundles, tagged with their bundle
    NSMutableArray<NSDictionary *> *allWindows = [NSMutableArray array];

    for (SCBlockBundle *bundle in bundles) {
        SCWeeklySchedule *schedule = nil;

        // If schedules were passed in, look up from there
        if (schedules) {
            for (SCWeeklySchedule *s in schedules) {
                if ([s.bundleID isEqualToString:bundle.bundleID]) {
                    schedule = s;
                    break;
                }
            }
        } else {
            // Use self's schedule lookup
            schedule = [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset];
        }

        if (!schedule) {
            schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundle.bundleID];
        }

        NSArray<SCBlockWindow *> *windows = [bridge allBlockWindowsForSchedule:schedule weekOffset:weekOffset];
        for (SCBlockWindow *window in windows) {
            [allWindows addObject:@{
                @"bundle": bundle,
                @"window": window
            }];
        }
    }

    if (allWindows.count == 0) {
        return @[];
    }

    // Step 2: Collect all unique transition times (start and end times)
    NSMutableSet<NSDate *> *transitionTimes = [NSMutableSet set];
    for (NSDictionary *entry in allWindows) {
        SCBlockWindow *window = entry[@"window"];
        [transitionTimes addObject:window.startDate];
        [transitionTimes addObject:window.endDate];
    }

    // Sort transition times chronologically
    NSArray<NSDate *> *sortedTimes = [[transitionTimes allObjects] sortedArrayUsingSelector:@selector(compare:)];

    if (sortedTimes.count < 2) {
        return @[];
    }

    // Step 3: For each pair of consecutive times, determine active bundles
    NSMutableArray<SCBlockSegment *> *segments = [NSMutableArray array];
    NSCalendar *calendar = [NSCalendar currentCalendar];

    for (NSUInteger i = 0; i < sortedTimes.count - 1; i++) {
        NSDate *segmentStart = sortedTimes[i];
        NSDate *segmentEnd = sortedTimes[i + 1];

        // Determine which bundles are active during this segment
        // A bundle is active if its block window contains this segment
        NSMutableArray<SCBlockBundle *> *activeBundles = [NSMutableArray array];

        for (NSDictionary *entry in allWindows) {
            SCBlockBundle *bundle = entry[@"bundle"];
            SCBlockWindow *window = entry[@"window"];

            // Check if this window covers the segment
            // Window must start at or before segment start AND end at or after segment end
            if ([window.startDate compare:segmentStart] != NSOrderedDescending &&
                [window.endDate compare:segmentEnd] != NSOrderedAscending) {
                // Avoid duplicates (same bundle may have multiple windows)
                if (![activeBundles containsObject:bundle]) {
                    [activeBundles addObject:bundle];
                }
            }
        }

        // Skip segments with no active bundles (these are allowed periods)
        if (activeBundles.count == 0) {
            continue;
        }

        // Apply 1-minute gap: end the segment 1 minute early
        NSDate *adjustedEnd = [calendar dateByAddingUnit:NSCalendarUnitMinute value:-1 toDate:segmentEnd options:0];

        // Get day and start minutes for launchd scheduling
        NSDateComponents *startComponents = [calendar components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
                                                        fromDate:segmentStart];
        // Convert NSCalendar weekday (1=Sunday) to SCDayOfWeek (0=Sunday)
        SCDayOfWeek day = (SCDayOfWeek)(startComponents.weekday - 1);
        NSInteger startMinutes = startComponents.hour * 60 + startComponents.minute;

        SCBlockSegment *segment = [SCBlockSegment segmentWithStart:segmentStart
                                                               end:adjustedEnd
                                                               day:day
                                                      startMinutes:startMinutes];
        [segment.activeBundles addObjectsFromArray:activeBundles];
        [segments addObject:segment];
    }

    NSLog(@"SCScheduleManager: Calculated %lu segments from %lu bundles", (unsigned long)segments.count, (unsigned long)bundles.count);
    return segments;
}

- (void)clearCommitmentForDebug {
#ifdef DEBUG
    // Uninstall all launchd jobs
    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    [bridge uninstallAllScheduleJobs:nil];

    // Clear commitment metadata
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCommitmentEndDateKey];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kIsCommittedKey];

    // Clear week-specific commitment keys
    NSString *currentWeekKey = [self weekKeyForOffset:0];
    NSString *nextWeekKey = [self weekKeyForOffset:1];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[kWeekCommitmentPrefix stringByAppendingString:currentWeekKey]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[kWeekCommitmentPrefix stringByAppendingString:nextWeekKey]];

    // Clear all local week schedules and V2 ID/source manifests.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults.allKeys) {
        if ([key hasPrefix:kWeekSchedulesPrefix] ||
            [key hasPrefix:kWeekScheduleManifestPrefix]) {
            [defaults removeObjectForKey:key];
        }
    }

    // Clear in-memory cache
    [self.weekSchedulesCache removeAllObjects];

    [defaults synchronize];

    // Clear ApprovedSchedules and active block in daemon (requires XPC)
    SCXPCClient *xpc = [[SCXPCClient alloc] init];

    // Clear ApprovedSchedules
    [xpc clearAllApprovedSchedules:^(NSError *error) {
        if (error) {
            NSLog(@"WARNING: Failed to clear approved schedules (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
        } else {
            NSLog(@"SCScheduleManager: Cleared ApprovedSchedules in daemon");
        }
    }];

    // If a block is running, forcibly clear it (DEBUG ONLY)
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"SCScheduleManager: Active block detected, clearing via debug method...");
        [xpc clearBlockForDebug:^(NSError *error) {
            if (error) {
                NSLog(@"WARNING: Failed to clear active block (domain=%@ code=%ld)",
                      error.domain, (long)error.code);
            } else {
                NSLog(@"SCScheduleManager: Active block cleared via debug method");
            }
        }];
    }

    [self postChangeNotification];

    NSLog(@"SCScheduleManager: Cleared all commitments, schedules, and launchd jobs (DEBUG)");
#endif
}

- (void)cleanupExpiredCommitments {
    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];

    // Check recent weeks for expired commitments
    for (NSInteger weekOffset = -4; weekOffset <= 0; weekOffset++) {
        NSDate *commitmentEnd = [self commitmentEndDateForWeekOffset:weekOffset];
        if (commitmentEnd && [commitmentEnd timeIntervalSinceNow] < 0) {
            // This week's commitment has expired - uninstall its jobs
            NSString *weekKey = [self weekKeyForOffset:weekOffset];

            NSLog(@"SCScheduleManager: Cleaning up one expired commitment");

            // Uninstall jobs for all bundles from that week
            for (SCBlockBundle *bundle in self.mutableBundles) {
                [bridge uninstallJobsForBundleID:bundle.bundleID error:nil];
            }

            // Clear the commitment metadata
            NSString *storageKey = [kWeekCommitmentPrefix stringByAppendingString:weekKey];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:storageKey];
            [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:[kWeekScheduleManifestPrefix stringByAppendingString:weekKey]];
        }
    }

    // Clean up old week schedules, commitment markers, and V2 local manifests.
    NSString *currentWeekKey = [self weekKeyForOffset:0];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    for (NSString *key in [defaults dictionaryRepresentation].allKeys) {
        NSString *weekKey = nil;

        if ([key hasPrefix:kWeekSchedulesPrefix]) {
            weekKey = [key substringFromIndex:kWeekSchedulesPrefix.length];
        } else if ([key hasPrefix:kWeekCommitmentPrefix]) {
            weekKey = [key substringFromIndex:kWeekCommitmentPrefix.length];
        } else if ([key hasPrefix:kWeekScheduleManifestPrefix]) {
            weekKey = [key substringFromIndex:kWeekScheduleManifestPrefix.length];
        }

        if (weekKey) {
            // ISO date strings sort chronologically - delete only past weeks
            if ([weekKey compare:currentWeekKey] == NSOrderedAscending) {
                NSLog(@"SCScheduleManager: Removing one old week record");
                [defaults removeObjectForKey:key];
            }
        }
    }

    [[NSUserDefaults standardUserDefaults] synchronize];
}

/// Cleans up stale (expired) schedule jobs.
/// Only removes jobs where endDate is in the past, preserving valid jobs from other weeks.
/// This allows multi-week commits without destroying jobs from other committed weeks.
- (void)cleanupStaleScheduleJobs {
    NSDate *now = [NSDate date];
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];

    // Scan all schedule job plists
    NSString *launchAgentsDir = [@"~/Library/LaunchAgents" stringByExpandingTildeInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefix = @"org.eyebeam.selfcontrol.schedule.merged-";

    NSArray *files = [fm contentsOfDirectoryAtPath:launchAgentsDir error:nil];
    NSMutableArray *staleSegmentIDs = [NSMutableArray array];

    for (NSString *file in files) {
        if (![file hasPrefix:prefix] || ![file hasSuffix:@".plist"]) continue;

        NSString *path = [launchAgentsDir stringByAppendingPathComponent:file];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!plist) continue;

        // Parse endDate from ProgramArguments
        NSDate *endDate = nil;
        NSArray *args = plist[@"ProgramArguments"];
        for (NSString *arg in args) {
            if ([arg hasPrefix:@"--enddate="]) {
                NSString *endDateStr = [arg substringFromIndex:10];
                endDate = [isoFormatter dateFromString:endDateStr];
                break;
            }
        }

        // If expired (endDate in past), mark for cleanup
        if (endDate && [now compare:endDate] == NSOrderedDescending) {
            // Extract segmentID from label
            NSString *label = plist[@"Label"];
            NSArray *parts = [label componentsSeparatedByString:@".merged-"];
            if (parts.count > 1) {
                NSString *remainder = parts[1];
                NSString *segmentID = [remainder componentsSeparatedByString:@"."].firstObject;
                if (segmentID.length > 0) {
                    [staleSegmentIDs addObject:segmentID];
                    NSLog(@"SCScheduleManager: Found one stale schedule job");
                }
            }
        }
    }

    // Cleanup stale jobs via daemon XPC
    if (staleSegmentIDs.count > 0) {
        NSLog(@"SCScheduleManager: Cleaning up %lu stale schedule jobs", (unsigned long)staleSegmentIDs.count);
        SCXPCClient *xpc = [[SCXPCClient alloc] init];

        for (NSString *segmentID in staleSegmentIDs) {
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            [xpc cleanupStaleSchedule:segmentID reply:^(NSError *error) {
                if (error) {
                    NSLog(@"SCScheduleManager: Schedule cleanup failed (domain=%@ code=%ld)",
                          error.domain, (long)error.code);
                } else {
                    NSLog(@"SCScheduleManager: Cleaned up one stale schedule");
                }
                dispatch_semaphore_signal(sema);
            }];

            // Wait for cleanup (with run loop to avoid deadlock)
            if (![NSThread isMainThread]) {
                dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
            } else {
                while (dispatch_semaphore_wait(sema, DISPATCH_TIME_NOW)) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                }
            }
        }
    } else {
        NSLog(@"SCScheduleManager: No stale schedule jobs to cleanup");
    }
}

#pragma mark - Status Display

- (NSString *)statusStringForBundleID:(NSString *)bundleID {
    SCWeeklySchedule *schedule = [self scheduleForBundleID:bundleID weekOffset:0];
    if (!schedule) {
        // No schedule for current week = not active, return empty
        return @"";
    }

    NSString *baseStatus = [schedule currentStatusString];

    // If no next state change (empty string), use commitment end date
    // This happens when bundle is blocked all week with no allowed windows
    if (baseStatus.length == 0) {
        NSDate *commitmentEnd = [self commitmentEndDateForWeekOffset:0];
        if (commitmentEnd) {
            return [self formatStatusStringForDate:commitmentEnd];
        }
        return @"";  // Fallback
    }
    return baseStatus;
}

/// Formats a date as "till X" - shows just time if today, otherwise day + time
- (NSString *)formatStatusStringForDate:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSCalendar *calendar = [NSCalendar currentCalendar];

    if ([calendar isDateInToday:date]) {
        formatter.dateFormat = @"h:mma";  // Just time: "11:59pm"
    } else {
        formatter.dateFormat = @"EEE h:mma";  // Day + time: "Sun 11:59pm"
    }
    return [NSString stringWithFormat:@"till %@", [formatter stringFromDate:date]];
}

- (BOOL)wouldBundleBeAllowed:(NSString *)bundleID {
    SCWeeklySchedule *schedule = [self scheduleForBundleID:bundleID weekOffset:0];
    if (!schedule) {
        // No schedule for current week = not active = allowed
        return YES;
    }
    return [schedule isAllowedNow];
}

#pragma mark - Persistence

- (void)save {
    // Save bundles
    NSMutableArray *bundleDicts = [NSMutableArray array];
    for (SCBlockBundle *bundle in self.mutableBundles) {
        [bundleDicts addObject:[bundle toDictionary]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:bundleDicts forKey:kBundlesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)reload {
    [self.mutableBundles removeAllObjects];

    // Load bundles
    NSArray *bundleDicts = [[NSUserDefaults standardUserDefaults] objectForKey:kBundlesKey];
    for (NSDictionary *dict in bundleDicts) {
        SCBlockBundle *bundle = [SCBlockBundle bundleFromDictionary:dict];
        if (bundle) {
            [self.mutableBundles addObject:bundle];
        }
    }

    // Sort bundles by display order
    [self.mutableBundles sortUsingComparator:^NSComparisonResult(SCBlockBundle *b1, SCBlockBundle *b2) {
        return [@(b1.displayOrder) compare:@(b2.displayOrder)];
    }];
}

- (NSDictionary<NSString *, NSNumber *> *)telemetryStructuralSnapshot {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *domainName = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *persistentDomain = domainName.length > 0
        ? [defaults persistentDomainForName:domainName] ?: @{}
        : @{};

    id rawBundlesValue = persistentDomain[kBundlesKey];
    NSUInteger rawBundleCount = [rawBundlesValue isKindOfClass:[NSArray class]]
        ? [rawBundlesValue count] : 0;

    NSUInteger rawScheduleCount = 0;
    NSUInteger decodedScheduleCount = 0;
    NSUInteger commitmentCount = 0;
    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        NSString *weekKey = [self weekKeyForOffset:weekOffset];
        NSString *scheduleKey = [kWeekSchedulesPrefix stringByAppendingString:weekKey];
        id rawSchedulesValue = persistentDomain[scheduleKey];
        if ([rawSchedulesValue isKindOfClass:[NSArray class]]) {
            rawScheduleCount += [rawSchedulesValue count];
        }
        decodedScheduleCount += [self schedulesForWeekOffset:weekOffset].count;
        if ([self isCommittedForWeekOffset:weekOffset]) commitmentCount += 1;
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *installedJobs = [self installedMergedScheduleIDsByStartKey];
    NSUInteger installedJobCount = 0;
    for (NSArray<NSString *> *matchingJobs in installedJobs.allValues) {
        installedJobCount += matchingJobs.count;
    }

    BOOL activeProjectionAvailable = [self isCommittedForWeekOffset:0];
    NSUInteger expectedActiveEntryCount = 0;
    NSUInteger expectedActiveAppEntryCount = 0;
    NSUInteger expectedActiveSiteEntryCount = 0;
    BOOL expectedRequiresHosts = NO;
    BOOL expectedRequiresPacketFilter = NO;
    if (activeProjectionAvailable) {
        SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
        NSArray<SCBlockSegment *> *segments = [self calculateBlockSegmentsForBundles:[self enabledBundlesForCommittedBlockCalculations]
                                                                          weekOffset:0
                                                                              bridge:bridge];
        NSDate *now = [NSDate date];
        NSMutableOrderedSet<NSString *> *expectedEntries = [NSMutableOrderedSet orderedSet];
        for (SCBlockSegment *segment in segments) {
            if ([segment.startDate compare:now] == NSOrderedDescending ||
                [segment.endDate compare:now] == NSOrderedAscending) {
                continue;
            }
            for (SCBlockBundle *activeBundle in segment.activeBundles) {
                for (id rawEntry in activeBundle.entries ?: @[]) {
                    if (![rawEntry isKindOfClass:[NSString class]]) continue;
                    NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:rawEntry];
                    // Existing opaque legacy entries remain part of the local
                    // projection count; the value itself never leaves memory.
                    [expectedEntries addObject:canonicalEntry ?: rawEntry];
                }
            }
            break;
        }
        expectedActiveEntryCount = expectedEntries.count;
        for (NSString *entry in expectedEntries) {
            SCBlockEntry *blockEntry = [SCBlockEntry entryFromString:entry];
            if (blockEntry.isAppEntry) {
                expectedActiveAppEntryCount += 1;
            } else {
                expectedActiveSiteEntryCount += 1;
                BOOL requiresPacketFilter = [blockEntry.hostname isEqualToString:@"*"] ||
                    [blockEntry.hostname isValidIPAddress] || blockEntry.port != 0;
                expectedRequiresPacketFilter = expectedRequiresPacketFilter || requiresPacketFilter;
                expectedRequiresHosts = expectedRequiresHosts || !requiresPacketFilter;
            }
        }
    }

    BOOL hasScheduleState = rawBundleCount > 0 || rawScheduleCount > 0 || commitmentCount > 0;
    return @{
        @"app_has_schedule_state": @(hasScheduleState),
        @"raw_bundle_count": @(rawBundleCount),
        @"decoded_bundle_count": @(self.mutableBundles.count),
        @"raw_schedule_count": @(rawScheduleCount),
        @"decoded_schedule_count": @(decodedScheduleCount),
        @"commitment_count": @(commitmentCount),
        @"installed_schedule_job_count": @(installedJobCount),
        @"active_projection_available": @(activeProjectionAvailable),
        @"expected_active_entry_count": @(expectedActiveEntryCount),
        @"expected_active_app_entry_count": @(expectedActiveAppEntryCount),
        @"expected_active_site_entry_count": @(expectedActiveSiteEntryCount),
        @"expected_requires_hosts": @(expectedRequiresHosts),
        @"expected_requires_packet_filter": @(expectedRequiresPacketFilter),
    };
}

- (NSDictionary<NSString *, id> *)daemonConsistencyProjection {
    static const NSUInteger kMaximumProjectedSchedules = 512;
    static const NSUInteger kMaximumProjectedEntries = 4096;

    NSDate *now = [NSDate date];
    NSMutableArray<NSDictionary<NSString *, id> *> *expectedApprovals = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *expectedJobs = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *expectedActiveEntries = [NSMutableOrderedSet orderedSet];
    BOOL activeProjectionAvailable = [self isCommittedForWeekOffset:0];
    NSUInteger totalProjectedEntries = 0;

    NSArray<SCBlockBundle *> *enabledBundles = [self enabledBundlesForCommittedBlockCalculations];
    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        if (![self isCommittedForWeekOffset:weekOffset]) continue;
        BOOL usesRootScheduler = [self v2ManifestForWeekOffset:weekOffset] != nil;

        NSArray<SCBlockSegment *> *segments = [self calculateBlockSegmentsForBundles:enabledBundles
                                                                          weekOffset:weekOffset
                                                                              bridge:bridge];
        for (SCBlockSegment *segment in segments) {
            if ([segment.endDate compare:now] != NSOrderedDescending) continue;

            NSMutableOrderedSet<NSString *> *segmentEntries = [NSMutableOrderedSet orderedSet];
            for (SCBlockBundle *bundle in segment.activeBundles) {
                for (id rawEntry in bundle.entries ?: @[]) {
                    if ([rawEntry isKindOfClass:[NSString class]]) {
                        [segmentEntries addObject:rawEntry];
                    }
                }
            }
            if (segmentEntries.count == 0) continue;
            totalProjectedEntries += segmentEntries.count;
            if (expectedApprovals.count >= kMaximumProjectedSchedules ||
                totalProjectedEntries > kMaximumProjectedEntries) {
                return @{
                    @"schema_version": @1,
                    @"projection_valid": @NO,
                    @"active_projection_available": @(activeProjectionAvailable),
                    @"active_entries": @[],
                    @"approval_schedules": @[],
                    @"job_schedules": @[],
                };
            }

            NSDictionary<NSString *, id> *descriptor = @{
                @"entries": segmentEntries.array,
                @"start_date": segment.startDate,
                @"end_date": segment.endDate,
            };
            if ([segment.startDate compare:now] == NSOrderedDescending) {
                [expectedApprovals addObject:descriptor];
                if (!usesRootScheduler) [expectedJobs addObject:descriptor];
            } else if (weekOffset == 0) {
                [expectedActiveEntries addObjectsFromArray:segmentEntries.array];
            }
        }
    }

    return @{
        @"schema_version": @1,
        @"projection_valid": @YES,
        @"active_projection_available": @(activeProjectionAvailable),
        @"active_entries": expectedActiveEntries.array,
        @"approval_schedules": expectedApprovals,
        @"job_schedules": expectedJobs,
    };
}

- (void)clearAllData {
    [self.mutableBundles removeAllObjects];
    [self.weekSchedulesCache removeAllObjects];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kBundlesKey];
    [defaults removeObjectForKey:kCommitmentEndDateKey];
    [defaults removeObjectForKey:kIsCommittedKey];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:kWeekSchedulesPrefix] ||
            [key hasPrefix:kWeekCommitmentPrefix] ||
            [key hasPrefix:kWeekScheduleManifestPrefix]) {
            [defaults removeObjectForKey:key];
        }
    }
    [defaults synchronize];

    [self postChangeNotification];
}

#pragma mark - Notifications

- (void)postChangeNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:SCScheduleManagerDidChangeNotification
                                                        object:self];
}

#pragma mark - Emergency Unlock Credits

- (NSInteger)emergencyUnlockCreditsRemaining {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Initialize credits on first access
    if (![defaults boolForKey:kEmergencyUnlockCreditsInitializedKey]) {
        [defaults setInteger:kDefaultEmergencyUnlockCredits forKey:kEmergencyUnlockCreditsKey];
        [defaults setBool:YES forKey:kEmergencyUnlockCreditsInitializedKey];
        [defaults synchronize];
        return kDefaultEmergencyUnlockCredits;
    }

    return [defaults integerForKey:kEmergencyUnlockCreditsKey];
}

- (BOOL)useEmergencyUnlockCredit {
    NSInteger remaining = [self emergencyUnlockCreditsRemaining];
    if (remaining <= 0) {
        return NO;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:remaining - 1 forKey:kEmergencyUnlockCreditsKey];
    [defaults synchronize];

    NSLog(@"SCScheduleManager: Used emergency unlock credit. %ld remaining.", (long)(remaining - 1));
    return YES;
}

- (void)resetEmergencyUnlockCredits {
#ifdef DEBUG
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:kDefaultEmergencyUnlockCredits forKey:kEmergencyUnlockCreditsKey];
    [defaults synchronize];
    NSLog(@"SCScheduleManager: Reset emergency unlock credits to %ld (DEBUG)", (long)kDefaultEmergencyUnlockCredits);
#endif
}

@end

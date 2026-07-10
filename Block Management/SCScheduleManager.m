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
static NSString * const kCommitmentEndDateKey = @"SCCommitmentEndDate";
static NSString * const kIsCommittedKey = @"SCIsCommitted";
static NSString * const kEmergencyUnlockCreditsKey = @"SCEmergencyUnlockCredits";
static NSString * const kEmergencyUnlockCreditsInitializedKey = @"SCEmergencyUnlockCreditsInitialized";
static const NSInteger kDefaultEmergencyUnlockCredits = 5;
static NSString * const kLastScheduleCommitOutcomeKey = @"SCLastScheduleCommitOutcome";
static NSString * const kLastScheduleCommitFailureStageKey = @"SCLastScheduleCommitFailureStage";

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

static void SCEmitScheduleCommitFailure(NSString *stage,
                                        NSUInteger segmentsPlanned,
                                        NSUInteger segmentsInstalled,
                                        NSInteger weekOffset,
                                        NSInteger errorCode) {
    [SCSentry captureTelemetryEvent:@"schedule.commit_install_failed"
                              level:SCTelemetryEventLevelError
                             fields:@{
        @"stage": stage,
        @"segments_planned": @(segmentsPlanned),
        @"segments_installed": @(segmentsInstalled),
        @"week_offset": @(MAX(0, weekOffset)),
        @"error_code": @(errorCode),
    }];
}

static BOOL SCRollbackScheduleSegments(NSArray<NSString *> *segmentIDs,
                                       SCScheduleLaunchdBridge *bridge,
                                       SCXPCClient *xpc) {
    __block BOOL rollbackSucceeded = YES;
    for (NSString *segmentID in segmentIDs.reverseObjectEnumerator) {
        NSError *unloadError = nil;
        if (![bridge uninstallJobForSegmentID:segmentID error:&unloadError]) {
            rollbackSucceeded = NO;
        }

        dispatch_semaphore_t unregisterSema = dispatch_semaphore_create(0);
        __block NSError *unregisterError = nil;
        [xpc unregisterScheduleWithID:segmentID reply:^(NSError *error) {
            unregisterError = error;
            dispatch_semaphore_signal(unregisterSema);
        }];
        if (!SCScheduleWaitForSemaphore(unregisterSema, 10) || unregisterError != nil) {
            rollbackSucceeded = NO;
        }
    }
    return rollbackSucceeded;
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

        BOOL blocklistFilePersisted = !usedInCommittedSchedule;
        if (usedInCommittedSchedule) {
            // Always update the blocklist file for future jobs
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

- (NSDictionary<NSString *, NSArray<NSString *> *> *)expectedApprovedScheduleBlocklistsForBundle:(SCBlockBundle *)bundle oldBundle:(SCBlockBundle *)oldBundle {
    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    NSDictionary<NSString *, NSArray<NSString *> *> *installedScheduleIDsByStartKey = [self installedMergedScheduleIDsByStartKey];
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *expectedBlocklistsByScheduleID = [NSMutableDictionary dictionary];

    for (NSInteger weekOffset = 0; weekOffset <= 1; weekOffset++) {
        if (![self isCommittedForWeekOffset:weekOffset] ||
            [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset] == nil) {
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
        @"future_job_count": @([futureResult[@"candidate_count"] unsignedIntegerValue]),
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
    // Clean up old week data from NSUserDefaults before committing
    [self cleanupExpiredCommitments];

    NSCalendar *calendar = [NSCalendar currentCalendar];

    // Get the Monday of the target week
    NSDate *weekStart;
    if (weekOffset == 0) {
        weekStart = [SCWeeklySchedule startOfCurrentWeek];
    } else {
        weekStart = [calendar dateByAddingUnit:NSCalendarUnitDay
                                         value:weekOffset * 7
                                        toDate:[SCWeeklySchedule startOfCurrentWeek]
                                       options:0];
    }

    // Week ends on Sunday (6 days after Monday) at 23:59:59
    NSDate *endOfWeek = [calendar dateByAddingUnit:NSCalendarUnitDay value:6 toDate:weekStart options:0];
    // Move to end of day
    NSDateComponents *endOfDayComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                                       fromDate:endOfWeek];
    endOfDayComponents.hour = 23;
    endOfDayComponents.minute = 59;
    endOfDayComponents.second = 59;
    endOfWeek = [calendar dateFromComponents:endOfDayComponents];

    // ═══════════════════════════════════════════════════════════════════════════
    // Install launchd jobs using segment-based merging
    // ═══════════════════════════════════════════════════════════════════════════

    SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
    NSError *error = nil;

    // Cleanup only stale (expired) schedule jobs, preserving valid ones from other weeks
    [self cleanupStaleScheduleJobs];

    // Collect all enabled bundles
    NSMutableArray<SCBlockBundle *> *enabledBundles = [NSMutableArray array];
    for (SCBlockBundle *bundle in self.mutableBundles) {
        if (bundle.enabled) {
            [enabledBundles addObject:bundle];
        } else {
            NSLog(@"SCScheduleManager: Skipping one disabled bundle");
        }
    }

    // Ensure all enabled bundles have a persisted schedule for the committed week
    // Bundles with no drawn allow blocks get an empty schedule (blocked all week)
    // This is scoped to weekOffset, so it won't affect other weeks
    for (SCBlockBundle *bundle in enabledBundles) {
        SCWeeklySchedule *schedule = [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset];
        if (!schedule) {
            NSLog(@"SCScheduleManager: Creating one empty schedule (no allow blocks drawn)");
            [self createScheduleForBundle:bundle weekOffset:weekOffset];
        }
    }

    BOOL commitInstallSucceeded = YES;
    NSString *commitFailureStage = @"verification";
    NSInteger commitFailureCode = 0;
    NSUInteger segmentsPlanned = 0;
    NSUInteger segmentsInstalled = 0;

    if (enabledBundles.count == 0) {
        NSLog(@"SCScheduleManager: No enabled bundles to schedule");
    } else {
        // Calculate merged segments
        NSArray<SCBlockSegment *> *segments = [self calculateBlockSegmentsForBundles:enabledBundles
                                                                          weekOffset:weekOffset
                                                                              bridge:bridge];

        NSLog(@"SCScheduleManager: Installing %lu segment-based jobs", (unsigned long)segments.count);

        // Install daemon ONCE before registering any schedules (will prompt for password)
        SCXPCClient *xpc = [SCXPCClient new];
        dispatch_semaphore_t daemonSema = dispatch_semaphore_create(0);
        __block NSError *daemonError = nil;

        [xpc installDaemon:^(NSError *err) {
            daemonError = err;
            dispatch_semaphore_signal(daemonSema);
        }];

        // Authorization is an explicit user interaction and must not time out
        // while the system password/Touch ID sheet is still open.
        BOOL daemonCompleted = SCScheduleWaitForSemaphore(daemonSema, 0);

        if (!daemonCompleted || daemonError) {
            NSLog(@"ERROR: Failed to install daemon for schedule commit (domain=%@ code=%ld)",
                  daemonError.domain, (long)daemonError.code);
            commitInstallSucceeded = NO;
            commitFailureStage = @"daemon_install";
            commitFailureCode = daemonCompleted ? daemonError.code : 408;
        }

        if (!commitInstallSucceeded) {
            SCEmitScheduleCommitFailure(commitFailureStage, segments.count, 0,
                                        weekOffset, commitFailureCode);
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:@"failed" forKey:kLastScheduleCommitOutcomeKey];
            [defaults setObject:commitFailureStage forKey:kLastScheduleCommitFailureStageKey];
            [defaults synchronize];
            return NO;
        }

        NSLog(@"SCScheduleManager: Daemon installed, proceeding with schedule registration");

        // Install every future job before starting an in-progress segment. If
        // anything fails, every attempted local job and root-owned approval is
        // rolled back before the commitment is persisted.
        NSMutableArray<SCBlockSegment *> *futureSegments = [NSMutableArray array];
        NSMutableArray<SCBlockSegment *> *inProgressSegments = [NSMutableArray array];
        for (SCBlockSegment *segment in segments) {
            if (weekOffset == 0 && [segment.startDate timeIntervalSinceNow] < 0) {
                if ([segment.endDate timeIntervalSinceNow] > 0) {
                    [inProgressSegments addObject:segment];
                } else {
                    NSLog(@"SCScheduleManager: Skipping one past segment");
                }
            } else {
                [futureSegments addObject:segment];
            }
        }
        segmentsPlanned = futureSegments.count + inProgressSegments.count;
        NSMutableArray<NSString *> *attemptedSegmentIDs = [NSMutableArray array];

        for (SCBlockSegment *segment in futureSegments) {
            [attemptedSegmentIDs addObject:segment.segmentID];
            error = nil;
            BOOL success = [bridge installJobForSegmentWithBundles:segment.activeBundles
                                                         segmentID:segment.segmentID
                                                         startDate:segment.startDate
                                                           endDate:segment.endDate
                                                               day:segment.day
                                                      startMinutes:segment.startMinutes
                                                        weekOffset:weekOffset
                                                             error:&error];
            if (!success) {
                NSLog(@"ERROR: Failed to install segment job (domain=%@ code=%ld)",
                      error.domain, (long)error.code);
                commitInstallSucceeded = NO;
                NSString *reportedStage = error.userInfo[SCScheduleLaunchdBridgeFailureStageKey];
                commitFailureStage = [reportedStage isEqualToString:@"schedule_register"]
                    ? @"schedule_register" : @"job_install";
                commitFailureCode = error != nil ? error.code : -1;
                break;
            }
            segmentsInstalled += 1;
        }

        if (commitInstallSucceeded) {
            for (SCBlockSegment *segment in futureSegments) {
                if ([bridge installedJobLabelsForSegmentID:segment.segmentID].count == 0) {
                    commitInstallSucceeded = NO;
                    commitFailureStage = @"verification";
                    commitFailureCode = 2;
                    break;
                }
            }
        }

        if (commitInstallSucceeded) {
            for (SCBlockSegment *segment in inProgressSegments) {
                [attemptedSegmentIDs addObject:segment.segmentID];
                NSError *startError = nil;
                NSLog(@"SCScheduleManager: Starting one in-progress segment immediately");
                if (![bridge startMergedBlockImmediatelyForBundles:segment.activeBundles
                                                        segmentID:segment.segmentID
                                                          endDate:segment.endDate
                                                            error:&startError]) {
                    commitInstallSucceeded = NO;
                    commitFailureStage = @"schedule_register";
                    commitFailureCode = startError != nil ? startError.code : -1;
                    break;
                }
                segmentsInstalled += 1;
            }
        }

        if (!commitInstallSucceeded) {
            BOOL rolledBack = SCRollbackScheduleSegments(attemptedSegmentIDs, bridge, xpc);
            if (!rolledBack) NSLog(@"ERROR: Schedule commit rollback was incomplete");
            SCEmitScheduleCommitFailure(commitFailureStage, segmentsPlanned,
                                        segmentsInstalled, weekOffset, commitFailureCode);
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:@"failed" forKey:kLastScheduleCommitOutcomeKey];
            [defaults setObject:commitFailureStage forKey:kLastScheduleCommitFailureStageKey];
            [defaults synchronize];
            [self postChangeNotification];
            return NO;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════

    // Store commitment end date with week-specific key
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    NSString *storageKey = [kWeekCommitmentPrefix stringByAppendingString:weekKey];
    [[NSUserDefaults standardUserDefaults] setObject:endOfWeek forKey:storageKey];
    [[NSUserDefaults standardUserDefaults] setObject:@"verified" forKey:kLastScheduleCommitOutcomeKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLastScheduleCommitFailureStageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Mark that user has committed (persistent - skips test block prompt on future launches)
    [SCVersionTracker markHasEverCommitted];

    [self postChangeNotification];
    return YES;
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

    // Clear all week schedule data (SCWeekSchedules_*) - wipe schedule drawings
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults.allKeys) {
        if ([key hasPrefix:kWeekSchedulesPrefix]) {
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
        }
    }

    // Clean up old week schedule data (SCWeekSchedules_* and SCWeekCommitment_* for past weeks)
    NSString *currentWeekKey = [self weekKeyForOffset:0];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    for (NSString *key in [defaults dictionaryRepresentation].allKeys) {
        NSString *weekKey = nil;

        if ([key hasPrefix:kWeekSchedulesPrefix]) {
            weekKey = [key substringFromIndex:kWeekSchedulesPrefix.length];
        } else if ([key hasPrefix:kWeekCommitmentPrefix]) {
            weekKey = [key substringFromIndex:kWeekCommitmentPrefix.length];
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
                [expectedJobs addObject:descriptor];
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

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBundlesKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCommitmentEndDateKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kIsCommittedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

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

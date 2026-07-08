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

NSNotificationName const SCScheduleManagerDidChangeNotification = @"SCScheduleManagerDidChangeNotification";

// NSUserDefaults keys (app-layer only, not in SCSettings)
static NSString * const kBundlesKey = @"SCScheduleBundles";
static NSString * const kWeekSchedulesPrefix = @"SCWeekSchedules_"; // + week key (e.g., "2024-12-23")
static NSString * const kWeekCommitmentPrefix = @"SCWeekCommitment_"; // + week key
static NSString * const kCommitmentEndDateKey = @"SCCommitmentEndDate";
static NSString * const kIsCommittedKey = @"SCIsCommitted";
static NSString * const kEmergencyUnlockCreditsKey = @"SCEmergencyUnlockCredits";
static NSString * const kEmergencyUnlockCreditsInitializedKey = @"SCEmergencyUnlockCreditsInitialized";
static const NSInteger kDefaultEmergencyUnlockCredits = 5;

@class SCBlockSegment;

@interface SCScheduleManager ()

@property (nonatomic, strong) NSMutableArray<SCBlockBundle *> *mutableBundles;
// Cache for week-specific schedules: weekKey -> array of schedules
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<SCWeeklySchedule *> *> *weekSchedulesCache;

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
                        toBundle:(SCBlockBundle *)bundle;

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
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"EEE HH:mm";
    return [NSString stringWithFormat:@"<SCBlockSegment %@ - %@ bundles=%@>",
            [fmt stringFromDate:self.startDate],
            [fmt stringFromDate:self.endDate],
            [self.activeBundles valueForKey:@"name"]];
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
            NSLog(@"SCScheduleManager: Preserving %lu removed entries for committed bundle %@",
                  (unsigned long)removedEntries.count, bundle.name);
            for (NSString *entry in removedEntries) {
                if (![bundle.entries containsObject:entry]) {
                    [bundle.entries addObject:entry];
                }
            }
        }

        NSArray<NSString *> *addedEntries = [self entriesInArray:bundle.entries notInArray:oldBundle.entries];

        self.mutableBundles[index] = bundle;
        [self save];

        // ═══════════════════════════════════════════════════════════════════════════
        // Live strictify: If committed and a block is running, update the active block
        // ═══════════════════════════════════════════════════════════════════════════

        if (usedInCommittedSchedule) {
            // Always update the blocklist file for future jobs
            SCScheduleLaunchdBridge *bridge = [[SCScheduleLaunchdBridge alloc] init];
            NSError *error = nil;
            [bridge writeBlocklistFileForBundle:bundle error:&error];
            if (error) {
                NSLog(@"WARNING: Failed to update blocklist file for bundle %@: %@", bundle.name, error);
            }

            if (addedEntries.count > 0) {
                [self appendCommittedAdditions:addedEntries oldBundle:oldBundle toBundle:bundle];
            }
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
                NSLog(@"SCScheduleManager: Skipping approved schedule append for %@ because %lu matching jobs were found",
                      startKey, (unsigned long)matchingSegmentIDs.count);
                continue;
            }

            expectedBlocklistsByScheduleID[matchingSegmentIDs.firstObject] = [self expectedBlocklistForSegment:segment oldBundle:oldBundle];
        }
    }

    return expectedBlocklistsByScheduleID;
}

- (void)appendCommittedAdditions:(NSArray<NSString *> *)addedEntries
                       oldBundle:(SCBlockBundle *)oldBundle
                        toBundle:(SCBlockBundle *)bundle {
    SCXPCClient *xpc = [[SCXPCClient alloc] init];

    NSArray<NSString *> *expectedActiveBlocklist = [self expectedActiveBlocklistForBundle:bundle oldBundle:oldBundle];
    if (expectedActiveBlocklist.count > 0) {
        [xpc appendEntriesToActiveBlocklist:addedEntries
                  matchingExistingBlocklist:expectedActiveBlocklist
                                      reply:^(NSError *appendError) {
            if (appendError) {
                NSLog(@"ERROR: Failed to append active blocklist entries for bundle %@: %@", bundle.name, appendError);
            } else {
                NSLog(@"SCScheduleManager: Appended active blocklist entries for bundle %@", bundle.name);
            }
        }];
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *expectedApprovedBlocklists = [self expectedApprovedScheduleBlocklistsForBundle:bundle oldBundle:oldBundle];
    if (expectedApprovedBlocklists.count == 0) {
        NSLog(@"SCScheduleManager: No safely identifiable approved schedules to update for bundle %@", bundle.name);
        return;
    }

    [xpc appendEntriesToApprovedSchedules:expectedApprovedBlocklists
                                   entries:addedEntries
                                     reply:^(NSError *appendError) {
        if (appendError) {
            NSLog(@"ERROR: Failed to append approved schedule entries for bundle %@: %@", bundle.name, appendError);
        } else {
            NSLog(@"SCScheduleManager: Requested append to %lu approved schedules for bundle %@",
                  (unsigned long)expectedApprovedBlocklists.count, bundle.name);
        }
    }];
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

- (void)commitToWeek {
    [self commitToWeekWithOffset:0];
}

- (void)commitToWeekWithOffset:(NSInteger)weekOffset {
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
            NSLog(@"SCScheduleManager: Skipping disabled bundle %@", bundle.name);
        }
    }

    // Ensure all enabled bundles have a persisted schedule for the committed week
    // Bundles with no drawn allow blocks get an empty schedule (blocked all week)
    // This is scoped to weekOffset, so it won't affect other weeks
    for (SCBlockBundle *bundle in enabledBundles) {
        SCWeeklySchedule *schedule = [self scheduleForBundleID:bundle.bundleID weekOffset:weekOffset];
        if (!schedule) {
            NSLog(@"SCScheduleManager: Creating empty schedule for bundle '%@' (no allow blocks drawn)", bundle.name);
            [self createScheduleForBundle:bundle weekOffset:weekOffset];
        }
    }

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

        // Wait for daemon installation (use run loop to avoid main thread deadlock)
        if (![NSThread isMainThread]) {
            dispatch_semaphore_wait(daemonSema, DISPATCH_TIME_FOREVER);
        } else {
            while (dispatch_semaphore_wait(daemonSema, DISPATCH_TIME_NOW)) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }

        if (daemonError) {
            NSLog(@"ERROR: Failed to install daemon for schedule commit: %@", daemonError);
            return; // Can't proceed without daemon
        }

        NSLog(@"SCScheduleManager: Daemon installed, proceeding with schedule registration");

        // Install a job for each segment
        for (SCBlockSegment *segment in segments) {
            // Skip segments that have already passed (for current week)
            if (weekOffset == 0 && [segment.startDate timeIntervalSinceNow] < 0) {
                // Check if we're currently within this segment
                if ([segment.endDate timeIntervalSinceNow] > 0) {
                    // We're in the middle of this segment - start it immediately!
                    NSLog(@"SCScheduleManager: In-progress segment %@ - starting immediately", segment);
                    NSError *startError = nil;
                    if (![bridge startMergedBlockImmediatelyForBundles:segment.activeBundles
                                                            segmentID:segment.segmentID
                                                              endDate:segment.endDate
                                                                error:&startError]) {
                        NSLog(@"WARNING: Failed to start in-progress segment: %@", startError);
                    }
                } else {
                    NSLog(@"SCScheduleManager: Skipping past segment %@", segment);
                }
                continue;
            }

            // Install launchd job for this segment
            BOOL success = [bridge installJobForSegmentWithBundles:segment.activeBundles
                                                         segmentID:segment.segmentID
                                                         startDate:segment.startDate
                                                           endDate:segment.endDate
                                                               day:segment.day
                                                      startMinutes:segment.startMinutes
                                                        weekOffset:weekOffset
                                                             error:&error];
            if (!success) {
                NSLog(@"ERROR: Failed to install segment job: %@", error);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════

    // Store commitment end date with week-specific key
    NSString *weekKey = [self weekKeyForOffset:weekOffset];
    NSString *storageKey = [kWeekCommitmentPrefix stringByAppendingString:weekKey];
    [[NSUserDefaults standardUserDefaults] setObject:endOfWeek forKey:storageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Mark that user has committed (persistent - skips test block prompt on future launches)
    [SCVersionTracker markHasEverCommitted];

    [self postChangeNotification];
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
    for (SCBlockSegment *seg in segments) {
        NSLog(@"  %@", seg);
    }

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
            NSLog(@"WARNING: Failed to clear ApprovedSchedules: %@", error);
        } else {
            NSLog(@"SCScheduleManager: Cleared ApprovedSchedules in daemon");
        }
    }];

    // If a block is running, forcibly clear it (DEBUG ONLY)
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"SCScheduleManager: Active block detected, clearing via debug method...");
        [xpc clearBlockForDebug:^(NSError *error) {
            if (error) {
                NSLog(@"WARNING: Failed to clear active block: %@", error);
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

            NSLog(@"SCScheduleManager: Cleaning up expired commitment for week %@", weekKey);

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
                NSLog(@"SCScheduleManager: Removing old week data: %@", key);
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
                    NSLog(@"SCScheduleManager: Found stale job %@ (endDate=%@)", segmentID, endDate);
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
                    NSLog(@"SCScheduleManager: Cleanup failed for %@: %@", segmentID, error);
                } else {
                    NSLog(@"SCScheduleManager: Cleaned up stale schedule %@", segmentID);
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

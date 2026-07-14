//
//  SCDaemonScheduler.m
//  selfcontrold
//

#import "SCDaemonScheduler.h"
#include <math.h>
#include <time.h>

NSString * const SCDaemonScheduleSchemaVersionKey = @"schemaVersion";
NSString * const SCDaemonScheduleWeekKey = @"weekKey";
NSString * const SCDaemonScheduleCommitmentIDKey = @"commitmentID";
NSString * const SCDaemonScheduleGenerationKey = @"generation";
NSString * const SCDaemonSchedulePolicyRevisionKey = @"policyRevision";
NSString * const SCDaemonScheduleSourceBundleIDsKey = @"sourceBundleIDs";

NSString * const SCDaemonActiveBlockSourceManual = @"manual";
NSString * const SCDaemonActiveBlockSourceTest = @"test";
NSString * const SCDaemonActiveBlockSourceLegacySchedule = @"legacy_schedule";
NSString * const SCDaemonActiveBlockSourceSchedulerV2 = @"scheduler_v2";

BOOL SCDaemonScheduleEntryCountCanAdd(NSUInteger currentCount,
                                      NSUInteger additionCount,
                                      NSUInteger maximumCount) {
    return currentCount <= maximumCount && additionCount <= maximumCount - currentCount;
}

BOOL SCDaemonScheduleIntervalsOverlap(NSDate *leftStart,
                                      NSDate *leftEnd,
                                      NSDate *rightStart,
                                      NSDate *rightEnd) {
    if (![leftStart isKindOfClass:[NSDate class]] || ![leftEnd isKindOfClass:[NSDate class]] ||
        ![rightStart isKindOfClass:[NSDate class]] || ![rightEnd isKindOfClass:[NSDate class]] ||
        [leftEnd compare:leftStart] != NSOrderedDescending ||
        [rightEnd compare:rightStart] != NSOrderedDescending) return NO;
    return [leftStart compare:rightEnd] == NSOrderedAscending &&
        [rightStart compare:leftEnd] == NSOrderedAscending;
}

static NSString * const SCDaemonSchedulerRecordIDKey = @"scheduleID";
static NSString * const SCDaemonSchedulerStartKey = @"approvedStartDate";
static NSString * const SCDaemonSchedulerEndKey = @"approvedEndDate";
static NSString * const SCDaemonSchedulerOwnerKey = @"controllingUID";
static NSString * const SCDaemonSchedulerBlocklistKey = @"blocklist";
static NSString * const SCDaemonSchedulerBlockSettingsKey = @"blockSettings";

static BOOL SCDaemonSchedulerUUIDString(id value) {
    return [value isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:(NSString *)value] != nil;
}

static BOOL SCDaemonSchedulerStringArray(id value, BOOL requireUUIDs) {
    if (![value isKindOfClass:[NSArray class]]) return NO;
    for (id candidate in (NSArray *)value) {
        if (![candidate isKindOfClass:[NSString class]] ||
            (requireUUIDs && !SCDaemonSchedulerUUIDString(candidate))) return NO;
    }
    return YES;
}

static BOOL SCDaemonSchedulerRecordIsValid(NSString *scheduleID,
                                           NSDictionary<NSString *, id> *record,
                                           uid_t ownerUID) {
    if (!SCDaemonSchedulerUUIDString(scheduleID)) return NO;
    NSNumber *owner = [record[SCDaemonSchedulerOwnerKey] isKindOfClass:[NSNumber class]]
        ? record[SCDaemonSchedulerOwnerKey] : nil;
    NSDate *start = [record[SCDaemonSchedulerStartKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerStartKey] : nil;
    NSDate *end = [record[SCDaemonSchedulerEndKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerEndKey] : nil;
    if (owner == nil || owner.longLongValue <= 0 ||
        (ownerUID != 0 && owner.unsignedIntValue != ownerUID) ||
        start == nil || end == nil || [end compare:start] != NSOrderedDescending ||
        !SCDaemonSchedulerStringArray(record[SCDaemonSchedulerBlocklistKey], NO) ||
        ![record[SCDaemonSchedulerBlockSettingsKey] isKindOfClass:[NSDictionary class]]) return NO;

    id schemaVersionValue = record[SCDaemonScheduleSchemaVersionKey];
    if (schemaVersionValue == nil) return YES;
    if (![schemaVersionValue isKindOfClass:[NSNumber class]]) return NO;
    NSNumber *schemaVersion = schemaVersionValue;
    if (schemaVersion.integerValue == 1) return YES;
    if (schemaVersion.integerValue != 2 ||
        ![record[SCDaemonScheduleWeekKey] isKindOfClass:[NSString class]] ||
        [(NSString *)record[SCDaemonScheduleWeekKey] length] != 10 ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonScheduleCommitmentIDKey]) ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonScheduleGenerationKey]) ||
        !SCDaemonSchedulerUUIDString(record[SCDaemonSchedulePolicyRevisionKey]) ||
        !SCDaemonSchedulerStringArray(record[SCDaemonScheduleSourceBundleIDsKey], YES)) return NO;
    return YES;
}

@interface SCDaemonScheduler ()
@property (nonatomic, copy) SCDaemonSchedulerStateProvider stateProvider;
@property (nonatomic, copy) SCDaemonSchedulerReconcileHandler reconcileHandler;
@property (nonatomic, copy) SCDaemonSchedulerEndHandler endHandler;
@property (nonatomic, copy, nullable) SCDaemonSchedulerAnomalyHandler anomalyHandler;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, nullable) dispatch_source_t boundaryTimer;
@property (nonatomic, nullable) dispatch_source_t backstopTimer;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL evaluationInFlight;
@property (nonatomic) BOOL evaluationPending;
@property (nonatomic, copy) NSString *pendingTrigger;
@property (nonatomic) NSMutableArray *currentCompletions;
@property (nonatomic) NSMutableArray *pendingCompletions;
@end

@implementation SCDaemonScheduler

+ (NSArray<NSDictionary<NSString *,id> *> *)validScheduleRecordsFromApprovedSchedules:(id)approvedSchedules
                                                                               ownerUID:(uid_t)ownerUID {
    if (![approvedSchedules isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *records = [NSMutableArray array];
    [(NSDictionary *)approvedSchedules enumerateKeysAndObjectsUsingBlock:^(id scheduleID, id value, BOOL *stop) {
        if (![scheduleID isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *record = (NSDictionary *)value;
        if (!SCDaemonSchedulerRecordIsValid(scheduleID, record, ownerUID)) return;
        NSMutableDictionary *recordWithID = [record mutableCopy];
        recordWithID[SCDaemonSchedulerRecordIDKey] = scheduleID;
        [records addObject:[recordWithID copy]];
    }];
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult startOrder = [left[SCDaemonSchedulerStartKey] compare:right[SCDaemonSchedulerStartKey]];
        if (startOrder != NSOrderedSame) return startOrder;
        return [left[SCDaemonSchedulerRecordIDKey] compare:right[SCDaemonSchedulerRecordIDKey]];
    }];
    return records;
}

+ (NSDictionary<NSString *,id> *)desiredScheduleRecordAtDate:(NSDate *)now
                                                       records:(NSArray<NSDictionary<NSString *,id> *> *)records {
    if (![now isKindOfClass:[NSDate class]]) return nil;
    NSDictionary *desired = nil;
    for (NSDictionary *record in records) {
        NSDate *start = record[SCDaemonSchedulerStartKey];
        NSDate *end = record[SCDaemonSchedulerEndKey];
        if (![start isKindOfClass:[NSDate class]] || ![end isKindOfClass:[NSDate class]] ||
            [start compare:now] == NSOrderedDescending || [end compare:now] != NSOrderedDescending) continue;
        if (desired == nil || [start compare:desired[SCDaemonSchedulerStartKey]] == NSOrderedDescending ||
            ([start isEqualToDate:desired[SCDaemonSchedulerStartKey]] &&
             [record[SCDaemonSchedulerRecordIDKey] compare:desired[SCDaemonSchedulerRecordIDKey]] == NSOrderedAscending)) {
            desired = record;
        }
    }
    return desired;
}

+ (NSDate *)nextBoundaryAfterDate:(NSDate *)now
                           records:(NSArray<NSDictionary<NSString *,id> *> *)records {
    if (![now isKindOfClass:[NSDate class]]) return nil;
    NSDate *next = nil;
    for (NSDictionary *record in records) {
        for (NSString *key in @[SCDaemonSchedulerStartKey, SCDaemonSchedulerEndKey]) {
            NSDate *candidate = [record[key] isKindOfClass:[NSDate class]] ? record[key] : nil;
            if (candidate == nil || [candidate compare:now] != NSOrderedDescending) continue;
            if (next == nil || [candidate compare:next] == NSOrderedAscending) next = candidate;
        }
    }
    return next;
}

+ (BOOL)activeState:(NSDictionary<NSString *,id> *)state
       matchesRecord:(NSDictionary<NSString *,id> *)record {
    if (![state[@"block_running"] boolValue]) return NO;
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : nil;
    if (![source isEqualToString:SCDaemonActiveBlockSourceLegacySchedule] &&
        ![source isEqualToString:SCDaemonActiveBlockSourceSchedulerV2]) return NO;
    NSNumber *activeOwner = [state[@"active_owner_uid"] isKindOfClass:[NSNumber class]]
        ? state[@"active_owner_uid"] : nil;
    NSNumber *recordOwner = [record[SCDaemonSchedulerOwnerKey] isKindOfClass:[NSNumber class]]
        ? record[SCDaemonSchedulerOwnerKey] : nil;
    if (activeOwner.unsignedIntValue != 0 && recordOwner.unsignedIntValue != 0 &&
        activeOwner.unsignedIntValue != recordOwner.unsignedIntValue) return NO;
    if (![state[@"active_schedule_id"] isEqual:record[SCDaemonSchedulerRecordIDKey]]) return NO;
    NSString *recordRevision = record[SCDaemonSchedulePolicyRevisionKey];
    if (recordRevision != nil && ![state[@"active_policy_revision"] isEqual:recordRevision]) return NO;
    if ([record[SCDaemonScheduleSchemaVersionKey] integerValue] >= 2 &&
        (![state[@"active_commitment_id"] isEqual:record[SCDaemonScheduleCommitmentIDKey]] ||
         ![state[@"active_generation"] isEqual:record[SCDaemonScheduleGenerationKey]])) return NO;

    BOOL recordIsAllowlist = [record[@"isAllowlist"] boolValue];
    if ([state[@"active_is_allowlist"] boolValue] != recordIsAllowlist) return NO;
    NSArray *activeBlocklist = [state[@"active_blocklist"] isKindOfClass:[NSArray class]]
        ? state[@"active_blocklist"] : nil;
    NSArray *recordBlocklist = [record[SCDaemonSchedulerBlocklistKey] isKindOfClass:[NSArray class]]
        ? record[SCDaemonSchedulerBlocklistKey] : nil;
    if (activeBlocklist == nil || recordBlocklist == nil ||
        !SCDaemonSchedulerStringArray(activeBlocklist, NO) ||
        !SCDaemonSchedulerStringArray(recordBlocklist, NO)) return NO;
    NSSet *activeEntries = [NSSet setWithArray:activeBlocklist];
    NSSet *recordEntries = [NSSet setWithArray:recordBlocklist];
    if (recordIsAllowlist) {
        if (![activeEntries isEqualToSet:recordEntries]) return NO;
    } else if (![recordEntries isSubsetOfSet:activeEntries]) {
        // A stricter active denylist is safe (for example if physical apply
        // succeeded before a root-store retry). A weaker one never matches.
        return NO;
    }
    return YES;
}

- (instancetype)initWithStateProvider:(SCDaemonSchedulerStateProvider)stateProvider
                      reconcileHandler:(SCDaemonSchedulerReconcileHandler)reconcileHandler
                            endHandler:(SCDaemonSchedulerEndHandler)endHandler
                         anomalyHandler:(SCDaemonSchedulerAnomalyHandler)anomalyHandler {
    self = [super init];
    if (self) {
        _stateProvider = [stateProvider copy];
        _reconcileHandler = [reconcileHandler copy];
        _endHandler = [endHandler copy];
        _anomalyHandler = [anomalyHandler copy];
        _queue = dispatch_queue_create("org.eyebeam.Fence.daemon-scheduler", DISPATCH_QUEUE_SERIAL);
        _pendingTrigger = @"periodic";
        _currentCompletions = [NSMutableArray array];
        _pendingCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.started) return;
        self.started = YES;
        self.backstopTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.backstopTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                                  60 * NSEC_PER_SEC,
                                  10 * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.backstopTimer, ^{
            [weakSelf evaluateForTrigger:@"periodic"];
        });
        dispatch_resume(self.backstopTimer);
        [self enqueueEvaluationForTrigger:@"startup" completion:nil];
    });
}

- (void)stop {
    dispatch_sync(self.queue, ^{
        self.started = NO;
        if (self.boundaryTimer != nil) {
            dispatch_source_cancel(self.boundaryTimer);
            self.boundaryTimer = nil;
        }
        if (self.backstopTimer != nil) {
            dispatch_source_cancel(self.backstopTimer);
            self.backstopTimer = nil;
        }
        [self.currentCompletions removeAllObjects];
        [self.pendingCompletions removeAllObjects];
    });
}

- (void)evaluateForTrigger:(NSString *)trigger {
    [self evaluateForTrigger:trigger completion:nil];
}

- (void)evaluateForTrigger:(NSString *)trigger
                 completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    dispatch_async(self.queue, ^{
        [self enqueueEvaluationForTrigger:trigger completion:completion];
    });
}

- (void)enqueueEvaluationForTrigger:(NSString *)trigger
                          completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    self.pendingTrigger = [self safeTrigger:trigger];
    if (self.evaluationInFlight) {
        if (completion != nil) [self.pendingCompletions addObject:[completion copy]];
        self.evaluationPending = YES;
        return;
    }
    if (completion != nil) [self.currentCompletions addObject:[completion copy]];
    [self performEvaluationForTrigger:self.pendingTrigger];
}

- (NSString *)safeTrigger:(NSString *)trigger {
    static NSSet<NSString *> *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[@"startup", @"timer", @"wake", @"clock_change",
                                               @"session_change", @"mutation", @"periodic", @"legacy"]];
    });
    return [allowed containsObject:trigger] ? trigger : @"periodic";
}

- (void)performEvaluationForTrigger:(NSString *)trigger {
    self.evaluationInFlight = YES;
    NSDictionary *state = self.stateProvider ? self.stateProvider() : @{};
    BOOL settingsAvailable = [state[@"settings_available"] boolValue];
    if (!settingsAvailable) {
        [self finishEvaluation:@{@"status": @"failed", @"stage": @"load", @"trigger": trigger}];
        [self emitAnomalyForTrigger:trigger transition:@"idle_idle" stage:@"load"
                            outcome:@"failed" state:state record:nil error:nil];
        return;
    }

    BOOL blockRunning = [state[@"block_running"] boolValue];
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : @"unknown";
    BOOL schedulerOwnsActive = [source isEqualToString:SCDaemonActiveBlockSourceLegacySchedule] ||
        [source isEqualToString:SCDaemonActiveBlockSourceSchedulerV2];
    uid_t consoleUID = [state[@"console_uid"] unsignedIntValue];
    uid_t activeOwnerUID = [state[@"active_owner_uid"] unsignedIntValue];
    // A fast-user switch must never make another console user's empty desired
    // set tear down a still-valid scheduled block. Finish the active owner's
    // policy first; once it ends, a fresh evaluation selects the console user.
    uid_t selectedOwner = blockRunning && schedulerOwnsActive && activeOwnerUID != 0
        ? activeOwnerUID : (consoleUID != 0 ? consoleUID : activeOwnerUID);
    NSArray *records = [SCDaemonScheduler validScheduleRecordsFromApprovedSchedules:state[@"approved_schedules"]
                                                                                  ownerUID:selectedOwner];
    NSDate *now = [state[@"now"] isKindOfClass:[NSDate class]] ? state[@"now"] : [NSDate date];
    NSDictionary *desired = [SCDaemonScheduler desiredScheduleRecordAtDate:now records:records];
    BOOL activeMatches = desired != nil && [SCDaemonScheduler activeState:state matchesRecord:desired];

    [self armBoundaryAfterDate:now records:records state:state];
    if (activeMatches || (!blockRunning && desired == nil)) {
        [self finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
        return;
    }

    if (blockRunning && !schedulerOwnsActive) {
        [self finishEvaluation:@{@"status": @"deferred", @"stage": @"select", @"trigger": trigger}];
        return;
    }

    NSString *transition = !blockRunning ? @"idle_active" : (desired == nil ? @"active_idle" : @"active_active");
    // A policy replacement needs a staged PF/hosts/AppBlocker primitive. Keep
    // the currently enforced schedule until its approved end instead of
    // weakening enforcement with remove-then-add during a V2 mutation.
    if (blockRunning && schedulerOwnsActive && desired != nil) {
        [self finishEvaluation:@{@"status": @"deferred", @"stage": @"select", @"trigger": trigger}];
        return;
    }

    if (blockRunning && schedulerOwnsActive) {
        __weak typeof(self) weakSelf = self;
        self.endHandler(^(NSError *error) {
            dispatch_async(weakSelf.queue, ^{
                if (error != nil) {
                    [weakSelf emitAnomalyForTrigger:trigger transition:transition stage:@"teardown"
                                           outcome:@"failed" state:state record:desired error:error];
                    [weakSelf finishEvaluation:@{@"status": @"failed", @"stage": @"teardown", @"trigger": trigger}];
                    return;
                }
                if (desired == nil) {
                    if (consoleUID != 0 && consoleUID != selectedOwner) {
                        // The previous evaluation deliberately finished the
                        // old active owner's schedule after a fast-user
                        // switch. Immediately run once more for the current
                        // console user rather than waiting for the backstop.
                        weakSelf.evaluationPending = YES;
                        weakSelf.pendingTrigger = @"session_change";
                    }
                    [weakSelf finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
                    return;
                }
                [weakSelf reconcileRecord:desired trigger:trigger transition:transition state:state];
            });
        });
        return;
    }

    [self reconcileRecord:desired trigger:trigger transition:transition state:state];
}

- (void)reconcileRecord:(NSDictionary<NSString *, id> *)record
                 trigger:(NSString *)trigger
              transition:(NSString *)transition
                   state:(NSDictionary<NSString *, id> *)state {
    NSString *scheduleID = record[SCDaemonSchedulerRecordIDKey];
    __weak typeof(self) weakSelf = self;
    self.reconcileHandler(scheduleID, record, ^(NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            if (error != nil) {
                [weakSelf emitAnomalyForTrigger:trigger transition:transition stage:@"apply"
                                       outcome:@"failed" state:state record:record error:error];
                [weakSelf finishEvaluation:@{@"status": @"failed", @"stage": @"apply", @"trigger": trigger}];
                return;
            }
            [weakSelf finishEvaluation:@{@"status": @"verified", @"stage": @"none", @"trigger": trigger}];
        });
    });
}

- (void)armBoundaryAfterDate:(NSDate *)now
                      records:(NSArray<NSDictionary<NSString *, id> *> *)records
                        state:(NSDictionary<NSString *, id> *)state {
    NSDate *next = [SCDaemonScheduler nextBoundaryAfterDate:now records:records];
    NSDate *activeEnd = [state[@"block_end_date"] isKindOfClass:[NSDate class]] ? state[@"block_end_date"] : nil;
    if (activeEnd != nil && [activeEnd compare:now] == NSOrderedDescending &&
        (next == nil || [activeEnd compare:next] == NSOrderedAscending)) next = activeEnd;

    if (self.boundaryTimer != nil) {
        dispatch_source_cancel(self.boundaryTimer);
        self.boundaryTimer = nil;
    }
    if (next == nil || !self.started) return;

    NSTimeInterval interval = next.timeIntervalSince1970;
    struct timespec wallTime = {
        .tv_sec = (time_t)floor(interval),
        .tv_nsec = (long)((interval - floor(interval)) * NSEC_PER_SEC),
    };
    self.boundaryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.boundaryTimer, dispatch_walltime(&wallTime, 0), DISPATCH_TIME_FOREVER,
                              1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.boundaryTimer, ^{
        weakSelf.boundaryTimer = nil;
        [weakSelf enqueueEvaluationForTrigger:@"timer" completion:nil];
    });
    dispatch_resume(self.boundaryTimer);
}

- (void)emitAnomalyForTrigger:(NSString *)trigger
                    transition:(NSString *)transition
                         stage:(NSString *)stage
                       outcome:(NSString *)outcome
                         state:(NSDictionary<NSString *, id> *)state
                        record:(NSDictionary<NSString *, id> *)record
                         error:(NSError *)error {
    if (self.anomalyHandler == nil) return;
    NSDate *now = [state[@"now"] isKindOfClass:[NSDate class]] ? state[@"now"] : [NSDate date];
    NSDate *start = [record[SCDaemonSchedulerStartKey] isKindOfClass:[NSDate class]]
        ? record[SCDaemonSchedulerStartKey] : nil;
    NSUInteger minutesLate = start == nil ? 0 : (NSUInteger)floor(MAX(0, [now timeIntervalSinceDate:start]) / 60.0);
    NSString *source = [state[@"active_block_source"] isKindOfClass:[NSString class]]
        ? state[@"active_block_source"] : @"unknown";
    uid_t consoleUID = [state[@"console_uid"] unsignedIntValue];
    uid_t activeOwnerUID = [state[@"active_owner_uid"] unsignedIntValue];
    uid_t selectedOwner = consoleUID != 0 ? consoleUID : activeOwnerUID;
    NSUInteger ownedRecordCount = [[SCDaemonScheduler
        validScheduleRecordsFromApprovedSchedules:state[@"approved_schedules"]
                                           ownerUID:selectedOwner] count];
    self.anomalyHandler(@{
        @"trigger": trigger,
        @"transition": transition,
        @"stage": stage,
        @"outcome": outcome,
        @"applied_source": source,
        @"block_running": @([state[@"block_running"] boolValue]),
        @"stored_segment_count": @(ownedRecordCount),
        @"minutes_late_bucket": @(MIN(minutesLate, (NSUInteger)1440)),
        @"error_code": @(error != nil ? error.code : 0),
    });
}

- (void)finishEvaluation:(NSDictionary<NSString *, id> *)result {
    NSArray *completions = [self.currentCompletions copy];
    [self.currentCompletions removeAllObjects];
    self.evaluationInFlight = NO;
    for (void (^completion)(NSDictionary *) in completions) completion(result);
    if (self.evaluationPending) {
        self.evaluationPending = NO;
        [self.currentCompletions addObjectsFromArray:self.pendingCompletions];
        [self.pendingCompletions removeAllObjects];
        [self performEvaluationForTrigger:self.pendingTrigger];
    }
}

- (void)dealloc {
    if (_boundaryTimer != nil) dispatch_source_cancel(_boundaryTimer);
    if (_backstopTimer != nil) dispatch_source_cancel(_backstopTimer);
}

@end

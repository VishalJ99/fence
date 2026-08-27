//
//  SCScheduleManager.h
//  SelfControl
//
//  Manages bundles and weekly schedules at the app layer (NSUserDefaults).
//  This is purely for UX - does NOT connect to the daemon blocking logic.
//  Designed for safe UX testing without affecting actual blocking.
//

#import <Foundation/Foundation.h>
#import "SCBlockBundle.h"
#import "SCWeeklySchedule.h"
#import "SCTimeRange.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted when bundles or schedules change
extern NSNotificationName const SCScheduleManagerDidChangeNotification;
/// Posted after an explicit committed-bundle addition has either verified or
/// failed/skipped. userInfo contains static outcome/stage strings and an
/// app-local opaque operation token.
extern NSNotificationName const SCScheduleStrictifyDidCompleteNotification;
extern NSString * const SCScheduleStrictifyOutcomeKey;
extern NSString * const SCScheduleStrictifyFailedStageKey;
/// Opaque, app-local identifier for the exact update attempt represented by a
/// strictify completion notification. It is never included in telemetry.
extern NSString * const SCScheduleStrictifyOperationTokenKey;

@interface SCScheduleManager : NSObject

#pragma mark - Singleton

+ (instancetype)sharedManager;

#pragma mark - Bundles

/// All configured bundles
@property (nonatomic, readonly) NSArray<SCBlockBundle *> *bundles;

/// Adds a new bundle
- (void)addBundle:(SCBlockBundle *)bundle;

/// Removes a bundle by ID
- (void)removeBundleWithID:(NSString *)bundleID;

/// Updates an existing bundle
- (void)updateBundle:(SCBlockBundle *)bundle;

/// Repeats the most recent in-memory strictify operation. Returns NO if there
/// is no failed/skipped operation available to retry.
- (BOOL)retryLastStrictifyUpdate;

/// Repeats only the strictify update identified by `operationToken`. This is
/// used by completion UI so overlapping bundle edits cannot retry one
/// another's payload.
- (BOOL)retryStrictifyUpdateForOperationToken:(NSString *)operationToken;

/// Gets a bundle by ID
- (nullable SCBlockBundle *)bundleWithID:(NSString *)bundleID;

/// Reorders bundles
- (void)reorderBundles:(NSArray<SCBlockBundle *> *)bundles;

#pragma mark - Week Settings

/// Returns remaining days in current week (always Mon-Sun)
- (NSArray<NSNumber *> *)daysToDisplay;

/// Returns remaining days for a specific week offset (0 = this week, 1 = next week)
- (NSArray<NSNumber *> *)daysToDisplayForWeekOffset:(NSInteger)weekOffset;

/// Returns all days in order (always Mon-Sun)
- (NSArray<NSNumber *> *)allDaysInOrder;

#pragma mark - Multi-Week Schedules

/// Gets all schedules for a specific week offset (0 = current, 1 = next)
- (NSArray<SCWeeklySchedule *> *)schedulesForWeekOffset:(NSInteger)weekOffset;

/// Gets schedule for a specific bundle and week offset
- (nullable SCWeeklySchedule *)scheduleForBundleID:(NSString *)bundleID weekOffset:(NSInteger)weekOffset;

/// Updates schedule for a specific week offset
- (void)updateSchedule:(SCWeeklySchedule *)schedule forWeekOffset:(NSInteger)weekOffset;

/// Creates an empty schedule for a bundle at a specific week offset
- (SCWeeklySchedule *)createScheduleForBundle:(SCBlockBundle *)bundle weekOffset:(NSInteger)weekOffset;

#pragma mark - Recurring Schedule

/// The single editable seven-day schedule used by recurring commitments.
@property (nonatomic, readonly) NSArray<SCWeeklySchedule *> *recurringSchedules;

/// A legacy current/next draft conflict must be resolved before editing.
@property (nonatomic, readonly) BOOL recurringScheduleMigrationNeedsChoice;

/// Resolves a pinned legacy migration conflict without deleting either source.
- (void)resolveRecurringScheduleMigrationUsingNextWeek:(BOOL)useNextWeek;

- (nullable SCWeeklySchedule *)recurringScheduleForBundleID:(NSString *)bundleID;
- (void)updateRecurringSchedule:(SCWeeklySchedule *)schedule;
- (SCWeeklySchedule *)createRecurringScheduleForBundle:(SCBlockBundle *)bundle;

#pragma mark - Commitment

/// Record existence, rather than lock deadline, defines an active recurring
/// enforcement session.
@property (nonatomic, readonly) BOOL hasRecurringCommitment;
@property (nonatomic, readonly, nullable) NSString *recurringCommitmentGeneration;
@property (nonatomic, readonly) BOOL isRecurringCommitmentLockActive;
@property (nonatomic, readonly, nullable) NSDate *recurringCommitmentLockEndDate;
@property (nonatomic, readonly) NSString *recurringTimeZoneIdentifier;
@property (nonatomic, readonly) BOOL recurringCommitmentFollowsLocationTimeZone;

/// Applies a location-derived named timezone to a root commitment that opted
/// into travel tracking before Commit. Coordinates never enter this layer.
- (void)updateLocationTimeZoneIdentifier:(NSString *)timeZoneIdentifier
                              completion:(void(^)(BOOL updated, NSError * _Nullable error))completion;

/// Legacy V1/V2 absolute commitment data still within its finite window.
@property (nonatomic, readonly) BOOL hasUnexpiredLegacyCommitment;

/// Commits the recurring template. End remains unavailable for 1...7 calendar
/// days; editing stays locked until the commitment is explicitly ended.
- (void)commitRecurringScheduleForDays:(NSInteger)days
                            completion:(void(^)(BOOL verified, NSError * _Nullable error))completion;

/// App-selected wall-time authority for a new recurring commitment. The
/// location coordinator resolves the identifier; this shared layer never
/// receives coordinates or requests Location Services access.
- (void)commitRecurringScheduleForDays:(NSInteger)days
                     timeZoneIdentifier:(NSString *)timeZoneIdentifier
                followsLocationTimeZone:(BOOL)followsLocationTimeZone
                              completion:(void(^)(BOOL verified, NSError * _Nullable error))completion;

/// Adds 1...7 days to the later of the current deadline or now. The helper
/// caps the remaining lock horizon at 14 days and returns the authoritative
/// updated deadline.
- (void)extendRecurringCommitmentByDays:(NSInteger)days
                              completion:(void(^)(BOOL extended, NSError * _Nullable error))completion;

/// Ends an expired recurring commitment. The daemon enforces deadline and
/// Protected Hours eligibility before removing the root record.
- (void)endExpiredRecurringCommitmentWithCompletion:
    (void(^)(BOOL ended, NSError * _Nullable error))completion;

/// Reconciles the app-owned runtime index with the root-owned recurring state.
/// The callback is delivered on the main queue. A successful daemon response
/// is applied once; this method does not retry transport failures.
- (void)refreshRecurringRuntimeStateWithCompletion:
    (void(^)(BOOL refreshed, NSError * _Nullable error))completion;

/// Hydrates state from a handshake-confirmed helper. Protocol 6 responses may
/// omit the timezone pair that was added in protocol 7.
- (void)refreshRecurringRuntimeStateForDaemonProtocolVersion:(NSInteger)protocolVersion
                                                  completion:
    (void(^)(BOOL refreshed, NSError * _Nullable error))completion;

#pragma mark - Break Credits and Protected Hours

@property (nonatomic, readonly) NSInteger breakCreditsPerDay;
@property (nonatomic, readonly) NSInteger breakCreditsRemainingToday;
@property (nonatomic, readonly) NSInteger emergencyUnlockWaitMinutes;
@property (nonatomic, readonly) BOOL canEditProtectionSettings;
- (void)setBreakCreditsPerDay:(NSInteger)allowance;
- (void)setEmergencyUnlockWaitMinutes:(NSInteger)minutes;
- (void)reconcileBreakCreditsForDate:(NSDate *)date forceReset:(BOOL)forceReset;

@property (nonatomic, readonly) BOOL protectedHoursEnabled;
@property (nonatomic, readonly) NSInteger protectedHoursStartMinute;
@property (nonatomic, readonly) NSInteger protectedHoursEndMinute;
@property (nonatomic, readonly) BOOL protectedHoursActiveNow;
@property (nonatomic, readonly) BOOL canEditProtectedHours;
- (void)updateProtectedHoursEnabled:(BOOL)enabled
                        startMinute:(NSInteger)startMinute
                          endMinute:(NSInteger)endMinute
                         completion:(void(^)(BOOL updated, NSError * _Nullable error))completion;

@property (nonatomic, readonly) BOOL hasActiveTimedBreak;
@property (nonatomic, readonly, nullable) NSDate *activeTimedBreakEndDate;
@property (nonatomic, readonly) BOOL canBeginTimedBreak;
@property (nonatomic, readonly) BOOL timedBreakMutationInFlight;
- (void)beginTimedBreakForMinutes:(NSInteger)minutes
                       completion:(void(^)(BOOL started, NSError * _Nullable error))completion;
- (void)endTimedBreakWithCompletion:(void(^)(BOOL ended, NSError * _Nullable error))completion;

/// Whether the current week has an active commitment
@property (nonatomic, readonly) BOOL isCommitted;

/// End date of current week's commitment (nil if not committed)
@property (nonatomic, readonly, nullable) NSDate *commitmentEndDate;

/// Checks if a specific week offset is committed
- (BOOL)isCommittedForWeekOffset:(NSInteger)weekOffset;

/// Gets commitment end date for a specific week offset
- (nullable NSDate *)commitmentEndDateForWeekOffset:(NSInteger)weekOffset;

/// Commits to a specific week (0 = current, 1 = next) through the root-owned
/// V2 schedule store. The callback is delivered on the main queue. `verified`
/// is YES only when persistence, exact post-write verification, and immediate
/// reconciliation all succeeded. If root persistence succeeded but immediate
/// reconciliation did not, the week remains locally locked (fail closed) and
/// the callback returns NO with an error describing that state.
- (void)commitToWeekWithOffset:(NSInteger)weekOffset
                    completion:(void(^)(BOOL verified, NSError * _Nullable error))completion;

/// Synchronous compatibility wrapper. UI code should use the completion-based
/// API so authorization and daemon reconciliation never block the main thread.
- (BOOL)commitToWeekWithOffset:(NSInteger)weekOffset;

/// Legacy method - commits to current week
- (BOOL)commitToWeek;

/// Checks if a change would make the schedule looser (not allowed when committed)
- (BOOL)changeWouldLoosenSchedule:(SCWeeklySchedule *)oldSchedule
                     toSchedule:(SCWeeklySchedule *)newSchedule
                         forDay:(SCDayOfWeek)day;

/// Clears commitment (for testing/debug only)
- (void)clearCommitmentForDebug;

/// Cleans up expired commitments and their launchd jobs
/// Called on app launch and periodically
- (void)cleanupExpiredCommitments;

/// Cleans up stale (expired) schedule jobs only.
/// Preserves valid jobs from other weeks, enabling multi-week commits.
- (void)cleanupStaleScheduleJobs;

#pragma mark - Status Display (UX Only)

/// Returns status string for a specific bundle
- (NSString *)statusStringForBundleID:(NSString *)bundleID;

/// Checks if a bundle WOULD be allowed right now (for display)
- (BOOL)wouldBundleBeAllowed:(NSString *)bundleID;

/// Returns the next effective recurring boundary where one or more enabled
/// bundles begin blocking. The calculation uses the commitment's named
/// timezone and the same half-open compiled policy, timed-break override, and
/// Protected Hours precedence as daemon enforcement.
- (nullable NSDate *)nextRecurringBlockingStartAfterDate:(NSDate *)date
                                        affectedBundleIDs:(NSArray<NSString *> * _Nullable * _Nullable)affectedBundleIDs;

#pragma mark - Persistence

/// Saves all data to NSUserDefaults
- (void)save;

/// Reloads data from NSUserDefaults
- (void)reload;

/// Privacy-safe structural view used by consistency diagnostics. Values are
/// booleans and counts only; no bundle IDs, names, schedule times, dates, or
/// blocklist entries are returned.
- (NSDictionary<NSString *, NSNumber *> *)telemetryStructuralSnapshot;

/// Local-only expected state passed over the authenticated daemon XPC
/// connection for exact consistency comparison. This dictionary can contain
/// block entries and schedule dates and must never be attached to telemetry or
/// written to logs. The daemon returns only booleans and aggregate deltas.
- (NSDictionary<NSString *, id> *)daemonConsistencyProjection;

/// Clears all data (for testing)
- (void)clearAllData;

@end

NS_ASSUME_NONNULL_END

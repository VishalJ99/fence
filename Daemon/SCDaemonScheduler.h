//
//  SCDaemonScheduler.h
//  selfcontrold
//
//  Root-owned wall-clock reconciliation for approved schedule records.
//

#import <Foundation/Foundation.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const SCDaemonScheduleSchemaVersionKey;
FOUNDATION_EXPORT NSString * const SCDaemonScheduleWeekKey;
FOUNDATION_EXPORT NSString * const SCDaemonScheduleCommitmentIDKey;
FOUNDATION_EXPORT NSString * const SCDaemonScheduleGenerationKey;
FOUNDATION_EXPORT NSString * const SCDaemonSchedulePolicyRevisionKey;
FOUNDATION_EXPORT NSString * const SCDaemonScheduleSourceBundleIDsKey;
FOUNDATION_EXPORT NSString * const SCDaemonRecurringTimeZoneIdentifierKey;
FOUNDATION_EXPORT NSString * const SCDaemonRecurringFollowsLocationTimeZoneKey;

FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceManual;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceTest;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceLegacySchedule;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceSchedulerV2;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceSchedulerRecurring;

/// Overflow-safe aggregate cap used while validating one commitment batch.
FOUNDATION_EXPORT BOOL SCDaemonScheduleEntryCountCanAdd(NSUInteger currentCount,
                                                        NSUInteger additionCount,
                                                        NSUInteger maximumCount);
/// Half-open absolute interval overlap; local week keys/timezones are not part
/// of admission once dates have been resolved.
FOUNDATION_EXPORT BOOL SCDaemonScheduleIntervalsOverlap(NSDate *leftStart,
                                                        NSDate *leftEnd,
                                                        NSDate *rightStart,
                                                        NSDate *rightEnd);
/// Recurring commitments have no automatic expiry; while one remains in the
/// root store, the same owner cannot admit a finite V1/V2 commitment.
FOUNDATION_EXPORT BOOL SCDaemonScheduleAdmissionConflictsWithRecurringCommitments(
    id recurringCommitments,
    uid_t ownerUID);

typedef NSDictionary<NSString *, id> * _Nonnull (^SCDaemonSchedulerStateProvider)(void);
typedef void (^SCDaemonSchedulerReconcileHandler)(NSString *scheduleID,
                                                  NSDictionary<NSString *, id> *record,
                                                  void (^completion)(NSError * _Nullable error));
typedef void (^SCDaemonSchedulerEndHandler)(void (^completion)(NSError * _Nullable error));
typedef void (^SCDaemonSchedulerAnomalyHandler)(NSDictionary<NSString *, id> *fields);

/// The scheduler is deliberately dependency-injected and Foundation-only so its
/// selection/timer behavior can be compiled directly into the XCTest target.
@interface SCDaemonScheduler : NSObject

/// Returns validated records owned by `ownerUID`. Passing zero accepts every
/// owner, which is used only for deterministic pre-login selection.
+ (NSArray<NSDictionary<NSString *, id> *> *)validScheduleRecordsFromApprovedSchedules:(id)approvedSchedules
                                                                               ownerUID:(uid_t)ownerUID;

/// Selects the active half-open record (`start <= now < end`). Malformed and
/// foreign-owner records must be filtered first with the method above.
+ (nullable NSDictionary<NSString *, id> *)desiredScheduleRecordAtDate:(NSDate *)now
                                                                records:(NSArray<NSDictionary<NSString *, id> *> *)records;

/// Earliest future start/end boundary, or nil when there is no future work.
+ (nullable NSDate *)nextBoundaryAfterDate:(NSDate *)now
                                    records:(NSArray<NSDictionary<NSString *, id> *> *)records;

/// Validates owner-scoped recurring commitment envelopes from the root store.
+ (NSArray<NSDictionary<NSString *, id> *> *)validRecurringCommitmentsFromValue:(id)value
                                                                        ownerUID:(uid_t)ownerUID;

/// Returns a Monday-first Gregorian calendar rooted in the commitment's
/// accepted timezone. Legacy records without timezone fields use the supplied
/// fallback solely until the startup pinning migration persists them.
+ (NSCalendar *)calendarForRecurringCommitment:(nullable NSDictionary<NSString *, id> *)commitment
                              fallbackTimeZone:(NSTimeZone *)fallbackTimeZone;

/// Materializes the previous/current/next local-week occurrences used by the
/// absolute-record selector. Supplying a calendar makes DST behavior directly
/// testable; production passes an explicit local Gregorian calendar.
+ (NSArray<NSDictionary<NSString *, id> *> *)recurringOccurrenceRecordsAtDate:(NSDate *)now
                                                                    commitments:(NSArray<NSDictionary<NSString *, id> *> *)commitments
                                                                        calendar:(NSCalendar *)calendar;

+ (BOOL)protectedHoursAreActiveAtDate:(NSDate *)date
                            commitment:(NSDictionary<NSString *, id> *)commitment
                               calendar:(NSCalendar *)calendar;

+ (BOOL)protectedHoursEditLockIsActiveAtDate:(NSDate *)date
                                     commitment:(NSDictionary<NSString *, id> *)commitment
                                        calendar:(NSCalendar *)calendar;

+ (nullable NSDate *)nextProtectedHoursBoundaryAfterDate:(NSDate *)date
                                               commitment:(NSDictionary<NSString *, id> *)commitment
                                                  calendar:(NSCalendar *)calendar;

+ (nullable NSDictionary<NSString *, id> *)activeBreakAtDate:(NSDate *)date
                                                        value:(id)value
                                                     ownerUID:(uid_t)ownerUID
                                                   commitment:(nullable NSDictionary<NSString *, id> *)commitment;

+ (BOOL)activeState:(NSDictionary<NSString *, id> *)state
       matchesRecord:(NSDictionary<NSString *, id> *)record;

- (instancetype)initWithStateProvider:(SCDaemonSchedulerStateProvider)stateProvider
                      reconcileHandler:(SCDaemonSchedulerReconcileHandler)reconcileHandler
                            endHandler:(SCDaemonSchedulerEndHandler)endHandler
                         anomalyHandler:(nullable SCDaemonSchedulerAnomalyHandler)anomalyHandler
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stop;
- (void)evaluateForTrigger:(NSString *)trigger;
- (void)evaluateForTrigger:(NSString *)trigger
                 completion:(nullable void (^)(NSDictionary<NSString *, id> *result))completion;

@end

NS_ASSUME_NONNULL_END

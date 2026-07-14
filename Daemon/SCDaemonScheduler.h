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

FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceManual;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceTest;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceLegacySchedule;
FOUNDATION_EXPORT NSString * const SCDaemonActiveBlockSourceSchedulerV2;

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

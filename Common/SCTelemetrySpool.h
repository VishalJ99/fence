//
//  SCTelemetrySpool.h
//  Fence
//
//  Privacy-safe, daemon-owned telemetry queue. The production queue is only
//  exposed to signed Fence clients through SCDaemonProtocol.
//


#import <Foundation/Foundation.h>
#import <sys/types.h>
#import "SCSentry.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const SCTelemetrySpoolErrorDomain;

typedef NS_ENUM(NSInteger, SCTelemetrySpoolErrorCode) {
    SCTelemetrySpoolErrorInvalidArgument = 1,
    SCTelemetrySpoolErrorUnsafePath = 2,
    SCTelemetrySpoolErrorIO = 3,
    SCTelemetrySpoolErrorInvalidConsent = 4,
    SCTelemetrySpoolErrorStaleConsent = 5,
    SCTelemetrySpoolErrorPrivacyRejected = 6,
    SCTelemetrySpoolErrorRecordTooLarge = 7,
};

/// The serialized origin is selected from this enum; callers cannot provide an
/// arbitrary origin string.
typedef NS_ENUM(NSInteger, SCTelemetryOrigin) {
    SCTelemetryOriginDaemon = 0,
    SCTelemetryOriginApp = 1,
    SCTelemetryOriginCLI = 2,
};

@interface SCTelemetrySpool : NSObject

/// Uses the daemon-owned production root: /usr/local/etc/fence-telemetry.
- (instancetype)init;

/// Test seam. The directory itself must have an existing parent. The same
/// no-symlink and permission checks used in production still apply.
- (instancetype)initWithBaseDirectory:(NSString *)baseDirectory NS_DESIGNATED_INITIALIZER;

/// Stores a monotonic consent generation for `uid`. Repeating the same state
/// and generation is idempotent. A newer opt-out purges all queued records.
- (BOOL)setConsentEnabled:(BOOL)enabled
               generation:(NSUInteger)generation
                   forUID:(uid_t)uid
                    error:(NSError * _Nullable * _Nullable)error;

/// Appends one typed record only when the supplied opt-in exactly matches the
/// daemon-owned consent marker. A return value of NO with no error means the
/// record was intentionally skipped because consent was unknown/off/stale.
- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(nullable NSDictionary<NSString *, id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
       consentGeneration:(NSUInteger)consentGeneration
         consentEnabled:(BOOL)consentEnabled
                  error:(NSError * _Nullable * _Nullable)error;

/// Daemon/background variant. It reads the current root-owned consent marker
/// under the queue lock and uses that exact generation. Unknown/off consent
/// skips the record without an error.
- (BOOL)appendEventName:(NSString *)eventName
                  level:(SCTelemetryEventLevel)level
                 fields:(nullable NSDictionary<NSString *, id> *)fields
                 origin:(SCTelemetryOrigin)origin
                 forUID:(uid_t)uid
                  error:(NSError * _Nullable * _Nullable)error;

/// Returns at most 25 validated records for one UID. Records are re-sanitized
/// at this boundary so corrupt/tampered lines fail closed.
- (NSArray<NSDictionary<NSString *, id> *> *)recordsForUID:(uid_t)uid
                                                      limit:(NSUInteger)limit
                                                      error:(NSError * _Nullable * _Nullable)error;

/// Removes matching records. Unknown/already-acknowledged IDs are ignored, so
/// acknowledgements can safely be retried.
- (BOOL)acknowledgeRecordIDs:(NSArray<NSString *> *)recordIDs
                       forUID:(uid_t)uid
                        error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

//
//  SCSentry.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/15/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread after an explicit opt-in or opt-out has been
/// persisted and the in-process Sentry lifecycle has been reconciled.
FOUNDATION_EXPORT NSString * const SCTelemetryConsentDidChangeNotification;

/// NSUserDefaults key holding the monotonic telemetry-consent generation. The
/// value is at least 1 once initialized and advances on each explicit choice.
FOUNDATION_EXPORT NSString * const SCTelemetryConsentGenerationDefaultsKey;

typedef NS_ENUM(NSInteger, SCSentryLogLevel) {
    SCSentryLogLevelDebug,
    SCSentryLogLevelInfo,
    SCSentryLogLevelWarning,
    SCSentryLogLevelError,
};

typedef NS_ENUM(NSInteger, SCTelemetryEventLevel) {
    SCTelemetryEventLevelInfo = 0,
    SCTelemetryEventLevelWarning = 1,
    SCTelemetryEventLevelError = 2,
};

@interface SCSentry : NSObject

+ (void)startSentry:(NSString*)componentId;
+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category;
+ (void)logMessage:(NSString*)message level:(SCSentryLogLevel)level category:(NSString*)category attributes:(nullable NSDictionary<NSString*, id>*)attributes;
+ (void)logMessage:(NSString*)message category:(NSString*)category;
+ (void)captureError:(NSError*)error;
+ (void)captureMessage:(NSString*)message;
+ (BOOL)errorReportingEnabled;
+ (BOOL)showErrorReportingPromptIfNeeded;

/// Records an explicit user choice and applies it immediately. Enabling starts
/// the app SDK only when a valid Fence DSN exists; disabling closes it and
/// purges Fence's dedicated telemetry cache without flushing queued data.
+ (void)setUserErrorReportingEnabled:(BOOL)enabled;

/// Reconciles the SDK with the current explicit-consent defaults. Call this
/// after a defaults-bound preference changes; SCSentry also observes defaults
/// changes after startSentry: is called.
+ (void)synchronizeErrorReportingLifecycle;

/// Whether the SDK is currently active in this process. Root processes always
/// return NO and never initialize a network transport.
+ (BOOL)isSentrySDKActive;

/// Flushes queued Sentry envelopes off the main thread, then invokes completion
/// on the main thread. The completion means the SDK flush attempt finished;
/// offline transports may still retain the event for a later retry.
+ (void)flushWithTimeout:(NSTimeInterval)timeout completion:(void (^)(void))completion;

// Pure-Foundation privacy helpers used by focused serializer tests. The test
// target also compiles SCSentry.m alone through its non-TESTING SDK path for a
// network-free final-envelope integration test.
+ (BOOL)isValidSentryDSNString:(nullable NSString*)dsn;
+ (BOOL)hasExplicitErrorReportingConsentInDefaults:(nullable NSDictionary<NSString*, id>*)defaults;
+ (BOOL)shouldInitializeSentryForRootProcess:(BOOL)isRootProcess
                               configuredDSN:(nullable NSString*)dsn
                                    defaults:(nullable NSDictionary<NSString*, id>*)defaults;
+ (nullable NSString*)dedicatedSentryCacheDirectoryPathForCachesDirectory:(nullable NSString*)cachesDirectory;
+ (NSError*)sanitizedError:(NSError*)error;
+ (NSDictionary<NSString*, id>*)sanitizedDefaultsContextFromDictionary:(nullable NSDictionary<NSString*, id>*)defaults;
+ (NSDictionary<NSString*, id>*)sanitizedSettingsContextFromDictionary:(nullable NSDictionary<NSString*, id>*)settings;
+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)sanitizedEventContextsFromDictionary:(nullable NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)contexts;
+ (nullable NSDictionary<NSString*, NSString*>*)sanitizedBreadcrumbWithMessage:(nullable NSString*)message
                                                                        category:(nullable NSString*)category;
+ (nullable NSDictionary<NSString*, id>*)sanitizedTelemetryFields:(nullable NSDictionary<NSString*, id>*)fields
                                                      forEventName:(NSString*)eventName;

/// Returns a deterministic local-only signature after applying the event's
/// typed privacy schema. Raw entries, paths, dates, and identifiers are
/// rejected before hashing and the signature itself is never uploaded.
+ (nullable NSString*)privacySafeTelemetrySignatureForFields:(nullable NSDictionary<NSString*, id>*)fields
                                                    eventName:(NSString*)eventName;

/// Pure time-window predicate for local event-volume suppression.
+ (BOOL)shouldEmitTelemetrySignature:(nullable NSString*)signature
                   previousSignature:(nullable NSString*)previousSignature
                previousEmissionDate:(nullable NSDate*)previousEmissionDate
                                 now:(NSDate*)now
                 suppressionInterval:(NSTimeInterval)suppressionInterval;

/// Flattens SCBlockApplyResult.dictionaryRepresentation into the typed
/// block.apply_failed or block.strictify_result schema, merges caller-supplied
/// operation context, and validates the complete result. Pass the raw nested
/// dictionary here; captureTelemetryEvent: never accepts that raw shape.
+ (nullable NSDictionary<NSString*, id>*)telemetryFieldsForBlockApplyResultDictionary:(nullable NSDictionary<NSString*, id>*)applyResult
                                                                          eventName:(NSString*)eventName
                                                                 supplementalFields:(nullable NSDictionary<NSString*, id>*)supplementalFields;
+ (nullable NSDictionary<NSString*, id>*)sanitizedSpooledTelemetryRecord:(nullable NSDictionary<NSString*, id>*)record;
+ (BOOL)payloadPassesTelemetryPrivacyTripwire:(nullable id)payload;

/// Captures one allowlisted, typed diagnostic event. Unknown event names and
/// fields are rejected. The returned value is the Sentry event identifier when
/// the SDK is active, otherwise nil.
+ (nullable NSString*)captureTelemetryEvent:(NSString*)eventName
                                      level:(SCTelemetryEventLevel)level
                                     fields:(nullable NSDictionary<NSString*, id>*)fields;

/// Revalidates and captures one exact record returned by the daemon telemetry
/// spool. Disk-supplied tags are never accepted: only the typed event fields,
/// the allowlisted origin, and Fence's own `spooled=true` marker are sent.
+ (nullable NSString*)captureSpooledTelemetryRecord:(nullable NSDictionary<NSString*, id>*)record;

@end

NS_ASSUME_NONNULL_END

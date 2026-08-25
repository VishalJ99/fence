//
//  SCTravelTimezoneManager.h
//  SelfControl
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const SCTravelTimezoneManagerDidChangeNotification;
extern NSString * const SCTravelTimezoneEnabledDefaultsKey;

typedef NS_ENUM(NSInteger, SCTravelTimezoneStatus) {
    SCTravelTimezoneStatusDisabled = 0,
    SCTravelTimezoneStatusNeedsAuthorization,
    SCTravelTimezoneStatusResolving,
    SCTravelTimezoneStatusReady,
    SCTravelTimezoneStatusUnavailable,
};

typedef NS_ENUM(NSInteger, SCTravelTimezoneFailureReason) {
    SCTravelTimezoneFailureReasonNone = 0,
    SCTravelTimezoneFailureReasonPermission,
    SCTravelTimezoneFailureReasonTransient,
};

/// Resolves coarse Core Location updates to timezone identifiers. Coordinates
/// are used only for reverse geocoding and are never persisted by Fence.
@interface SCTravelTimezoneManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) SCTravelTimezoneStatus status;
@property (nonatomic, readonly) SCTravelTimezoneFailureReason failureReason;
/// The timezone accepted from Core Location during this app session. Fence
/// never restores this value from writable preferences when creating a commit.
@property (nonatomic, readonly, nullable) NSString *lastResolvedTimeZoneIdentifier;
/// The last location-derived timezone persisted by the root helper for this
/// user. Coordinates are never stored, and the app cannot seed this value.
@property (nonatomic, readonly, nullable) NSString *lastTrustedTimeZoneIdentifier;
@property (nonatomic, readonly, nullable) NSDate *lastTrustedTimeZoneResolutionDate;

/// Returns the fresh session result, or the root-trusted fallback only after a
/// transient resolution failure. Permission failures and in-flight requests
/// return nil.
- (nullable NSString *)timeZoneIdentifierForCommit;
- (BOOL)usesTrustedTimeZoneForCommit;

/// Changes the pre-commit preference. Calls are ignored while a recurring
/// commitment exists because its travel mode is immutable until it ends.
- (void)setEnabled:(BOOL)enabled;

/// Requests one coarse location update when the preference or the active
/// recurring commitment requires it. Fence never keeps a continuous location
/// subscription running.
- (void)requestTimeZoneRefreshIfNeeded;

/// Retries a timezone already accepted from a one-shot request after the
/// active block reaches a safe boundary. This never requests location.
- (void)retryPendingDaemonTimeZoneUpdateIfNeeded;

/// Requests permission only from an explicit user interaction, never from
/// background launch-at-login startup.
- (void)requestAuthorizationFromUserInteraction;

@end

NS_ASSUME_NONNULL_END

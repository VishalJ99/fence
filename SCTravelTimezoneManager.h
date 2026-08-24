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

/// Resolves coarse Core Location updates to timezone identifiers. Coordinates
/// are used only for reverse geocoding and are never persisted by Fence.
@interface SCTravelTimezoneManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) SCTravelTimezoneStatus status;
/// The timezone accepted from Core Location during this app session. Fence
/// never restores this value from writable preferences when creating a commit.
@property (nonatomic, readonly, nullable) NSString *lastResolvedTimeZoneIdentifier;

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

//
//  SCTravelTimezoneManager.m
//  SelfControl
//

#import "SCTravelTimezoneManager.h"

#import "Block Management/SCScheduleManager.h"
#import "SCXPCClient.h"

NSNotificationName const SCTravelTimezoneManagerDidChangeNotification =
    @"SCTravelTimezoneManagerDidChangeNotification";
NSString * const SCTravelTimezoneEnabledDefaultsKey = @"SCTravelTimezoneEnabled";

// Reduced-accuracy locations may be up to 20 minutes old. Thirty minutes
// rejects stale cached fixes without excluding valid coarse updates.
static NSTimeInterval const SCTravelTimezoneMaximumLocationAge = 30.0 * 60.0;

@interface SCTravelTimezoneManager () <CLLocationManagerDelegate>
@property (nonatomic, strong, nullable) CLLocationManager *locationManager;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, readwrite) SCTravelTimezoneStatus status;
@property (nonatomic, readwrite) SCTravelTimezoneFailureReason failureReason;
@property (nonatomic, copy, nullable) NSString *currentSessionTimeZoneIdentifier;
@property (nonatomic, strong, nullable) NSDate *currentSessionResolutionDate;
@property (nonatomic, copy, readwrite, nullable) NSString *lastTrustedTimeZoneIdentifier;
@property (nonatomic, strong, readwrite, nullable) NSDate *lastTrustedTimeZoneResolutionDate;
@property (nonatomic, copy, nullable) NSString *pendingDaemonTimeZoneIdentifier;
@property (nonatomic) BOOL locationRequestInFlight;
// Root-cache operations share one XPC client. Writes run in order, and a read
// invalidated by a newer write is retried after that write finishes.
@property (nonatomic) BOOL trustedTimeZoneLoadInFlight;
@property (nonatomic) BOOL trustedTimeZoneStoreInFlight;
@property (nonatomic) BOOL trustedTimeZoneReloadAfterStore;
@property (nonatomic) NSUInteger trustedTimeZoneGeneration;
@property (nonatomic, copy, nullable) NSString *queuedTrustedTimeZoneIdentifier;
@property (nonatomic, strong, nullable) SCXPCClient *trustedTimeZoneXPCClient;
- (void)beginOneShotLocationRequest;
- (void)attemptDaemonUpdateForTimeZoneIdentifier:(NSString *)identifier;
- (void)refreshTrustedTimeZone;
- (void)persistTrustedTimeZoneIdentifier:(NSString *)identifier;
@end

@implementation SCTravelTimezoneManager

+ (instancetype)sharedManager {
    static SCTravelTimezoneManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _geocoder = [[CLGeocoder alloc] init];
        _status = self.isEnabled
            ? SCTravelTimezoneStatusNeedsAuthorization
            : SCTravelTimezoneStatusDisabled;
        _failureReason = self.isEnabled
            ? SCTravelTimezoneFailureReasonPermission
            : SCTravelTimezoneFailureReasonNone;
#if !defined(TESTING)
        [self refreshTrustedTimeZone];
#endif
    }
    return self;
}

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:SCTravelTimezoneEnabledDefaultsKey];
}

- (NSString *)lastResolvedTimeZoneIdentifier {
    NSTimeInterval age = -self.currentSessionResolutionDate.timeIntervalSinceNow;
    if (self.currentSessionResolutionDate == nil || age < 0.0 ||
        age > SCTravelTimezoneMaximumLocationAge) {
        return nil;
    }
    return self.currentSessionTimeZoneIdentifier;
}

- (NSString *)timeZoneIdentifierForCommit {
    NSString *freshIdentifier = self.lastResolvedTimeZoneIdentifier;
    BOOL mayUseFreshResult = self.status == SCTravelTimezoneStatusReady ||
        (self.status == SCTravelTimezoneStatusUnavailable &&
         self.failureReason == SCTravelTimezoneFailureReasonTransient);
    if (mayUseFreshResult &&
        [NSTimeZone timeZoneWithName:freshIdentifier] != nil) {
        return freshIdentifier;
    }
    if (self.status == SCTravelTimezoneStatusUnavailable &&
        self.failureReason == SCTravelTimezoneFailureReasonTransient &&
        [NSTimeZone timeZoneWithName:self.lastTrustedTimeZoneIdentifier] != nil) {
        return self.lastTrustedTimeZoneIdentifier;
    }
    return nil;
}

- (BOOL)usesTrustedTimeZoneForCommit {
    return self.status == SCTravelTimezoneStatusUnavailable &&
        self.failureReason == SCTravelTimezoneFailureReasonTransient &&
        self.lastResolvedTimeZoneIdentifier == nil &&
        self.timeZoneIdentifierForCommit != nil;
}

- (void)setEnabled:(BOOL)enabled {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setEnabled:enabled];
        });
        return;
    }

    if ([SCScheduleManager sharedManager].hasRecurringCommitment ||
        self.isEnabled == enabled) {
        return;
    }

    [[NSUserDefaults standardUserDefaults]
        setBool:enabled forKey:SCTravelTimezoneEnabledDefaultsKey];

    if (enabled) {
        [self requestTimeZoneRefreshIfNeeded];
        [self requestAuthorizationFromUserInteraction];
    } else {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusDisabled;
        self.failureReason = SCTravelTimezoneFailureReasonNone;
        [self postChangeNotification];
    }
}

- (void)requestTimeZoneRefreshIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestTimeZoneRefreshIfNeeded];
        });
        return;
    }

    if (![self shouldTrackLocation]) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusDisabled;
        self.failureReason = SCTravelTimezoneFailureReasonNone;
        [self postChangeNotification];
        return;
    }

    [self refreshTrustedTimeZone];

    if (![CLLocationManager locationServicesEnabled]) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
        self.failureReason = SCTravelTimezoneFailureReasonPermission;
        [self postChangeNotification];
        return;
    }

    [self ensureLocationManager];
    CLAuthorizationStatus authorization = self.locationManager.authorizationStatus;
    if (authorization == kCLAuthorizationStatusDenied ||
        authorization == kCLAuthorizationStatusRestricted) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
        self.failureReason = SCTravelTimezoneFailureReasonPermission;
        [self postChangeNotification];
        return;
    }

    if (authorization == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusNeedsAuthorization;
        self.failureReason = SCTravelTimezoneFailureReasonPermission;
        [self postChangeNotification];
        return;
    }

    if (self.locationRequestInFlight || self.geocoder.isGeocoding) return;

    [self beginOneShotLocationRequest];
}

- (void)beginOneShotLocationRequest {
    self.locationRequestInFlight = YES;
    self.status = SCTravelTimezoneStatusResolving;
    self.failureReason = SCTravelTimezoneFailureReasonNone;
    [self postChangeNotification];
    [self.locationManager requestLocation];
}

- (void)requestAuthorizationFromUserInteraction {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestAuthorizationFromUserInteraction];
        });
        return;
    }
    if (![self shouldTrackLocation] || ![CLLocationManager locationServicesEnabled]) return;
    [self ensureLocationManager];
    if (self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    }
}

- (BOOL)shouldTrackLocation {
    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    if (scheduleManager.hasRecurringCommitment) {
        return scheduleManager.recurringCommitmentFollowsLocationTimeZone;
    }
    return self.isEnabled;
}

- (void)ensureLocationManager {
    if (self.locationManager != nil) return;

    CLLocationManager *manager = [[CLLocationManager alloc] init];
    manager.delegate = self;
    manager.desiredAccuracy = kCLLocationAccuracyReduced;
    self.locationManager = manager;
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self requestTimeZoneRefreshIfNeeded];
}

- (void)locationManager:(CLLocationManager *)manager
      didUpdateLocations:(NSArray<CLLocation *> *)locations {
    self.locationRequestInFlight = NO;
    CLLocation *location = nil;
    for (CLLocation *candidate in locations.reverseObjectEnumerator) {
        if ([self isUsableLocation:candidate]) {
            location = candidate;
            break;
        }
    }
    if (location == nil || self.geocoder.isGeocoding) {
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = [self shouldTrackLocation]
            ? SCTravelTimezoneStatusUnavailable : SCTravelTimezoneStatusDisabled;
        self.failureReason = [self shouldTrackLocation]
            ? SCTravelTimezoneFailureReasonTransient : SCTravelTimezoneFailureReasonNone;
        [self postChangeNotification];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.geocoder reverseGeocodeLocation:location
                       completionHandler:^(NSArray<CLPlacemark *> *placemarks,
                                           NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        CLAuthorizationStatus authorization = strongSelf.locationManager.authorizationStatus;
        BOOL stillAuthorized = authorization == kCLAuthorizationStatusAuthorized;
        BOOL shouldTrack = [strongSelf shouldTrackLocation];
        BOOL permissionError = [error.domain isEqualToString:kCLErrorDomain] &&
            error.code == kCLErrorDenied;
        BOOL permissionUnavailable = ![CLLocationManager locationServicesEnabled] ||
            !stillAuthorized || permissionError;
        if (!shouldTrack || error != nil || permissionUnavailable ||
            ![strongSelf isUsableLocation:location]) {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
            strongSelf.status = shouldTrack
                ? SCTravelTimezoneStatusUnavailable : SCTravelTimezoneStatusDisabled;
            strongSelf.failureReason = !shouldTrack
                ? SCTravelTimezoneFailureReasonNone
                : (permissionUnavailable
                    ? SCTravelTimezoneFailureReasonPermission
                    : SCTravelTimezoneFailureReasonTransient);
            [strongSelf postChangeNotification];
            return;
        }

        NSString *identifier = placemarks.firstObject.timeZone.name;
        if (identifier.length == 0 || [NSTimeZone timeZoneWithName:identifier] == nil) {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
            strongSelf.status = SCTravelTimezoneStatusUnavailable;
            strongSelf.failureReason = SCTravelTimezoneFailureReasonTransient;
            [strongSelf postChangeNotification];
            return;
        }
        [strongSelf acceptTimeZoneIdentifier:identifier];
    }];
}

- (void)locationManager:(CLLocationManager *)manager
        didFailWithError:(NSError *)error {
    self.locationRequestInFlight = NO;
    [self.geocoder cancelGeocode];
    self.pendingDaemonTimeZoneIdentifier = nil;
    self.status = [self shouldTrackLocation]
        ? SCTravelTimezoneStatusUnavailable : SCTravelTimezoneStatusDisabled;
    self.failureReason = ![self shouldTrackLocation]
        ? SCTravelTimezoneFailureReasonNone
        : ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied
            ? SCTravelTimezoneFailureReasonPermission
            : SCTravelTimezoneFailureReasonTransient);
    [self postChangeNotification];
}

- (BOOL)isUsableLocation:(nullable CLLocation *)location {
    if (location == nil || location.horizontalAccuracy < 0.0 ||
        !CLLocationCoordinate2DIsValid(location.coordinate)) {
        return NO;
    }

    NSTimeInterval age = fabs(location.timestamp.timeIntervalSinceNow);
    if (age > SCTravelTimezoneMaximumLocationAge) return NO;

    CLLocationSourceInformation *source = location.sourceInformation;
    return source == nil || !source.isSimulatedBySoftware;
}

- (void)acceptTimeZoneIdentifier:(NSString *)identifier {
    self.currentSessionTimeZoneIdentifier = identifier;
    self.currentSessionResolutionDate = [NSDate date];

    self.status = SCTravelTimezoneStatusReady;
    self.failureReason = SCTravelTimezoneFailureReasonNone;
    [self postChangeNotification];
    [self persistTrustedTimeZoneIdentifier:identifier];

    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    if (!scheduleManager.hasRecurringCommitment ||
        !scheduleManager.recurringCommitmentFollowsLocationTimeZone ||
        [scheduleManager.recurringTimeZoneIdentifier isEqualToString:identifier] ||
        [self.pendingDaemonTimeZoneIdentifier isEqualToString:identifier]) {
        return;
    }

    [self attemptDaemonUpdateForTimeZoneIdentifier:identifier];
}

- (void)attemptDaemonUpdateForTimeZoneIdentifier:(NSString *)identifier {
    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    if (self.status != SCTravelTimezoneStatusReady ||
        ![self.currentSessionTimeZoneIdentifier isEqualToString:identifier] ||
        ![self shouldTrackLocation] ||
        !scheduleManager.hasRecurringCommitment ||
        !scheduleManager.recurringCommitmentFollowsLocationTimeZone ||
        [scheduleManager.recurringTimeZoneIdentifier isEqualToString:identifier]) {
        if ([self.pendingDaemonTimeZoneIdentifier isEqualToString:identifier]) {
            self.pendingDaemonTimeZoneIdentifier = nil;
        }
        [self postChangeNotification];
        return;
    }

    self.pendingDaemonTimeZoneIdentifier = identifier;
    __weak typeof(self) weakSelf = self;
    [scheduleManager updateLocationTimeZoneIdentifier:identifier
                                           completion:^(BOOL updated, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil ||
            ![strongSelf.pendingDaemonTimeZoneIdentifier isEqualToString:identifier]) {
            return;
        }

        if (updated || error.code != 409) {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
        }
        [strongSelf postChangeNotification];
    }];
}

- (void)retryPendingDaemonTimeZoneUpdateIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self retryPendingDaemonTimeZoneUpdateIfNeeded];
        });
        return;
    }

    NSString *identifier = self.pendingDaemonTimeZoneIdentifier;
    if (identifier.length == 0) return;

    CLAuthorizationStatus authorization = self.locationManager.authorizationStatus;
    if (![CLLocationManager locationServicesEnabled] ||
        authorization != kCLAuthorizationStatusAuthorized ||
        ![self shouldTrackLocation]) {
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = [self shouldTrackLocation]
            ? SCTravelTimezoneStatusUnavailable : SCTravelTimezoneStatusDisabled;
        self.failureReason = [self shouldTrackLocation]
            ? SCTravelTimezoneFailureReasonPermission : SCTravelTimezoneFailureReasonNone;
        [self postChangeNotification];
        return;
    }

    [self attemptDaemonUpdateForTimeZoneIdentifier:identifier];
}

- (void)refreshTrustedTimeZone {
    if (self.trustedTimeZoneStoreInFlight) {
        self.trustedTimeZoneReloadAfterStore = YES;
        return;
    }
    if (self.trustedTimeZoneLoadInFlight) return;
    self.trustedTimeZoneLoadInFlight = YES;
    NSUInteger generation = self.trustedTimeZoneGeneration;
    if (self.trustedTimeZoneXPCClient == nil) {
        self.trustedTimeZoneXPCClient = [SCXPCClient new];
    }
    SCXPCClient *xpc = self.trustedTimeZoneXPCClient;
    __weak typeof(self) weakSelf = self;
    [xpc getTrustedTravelTimeZone:^(NSDictionary<NSString *,id> *state, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.trustedTimeZoneLoadInFlight = NO;
            if (generation != strongSelf.trustedTimeZoneGeneration) {
                if (strongSelf.trustedTimeZoneStoreInFlight) {
                    strongSelf.trustedTimeZoneReloadAfterStore = YES;
                } else {
                    [strongSelf refreshTrustedTimeZone];
                }
                return;
            }
            if (error != nil) return;

            NSString *identifier = state[@"time_zone_identifier"];
            NSDate *resolvedAt = state[@"resolved_at"];
            if ([state[@"has_trusted_time_zone"] boolValue] &&
                [NSTimeZone timeZoneWithName:identifier] != nil &&
                [resolvedAt isKindOfClass:[NSDate class]]) {
                strongSelf.lastTrustedTimeZoneIdentifier = identifier;
                strongSelf.lastTrustedTimeZoneResolutionDate = resolvedAt;
            } else {
                strongSelf.lastTrustedTimeZoneIdentifier = nil;
                strongSelf.lastTrustedTimeZoneResolutionDate = nil;
            }
            [strongSelf postChangeNotification];
        });
    }];
}

- (void)persistTrustedTimeZoneIdentifier:(NSString *)identifier {
#if defined(TESTING)
    return;
#else
    if (self.trustedTimeZoneStoreInFlight) {
        self.queuedTrustedTimeZoneIdentifier = identifier;
        return;
    }
    self.trustedTimeZoneStoreInFlight = YES;
    self.trustedTimeZoneGeneration += 1;
    NSUInteger generation = self.trustedTimeZoneGeneration;
    if (self.trustedTimeZoneXPCClient == nil) {
        self.trustedTimeZoneXPCClient = [SCXPCClient new];
    }
    SCXPCClient *xpc = self.trustedTimeZoneXPCClient;
    __weak typeof(self) weakSelf = self;
    [xpc storeTrustedTravelTimeZoneIdentifier:identifier
                                        reply:^(NSDictionary<NSString *,id> *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.trustedTimeZoneStoreInFlight = NO;
            if (generation == strongSelf.trustedTimeZoneGeneration && error == nil &&
                [result[@"stored"] boolValue]) {
                NSString *storedIdentifier = result[@"time_zone_identifier"];
                NSDate *resolvedAt = result[@"resolved_at"];
                if ([NSTimeZone timeZoneWithName:storedIdentifier] != nil &&
                    [resolvedAt isKindOfClass:[NSDate class]]) {
                    strongSelf.lastTrustedTimeZoneIdentifier = storedIdentifier;
                    strongSelf.lastTrustedTimeZoneResolutionDate = resolvedAt;
                    [strongSelf postChangeNotification];
                }
            }

            NSString *queuedIdentifier = strongSelf.queuedTrustedTimeZoneIdentifier;
            strongSelf.queuedTrustedTimeZoneIdentifier = nil;
            if (queuedIdentifier.length > 0) {
                [strongSelf persistTrustedTimeZoneIdentifier:queuedIdentifier];
            } else if (strongSelf.trustedTimeZoneReloadAfterStore) {
                strongSelf.trustedTimeZoneReloadAfterStore = NO;
                [strongSelf refreshTrustedTimeZone];
            }
        });
    }];
#endif
}

- (void)postChangeNotification {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SCTravelTimezoneManagerDidChangeNotification
                      object:self];
}

@end

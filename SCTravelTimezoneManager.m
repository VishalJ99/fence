//
//  SCTravelTimezoneManager.m
//  SelfControl
//

#import "SCTravelTimezoneManager.h"

#import "Block Management/SCScheduleManager.h"

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
@property (nonatomic, copy, nullable) NSString *currentSessionTimeZoneIdentifier;
@property (nonatomic, strong, nullable) NSDate *currentSessionResolutionDate;
@property (nonatomic, copy, nullable) NSString *pendingDaemonTimeZoneIdentifier;
@property (nonatomic) BOOL locationRequestInFlight;
- (void)beginOneShotLocationRequest;
- (void)attemptDaemonUpdateForTimeZoneIdentifier:(NSString *)identifier;
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
        [self postChangeNotification];
        return;
    }

    if (![CLLocationManager locationServicesEnabled]) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
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
        [self postChangeNotification];
        return;
    }

    if (authorization == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.locationRequestInFlight = NO;
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusNeedsAuthorization;
        [self postChangeNotification];
        return;
    }

    if (self.locationRequestInFlight || self.geocoder.isGeocoding) return;

    [self beginOneShotLocationRequest];
}

- (void)beginOneShotLocationRequest {
    self.locationRequestInFlight = YES;
    self.status = SCTravelTimezoneStatusResolving;
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
        if (![strongSelf shouldTrackLocation] || error != nil ||
            ![CLLocationManager locationServicesEnabled] || !stillAuthorized ||
            ![strongSelf isUsableLocation:location]) {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
            strongSelf.status = [strongSelf shouldTrackLocation]
                ? SCTravelTimezoneStatusUnavailable : SCTravelTimezoneStatusDisabled;
            [strongSelf postChangeNotification];
            return;
        }

        NSString *identifier = placemarks.firstObject.timeZone.name;
        if (identifier.length == 0 || [NSTimeZone timeZoneWithName:identifier] == nil) {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
            strongSelf.status = SCTravelTimezoneStatusUnavailable;
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
    [self postChangeNotification];

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
        [self postChangeNotification];
        return;
    }

    [self attemptDaemonUpdateForTimeZoneIdentifier:identifier];
}

- (void)postChangeNotification {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SCTravelTimezoneManagerDidChangeNotification
                      object:self];
}

@end

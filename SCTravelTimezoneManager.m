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
        [self startIfEnabled];
        [self requestAuthorizationFromUserInteraction];
    } else {
        [self.locationManager stopUpdatingLocation];
        [self.geocoder cancelGeocode];
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusDisabled;
        [self postChangeNotification];
    }
}

- (void)startIfEnabled {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startIfEnabled];
        });
        return;
    }

    if (![self shouldTrackLocation]) {
        [self.locationManager stopUpdatingLocation];
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusDisabled;
        [self postChangeNotification];
        return;
    }

    if (![CLLocationManager locationServicesEnabled]) {
        [self.geocoder cancelGeocode];
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
        [self postChangeNotification];
        return;
    }

    [self ensureLocationManager];
    CLAuthorizationStatus authorization = self.locationManager.authorizationStatus;
    if (authorization == kCLAuthorizationStatusDenied ||
        authorization == kCLAuthorizationStatusRestricted) {
        [self.geocoder cancelGeocode];
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
        [self postChangeNotification];
        return;
    }

    if (authorization == kCLAuthorizationStatusNotDetermined) {
        self.status = SCTravelTimezoneStatusNeedsAuthorization;
        [self postChangeNotification];
        return;
    }

    // A new automatic commitment must have a recent fix from this app
    // session. Returning from sleep or Settings restarts the resolving state
    // once that acceptance has aged out.
    self.status = self.lastResolvedTimeZoneIdentifier != nil
        ? SCTravelTimezoneStatusReady : SCTravelTimezoneStatusResolving;
    [self postChangeNotification];
    [self.locationManager startUpdatingLocation];
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
    manager.distanceFilter = kCLDistanceFilterNone;
    self.locationManager = manager;
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self startIfEnabled];
}

- (void)locationManager:(CLLocationManager *)manager
      didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (![self isUsableLocation:location] || self.geocoder.isGeocoding) return;

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
            ![strongSelf isUsableLocation:location]) return;

        NSString *identifier = placemarks.firstObject.timeZone.name;
        if (identifier.length == 0 || [NSTimeZone timeZoneWithName:identifier] == nil) return;
        [strongSelf acceptTimeZoneIdentifier:identifier];
    }];
}

- (void)locationManager:(CLLocationManager *)manager
        didFailWithError:(NSError *)error {
    if (error.code == kCLErrorDenied) {
        [self.geocoder cancelGeocode];
        self.pendingDaemonTimeZoneIdentifier = nil;
        self.status = SCTravelTimezoneStatusUnavailable;
        [self postChangeNotification];
    }
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
        ![self.lastResolvedTimeZoneIdentifier isEqualToString:identifier] ||
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

        if (!updated && error.code == 409) {
            // The helper rejected an active-to-active policy change. Keep the
            // root timezone unchanged and retry at a scheduler-sized interval;
            // stationary Macs are not guaranteed another location callback.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                typeof(self) retrySelf = weakSelf;
                if (retrySelf == nil ||
                    ![retrySelf.pendingDaemonTimeZoneIdentifier isEqualToString:identifier]) return;
                [retrySelf attemptDaemonUpdateForTimeZoneIdentifier:identifier];
            });
        } else {
            strongSelf.pendingDaemonTimeZoneIdentifier = nil;
        }
        [strongSelf postChangeNotification];
    }];
}

- (void)postChangeNotification {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SCTravelTimezoneManagerDidChangeNotification
                      object:self];
}

@end

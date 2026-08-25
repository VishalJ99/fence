#import <XCTest/XCTest.h>

#import "SCTravelTimezoneManager.h"

@interface SCTravelTimezoneManager (Testing)
- (BOOL)isUsableLocation:(nullable CLLocation *)location;
- (void)acceptTimeZoneIdentifier:(NSString *)identifier;
- (void)beginOneShotLocationRequest;
@property (nonatomic, strong, nullable) CLLocationManager *locationManager;
@property (nonatomic) BOOL locationRequestInFlight;
@property (nonatomic) SCTravelTimezoneStatus status;
@property (nonatomic) SCTravelTimezoneFailureReason failureReason;
@property (nonatomic, copy, nullable) NSString *lastTrustedTimeZoneIdentifier;
@property (nonatomic, strong, nullable) NSDate *lastTrustedTimeZoneResolutionDate;
@property (nonatomic, strong, nullable) NSDate *currentSessionResolutionDate;
@end

@interface SCRecordingLocationManager : CLLocationManager
@property (nonatomic) NSInteger requestLocationCount;
@property (nonatomic) NSInteger startUpdatingLocationCount;
@end

@implementation SCRecordingLocationManager

- (void)requestLocation {
    self.requestLocationCount += 1;
}

- (void)startUpdatingLocation {
    self.startUpdatingLocationCount += 1;
}

@end

@interface SCTravelTimezoneManagerTests : XCTestCase
@end

@implementation SCTravelTimezoneManagerTests

- (CLLocation *)locationWithAccuracy:(CLLocationAccuracy)accuracy
                            timestamp:(NSDate *)timestamp
                            simulated:(BOOL)simulated {
    CLLocationSourceInformation *source = [[CLLocationSourceInformation alloc]
        initWithSoftwareSimulationState:simulated
              andExternalAccessoryState:NO];
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(51.5074, -0.1278)
                                         altitude:0.0
                               horizontalAccuracy:accuracy
                                 verticalAccuracy:accuracy
                                           course:0.0
                                   courseAccuracy:1.0
                                            speed:0.0
                                    speedAccuracy:1.0
                                        timestamp:timestamp
                                       sourceInfo:source];
}

- (void)testAcceptsFreshPhysicalLocation {
    CLLocation *location = [self locationWithAccuracy:1000.0
                                             timestamp:[NSDate date]
                                             simulated:NO];
    XCTAssertTrue([[SCTravelTimezoneManager sharedManager] isUsableLocation:location]);
}

- (void)testRejectsStaleInvalidAndSoftwareSimulatedLocations {
    NSDate *staleTimestamp = [NSDate dateWithTimeIntervalSinceNow:-(31.0 * 60.0)];
    XCTAssertFalse([[SCTravelTimezoneManager sharedManager]
        isUsableLocation:[self locationWithAccuracy:1000.0
                                       timestamp:staleTimestamp
                                       simulated:NO]]);
    XCTAssertFalse([[SCTravelTimezoneManager sharedManager]
        isUsableLocation:[self locationWithAccuracy:-1.0
                                       timestamp:[NSDate date]
                                       simulated:NO]]);
    XCTAssertFalse([[SCTravelTimezoneManager sharedManager]
        isUsableLocation:[self locationWithAccuracy:1000.0
                                       timestamp:[NSDate date]
                                       simulated:YES]]);
}

- (void)testWritableDefaultsCannotSeedCommitTimezone {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *legacyKey = @"SCTravelTimezoneLastResolvedIdentifier";
    id previousValue = [defaults objectForKey:legacyKey];
    [defaults setObject:@"Pacific/Honolulu" forKey:legacyKey];

    SCTravelTimezoneManager *manager = [[SCTravelTimezoneManager alloc] init];
    XCTAssertNil(manager.lastResolvedTimeZoneIdentifier);
    XCTAssertNil(manager.lastTrustedTimeZoneIdentifier);
    XCTAssertNil(manager.timeZoneIdentifierForCommit);
    [manager acceptTimeZoneIdentifier:@"Europe/London"];
    XCTAssertEqualObjects(manager.lastResolvedTimeZoneIdentifier, @"Europe/London");
    manager.currentSessionResolutionDate = [NSDate dateWithTimeIntervalSinceNow:-(31.0 * 60.0)];
    XCTAssertNil(manager.lastResolvedTimeZoneIdentifier);

    if (previousValue != nil) {
        [defaults setObject:previousValue forKey:legacyKey];
    } else {
        [defaults removeObjectForKey:legacyKey];
    }
}

- (void)testCommitTimezonePrefersFreshThenUsesRootTrustedOnlyAfterTransientFailure {
    SCTravelTimezoneManager *manager = [[SCTravelTimezoneManager alloc] init];
    manager.lastTrustedTimeZoneIdentifier = @"Pacific/Honolulu";
    manager.lastTrustedTimeZoneResolutionDate = [NSDate distantPast];

    [manager acceptTimeZoneIdentifier:@"Europe/London"];
    XCTAssertEqualObjects(manager.timeZoneIdentifierForCommit, @"Europe/London");
    XCTAssertFalse(manager.usesTrustedTimeZoneForCommit);

    manager.status = SCTravelTimezoneStatusUnavailable;
    manager.failureReason = SCTravelTimezoneFailureReasonTransient;
    XCTAssertEqualObjects(manager.timeZoneIdentifierForCommit, @"Europe/London");
    XCTAssertFalse(manager.usesTrustedTimeZoneForCommit);

    manager.currentSessionResolutionDate = [NSDate dateWithTimeIntervalSinceNow:-(31.0 * 60.0)];
    XCTAssertEqualObjects(manager.timeZoneIdentifierForCommit, @"Pacific/Honolulu");
    XCTAssertTrue(manager.usesTrustedTimeZoneForCommit);

    manager.status = SCTravelTimezoneStatusResolving;
    XCTAssertNil(manager.timeZoneIdentifierForCommit);
    manager.status = SCTravelTimezoneStatusUnavailable;
    manager.failureReason = SCTravelTimezoneFailureReasonPermission;
    XCTAssertNil(manager.timeZoneIdentifierForCommit);
}

- (void)testCommitTimezoneRefusesMissingOrInvalidRootTrustedFallback {
    SCTravelTimezoneManager *manager = [[SCTravelTimezoneManager alloc] init];
    manager.status = SCTravelTimezoneStatusUnavailable;
    manager.failureReason = SCTravelTimezoneFailureReasonTransient;
    XCTAssertNil(manager.timeZoneIdentifierForCommit);

    manager.lastTrustedTimeZoneIdentifier = @"Mars/Olympus_Mons";
    manager.lastTrustedTimeZoneResolutionDate = [NSDate distantPast];
    XCTAssertNil(manager.timeZoneIdentifierForCommit);
}

- (void)testOneShotRefreshNeverStartsContinuousLocationUpdates {
    SCTravelTimezoneManager *manager = [[SCTravelTimezoneManager alloc] init];
    SCRecordingLocationManager *locationManager = [[SCRecordingLocationManager alloc] init];
    manager.locationManager = locationManager;

    [manager beginOneShotLocationRequest];

    XCTAssertTrue(manager.locationRequestInFlight);
    XCTAssertEqual(manager.status, SCTravelTimezoneStatusResolving);
    XCTAssertEqual(locationManager.requestLocationCount, 1);
    XCTAssertEqual(locationManager.startUpdatingLocationCount, 0);
}

@end

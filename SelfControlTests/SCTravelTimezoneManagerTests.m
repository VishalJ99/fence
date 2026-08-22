#import <XCTest/XCTest.h>

#import "SCTravelTimezoneManager.h"

@interface SCTravelTimezoneManager (Testing)
- (BOOL)isUsableLocation:(nullable CLLocation *)location;
- (void)acceptTimeZoneIdentifier:(NSString *)identifier;
@property (nonatomic, strong, nullable) NSDate *currentSessionResolutionDate;
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

@end

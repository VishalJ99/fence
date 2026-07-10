//
//  SCLicenseManager.m
//  SelfControl
//
//  Manages trial tracking, license validation, and Keychain storage for Fence licensing.
//

#import "SCLicenseManager.h"
#import "SCDeviceIdentifier.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonHMAC.h>

#pragma mark - UserDefaults Keys

static NSString * const kFirstLaunchDateKey = @"FenceFirstLaunchDate";
static NSString * const kTrialExpiryDateKey = @"FenceTrialExpiryDate";
static NSString * const kCachedTrialExpiryKey = @"FenceCachedServerTrialExpiry";

#pragma mark - API Configuration

static NSString * const kLicenseAPIBaseURL = @"https://fence-api-cli-production.up.railway.app";

#pragma mark - iCloud Storage Constants

static NSString * const kLicenseStorageKey = @"FenceLicenseCode";

#pragma mark - License Validation Constants

static NSString * const kLicensePrefix = @"FENCE-";

// The secret key is injected via build settings (Secrets.xcconfig)
// This allows the key to be kept out of source control
#ifndef LICENSE_SECRET_KEY
#define LICENSE_SECRET_KEY PLACEHOLDER_KEY_FOR_DEVELOPMENT
#endif

// Stringify macro to convert preprocessor definition to NSString
#define STRINGIFY(x) @#x
#define STRINGIFY_VALUE(x) STRINGIFY(x)

#pragma mark - Error Domain

NSString * const SCLicenseErrorDomain = @"SCLicenseError";

typedef NS_ENUM(NSInteger, SCLicenseErrorCode) {
    SCLicenseErrorInvalidFormat = 1,
    SCLicenseErrorInvalidEncoding = 2,
    SCLicenseErrorInvalidStructure = 3,
    SCLicenseErrorInvalidSignature = 4,
    SCLicenseErrorKeychainFailure = 5,
    SCLicenseErrorInvalidPayload = 6
};

#pragma mark - Implementation

@interface SCLicenseManager ()
@property (nonatomic, strong) NSDate *firstLaunchDate;
@property (nonatomic, strong) NSURLSession *apiSession;
@end

@implementation SCLicenseManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static SCLicenseManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SCLicenseManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self ensureFirstLaunchDate];
        [self setupAPISession];
    }
    return self;
}

- (void)setupAPISession {
    // Create a session configuration that bypasses system proxy settings.
    // This prevents timeouts caused by broken WPAD/PAC proxy auto-discovery
    // on networks where the proxy config URL doesn't exist.
    // Security note: Connection is still HTTPS/TLS encrypted - this only
    // skips the proxy lookup, not the encryption.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.connectionProxyDictionary = @{};  // Empty dict = no proxy
    _apiSession = [NSURLSession sessionWithConfiguration:config];
}

- (void)ensureFirstLaunchDate {
    NSDate *storedDate = [[NSUserDefaults standardUserDefaults] objectForKey:kFirstLaunchDateKey];
    if (!storedDate) {
        storedDate = [NSDate date];
        [[NSUserDefaults standardUserDefaults] setObject:storedDate forKey:kFirstLaunchDateKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    _firstLaunchDate = storedDate;
}

#pragma mark - Trial Tracking (Date-Based)

- (NSDate *)calculateTrialExpiryDate {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [NSDate date];

    // Get the weekday component (Sunday=1, Monday=2, ... Saturday=7)
    NSDateComponents *comps = [calendar components:NSCalendarUnitWeekday fromDate:today];

    // Calculate days until the next Sunday
    // If today is Sunday (1), we want the next Sunday (7 days away)
    NSInteger daysUntilSunday = (8 - comps.weekday) % 7;
    if (daysUntilSunday == 0) {
        daysUntilSunday = 7;
    }

    // Trial expires Saturday 23:59:59 before the "3rd Sunday"
    // so user CANNOT commit on the 3rd Sunday (they're blocked)
    NSInteger totalDays = daysUntilSunday + 13;

    NSDate *expiry = [calendar dateByAddingUnit:NSCalendarUnitDay value:totalDays toDate:today options:0];

    // Set to end of Saturday (23:59:59) so trial expires at midnight into Sunday
    return [calendar dateBySettingHour:23 minute:59 second:59 ofDate:expiry options:0];
}

- (NSDate *)trialExpiryDate {
    NSDate *date = [[NSUserDefaults standardUserDefaults] objectForKey:kTrialExpiryDateKey];
    if (!date) {
        date = [self calculateTrialExpiryDate];
        [[NSUserDefaults standardUserDefaults] setObject:date forKey:kTrialExpiryDateKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[SCLicenseManager] Trial expiry date set to: %@", date);
    }
    return date;
}

- (BOOL)isTrialExpired {
    NSDate *expiry = [self trialExpiryDate];
    // Returns YES if current date >= expiry date (not before expiry)
    BOOL expired = [[NSDate date] compare:expiry] != NSOrderedAscending;
    NSLog(@"[SCLicenseManager] isTrialExpired = %@ (expiry: %@)", expired ? @"YES" : @"NO", expiry);
    return expired;
}

- (NSInteger)trialDaysRemaining {
    if ([self isTrialExpired]) return 0;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *diff = [calendar components:NSCalendarUnitDay
                                         fromDate:[NSDate date]
                                           toDate:[self trialExpiryDate]
                                          options:0];
    return MAX(0, diff.day);
}

#pragma mark - License Status

- (BOOL)canCommit {
    if (![self isTrialExpired]) {
        return YES;  // Still in trial
    }
    return [self currentStatus] == SCLicenseStatusValid;
}

- (SCLicenseStatus)currentStatus {
    // Check for valid license FIRST (takes priority over trial)
    NSString *storedCode = [self retrieveLicenseFromStorage];
    if (storedCode && [self validateLicenseCode:storedCode error:nil]) {
        NSLog(@"[SCLicenseManager] currentStatus = SCLicenseStatusValid (valid license)");
        return SCLicenseStatusValid;
    }

    // No valid license - check trial
    if (![self isTrialExpired]) {
        NSLog(@"[SCLicenseManager] currentStatus = SCLicenseStatusTrial (trial not expired)");
        return SCLicenseStatusTrial;
    }

    // Trial expired, no valid license
    if (!storedCode) {
        NSLog(@"[SCLicenseManager] currentStatus = SCLicenseStatusTrialExpired (no stored code)");
        return SCLicenseStatusTrialExpired;
    }

    NSLog(@"[SCLicenseManager] currentStatus = SCLicenseStatusInvalid (invalid license)");
    return SCLicenseStatusInvalid;
}

#pragma mark - License Validation

- (BOOL)validateLicenseCode:(NSString *)code error:(NSError **)error {
    NSLog(@"[SCLicenseManager] validateLicenseCode called with code length: %lu", (unsigned long)code.length);

    // Must start with "FENCE-"
    if (![code hasPrefix:kLicensePrefix]) {
        NSLog(@"[SCLicenseManager] Validation failed: code doesn't start with FENCE-");
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidFormat
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license format. Code must start with FENCE-."}];
        }
        return NO;
    }

    // Extract the base64-encoded part
    NSString *encoded = [code substringFromIndex:kLicensePrefix.length];

    // Decode from base64
    // Handle base64url encoding (replace - with + and _ with /)
    NSString *base64Standard = [[encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                stringByReplacingOccurrencesOfString:@"_" withString:@"/"];

    // Add padding if necessary
    NSInteger padLength = (4 - (base64Standard.length % 4)) % 4;
    NSString *paddedBase64 = [base64Standard stringByPaddingToLength:base64Standard.length + padLength
                                                          withString:@"="
                                                     startingAtIndex:0];

    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:paddedBase64 options:0];
    if (!decoded) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidEncoding
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license encoding."}];
        }
        return NO;
    }

    NSString *decodedStr = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
    if (!decodedStr) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidEncoding
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license data."}];
        }
        return NO;
    }

    // Split into payload and signature by last "." separator
    NSRange lastDotRange = [decodedStr rangeOfString:@"." options:NSBackwardsSearch];
    if (lastDotRange.location == NSNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidStructure
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license structure."}];
        }
        return NO;
    }

    NSString *payloadStr = [decodedStr substringToIndex:lastDotRange.location];
    NSString *providedSignature = [decodedStr substringFromIndex:lastDotRange.location + 1];

    // Verify the payload is valid JSON
    NSData *payloadData = [payloadStr dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&jsonError];
    if (!payload || jsonError) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidPayload
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license payload."}];
        }
        return NO;
    }

    // Verify required fields exist
    if (!payload[@"e"] || !payload[@"t"] || !payload[@"c"]) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidPayload
                                     userInfo:@{NSLocalizedDescriptionKey: @"License missing required fields."}];
        }
        return NO;
    }

    // Compute HMAC signature
    NSString *secretKey = STRINGIFY_VALUE(LICENSE_SECRET_KEY);
    NSString *computedSignature = [self hmacSHA256:payloadStr withKey:secretKey];

    // Compare signatures (case-insensitive hex comparison)
#ifdef DEBUG
    // Never log license signatures or any portion of the embedded validation
    // secret. A boolean outcome is sufficient for diagnostics.
#endif

    if (![computedSignature.lowercaseString isEqualToString:providedSignature.lowercaseString]) {
        NSLog(@"[SCLicenseManager] Validation failed: signature mismatch");
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorInvalidSignature
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid license signature."}];
        }
        return NO;
    }

    NSLog(@"[SCLicenseManager] Validation successful!");
    return YES;
}

- (BOOL)activateLicenseCode:(NSString *)code error:(NSError **)error {
    // First validate the code
    if (![self validateLicenseCode:code error:error]) {
        return NO;
    }

    // Store in iCloud
    BOOL stored = [self storeLicenseIniCloud:code];
    if (!stored) {
        if (error) {
            *error = [NSError errorWithDomain:SCLicenseErrorDomain
                                         code:SCLicenseErrorKeychainFailure
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to store license. Please ensure iCloud is enabled."}];
        }
        return NO;
    }

    return YES;
}

- (NSString *)storedLicenseEmail {
    NSString *code = [self retrieveLicenseFromStorage];
    if (!code) return nil;

    // Validate first to ensure it's still valid
    if (![self validateLicenseCode:code error:nil]) {
        return nil;
    }

    // Extract payload and parse email
    NSDictionary *payload = [self extractPayloadFromCode:code];
    return payload[@"e"];
}

- (NSString *)storedLicenseCode {
    return [self retrieveLicenseFromStorage];
}

- (NSDictionary *)extractPayloadFromCode:(NSString *)code {
    if (![code hasPrefix:kLicensePrefix]) return nil;

    NSString *encoded = [code substringFromIndex:kLicensePrefix.length];

    // Handle base64url encoding
    NSString *base64Standard = [[encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                stringByReplacingOccurrencesOfString:@"_" withString:@"/"];

    NSInteger padLength = (4 - (base64Standard.length % 4)) % 4;
    NSString *paddedBase64 = [base64Standard stringByPaddingToLength:base64Standard.length + padLength
                                                          withString:@"="
                                                     startingAtIndex:0];

    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:paddedBase64 options:0];
    if (!decoded) return nil;

    NSString *decodedStr = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
    if (!decodedStr) return nil;

    NSRange lastDotRange = [decodedStr rangeOfString:@"." options:NSBackwardsSearch];
    if (lastDotRange.location == NSNotFound) return nil;

    NSString *payloadStr = [decodedStr substringToIndex:lastDotRange.location];
    NSData *payloadData = [payloadStr dataUsingEncoding:NSUTF8StringEncoding];

    return [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
}

#pragma mark - iCloud Storage Operations

- (BOOL)storeLicenseIniCloud:(NSString *)code {
    NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
    [store setString:code forKey:kLicenseStorageKey];
    BOOL synced = [store synchronize];

    if (synced) {
        NSLog(@"[SCLicenseManager] License stored in iCloud key-value storage");
    } else {
        NSLog(@"[SCLicenseManager] Warning: iCloud sync may be pending");
    }

    // Also store locally as backup
    [[NSUserDefaults standardUserDefaults] setObject:code forKey:kLicenseStorageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    return YES;  // Always return YES - iCloud will sync eventually
}

- (NSString *)retrieveLicenseFromStorage {
    // Try iCloud first
    NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
    NSString *iCloudCode = [store stringForKey:kLicenseStorageKey];

    if (iCloudCode) {
        NSLog(@"[SCLicenseManager] License retrieved from iCloud");
        return iCloudCode;
    }

    // Fall back to local storage
    NSString *localCode = [[NSUserDefaults standardUserDefaults] stringForKey:kLicenseStorageKey];
    if (localCode) {
        NSLog(@"[SCLicenseManager] License found in local storage but not in iCloud - attempting sync");

        // Try to sync local license to iCloud
        @try {
            if (store) {
                [store setString:localCode forKey:kLicenseStorageKey];
                BOOL synced = [store synchronize];
                if (synced) {
                    NSLog(@"[SCLicenseManager] Successfully synced local license to iCloud");
                } else {
                    NSLog(@"[SCLicenseManager] iCloud sync requested but synchronize returned NO (will retry later)");
                }
            } else {
                NSLog(@"[SCLicenseManager] iCloud store unavailable - cannot sync local license");
            }
        } @catch (NSException *exception) {
            NSLog(@"[SCLicenseManager] Error syncing license to iCloud: %@ - %@", exception.name, exception.reason);
        }
    }

    return localCode;
}

- (void)deleteLicenseFromStorage {
    // Remove from iCloud
    NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
    [store removeObjectForKey:kLicenseStorageKey];
    [store synchronize];

    // Remove from local storage
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLicenseStorageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[SCLicenseManager] License removed from storage");
}

#pragma mark - Crypto

- (NSString *)hmacSHA256:(NSString *)data withKey:(NSString *)key {
    const char *cKey = [key cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [data cStringUsingEncoding:NSUTF8StringEncoding];

    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), hmac);

    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [result appendFormat:@"%02x", hmac[i]];
    }

    return result;
}

#pragma mark - Online Activation

- (void)activateLicenseOnline:(NSString *)code
                   completion:(void(^)(BOOL success, NSString *errorMessage))completion {

    // First validate locally (signature check)
    NSError *localError = nil;
    if (![self validateLicenseCode:code error:&localError]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, localError.localizedDescription ?: @"Invalid license code");
        });
        return;
    }

    // Build request to server
    NSString *deviceId = [SCDeviceIdentifier deviceIdentifier];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/activate", kLicenseAPIBaseURL]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 15.0;

    NSDictionary *body = @{
        @"licenseCode": code,
        @"deviceId": deviceId
    };

    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Failed to prepare request");
        });
        return;
    }

    NSURLSessionDataTask *task = [self.apiSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        // Network error - allow offline activation
        if (error) {
            NSLog(@"[SCLicenseManager] Online activation failed (network): %@", error);
            // Fall back to offline activation (just store locally)
            BOOL stored = [self storeLicenseIniCloud:code];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (stored) {
                    completion(YES, nil);  // Offline activation succeeded
                } else {
                    completion(NO, @"Failed to store license. Please ensure iCloud is enabled.");
                }
            });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSDictionary *json = nil;
        if (data) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }

        if (httpResponse.statusCode == 200 && [json[@"success"] boolValue]) {
            // Success - store in iCloud
            BOOL stored = [self storeLicenseIniCloud:code];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (stored) {
                    completion(YES, nil);
                } else {
                    completion(NO, @"Failed to store license. Please ensure iCloud is enabled.");
                }
            });
        } else if (httpResponse.statusCode == 409) {
            // Already activated
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"This license key has already been activated on another device");
            });
        } else if (httpResponse.statusCode == 404) {
            // Key not in database - reject
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Invalid license key");
            });
        } else {
            // Other server error
            NSString *errorMsg = json[@"message"] ?: @"Server error during activation";
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, errorMsg);
            });
        }
    }];

    [task resume];
}

#pragma mark - Trial Sync

- (void)syncTrialStatusWithCompletion:(void(^)(NSInteger daysRemaining))completion {
    NSString *deviceId = [SCDeviceIdentifier deviceIdentifier];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/trial/check", kLicenseAPIBaseURL]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 10.0;

    NSDictionary *body = @{ @"deviceId": deviceId };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [self.apiSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            NSLog(@"[SCLicenseManager] Trial sync failed (network): %@", error);
            // Use cached or local trial
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self trialDaysRemaining]);
            });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200 || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self trialDaysRemaining]);
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json[@"expiresAt"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self trialDaysRemaining]);
            });
            return;
        }

        // Parse and cache server expiry date
        NSString *expiresAtStr = json[@"expiresAt"];
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        NSDate *serverExpiry = [formatter dateFromString:expiresAtStr];

        if (serverExpiry) {
            // Cache server expiry date
            [[NSUserDefaults standardUserDefaults] setObject:serverExpiry forKey:kCachedTrialExpiryKey];

            // Also update local trial expiry to match server
            [[NSUserDefaults standardUserDefaults] setObject:serverExpiry forKey:kTrialExpiryDateKey];
            [[NSUserDefaults standardUserDefaults] synchronize];

            NSLog(@"[SCLicenseManager] Trial synced from server: %@", serverExpiry);
        }

        NSInteger daysRemaining = [json[@"daysRemaining"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(daysRemaining);
        });
    }];

    [task resume];
}

#pragma mark - License Recovery

- (void)attemptLicenseRecoveryWithCompletion:(void(^)(BOOL recovered))completion {
    // Only attempt recovery if no local license exists
    NSString *existingLicense = [self retrieveLicenseFromStorage];
    if (existingLicense) {
        NSLog(@"[SCLicenseManager] Recovery skipped - license already in storage");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO);
        });
        return;
    }

    NSString *deviceId = [SCDeviceIdentifier deviceIdentifier];
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/recover?deviceId=%@", kLicenseAPIBaseURL, deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;

    NSLog(@"[SCLicenseManager] Attempting license recovery");

    NSURLSessionDataTask *task = [self.apiSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            NSLog(@"[SCLicenseManager] Recovery failed (network): %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 404) {
            NSLog(@"[SCLicenseManager] Recovery: no license found for this device");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }

        if (httpResponse.statusCode != 200 || !data) {
            NSLog(@"[SCLicenseManager] Recovery failed (status: %ld)", (long)httpResponse.statusCode);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *code = json[@"code"];

        if (!code) {
            NSLog(@"[SCLicenseManager] Recovery failed: no code in response");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }

        // Validate the recovered code
        if (![self validateLicenseCode:code error:nil]) {
            NSLog(@"[SCLicenseManager] Recovery failed: recovered code is invalid");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }

        // Try to store in iCloud
        BOOL stored = [self storeLicenseIniCloud:code];
        if (stored) {
            NSLog(@"[SCLicenseManager] Recovery successful - license restored to iCloud storage");
        } else {
            NSLog(@"[SCLicenseManager] Recovery: found license but iCloud storage still failing");
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(stored);
        });
    }];

    [task resume];
}

#pragma mark - Debug/Testing

- (void)clearStoredLicense {
    [self deleteLicenseFromStorage];
}

- (void)resetTrialState {
    // Clear expiry date (will be recalculated on next access)
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTrialExpiryDateKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kFirstLaunchDateKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self ensureFirstLaunchDate];

    // Force recalculation of expiry date
    NSDate *newExpiry = [self trialExpiryDate];

    // Clear license from storage
    [self deleteLicenseFromStorage];

    NSLog(@"[SCLicenseManager] Trial reset (new expiry: %@, license removed)", newExpiry);
}

- (void)expireTrialState {
    // Set expiry date to start of today (trial immediately expired)
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *startOfToday = [calendar startOfDayForDate:[NSDate date]];
    [[NSUserDefaults standardUserDefaults] setObject:startOfToday forKey:kTrialExpiryDateKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Clear license from storage
    [self deleteLicenseFromStorage];

    NSLog(@"[SCLicenseManager] Trial expired (expiry set to: %@, license removed)", startOfToday);
}

@end

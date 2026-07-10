//
//  BlockDateUtilitiesTests.m
//  SelfControlTests
//
//  Created by Charles Stigler on 17/07/2018.
//

#import <XCTest/XCTest.h>
#import "SCUtility.h"
#import "SCSentry.h"
#import "SCErr.h"
#import "SCSettings.h"
#import "SCBlockEntry.h"
#import "SCXPCClient.h"
#import "SCDaemonProtocol.h"
#import "BlockManager.h"
#import "HostFileBlocker.h"
#import "SCBlockBundle.h"
#import "SCScheduleManager.h"
#import <Sentry/Sentry.h>
#import <Sentry/Sentry-Swift.h>
#import <zlib.h>

@interface SCSentry (SDKPrivacyIntegrationTests)
+ (void)configurePrivacyBoundaryOnOptions:(SentryOptions *)options
                       transmissionAllowed:(BOOL (^)(void))transmissionAllowed;
@end

@interface SCXPCClient (TelemetryTests)
+ (nullable NSDictionary<NSString *, id>*)authorizationRejectionTelemetryFieldsForCommand:(NSString*)command
                                                                                       error:(NSError*)error;
+ (BOOL)shouldRecordAuthorizationRejectionForCommand:(NSString*)command
                                                error:(NSError*)error
                                     recordedCommands:(NSMutableSet<NSString*>*)recordedCommands;
@end

typedef void (^SCSentryFakeRequestHandler)(NSURLRequest *request);

@interface SCSentryFakeURLProtocol : NSURLProtocol
+ (void)setRequestHandler:(nullable SCSentryFakeRequestHandler)requestHandler;
@end

@implementation SCSentryFakeURLProtocol

static SCSentryFakeRequestHandler SCSentryCapturedRequestHandler = nil;

+ (void)setRequestHandler:(SCSentryFakeRequestHandler)requestHandler {
    @synchronized (self) {
        SCSentryCapturedRequestHandler = [requestHandler copy];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    SCSentryFakeRequestHandler requestHandler = nil;
    @synchronized (SCSentryFakeURLProtocol.class) {
        requestHandler = [SCSentryCapturedRequestHandler copy];
    }
    if (requestHandler != nil) requestHandler(self.request);

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSData *SCSentryRequestBody(NSURLRequest *request) {
    if (request.HTTPBody != nil) return request.HTTPBody;
    NSInputStream *stream = request.HTTPBodyStream;
    if (stream == nil) return nil;

    NSMutableData *body = [NSMutableData data];
    uint8_t buffer[16 * 1024];
    [stream open];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count <= 0) break;
        [body appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return body.length > 0 ? body : nil;
}

static NSData *SCSentryGunzipData(NSData *compressedData) {
    if (compressedData.length == 0 || compressedData.length > UINT_MAX) return nil;

    z_stream stream = {0};
    stream.next_in = (Bytef *)compressedData.bytes;
    stream.avail_in = (uInt)compressedData.length;
    if (inflateInit2(&stream, 15 + 32) != Z_OK) return nil;

    NSMutableData *decompressedData = [NSMutableData data];
    uint8_t buffer[32 * 1024];
    int status = Z_OK;
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            inflateEnd(&stream);
            return nil;
        }
        [decompressedData appendBytes:buffer length:sizeof(buffer) - stream.avail_out];
    } while (status != Z_STREAM_END);
    inflateEnd(&stream);
    return decompressedData;
}

static NSDictionary<NSString *, id> *SCSentryParsedEnvelopeFromRequest(NSURLRequest *request) {
    NSData *decompressedData = SCSentryGunzipData(SCSentryRequestBody(request));
    if (decompressedData == nil) return nil;
    SentryEnvelope *envelope = [SentrySerializationSwift envelopeWithData:decompressedData];
    if (envelope == nil) return nil;
    NSMutableArray<NSString *> *itemTypes = [NSMutableArray array];
    NSDictionary *eventPayload = nil;
    for (SentryEnvelopeItem *item in envelope.items) {
        [itemTypes addObject:item.type ?: @"unknown"];
        if ([[item type] isEqualToString:SentryEnvelopeItemTypes.event] && item.data != nil) {
            id payload = [NSJSONSerialization JSONObjectWithData:item.data options:0 error:nil];
            if ([payload isKindOfClass:[NSDictionary class]]) eventPayload = payload;
        }
    }
    return @{
        @"item_types": [itemTypes copy],
        @"event": eventPayload ?: NSNull.null,
    };
}

@interface SCScheduleManager (StrictifyRetryTests)
- (NSString *)storeStrictifyRetryStateForEntries:(NSArray<NSString *> *)addedEntries
                                        toBundle:(SCBlockBundle *)bundle
                                     bundleSaved:(BOOL)bundleSaved
                                  operationToken:(NSString *)operationToken;
- (void)clearStrictifyRetryStateForOperationToken:(NSString *)operationToken;
@end

@interface SCUtilityTests : XCTestCase

@end

// Static dictionaries of block values to test against

NSDictionary* activeBlockLegacyDict; // Active (started 5 minutes ago, duration 10 min)
NSDictionary* expiredBlockLegacyDict; // Expired (started 10 minutes 10 seconds ago, duration 10 min)
NSDictionary* noBlockLegacyDict; // start date is distantFuture
NSDictionary* noBlockLegacyDict2; // start date is nil
NSDictionary* emptyLegacyDict; // literally an empty dictionary
NSDictionary* futureStartDateLegacyDict; // start date is in the future
NSDictionary* negativeBlockDurationLegacyDict; // block duration is negative
NSDictionary* veryLongBlockLegacyDict; // year-long block, one day in

@implementation SCUtilityTests

- (NSUserDefaults*)testDefaults {
    return [[NSUserDefaults alloc] initWithSuiteName: @"BlockDateUtilitiesTests"];
}

+ (void)setUp {
    // SCSettings shouldn't be readOnly during our tests
    // so we can test changing values
    [SCSettings sharedSettings].readOnly = NO;
    
    // Initialize the sample legacy setting dictionaries
    activeBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -300], // 5 minutes ago
        @"BlockDuration": @10 // 10 minutes
    };
    expiredBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -610], // 10 min 10 seconds ago
        @"BlockDuration": @10 // 10 minutes
    };
    noBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate distantFuture],
        @"BlockDuration": @300 // 6 hours
    };
    noBlockLegacyDict2 = @{
        @"BlockDuration": @300 // 6 hours
    };
    futureStartDateLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: 600], // 10 min from now
        @"BlockDuration": @300 // 6 hours
    };
    negativeBlockDurationLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -600], // 10 min ago
        @"BlockDuration": @-15 // negative 15 minutes
    };
    veryLongBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -86400], // 1 day ago
        @"BlockDuration": @432000 // 300 days
    };
    emptyLegacyDict = @{
    };
}

- (void)setUp {
    [super setUp];

    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void) testCleanBlocklistEntries {
    // ignores weird invalid entries
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: nil].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @""].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"      "].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"  \n\n   \n***!@#$%^*()+=<>,/?| "].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"://}**"].count == 0);
    
    // can take a plain hostname
    NSArray* cleaned = [SCMiscUtilities cleanBlocklistEntry: @"selfcontrolapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"selfcontrolapp.com"]);
    
    // and lowercase it
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"selfcontrolapp.com"]);
    
    // with subdomains
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with http scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with https scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"https://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with ftp scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"ftp://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with port
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"https://www.selFconTROLapp.com:73"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com:73"]);
    
    // strips username/password
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://charlie:mypass@cnn.com:54"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"cnn.com:54"]);
    
    // strips path etc
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://mysite.com/my/path/is/very/long.php?querystring=ydfjkl&otherquerystring=%40%80%20#cool"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"mysite.com"]);
    
    // CIDR IP ranges
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"127.0.0.1/20"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"127.0.0.1/20"]);
    
    // can split entries by newlines
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://charlie:mypass@cnn.com:54\nhttps://selfcontrolAPP.com\n192.168.1.1/24\ntest.com\n{}*&\nhttps://reader.google.com/mypath/is/great.php"];
    XCTAssert(cleaned.count == 5);
    XCTAssert([cleaned[0] isEqualToString: @"cnn.com:54"]);
    XCTAssert([cleaned[1] isEqualToString: @"selfcontrolapp.com"]);
    XCTAssert([cleaned[2] isEqualToString: @"192.168.1.1/24"]);
    XCTAssert([cleaned[3] isEqualToString: @"test.com"]);
    XCTAssert([cleaned[4] isEqualToString: @"reader.google.com"]);
}

- (void)testCanonicalBlockEntries {
    NSArray<NSDictionary*>* cases = @[
        @{@"name": @"plain host", @"input": @"example.com", @"expected": @"example.com"},
        @{@"name": @"trailing slash", @"input": @"example.com/", @"expected": @"example.com"},
        @{@"name": @"path and query", @"input": @"example.com/a/path?x=1", @"expected": @"example.com"},
        @{@"name": @"query without slash", @"input": @"example.com?x=1", @"expected": @"example.com"},
        @{@"name": @"mixed case scheme", @"input": @"HtTpS://Example.COM/a", @"expected": @"example.com"},
        @{@"name": @"international host IDNA", @"input": @"https://BÜCHER.example/path", @"expected": @"xn--bcher-kva.example"},
        @{@"name": @"legacy underscore labels", @"input": @"_Service._TCP.Example.com/", @"expected": @"_service._tcp.example.com"},
        @{@"name": @"port", @"input": @"https://Example.COM:8443/path", @"expected": @"example.com:8443"},
        @{@"name": @"CIDR", @"input": @"192.168.1.0/24", @"expected": @"192.168.1.0/24"},
        @{@"name": @"CIDR and port", @"input": @"192.168.1.0/24:8443", @"expected": @"192.168.1.0/24:8443"},
        @{@"name": @"IPv6 CIDR", @"input": @"2001:DB8::/32", @"expected": @"2001:db8::/32"},
        @{@"name": @"IPv6 port", @"input": @"[2001:DB8::1]:443/path", @"expected": @"[2001:db8::1]:443"},
        @{@"name": @"wildcard port", @"input": @"*:443", @"expected": @"*:443"},
        @{@"name": @"app entry", @"input": @" app:com.apple.Terminal ", @"expected": @"app:com.apple.Terminal"},
        @{@"name": @"whitespace", @"input": @"  Example.COM.  ", @"expected": @"example.com"},
        @{@"name": @"invalid host", @"input": @"exa mple!.com", @"expected": [NSNull null]},
        @{@"name": @"invalid numeric host", @"input": @"999.999.999.999", @"expected": [NSNull null]},
        @{@"name": @"invalid port", @"input": @"example.com:70000", @"expected": [NSNull null]},
    ];

    for (NSDictionary* testCase in cases) {
        NSString* actual = [SCMiscUtilities canonicalBlockEntryFromString:testCase[@"input"]];
        id expected = testCase[@"expected"];
        if (expected == [NSNull null]) {
            XCTAssertNil(actual, @"%@", testCase[@"name"]);
        } else {
            XCTAssertEqualObjects(actual, expected, @"%@", testCase[@"name"]);
        }
    }
}

- (void)testBlockEntryParsingUsesCanonicalForm {
    NSArray<NSDictionary*>* cases = @[
        @{@"input": @"https://Example.COM/path?x=1", @"hostname": @"example.com", @"port": @0, @"mask": @0},
        @{@"input": @"example.com?x=1", @"hostname": @"example.com", @"port": @0, @"mask": @0},
        @{@"input": @"example.com:8443/path", @"hostname": @"example.com", @"port": @8443, @"mask": @0},
        @{@"input": @"192.168.1.0/24", @"hostname": @"192.168.1.0", @"port": @0, @"mask": @24},
        @{@"input": @"192.168.1.0/24:8443", @"hostname": @"192.168.1.0", @"port": @8443, @"mask": @24},
        @{@"input": @"2001:DB8::/32", @"hostname": @"2001:db8::", @"port": @0, @"mask": @32},
        @{@"input": @"[2001:DB8::1]:443/path", @"hostname": @"2001:db8::1", @"port": @443, @"mask": @0},
        @{@"input": @"*:443", @"hostname": @"*", @"port": @443, @"mask": @0},
    ];

    for (NSDictionary* testCase in cases) {
        SCBlockEntry* entry = [SCBlockEntry entryFromString:testCase[@"input"]];
        XCTAssertNotNil(entry, @"%@", testCase[@"input"]);
        XCTAssertEqualObjects(entry.hostname, testCase[@"hostname"], @"%@", testCase[@"input"]);
        XCTAssertEqual(entry.port, [testCase[@"port"] integerValue], @"%@", testCase[@"input"]);
        XCTAssertEqual(entry.maskLen, [testCase[@"mask"] integerValue], @"%@", testCase[@"input"]);
    }

    SCBlockEntry* appEntry = [SCBlockEntry entryFromString:@" app:com.apple.Terminal "];
    XCTAssertTrue(appEntry.isAppEntry);
    XCTAssertEqualObjects(appEntry.appBundleID, @"com.apple.Terminal");
    XCTAssertNil([SCBlockEntry entryFromString:@"exa mple!.com"]);
}

- (void)testBundleDecodePreservesOpaqueLegacyEntriesWithoutAcceptingNewInvalidEntries {
    SCBlockBundle *bundle = [SCBlockBundle bundleFromDictionary:@{
        @"bundleID": @"fixture-bundle",
        @"name": @"Fixture",
        @"entries": @[@" Example.COM/ ", @"legacy opaque?!"],
    }];
    XCTAssertEqualObjects(bundle.entries, (@[@"example.com", @"legacy opaque?!"]));
    [bundle addEntry:@"new invalid entry!"];
    XCTAssertEqualObjects(bundle.entries, (@[@"example.com", @"legacy opaque?!"]));
    XCTAssertEqualObjects([bundle toDictionary][@"entries"],
                          (@[@"example.com", @"legacy opaque?!"]));
}

- (void)testDaemonCapabilitiesRejectLegacyProtocol {
    NSArray<NSString*>* requiredCapabilities = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
        SCDaemonCapabilityStrictApplyResults,
        SCDaemonCapabilityScheduleOwnerBounds,
        SCDaemonCapabilityConsistencyProjection,
    ];
    NSString *reason = nil;

    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionLegacy
                                           capabilities:requiredCapabilities
                      compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"protocol-too-old");
}

- (void)testDaemonCapabilitiesRequireBothAppendSelectors {
    NSString *reason = nil;
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:nil
                      compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"capabilities-missing");

    reason = nil;
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:@[SCDaemonCapabilityActiveBlocklistAppend]
                      compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"approved-append-missing");

    reason = nil;
    XCTAssertFalse([SCXPCClient isDaemonProtocolVersion:SCDaemonProtocolVersionCurrent
                                           capabilities:@[SCDaemonCapabilityApprovedSchedulesAppend]
                      compatibleWithCurrentAppWithReason:&reason]);
    XCTAssertEqualObjects(reason, @"active-append-missing");
}

- (void)testDaemonCapabilitiesAcceptCurrentAndFutureProtocols {
    NSArray<NSString*>* capabilities = @[
        SCDaemonCapabilityActiveBlocklistAppend,
        SCDaemonCapabilityApprovedSchedulesAppend,
        SCDaemonCapabilityTelemetrySpool,
        SCDaemonCapabilityStrictApplyResults,
        SCDaemonCapabilityScheduleOwnerBounds,
        SCDaemonCapabilityConsistencyProjection,
        @"future-safe-capability-v1",
    ];

    for (NSNumber *protocolVersion in @[@(SCDaemonProtocolVersionCurrent),
                                         @(SCDaemonProtocolVersionCurrent + 1)]) {
        NSString *reason = nil;
        XCTAssertTrue([SCXPCClient isDaemonProtocolVersion:protocolVersion.integerValue
                                               capabilities:capabilities
                          compatibleWithCurrentAppWithReason:&reason]);
        XCTAssertEqualObjects(reason, @"compatible");
    }
}

- (void)testTelemetryDSNValidationRejectsPlaceholdersAndLegacyUpstream {
    XCTAssertTrue([SCSentry isValidSentryDSNString:@"https://publickey@o123456.ingest.sentry.io/789012"]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:nil]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:@""]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:@"$(SENTRY_DSN)"]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:@"https://publickey@example.com/123"]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:@"http://publickey@localhost/123"]);
    XCTAssertFalse([SCSentry isValidSentryDSNString:@"https://legacy-public-key@o504820.ingest.sentry.io/5592195"]);
}

- (void)testTelemetryErrorSanitizerKeepsOnlyDomainAndCode {
    NSError* underlying = [NSError errorWithDomain:@"UnderlyingSecretDomain"
                                               code:99
                                           userInfo:@{NSLocalizedDescriptionKey: @"canary-telemetry-test.example"}];
    NSError* error = [NSError errorWithDomain:NSCocoaErrorDomain
                                          code:NSFileWriteNoPermissionError
                                      userInfo:@{
                                          NSFilePathErrorKey: @"/Users/private/Documents/secret.txt",
                                          NSUnderlyingErrorKey: underlying,
                                          @"email": @"private@example.invalid"
                                      }];

    NSError* sanitized = [SCSentry sanitizedError:error];
    XCTAssertEqualObjects(sanitized.domain, NSCocoaErrorDomain);
    XCTAssertEqual(sanitized.code, NSFileWriteNoPermissionError);
    XCTAssertEqual(sanitized.userInfo.count, 0u);

    NSError* malformedDomain = [NSError errorWithDomain:@"private@example.invalid/Users/private" code:7 userInfo:nil];
    XCTAssertEqualObjects([SCSentry sanitizedError:malformedDomain].domain, @"UnknownErrorDomain");
}

- (void)testTelemetryDefaultsSanitizerUsesAllowlistAndDerivedCounts {
    NSDictionary* defaults = @{
        @"BlockAsWhitelist": @YES,
        @"EnableErrorReporting": @YES,
        @"BlockDuration": @45,
        @"Blocklist": @[@"canary-telemetry-test.example", @"app:private.bundle"],
        @"SCScheduleBundles": @[
            @{@"name": @"Private work bundle", @"blocklist": @[@"private.example"]},
            @{@"name": @"Private rest bundle", @"blocklist": @[@"other.example"]}
        ],
        @"SCWeekSchedules_2026-07-06": @[@{@"start": @"private exact time"}],
        @"SCWeekCommitment_2026-07-06": [NSDate date],
        @"SCEmergencyUnlockCredits": @4,
        @"SCEmergencyUnlockCreditsInitialized": @YES,
        @"FenceLicenseCode": @"FENCE-private@example.invalid-secret",
        @"FenceDeviceIdentifierFallback": @"private-device-id",
        @"FenceTrialExpiryDate": [NSDate date]
    };

    NSDictionary* sanitized = [SCSentry sanitizedDefaultsContextFromDictionary:defaults];
    XCTAssertEqualObjects(sanitized[@"BlockAsWhitelist"], @YES);
    XCTAssertEqualObjects(sanitized[@"BlockDuration"], @45);
    XCTAssertEqualObjects(sanitized[@"BlocklistCount"], @2);
    XCTAssertEqualObjects(sanitized[@"BundlesCount"], @2);
    XCTAssertEqualObjects(sanitized[@"WeekScheduleKeyCount"], @1);
    XCTAssertEqualObjects(sanitized[@"WeekScheduleEntryCount"], @1);
    XCTAssertEqualObjects(sanitized[@"CommitmentWeekCount"], @1);
    XCTAssertEqualObjects(sanitized[@"EmergencyUnlockCreditsCount"], @4);
    XCTAssertNil(sanitized[@"Blocklist"]);
    XCTAssertNil(sanitized[@"SCScheduleBundles"]);
    XCTAssertNil(sanitized[@"FenceLicenseCode"]);
    XCTAssertNil(sanitized[@"FenceDeviceIdentifierFallback"]);
    XCTAssertNil(sanitized[@"FenceTrialExpiryDate"]);
    XCTAssertFalse([[sanitized description] containsString:@"canary-telemetry-test.example"]);
    XCTAssertFalse([[sanitized description] containsString:@"Private work bundle"]);
}

- (void)testTelemetrySettingsSanitizerNeverIncludesBlocklistsSchedulesOrDates {
    NSDictionary* settings = @{
        @"BlockIsRunning": @YES,
        @"ActiveBlockAsWhitelist": @NO,
        @"SettingsVersionNumber": @42,
        @"ActiveBlocklist": @[@"canary-telemetry-test.example", @"app:private.bundle"],
        @"ApprovedSchedules": @{
            @"private-segment-id": @{
                @"blocklist": @[@"private.example", @"other.example", @"third.example"],
                @"isAllowlist": @YES,
                @"controllingUID": @501,
                @"registeredAt": [NSDate date]
            }
        },
        @"BlockEndDate": [NSDate dateWithTimeIntervalSinceNow:600],
        @"LastSettingsUpdate": [NSDate date],
        @"FenceLicenseCode": @"FENCE-private@example.invalid-secret"
    };

    NSDictionary* sanitized = [SCSentry sanitizedSettingsContextFromDictionary:settings];
    XCTAssertEqualObjects(sanitized[@"BlockIsRunning"], @YES);
    XCTAssertEqualObjects(sanitized[@"SettingsVersionNumber"], @42);
    XCTAssertEqualObjects(sanitized[@"ActiveBlocklistCount"], @2);
    XCTAssertEqualObjects(sanitized[@"ApprovedSchedulesCount"], @1);
    XCTAssertEqualObjects(sanitized[@"ApprovedScheduleEntryCount"], @3);
    XCTAssertEqualObjects(sanitized[@"ApprovedAllowlistScheduleCount"], @1);
    XCTAssertEqualObjects(sanitized[@"BlockEndDateState"], @"future");
    XCTAssertEqualObjects(sanitized[@"LastSettingsUpdatePresent"], @YES);
    XCTAssertNil(sanitized[@"ActiveBlocklist"]);
    XCTAssertNil(sanitized[@"ApprovedSchedules"]);
    XCTAssertNil(sanitized[@"BlockEndDate"]);
    XCTAssertNil(sanitized[@"LastSettingsUpdate"]);
    XCTAssertNil(sanitized[@"FenceLicenseCode"]);
    XCTAssertFalse([[sanitized description] containsString:@"canary-telemetry-test.example"]);
    XCTAssertFalse([[sanitized description] containsString:@"private-segment-id"]);
}

- (void)testTelemetryEventContextSanitizerDropsSDKDeviceAndArbitraryContexts {
    NSDictionary* contexts = @{
        @"app": @{
            @"app_identifier": @"org.eyebeam.Fence",
            @"app_version": @"3.4.7",
            @"app_build": @"647",
            @"device_app_hash": @"private-device-hash",
            @"app_start_time": [NSDate date]
        },
        @"os": @{
            @"name": @"macOS",
            @"version": @"26.0",
            @"kernel_version": @"private-kernel-value"
        },
        @"device": @{
            @"model": @"MacPrivate",
            @"locale": @"en_GB",
            @"serial": @"private-serial"
        },
        @"user info": @{@"NSFilePath": @"/Users/private/secret"},
        @"NSUserDefaults": @{
            @"Blocklist": @[@"canary-telemetry-test.example"],
            @"FenceLicenseCode": @"private@example.invalid"
        },
        @"SCSettings": @{
            @"ApprovedSchedules": @{@"segment": @{@"blocklist": @[@"private.example"]}}
        }
    };

    NSDictionary* sanitized = [SCSentry sanitizedEventContextsFromDictionary:contexts];
    NSSet* expectedContextKeys = [NSSet setWithArray:@[@"app", @"os", @"NSUserDefaults", @"SCSettings"]];
    XCTAssertEqualObjects([NSSet setWithArray:sanitized.allKeys], expectedContextKeys);
    NSDictionary* appContext = sanitized[@"app"];
    NSDictionary* osContext = sanitized[@"os"];
    XCTAssertEqualObjects(appContext[@"app_identifier"], @"org.eyebeam.Fence");
    XCTAssertNil(appContext[@"device_app_hash"]);
    XCTAssertNil(osContext[@"kernel_version"]);
    XCTAssertNil(sanitized[@"device"]);
    XCTAssertNil(sanitized[@"user info"]);
    XCTAssertFalse([[sanitized description] containsString:@"canary-telemetry-test.example"]);
    XCTAssertFalse([[sanitized description] containsString:@"private@example.invalid"]);
}

- (void)testTelemetryBreadcrumbSanitizerAllowsTemplatesAndRedactsDynamicValues {
    NSDictionary* safe = [SCSentry sanitizedBreadcrumbWithMessage:@"Opening preferences window" category:@"app"];
    XCTAssertEqualObjects(safe[@"message"], @"Opening preferences window");

    NSDictionary* appBlocker = [SCSentry sanitizedBreadcrumbWithMessage:@"Terminated blocked app: private.user.bundle"
                                                                 category:@"appblocker"];
    XCTAssertEqualObjects(appBlocker[@"message"], @"Blocked app termination attempted");
    XCTAssertFalse([[appBlocker description] containsString:@"private.user.bundle"]);

    NSDictionary* settings = [SCSentry sanitizedBreadcrumbWithMessage:@"Failed to create directory for SCSettings with error /Users/private/secret"
                                                                category:@"settings"];
    XCTAssertEqualObjects(settings[@"message"], @"Failed to create directory for SCSettings");
    XCTAssertNotNil([SCSentry sanitizedBreadcrumbWithMessage:@"Initialized SCSettings to safe in-memory defaults"
                                                     category:@"settings"]);
    XCTAssertNotNil([SCSentry sanitizedBreadcrumbWithMessage:@"Suppressed repeated startup consistency violation"
                                                     category:@"telemetry.consistency"]);
    XCTAssertNotNil([SCSentry sanitizedBreadcrumbWithMessage:@"Startup consistency checks passed"
                                                     category:@"telemetry.consistency"]);
    XCTAssertNil([SCSentry sanitizedBreadcrumbWithMessage:@"User-entered private text" category:@"app"]);
    XCTAssertNil([SCSentry sanitizedBreadcrumbWithMessage:@"Opening preferences window" category:@"unapproved"]);
}

- (void)testFenceDefaultsMigrationRestoresOnlyScheduleStateIntoEmptyDomain {
    NSDictionary *legacy = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"private-id", @"entries": @[@"private.example"]}],
        @"SCWeekSchedules_2026-07-06": @[@{@"bundleID": @"private-id"}],
        @"SCWeekCommitment_2026-07-06": [NSDate date],
        @"SCCommitmentEndDate": [NSDate date],
        @"SCIsCommitted": @YES,
        @"SCEmergencyUnlockCredits": @3,
        @"SCEmergencyUnlockCreditsInitialized": @YES,
        @"FenceLicenseCode": @"FENCE-private@example.invalid-secret",
        @"EnableErrorReporting": @YES,
        @"UnrelatedPreference": @"do-not-copy"
    };

    NSDictionary *restored = [SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                                                     currentDomain:@{}];
    XCTAssertEqualObjects(restored[@"SCScheduleBundles"], legacy[@"SCScheduleBundles"]);
    XCTAssertEqualObjects(restored[@"SCWeekSchedules_2026-07-06"], legacy[@"SCWeekSchedules_2026-07-06"]);
    XCTAssertEqualObjects(restored[@"SCWeekCommitment_2026-07-06"], legacy[@"SCWeekCommitment_2026-07-06"]);
    XCTAssertEqualObjects(restored[@"SCEmergencyUnlockCredits"], @3);
    XCTAssertNil(restored[@"FenceLicenseCode"]);
    XCTAssertNil(restored[@"EnableErrorReporting"]);
    XCTAssertNil(restored[@"UnrelatedPreference"]);
}

- (void)testFenceDefaultsMigrationNeverOverwritesCurrentScheduleState {
    NSDictionary *legacy = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"legacy"}],
        @"SCWeekSchedules_2026-07-06": @[@{@"bundleID": @"legacy"}]
    };
    NSDictionary *currentBundleState = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"current"}]
    };
    NSDictionary *currentWeekState = @{
        @"SCWeekSchedules_2026-07-13": @[@{@"bundleID": @"current"}]
    };

    XCTAssertEqual([SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                                          currentDomain:currentBundleState].count, 0u);
    XCTAssertEqual([SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                                          currentDomain:currentWeekState].count, 0u);
    XCTAssertEqual([SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:@{@"SCEmergencyUnlockCredits": @2}
                                                                          currentDomain:@{}].count, 0u);
}

- (void)testFenceDefaultsMigrationIgnoresExpiredCurrentCommitmentMarkers {
    NSDate *expired = [NSDate dateWithTimeIntervalSinceNow:-3600.0];
    NSDate *live = [NSDate dateWithTimeIntervalSinceNow:3600.0];
    NSDictionary *legacy = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"legacy"}],
        @"SCWeekSchedules_2026-07-06": @[@{@"bundleID": @"legacy"}],
        @"SCWeekCommitment_2026-07-06": live,
    };
    NSDictionary *expiredCurrentMarkers = @{
        @"SCIsCommitted": @YES,
        @"SCCommitmentEndDate": expired,
        @"SCWeekCommitment_2026-06-29": expired,
    };

    NSDictionary *restored =
        [SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                              currentDomain:expiredCurrentMarkers];
    XCTAssertEqualObjects(restored[@"SCScheduleBundles"], legacy[@"SCScheduleBundles"]);
    XCTAssertEqualObjects(restored[@"SCWeekSchedules_2026-07-06"],
                          legacy[@"SCWeekSchedules_2026-07-06"]);
}

- (void)testFenceDefaultsMigrationIgnoresBooleanOnlyCommitmentMarker {
    NSDictionary *legacy = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"legacy"}],
        @"SCWeekSchedules_2026-07-06": @[@{@"bundleID": @"legacy"}],
    };

    NSDictionary *restored =
        [SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                              currentDomain:@{@"SCIsCommitted": @YES}];
    XCTAssertEqualObjects(restored[@"SCScheduleBundles"], legacy[@"SCScheduleBundles"]);
}

- (void)testFenceDefaultsMigrationRespectsLiveCurrentCommitmentMarker {
    NSDictionary *legacy = @{
        @"SCScheduleBundles": @[@{@"bundleID": @"legacy"}],
        @"SCWeekSchedules_2026-07-06": @[@{@"bundleID": @"legacy"}],
    };
    NSDictionary *current = @{
        @"SCWeekCommitment_2026-07-06": [NSDate dateWithTimeIntervalSinceNow:3600.0],
    };

    XCTAssertEqual([SCMigrationUtilities legacyFenceScheduleValuesToRestoreFromDomain:legacy
                                                                          currentDomain:current].count, 0u);
}

- (void)testStrictifyRetryStateAndNotificationAreScopedToOperationToken {
    SCScheduleManager *manager = [[SCScheduleManager alloc] init];
    SCBlockBundle *original = [SCBlockBundle bundleWithName:@"Test" color:NSColor.blueColor];
    [original addEntry:@"base.invalid"];
    SCBlockBundle *afterFirstEdit = [original copy];
    [afterFirstEdit addEntry:@"first.invalid"];
    SCBlockBundle *afterSecondEdit = [afterFirstEdit copy];
    [afterSecondEdit addEntry:@"second.invalid"];
    [manager setValue:[NSMutableArray arrayWithObject:afterSecondEdit]
               forKey:@"mutableBundles"];

    NSString *firstToken = @"strictify-test-first";
    NSString *secondToken = @"strictify-test-second";
    [manager storeStrictifyRetryStateForEntries:@[@"first.invalid"]
                                       toBundle:afterFirstEdit
                                    bundleSaved:YES
                                 operationToken:firstToken];
    [manager storeStrictifyRetryStateForEntries:@[@"second.invalid"]
                                       toBundle:afterSecondEdit
                                    bundleSaved:YES
                                 operationToken:secondToken];

    __block NSString *completedToken = nil;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:SCScheduleStrictifyDidCompleteNotification
                    object:manager
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        completedToken = notification.userInfo[SCScheduleStrictifyOperationTokenKey];
    }];
    @try {
        XCTAssertTrue([manager retryStrictifyUpdateForOperationToken:firstToken]);
        XCTAssertEqualObjects(completedToken, firstToken);

        [manager clearStrictifyRetryStateForOperationToken:firstToken];
        NSDictionary *states = [manager valueForKey:@"strictifyRetryStatesByToken"];
        XCTAssertNil(states[firstToken]);
        XCTAssertNotNil(states[secondToken]);
        XCTAssertEqualObjects([manager valueForKey:@"lastStrictifyOperationToken"], secondToken);

        SCBlockBundle *current = [manager bundleWithID:afterSecondEdit.bundleID];
        XCTAssertTrue([current.entries containsObject:@"first.invalid"]);
        XCTAssertTrue([current.entries containsObject:@"second.invalid"]);
    } @finally {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
}

- (NSDictionary<NSString*, id>*)completeNestedBlockApplyResultForTelemetryTests {
    return @{
        @"schema_version": @1,
        @"operation": @"integrity",
        @"status": @"failed",
        @"duration_ms": @17,
        @"entries": @{
            @"input_count": @4, @"valid_count": @3, @"rejected_count": @1,
            @"unapplied_count": @1, @"app_count": @1, @"site_count": @2,
            @"dns_lookup_count": @2, @"dns_resolved_host_count": @1,
            @"dns_resolved_address_count": @2, @"dns_failure_count": @1,
        },
        @"hosts": @{
            @"ready": @"succeeded", @"write": @"succeeded", @"verify": @"failed",
            @"error_code": @2,
        },
        @"packet_filter": @{
            @"anchor_open": @"succeeded", @"anchor_write": @"failed",
            @"main_config_write": @"succeeded", @"verify": @"failed",
            @"command": @"start", @"exit_code": @-1, @"error_code": @4,
        },
        @"apps": @{
            @"blocked_count": @1, @"monitoring_before": @NO, @"monitoring_after": @YES,
            @"kill_attempt_count": @2, @"terminate_success_count": @1,
            @"force_kill_count": @1, @"kill_failure_count": @1,
            @"scan_error_code": @0, @"kill_error_code": @5,
        },
    };
}

- (NSDictionary<NSString*, id>*)completeStrictifySupplementalTelemetryFields {
    return @{
        @"is_allowlist": @NO, @"layer": @"pf", @"settings_persisted": @NO,
        @"outcome": @"failed", @"target": @"active_and_future",
        @"failed_stage": @"physical_apply", @"skip_reason": @"none",
        @"bundle_saved": @YES, @"used_in_committed_schedule": @YES, @"block_running": @YES,
        @"active_expected": @YES, @"active_precondition_matched": @YES,
        @"active_verified": @NO, @"active_physical_reapply_attempted": @YES,
        @"future_verified": @NO,
        @"blocklist_file_persisted": @YES, @"xpc_completed": @YES,
        @"operation_sequence": @7, @"requested_addition_count": @4,
        @"canonical_addition_count": @3, @"duplicate_addition_count": @0,
        @"future_candidate_count": @2, @"future_job_count": @2,
        @"future_loaded_job_count": @1, @"future_launchd_probe_failure_count": @0,
        @"approval_requested_count": @2, @"approval_matched_count": @2,
        @"approval_updated_count": @1, @"approval_skipped_count": @1,
        @"active_before_count": @5, @"active_after_count": @7, @"daemon_protocol": @1,
    };
}

- (NSDictionary<NSString*, id>*)completeDaemonDivergenceTelemetryFields {
    return @{
        @"reason": @"active_state_mismatch", @"collector_status": @"complete",
        @"settings_available": @YES, @"block_running": @YES,
        @"app_has_schedule_state": @YES, @"active_counts_match": @NO,
        @"approval_counts_match": @YES, @"plist_counts_match": @YES, @"job_counts_match": @YES,
        @"pf_active": @YES, @"hosts_active": @NO, @"app_monitoring": @YES,
        @"physical_layers_match": @NO, @"app_bundle_count": @2,
        @"app_week_count": @3, @"app_commitment_count": @1,
        @"daemon_active_entry_count": @4, @"daemon_approval_count": @2,
        @"daemon_approval_entry_count": @4, @"daemon_plist_count": @2, @"daemon_job_count": @2,
        @"raw_bundle_count": @2, @"decoded_bundle_count": @2,
        @"rendered_bundle_count": @2,
        @"active_expected_count": @4, @"active_actual_count": @4,
        @"active_missing_count": @0, @"active_extra_count": @0,
        @"approval_expected_count": @2, @"approval_actual_count": @2,
        @"approval_missing_count": @0, @"approval_extra_count": @0,
        @"plist_expected_count": @2, @"plist_actual_count": @2,
        @"plist_missing_count": @0, @"plist_extra_count": @0,
        @"loaded_job_expected_count": @2, @"loaded_job_actual_count": @2,
        @"loaded_job_missing_count": @0, @"loaded_job_extra_count": @0,
        @"launchd_probe_failure_count": @0, @"invalid_approval_count": @0,
        @"invalid_plist_count": @0,
    };
}

- (NSDictionary<NSString*, id>*)completeSupportSnapshotTelemetryFields {
    return @{
        @"collector_status": @"complete", @"last_strictify_outcome": @"verified",
        @"settings_available": @YES, @"block_running": @YES, @"app_has_schedule_state": @YES,
        @"legacy_domain_has_state": @NO, @"daemon_reachable": @YES,
        @"pf_active": @YES, @"hosts_active": @YES, @"app_monitoring": @YES,
        @"physical_layers_match": @YES, @"active_counts_match": @YES,
        @"approval_counts_match": @YES, @"app_bundle_count": @2,
        @"app_week_count": @3, @"app_commitment_count": @1,
        @"daemon_active_entry_count": @4, @"daemon_approval_count": @2,
        @"daemon_job_count": @2, @"collector_error_count": @0,
        @"daemon_protocol": @(SCDaemonProtocolVersionCurrent),
    };
}

- (void)testTelemetryBlockApplyAdapterFlattensAndNormalizesTypedResults {
    NSDictionary *raw = [self completeNestedBlockApplyResultForTelemetryTests];
    NSDictionary *safe = [SCSentry telemetryFieldsForBlockApplyResultDictionary:raw
                                                                       eventName:@"block.apply_failed"
                                                              supplementalFields:@{
        @"is_allowlist": @NO, @"layer": @"pf", @"settings_persisted": @NO,
    }];
    XCTAssertNotNil(safe);
    XCTAssertEqualObjects(safe[@"operation"], @"integrity_reapply");
    XCTAssertEqualObjects(safe[@"pf_command"], @"load");
    XCTAssertEqualObjects(safe[@"duration_milliseconds"], @17);
    XCTAssertEqualObjects(safe[@"unapplied_entry_count"], @1);
    XCTAssertEqualObjects(safe[@"pf_exit_code"], @-1);
    XCTAssertEqualObjects(safe[@"app_kill_error_code"], @5);

    NSDictionary *strictify = [SCSentry telemetryFieldsForBlockApplyResultDictionary:raw
                                                                             eventName:@"block.strictify_result"
                                                                    supplementalFields:[self completeStrictifySupplementalTelemetryFields]];
    XCTAssertNotNil(strictify);
    XCTAssertEqualObjects(strictify[@"operation"], @"strictify");
    XCTAssertEqualObjects(strictify[@"failed_stage"], @"physical_apply");
    XCTAssertEqualObjects(strictify[@"blocklist_file_persisted"], @YES);
    XCTAssertEqualObjects(strictify[@"active_physical_reapply_attempted"], @YES);
    XCTAssertEqualObjects(strictify[@"future_loaded_job_count"], @1);
    XCTAssertEqualObjects(strictify[@"future_launchd_probe_failure_count"], @0);

    // The raw nested representation is never itself a valid outbound payload.
    XCTAssertNil([SCSentry sanitizedTelemetryFields:raw forEventName:@"block.apply_failed"]);
}

- (void)testTelemetryTypedSchemasRejectMissingRequiredFieldsAndUnknownValues {
    NSMutableDictionary *incompleteStrictify = [[self completeStrictifySupplementalTelemetryFields] mutableCopy];
    [incompleteStrictify removeObjectForKey:@"xpc_completed"];
    XCTAssertNil([SCSentry telemetryFieldsForBlockApplyResultDictionary:[self completeNestedBlockApplyResultForTelemetryTests]
                                                               eventName:@"block.strictify_result"
                                                      supplementalFields:incompleteStrictify]);

    XCTAssertNil([SCSentry sanitizedTelemetryFields:@{} forEventName:@"block.apply_failed"]);
    NSDictionary *remnantFields = @{
        @"remnants": @"multiple", @"hosts_remnant": @YES, @"pf_remnant": @YES,
        @"app_monitoring": @NO, @"teardown_verified": @YES, @"settings_version": @12,
    };
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:remnantFields
                                          forEventName:@"tamper.no_block_found"]);
    NSMutableDictionary *unsafeRemnantFields = [remnantFields mutableCopy];
    [unsafeRemnantFields addEntriesFromDictionary:@{
        @"remnants": @"hosts", @"hosts_remnant": @YES, @"pf_remnant": @NO,
        @"host_contents": @"canary-telemetry-test.example",
    }];
    XCTAssertNil([SCSentry sanitizedTelemetryFields:unsafeRemnantFields
                                       forEventName:@"tamper.no_block_found"]);
    XCTAssertNil([SCSentry sanitizedTelemetryFields:@{@"reason": @"decode_loss"}
                                      forEventName:@"state.app_defaults_regressed"]);
    NSDictionary *incompleteSettingsFailure = @{@"reason": @"missing", @"settings_version": @1};
    XCTAssertNil([SCSentry sanitizedTelemetryFields:incompleteSettingsFailure
                                      forEventName:@"daemon.settings_load_failed"]);

    NSDictionary *completeDivergence = [self completeDaemonDivergenceTelemetryFields];
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:completeDivergence
                                          forEventName:@"state.app_daemon_diverged"]);
    NSMutableDictionary *incompleteDivergence = [completeDivergence mutableCopy];
    [incompleteDivergence removeObjectForKey:@"physical_layers_match"];
    XCTAssertNil([SCSentry sanitizedTelemetryFields:incompleteDivergence
                                      forEventName:@"state.app_daemon_diverged"]);

    NSDictionary *completeSupport = [self completeSupportSnapshotTelemetryFields];
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:completeSupport
                                          forEventName:@"support.diagnostic_snapshot"]);
    NSMutableDictionary *incompleteSupport = [completeSupport mutableCopy];
    [incompleteSupport removeObjectForKey:@"daemon_reachable"];
    XCTAssertNil([SCSentry sanitizedTelemetryFields:incompleteSupport
                                      forEventName:@"support.diagnostic_snapshot"]);
    XCTAssertNil([SCSentry sanitizedTelemetryFields:@{@"reason": @"mystery"}
                                      forEventName:@"daemon.incompatible"]);
    NSDictionary *domainShapedBuild = @{
        @"reason": @"protocol_too_old", @"daemon_build": @"private.example"
    };
    XCTAssertNil([SCSentry sanitizedTelemetryFields:domainShapedBuild
                                      forEventName:@"daemon.incompatible"]);

    NSDictionary *connectionRejected = @{
        @"stage": @"validity", @"client_id": @"app", @"identifier_ok": @YES,
        @"team_ok": @NO, @"version_ok": @YES, @"os_status": @-67050,
        @"client_version": @"647",
    };
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:connectionRejected
                                          forEventName:@"xpc.connection_rejected"]);
    NSMutableDictionary *unsafeConnectionRejected = [connectionRejected mutableCopy];
    unsafeConnectionRejected[@"client_path"] = @"/Users/private/Fence.app";
    XCTAssertNil([SCSentry sanitizedTelemetryFields:unsafeConnectionRejected
                                      forEventName:@"xpc.connection_rejected"]);

    NSDictionary *scheduleExecutionFailure = @{
        @"path": @"cli_launchd", @"block_already_running": @NO,
        @"minutes_late_bucket": @5, @"approved_count": @2,
        @"list_count": @4, @"error_code": @403,
    };
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:scheduleExecutionFailure
                                          forEventName:@"schedule.exec_failed"]);
    NSMutableDictionary *unsafeScheduleExecution = [scheduleExecutionFailure mutableCopy];
    unsafeScheduleExecution[@"schedule_id"] = @"72EF8B58-ABCD-4567-ABCD-0123456789AB";
    XCTAssertNil([SCSentry sanitizedTelemetryFields:unsafeScheduleExecution
                                      forEventName:@"schedule.exec_failed"]);

    NSDictionary *commitInstallFailure = @{
        @"stage": @"job_install", @"segments_planned": @3,
        @"segments_installed": @1, @"week_offset": @0, @"error_code": @5,
    };
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:commitInstallFailure
                                          forEventName:@"schedule.commit_install_failed"]);

    NSDictionary *verifiedEmergencyUnlock = @{
        @"outcome": @"success", @"credits_remaining": @4,
        @"settings_cleared": @YES, @"hosts_clean": @YES, @"pf_check": @YES,
        @"duration_milliseconds": @1200,
    };
    XCTAssertNotNil([SCSentry sanitizedTelemetryFields:verifiedEmergencyUnlock
                                          forEventName:@"emergency.unlock_result"]);
    NSMutableDictionary *incompleteEmergencyUnlock = [verifiedEmergencyUnlock mutableCopy];
    [incompleteEmergencyUnlock removeObjectForKey:@"pf_check"];
    XCTAssertNil([SCSentry sanitizedTelemetryFields:incompleteEmergencyUnlock
                                      forEventName:@"emergency.unlock_result"]);
    XCTAssertNil([SCSentry sanitizedTelemetryFields:@{} forEventName:@"unknown.event"]);
}

- (void)testXPCAuthorizationRejectionTelemetrySkipsCancellationAndDeduplicatesByCommand {
    NSError *denied = [NSError errorWithDomain:NSOSStatusErrorDomain
                                           code:errAuthorizationDenied
                                       userInfo:@{NSLocalizedDescriptionKey: @"private text is never serialized"}];
    NSDictionary *fields = [SCXPCClient authorizationRejectionTelemetryFieldsForCommand:@"update"
                                                                                   error:denied];
    XCTAssertEqualObjects(fields, (@{
        @"command": @"update",
        @"user_cancelled": @NO,
        @"error_code": @(errAuthorizationDenied),
    }));

    NSError *cancelled = [NSError errorWithDomain:NSOSStatusErrorDomain
                                              code:AUTH_CANCELLED_STATUS
                                          userInfo:nil];
    XCTAssertNil([SCXPCClient authorizationRejectionTelemetryFieldsForCommand:@"update"
                                                                         error:cancelled]);
    XCTAssertNil([SCXPCClient authorizationRejectionTelemetryFieldsForCommand:@"unknown_command"
                                                                         error:denied]);
    XCTAssertNotNil([SCXPCClient authorizationRejectionTelemetryFieldsForCommand:@"repair"
                                                                            error:denied]);
    XCTAssertNil([SCXPCClient authorizationRejectionTelemetryFieldsForCommand:@"update"
                                                                         error:[SCErr errorWithCode:500]]);

    NSMutableSet<NSString*> *recordedCommands = [NSMutableSet set];
    XCTAssertTrue([SCXPCClient shouldRecordAuthorizationRejectionForCommand:@"update"
                                                                      error:denied
                                                           recordedCommands:recordedCommands]);
    XCTAssertFalse([SCXPCClient shouldRecordAuthorizationRejectionForCommand:@"update"
                                                                       error:denied
                                                            recordedCommands:recordedCommands]);
    XCTAssertFalse([SCXPCClient shouldRecordAuthorizationRejectionForCommand:@"install"
                                                                       error:cancelled
                                                            recordedCommands:recordedCommands]);
    XCTAssertEqualObjects(recordedCommands, [NSSet setWithObject:@"update"]);
}

- (void)testDaemonUnreachableRepairTelemetryDistinguishesInstallAndPostHandshakeFailures {
    NSError *initialTimeout = [NSError
        errorWithDomain:@"org.eyebeam.Fence.DaemonCompatibility.Handshake"
                   code:3
               userInfo:@{NSLocalizedDescriptionKey: @"raw XPC details stay local"}];
    NSError *installFailure = [SCErr errorWithCode:500 subDescription:@"private install description"];
    NSDictionary *installFields = [SCXPCClient
        daemonUnreachableReinstallTelemetryFieldsForOutcome:@"install_failed"
                                      initialHandshakeError:initialTimeout
                                                 finalError:installFailure
                              installedHelperPresentBefore:YES
                               installedHelperPresentAfter:YES
                                      bundledHelperPresent:YES
                                        reinstallSucceeded:NO
                                         reconnectAttempted:NO
                              postRepairHandshakeSucceeded:NO
                                      postRepairCompatible:NO];
    XCTAssertEqualObjects(installFields[@"outcome"], @"install_failed");
    XCTAssertEqualObjects(installFields[@"initial_failure"], @"timeout");
    XCTAssertEqualObjects(installFields[@"final_failure"], @"install");
    XCTAssertEqualObjects(installFields[@"reconnect_attempted"], @NO);
    XCTAssertEqualObjects(installFields[@"final_error_code"], @500);
    XCTAssertFalse([[installFields description] containsString:@"private"]);

    NSDictionary *authorizationInstallFields = [SCXPCClient
        daemonUnreachableReinstallTelemetryFieldsForOutcome:@"install_failed"
                                      initialHandshakeError:initialTimeout
                                                 finalError:[SCErr errorWithCode:501]
                              installedHelperPresentBefore:YES
                               installedHelperPresentAfter:YES
                                      bundledHelperPresent:YES
                                        reinstallSucceeded:NO
                                         reconnectAttempted:NO
                              postRepairHandshakeSucceeded:NO
                                      postRepairCompatible:NO];
    XCTAssertEqualObjects(authorizationInstallFields[@"final_failure"], @"authorization");

    NSError *postRepairHandshake = [NSError
        errorWithDomain:@"org.eyebeam.Fence.DaemonCompatibility.Handshake"
                   code:2
               userInfo:nil];
    NSDictionary *postRepairFields = [SCXPCClient
        daemonUnreachableReinstallTelemetryFieldsForOutcome:@"post_repair_unreachable"
                                      initialHandshakeError:initialTimeout
                                                 finalError:postRepairHandshake
                              installedHelperPresentBefore:NO
                               installedHelperPresentAfter:YES
                                      bundledHelperPresent:YES
                                        reinstallSucceeded:YES
                                         reconnectAttempted:YES
                              postRepairHandshakeSucceeded:NO
                                      postRepairCompatible:NO];
    XCTAssertEqualObjects(postRepairFields[@"outcome"], @"post_repair_unreachable");
    XCTAssertEqualObjects(postRepairFields[@"final_failure"], @"handshake");
    XCTAssertEqualObjects(postRepairFields[@"reinstall_succeeded"], @YES);
    XCTAssertEqualObjects(postRepairFields[@"reconnect_attempted"], @YES);

    XCTAssertNil([SCXPCClient
        daemonUnreachableReinstallTelemetryFieldsForOutcome:@"post_repair_unreachable"
                                      initialHandshakeError:initialTimeout
                                                 finalError:postRepairHandshake
                              installedHelperPresentBefore:NO
                               installedHelperPresentAfter:YES
                                      bundledHelperPresent:YES
                                        reinstallSucceeded:NO
                                         reconnectAttempted:NO
                              postRepairHandshakeSucceeded:NO
                                      postRepairCompatible:NO]);
}

- (void)testStartupDivergenceSignatureSuppressesOnlyIdenticalRecentResults {
    NSDictionary<NSString *, id> *fields = [self completeDaemonDivergenceTelemetryFields];
    NSString *signature = [SCSentry privacySafeTelemetrySignatureForFields:fields
                                                                  eventName:@"state.app_daemon_diverged"];
    XCTAssertEqual(signature.length, 64U);

    NSMutableDictionary<NSString *, id> *changedFields = [fields mutableCopy];
    changedFields[@"active_actual_count"] = @3;
    NSString *changedSignature = [SCSentry privacySafeTelemetrySignatureForFields:changedFields
                                                                         eventName:@"state.app_daemon_diverged"];
    XCTAssertNotEqualObjects(signature, changedSignature);

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:2000000];
    NSTimeInterval window = 7.0 * 24.0 * 60.0 * 60.0;
    NSDate *oneMinuteAgo = [now dateByAddingTimeInterval:-60.0];
    XCTAssertTrue([SCSentry shouldEmitTelemetrySignature:signature
                                             previousSignature:nil
                                          previousEmissionDate:nil
                                                           now:now
                                           suppressionInterval:window]);
    XCTAssertFalse([SCSentry shouldEmitTelemetrySignature:signature
                                              previousSignature:signature
                                           previousEmissionDate:oneMinuteAgo
                                                            now:now
                                            suppressionInterval:window]);
    XCTAssertTrue([SCSentry shouldEmitTelemetrySignature:changedSignature
                                             previousSignature:signature
                                          previousEmissionDate:oneMinuteAgo
                                                           now:now
                                           suppressionInterval:window]);
    XCTAssertTrue([SCSentry shouldEmitTelemetrySignature:signature
                                             previousSignature:signature
                                          previousEmissionDate:[now dateByAddingTimeInterval:-window]
                                                           now:now
                                           suppressionInterval:window]);

    NSMutableDictionary<NSString *, id> *unsafeFields = [fields mutableCopy];
    unsafeFields[@"schedule_id"] = @"not-allowed";
    XCTAssertNil([SCSentry privacySafeTelemetrySignatureForFields:unsafeFields
                                                        eventName:@"state.app_daemon_diverged"]);
}

- (void)testSettingsSchemaAcceptsLegacyOptionalGapsAndRejectsUnsafeEnforcementTypes {
    NSDictionary *validMinimal = @{
        @"SettingsVersionNumber": @7,
        @"LastSettingsUpdate": [NSDate date],
        @"BlockIsRunning": @YES,
        @"BlockEndDate": [NSDate dateWithTimeIntervalSinceNow:60],
        @"ActiveBlocklist": @[@"example.invalid", @"app:com.example.App"],
        @"ActiveBlockAsWhitelist": @NO,
        @"ActiveBlockControllingUID": @501,
    };
    XCTAssertTrue([SCSettings settingsDictionaryHasValidSchema:validMinimal]);

    NSMutableDictionary *invalidVersion = [validMinimal mutableCopy];
    invalidVersion[@"SettingsVersionNumber"] = @YES;
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:invalidVersion]);

    NSMutableDictionary *invalidBlocklist = [validMinimal mutableCopy];
    invalidBlocklist[@"ActiveBlocklist"] = @[@"example.invalid", @42];
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:invalidBlocklist]);

    NSMutableDictionary *invalidRunningState = [validMinimal mutableCopy];
    invalidRunningState[@"BlockIsRunning"] = @"yes";
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:invalidRunningState]);

    invalidRunningState = [validMinimal mutableCopy];
    invalidRunningState[@"BlockIsRunning"] = @1;
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:invalidRunningState]);

    NSMutableDictionary *activeWithoutEnd = [validMinimal mutableCopy];
    [activeWithoutEnd removeObjectForKey:@"BlockEndDate"];
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:activeWithoutEnd]);

    NSMutableDictionary *activeWithoutList = [validMinimal mutableCopy];
    [activeWithoutList removeObjectForKey:@"ActiveBlocklist"];
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:activeWithoutList]);

    NSMutableDictionary *activeEmptyDenylist = [validMinimal mutableCopy];
    activeEmptyDenylist[@"ActiveBlocklist"] = @[];
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:activeEmptyDenylist]);

    NSMutableDictionary *activeEmptyAllowlist = [activeEmptyDenylist mutableCopy];
    activeEmptyAllowlist[@"ActiveBlockAsWhitelist"] = @YES;
    XCTAssertTrue([SCSettings settingsDictionaryHasValidSchema:activeEmptyAllowlist]);

    NSMutableDictionary *invalidSchedule = [validMinimal mutableCopy];
    invalidSchedule[@"ApprovedSchedules"] = @{@"segment": @[@"example.invalid"]};
    XCTAssertFalse([SCSettings settingsDictionaryHasValidSchema:invalidSchedule]);
}

- (void)testSettingsInitializationIsPerInstanceAndNeverLeavesDictionaryNil {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousTestFlag = [defaults objectForKey:@"isTest"];
    @try {
        [defaults setBool:YES forKey:@"isTest"];
        SCSettings *first = [SCSettings new];
        SCSettings *second = [SCSettings new];
        XCTAssertNotNil(first.dictionaryRepresentation);
        XCTAssertNotNil(second.dictionaryRepresentation);
        XCTAssertTrue(first.settingsStateAvailableForEnforcement);
        XCTAssertTrue(second.settingsStateAvailableForEnforcement);
        XCTAssertEqualObjects(first.dictionaryRepresentation[@"ActiveBlocklist"], @[]);
        XCTAssertEqualObjects(second.dictionaryRepresentation[@"ActiveBlocklist"], @[]);
    } @finally {
        if (previousTestFlag != nil) [defaults setObject:previousTestFlag forKey:@"isTest"];
        else [defaults removeObjectForKey:@"isTest"];
    }
}

- (void)testSettingsLoaderRecoversFromCorruptionAndRetainsLastKnownGoodState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousTestFlag = [defaults objectForKey:@"isTest"];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [directory stringByAppendingPathComponent:@"settings.plist"];
    SCSettings *settings = nil;
    @try {
        [defaults setBool:NO forKey:@"isTest"];
        NSError *error = nil;
        XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:&error]);
        XCTAssertTrue([[@"not-a-property-list" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:path options:NSDataWritingAtomic error:&error]);

        settings = [[SCSettings alloc] initWithSettingsFilePathForTesting:path];
        XCTAssertNotNil(settings.dictionaryRepresentation);
        XCTAssertFalse(settings.settingsStateAvailableForEnforcement);

        NSDictionary *validActiveState = @{
            @"SettingsVersionNumber": @10,
            @"LastSettingsUpdate": [NSDate date],
            @"BlockIsRunning": @YES,
            @"BlockEndDate": [NSDate dateWithTimeIntervalSinceNow:600],
            @"ActiveBlocklist": @[@"example.invalid"],
            @"ActiveBlockAsWhitelist": @NO,
            @"ActiveBlockControllingUID": @501,
        };
        NSData *validData = [NSPropertyListSerialization dataWithPropertyList:validActiveState
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0
                                                                         error:&error];
        XCTAssertNotNil(validData);
        XCTAssertTrue([validData writeToFile:path options:NSDataWritingAtomic error:&error]);
        [settings reloadSettings];
        XCTAssertTrue(settings.settingsStateAvailableForEnforcement);
        XCTAssertEqualObjects(settings.dictionaryRepresentation[@"SettingsVersionNumber"], @10);
        XCTAssertEqualObjects(settings.dictionaryRepresentation[@"ActiveBlocklist"], @[@"example.invalid"]);

        XCTAssertTrue([[@"corrupt-again" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:path options:NSDataWritingAtomic error:&error]);
        [settings forceReloadFromDisk];
        XCTAssertTrue(settings.settingsStateAvailableForEnforcement);
        XCTAssertEqualObjects(settings.dictionaryRepresentation[@"SettingsVersionNumber"], @10);
        XCTAssertEqualObjects(settings.dictionaryRepresentation[@"ActiveBlocklist"], @[@"example.invalid"]);
    } @finally {
        settings = nil;
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        if (previousTestFlag != nil) [defaults setObject:previousTestFlag forKey:@"isTest"];
        else [defaults removeObjectForKey:@"isTest"];
    }
}

- (void)testUnavailableSettingsRefuseMutationAndPersistenceUntilValidRecovery {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousTestFlag = [defaults objectForKey:@"isTest"];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [directory stringByAppendingPathComponent:@"settings.plist"];
    SCSettings *settings = nil;
    @try {
        [defaults setBool:NO forKey:@"isTest"];
        NSError *error = nil;
        XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:&error]);
        NSData *corruptData = [@"not-a-property-list" dataUsingEncoding:NSUTF8StringEncoding];
        XCTAssertTrue([corruptData writeToFile:path options:NSDataWritingAtomic error:&error]);

        settings = [[SCSettings alloc] initWithSettingsFilePathForTesting:path];
        settings.readOnly = NO;
        NSDictionary *safeDefaults = [settings.dictionaryRepresentation copy];
        XCTAssertFalse(settings.settingsStateAvailableForEnforcement);

        [settings setValue:@[@"must-not-become-authoritative.invalid"] forKey:@"ActiveBlocklist"];
        XCTAssertEqualObjects(settings.dictionaryRepresentation, safeDefaults);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], corruptData);

        __block NSError *writeError = nil;
        [settings writeSettingsWithCompletion:^(NSError *error) {
            writeError = error;
        }];
        XCTAssertEqual(writeError.code, SCSettingsStateUnavailableErrorCode);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], corruptData);

        NSError *syncError = [settings syncSettingsAndWait:1];
        XCTAssertEqual(syncError.code, SCSettingsStateUnavailableErrorCode);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], corruptData);

        NSDictionary *validActiveState = @{
            @"SettingsVersionNumber": @10,
            @"LastSettingsUpdate": [NSDate date],
            @"BlockIsRunning": @YES,
            @"BlockEndDate": [NSDate dateWithTimeIntervalSinceNow:600],
            @"ActiveBlocklist": @[@"example.invalid"],
            @"ActiveBlockAsWhitelist": @NO,
            @"ActiveBlockControllingUID": @501,
        };
        NSData *validData = [NSPropertyListSerialization dataWithPropertyList:validActiveState
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0
                                                                         error:&error];
        XCTAssertNotNil(validData);
        XCTAssertTrue([validData writeToFile:path options:NSDataWritingAtomic error:&error]);
        [settings reloadSettings];
        XCTAssertTrue(settings.settingsStateAvailableForEnforcement);

        [settings setValue:@[@"recovered.invalid"] forKey:@"ActiveBlocklist"];
        XCTAssertEqualObjects(settings.dictionaryRepresentation[@"ActiveBlocklist"], @[@"recovered.invalid"]);
        __block NSError *recoveredWriteError = nil;
        [settings writeSettingsWithCompletion:^(NSError *error) {
            recoveredWriteError = error;
        }];
        XCTAssertNil(recoveredWriteError);

        // A genuinely missing file has one narrow bootstrap exception. The
        // TESTING build intentionally does not touch disk, but must preserve
        // the production availability transition and normal mutation behavior.
        NSString *missingPath = [directory stringByAppendingPathComponent:@"missing.plist"];
        SCSettings *missingSettings = [[SCSettings alloc] initWithSettingsFilePathForTesting:missingPath];
        missingSettings.readOnly = NO;
        XCTAssertNotNil(missingSettings.dictionaryRepresentation);
        XCTAssertTrue(missingSettings.settingsStateAvailableForEnforcement);
        [missingSettings setValue:@YES forKey:@"EnableErrorReporting"];
        XCTAssertTrue([missingSettings boolForKey:@"EnableErrorReporting"]);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:missingPath]);
    } @finally {
        settings = nil;
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        if (previousTestFlag != nil) [defaults setObject:previousTestFlag forKey:@"isTest"];
        else [defaults removeObjectForKey:@"isTest"];
    }
}

- (void)testSentryConsentConfigurationRequiresExplicitChoiceAndNonRootProcess {
    NSString *dsn = @"https://publickey@o123456.ingest.sentry.io/789012";
    NSDictionary *enabled = @{@"ErrorReportingPromptDismissed": @YES, @"EnableErrorReporting": @YES};
    XCTAssertTrue([SCSentry hasExplicitErrorReportingConsentInDefaults:enabled]);
    XCTAssertFalse([SCSentry hasExplicitErrorReportingConsentInDefaults:@{@"EnableErrorReporting": @YES}]);
    NSDictionary *invalidConsent = @{
        @"ErrorReportingPromptDismissed": @YES, @"EnableErrorReporting": @"YES"
    };
    XCTAssertFalse([SCSentry hasExplicitErrorReportingConsentInDefaults:invalidConsent]);
    NSDictionary *numericConsent = @{
        @"ErrorReportingPromptDismissed": @1, @"EnableErrorReporting": @1
    };
    XCTAssertFalse([SCSentry hasExplicitErrorReportingConsentInDefaults:numericConsent]);
    XCTAssertTrue([SCSentry shouldInitializeSentryForRootProcess:NO configuredDSN:dsn defaults:enabled]);
    XCTAssertFalse([SCSentry shouldInitializeSentryForRootProcess:YES configuredDSN:dsn defaults:enabled]);
    XCTAssertFalse([SCSentry shouldInitializeSentryForRootProcess:NO configuredDSN:nil defaults:enabled]);
    XCTAssertFalse([SCSentry shouldInitializeSentryForRootProcess:NO configuredDSN:dsn defaults:@{}]);
    XCTAssertFalse([SCSentry isSentrySDKActive]);
}

- (void)testSentryExplicitChoicesAdvanceConsentGenerationAndNotify {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id oldEnabled = [defaults objectForKey:@"EnableErrorReporting"];
    id oldDismissed = [defaults objectForKey:@"ErrorReportingPromptDismissed"];
    id oldGeneration = [defaults objectForKey:SCTelemetryConsentGenerationDefaultsKey];
    __block NSDictionary *lastUserInfo = nil;
    __block NSUInteger notificationCount = 0;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:SCTelemetryConsentDidChangeNotification
                    object:SCSentry.class
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        lastUserInfo = notification.userInfo;
        notificationCount += 1;
    }];

    @try {
        [defaults removeObjectForKey:SCTelemetryConsentGenerationDefaultsKey];
        [SCSentry setUserErrorReportingEnabled:YES];
        XCTAssertEqual([defaults integerForKey:SCTelemetryConsentGenerationDefaultsKey], 1);
        XCTAssertTrue([defaults boolForKey:@"ErrorReportingPromptDismissed"]);
        XCTAssertTrue([defaults boolForKey:@"EnableErrorReporting"]);
        XCTAssertEqualObjects(lastUserInfo[@"enabled"], @YES);
        XCTAssertEqualObjects(lastUserInfo[@"generation"], @1);
        XCTAssertEqual(notificationCount, 1U);

        [SCSentry setUserErrorReportingEnabled:NO];
        XCTAssertEqual([defaults integerForKey:SCTelemetryConsentGenerationDefaultsKey], 2);
        XCTAssertFalse([defaults boolForKey:@"EnableErrorReporting"]);
        XCTAssertEqualObjects(lastUserInfo[@"enabled"], @NO);
        XCTAssertEqualObjects(lastUserInfo[@"generation"], @2);
        XCTAssertEqual(notificationCount, 2U);
    } @finally {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        if (oldEnabled != nil) [defaults setObject:oldEnabled forKey:@"EnableErrorReporting"];
        else [defaults removeObjectForKey:@"EnableErrorReporting"];
        if (oldDismissed != nil) [defaults setObject:oldDismissed forKey:@"ErrorReportingPromptDismissed"];
        else [defaults removeObjectForKey:@"ErrorReportingPromptDismissed"];
        if (oldGeneration != nil) [defaults setObject:oldGeneration forKey:SCTelemetryConsentGenerationDefaultsKey];
        else [defaults removeObjectForKey:SCTelemetryConsentGenerationDefaultsKey];
    }
}

- (void)testSpooledTelemetryRecordBoundaryRevalidatesExactShapeAndOrigin {
    NSDictionary *record = @{
        @"id": @"D2737210-4DA5-4CE7-BC24-D5A58A8292B7",
        @"schema_version": @1,
        @"event_name": @"daemon.settings_load_failed",
        @"level": @"error",
        @"origin": @"daemon",
        @"created_at_ms": @1750000000000,
        @"fields": @{
            @"reason": @"missing", @"settings_version": @1,
            @"recovery_attempted": @NO, @"recovery_succeeded": @NO,
        },
    };
    NSDictionary *safe = [SCSentry sanitizedSpooledTelemetryRecord:record];
    XCTAssertNotNil(safe);
    XCTAssertEqualObjects(safe[@"id"], @"d2737210-4da5-4ce7-bc24-d5a58a8292b7");
    XCTAssertEqualObjects(safe[@"origin"], @"daemon");

    NSMutableDictionary *extraKey = [record mutableCopy];
    extraKey[@"tags"] = @{@"origin": @"attacker"};
    XCTAssertNil([SCSentry sanitizedSpooledTelemetryRecord:extraKey]);

    NSMutableDictionary *badOrigin = [record mutableCopy];
    badOrigin[@"origin"] = @"root";
    XCTAssertNil([SCSentry sanitizedSpooledTelemetryRecord:badOrigin]);

    NSMutableDictionary *emptyEventID = [record mutableCopy];
    emptyEventID[@"id"] = @"00000000-0000-0000-0000-000000000000";
    XCTAssertNil([SCSentry sanitizedSpooledTelemetryRecord:emptyEventID]);

    NSMutableDictionary *missingRequiredField = [record mutableCopy];
    NSMutableDictionary *fields = [record[@"fields"] mutableCopy];
    [fields removeObjectForKey:@"recovery_succeeded"];
    missingRequiredField[@"fields"] = fields;
    XCTAssertNil([SCSentry sanitizedSpooledTelemetryRecord:missingRequiredField]);
}

- (void)testSentryDedicatedCachePathIsFenceScoped {
    NSString *path = [SCSentry dedicatedSentryCacheDirectoryPathForCachesDirectory:@"/tmp/cache-root"];
    XCTAssertEqualObjects(path, @"/tmp/cache-root/org.eyebeam.Fence/Telemetry/SentrySDK");
    XCTAssertNil([SCSentry dedicatedSentryCacheDirectoryPathForCachesDirectory:nil]);
    XCTAssertNil([SCSentry dedicatedSentryCacheDirectoryPathForCachesDirectory:@""]);
}

- (void)testTelemetryOutgoingPrivacyTripwireFailsClosed {
    NSDictionary *safePayload = @{
        @"release": @"fence-app@3.4.7+647",
        @"contexts": @{
            @"diagnostic": @{
                @"event_name": @"block.strictify_result",
                @"fields": @{
                    @"requested_addition_count": @2,
                    @"active_counts_match": @YES
                }
            }
        }
    };
    XCTAssertTrue([SCSentry payloadPassesTelemetryPrivacyTripwire:safePayload]);
    XCTAssertFalse([SCSentry payloadPassesTelemetryPrivacyTripwire:@{@"blocklist": @[@"private.example"]}]);
    XCTAssertFalse([SCSentry payloadPassesTelemetryPrivacyTripwire:@{@"message": @"canary-telemetry-test.example"}]);
    XCTAssertFalse([SCSentry payloadPassesTelemetryPrivacyTripwire:@{@"message": @"private@example.invalid"}]);
    XCTAssertFalse([SCSentry payloadPassesTelemetryPrivacyTripwire:@{@"message": @"/Users/private/secret.txt"}]);
    XCTAssertFalse([SCSentry payloadPassesTelemetryPrivacyTripwire:@{@"message": @"app:private.bundle"}]);
}

- (void)testRealSentrySDKFakeTransportEmitsOnlySanitizedEnvelope {
    NSString *temporaryCache = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"fence-sentry-sdk-test-%@",
                                                                  NSUUID.UUID.UUIDString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:temporaryCache
                                            withIntermediateDirectories:YES
                                                             attributes:@{NSFilePosixPermissions: @0700}
                                                                  error:nil]);

    NSURLSessionConfiguration *sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    sessionConfiguration.protocolClasses = @[[SCSentryFakeURLProtocol class]];
    sessionConfiguration.URLCache = nil;
    sessionConfiguration.HTTPCookieStorage = nil;
    NSURLSession *fakeTransportSession = [NSURLSession sessionWithConfiguration:sessionConfiguration];

    SentryOptions *options = [[SentryOptions alloc] init];
    // The custom URL protocol intercepts every request. Loopback remains a
    // second fail-safe if that interception is accidentally removed.
    options.dsn = @"https://publickey@127.0.0.1:1/789012";
    options.cacheDirectoryPath = temporaryCache;
    options.urlSession = fakeTransportSession;
    options.releaseName = @"fence-app@3.4.7+647";
    options.dist = @"647";
    options.shutdownTimeInterval = 0;
    [SCSentry configurePrivacyBoundaryOnOptions:options transmissionAllowed:^BOOL{
        return YES;
    }];

    XCTAssertFalse(options.sendDefaultPii);
    XCTAssertFalse(options.sendClientReports);
    XCTAssertFalse(options.enableNetworkBreadcrumbs);
    XCTAssertFalse(options.enableNetworkTracking);
    XCTAssertFalse(options.enableCaptureFailedRequests);
    XCTAssertFalse(options.enableAutoBreadcrumbTracking);
    XCTAssertFalse(options.enableAutoPerformanceTracing);
    XCTAssertFalse(options.enableLogs);
    XCTAssertEqual(options.maxAttachmentSize, 0u);
    XCTAssertEqualObjects(options.tracePropagationTargets, @[]);

    SentryBreadcrumb *automaticURLBreadcrumb = [[SentryBreadcrumb alloc] initWithLevel:kSentryLevelInfo
                                                                               category:@"http"];
    automaticURLBreadcrumb.type = @"http";
    automaticURLBreadcrumb.message = @"GET https://canary-telemetry-test.example/private";
    automaticURLBreadcrumb.data = @{@"url": @"https://canary-telemetry-test.example/private"};
    XCTAssertNil(options.beforeBreadcrumb(automaticURLBreadcrumb));

    NSMutableArray<NSString *> *userIDsSeenAtBoundary = [NSMutableArray array];
    SentryBeforeSendEventCallback productionBeforeSend = options.beforeSend;
    options.beforeSend = ^SentryEvent * _Nullable(SentryEvent *event) {
        if (event.user.userId.length > 0) {
            @synchronized (userIDsSeenAtBoundary) {
                [userIDsSeenAtBoundary addObject:event.user.userId];
            }
        }
        return productionBeforeSend(event);
    };

    XCTestExpectation *requestExpectation = [self expectationWithDescription:@"two sanitized Sentry envelopes"];
    requestExpectation.expectedFulfillmentCount = 2;
    NSMutableArray<NSDictionary<NSString *, id> *> *capturedEnvelopes = [NSMutableArray array];
    [SCSentryFakeURLProtocol setRequestHandler:^(NSURLRequest *request) {
        NSDictionary *envelope = SCSentryParsedEnvelopeFromRequest(request);
        @synchronized (capturedEnvelopes) {
            if (envelope != nil) [capturedEnvelopes addObject:envelope];
        }
        [requestExpectation fulfill];
    }];

    SentryClient *client = [[SentryClient alloc] initWithOptions:options];
    XCTAssertNotNil(client);

    NSDictionary *safeDiagnostic = @{
        @"event_name": @"daemon.settings_load_failed",
        @"fields": @{
            @"reason": @"missing",
            @"recovery_attempted": @YES,
            @"recovery_succeeded": @NO,
            @"settings_version": @1,
        },
    };

    SentryEvent *unsafeEvent = [[SentryEvent alloc] initWithLevel:kSentryLevelError];
    unsafeEvent.message = [[SentryMessage alloc] initWithFormatted:@"daemon.settings_load_failed"];
    unsafeEvent.context = @{
        @"diagnostic": safeDiagnostic,
        @"undeclared_context": @{
            @"blocklist": @[@"canary-telemetry-test.example"],
            @"controllingUID": @4242424242,
            @"deviceIdentifierFallback": @"device-token-telemetry-sentinel",
        },
    };
    unsafeEvent.extra = @{
        @"license": @"FENCE-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
        @"path": @"/Users/private-person/secret.txt",
    };
    unsafeEvent.tags = @{@"undeclared_tag": @"canary-telemetry-test.example"};
    SentryRequest *request = [[SentryRequest alloc] init];
    request.url = @"https://canary-telemetry-test.example/private";
    request.queryString = @"email=private@example.invalid";
    unsafeEvent.request = request;

    SentryScope *unsafeScope = [[SentryScope alloc] init];
    SentryUser *unsafeUser = [[SentryUser alloc] initWithUserId:@"raw-user-id-telemetry-sentinel"];
    unsafeUser.username = @"/Users/private-person";
    unsafeUser.email = @"private@example.invalid";
    unsafeUser.data = @{
        @"license": @"FENCE-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
        @"device_token": @"device-token-telemetry-sentinel",
    };
    [unsafeScope setUser:unsafeUser];
    [unsafeScope addBreadcrumb:automaticURLBreadcrumb];
    [unsafeScope setContextValue:@{@"value": @"undeclared-context-telemetry-sentinel"}
                          forKey:@"another_undeclared_context"];
    NSData *attachmentData = [@"attachment-private@example.invalid"
        dataUsingEncoding:NSUTF8StringEncoding];
    [unsafeScope addAttachment:[[SentryAttachment alloc] initWithData:attachmentData
                                                             filename:@"private-support-log.txt"]];
    [client captureEvent:unsafeEvent withScope:unsafeScope];

    // With no user supplied, Sentry 9.14 injects its installation identifier
    // immediately before beforeSend. The production callback must remove it.
    SentryEvent *sdkUserEvent = [[SentryEvent alloc] initWithLevel:kSentryLevelError];
    sdkUserEvent.message = [[SentryMessage alloc] initWithFormatted:@"daemon.settings_load_failed"];
    sdkUserEvent.context = @{@"diagnostic": safeDiagnostic};
    [client captureEvent:sdkUserEvent withScope:[[SentryScope alloc] init]];

    [self waitForExpectations:@[requestExpectation] timeout:8.0];

    NSArray<NSDictionary<NSString *, id> *> *envelopes = nil;
    @synchronized (capturedEnvelopes) {
        envelopes = [capturedEnvelopes copy];
    }
    XCTAssertEqual(envelopes.count, 2u);

    NSMutableArray<NSDictionary<NSString *, id> *> *payloads = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *envelope in envelopes) {
        // beforeSend cannot inspect attachment/session/client-report items. The
        // production options must ensure the final HTTP envelope is event-only.
        XCTAssertEqualObjects(envelope[@"item_types"], @[SentryEnvelopeItemTypes.event]);
        NSDictionary *payload = [envelope[@"event"] isKindOfClass:[NSDictionary class]]
            ? envelope[@"event"] : nil;
        XCTAssertNotNil(payload);
        if (payload != nil) [payloads addObject:payload];
    }
    XCTAssertEqual(payloads.count, 2u);

    NSArray<NSString *> *forbiddenFragments = @[
        @"canary-telemetry-test.example",
        @"/users/private-person",
        @"private@example.invalid",
        @"fence-abcdefghijklmnopqrstuvwxyz123456",
        @"device-token-telemetry-sentinel",
        @"raw-user-id-telemetry-sentinel",
        @"4242424242",
        @"undeclared-context-telemetry-sentinel",
        @"another_undeclared_context",
        @"undeclared_context",
        @"undeclared_tag",
        @"private-support-log.txt",
        @"attachment-private@example.invalid",
    ];
    for (NSDictionary<NSString *, id> *payload in payloads) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
        NSString *json = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] lowercaseString];
        XCTAssertTrue([json containsString:@"daemon.settings_load_failed"]);
        for (NSString *forbidden in forbiddenFragments) {
            XCTAssertFalse([json containsString:forbidden], @"Outbound envelope retained forbidden fragment: %@", forbidden);
        }

        XCTAssertNil(payload[@"user"]);
        XCTAssertNil(payload[@"request"]);
        XCTAssertNil(payload[@"extra"]);
        NSDictionary *contexts = payload[@"contexts"];
        XCTAssertEqualObjects([NSSet setWithArray:contexts.allKeys], [NSSet setWithObject:@"diagnostic"]);
        NSArray *breadcrumbs = payload[@"breadcrumbs"];
        XCTAssertTrue(breadcrumbs == nil || breadcrumbs.count == 0);
        XCTAssertTrue([SCSentry payloadPassesTelemetryPrivacyTripwire:payload]);
    }

    NSArray<NSString *> *boundaryUserIDs = nil;
    @synchronized (userIDsSeenAtBoundary) {
        boundaryUserIDs = [userIDsSeenAtBoundary copy];
    }
    XCTAssertEqual(boundaryUserIDs.count, 2u);
    XCTAssertEqualObjects(boundaryUserIDs.firstObject, @"raw-user-id-telemetry-sentinel");
    XCTAssertTrue(boundaryUserIDs.lastObject.length > 0);
    XCTAssertNotEqualObjects(boundaryUserIDs.lastObject, boundaryUserIDs.firstObject);

    [client close];
    [SCSentryFakeURLProtocol setRequestHandler:nil];
    [fakeTransportSession invalidateAndCancel];
    [[NSFileManager defaultManager] removeItemAtPath:temporaryCache error:nil];
}

- (void)testBlockApplyResultDefaultDictionaryIsTypedAndPrivacySafe {
    SCBlockApplyResult* result = [[SCBlockApplyResult alloc] initWithOperation:SCBlockApplyOperationStrictify];
    NSDictionary* dictionary = [result dictionaryRepresentation];

    XCTAssertEqualObjects(dictionary[@"schema_version"], @1);
    XCTAssertEqualObjects(dictionary[@"operation"], @"strictify");
    XCTAssertEqualObjects(dictionary[@"status"], @"in_progress");
    XCTAssertEqualObjects(dictionary[@"hosts"][@"write"], @"not_attempted");
    XCTAssertEqualObjects(dictionary[@"packet_filter"][@"verify"], @"not_attempted");
    XCTAssertEqualObjects(dictionary[@"entries"][@"rejected_count"], @0);
    XCTAssertFalse([[dictionary description] containsString:@"bundle_id"]);
    XCTAssertFalse([[dictionary description] containsString:@"path"]);
    XCTAssertFalse([[dictionary description] containsString:@"canary.invalid"]);
}

- (void)testHostFileBlockerReportsExactDiskVerificationFailure {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* hostsPath = [directory stringByAppendingPathComponent:@"hosts"];
    NSError* error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([@"127.0.0.1 localhost\n" writeToFile:hostsPath
                                               atomically:YES
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error]);

    HostFileBlocker* blocker = [[HostFileBlocker alloc] initWithPath:hostsPath];
    XCTAssertFalse([blocker containsCompleteSelfControlBlock]);
    [blocker addSelfControlBlockHeader];
    XCTAssertTrue([blocker containsSelfControlBlock]);
    XCTAssertFalse([blocker containsCompleteSelfControlBlock]);
    XCTAssertFalse([blocker appendExistingBlockWithRuleForDomain:@"missing-footer.invalid"]);
    [blocker addRuleBlockingDomain:@"canary.invalid"];
    [blocker addSelfControlBlockFooter];
    XCTAssertTrue([blocker containsCompleteSelfControlBlock]);
    XCTAssertTrue([blocker appendExistingBlockWithRuleForDomain:@"append-canary.invalid"]);
    XCTAssertTrue([blocker writeNewFileContentsWithError:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([blocker verifyNewFileContentsWithError:&error]);
    XCTAssertNil(error);

    XCTAssertTrue([@"externally changed\n" writeToFile:hostsPath
                                              atomically:YES
                                                encoding:NSUTF8StringEncoding
                                                   error:&error]);
    XCTAssertFalse([blocker verifyNewFileContentsWithError:&error]);
    XCTAssertEqual(error.code, SCHostFileBlockerErrorContentsMismatch);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void) testModernBlockDetection {
    SCSettings* settings = [SCSettings sharedSettings];

    XCTAssert(![SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);

    // test a block that should have expired 5 minutes ago
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    [settings setValue: @[ @"facebook.com", @"reddit.com" ] forKey: @"ActiveBlocklist"];
    [settings setValue: @NO forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: [NSDate dateWithTimeIntervalSinceNow: -300] forKey: @"BlockEndDate"];

    XCTAssert([SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);

    // test block that should still be running
    [settings setValue: [NSDate dateWithTimeIntervalSinceNow: 300] forKey: @"BlockEndDate"];
    XCTAssert([SCBlockUtilities modernBlockIsRunning]);
    XCTAssert(![SCBlockUtilities currentBlockIsExpired]);

    // test removing a block
    [SCBlockUtilities removeBlockFromSettings];
    XCTAssert(![SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);
}

- (void) testLegacyBlockDetection {
    // test blockIsRunningInLegacyDictionary
    // the block is "running" even if it's expired, since it hasn't been removed
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: activeBlockLegacyDict]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: expiredBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: noBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: noBlockLegacyDict2]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: futureStartDateLegacyDict]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: negativeBlockDurationLegacyDict]); // negative still might be running?
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: veryLongBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: emptyLegacyDict]);
}

@end

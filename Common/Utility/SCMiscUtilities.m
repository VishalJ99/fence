//
//  SCMiscUtilities.m
//  SelfControl
//
//  Created by Charles Stigler on 07/07/2018.
//

#import "SCMiscUtilities.h"
#import "SCHelperToolUtilities.h"
#import "SCSettings.h"
#import <CommonCrypto/CommonCrypto.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <IOKit/IOKitLib.h>
#include <arpa/inet.h>

static BOOL SCParsePositiveInteger(NSString* string, NSInteger maximum, NSInteger* valueOut) {
    if (string.length == 0) return NO;

    NSInteger value = 0;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar character = [string characterAtIndex:i];
        if (character < '0' || character > '9') return NO;

        NSInteger digit = character - '0';
        if (value > (maximum - digit) / 10) return NO;
        value = (value * 10) + digit;
    }

    if (value < 1 || value > maximum) return NO;
    if (valueOut != NULL) *valueOut = value;
    return YES;
}

static int SCIPAddressFamily(NSString* string) {
    struct in_addr ipv4Address;
    if (inet_pton(AF_INET, string.UTF8String, &ipv4Address) == 1) return AF_INET;

    struct in6_addr ipv6Address;
    if (inet_pton(AF_INET6, string.UTF8String, &ipv6Address) == 1) return AF_INET6;

    return AF_UNSPEC;
}

static NSString* SCNormalizedHost(NSString* rawHost, int* addressFamilyOut) {
    NSString* host = [rawHost lowercaseString];
    if (host.length == 0) return nil;

    // A single terminal dot is the valid fully-qualified form of a DNS name.
    // More than one terminal dot is malformed and must not be normalized into
    // a different, apparently valid hostname.
    if ([host hasSuffix:@"."]) {
        if ([host hasSuffix:@".."] || host.length == 1) return nil;
        host = [host substringToIndex:host.length - 1];
    }

    int addressFamily = SCIPAddressFamily(host);
    if (addressFamily != AF_UNSPEC) {
        if (addressFamilyOut != NULL) *addressFamilyOut = addressFamily;
        return host;
    }

    // Normalize internationalized hostnames to the ASCII form used by DNS,
    // /etc/hosts, and PF. NSURL performs IDNA conversion without retaining any
    // URL path/query/user data.
    if (![host canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        NSURLComponents *components = [NSURLComponents componentsWithString:
            [@"https://" stringByAppendingString:host]];
        NSString *asciiHost = components.URL.host.lowercaseString;
        if (asciiHost.length == 0 || ![asciiHost canBeConvertedToEncoding:NSASCIIStringEncoding]) return nil;
        host = asciiHost;
    }

    if (host.length > 253) return nil;

    NSArray<NSString*>* labels = [host componentsSeparatedByString:@"."];
    if (labels.count == 0) return nil;

    BOOL containsOnlyDigitsAndDots = YES;
    for (NSString* label in labels) {
        if (label.length == 0 || label.length > 63 ||
            [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) {
            return nil;
        }

        for (NSUInteger i = 0; i < label.length; i++) {
            unichar character = [label characterAtIndex:i];
            BOOL isASCIILetter = (character >= 'a' && character <= 'z');
            BOOL isDigit = (character >= '0' && character <= '9');
            // Underscores are not valid in ordinary host labels, but browsers
            // and existing Fence lists can resolve them. Preserve support so an
            // update never silently removes an already-enforced entry.
            if (!isASCIILetter && !isDigit && character != '-' && character != '_') return nil;
            if (!isDigit) containsOnlyDigitsAndDots = NO;
        }
    }

    // A dotted numeric value is intended to be an IP address. Requiring it to
    // pass inet_pton avoids treating values such as 999.999.999.999 as DNS.
    if (labels.count > 1 && containsOnlyDigitsAndDots) return nil;

    if (addressFamilyOut != NULL) *addressFamilyOut = AF_UNSPEC;
    return host;
}

static BOOL SCParseNetworkAuthority(NSString* rawAuthority,
                                    NSString** hostnameOut,
                                    NSInteger* portOut,
                                    int* addressFamilyOut) {
    NSString* authority = rawAuthority;

    // Keep compatibility with pasted URLs containing credentials, but never
    // retain or emit the credentials themselves.
    NSRange atRange = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    if (atRange.location != NSNotFound) {
        authority = [authority substringFromIndex:NSMaxRange(atRange)];
    }

    if (authority.length == 0) return NO;

    NSString* rawHost = nil;
    NSInteger port = 0;
    int addressFamily = AF_UNSPEC;

    if ([authority hasPrefix:@"["]) {
        NSRange closingBracket = [authority rangeOfString:@"]"];
        if (closingBracket.location == NSNotFound || closingBracket.location < 2) return NO;

        rawHost = [authority substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
        NSString* suffix = [authority substringFromIndex:NSMaxRange(closingBracket)];
        if (suffix.length > 0) {
            if (![suffix hasPrefix:@":"] ||
                !SCParsePositiveInteger([suffix substringFromIndex:1], 65535, &port)) {
                return NO;
            }
        }

        rawHost = SCNormalizedHost(rawHost, &addressFamily);
        if (rawHost == nil || addressFamily != AF_INET6) return NO;
    } else {
        // An unbracketed IPv6 address has colons but no port. Try it as a whole
        // before interpreting a single colon as the host/port delimiter.
        NSString* wholeHost = SCNormalizedHost(authority, &addressFamily);
        if (wholeHost != nil && addressFamily == AF_INET6) {
            rawHost = wholeHost;
        } else {
            NSArray<NSString*>* colonParts = [authority componentsSeparatedByString:@":"];
            if (colonParts.count > 2) return NO;

            if (colonParts.count == 2) {
                rawHost = colonParts[0];
                if (!SCParsePositiveInteger(colonParts[1], 65535, &port)) return NO;
            } else {
                rawHost = authority;
            }

            if (rawHost.length == 0 && port > 0) rawHost = @"*";
            if ([rawHost isEqualToString:@"*"]) {
                addressFamily = AF_UNSPEC;
            } else {
                rawHost = SCNormalizedHost(rawHost, &addressFamily);
                if (rawHost == nil) return NO;
            }
        }
    }

    if ([rawHost isEqualToString:@"*"] && port == 0) return NO;

    if (hostnameOut != NULL) *hostnameOut = rawHost;
    if (portOut != NULL) *portOut = port;
    if (addressFamilyOut != NULL) *addressFamilyOut = addressFamily;
    return YES;
}

static BOOL SCValidAppBundleID(NSString* bundleID) {
    if (bundleID.length == 0 || bundleID.length > 255) return NO;

    NSArray<NSString*>* components = [bundleID componentsSeparatedByString:@"."];
    for (NSString* component in components) {
        if (component.length == 0) return NO;
        for (NSUInteger i = 0; i < component.length; i++) {
            unichar character = [component characterAtIndex:i];
            BOOL isASCIILetter = ((character >= 'a' && character <= 'z') ||
                                  (character >= 'A' && character <= 'Z'));
            BOOL isDigit = (character >= '0' && character <= '9');
            if (!isASCIILetter && !isDigit && character != '-') return NO;
        }
    }
    return YES;
}

@implementation SCMiscUtilities

// copied from stevenojo's GitHub snippet: https://gist.github.com/stevenojo/e1dcc2b3e2fd4ed1f411eef88e254cb0
+ (dispatch_source_t)createDebounceDispatchTimer:(double)debounceTime queue:(dispatch_queue_t)queue block:(dispatch_block_t)block {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    
    if (timer) {
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, debounceTime * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, (1ull * NSEC_PER_SEC) / 10);
        dispatch_source_set_event_handler(timer, block);
        dispatch_resume(timer);
    }
    
    return timer;
}

// by Martin R et al on StackOverflow: https://stackoverflow.com/a/15451318
+ (NSString *)getSerialNumber {
    NSString *serial = nil;
    io_service_t platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                              IOServiceMatching("IOPlatformExpertDevice"));
    if (platformExpert) {
        CFTypeRef serialNumberAsCFString =
        IORegistryEntryCreateCFProperty(platformExpert,
                                        CFSTR(kIOPlatformSerialNumberKey),
                                        kCFAllocatorDefault, 0);
        if (serialNumberAsCFString) {
            serial = CFBridgingRelease(serialNumberAsCFString);
        }
        
        IOObjectRelease(platformExpert);
    }
    return serial;
}
// by hypercrypt et al on StackOverflow: https://stackoverflow.com/a/7571583
+ (NSString *)sha1:(NSString*)stringToHash
{
    NSData *data = [stringToHash dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
    {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

+ (BOOL)systemThirdPartyCrashReportingEnabled {
    NSUserDefaults* appleCrashReporter = [NSUserDefaults standardUserDefaults];
    [appleCrashReporter addSuiteNamed: @"/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"];

    return [appleCrashReporter boolForKey: @"ThirdPartyDataSubmit"];
}

+ (NSString*)canonicalBlockEntryFromString:(NSString*)rawEntry {
    if (rawEntry == nil) return nil;

    NSString* trimmedEntry = [rawEntry stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedEntry.length == 0 ||
        [trimmedEntry rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
        return nil;
    }

    if (trimmedEntry.length >= 4 &&
        [[trimmedEntry substringToIndex:4] caseInsensitiveCompare:@"app:"] == NSOrderedSame) {
        NSString* bundleID = [[trimmedEntry substringFromIndex:4]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!SCValidAppBundleID(bundleID)) return nil;

        // Bundle identifiers are compared with the running process's identifier,
        // so preserve their case even though network entries are lowercased.
        return [@"app:" stringByAppendingString:bundleID];
    }

    NSString* networkEntry = [trimmedEntry lowercaseString];
    NSString* authority = nil;
    NSInteger maskLength = 0;
    NSInteger port = 0;
    NSString* hostname = nil;
    int addressFamily = AF_UNSPEC;

    NSRange schemeSeparator = [networkEntry rangeOfString:@"://"];
    if (schemeSeparator.location != NSNotFound) {
        NSString* scheme = [networkEntry substringToIndex:schemeSeparator.location];
        if (scheme.length == 0) return nil;

        for (NSUInteger i = 0; i < scheme.length; i++) {
            unichar character = [scheme characterAtIndex:i];
            BOOL isLetter = (character >= 'a' && character <= 'z');
            BOOL isDigit = (character >= '0' && character <= '9');
            if ((!isLetter && (i == 0 || (!isDigit && character != '+' && character != '-' && character != '.')))) {
                return nil;
            }
        }

        NSString* remainder = [networkEntry substringFromIndex:NSMaxRange(schemeSeparator)];
        NSRange delimiter = [remainder rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
        authority = (delimiter.location == NSNotFound) ? remainder : [remainder substringToIndex:delimiter.location];
        if (!SCParseNetworkAuthority(authority, &hostname, &port, &addressFamily)) return nil;
    } else {
        NSRange queryOrFragment = [networkEntry rangeOfCharacterFromSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"?#"]];
        NSString* withoutQuery = (queryOrFragment.location == NSNotFound)
            ? networkEntry
            : [networkEntry substringToIndex:queryOrFragment.location];

        NSRange slash = [withoutQuery rangeOfString:@"/"];
        authority = (slash.location == NSNotFound)
            ? withoutQuery
            : [withoutQuery substringToIndex:slash.location];

        if (!SCParseNetworkAuthority(authority, &hostname, &port, &addressFamily)) return nil;

        if (slash.location != NSNotFound && addressFamily != AF_UNSPEC) {
            NSString* suffix = [withoutQuery substringFromIndex:NSMaxRange(slash)];
            BOOL hasAnotherSlash = [suffix rangeOfString:@"/"].location != NSNotFound;
            NSArray<NSString*>* maskAndPort = [suffix componentsSeparatedByString:@":"];

            // A numeric suffix on an IP address is CIDR rather than a URL path.
            // If it looks like CIDR, reject invalid masks/ports rather than
            // silently dropping them.
            BOOL looksLikeCIDR = suffix.length > 0 &&
                [suffix characterAtIndex:0] >= '0' && [suffix characterAtIndex:0] <= '9' &&
                !hasAnotherSlash && maskAndPort.count <= 2;
            if (looksLikeCIDR) {
                NSInteger maximumMask = (addressFamily == AF_INET) ? 32 : 128;
                if (!SCParsePositiveInteger(maskAndPort[0], maximumMask, &maskLength)) return nil;

                if (maskAndPort.count == 2) {
                    NSInteger trailingPort = 0;
                    if (port > 0 || !SCParsePositiveInteger(maskAndPort[1], 65535, &trailingPort)) return nil;
                    port = trailingPort;
                }
            }
        }
    }

    BOOL requiresIPv6Brackets = (addressFamily == AF_INET6 && port > 0);
    NSString* canonicalHost = requiresIPv6Brackets
        ? [NSString stringWithFormat:@"[%@]", hostname]
        : hostname;
    NSMutableString* canonicalEntry = [canonicalHost mutableCopy];
    if (maskLength > 0) [canonicalEntry appendFormat:@"/%ld", (long)maskLength];
    if (port > 0) [canonicalEntry appendFormat:@":%ld", (long)port];
    return canonicalEntry;
}

// Standardize and clean up the input value so it'll block properly (and look good doing it)
// note that if the user entered line breaks, we'll split it into many entries, so this can return multiple
// cleaned entries in the NSArray it returns
+ (NSArray<NSString*>*) cleanBlocklistEntry:(NSString*)rawEntry {
    if (rawEntry == nil) return @[];

    // if there are newlines in the string, split it and process it as many strings
	if([rawEntry rangeOfCharacterFromSet: [NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
		NSArray* splitEntries = [rawEntry componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]];
        
        NSMutableArray* returnArr = [NSMutableArray new];
        for (NSString* splitEntry in splitEntries) {
            // recursion makes the rest of the code prettier
            NSArray<NSString*>* cleanedSubEntries = [SCMiscUtilities cleanBlocklistEntry: splitEntry];
            [returnArr addObjectsFromArray: cleanedSubEntries];
        }
        return returnArr;
    }

    NSString* canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:rawEntry];
    return canonicalEntry == nil ? @[] : @[canonicalEntry];
}

+ (NSArray<NSString*>*)cleanBlocklist:(NSArray<NSString*>*)blocklist {
    NSMutableOrderedSet<NSString*>* cleanedList = [NSMutableOrderedSet orderedSet];

    for (id blockString in blocklist ?: @[]) {
        if (![blockString isKindOfClass:[NSString class]]) continue;
        for (NSString *canonicalEntry in [SCMiscUtilities cleanBlocklistEntry:blockString]) {
            [cleanedList addObject:canonicalEntry];
        }
    }

    return cleanedList.array;
}

+ (NSDictionary*) defaultsDictForUser:(uid_t) controllingUID {
    if (geteuid() != 0) {
        // if we're not root, we can't just get defaults for some arbitrary user
        return nil;
    }
    
    // pull up the user's defaults in the old legacy way
    // to do that, we have to seteuid to the controlling UID so NSUserDefaults thinks we're them
    seteuid(controllingUID);
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults addSuiteNamed: @"org.eyebeam.SelfControl"];
    [defaults registerDefaults: SCConstants.defaultUserDefaults];
    [defaults synchronize];
    NSDictionary* dictValue = [defaults dictionaryRepresentation];
    // reset the euid so nothing else gets funky
    [NSUserDefaults resetStandardUserDefaults];
    seteuid(0);
    
    return dictValue;
}

+ (BOOL)errorIsAuthCanceled:(NSError*)err {
    if (err == nil) return NO;
    
    if ([err.domain isEqualToString: NSOSStatusErrorDomain] && err.code == AUTH_CANCELLED_STATUS) {
        return YES;
    }
    if ([err.domain isEqualToString: kSelfControlErrorDomain] && err.code == 1) {
        return YES;
    }
    
    return NO;
}

+ (NSArray<NSURL*>*)allUserHomeDirectoryURLs:(NSError**)errPtr {
    NSError* retErr = nil;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL* usersFolderURL = [NSURL fileURLWithPath: @"/Users"];
    NSArray<NSURL *>* homeDirectoryURLs = [fileManager contentsOfDirectoryAtURL: usersFolderURL
                                                     includingPropertiesForKeys: @[NSURLPathKey, NSURLIsDirectoryKey, NSURLIsReadableKey]
                                                                        options: NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error: &retErr];
    if (homeDirectoryURLs == nil || homeDirectoryURLs.count == 0) {
        if (retErr != nil) {
            *errPtr = retErr;
        } else {
            *errPtr = [SCErr errorWithCode: 700];
        }
        
        [SCSentry captureError: *errPtr];
        
        return nil;
    }
    
    return homeDirectoryURLs;
}

+ (NSString*)killerKeyForDate:(NSDate*)date {
    return [SCMiscUtilities sha1: [NSString stringWithFormat: @"SelfControlKillerKey%@%@", [SCMiscUtilities getSerialNumber], [date descriptionWithLocale: nil]]];
}

+ (uid_t)consoleUserUID {
    uid_t uid = 0;
    CFStringRef userName = SCDynamicStoreCopyConsoleUser(NULL, &uid, NULL);
    if (userName) {
        CFRelease(userName);
    }
    return uid;
}

@end

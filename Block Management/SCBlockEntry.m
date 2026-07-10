//
//  SCBlockEntry.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/20/21.
//

#import "SCBlockEntry.h"
#import "SCMiscUtilities.h"

@implementation SCBlockEntry

- (instancetype)init {
    return [self initWithHostname: nil port: 0 maskLen: 0];
}
- (instancetype)initWithHostname:(NSString*)hostname {
    return [self initWithHostname: hostname port: 0 maskLen: 0];
}
- (instancetype)initWithHostname:(NSString*)hostname port:(NSInteger)port maskLen:(NSInteger)maskLen {
    if (self = [super init]) {
        _hostname = hostname;
        _port = port;
        _maskLen = maskLen;
    }
    return self;
}

+ (instancetype)entryWithHostname:(NSString*)hostname port:(NSInteger)port maskLen:(NSInteger)maskLen {
    return [[SCBlockEntry alloc] initWithHostname: hostname port: port maskLen: maskLen];
}

+ (instancetype)entryWithHostname:(NSString*)hostname {
    return [[SCBlockEntry alloc] initWithHostname: hostname];
}

+ (instancetype)entryWithAppBundleID:(NSString*)bundleID {
    SCBlockEntry* entry = [[SCBlockEntry alloc] init];
    entry.appBundleID = bundleID;
    entry.hostname = nil;
    entry.port = 0;
    entry.maskLen = 0;
    return entry;
}

+ (instancetype)entryFromString:(NSString*)hostString {
    NSString* canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:hostString];
    if (canonicalEntry == nil) return nil;

    // Handle app: prefix for app blocking
    if ([canonicalEntry hasPrefix:@"app:"]) {
        NSString* bundleID = [canonicalEntry substringFromIndex:4];
        return [SCBlockEntry entryWithAppBundleID:bundleID];
    }

    NSString* hostname = nil;
    NSInteger maskLen = 0;
    NSInteger port = 0;

    NSRange slash = [canonicalEntry rangeOfString:@"/"];
    NSString* hostPort = (slash.location == NSNotFound)
        ? canonicalEntry
        : [canonicalEntry substringToIndex:slash.location];

    if (slash.location != NSNotFound) {
        NSString* maskPort = [canonicalEntry substringFromIndex:NSMaxRange(slash)];
        NSArray<NSString*>* maskPortParts = [maskPort componentsSeparatedByString:@":"];
        maskLen = [maskPortParts[0] integerValue];
        if (maskPortParts.count == 2) port = [maskPortParts[1] integerValue];
    }

    if ([hostPort hasPrefix:@"["]) {
        NSRange closingBracket = [hostPort rangeOfString:@"]"];
        hostname = [hostPort substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
        NSString* suffix = [hostPort substringFromIndex:NSMaxRange(closingBracket)];
        if (suffix.length > 1) port = [[suffix substringFromIndex:1] integerValue];
    } else {
        NSArray<NSString*>* colonParts = [hostPort componentsSeparatedByString:@":"];
        if (colonParts.count == 2) {
            hostname = colonParts[0];
            port = [colonParts[1] integerValue];
        } else {
            // Zero or multiple colons means a host without a port; the multiple
            // colon case is an unbracketed IPv6 address.
            hostname = hostPort;
        }
    }

    return [SCBlockEntry entryWithHostname: hostname port: port maskLen: maskLen];
}

- (NSString*)description {
    if ([self isAppEntry]) {
        return [NSString stringWithFormat: @"[Entry: appBundleID = %@]", self.appBundleID];
    }
    return [NSString stringWithFormat: @"[Entry: hostname = %@, port = %ld, maskLen = %ld]", self.hostname, (long)self.port, (long)self.maskLen];
}

- (BOOL)isAppEntry {
    return self.appBundleID != nil && self.appBundleID.length > 0;
}

// method implementations of isEqual, isEqualToEntry, and hash are based on this answer from StackOverflow: https://stackoverflow.com/q/254281

- (BOOL)isEqual:(id)other {
    if (other == self)
        return YES;
    if (!other || ![other isKindOfClass: [self class]])
        return NO;
    return [self isEqualToEntry: other];
}

- (BOOL)isEqualToEntry:(SCBlockEntry*)otherEntry {
    if (otherEntry == nil) return NO;
    if (self == otherEntry) return YES;

    // Handle app entries
    if ([self isAppEntry] || [otherEntry isAppEntry]) {
        // Both must be app entries with matching bundle IDs
        if (![self isAppEntry] || ![otherEntry isAppEntry]) return NO;
        return [self.appBundleID isEqualToString:otherEntry.appBundleID];
    }

    // Handle network entries (existing logic)
    if ([self.hostname isEqualToString: otherEntry.hostname] && self.port == otherEntry.port && self.maskLen == otherEntry.maskLen) {
        return YES;
    } else {
        return NO;
    }
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = 1;

    // Hash app entries differently
    if ([self isAppEntry]) {
        result = prime * result + [self.appBundleID hash];
        return result;
    }

    // Hash network entries (existing logic)
    if (self.hostname == nil) {
        result = prime * result;
    } else {
        result = prime * result + [self.hostname hash];
    }

    result = prime * result + (NSUInteger)self.port;
    result = prime * result + (NSUInteger)self.maskLen;

    return result;
}

@end

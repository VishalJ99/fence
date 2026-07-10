//
//  SCBlockBundle.m
//  SelfControl
//

#import "SCBlockBundle.h"
#import "SCMiscUtilities.h"

static NSMutableArray<NSString*> *SCCanonicalBundleEntries(id rawEntries) {
    if (![rawEntries isKindOfClass:[NSArray class]]) {
        return [NSMutableArray array];
    }

    NSMutableOrderedSet<NSString*> *canonicalEntries = [NSMutableOrderedSet orderedSet];
    for (id rawEntry in (NSArray*)rawEntries) {
        if (![rawEntry isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:rawEntry];
        if (canonicalEntry != nil) {
            [canonicalEntries addObject:canonicalEntry];
        } else {
            // Preserve an opaque legacy entry rather than silently loosening a
            // committed bundle during decode/save. New entries still go through
            // addEntry: and must canonicalize successfully.
            NSString *trimmed = [rawEntry stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length > 0 &&
                [trimmed rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
                [canonicalEntries addObject:trimmed];
            }
        }
    }
    return [canonicalEntries.array mutableCopy];
}

@implementation SCBlockBundle

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bundleID = [[NSUUID UUID] UUIDString];
        _name = @"New Bundle";
        _color = [SCBlockBundle colorBlue];
        _entries = [NSMutableArray array];
        _enabled = YES;
        _displayOrder = 0;
    }
    return self;
}

+ (instancetype)bundleWithName:(NSString *)name color:(NSColor *)color {
    SCBlockBundle *bundle = [[SCBlockBundle alloc] init];
    bundle.name = name;
    bundle.color = color;
    return bundle;
}

+ (nullable instancetype)bundleFromDictionary:(NSDictionary *)dict {
    if (!dict[@"bundleID"] || !dict[@"name"]) {
        return nil;
    }

    SCBlockBundle *bundle = [[SCBlockBundle alloc] init];
    bundle->_bundleID = dict[@"bundleID"];
    bundle.name = dict[@"name"];
    bundle.enabled = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
    bundle.displayOrder = dict[@"displayOrder"] ? [dict[@"displayOrder"] integerValue] : 0;

    // Parse color
    if (dict[@"colorHex"]) {
        bundle.color = [bundle colorFromHex:dict[@"colorHex"]];
    } else {
        bundle.color = [SCBlockBundle colorBlue];
    }

    // Parse entries
    bundle.entries = SCCanonicalBundleEntries(dict[@"entries"]);

    return bundle;
}

- (NSDictionary *)toDictionary {
    return @{
        @"bundleID": self.bundleID ?: @"",
        @"name": self.name ?: @"",
        @"colorHex": [self hexFromColor:self.color] ?: @"007AFF",
        @"entries": SCCanonicalBundleEntries(self.entries),
        @"enabled": @(self.enabled),
        @"displayOrder": @(self.displayOrder)
    };
}

#pragma mark - Color Helpers

- (NSString *)hexFromColor:(NSColor *)color {
    if (!color) return @"007AFF";

    NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgbColor) return @"007AFF";

    CGFloat r, g, b, a;
    [rgbColor getRed:&r green:&g blue:&b alpha:&a];

    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)(r * 255), (int)(g * 255), (int)(b * 255)];
}

- (NSColor *)colorFromHex:(NSString *)hex {
    if (hex.length != 6) return [SCBlockBundle colorBlue];

    unsigned int r, g, b;
    [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(0, 2)]] scanHexInt:&r];
    [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(2, 2)]] scanHexInt:&g];
    [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(4, 2)]] scanHexInt:&b];

    return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}

#pragma mark - Entry Management

- (void)addEntry:(NSString *)entry {
    NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:entry];
    if (canonicalEntry && ![self.entries containsObject:canonicalEntry]) {
        [self.entries addObject:canonicalEntry];
    }
}

- (void)removeEntry:(NSString *)entry {
    NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:entry];
    if (canonicalEntry != nil) {
        [self.entries removeObject:canonicalEntry];
    }
}

- (BOOL)containsEntry:(NSString *)entry {
    NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:entry];
    return canonicalEntry != nil && [self.entries containsObject:canonicalEntry];
}

- (NSInteger)appEntryCount {
    return [[self appEntries] count];
}

- (NSInteger)websiteEntryCount {
    return [[self websiteEntries] count];
}

- (NSArray<NSString *> *)appEntries {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *entry, NSDictionary *bindings) {
        return [entry hasPrefix:@"app:"];
    }];
    return [self.entries filteredArrayUsingPredicate:predicate];
}

- (NSArray<NSString *> *)websiteEntries {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *entry, NSDictionary *bindings) {
        return ![entry hasPrefix:@"app:"];
    }];
    return [self.entries filteredArrayUsingPredicate:predicate];
}

- (BOOL)isValid {
    return self.name.length > 0;
}

#pragma mark - Preset Bundles

+ (instancetype)distractingSitesBundle {
    SCBlockBundle *bundle = [self bundleWithName:@"Distracting Sites" color:[self colorRed]];
    [bundle addEntry:@"facebook.com"];
    [bundle addEntry:@"twitter.com"];
    [bundle addEntry:@"x.com"];
    [bundle addEntry:@"instagram.com"];
    [bundle addEntry:@"tiktok.com"];
    [bundle addEntry:@"reddit.com"];
    [bundle addEntry:@"youtube.com"];
    [bundle addEntry:@"netflix.com"];
    return bundle;
}

+ (instancetype)workAppsBundle {
    SCBlockBundle *bundle = [self bundleWithName:@"Work Apps" color:[self colorGreen]];
    // Empty by default - user adds their work apps
    return bundle;
}

+ (instancetype)gamingBundle {
    SCBlockBundle *bundle = [self bundleWithName:@"Gaming" color:[self colorPurple]];
    [bundle addEntry:@"twitch.tv"];
    [bundle addEntry:@"steampowered.com"];
    [bundle addEntry:@"discord.com"];
    return bundle;
}

#pragma mark - Color Presets

+ (NSColor *)colorRed {
    return [NSColor colorWithSRGBRed:255/255.0 green:59/255.0 blue:48/255.0 alpha:1.0];
}

+ (NSColor *)colorOrange {
    return [NSColor colorWithSRGBRed:255/255.0 green:149/255.0 blue:0/255.0 alpha:1.0];
}

+ (NSColor *)colorYellow {
    return [NSColor colorWithSRGBRed:255/255.0 green:204/255.0 blue:0/255.0 alpha:1.0];
}

+ (NSColor *)colorGreen {
    return [NSColor colorWithSRGBRed:52/255.0 green:199/255.0 blue:89/255.0 alpha:1.0];
}

+ (NSColor *)colorBlue {
    return [NSColor colorWithSRGBRed:0/255.0 green:122/255.0 blue:255/255.0 alpha:1.0];
}

+ (NSColor *)colorPurple {
    return [NSColor colorWithSRGBRed:175/255.0 green:82/255.0 blue:222/255.0 alpha:1.0];
}

+ (NSArray<NSColor *> *)allPresetColors {
    return @[
        [self colorRed],
        [self colorOrange],
        [self colorYellow],
        [self colorGreen],
        [self colorBlue],
        [self colorPurple]
    ];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    SCBlockBundle *copy = [[SCBlockBundle allocWithZone:zone] init];
    copy->_bundleID = [self.bundleID copy];
    copy.name = [self.name copy];
    copy.color = [self.color copy];
    copy.entries = [self.entries mutableCopy];
    copy.enabled = self.enabled;
    copy.displayOrder = self.displayOrder;
    return copy;
}

#pragma mark - NSSecureCoding

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.bundleID forKey:@"bundleID"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:[self hexFromColor:self.color] forKey:@"colorHex"];
    [coder encodeObject:SCCanonicalBundleEntries(self.entries) forKey:@"entries"];
    [coder encodeBool:self.enabled forKey:@"enabled"];
    [coder encodeInteger:self.displayOrder forKey:@"displayOrder"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _bundleID = [coder decodeObjectOfClass:[NSString class] forKey:@"bundleID"];
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];

        NSString *colorHex = [coder decodeObjectOfClass:[NSString class] forKey:@"colorHex"];
        _color = [self colorFromHex:colorHex];

        NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSString class], nil];
        _entries = SCCanonicalBundleEntries([coder decodeObjectOfClasses:allowedClasses forKey:@"entries"]);

        _enabled = [coder decodeBoolForKey:@"enabled"];
        _displayOrder = [coder decodeIntegerForKey:@"displayOrder"];
    }
    return self;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[SCBlockBundle class]]) return NO;

    SCBlockBundle *other = (SCBlockBundle *)object;
    return [self.bundleID isEqualToString:other.bundleID];
}

- (NSUInteger)hash {
    return [self.bundleID hash];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SCBlockBundle: %@ (%ld entries)>",
            self.name, (long)self.entries.count];
}

@end

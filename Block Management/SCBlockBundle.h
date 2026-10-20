//
//  SCBlockBundle.h
//  SelfControl
//
//  Represents a bundle/group of blocked items (apps and websites)
//  with a name, color, and list of entries.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCBundlePolicy) {
    SCBundlePolicyAllow = 0,
    SCBundlePolicyBlock = 1,
};

@interface SCBlockBundle : NSObject <NSCopying, NSSecureCoding>

/// Unique identifier for this bundle (UUID string)
@property (nonatomic, copy, readonly) NSString *bundleID;

/// User-friendly name (e.g., "Work Apps", "Social Media", "Gaming")
@property (nonatomic, copy) NSString *name;

/// Color for visual identification in the UI
@property (nonatomic, strong) NSColor *color;

/// List of blocked entries: domains ("facebook.com") and apps ("app:com.bundle.id")
@property (nonatomic, strong) NSMutableArray<NSString *> *entries;

/// Allow blocks outside timetable windows; Block blocks inside them.
@property (nonatomic) SCBundlePolicy policy;

/// Whether this bundle is enabled (if NO, schedule is ignored)
@property (nonatomic, assign) BOOL enabled;

/// Order index for UI display
@property (nonatomic, assign) NSInteger displayOrder;

/// Creates a new bundle with a generated UUID
+ (instancetype)bundleWithName:(NSString *)name color:(NSColor *)color;

/// Creates a bundle from a dictionary (for persistence)
+ (nullable instancetype)bundleFromDictionary:(NSDictionary *)dict;

/// Converts to dictionary for persistence
- (NSDictionary *)toDictionary;

/// Adds an entry to this bundle
- (void)addEntry:(NSString *)entry;

/// Removes an entry from this bundle
- (void)removeEntry:(NSString *)entry;

/// Checks if bundle contains a specific entry
- (BOOL)containsEntry:(NSString *)entry;

/// Returns count of app entries
- (NSInteger)appEntryCount;

/// Returns count of website entries
- (NSInteger)websiteEntryCount;

/// Returns all app entries (those starting with "app:")
- (NSArray<NSString *> *)appEntries;

/// Returns all website entries (those NOT starting with "app:")
- (NSArray<NSString *> *)websiteEntries;

/// Validates the bundle (has name, at least one entry)
- (BOOL)isValid;

#pragma mark - Preset Bundles

/// Creates a "Distracting Sites" bundle with common social media
+ (instancetype)distractingSitesBundle;

/// Creates a "Work Apps" bundle (empty, user fills)
+ (instancetype)workAppsBundle;

/// Creates a "Gaming" bundle (empty, user fills)
+ (instancetype)gamingBundle;

#pragma mark - Color Presets

+ (NSColor *)colorRed;
+ (NSColor *)colorOrange;
+ (NSColor *)colorYellow;
+ (NSColor *)colorGreen;
+ (NSColor *)colorBlue;
+ (NSColor *)colorPurple;
+ (NSArray<NSColor *> *)allPresetColors;

@end

NS_ASSUME_NONNULL_END

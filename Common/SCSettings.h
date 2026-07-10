//
//  SCLockFileUtilities.h
//  SelfControl
//
//  Created by Charles Stigler on 20/10/2018.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted in-process when the secured settings file cannot be loaded safely.
/// The notification contains only fields accepted by the
/// `daemon.settings_load_failed` telemetry schema; it never includes settings
/// values, paths, or blocklist entries.
FOUNDATION_EXPORT NSString * const SCSettingsLoadFailedNotification;

/// Returned when a secured settings snapshot could not be loaded safely and an
/// ordinary caller attempts to mutate or persist the in-memory safe defaults.
/// Only the internal first-run missing-file bootstrap may bypass this error.
FOUNDATION_EXPORT NSInteger const SCSettingsStateUnavailableErrorCode;

@interface SCSettings : NSObject

@property (readonly) uid_t userId;
@property (readonly) NSDictionary* dictionaryRepresentation;
@property (nonatomic, getter=isReadOnly) BOOL readOnly;
/// YES only when enforcement may safely trust the in-memory state. Initial
/// corrupt/unreadable disk state stays unavailable; only a later valid reload
/// or the internal first-run missing-file bootstrap restores availability.
@property (nonatomic, readonly) BOOL settingsStateAvailableForEnforcement;

@property (class, nonatomic, readonly) NSString* settingsFileName;
@property (class, nonatomic, readonly) NSString* securedSettingsFilePath;

+ (instancetype)sharedSettings;

#if defined(TESTING)
/// Unit-test seam for fail-safe loader/reload behavior. Production code always
/// uses `securedSettingsFilePath`.
- (instancetype)initWithSettingsFilePathForTesting:(NSString *)settingsFilePath;
#endif

/// Pure schema check used by the loader and unit tests. Missing optional keys
/// are accepted for backward compatibility; present enforcement keys must
/// have their expected property-list types.
+ (BOOL)settingsDictionaryHasValidSchema:(nullable id)settingsDictionary;

- (void)reloadSettings;
- (void)forceReloadFromDisk;  // Ignores version numbers, always reloads from disk
- (void)writeSettingsWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock;
- (void)writeSettings;
- (void)synchronizeSettingsWithCompletion:(nullable void(^)(NSError* _Nullable))completionBlock;
- (void)synchronizeSettings;
- (NSError*)syncSettingsAndWait:(NSInteger)timeoutSecs;

- (void)setValue:(id)value forKey:(NSString*)key stopPropagation:(BOOL)stopPropagation;
- (void)setValue:(nullable id)value forKey:(NSString*)key;

- (id)valueForKey:(NSString*)key;
- (BOOL)boolForKey:(NSString*)key;

- (void)updateSentryContext;

- (void)resetAllSettingsToDefaults;

@end

NS_ASSUME_NONNULL_END

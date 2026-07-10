//
//  SCLogger.h
//  SelfControl
//
//  Log export utility for user support
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCLogger : NSObject

// Call on app startup to create ~/.fence/logs/ directory
+ (void)ensureDirectoriesExist;

// Export logs from the last 24 hours for Fence/selfcontrold processes
// Saves to ~/.fence/logs/fence-logs-{timestamp}.txt, reveals in Finder, opens email
+ (void)exportLogsForSupport;

// Removes user-entered block entries, bundle identifiers, credentials, tokens,
// and user-specific paths from unified-log text before it can be exported.
+ (NSString*)sanitizedSupportLogContent:(NSString*)content;

@end

NS_ASSUME_NONNULL_END

//
//  SCSentry.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/15/21.
//

#import "SCSentry.h"
#import "SCSettings.h"

// Only include Sentry if available and not testing
#if !defined(TESTING) && __has_include(<Sentry/Sentry.h>)
#define SENTRY_ENABLED 1
#import <Sentry/Sentry.h>
#import <Sentry/Sentry-Swift.h>
#else
#define SENTRY_ENABLED 0
#endif

@implementation SCSentry

//org.eyebeam.SelfControl
+ (void)startSentry:(NSString*)componentId {
#if SENTRY_ENABLED
    [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
        options.dsn = @"https://58fbe7145368418998067f88896007b2@o504820.ingest.sentry.io/5592195";
        options.releaseName = [NSString stringWithFormat: @"%@%@", componentId, SELFCONTROL_VERSION_STRING];
        options.enableAutoSessionTracking = NO;
        options.enableLogs = YES;
        options.environment = @"dev";

        // make sure no data leaves the device if error reporting isn't enabled
        options.beforeSend = ^SentryEvent * _Nullable(SentryEvent * _Nonnull event) {
            if ([SCSentry errorReportingEnabled]) {
                return event;
            } else {
                return NULL;
            }
        };
        options.beforeSendLog = ^SentryLog * _Nullable(SentryLog * _Nonnull log) {
            if ([SCSentry errorReportingEnabled]) {
                return log;
            } else {
                return NULL;
            }
        };
    }];
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setTagValue: [[NSLocale currentLocale] localeIdentifier] forKey: @"localeId"];
    }];
#endif
}

+ (BOOL)errorReportingEnabled {
#ifdef TESTING
    // don't report to Sentry while unit-testing!
    if ([[NSUserDefaults standardUserDefaults] boolForKey: @"isTest"]) {
        return YES;
    }
#endif
    if (geteuid() != 0) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        return [defaults boolForKey: @"EnableErrorReporting"];
    } else {
        // since we're root, we've gotta see what's in SCSettings (where the user's defaults will have been copied)
        return [[SCSettings sharedSettings] boolForKey: @"EnableErrorReporting"];
    }
}

// returns YES if we turned on error reporting based on the prompt return
+ (BOOL)showErrorReportingPromptIfNeeded {
    // no need to show the prompt if we're root (aka in the CLI/daemon), or already enabled error reporting, or if the user already dismissed it
    if (!geteuid()) return NO;
    if ([SCSentry errorReportingEnabled]) return NO;
    
    // if they've already dismissed this once, don't show it again
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey: @"ErrorReportingPromptDismissed"]) {
        return NO;
    }
    
    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [SCSentry showErrorReportingPromptIfNeeded];
        });
        return retVal;
    }
    
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText: NSLocalizedString(@"Enable automatic error reporting", "Title of error reporting prompt")];
    [alert setInformativeText:NSLocalizedString(@"Fence can automatically send bug reports to help us improve the software. All data is anonymized, your blocklist is never shared, and no identifying information is sent.", @"Message explaining error reporting")];
    [alert addButtonWithTitle: NSLocalizedString(@"Enable Error Reporting", @"Button to enable error reporting")];
    [alert addButtonWithTitle: NSLocalizedString(@"Don't Send Reports", "Button to decline error reporting")];
    
    NSModalResponse modalResponse = [alert runModal];
    if (modalResponse == NSAlertFirstButtonReturn) {
        [defaults setBool: YES forKey: @"EnableErrorReporting"];
        [defaults setBool: YES forKey: @"ErrorReportingPromptDismissed"];
        return YES;
    } else if (modalResponse == NSAlertSecondButtonReturn) {
        [defaults setBool: NO forKey: @"EnableErrorReporting"];
        [defaults setBool: YES forKey: @"ErrorReportingPromptDismissed"];
    } // if the modal exited some other way, do nothing
    
    return NO;
}

+ (void)updateDefaultsContext {
    // if we're root, we can't get defaults properly, so forget it
    if (!geteuid()) {
        return;
    }

    NSMutableDictionary* defaultsDict = [[[NSUserDefaults standardUserDefaults] persistentDomainForName: @"org.eyebeam.SelfControl"] mutableCopy];

    // delete blocklist (because PII) and update check time
    // (because unnecessary, and Sentry dies if you feed it dates)
    // but store the blocklist length as a useful piece of debug info
    id blocklist = defaultsDict[@"Blocklist"];
    NSUInteger blocklistLength = (blocklist == nil) ? 0 : ((NSArray*)blocklist).count;
    [defaultsDict setObject: @(blocklistLength) forKey: @"BlocklistLength"];
    [defaultsDict removeObjectForKey: @"Blocklist"];
    [defaultsDict removeObjectForKey: @"SULastCheckTime"];
    [defaultsDict removeObjectForKey: @"SULastProfileSubmissionDate"];

#if SENTRY_ENABLED
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setContextValue: defaultsDict forKey: @"NSUserDefaults"];
    }];
#endif
}

+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category {
#if SENTRY_ENABLED
    SentryBreadcrumb* crumb = [[SentryBreadcrumb alloc] init];
    crumb.level = kSentryLevelInfo;
    crumb.category = category;
    crumb.message = message;
    [SentrySDK addBreadcrumb: crumb];
#endif
}

+ (NSDictionary<NSString*, id>*)sanitizedLogAttributes:(NSDictionary<NSString*, id>*)attributes category:(NSString*)category {
    NSMutableDictionary* sanitizedAttributes = [NSMutableDictionary dictionaryWithObject:category forKey:@"category"];
    NSArray<NSString*>* sensitiveKeyFragments = @[@"blocklist", @"host", @"domain", @"url", @"path"];

    [attributes enumerateKeysAndObjectsUsingBlock:^(NSString* key, id value, BOOL* stop) {
        if (![key isKindOfClass:[NSString class]] || value == nil || value == [NSNull null]) {
            return;
        }

        NSString* lowercaseKey = key.lowercaseString;
        for (NSString* fragment in sensitiveKeyFragments) {
            if ([lowercaseKey containsString:fragment] && ![lowercaseKey containsString:@"count"] && ![lowercaseKey containsString:@"length"]) {
                return;
            }
        }

        if ([value isKindOfClass:[NSString class]]) {
            NSString* stringValue = (NSString*)value;
            sanitizedAttributes[key] = stringValue.length > 256 ? [stringValue substringToIndex:256] : stringValue;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            sanitizedAttributes[key] = value;
        } else {
            sanitizedAttributes[key] = [[value description] substringToIndex:MIN([[value description] length], 256)];
        }
    }];

    return sanitizedAttributes;
}

+ (void)logMessage:(NSString*)message level:(SCSentryLogLevel)level category:(NSString*)category attributes:(nullable NSDictionary<NSString*, id>*)attributes {
    if (![SCSentry errorReportingEnabled]) {
        return;
    }

#if SENTRY_ENABLED
    NSDictionary* sanitizedAttributes = [SCSentry sanitizedLogAttributes:attributes ?: @{} category:category ?: @"app"];
    SentryLogger* logger = [SentrySDK logger];
    switch (level) {
        case SCSentryLogLevelDebug:
            [logger debug:message attributes:sanitizedAttributes];
            break;
        case SCSentryLogLevelWarning:
            [logger warn:message attributes:sanitizedAttributes];
            break;
        case SCSentryLogLevelError:
            [logger error:message attributes:sanitizedAttributes];
            break;
        case SCSentryLogLevelInfo:
        default:
            [logger info:message attributes:sanitizedAttributes];
            break;
    }
#endif
}

+ (void)logMessage:(NSString*)message category:(NSString*)category {
    [SCSentry logMessage:message level:SCSentryLogLevelInfo category:category attributes:nil];
}

+ (void)captureError:(NSError*)error {
    if (![SCSentry errorReportingEnabled]) {
        // if we're root (CLI/daemon), we can't show prompts
        if (!geteuid()) {
            return;
        }
        
        // prompt 'em to turn on error reports now if we haven't already! if they do we can continue
        BOOL enabledReports = [SCSentry showErrorReportingPromptIfNeeded];
        if (!enabledReports) {
            return;
        }
    }

    NSLog(@"Reporting error %@ to Sentry...", error);
    [[SCSettings sharedSettings] updateSentryContext];
    [SCSentry updateDefaultsContext];
#if SENTRY_ENABLED
    [SentrySDK captureError: error];
#endif
}

+ (void)captureMessage:(NSString*)message withScopeBlock:(nullable void (^)(SentryScope * _Nonnull))block {
    if (![SCSentry errorReportingEnabled]) {
        // if we're root (CLI/daemon), we can't show prompts
        if (!geteuid()) {
            return;
        }
        
        // prompt 'em to turn on error reports now if we haven't already! if they do we can continue
        BOOL enabledReports = [SCSentry showErrorReportingPromptIfNeeded];
        if (!enabledReports) {
            return;
        }
    }

    NSLog(@"Reporting message %@ to Sentry...", message);
    [[SCSettings sharedSettings] updateSentryContext];
    [SCSentry updateDefaultsContext];

#if SENTRY_ENABLED
    if (block != nil) {
        [SentrySDK captureMessage: message withScopeBlock: block];
    } else {
        [SentrySDK captureMessage: message];
    }
#endif
}

+ (void)captureMessage:(NSString*)message {
    [SCSentry captureMessage: message withScopeBlock: nil];
}

@end

//
//  SCSentry.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/15/21.
//

#import <Foundation/Foundation.h>

@class SentryScope;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCSentryLogLevel) {
    SCSentryLogLevelDebug,
    SCSentryLogLevelInfo,
    SCSentryLogLevelWarning,
    SCSentryLogLevelError,
};

@interface SCSentry : NSObject

+ (void)startSentry:(NSString*)componentId;
+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category;
+ (void)logMessage:(NSString*)message level:(SCSentryLogLevel)level category:(NSString*)category attributes:(nullable NSDictionary<NSString*, id>*)attributes;
+ (void)logMessage:(NSString*)message category:(NSString*)category;
+ (void)captureError:(NSError*)error;
+ (void)captureMessage:(NSString*)message withScopeBlock:(nullable void (^)(SentryScope * _Nonnull))block;
+ (void)captureMessage:(NSString*)message;
+ (BOOL)showErrorReportingPromptIfNeeded;

@end

NS_ASSUME_NONNULL_END

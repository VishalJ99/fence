//
//  SCLogger.h
//  SelfControl
//
//  Privacy-safe, Sentry-only diagnostic reporting for user support.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const SCDiagnosticReportErrorDomain;

typedef NS_ENUM(NSInteger, SCDiagnosticReportErrorCode) {
    SCDiagnosticReportErrorReportingDisabled = 1,
    SCDiagnosticReportErrorCaptureFailed = 2,
};

@interface SCLogger : NSObject

/// Captures a fresh allowlisted app/UI/daemon snapshot in Sentry. uiSnapshot
/// must contain counts and booleans only; unknown values are discarded before
/// the typed telemetry boundary. Completion runs on the main thread after the
/// SDK flush attempt and returns a support reference such as FENCE-1234ABCD.
+ (void)sendDiagnosticReportWithUISnapshot:(nullable NSDictionary<NSString *, NSNumber *> *)uiSnapshot
                                completion:(void (^)(NSString * _Nullable reference,
                                                     NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

//
//  SCAppXPC.m
//  SelfControl
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCXPCClient.h"
#import "SCDaemonProtocol.h"
#import <ServiceManagement/ServiceManagement.h>
#import <Security/AuthorizationTags.h>
#import "SCXPCAuthorization.h"
#import "SCErr.h"

static NSString * const SCXPCDaemonCompatibilityErrorDomain = @"org.eyebeam.Fence.DaemonCompatibility.Handshake";

typedef NS_ENUM(NSInteger, SCXPCDaemonCompatibilityErrorCode) {
    SCXPCDaemonCompatibilityErrorConnection = 1,
    SCXPCDaemonCompatibilityErrorHandshake = 2,
    SCXPCDaemonCompatibilityErrorTimeout = 3,
};

static const NSTimeInterval SCXPCDaemonCompatibilityTimeout = 5.0;

static NSInteger SCXPCSafeTelemetryErrorCode(NSInteger errorCode) {
    return MIN(MAX(errorCode, -1000000000), 1000000000);
}

@interface SCXPCClient () {
    AuthorizationRef    _authRef;
}

@property (atomic, strong, readwrite) NSXPCConnection* daemonConnection;
@property (atomic, copy, readwrite) NSData* authorization;
@property (atomic, assign, readwrite) BOOL connectionIsValid;

+ (BOOL)isAuthorizationFailureError:(NSError*)error;
+ (nullable NSDictionary<NSString *, id>*)authorizationRejectionTelemetryFieldsForCommand:(NSString*)command
                                                                                       error:(NSError*)error;
+ (BOOL)shouldRecordAuthorizationRejectionForCommand:(NSString*)command
                                                error:(NSError*)error
                                     recordedCommands:(NSMutableSet<NSString*>*)recordedCommands;
+ (BOOL)recordAuthorizationRejectionForCommand:(NSString*)command error:(NSError*)error;

@end

@implementation SCXPCClient

+ (BOOL)isAuthorizationFailureError:(NSError*)error {
    return [error isKindOfClass:[NSError class]] &&
           [error.domain isEqualToString:NSOSStatusErrorDomain];
}

+ (nullable NSDictionary<NSString *, id>*)authorizationRejectionTelemetryFieldsForCommand:(NSString*)command
                                                                                       error:(NSError*)error {
    static NSSet<NSString*> *allowedCommands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCommands = [NSSet setWithArray:@[
            @"start", @"update", @"register_schedule", @"replace_schedule", @"unregister_schedule",
            @"clear_schedules", @"install", @"repair"
        ]];
    });

    if (![allowedCommands containsObject:command] || ![self isAuthorizationFailureError:error] ||
        [SCMiscUtilities errorIsAuthCanceled:error]) {
        return nil;
    }
    return [SCSentry sanitizedTelemetryFields:@{
        @"command": command,
        @"user_cancelled": @NO,
        @"error_code": @(SCXPCSafeTelemetryErrorCode(error.code)),
    } forEventName:@"xpc.auth_rejected"];
}

+ (BOOL)shouldRecordAuthorizationRejectionForCommand:(NSString*)command
                                                error:(NSError*)error
                                     recordedCommands:(NSMutableSet<NSString*>*)recordedCommands {
    if (![recordedCommands isKindOfClass:[NSMutableSet class]] ||
        [self authorizationRejectionTelemetryFieldsForCommand:command error:error] == nil) {
        return NO;
    }
    @synchronized (recordedCommands) {
        if ([recordedCommands containsObject:command]) return NO;
        [recordedCommands addObject:command];
        return YES;
    }
}

+ (BOOL)recordAuthorizationRejectionForCommand:(NSString*)command error:(NSError*)error {
    // Return YES for cancellation too so callers do not fall back to a noisy
    // generic error event. A user dismissing an authorization prompt is not an
    // incident; only non-cancelled Authorization Services failures are emitted.
    if (![self isAuthorizationFailureError:error]) return NO;
    if ([SCMiscUtilities errorIsAuthCanceled:error]) return YES;
    if (![SCSentry errorReportingEnabled]) return YES;

    static NSMutableSet<NSString*> *recordedCommands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ recordedCommands = [NSMutableSet set]; });
    if (![self shouldRecordAuthorizationRejectionForCommand:command
                                                      error:error
                                           recordedCommands:recordedCommands]) {
        return YES;
    }

    NSDictionary *fields = [self authorizationRejectionTelemetryFieldsForCommand:command error:error];
    NSString *eventID = fields == nil ? nil : [SCSentry captureTelemetryEvent:@"xpc.auth_rejected"
                                                                         level:SCTelemetryEventLevelError
                                                                        fields:fields];
    if (eventID == nil) {
        // No consent/DSN means no historical report. Let a later real failure
        // in this process try again if telemetry becomes available.
        @synchronized (recordedCommands) {
            [recordedCommands removeObject:command];
        }
    }
    return YES;
}

+ (NSString*)daemonHandshakeFailureKindForError:(NSError*)error {
    if (![error.domain isEqualToString:SCXPCDaemonCompatibilityErrorDomain]) return @"unknown";
    switch (error.code) {
        case SCXPCDaemonCompatibilityErrorConnection: return @"connection";
        case SCXPCDaemonCompatibilityErrorHandshake: return @"handshake";
        case SCXPCDaemonCompatibilityErrorTimeout: return @"timeout";
        default: return @"unknown";
    }
}

+ (nullable NSDictionary<NSString *, id>*)daemonUnreachableReinstallTelemetryFieldsForOutcome:(NSString*)outcome
                                                                          initialHandshakeError:(NSError*)initialHandshakeError
                                                                                     finalError:(nullable NSError*)finalError
                                                                  installedHelperPresentBefore:(BOOL)installedHelperPresentBefore
                                                                   installedHelperPresentAfter:(BOOL)installedHelperPresentAfter
                                                                          bundledHelperPresent:(BOOL)bundledHelperPresent
                                                                            reinstallSucceeded:(BOOL)reinstallSucceeded
                                                                             reconnectAttempted:(BOOL)reconnectAttempted
                                                                  postRepairHandshakeSucceeded:(BOOL)postRepairHandshakeSucceeded
                                                                          postRepairCompatible:(BOOL)postRepairCompatible {
    if (![initialHandshakeError isKindOfClass:[NSError class]]) return nil;

    BOOL stateIsConsistent =
        ([outcome isEqualToString:@"install_failed"] && !reinstallSucceeded && !reconnectAttempted &&
         !postRepairHandshakeSucceeded && !postRepairCompatible && finalError != nil) ||
        ([outcome isEqualToString:@"recovered"] && reinstallSucceeded && reconnectAttempted &&
         postRepairHandshakeSucceeded && postRepairCompatible && finalError == nil) ||
        ([outcome isEqualToString:@"post_repair_unreachable"] && reinstallSucceeded && reconnectAttempted &&
         !postRepairHandshakeSucceeded && !postRepairCompatible && finalError != nil) ||
        ([outcome isEqualToString:@"post_repair_incompatible"] && reinstallSucceeded && reconnectAttempted &&
         postRepairHandshakeSucceeded && !postRepairCompatible && finalError == nil);
    if (!stateIsConsistent) return nil;

    NSString *finalFailure = @"none";
    if ([outcome isEqualToString:@"post_repair_incompatible"]) {
        finalFailure = @"incompatible";
    } else if (finalError != nil) {
        if ([finalError.domain isEqualToString:SCXPCDaemonCompatibilityErrorDomain]) {
            finalFailure = [self daemonHandshakeFailureKindForError:finalError];
        } else if ([self isAuthorizationFailureError:finalError] ||
                   ([finalError.domain isEqualToString:kSelfControlErrorDomain] && finalError.code == 501)) {
            finalFailure = @"authorization";
        } else if ([outcome isEqualToString:@"install_failed"]) {
            finalFailure = @"install";
        } else {
            finalFailure = @"unknown";
        }
    }

    NSDictionary *fields = @{
        @"outcome": outcome,
        @"initial_failure": [self daemonHandshakeFailureKindForError:initialHandshakeError],
        @"final_failure": finalFailure,
        @"installed_helper_present_before": @(installedHelperPresentBefore),
        @"installed_helper_present_after": @(installedHelperPresentAfter),
        @"bundled_helper_present": @(bundledHelperPresent),
        @"reinstall_attempted": @YES,
        @"reinstall_succeeded": @(reinstallSucceeded),
        @"reconnect_attempted": @(reconnectAttempted),
        @"post_repair_handshake_succeeded": @(postRepairHandshakeSucceeded),
        @"post_repair_compatible": @(postRepairCompatible),
        @"initial_error_code": @(SCXPCSafeTelemetryErrorCode(initialHandshakeError.code)),
        @"final_error_code": @(SCXPCSafeTelemetryErrorCode(finalError.code)),
    };
    return [SCSentry sanitizedTelemetryFields:fields forEventName:@"daemon.unreachable_reinstall"];
}

- (void)setupAuthorization {
    // this is mostly copied from Apple's Even Better Authorization Sample

    // Create our connection to the authorization system.
    //
    // If we can't create an authorization reference then the app is not going to be able
    // to do anything requiring authorization.  Generally this only happens when you launch
    // the app in some wacky, and typically unsupported, way.
    
    // if we've already got an authorization session, no need to make another
    if (self.authorization) {
        return;
    }
    
    AuthorizationRef authRef;
    OSStatus errCode = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, 0, &authRef);
    if (errCode) {
        NSError* err = [NSError errorWithDomain: NSOSStatusErrorDomain code: errCode userInfo: nil];
        NSLog(@"Failed to set up initial authorization with error %@", err);
        [SCXPCClient recordAuthorizationRejectionForCommand:@"repair" error:err];
    } else {
        [self updateStoredAuthorization: authRef];
    }
}

- (void)updateStoredAuthorization:(AuthorizationRef)authRef {
    self->_authRef = authRef;
    if (!self->_authRef) {
        self.authorization = nil;
        return;
    }
    
    AuthorizationExternalForm extForm;
    OSStatus errCode = AuthorizationMakeExternalForm(self->_authRef, &extForm);
    if (errCode) {
        NSError* err = [NSError errorWithDomain: NSOSStatusErrorDomain code: errCode userInfo: nil];
        NSLog(@"Failed to update stored authorization with error %@", err);
        [SCXPCClient recordAuthorizationRejectionForCommand:@"repair" error:err];
    } else {
        self.authorization = [[NSData alloc] initWithBytes: &extForm length: sizeof(extForm)];
    }

    // If we successfully connected to Authorization Services, add definitions for our default
    // rights (unless they're already in the database).
    [SCXPCAuthorization setupAuthorizationRights: self->_authRef];
}

// Ensures that we're connected to our helper tool
// should only be called from the main thread
// Copied from Apple's EvenBetterAuthorizationSample
- (void)connectToHelperTool {
    assert([NSThread isMainThread]);

    [self setupAuthorization];

    // Check both nil AND validity - a non-nil connection can be invalidated
    if (self.daemonConnection == nil || !self.connectionIsValid) {
        // Force cleanup if we have an invalid connection
        if (self.daemonConnection != nil && !self.connectionIsValid) {
            self.daemonConnection = nil;
        }

        self.daemonConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.eyebeam.selfcontrold" options: NSXPCConnectionPrivileged];
        self.daemonConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SCDaemonProtocol)];
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-retain-cycles"
        // We can ignore the retain cycle warning because a) the retain taken by the
        // invalidation handler block is released by us setting it to nil when the block
        // actually runs, and b) the retain taken by the block passed to -addOperationWithBlock:
        // will be released when that operation completes and the operation itself is deallocated
        // (notably self does not have a reference to the NSBlockOperation).
        // note we need a local reference to the daemonConnection since there is a race condition where
        // we could reinstantiate a new connection before the handler fires, and we don't want to clear the new connection
        NSXPCConnection* connection = self.daemonConnection;
        connection.invalidationHandler = ^{
            // If the connection gets invalidated then, on the main thread, nil out our
            // reference to it.  This ensures that we attempt to rebuild it the next time around.
            connection.invalidationHandler = connection.interruptionHandler = nil;

            // Mark invalid FIRST - this ensures connectToHelperTool won't reuse this connection
            // even if daemonConnection hasn't been nil'd yet
            self.connectionIsValid = NO;

            if (connection == self.daemonConnection) {
                // dispatch_sync on main thread would deadlock, so be careful
                if ([NSThread isMainThread]) {
                    self.daemonConnection = nil;
                } else {
                    // running this synchronously ensures that the daemonConnection is nil'd out even if
                    // reinstantiate the connection immediately
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        self.daemonConnection = nil;
                    });
                }
            }
        };
        // our interruption handler is just our invalidation handler, except we retry afterward
        connection.interruptionHandler = ^{
            if (connection.invalidationHandler != nil) {
                connection.invalidationHandler();
            }

            // interruptions may have happened because the daemon crashed
            // so wait a second and try to reconnect
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self connectToHelperTool];
            });
        };

        #pragma clang diagnostic pop
        [self.daemonConnection resume];
        self.connectionIsValid = YES;
    }
}

- (BOOL)isConnected {
    return (self.daemonConnection != nil);
}

- (void)forceDisconnect {
    self.connectionIsValid = NO;
    if (self.daemonConnection) {
        [self.daemonConnection invalidate];
        self.daemonConnection = nil;
    }
}

- (void)installDaemon:(void(^)(NSError*))callback {
    // make sure authorization is set up (if we haven't connected yet)
    [self setupAuthorization];
    
    AuthorizationItem blessRight = {
        kSMRightBlessPrivilegedHelper, 0, NULL, 0
    };
    AuthorizationItem startBlockRight = {
        "org.eyebeam.SelfControl.startBlock", 0, NULL, 0
    };
    AuthorizationItem rightsArr[] = { blessRight, startBlockRight };

    AuthorizationRights authRights;
    authRights.count = 2;
    authRights.items = rightsArr;

    AuthorizationFlags myFlags = kAuthorizationFlagDefaults |
    kAuthorizationFlagExtendRights |
    kAuthorizationFlagInteractionAllowed;
    OSStatus status;
    
    status = AuthorizationCopyRights(
                                           self->_authRef,
                                           &authRights,
                                           kAuthorizationEmptyEnvironment,
                                           myFlags,
                                           NULL
                                       );

    if(status) {
        NSError *authorizationError = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        [SCXPCClient recordAuthorizationRejectionForCommand:@"install" error:authorizationError];
        // if it's just the user cancelling, make that obvious
        // to any listeners so they can ignore it appropriately
        if (status == AUTH_CANCELLED_STATUS) {
            callback([SCErr errorWithCode: 1]);
        } else {
            NSLog(@"ERROR: Failed to authorize installing selfcontrold with status %d.", status);

            NSError* err = [SCErr errorWithCode: 501];
            callback(err);
        }

        return;
    }
    
    CFErrorRef cfError;

    // in some cases, SMJobBless will fail if we don't first remove the currently running daemon
    // it's not clear why exactly or what the exact cause is, but I can reproduce consistently
    // by running a 100-site whitelist block, then immediately trying to start another block
    // I consistently get the error (CFErrorDomainLaunchd error 2)
    SILENCE_OSX10_10_DEPRECATION(
    SMJobRemove(kSMDomainSystemLaunchd, CFSTR("org.eyebeam.selfcontrold"), self->_authRef, YES, &cfError);
                                 );
    if (cfError) {
        NSLog(@"WARNING: Failed to remove existing selfcontrold daemon with error %@", cfError);
        cfError = NULL;
    }

    BOOL result = (BOOL)SMJobBless(
                                   kSMDomainSystemLaunchd,
                                   CFSTR("org.eyebeam.selfcontrold"),
                                   self->_authRef,
                                   &cfError);

    if(!result) {
        NSError* error = CFBridgingRelease(cfError);
        
        NSLog(@"WARNING: Authorized installation of selfcontrold returned failure status code %d and error %@", (int)status, error);

        BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"install" error:error];
        if ([SCMiscUtilities errorIsAuthCanceled:error]) {
            callback([SCErr errorWithCode:1]);
        } else {
            NSInteger wrappedCode = authorizationFailure ? 501 : 500;
            NSError* err = [SCErr errorWithCode:wrappedCode subDescription:error.localizedDescription];
            if (!authorizationFailure) [SCSentry captureError:err];
            callback(err);
        }
        return;
    } else {
        NSLog(@"Daemon installed successfully!");
        callback(nil);
    }
}

- (BOOL)authorizationRightsNeedRefresh {
    [self setupAuthorization];
    return [SCXPCAuthorization authorizationRightsNeedRefresh];
}

- (BOOL)refreshAuthorizationRights:(NSError **)error {
    return [self refreshAuthorizationRightsAllowingInteraction:NO error:error];
}

- (BOOL)refreshAuthorizationRightsAllowingInteraction:(BOOL)allowInteraction error:(NSError **)error {
    [self setupAuthorization];
    if (self->_authRef == NULL) {
        NSError *authorizationError = [NSError errorWithDomain:NSOSStatusErrorDomain code:paramErr userInfo:nil];
        [SCXPCClient recordAuthorizationRejectionForCommand:@"repair" error:authorizationError];
        if (error) {
            *error = authorizationError;
        }
        return NO;
    }

    #pragma unused(allowInteraction)

    NSError *refreshError = nil;
    BOOL refreshed = [SCXPCAuthorization refreshAuthorizationRights:self->_authRef error:&refreshError];
    if (!refreshed) {
        [SCXPCClient recordAuthorizationRejectionForCommand:@"repair" error:refreshError];
        if (error) *error = refreshError;
    }
    return refreshed;
}

- (BOOL)connectionIsActive {
    return (self.daemonConnection != nil);
}

- (void)refreshConnectionAndRun:(void(^)(void))callback {
    // Simplified: just force disconnect and call back immediately.
    // The next connectToHelperTool call will create a fresh connection.
    // This fixes the bug where calling invalidate on an already-invalidated
    // connection would do nothing, causing the callback to never fire.
    [self forceDisconnect];
    callback();
}

// Also copied from Apple's EvenBetterAuthorizationSample
// Connects to the helper tool and then executes the supplied command block on the
// main thread, passing it an error indicating if the connection was successful.
- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock {
    // Ensure that there's a helper tool connection in place.
    
    [self performSelectorOnMainThread: @selector(connectToHelperTool) withObject:nil waitUntilDone: YES];

    // Run the command block.  Note that we never error in this case because, if there is
    // an error connecting to the helper tool, it will be delivered to the error handler
    // passed to -remoteObjectProxyWithErrorHandler:.  However, I maintain the possibility
    // of an error here to allow for future expansion.

    commandBlock(nil);
}

- (void)getVersion:(void(^)(NSString* version, NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Failed to get daemon version with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(nil, connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Failed to get daemon version with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(nil, proxyError);
            }] getVersionWithReply:^(NSString * _Nonnull version) {
                reply(version, nil);
            }];
        }
    }];
}

- (void)getCompatibilityInfo:(void(^)(NSInteger protocolVersion,
                                      NSString* buildVersion,
                                      NSString* marketingVersion,
                                      NSArray<NSString*>* capabilities,
                                      NSError* error))reply {
    NSLock *completionLock = [NSLock new];
    __block BOOL completed = NO;
    BOOL (^finishOnce)(NSInteger, NSString*, NSString*, NSArray<NSString*>*, NSError*) =
    ^BOOL(NSInteger protocolVersion,
      NSString *buildVersion,
      NSString *marketingVersion,
      NSArray<NSString*> *capabilities,
      NSError *error) {
        [completionLock lock];
        BOOL shouldReply = !completed;
        completed = YES;
        [completionLock unlock];

        if (shouldReply) {
            reply(protocolVersion, buildVersion, marketingVersion, capabilities, error);
        }
        return shouldReply;
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SCXPCDaemonCompatibilityTimeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *safeError = [NSError errorWithDomain:SCXPCDaemonCompatibilityErrorDomain
                                                 code:SCXPCDaemonCompatibilityErrorTimeout
                                             userInfo:@{NSLocalizedDescriptionKey: @"The daemon compatibility handshake timed out"}];
        if (finishOnce(SCDaemonProtocolVersionLegacy, nil, nil, nil, safeError)) {
            NSLog(@"Daemon compatibility handshake timed out");
        }
    });

    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Failed to get daemon compatibility info with connection error: %@", connectError);
            NSError *safeError = [NSError errorWithDomain:SCXPCDaemonCompatibilityErrorDomain
                                                     code:SCXPCDaemonCompatibilityErrorConnection
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Could not connect for the daemon compatibility handshake"}];
            finishOnce(SCDaemonProtocolVersionLegacy, nil, nil, nil, safeError);
            return;
        }

        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
            // Keep the potentially verbose NSXPC error local. The returned
            // error contains no selector arguments, paths, or user data.
            NSLog(@"Failed to get daemon compatibility info with remote object proxy error: %@", proxyError);
            NSError *safeError = [NSError errorWithDomain:SCXPCDaemonCompatibilityErrorDomain
                                                     code:SCXPCDaemonCompatibilityErrorHandshake
                                                 userInfo:@{NSLocalizedDescriptionKey: @"The daemon compatibility handshake is unavailable"}];
            finishOnce(SCDaemonProtocolVersionLegacy, nil, nil, nil, safeError);
        }] getCompatibilityInfoWithReply:^(NSInteger protocolVersion,
                                           NSString *buildVersion,
                                           NSString *marketingVersion,
                                           NSArray<NSString *> *capabilities) {
            finishOnce(protocolVersion, buildVersion, marketingVersion, capabilities, nil);
        }];
    }];
}

+ (BOOL)isDaemonProtocolVersion:(NSInteger)protocolVersion
                   capabilities:(NSArray<NSString*>*)capabilities
compatibleWithCurrentAppWithReason:(NSString**)reason {
    if (protocolVersion < SCDaemonProtocolVersionCurrent) {
        if (reason != NULL) {
            *reason = @"protocol-too-old";
        }
        return NO;
    }

    if (![capabilities isKindOfClass:[NSArray class]]) {
        if (reason != NULL) {
            *reason = @"capabilities-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityActiveBlocklistAppend]) {
        if (reason != NULL) {
            *reason = @"active-append-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityApprovedSchedulesAppend]) {
        if (reason != NULL) {
            *reason = @"approved-append-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityTelemetrySpool]) {
        if (reason != NULL) {
            // Keep the public diagnostic reason coarse. The exact required
            // capability is static in this binary and checked above.
            *reason = @"capabilities-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityStrictApplyResults]) {
        if (reason != NULL) {
            *reason = @"capabilities-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityScheduleOwnerBounds]) {
        if (reason != NULL) {
            *reason = @"capabilities-missing";
        }
        return NO;
    }

    if (![capabilities containsObject:SCDaemonCapabilityConsistencyProjection]) {
        if (reason != NULL) {
            *reason = @"consistency-projection-missing";
        }
        return NO;
    }

    if (![self isDaemonProtocolVersion:protocolVersion
                           capabilities:capabilities
          supportsRootScheduleCommitWithReason:reason]) {
        return NO;
    }

    if (![self isDaemonProtocolVersion:protocolVersion
                           capabilities:capabilities
          supportsRecurringSchedulesWithReason:reason]) {
        return NO;
    }

    if (reason != NULL) {
        *reason = @"compatible";
    }
    return YES;
}

+ (BOOL)isDaemonProtocolVersion:(NSInteger)protocolVersion
                   capabilities:(NSArray<NSString*>*)capabilities
supportsRecurringSchedulesWithReason:(NSString**)reason {
    if (protocolVersion < SCDaemonProtocolVersionRecurringScheduler) {
        if (reason != NULL) *reason = @"recurring-scheduler-protocol-too-old";
        return NO;
    }
    if (![capabilities isKindOfClass:[NSArray class]] ||
        ![capabilities containsObject:SCDaemonCapabilityRecurringScheduleStore]) {
        if (reason != NULL) *reason = @"recurring-schedule-store-missing";
        return NO;
    }
    if (![capabilities containsObject:SCDaemonCapabilityRecurringScheduleTimer]) {
        if (reason != NULL) *reason = @"recurring-schedule-timer-missing";
        return NO;
    }
    if (![capabilities containsObject:SCDaemonCapabilityRecurringScheduleBreaks]) {
        if (reason != NULL) *reason = @"recurring-schedule-breaks-missing";
        return NO;
    }
    if (![capabilities containsObject:SCDaemonCapabilityRecurringCommitmentExtend]) {
        if (reason != NULL) *reason = @"recurring-commitment-extend-missing";
        return NO;
    }
    if (reason != NULL) *reason = @"compatible";
    return YES;
}

+ (BOOL)isDaemonProtocolVersion:(NSInteger)protocolVersion
                   capabilities:(NSArray<NSString*>*)capabilities
supportsRootScheduleCommitWithReason:(NSString**)reason {
    if (protocolVersion < SCDaemonProtocolVersionRootScheduler) {
        if (reason != NULL) *reason = @"root-scheduler-protocol-too-old";
        return NO;
    }
    if (![capabilities isKindOfClass:[NSArray class]] ||
        ![capabilities containsObject:SCDaemonCapabilityRootScheduleStore]) {
        if (reason != NULL) *reason = @"root-schedule-store-missing";
        return NO;
    }
    if (![capabilities containsObject:SCDaemonCapabilityRootScheduleTimer]) {
        if (reason != NULL) *reason = @"root-schedule-timer-missing";
        return NO;
    }
    if (reason != NULL) *reason = @"compatible";
    return YES;
}

- (void)setTelemetryConsentEnabled:(BOOL)enabled
                        generation:(NSUInteger)generation
                             reply:(void(^)(NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(proxyError);
        }] setTelemetryConsentEnabled:enabled generation:generation reply:reply];
    }];
}

- (void)fetchTelemetryRecordsWithLimit:(NSUInteger)limit
                                  reply:(void(^)(NSArray<NSDictionary<NSString *,id> *> *records,
                                                 NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(@[], connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@[], proxyError);
        }] fetchTelemetryRecordsWithLimit:MIN(limit, 25) reply:reply];
    }];
}

- (void)acknowledgeTelemetryRecordIDs:(NSArray<NSString *> *)recordIDs
                                 reply:(void(^)(NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(proxyError);
        }] acknowledgeTelemetryRecordIDs:recordIDs reply:reply];
    }];
}

- (void)getSanitizedDaemonSnapshot:(void(^)(NSDictionary<NSString *,id> *snapshot,
                                             NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(@{}, connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] getSanitizedDaemonSnapshotWithReply:reply];
    }];
}

- (void)getSanitizedDaemonSnapshotForExpectedState:(NSDictionary<NSString *,id> *)expectedState
                                              reply:(void(^)(NSDictionary<NSString *,id> *snapshot,
                                                             NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(@{}, connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] getSanitizedDaemonSnapshotForExpectedState:expectedState reply:reply];
    }];
}

- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            [SCSentry captureError: connectError];
            NSLog(@"Start block command failed with connection error: %@", connectError);
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Start block command failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] startBlockWithControllingUID: controllingUID blocklist: blocklist isAllowlist:isAllowlist endDate:endDate blockSettings: blockSettings authorization: self.authorization reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"start" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Start block failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Blocklist update failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Blocklist update command failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] updateBlocklist: newBlocklist authorization: self.authorization reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"update" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Blocklist update failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                                 reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Append active blocklist entries failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Append active blocklist entries failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] appendEntriesToActiveBlocklist:entries
                    matchingExistingBlocklist:existingBlocklist
                                        reply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Append active blocklist entries failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)appendEntriesToActiveBlocklist:(NSArray<NSString*>*)entries
             matchingExistingBlocklist:(NSArray<NSString*>*)existingBlocklist
                            resultReply:(void(^)(NSDictionary<NSString *,id> *result,
                                                 NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(@{}, connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] appendEntriesToActiveBlocklist:entries
                matchingExistingBlocklist:existingBlocklist
                               resultReply:reply];
    }];
}

- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Block end date update failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Block end date update command failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] updateBlockEndDate: newEndDate authorization: self.authorization reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"update" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Block end date update failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

#pragma mark - Schedule Registration (Pre-Authorization System)

- (void)replaceScheduledCommitmentForWeekKey:(NSString *)weekKey
                               weekStartDate:(NSDate *)weekStartDate
                                 weekEndDate:(NSDate *)weekEndDate
                                commitmentID:(NSString *)commitmentID
                                  generation:(NSString *)generation
                                    segments:(NSArray<NSDictionary<NSString *,id> *> *)segments
                                       reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self getCompatibilityInfo:^(NSInteger protocolVersion,
                                 NSString *buildVersion,
                                 NSString *marketingVersion,
                                 NSArray<NSString *> *capabilities,
                                 NSError *handshakeError) {
        #pragma unused(buildVersion)
        #pragma unused(marketingVersion)
        if (handshakeError != nil) {
            reply(@{}, handshakeError);
            return;
        }

        NSString *reason = nil;
        if (![SCXPCClient isDaemonProtocolVersion:protocolVersion
                                      capabilities:capabilities
                     supportsRootScheduleCommitWithReason:&reason]) {
            NSError *compatibilityError = [NSError errorWithDomain:SCXPCDaemonCompatibilityErrorDomain
                                                               code:SCXPCDaemonCompatibilityErrorHandshake
                                                           userInfo:@{
                NSLocalizedDescriptionKey: @"The installed Fence helper does not support root-owned schedules.",
                @"reason": reason ?: @"root-scheduler-incompatible",
            }];
            reply(@{}, compatibilityError);
            return;
        }

        [self connectAndExecuteCommandBlock:^(NSError *connectError) {
            if (connectError != nil) {
                reply(@{}, connectError);
                return;
            }
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
                NSLog(@"Replace scheduled commitment failed (domain=%@ code=%ld)",
                      proxyError.domain, (long)proxyError.code);
                reply(@{}, proxyError);
            }] replaceScheduledCommitmentForWeekKey:weekKey
                                      weekStartDate:weekStartDate
                                        weekEndDate:weekEndDate
                                       commitmentID:commitmentID
                                         generation:generation
                                           segments:segments
                                      authorization:self.authorization
                                              reply:^(NSDictionary<NSString *,id> *result, NSError *error) {
                BOOL authorizationFailure =
                    [SCXPCClient recordAuthorizationRejectionForCommand:@"replace_schedule" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Replace scheduled commitment failed (domain=%@ code=%ld)",
                          error.domain, (long)error.code);
                }
                reply([result isKindOfClass:[NSDictionary class]] ? result : @{}, error);
            }];
        }];
    }];
}

- (void)installRecurringCommitmentWithID:(NSString *)commitmentID
                               generation:(NSString *)generation
                                 startedAt:(NSDate *)startedAt
                                lockEndsAt:(NSDate *)lockEndsAt
                            protectedHours:(NSDictionary<NSString *,id> *)protectedHours
                             blockSettings:(NSDictionary<NSString *,id> *)blockSettings
                                  segments:(NSArray<NSDictionary<NSString *,id> *> *)segments
                                     reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self getCompatibilityInfo:^(NSInteger protocolVersion, NSString *buildVersion,
                                 NSString *marketingVersion, NSArray<NSString *> *capabilities,
                                 NSError *handshakeError) {
        #pragma unused(buildVersion)
        #pragma unused(marketingVersion)
        if (handshakeError != nil) { reply(@{}, handshakeError); return; }
        NSString *reason = nil;
        if (![SCXPCClient isDaemonProtocolVersion:protocolVersion capabilities:capabilities
             supportsRecurringSchedulesWithReason:&reason]) {
            reply(@{}, [NSError errorWithDomain:SCXPCDaemonCompatibilityErrorDomain
                                            code:SCXPCDaemonCompatibilityErrorHandshake
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"The installed Fence helper does not support recurring schedules.",
                @"reason": reason ?: @"recurring-scheduler-incompatible",
            }]);
            return;
        }
        [self connectAndExecuteCommandBlock:^(NSError *connectError) {
            if (connectError != nil) { reply(@{}, connectError); return; }
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
                reply(@{}, proxyError);
            }] installRecurringCommitmentWithID:commitmentID
                                     generation:generation
                                       startedAt:startedAt
                                      lockEndsAt:lockEndsAt
                                  protectedHours:protectedHours
                                   blockSettings:blockSettings
                                        segments:segments
                                   authorization:self.authorization
                                           reply:^(NSDictionary *result, NSError *error) {
                [SCXPCClient recordAuthorizationRejectionForCommand:@"replace_schedule" error:error];
                reply([result isKindOfClass:[NSDictionary class]] ? result : @{}, error);
            }];
        }];
    }];
}

- (void)endExpiredRecurringCommitmentWithID:(NSString *)commitmentID
                                  generation:(NSString *)generation
                                       reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] endExpiredRecurringCommitmentWithID:commitmentID generation:generation reply:reply];
    }];
}

- (void)extendRecurringCommitmentWithID:(NSString *)commitmentID
                              generation:(NSString *)generation
                                    days:(NSInteger)days
                                   reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] extendRecurringCommitmentWithID:commitmentID
                                 generation:generation
                                       days:days
                                      reply:reply];
    }];
}

- (void)updateProtectedHoursForRecurringCommitmentID:(NSString *)commitmentID
                                           generation:(NSString *)generation
                                       protectedHours:(NSDictionary<NSString *,id> *)protectedHours
                                                reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] updateProtectedHoursForRecurringCommitmentID:commitmentID
                                              generation:generation
                                          protectedHours:protectedHours
                                                   reply:reply];
    }];
}

- (void)beginRecurringTimedBreakForCommitmentID:(NSString *)commitmentID
                                      generation:(NSString *)generation
                                 durationMinutes:(NSInteger)durationMinutes
                                           reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] beginRecurringTimedBreakForCommitmentID:commitmentID
                                         generation:generation
                                    durationMinutes:durationMinutes
                                              reply:reply];
    }];
}

- (void)endRecurringTimedBreakForCommitmentID:(NSString *)commitmentID
                                    generation:(NSString *)generation
                                         reply:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] endRecurringTimedBreakForCommitmentID:commitmentID generation:generation reply:reply];
    }];
}

- (void)getRecurringScheduleRuntimeState:(void (^)(NSDictionary<NSString *,id> *, NSError *))reply {
    [self connectAndExecuteCommandBlock:^(NSError *error) {
        if (error != nil) { reply(@{}, error); return; }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] getRecurringScheduleRuntimeStateWithReply:reply];
    }];
}

- (void)registerScheduleWithID:(NSString*)scheduleId
                     blocklist:(NSArray<NSString*>*)blocklist
                   isAllowlist:(BOOL)isAllowlist
                 blockSettings:(NSDictionary*)blockSettings
             controllingUID:(uid_t)controllingUID
                   startDate:(NSDate*)startDate
                     endDate:(NSDate*)endDate
                         reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Register schedule failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Register schedule failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] registerScheduleWithID: scheduleId
                            blocklist: blocklist
                          isAllowlist: isAllowlist
                        blockSettings: blockSettings
                        controllingUID: controllingUID
                              startDate: startDate
                                endDate: endDate
                                authorization: self.authorization
                                reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"register_schedule" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Register schedule failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                            reply:(void(^)(NSError* error))reply {
    [self startScheduledBlockWithID:scheduleId
                            endDate:endDate
                      executionPath:@"xpc_direct"
                              reply:reply];
}

- (void)startScheduledBlockWithID:(NSString*)scheduleId
                          endDate:(NSDate*)endDate
                    executionPath:(NSString*)executionPath
                            reply:(void(^)(NSError* error))reply {
    // Note: This method does NOT require authorization - the schedule was pre-approved
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Start scheduled block failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Start scheduled block failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] startScheduledBlockWithID: scheduleId
                                 endDate: endDate
                           executionPath:executionPath
                                   reply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Start scheduled block failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)unregisterScheduleWithID:(NSString*)scheduleId
                           reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Unregister schedule failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Unregister schedule failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] unregisterScheduleWithID: scheduleId
                          authorization: self.authorization
                                  reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"unregister_schedule" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Unregister schedule failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)clearAllApprovedSchedules:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Clear all approved schedules failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Clear all approved schedules failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] clearAllApprovedSchedulesWithAuthorization: self.authorization
                                                    reply:^(NSError* error) {
                BOOL authorizationFailure = [SCXPCClient recordAuthorizationRejectionForCommand:@"clear_schedules" error:error];
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled:error] && !authorizationFailure) {
                    NSLog(@"Clear all approved schedules failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                  entries:(NSArray<NSString*>*)entries
                                    reply:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Append approved schedule entries failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Append approved schedule entries failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] appendEntriesToApprovedSchedules:expectedBlocklistsByScheduleID
                                        entries:entries
                                          reply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Append approved schedule entries failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)appendEntriesToApprovedSchedules:(NSDictionary<NSString*, NSArray<NSString*>*>*)expectedBlocklistsByScheduleID
                                  entries:(NSArray<NSString*>*)entries
                              resultReply:(void(^)(NSDictionary<NSString *,id> *result,
                                                   NSError *error))reply {
    [self connectAndExecuteCommandBlock:^(NSError *connectError) {
        if (connectError != nil) {
            reply(@{}, connectError);
            return;
        }
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            reply(@{}, proxyError);
        }] appendEntriesToApprovedSchedules:expectedBlocklistsByScheduleID
                                       entries:entries
                                   resultReply:reply];
    }];
}

- (void)clearBlockForDebug:(void(^)(NSError* error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Clear block for debug failed with connection error: %@", connectError);
            [SCSentry captureError: connectError];
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Clear block for debug failed with remote object proxy error: %@", proxyError);
                [SCSentry captureError: proxyError];
                reply(proxyError);
            }] clearBlockForDebugWithAuthorization: self.authorization
                                             reply:^(NSError* error) {
                if (error != nil && ![SCMiscUtilities errorIsAuthCanceled: error]) {
                    NSLog(@"Clear block for debug failed with error = %@\n", error);
                    [SCSentry captureError: error];
                }
                reply(error);
            }];
        }
    }];
}

- (void)isPFBlockActive:(void(^)(BOOL active, NSError* _Nullable error))reply {
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"isPFBlockActive failed with connection error: %@", connectError);
            reply(NO, connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"isPFBlockActive failed with remote object proxy error: %@", proxyError);
                reply(NO, proxyError);
            }] isPFBlockActiveWithReply:^(BOOL active) {
                reply(active, nil);
            }];
        }
    }];
}

- (void)stopTestBlock:(void(^)(NSError* error))reply {
    // Note: This method does NOT require authorization - test blocks are meant to be freely stoppable
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Stop test block failed with connection error: %@", connectError);
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Stop test block failed with remote object proxy error: %@", proxyError);
                reply(proxyError);
            }] stopTestBlockWithReply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Stop test block failed with error = %@\n", error);
                }
                reply(error);
            }];
        }
    }];
}

- (void)clearExpiredBlock:(void(^)(NSError* error))reply {
    // Note: This method does NOT require authorization - the block is already expired
    // This clears PF rules, /etc/hosts, AppBlocker, and sets BlockIsRunning=NO
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Clear expired block failed with connection error: %@", connectError);
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Clear expired block failed with remote object proxy error: %@", proxyError);
                reply(proxyError);
            }] clearExpiredBlockWithReply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Clear expired block failed with error = %@\n", error);
                }
                reply(error);
            }];
        }
    }];
}

- (void)cleanupStaleSchedule:(NSString*)scheduleId
                       reply:(void(^)(NSError* error))reply {
    // Note: This method does NOT require authorization - cleanup of expired pre-authorized schedules
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            NSLog(@"Cleanup stale schedule failed with connection error: %@", connectError);
            reply(connectError);
        } else {
            [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                NSLog(@"Cleanup stale schedule failed with remote object proxy error: %@", proxyError);
                reply(proxyError);
            }] cleanupStaleScheduleWithID:scheduleId reply:^(NSError* error) {
                if (error != nil) {
                    NSLog(@"Cleanup stale schedule failed with error = %@\n", error);
                }
                reply(error);
            }];
        }
    }];
}

- (NSString*)selfControlHelperToolPath {
    static NSString* path;

    // Cache the path so it doesn't have to be searched for again.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle* thisBundle = [NSBundle mainBundle];
        path = [thisBundle.bundlePath stringByAppendingString: @"/Contents/Library/LaunchServices/org.eyebeam.selfcontrold"];
    });

    return path;
}

- (char*)selfControlHelperToolPathUTF8String {
    static char* path;

    // Cache the converted path so it doesn't have to be converted again
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        path = malloc(512);
        [[self selfControlHelperToolPath] getCString: path
                                           maxLength: 512
                                            encoding: NSUTF8StringEncoding];
    });

    return path;
}

@end

//
//  SCLogger.m
//  SelfControl
//
//  Privacy-safe, Sentry-only diagnostic reporting for user support.
//

#import "SCLogger.h"
#import "SCSentry.h"
#import "SCXPCClient.h"
#import "SCScheduleManager.h"
#import "SCDaemonProtocol.h"

NSString * const SCDiagnosticReportErrorDomain = @"app.usefence.DiagnosticReport";

@implementation SCLogger

+ (BOOL)legacyDefaultsContainScheduleState {
    NSDictionary *legacyDomain = [[NSUserDefaults standardUserDefaults]
        persistentDomainForName:@"org.eyebeam.SelfControl"] ?: @{};
    id bundles = legacyDomain[@"SCScheduleBundles"];
    if ([bundles isKindOfClass:[NSArray class]] && [bundles count] > 0) return YES;
    for (id candidateKey in legacyDomain) {
        if (![candidateKey isKindOfClass:[NSString class]]) continue;
        NSString *key = candidateKey;
        id value = legacyDomain[key];
        if ([key hasPrefix:@"SCWeekSchedules_"] &&
            [value isKindOfClass:[NSArray class]] && [value count] > 0) {
            return YES;
        }
        if ([key hasPrefix:@"SCWeekCommitment_"] && [value isKindOfClass:[NSDate class]]) return YES;
    }
    return NO;
}

+ (NSDictionary<NSString *, id> *)diagnosticTelemetryFieldsForAppSnapshot:(NSDictionary<NSString *, NSNumber *> *)appSnapshot
                                                                 uiSnapshot:(nullable NSDictionary<NSString *, NSNumber *> *)uiSnapshot
                                                             daemonSnapshot:(NSDictionary<NSString *, id> *)daemonSnapshot
                                                            daemonReachable:(BOOL)daemonReachable {
    BOOL settingsAvailable = daemonReachable && [daemonSnapshot[@"settings_available"] boolValue];
    BOOL blockRunning = daemonReachable && [daemonSnapshot[@"block_running"] boolValue];
    BOOL pfActive = daemonReachable && [daemonSnapshot[@"pf_active"] boolValue];
    BOOL hostsActive = daemonReachable && [daemonSnapshot[@"hosts_active"] boolValue];
    BOOL appMonitoring = daemonReachable && [daemonSnapshot[@"app_monitoring"] boolValue];
    NSUInteger expectedActiveCount = [daemonSnapshot[@"active_expected_count"] unsignedIntegerValue];
    NSUInteger expectedAppCount = [appSnapshot[@"expected_active_app_entry_count"] unsignedIntegerValue];
    NSUInteger daemonActiveCount = [daemonSnapshot[@"active_actual_count"] unsignedIntegerValue];
    BOOL projectionAvailable = [appSnapshot[@"active_projection_available"] boolValue];
    BOOL requiresHosts = [appSnapshot[@"expected_requires_hosts"] boolValue];
    BOOL requiresPF = [appSnapshot[@"expected_requires_packet_filter"] boolValue];
    BOOL physicalLayersMatch = daemonReachable && (blockRunning
        ? ((!requiresHosts || hostsActive) && (!requiresPF || pfActive) &&
           (expectedAppCount == 0 || appMonitoring))
        : !(pfActive || hostsActive || appMonitoring));
    NSString *collectorStatus = daemonReachable &&
        [daemonSnapshot[@"collector_status"] isKindOfClass:[NSString class]]
        ? daemonSnapshot[@"collector_status"] : @"failed";
    if (![@[@"complete", @"partial", @"failed"] containsObject:collectorStatus]) {
        collectorStatus = daemonReachable ? @"partial" : @"failed";
    }
    NSString *comparisonStatus = daemonReachable &&
        [daemonSnapshot[@"comparison_status"] isKindOfClass:[NSString class]]
        ? daemonSnapshot[@"comparison_status"] : @"failed";
    if (![@[@"exact", @"unavailable"] containsObject:comparisonStatus]) {
        comparisonStatus = daemonReachable ? @"unavailable" : @"failed";
    }
    BOOL comparisonExact = [comparisonStatus isEqualToString:@"exact"];
    BOOL activeCountsMatch = daemonReachable && comparisonExact &&
        SCAppDaemonActiveStateMatches(projectionAvailable,
                                      [daemonSnapshot[@"active_comparison_available"] boolValue],
                                      [daemonSnapshot[@"active_entries_match"] boolValue],
                                      blockRunning,
                                      expectedActiveCount > 0,
                                      physicalLayersMatch);
    NSUInteger daemonApprovalCount = [daemonSnapshot[@"approved_schedule_count"] unsignedIntegerValue];
    BOOL approvalCountsMatch = daemonReachable && comparisonExact &&
        [daemonSnapshot[@"approval_schedules_match"] boolValue];
    BOOL plistCountsMatch = daemonReachable && comparisonExact &&
        [daemonSnapshot[@"plist_schedules_match"] boolValue];
    BOOL jobCountsMatch = daemonReachable && comparisonExact &&
        [daemonSnapshot[@"loaded_jobs_match"] boolValue];

    NSString *lastStrictifyOutcome = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"SCLastStrictifyTelemetryOutcome"] ?: @"none";
    if (![@[@"none", @"verified", @"partial", @"failed", @"skipped"]
            containsObject:lastStrictifyOutcome]) {
        lastStrictifyOutcome = @"none";
    }

    NSDictionary<NSString *, NSNumber *> *safeUI = [uiSnapshot isKindOfClass:[NSDictionary class]]
        ? uiSnapshot : @{};
    return @{
        @"collector_status": collectorStatus,
        @"projection_comparison_status": comparisonStatus,
        @"last_strictify_outcome": lastStrictifyOutcome,
        @"settings_available": @(settingsAvailable),
        @"block_running": @(blockRunning),
        @"app_has_schedule_state": appSnapshot[@"app_has_schedule_state"] ?: @NO,
        @"legacy_domain_has_state": @([self legacyDefaultsContainScheduleState]),
        @"daemon_reachable": @(daemonReachable),
        @"pf_active": @(pfActive),
        @"hosts_active": @(hostsActive),
        @"app_monitoring": @(appMonitoring),
        @"physical_layers_match": @(physicalLayersMatch),
        @"active_counts_match": @(activeCountsMatch),
        @"approval_counts_match": @(approvalCountsMatch),
        @"plist_counts_match": @(plistCountsMatch),
        @"job_counts_match": @(jobCountsMatch),
        @"app_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
        @"app_week_count": appSnapshot[@"decoded_schedule_count"] ?: @0,
        @"app_commitment_count": appSnapshot[@"commitment_count"] ?: @0,
        @"daemon_active_entry_count": @(daemonActiveCount),
        @"daemon_approval_count": @(daemonApprovalCount),
        @"daemon_approval_entry_count": daemonSnapshot[@"approved_entry_count"] ?: @0,
        @"daemon_plist_count": daemonSnapshot[@"schedule_plist_count"] ?: @0,
        @"daemon_job_count": daemonSnapshot[@"schedule_job_count"] ?: @0,
        @"collector_error_count": @(daemonReachable ? 0 : 1),
        @"daemon_protocol": daemonSnapshot[@"daemon_protocol"] ?: @0,
        @"raw_bundle_count": appSnapshot[@"raw_bundle_count"] ?: @0,
        @"decoded_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
        @"raw_schedule_count": appSnapshot[@"raw_schedule_count"] ?: @0,
        @"decoded_schedule_count": appSnapshot[@"decoded_schedule_count"] ?: @0,
        @"active_expected_count": daemonSnapshot[@"active_expected_count"] ?: @0,
        @"active_actual_count": daemonSnapshot[@"active_actual_count"] ?: @0,
        @"active_missing_count": daemonSnapshot[@"active_missing_count"] ?: @0,
        @"active_extra_count": daemonSnapshot[@"active_extra_count"] ?: @0,
        @"approval_expected_count": daemonSnapshot[@"approval_expected_count"] ?: @0,
        @"approval_actual_count": daemonSnapshot[@"approval_actual_count"] ?: @0,
        @"approval_missing_count": daemonSnapshot[@"approval_missing_count"] ?: @0,
        @"approval_extra_count": daemonSnapshot[@"approval_extra_count"] ?: @0,
        @"plist_expected_count": daemonSnapshot[@"plist_expected_count"] ?: @0,
        @"plist_actual_count": daemonSnapshot[@"plist_actual_count"] ?: @0,
        @"plist_missing_count": daemonSnapshot[@"plist_missing_count"] ?: @0,
        @"plist_extra_count": daemonSnapshot[@"plist_extra_count"] ?: @0,
        @"loaded_job_expected_count": daemonSnapshot[@"loaded_job_expected_count"] ?: @0,
        @"loaded_job_actual_count": daemonSnapshot[@"loaded_job_actual_count"] ?: @0,
        @"loaded_job_missing_count": daemonSnapshot[@"loaded_job_missing_count"] ?: @0,
        @"loaded_job_extra_count": daemonSnapshot[@"loaded_job_extra_count"] ?: @0,
        @"launchd_probe_failure_count": daemonSnapshot[@"launchd_probe_failure_count"] ?: @0,
        @"invalid_approval_count": daemonSnapshot[@"invalid_approval_count"] ?: @0,
        @"invalid_plist_count": daemonSnapshot[@"invalid_plist_count"] ?: @0,
        @"expired_approval_count": daemonSnapshot[@"expired_approval_count"] ?: @0,
        @"in_progress_approval_count": daemonSnapshot[@"in_progress_approval_count"] ?: @0,
        @"in_progress_plist_count": daemonSnapshot[@"in_progress_plist_count"] ?: @0,
        @"week_window_initialized": safeUI[@"week_window_initialized"] ?: @NO,
        @"week_window_loaded": safeUI[@"week_window_loaded"] ?: @NO,
        @"week_window_visible": safeUI[@"week_window_visible"] ?: @NO,
        @"ui_snapshot_available": safeUI[@"ui_snapshot_available"] ?: @NO,
        @"ui_calendar_attached": safeUI[@"ui_calendar_attached"] ?: @NO,
        @"ui_calendar_has_area": safeUI[@"ui_calendar_has_area"] ?: @NO,
        @"ui_empty_state_visible": safeUI[@"ui_empty_state_visible"] ?: @NO,
        @"ui_bundle_counts_match": safeUI[@"ui_bundle_counts_match"] ?: @NO,
        @"ui_schedule_counts_match": safeUI[@"ui_schedule_counts_match"] ?: @NO,
        @"ui_allow_block_counts_match": safeUI[@"ui_allow_block_counts_match"] ?: @NO,
        @"ui_block_geometry_counts_match": safeUI[@"ui_block_geometry_counts_match"] ?: @NO,
        @"ui_block_appearance_counts_match": safeUI[@"ui_block_appearance_counts_match"] ?: @NO,
        @"ui_visible_allow_block_counts_match": safeUI[@"ui_visible_allow_block_counts_match"] ?: @NO,
        @"ui_render_objects_without_visible_blocks": safeUI[@"ui_render_objects_without_visible_blocks"] ?: @NO,
        @"ui_window_occlusion_visible": safeUI[@"ui_window_occlusion_visible"] ?: @NO,
        @"ui_empty_despite_model": safeUI[@"ui_empty_despite_model"] ?: @NO,
        @"selected_week_offset": safeUI[@"selected_week_offset"] ?: @0,
        @"ui_model_bundle_count": safeUI[@"ui_model_bundle_count"] ?: @0,
        @"ui_model_schedule_count": safeUI[@"ui_model_schedule_count"] ?: @0,
        @"ui_rendered_bundle_count": safeUI[@"ui_rendered_bundle_count"] ?: @0,
        @"ui_rendered_schedule_count": safeUI[@"ui_rendered_schedule_count"] ?: @0,
        @"ui_day_column_count": safeUI[@"ui_day_column_count"] ?: @0,
        @"ui_expected_allow_block_count": safeUI[@"ui_expected_allow_block_count"] ?: @0,
        @"ui_rendered_allow_block_count": safeUI[@"ui_rendered_allow_block_count"] ?: @0,
        @"ui_nonzero_area_allow_block_count": safeUI[@"ui_nonzero_area_allow_block_count"] ?: @0,
        @"ui_intersecting_allow_block_count": safeUI[@"ui_intersecting_allow_block_count"] ?: @0,
        @"ui_appearance_valid_allow_block_count": safeUI[@"ui_appearance_valid_allow_block_count"] ?: @0,
        @"ui_visible_allow_block_count": safeUI[@"ui_visible_allow_block_count"] ?: @0,
    };
}

+ (void)sendDiagnosticReportWithUISnapshot:(nullable NSDictionary<NSString *, NSNumber *> *)uiSnapshot
                                completion:(void (^)(NSString * _Nullable,
                                                     NSError * _Nullable))completion {
    if (![SCSentry errorReportingEnabled]) {
        NSError *error = [NSError errorWithDomain:SCDiagnosticReportErrorDomain
                                             code:SCDiagnosticReportErrorReportingDisabled
                                         userInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    SCXPCClient *xpc = [[SCXPCClient alloc] init];
    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    NSDictionary<NSString *, NSNumber *> *appSnapshot = [scheduleManager telemetryStructuralSnapshot];
    NSDictionary<NSString *, id> *expectedState = [scheduleManager daemonConsistencyProjection];
    __block BOOL completed = NO;
    void (^finish)(NSDictionary<NSString *, id> *, NSError *) =
        ^(NSDictionary<NSString *, id> *daemonSnapshot, NSError *daemonError) {
        @synchronized (xpc) {
            if (completed) return;
            completed = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL daemonReachable = daemonError == nil && daemonSnapshot.count > 0;
            NSDictionary<NSString *, id> *fields =
                [self diagnosticTelemetryFieldsForAppSnapshot:appSnapshot
                                                   uiSnapshot:uiSnapshot
                                               daemonSnapshot:daemonSnapshot ?: @{}
                                              daemonReachable:daemonReachable];
            NSString *eventID = [SCSentry captureTelemetryEvent:@"support.diagnostic_snapshot"
                                                          level:SCTelemetryEventLevelInfo
                                                         fields:fields];
            if (eventID.length < 8) {
                NSError *captureError = [NSError errorWithDomain:SCDiagnosticReportErrorDomain
                                                             code:SCDiagnosticReportErrorCaptureFailed
                                                         userInfo:nil];
                completion(nil, captureError);
                return;
            }

            NSString *reference = [NSString stringWithFormat:@"FENCE-%@",
                [[eventID substringToIndex:8] uppercaseString]];
            [SCSentry flushWithTimeout:5.0 completion:^{
                completion(reference, nil);
            }];
        });
    };

    [xpc getSanitizedDaemonSnapshotForExpectedState:expectedState
                                             reply:^(NSDictionary<NSString *,id> *snapshot, NSError *error) {
        finish(snapshot ?: @{}, error);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *timeout = [NSError errorWithDomain:@"app.usefence.DiagnosticSnapshot"
                                               code:1
                                           userInfo:nil];
        finish(@{}, timeout);
    });
}

@end

//
//  SCSentry.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/15/21.
//

#import "SCSentry.h"
#import "SCSettings.h"
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <stdatomic.h>

// Only include Sentry if available and not testing.
#if !defined(TESTING) && __has_include(<Sentry/Sentry.h>)
#define SENTRY_ENABLED 1
#import <Sentry/Sentry.h>
#import <Sentry/Sentry-Swift.h>
#else
#define SENTRY_ENABLED 0
#endif

static NSString* const SCLegacyUpstreamSentryHost = @"o504820.ingest.sentry.io";
static NSString* const SCErrorReportingPromptDismissedKey = @"ErrorReportingPromptDismissed";
static NSString* const SCEnableErrorReportingKey = @"EnableErrorReporting";
static NSString* const SCDedicatedSentryCacheScope = @"org.eyebeam.Fence";
static NSString* const SCDedicatedSentryCacheConsentMarker = @".explicit-consent-v1";
static NSString* const SCLegacyUpstreamSentryDSNHash = @"26aad90e134be23208fc16fb03818eba86edb3c2";

NSString * const SCTelemetryConsentDidChangeNotification = @"SCTelemetryConsentDidChangeNotification";
NSString * const SCTelemetryConsentGenerationDefaultsKey = @"FenceTelemetryConsentGeneration";

static NSString* SCSentryComponentIdentifier = nil;
static id SCSentryDefaultsObserver = nil;
static BOOL SCSentryDisabledCachesPurged = NO;
static BOOL SCSentryConsentChoiceInProgress = NO;

static NSDictionary<NSString*, NSDictionary<NSString*, id>*> *SCTelemetryEventSchemas(void) {
    static NSDictionary<NSString*, NSDictionary<NSString*, id>*> *schemas;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString*> *blockApplyRequired = @[
            @"operation", @"layer", @"pf_command", @"is_allowlist",
            @"hosts_ready", @"hosts_write_succeeded", @"hosts_verification_succeeded",
            @"pf_anchor_open_succeeded", @"pf_anchor_write_succeeded",
            @"pf_main_configuration_write_succeeded", @"pf_verification_succeeded",
            @"app_monitoring_before", @"app_monitoring_after", @"settings_persisted",
            @"input_entry_count", @"valid_entry_count", @"rejected_entry_count",
            @"unapplied_entry_count", @"app_entry_count", @"site_entry_count",
            @"dns_lookup_count", @"dns_resolved_host_count", @"dns_resolved_address_count",
            @"dns_failure_count", @"blocked_app_count", @"app_kill_attempt_count",
            @"app_terminate_success_count", @"app_force_kill_count", @"app_kill_failure_count",
            @"duration_milliseconds", @"pf_exit_code"
        ];
        NSDictionary *blockApplyFields = @{
            @"enums": @{
                @"operation": @[@"fresh", @"strictify", @"integrity_reapply"],
                @"layer": @[@"input", @"hosts", @"pf", @"apps", @"settings", @"verification", @"unknown"],
                @"pf_command": @[@"none", @"load", @"refresh", @"append"],
            },
            @"booleans": @[
                @"is_allowlist", @"hosts_ready", @"hosts_write_succeeded",
                @"hosts_verification_succeeded", @"pf_anchor_open_succeeded",
                @"pf_anchor_write_succeeded", @"pf_main_configuration_write_succeeded",
                @"pf_verification_succeeded", @"app_monitoring_before",
                @"app_monitoring_after", @"settings_persisted"
            ],
            @"unsigned": @[
                @"input_entry_count", @"valid_entry_count", @"rejected_entry_count",
                @"unapplied_entry_count",
                @"app_entry_count", @"site_entry_count", @"dns_lookup_count",
                @"dns_resolved_host_count", @"dns_resolved_address_count",
                @"dns_failure_count", @"blocked_app_count", @"app_kill_attempt_count",
                @"app_terminate_success_count", @"app_force_kill_count",
                @"app_kill_failure_count", @"duration_milliseconds"
            ],
            @"signed": @[@"hosts_error_code", @"pf_error_code", @"app_scan_error_code",
                           @"app_kill_error_code", @"pf_exit_code"],
            @"required": blockApplyRequired
        };

        NSMutableDictionary *strictifyEnums = [blockApplyFields[@"enums"] mutableCopy];
        [strictifyEnums addEntriesFromDictionary:@{
            @"outcome": @[@"verified", @"partial", @"failed", @"skipped"],
            @"target": @[@"active", @"future", @"active_and_future", @"none"],
            @"failed_stage": @[@"none", @"persist", @"canonicalize", @"commitment_resolution", @"lock",
                                 @"daemon_compatibility", @"active_precondition", @"active_apply",
                                 @"physical_apply", @"future_resolution", @"future_apply", @"settings_sync", @"verification"],
            @"skip_reason": @[@"none", @"not_committed", @"bundle_not_in_committed_schedule",
                                @"no_additions", @"no_active_segment", @"no_matching_future_jobs",
                                @"daemon_incompatible"]
        }];
        NSMutableArray *strictifyBooleans = [blockApplyFields[@"booleans"] mutableCopy];
        [strictifyBooleans addObjectsFromArray:@[
            @"bundle_saved", @"used_in_committed_schedule", @"block_running",
            @"active_expected", @"active_precondition_matched", @"active_verified",
            @"active_physical_reapply_attempted", @"future_verified",
            @"blocklist_file_persisted", @"xpc_completed"
        ]];
        NSMutableArray *strictifyUnsigned = [blockApplyFields[@"unsigned"] mutableCopy];
        [strictifyUnsigned addObjectsFromArray:@[
            @"operation_sequence", @"requested_addition_count", @"canonical_addition_count",
            @"duplicate_addition_count", @"future_candidate_count", @"future_job_count",
            @"future_loaded_job_count", @"future_launchd_probe_failure_count",
            @"approval_requested_count", @"approval_matched_count", @"approval_updated_count",
            @"approval_skipped_count", @"active_before_count", @"active_after_count",
            @"daemon_protocol"
        ]];
        NSMutableArray<NSString*> *strictifyRequired = [blockApplyRequired mutableCopy];
        [strictifyRequired addObjectsFromArray:@[
            @"outcome", @"target", @"failed_stage", @"skip_reason",
            @"bundle_saved", @"used_in_committed_schedule", @"block_running",
            @"active_expected", @"active_precondition_matched", @"active_verified",
            @"active_physical_reapply_attempted", @"future_verified",
            @"blocklist_file_persisted", @"xpc_completed",
            @"operation_sequence", @"requested_addition_count", @"canonical_addition_count",
            @"duplicate_addition_count", @"future_candidate_count", @"future_job_count",
            @"future_loaded_job_count", @"future_launchd_probe_failure_count",
            @"approval_requested_count", @"approval_matched_count", @"approval_updated_count",
            @"approval_skipped_count", @"active_before_count", @"active_after_count", @"daemon_protocol"
        ]];

        schemas = @{
            @"state.app_defaults_regressed": @{
                @"enums": @{@"reason": @[@"bundle_id_changed", @"legacy_domain_orphaned", @"decode_loss", @"unexplained_drop"]},
                @"booleans": @[@"current_domain_has_state", @"legacy_domain_has_state", @"migration_applied"],
                @"unsigned": @[@"current_bundle_count", @"legacy_bundle_count", @"current_week_count",
                                 @"legacy_week_count", @"current_commitment_count", @"legacy_commitment_count",
                                 @"raw_bundle_count", @"decoded_bundle_count"],
                @"required": @[@"reason", @"current_domain_has_state", @"legacy_domain_has_state", @"migration_applied"]
            },
            @"state.app_daemon_diverged": @{
                @"enums": @{
                    @"reason": @[@"app_state_missing", @"schedule_drift", @"active_state_mismatch", @"projection_mismatch"],
                    @"collector_status": @[@"complete", @"partial", @"failed"]
                },
                @"booleans": @[@"settings_available", @"block_running", @"app_has_schedule_state", @"active_counts_match",
                                 @"approval_counts_match", @"plist_counts_match", @"job_counts_match", @"pf_active",
                                 @"hosts_active", @"app_monitoring", @"physical_layers_match"],
                @"unsigned": @[@"app_bundle_count", @"app_week_count", @"app_commitment_count",
                                 @"daemon_active_entry_count", @"daemon_approval_count", @"daemon_approval_entry_count",
                                 @"daemon_plist_count", @"daemon_job_count", @"raw_bundle_count", @"decoded_bundle_count",
                                 @"rendered_bundle_count", @"active_expected_count", @"active_actual_count",
                                 @"active_missing_count", @"active_extra_count", @"approval_expected_count",
                                 @"approval_actual_count", @"approval_missing_count", @"approval_extra_count",
                                 @"plist_expected_count", @"plist_actual_count", @"plist_missing_count",
                                 @"plist_extra_count", @"loaded_job_expected_count", @"loaded_job_actual_count",
                                 @"loaded_job_missing_count", @"loaded_job_extra_count", @"launchd_probe_failure_count",
                                 @"invalid_approval_count", @"invalid_plist_count"],
                @"required": @[@"reason", @"collector_status", @"settings_available", @"block_running", @"app_has_schedule_state", @"active_counts_match",
                                 @"approval_counts_match", @"plist_counts_match", @"job_counts_match", @"pf_active", @"hosts_active",
                                 @"app_monitoring", @"physical_layers_match", @"app_bundle_count",
                                 @"app_week_count", @"app_commitment_count", @"daemon_active_entry_count",
                                 @"daemon_approval_count", @"daemon_approval_entry_count", @"daemon_plist_count",
                                 @"daemon_job_count", @"raw_bundle_count", @"decoded_bundle_count", @"rendered_bundle_count",
                                 @"active_expected_count", @"active_actual_count", @"active_missing_count", @"active_extra_count",
                                 @"approval_expected_count", @"approval_actual_count", @"approval_missing_count", @"approval_extra_count",
                                 @"plist_expected_count", @"plist_actual_count", @"plist_missing_count", @"plist_extra_count",
                                 @"loaded_job_expected_count", @"loaded_job_actual_count", @"loaded_job_missing_count",
                                 @"loaded_job_extra_count", @"launchd_probe_failure_count", @"invalid_approval_count",
                                 @"invalid_plist_count"]
            },
            @"daemon.settings_load_failed": @{
                @"enums": @{@"reason": @[@"missing", @"decode_failed", @"permissions", @"version_invalid", @"schema_invalid"]},
                @"booleans": @[@"recovery_attempted", @"recovery_succeeded"],
                @"unsigned": @[@"settings_version"],
                @"signed": @[@"error_code"],
                @"required": @[@"reason", @"recovery_attempted", @"recovery_succeeded", @"settings_version"]
            },
            @"daemon.incompatible": @{
                @"enums": @{@"reason": @[@"handshake_unavailable", @"protocol_too_old", @"capabilities_missing",
                                                   @"active_append_missing", @"approved_append_missing", @"post_repair_incompatible",
                                                   @"telemetry_spool_missing", @"strict_apply_results_missing",
                                                   @"consistency_projection_missing"]},
                @"booleans": @[@"repair_attempted", @"repair_succeeded"],
                @"unsigned": @[@"daemon_protocol"],
                @"versions": @[@"daemon_build", @"daemon_marketing_version"],
                @"required": @[@"reason"]
            },
            @"block.apply_failed": blockApplyFields,
            @"block.strictify_result": @{
                @"enums": strictifyEnums,
                @"booleans": strictifyBooleans,
                @"unsigned": strictifyUnsigned,
                @"signed": blockApplyFields[@"signed"],
                @"required": strictifyRequired
            },
            @"block.teardown_failed": @{
                @"enums": @{@"layer": @[@"hosts", @"pf", @"apps", @"settings", @"launchd", @"unknown"]},
                @"booleans": @[@"hosts_removed", @"pf_removed", @"app_monitoring_stopped", @"settings_cleared", @"verified"],
                @"unsigned": @[@"duration_milliseconds"],
                @"signed": @[@"error_code"],
                @"required": @[@"layer", @"hosts_removed", @"pf_removed", @"app_monitoring_stopped",
                                 @"settings_cleared", @"verified", @"duration_milliseconds"]
            },
            @"tamper.no_block_found": @{
                @"enums": @{@"remnants": @[@"hosts", @"pf", @"apps", @"multiple", @"none"]},
                @"booleans": @[@"hosts_remnant", @"pf_remnant", @"app_monitoring", @"teardown_verified"],
                @"unsigned": @[@"settings_version"],
                @"required": @[@"remnants", @"hosts_remnant", @"pf_remnant", @"app_monitoring",
                                 @"teardown_verified", @"settings_version"]
            },
            @"xpc.auth_rejected": @{
                @"enums": @{@"command": @[@"start", @"update", @"register_schedule", @"unregister_schedule", @"clear_schedules", @"install", @"repair"]},
                @"booleans": @[@"user_cancelled"],
                @"signed": @[@"error_code"],
                @"required": @[@"command", @"user_cancelled", @"error_code"]
            },
            @"daemon.unreachable_reinstall": @{
                @"enums": @{
                    @"outcome": @[@"recovered", @"install_failed", @"post_repair_unreachable", @"post_repair_incompatible"],
                    @"initial_failure": @[@"connection", @"handshake", @"timeout", @"unknown"],
                    @"final_failure": @[@"none", @"authorization", @"install", @"connection", @"handshake", @"timeout", @"incompatible", @"unknown"]
                },
                @"booleans": @[@"installed_helper_present_before", @"installed_helper_present_after",
                                  @"bundled_helper_present", @"reinstall_attempted", @"reinstall_succeeded",
                                  @"reconnect_attempted", @"post_repair_handshake_succeeded",
                                  @"post_repair_compatible"],
                @"signed": @[@"initial_error_code", @"final_error_code"],
                @"required": @[@"outcome", @"initial_failure", @"final_failure",
                                 @"installed_helper_present_before", @"installed_helper_present_after",
                                 @"bundled_helper_present", @"reinstall_attempted", @"reinstall_succeeded",
                                 @"reconnect_attempted", @"post_repair_handshake_succeeded",
                                 @"post_repair_compatible", @"initial_error_code", @"final_error_code"]
            },
            @"xpc.connection_rejected": @{
                @"enums": @{
                    @"stage": @[@"guest_lookup", @"requirement_create", @"validity"],
                    @"client_id": @[@"app", @"cli", @"unknown"]
                },
                @"booleans": @[@"identifier_ok", @"team_ok", @"version_ok"],
                @"signed": @[@"os_status"],
                @"versions": @[@"client_version"],
                @"required": @[@"stage", @"client_id", @"identifier_ok", @"team_ok",
                                 @"version_ok", @"os_status", @"client_version"]
            },
            @"schedule.exec_failed": @{
                @"enums": @{@"path": @[@"cli_launchd", @"daemon_recovery", @"xpc_direct"]},
                @"booleans": @[@"block_already_running"],
                @"unsigned": @[@"minutes_late_bucket", @"approved_count", @"list_count"],
                @"signed": @[@"error_code"],
                @"required": @[@"path", @"block_already_running", @"minutes_late_bucket", @"approved_count",
                                 @"list_count", @"error_code"]
            },
            @"schedule.commit_install_failed": @{
                @"enums": @{@"stage": @[@"daemon_install", @"schedule_register", @"job_install", @"verification"]},
                @"unsigned": @[@"segments_planned", @"segments_installed", @"week_offset"],
                @"signed": @[@"error_code"],
                @"required": @[@"stage", @"segments_planned", @"segments_installed", @"week_offset", @"error_code"]
            },
            @"emergency.failed": @{
                @"enums": @{@"stage": @[@"credit", @"script_write", @"script_execute", @"verification"]},
                @"unsigned": @[@"credits_remaining"],
                @"signed": @[@"error_code"],
                @"required": @[@"stage", @"credits_remaining", @"error_code"]
            },
            @"emergency.unlock_result": @{
                @"enums": @{@"outcome": @[@"success", @"script_error", @"verify_failed"]},
                @"booleans": @[@"settings_cleared", @"hosts_clean", @"pf_check"],
                @"unsigned": @[@"credits_remaining", @"duration_milliseconds"],
                @"signed": @[@"apple_script_error_code"],
                @"required": @[@"outcome", @"credits_remaining", @"settings_cleared",
                                 @"hosts_clean", @"pf_check", @"duration_milliseconds"]
            },
            @"support.diagnostic_snapshot": @{
                @"enums": @{
                    @"collector_status": @[@"complete", @"partial", @"failed"],
                    @"projection_comparison_status": @[@"exact", @"unavailable", @"failed"],
                    @"last_strictify_outcome": @[@"none", @"verified", @"partial", @"failed", @"skipped"]
                },
                @"booleans": @[@"settings_available", @"block_running", @"app_has_schedule_state", @"legacy_domain_has_state",
                                 @"daemon_reachable", @"pf_active", @"hosts_active", @"app_monitoring",
                                 @"physical_layers_match", @"active_counts_match", @"approval_counts_match",
                                 @"plist_counts_match", @"job_counts_match",
                                 @"week_window_initialized", @"week_window_loaded", @"week_window_visible",
                                 @"ui_snapshot_available", @"ui_calendar_attached", @"ui_calendar_has_area",
                                 @"ui_empty_state_visible", @"ui_bundle_counts_match", @"ui_schedule_counts_match",
                                 @"ui_allow_block_counts_match", @"ui_block_geometry_counts_match",
                                 @"ui_block_appearance_counts_match", @"ui_visible_allow_block_counts_match",
                                 @"ui_render_objects_without_visible_blocks", @"ui_window_occlusion_visible",
                                 @"ui_empty_despite_model"],
                @"unsigned": @[@"app_bundle_count", @"app_week_count", @"app_commitment_count",
                                 @"daemon_active_entry_count", @"daemon_approval_count", @"daemon_approval_entry_count",
                                 @"daemon_plist_count", @"daemon_job_count",
                                 @"collector_error_count", @"daemon_protocol", @"raw_bundle_count",
                                 @"decoded_bundle_count", @"raw_schedule_count", @"decoded_schedule_count",
                                 @"active_expected_count", @"active_actual_count", @"active_missing_count", @"active_extra_count",
                                 @"approval_expected_count", @"approval_actual_count", @"approval_missing_count", @"approval_extra_count",
                                 @"plist_expected_count", @"plist_actual_count", @"plist_missing_count", @"plist_extra_count",
                                 @"loaded_job_expected_count", @"loaded_job_actual_count", @"loaded_job_missing_count", @"loaded_job_extra_count",
                                 @"launchd_probe_failure_count", @"invalid_approval_count", @"invalid_plist_count",
                                 @"expired_approval_count", @"in_progress_approval_count", @"in_progress_plist_count",
                                 @"selected_week_offset", @"ui_model_bundle_count", @"ui_model_schedule_count",
                                 @"ui_rendered_bundle_count", @"ui_rendered_schedule_count", @"ui_day_column_count",
                                 @"ui_expected_allow_block_count", @"ui_rendered_allow_block_count",
                                 @"ui_nonzero_area_allow_block_count", @"ui_intersecting_allow_block_count",
                                 @"ui_appearance_valid_allow_block_count", @"ui_visible_allow_block_count"],
                @"required": @[@"collector_status", @"projection_comparison_status", @"last_strictify_outcome",
                                 @"settings_available", @"block_running",
                                 @"app_has_schedule_state", @"legacy_domain_has_state", @"daemon_reachable",
                                 @"pf_active", @"hosts_active", @"app_monitoring", @"physical_layers_match",
                                 @"active_counts_match", @"approval_counts_match", @"plist_counts_match", @"job_counts_match",
                                 @"app_bundle_count",
                                 @"app_week_count", @"app_commitment_count", @"daemon_active_entry_count",
                                 @"daemon_approval_count", @"daemon_approval_entry_count", @"daemon_plist_count",
                                 @"daemon_job_count", @"collector_error_count", @"daemon_protocol",
                                 @"raw_bundle_count", @"decoded_bundle_count", @"raw_schedule_count", @"decoded_schedule_count",
                                 @"active_expected_count", @"active_actual_count", @"active_missing_count", @"active_extra_count",
                                 @"approval_expected_count", @"approval_actual_count", @"approval_missing_count", @"approval_extra_count",
                                 @"plist_expected_count", @"plist_actual_count", @"plist_missing_count", @"plist_extra_count",
                                 @"loaded_job_expected_count", @"loaded_job_actual_count", @"loaded_job_missing_count", @"loaded_job_extra_count",
                                 @"launchd_probe_failure_count", @"invalid_approval_count", @"invalid_plist_count",
                                 @"expired_approval_count", @"in_progress_approval_count", @"in_progress_plist_count",
                                 @"week_window_initialized", @"week_window_loaded", @"week_window_visible",
                                 @"ui_snapshot_available", @"ui_calendar_attached", @"ui_calendar_has_area",
                                 @"ui_empty_state_visible", @"ui_bundle_counts_match", @"ui_schedule_counts_match",
                                 @"ui_allow_block_counts_match", @"ui_block_geometry_counts_match",
                                 @"ui_block_appearance_counts_match", @"ui_visible_allow_block_counts_match",
                                 @"ui_render_objects_without_visible_blocks", @"ui_window_occlusion_visible",
                                 @"ui_empty_despite_model", @"selected_week_offset",
                                 @"ui_model_bundle_count", @"ui_model_schedule_count", @"ui_rendered_bundle_count",
                                 @"ui_rendered_schedule_count", @"ui_day_column_count", @"ui_expected_allow_block_count",
                                 @"ui_rendered_allow_block_count", @"ui_nonzero_area_allow_block_count",
                                 @"ui_intersecting_allow_block_count", @"ui_appearance_valid_allow_block_count",
                                 @"ui_visible_allow_block_count"]
            }
        };
    });
    return schemas;
}

static BOOL SCTelemetryNumberIsBoolean(NSNumber *number) {
    return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

static BOOL SCTelemetryNumberIsIntegerInRange(NSNumber *number, long long minimum, unsigned long long maximum) {
    if (![number isKindOfClass:[NSNumber class]] || SCTelemetryNumberIsBoolean(number)) return NO;
    double value = number.doubleValue;
    if (!isfinite(value) || floor(value) != value || value < (double)minimum || value > (double)maximum) return NO;
    return YES;
}

#if SENTRY_ENABLED
static BOOL SCSentrySDKStarted = NO;
static BOOL SCSentryLifecycleTransitionInProgress = NO;
static NSURLSession* SCSentryTransportSession = nil;
static atomic_bool SCSentryTransmissionAllowed = ATOMIC_VAR_INIT(false);
#endif

@interface SCSentry ()

+ (nullable NSString*)configuredSentryDSN;
+ (NSString*)safeComponentNameForIdentifier:(NSString*)componentId;
+ (NSString*)safeReleaseToken:(nullable id)value fallback:(NSString*)fallback;
+ (nullable NSString*)userCachesDirectory;
+ (nullable NSString*)dedicatedSentryCacheDirectoryPath;
+ (nullable NSString*)sha1ForString:(nullable NSString*)value;
+ (void)registerForConsentDefaultsChanges;
+ (BOOL)prepareDedicatedSentryCachePreservingConsentedData:(BOOL)preserveConsentedData;
+ (void)purgeDedicatedSentryCache;
+ (void)purgeLegacySentryDataForConfiguredDSN:(nullable NSString*)dsn;
+ (void)removeItemAtPathIfPresent:(nullable NSString*)path;
+ (void)activateSentryIfAllowed;
+ (void)deactivateSentryAndPurge;
+ (BOOL)transmissionAllowed;
+ (nullable NSString*)safeContextString:(nullable id)value;
+ (nullable NSString*)safeVersionString:(nullable id)value;
+ (NSUInteger)countForCollection:(nullable id)value;
+ (BOOL)payloadPassesTelemetryPrivacyTripwire:(nullable id)payload depth:(NSUInteger)depth;
+ (BOOL)isAllowlistedTelemetryMessage:(nullable NSString*)message;
+ (BOOL)isSentryReady;
+ (nullable NSString*)captureValidatedTelemetryEvent:(NSString*)eventName
                                               level:(SCTelemetryEventLevel)level
                                          safeFields:(NSDictionary<NSString*, id>*)safeFields
                                              origin:(NSString*)origin
                                             spooled:(BOOL)spooled
                                       stableEventID:(nullable NSString*)stableEventID
                               createdAtMilliseconds:(nullable NSNumber*)createdAtMilliseconds;

#if SENTRY_ENABLED
+ (BOOL)sentrySDKStarted;
+ (void)configurePrivacyBoundaryOnOptions:(SentryOptions*)options
                       transmissionAllowed:(BOOL (^)(void))transmissionAllowed;
+ (nullable SentryBreadcrumb*)sanitizedSentryBreadcrumb:(SentryBreadcrumb*)breadcrumb;
+ (void)sanitizeStacktrace:(nullable SentryStacktrace*)stacktrace;
+ (BOOL)sanitizeEventBeforeSend:(SentryEvent*)event;
#endif

@end

@implementation SCSentry

#pragma mark - Configuration

+ (BOOL)isValidSentryDSNString:(nullable NSString*)dsn {
    if (![dsn isKindOfClass:[NSString class]]) {
        return NO;
    }

    NSString* trimmed = [dsn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) {
        return NO;
    }

    NSString* lowercase = trimmed.lowercaseString;
    NSArray<NSString*>* placeholderMarkers = @[
        @"placeholder", @"change-me", @"changeme", @"your-sentry", @"your_sentry",
        @"$(sentry_dsn)", @"${sentry_dsn}", @"<sentry", @"example.com"
    ];
    for (NSString* marker in placeholderMarkers) {
        if ([lowercase containsString:marker]) {
            return NO;
        }
    }

    NSURLComponents* components = [NSURLComponents componentsWithString:trimmed];
    if (components == nil || ![components.scheme.lowercaseString isEqualToString:@"https"] ||
        components.user.length == 0 || components.host.length == 0 ||
        components.path.length <= 1 || components.query != nil || components.fragment != nil) {
        return NO;
    }

    // Never allow the accidentally shipped upstream SelfControl project back in,
    // even if it is supplied through an environment or plist override.
    if ([components.host.lowercaseString isEqualToString:SCLegacyUpstreamSentryHost]) {
        return NO;
    }

    return YES;
}

+ (nullable NSString*)configuredSentryDSN {
    id plistValue = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SentryDSN"];
    NSString* plistDSN = [plistValue isKindOfClass:[NSString class]] ? plistValue : nil;
    if ([self isValidSentryDSNString:plistDSN]) {
        return [plistDSN stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSString* environmentDSN = [NSProcessInfo processInfo].environment[@"SENTRY_DSN"];
    if ([self isValidSentryDSNString:environmentDSN]) {
        return [environmentDSN stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    return nil;
}

+ (NSString*)safeComponentNameForIdentifier:(NSString*)componentId {
    NSString* lowercase = componentId.lowercaseString;
    if ([lowercase containsString:@"selfcontrold"] || [lowercase containsString:@"daemon"]) {
        return @"daemon";
    }
    if ([lowercase containsString:@"cli"]) {
        return @"cli";
    }
    if ([lowercase containsString:@"killer"]) {
        return @"killer";
    }
    return @"app";
}

+ (NSString*)safeReleaseToken:(nullable id)value fallback:(NSString*)fallback {
    NSString* sanitized = [self safeContextString:value];
    return sanitized ?: fallback;
}

+ (BOOL)hasExplicitErrorReportingConsentInDefaults:(nullable NSDictionary<NSString*, id>*)defaults {
    NSDictionary *source = [defaults isKindOfClass:[NSDictionary class]] ? defaults : @{};
    id promptDismissed = source[SCErrorReportingPromptDismissedKey];
    id reportingEnabled = source[SCEnableErrorReportingKey];
    return [promptDismissed isKindOfClass:[NSNumber class]] && SCTelemetryNumberIsBoolean(promptDismissed) &&
           [promptDismissed boolValue] && [reportingEnabled isKindOfClass:[NSNumber class]] &&
           SCTelemetryNumberIsBoolean(reportingEnabled) && [reportingEnabled boolValue];
}

+ (BOOL)shouldInitializeSentryForRootProcess:(BOOL)isRootProcess
                               configuredDSN:(nullable NSString*)dsn
                                    defaults:(nullable NSDictionary<NSString*, id>*)defaults {
    return !isRootProcess && [self isValidSentryDSNString:dsn] &&
           [self hasExplicitErrorReportingConsentInDefaults:defaults];
}

+ (nullable NSString*)userCachesDirectory {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
}

+ (nullable NSString*)dedicatedSentryCacheDirectoryPathForCachesDirectory:(nullable NSString*)cachesDirectory {
    if (![cachesDirectory isKindOfClass:[NSString class]] || cachesDirectory.length == 0) {
        return nil;
    }
    return [[[[cachesDirectory stringByAppendingPathComponent:SCDedicatedSentryCacheScope]
              stringByAppendingPathComponent:@"Telemetry"]
             stringByAppendingPathComponent:@"SentrySDK"] stringByStandardizingPath];
}

+ (nullable NSString*)dedicatedSentryCacheDirectoryPath {
    return [self dedicatedSentryCacheDirectoryPathForCachesDirectory:[self userCachesDirectory]];
}

+ (nullable NSString*)sha1ForString:(nullable NSString*)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return nil;

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop

    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

+ (void)removeItemAtPathIfPresent:(nullable NSString*)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:path]) return;

    NSError *error = nil;
    if (![fileManager removeItemAtPath:path error:&error]) {
        NSLog(@"SCSentry: Failed to purge a telemetry cache item (domain=%@ code=%ld)",
              error.domain, (long)error.code);
    }
}

+ (void)purgeDedicatedSentryCache {
    [self removeItemAtPathIfPresent:[self dedicatedSentryCacheDirectoryPath]];
}

+ (void)purgeLegacySentryDataForConfiguredDSN:(nullable NSString*)dsn {
    NSString *cachesDirectory = [self userCachesDirectory];
    if (cachesDirectory == nil) return;

    // Old SDK versions used the shared user cache root. Remove only Fence's
    // known DSN subdirectories; never delete the shared io.sentry directory.
    NSMutableSet<NSString*> *dsnHashes = [NSMutableSet setWithObject:SCLegacyUpstreamSentryDSNHash];
    NSString *configuredHash = [self sha1ForString:dsn];
    if (configuredHash != nil) [dsnHashes addObject:configuredHash];
    for (NSString *hash in dsnHashes) {
        NSString *path = [[[cachesDirectory stringByAppendingPathComponent:@"io.sentry"]
                           stringByAppendingPathComponent:hash] stringByStandardizingPath];
        [self removeItemAtPathIfPresent:path];
    }

    // Static Sentry state was bundle-scoped even when envelope storage was not.
    for (NSString *bundleIdentifier in @[SCDedicatedSentryCacheScope, @"org.eyebeam.SelfControl"]) {
        NSString *path = [[[cachesDirectory stringByAppendingPathComponent:bundleIdentifier]
                           stringByAppendingPathComponent:@"io.sentry"] stringByStandardizingPath];
        [self removeItemAtPathIfPresent:path];
    }

    // SentryCrash also used the shared cache root but scoped reports by bundle
    // name. These are the two names shipped by Fence/SelfControl builds.
    for (NSString *bundleName in @[@"Fence", @"SelfControl"]) {
        NSString *path = [[[cachesDirectory stringByAppendingPathComponent:@"SentryCrash"]
                           stringByAppendingPathComponent:bundleName] stringByStandardizingPath];
        [self removeItemAtPathIfPresent:path];
    }
}

+ (BOOL)prepareDedicatedSentryCachePreservingConsentedData:(BOOL)preserveConsentedData {
    NSString *cachePath = [self dedicatedSentryCacheDirectoryPath];
    if (cachePath == nil) return NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *markerPath = [cachePath stringByAppendingPathComponent:SCDedicatedSentryCacheConsentMarker];
    NSDictionary *cacheAttributes = [fileManager attributesOfItemAtPath:cachePath error:nil];
    NSDictionary *markerAttributes = [fileManager attributesOfItemAtPath:markerPath error:nil];
    BOOL cacheIsDirectory = [cacheAttributes[NSFileType] isEqualToString:NSFileTypeDirectory];
    BOOL markerIsRegularFile = [markerAttributes[NSFileType] isEqualToString:NSFileTypeRegular];

    // A missing marker means the directory was not created by an explicitly
    // consented Fence SDK lifecycle. Never adopt its cached envelopes.
    if (!preserveConsentedData || (cacheAttributes != nil && (!cacheIsDirectory || !markerIsRegularFile))) {
        [self removeItemAtPathIfPresent:cachePath];
    }

    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:cachePath
                withIntermediateDirectories:YES
                                 attributes:@{NSFilePosixPermissions: @0700}
                                      error:&error]) {
        NSLog(@"SCSentry: Failed to create private telemetry cache (domain=%@ code=%ld)",
              error.domain, (long)error.code);
        return NO;
    }

    NSString *scopePath = [[self userCachesDirectory] stringByAppendingPathComponent:SCDedicatedSentryCacheScope];
    NSString *telemetryPath = [scopePath stringByAppendingPathComponent:@"Telemetry"];
    for (NSString *directory in @[scopePath, telemetryPath, cachePath]) {
        if (![fileManager setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:directory error:&error]) {
            NSLog(@"SCSentry: Failed to protect telemetry cache permissions (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
            return NO;
        }
    }

    if (![fileManager fileExistsAtPath:markerPath]) {
        NSData *marker = [@"explicit-consent-v1\n" dataUsingEncoding:NSUTF8StringEncoding];
        if (![marker writeToFile:markerPath options:NSDataWritingAtomic error:&error]) {
            NSLog(@"SCSentry: Failed to create telemetry consent marker (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
            [self removeItemAtPathIfPresent:cachePath];
            return NO;
        }
    }
    if (![fileManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:markerPath error:&error]) {
        NSLog(@"SCSentry: Failed to protect telemetry consent marker (domain=%@ code=%ld)",
              error.domain, (long)error.code);
        [self removeItemAtPathIfPresent:cachePath];
        return NO;
    }
    return YES;
}

+ (BOOL)transmissionAllowed {
#if SENTRY_ENABLED
    return geteuid() != 0 && atomic_load_explicit(&SCSentryTransmissionAllowed, memory_order_acquire) &&
           [self errorReportingEnabled];
#else
    return NO;
#endif
}

#if SENTRY_ENABLED
+ (void)configurePrivacyBoundaryOnOptions:(SentryOptions*)options
                       transmissionAllowed:(BOOL (^)(void))transmissionAllowed {
    // Privacy containment: retain explicit crash/error capture but turn off
    // every automatic high-volume or network-observing channel.
    options.sendDefaultPii = NO;
    options.sendClientReports = NO;
    options.enableNetworkBreadcrumbs = NO;
    options.enableNetworkTracking = NO;
    options.enableCaptureFailedRequests = NO;
    options.enablePropagateTraceparent = NO;
    options.tracePropagationTargets = @[];
    options.enableFileIOTracing = NO;
    options.enableDataSwizzling = NO;
    options.enableFileManagerSwizzling = NO;
    options.enableCoreDataTracing = NO;
    options.enableAppHangTracking = NO;
    options.enableWatchdogTerminationTracking = NO;
    options.enableMetricKit = NO;
    options.enableMetricKitRawPayload = NO;
    options.enableAutoSessionTracking = NO;
    options.enableAutoBreadcrumbTracking = NO;
    options.enableAutoPerformanceTracing = NO;
    options.tracesSampleRate = @0;
    options.enableLogs = NO;
    // These options are UIKit-only in Sentry 9.14 and therefore are not
    // declared on the macOS-generated Objective-C surface. Keep the boundary
    // explicit and future-safe if the SDK exposes them on macOS later.
    for (NSString *optionKey in @[@"attachScreenshot", @"attachViewHierarchy"]) {
        NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                                [[optionKey substringToIndex:1] uppercaseString],
                                [optionKey substringFromIndex:1]];
        if ([options respondsToSelector:NSSelectorFromString(setterName)]) {
            [options setValue:@NO forKey:optionKey];
        }
    }
    // Attachments are serialized after beforeSend and therefore cannot be
    // inspected by the final event tripwire. Fence has no attachment use case;
    // reject all non-empty attachments at envelope construction as a second
    // barrier behind the attachment-free public capture API.
    options.maxAttachmentSize = 0;

    BOOL (^gate)(void) = [transmissionAllowed copy];
    options.beforeBreadcrumb = ^SentryBreadcrumb * _Nullable(SentryBreadcrumb * _Nonnull breadcrumb) {
        if (gate == nil || !gate()) return nil;
        return [SCSentry sanitizedSentryBreadcrumb:breadcrumb];
    };

    options.beforeSend = ^SentryEvent * _Nullable(SentryEvent * _Nonnull event) {
        if (gate == nil || !gate()) return nil;
        return [SCSentry sanitizeEventBeforeSend:event] ? event : nil;
    };

    // Logs are disabled above. Keep an unconditional drop callback as a
    // second barrier if that SDK option changes accidentally later.
    options.beforeSendLog = ^SentryLog * _Nullable(__unused SentryLog * _Nonnull log) {
        return nil;
    };
}
#endif

+ (void)registerForConsentDefaultsChanges {
#if !defined(TESTING) && !defined(SC_SENTRY_SDK_PRIVACY_TEST)
    @synchronized (self) {
        if (SCSentryDefaultsObserver != nil) return;
        SCSentryDefaultsObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSUserDefaultsDidChangeNotification
                        object:[NSUserDefaults standardUserDefaults]
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            [SCSentry synchronizeErrorReportingLifecycle];
        }];
    }
#endif
}

+ (void)activateSentryIfAllowed {
#if SENTRY_ENABLED
    NSString *dsn = [self configuredSentryDSN];
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    if (![self shouldInitializeSentryForRootProcess:(geteuid() == 0)
                                      configuredDSN:dsn
                                           defaults:defaults]) {
        return;
    }

    @synchronized (self) {
        if (SCSentrySDKStarted || SCSentryLifecycleTransitionInProgress) return;
        SCSentryLifecycleTransitionInProgress = YES;
    }

    // Purge all paths used before this dedicated-consent cache before the SDK
    // can create a transport. Cached envelopes bypass beforeSend on startup.
    [self purgeLegacySentryDataForConfiguredDSN:dsn];
    if (![self prepareDedicatedSentryCachePreservingConsentedData:YES]) {
        @synchronized (self) {
            SCSentryLifecycleTransitionInProgress = NO;
        }
        return;
    }

    NSBundle* bundle = [NSBundle mainBundle];
    NSString* version = [self safeReleaseToken:[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
                                       fallback:SELFCONTROL_VERSION_STRING];
    NSString* build = [self safeReleaseToken:[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] fallback:@"0"];
    NSString* component = [self safeComponentNameForIdentifier:SCSentryComponentIdentifier ?: bundle.bundleIdentifier ?: @""];
    NSString* releaseName = [NSString stringWithFormat:@"fence-%@@%@+%@", component, version, build];

    NSURLSessionConfiguration *transportConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    transportConfiguration.URLCache = nil;
    transportConfiguration.HTTPCookieStorage = nil;
    transportConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *transportSession = [NSURLSession sessionWithConfiguration:transportConfiguration];

    @synchronized (self) {
        SCSentryTransportSession = transportSession;
        atomic_store_explicit(&SCSentryTransmissionAllowed, true, memory_order_release);
    }

    [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
        options.dsn = dsn;
        options.releaseName = releaseName;
        options.dist = build;
        options.cacheDirectoryPath = [SCSentry dedicatedSentryCacheDirectoryPath];
        options.urlSession = transportSession;
        options.shutdownTimeInterval = 0;
#if DEBUG
        options.environment = @"development";
#else
        options.environment = @"production";
#endif

        [SCSentry configurePrivacyBoundaryOnOptions:options transmissionAllowed:^BOOL{
            return [SCSentry transmissionAllowed];
        }];
    }];

    BOOL sdkStarted = SentrySDK.isEnabled;
    @synchronized (self) {
        SCSentrySDKStarted = sdkStarted;
        SCSentryLifecycleTransitionInProgress = NO;
        SCSentryDisabledCachesPurged = !sdkStarted;
        if (!sdkStarted) {
            atomic_store_explicit(&SCSentryTransmissionAllowed, false, memory_order_release);
            SCSentryTransportSession = nil;
        }
    }
    if (!sdkStarted) {
        [transportSession invalidateAndCancel];
        [self purgeDedicatedSentryCache];
        NSLog(@"SCSentry: SDK rejected the configured Fence DSN; telemetry remains disabled");
        return;
    }
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setUser:nil];
        [scope setExtras:nil];
        [scope setTagValue:component forKey:@"component"];
    }];
    // Sentry creates descendants itself. The 0700 parent remains the privacy
    // boundary even if an SDK file uses a more permissive creation mode.
    [self prepareDedicatedSentryCachePreservingConsentedData:YES];
#endif
}

+ (void)deactivateSentryAndPurge {
#if SENTRY_ENABLED
    __block BOOL wasStarted = NO;
    __block NSURLSession *transportSession = nil;
    @synchronized (self) {
        if (SCSentryLifecycleTransitionInProgress) return;
        SCSentryLifecycleTransitionInProgress = YES;
        atomic_store_explicit(&SCSentryTransmissionAllowed, false, memory_order_release);
        wasStarted = SCSentrySDKStarted;
        SCSentrySDKStarted = NO;
        transportSession = SCSentryTransportSession;
        SCSentryTransportSession = nil;
    }

    // SentrySDK.close flushes even with a zero timeout. Invalidate Fence's
    // dedicated ephemeral session first so neither cached nor in-memory
    // envelopes can create a network request during close.
    [transportSession invalidateAndCancel];
    [self purgeDedicatedSentryCache];
    [self purgeLegacySentryDataForConfiguredDSN:[self configuredSentryDSN]];
    if (wasStarted) [SentrySDK close];
    [self purgeDedicatedSentryCache];

    @synchronized (self) {
        SCSentryLifecycleTransitionInProgress = NO;
        SCSentryDisabledCachesPurged = YES;
    }
#else
    if (!SCSentryDisabledCachesPurged) {
        [self purgeDedicatedSentryCache];
        [self purgeLegacySentryDataForConfiguredDSN:[self configuredSentryDSN]];
        SCSentryDisabledCachesPurged = YES;
    }
#endif
}

+ (void)startSentry:(NSString*)componentId {
    if (geteuid() == 0) {
#if !defined(TESTING) && !defined(SC_SENTRY_SDK_PRIVACY_TEST)
        [self purgeLegacySentryDataForConfiguredDSN:[self configuredSentryDSN]];
#endif
        return;
    }

    @synchronized (self) {
        SCSentryComponentIdentifier = [componentId copy];
    }
#if !defined(TESTING) && !defined(SC_SENTRY_SDK_PRIVACY_TEST)
    [self registerForConsentDefaultsChanges];
    [self synchronizeErrorReportingLifecycle];
#endif
}

+ (void)synchronizeErrorReportingLifecycle {
#if defined(TESTING) || defined(SC_SENTRY_SDK_PRIVACY_TEST)
    return;
#else
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [SCSentry synchronizeErrorReportingLifecycle];
        });
        return;
    }

    NSString *dsn = [self configuredSentryDSN];
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    if ([self shouldInitializeSentryForRootProcess:(geteuid() == 0)
                                     configuredDSN:dsn
                                          defaults:defaults]) {
        [self activateSentryIfAllowed];
    } else {
#if SENTRY_ENABLED
        BOOL shouldPurge = NO;
        @synchronized (self) {
            shouldPurge = SCSentrySDKStarted || !SCSentryDisabledCachesPurged;
        }
        if (shouldPurge) [self deactivateSentryAndPurge];
#else
        if (!SCSentryDisabledCachesPurged) [self deactivateSentryAndPurge];
#endif
    }
#endif
}

+ (void)setUserErrorReportingEnabled:(BOOL)enabled {
    if (geteuid() == 0) return;
    @synchronized (self) {
        // NSUserDefaultsController bindings notify synchronously. Ignore the
        // callback caused by our own write so one user choice advances exactly
        // one generation and posts exactly one lifecycle notification.
        if (SCSentryConsentChoiceInProgress) return;
        SCSentryConsentChoiceInProgress = YES;
    }

    @try {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSInteger currentGeneration = [defaults integerForKey:SCTelemetryConsentGenerationDefaultsKey];
        NSInteger nextGeneration = currentGeneration <= 0 ? 1 :
            (currentGeneration < NSIntegerMax ? currentGeneration + 1 : NSIntegerMax);
        [defaults setBool:enabled forKey:SCEnableErrorReportingKey];
        [defaults setBool:YES forKey:SCErrorReportingPromptDismissedKey];
        [defaults setInteger:nextGeneration forKey:SCTelemetryConsentGenerationDefaultsKey];
        [defaults synchronize];
        [self synchronizeErrorReportingLifecycle];

        void (^postChange)(void) = ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:SCTelemetryConsentDidChangeNotification
                              object:SCSentry.class
                            userInfo:@{
                                @"enabled": @(enabled),
                                @"generation": @(nextGeneration),
                            }];
        };
        if ([NSThread isMainThread]) {
            postChange();
        } else {
            dispatch_sync(dispatch_get_main_queue(), postChange);
        }
    } @finally {
        @synchronized (self) {
            SCSentryConsentChoiceInProgress = NO;
        }
    }
}

#if SENTRY_ENABLED
+ (BOOL)sentrySDKStarted {
    @synchronized (self) {
        return SCSentrySDKStarted;
    }
}
#endif

+ (BOOL)isSentrySDKActive {
#if SENTRY_ENABLED
    return geteuid() != 0 && [self sentrySDKStarted] && [self transmissionAllowed];
#else
    return NO;
#endif
}

+ (void)flushWithTimeout:(NSTimeInterval)timeout completion:(void (^)(void))completion {
    void (^finishOnMainThread)(void) = ^{
        if (completion == nil) return;
        dispatch_async(dispatch_get_main_queue(), completion);
    };

    if (![self isSentryReady]) {
        finishOnMainThread();
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
#if SENTRY_ENABLED
        [SentrySDK flush:MAX(0, timeout)];
#else
        (void)timeout;
#endif
        finishOnMainThread();
    });
}

+ (BOOL)isSentryReady {
    return [self isSentrySDKActive];
}

#pragma mark - Consent

+ (BOOL)errorReportingEnabled {
    // SCSentry is the network boundary. Root components write only to the
    // daemon-owned local spool and can never transmit directly.
    if (geteuid() == 0) return NO;
    return [self hasExplicitErrorReportingConsentInDefaults:
            [[NSUserDefaults standardUserDefaults] dictionaryRepresentation]];
}

// Returns YES if the prompt enabled error reporting.
+ (BOOL)showErrorReportingPromptIfNeeded {
    // No UI in root processes, and do not ask for consent when this build has no
    // valid endpoint capable of using it.
    if (!geteuid()) return NO;
    if ([self configuredSentryDSN] == nil) return NO;
    if ([self errorReportingEnabled]) {
        [self synchronizeErrorReportingLifecycle];
        return NO;
    }

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:SCErrorReportingPromptDismissedKey]) {
        return NO;
    }

    if (![NSThread isMainThread]) {
        __block BOOL returnValue = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            returnValue = [SCSentry showErrorReportingPromptIfNeeded];
        });
        return returnValue;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Enable automatic error reporting", @"Title of error reporting prompt")];
    [alert setInformativeText:NSLocalizedString(@"Fence can automatically send bug reports to help us improve the software. All data is anonymized, your blocklist is never shared, and no identifying information is sent.", @"Message explaining error reporting")];
    [alert addButtonWithTitle:NSLocalizedString(@"Enable Error Reporting", @"Button to enable error reporting")];
    [alert addButtonWithTitle:NSLocalizedString(@"Don't Send Reports", @"Button to decline error reporting")];

    NSModalResponse modalResponse = [alert runModal];
    if (modalResponse == NSAlertFirstButtonReturn) {
        [self setUserErrorReportingEnabled:YES];
        return [self errorReportingEnabled];
    }
    if (modalResponse == NSAlertSecondButtonReturn) {
        [self setUserErrorReportingEnabled:NO];
    }

    return NO;
}

#pragma mark - Pure privacy sanitizers

+ (NSUInteger)countForCollection:(nullable id)value {
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]] ||
        [value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) {
        return [value count];
    }
    return 0;
}

+ (nullable NSString*)safeContextString:(nullable id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString* string = (NSString*)value;
    if (string.length == 0 || string.length > 128) {
        return nil;
    }

    NSMutableCharacterSet* allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._+- ()"];
    if ([string rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        return nil;
    }
    return string;
}

+ (nullable NSString*)safeVersionString:(nullable id)value {
    NSString *string = [self safeContextString:value];
    if (string.length == 0 || string.length > 64) return nil;
    unichar firstCharacter = [string characterAtIndex:0];
    return [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:firstCharacter] ? string : nil;
}

static NSNumber *SCBooleanForBlockApplyStatus(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    if ([value isEqualToString:@"succeeded"]) return @YES;
    if ([value isEqualToString:@"failed"] || [value isEqualToString:@"not_attempted"]) return @NO;
    return nil;
}

+ (nullable NSDictionary<NSString*, id>*)telemetryFieldsForBlockApplyResultDictionary:(nullable NSDictionary<NSString*, id>*)applyResult
                                                                          eventName:(NSString*)eventName
                                                                 supplementalFields:(nullable NSDictionary<NSString*, id>*)supplementalFields {
    if (![applyResult isKindOfClass:[NSDictionary class]] ||
        (supplementalFields != nil && ![supplementalFields isKindOfClass:[NSDictionary class]]) ||
        (! [eventName isEqualToString:@"block.apply_failed"] &&
         ! [eventName isEqualToString:@"block.strictify_result"])) {
        return nil;
    }

    NSNumber *schemaVersion = [applyResult[@"schema_version"] isKindOfClass:[NSNumber class]] ? applyResult[@"schema_version"] : nil;
    NSString *status = [applyResult[@"status"] isKindOfClass:[NSString class]] ? applyResult[@"status"] : nil;
    if (schemaVersion.integerValue != 1 ||
        (! [status isEqualToString:@"succeeded"] && ! [status isEqualToString:@"failed"])) {
        return nil;
    }

    NSDictionary *entries = [applyResult[@"entries"] isKindOfClass:[NSDictionary class]] ? applyResult[@"entries"] : nil;
    NSDictionary *hosts = [applyResult[@"hosts"] isKindOfClass:[NSDictionary class]] ? applyResult[@"hosts"] : nil;
    NSDictionary *packetFilter = [applyResult[@"packet_filter"] isKindOfClass:[NSDictionary class]] ? applyResult[@"packet_filter"] : nil;
    NSDictionary *apps = [applyResult[@"apps"] isKindOfClass:[NSDictionary class]] ? applyResult[@"apps"] : nil;
    if (entries == nil || hosts == nil || packetFilter == nil || apps == nil) return nil;

    NSString *operation = [applyResult[@"operation"] isKindOfClass:[NSString class]] ? applyResult[@"operation"] : nil;
    if ([operation isEqualToString:@"integrity"]) operation = @"integrity_reapply";
    if ([eventName isEqualToString:@"block.strictify_result"]) operation = @"strictify";

    NSString *pfCommand = [packetFilter[@"command"] isKindOfClass:[NSString class]] ? packetFilter[@"command"] : @"none";
    if ([pfCommand isEqualToString:@"start"]) pfCommand = @"load";

    NSNumber *hostsReady = SCBooleanForBlockApplyStatus(hosts[@"ready"]);
    NSNumber *hostsWrite = SCBooleanForBlockApplyStatus(hosts[@"write"]);
    NSNumber *hostsVerify = SCBooleanForBlockApplyStatus(hosts[@"verify"]);
    NSNumber *pfAnchorOpen = SCBooleanForBlockApplyStatus(packetFilter[@"anchor_open"]);
    NSNumber *pfAnchorWrite = SCBooleanForBlockApplyStatus(packetFilter[@"anchor_write"]);
    NSNumber *pfMainWrite = SCBooleanForBlockApplyStatus(packetFilter[@"main_config_write"]);
    NSNumber *pfVerify = SCBooleanForBlockApplyStatus(packetFilter[@"verify"]);
    if (operation == nil || hostsReady == nil || hostsWrite == nil || hostsVerify == nil ||
        pfAnchorOpen == nil || pfAnchorWrite == nil || pfMainWrite == nil || pfVerify == nil) {
        return nil;
    }

    NSMutableDictionary<NSString*, id> *flat = [NSMutableDictionary dictionaryWithDictionary:supplementalFields ?: @{}];
    [flat addEntriesFromDictionary:@{
        @"operation": operation,
        @"pf_command": pfCommand,
        @"duration_milliseconds": applyResult[@"duration_ms"] ?: [NSNull null],
        @"input_entry_count": entries[@"input_count"] ?: [NSNull null],
        @"valid_entry_count": entries[@"valid_count"] ?: [NSNull null],
        @"rejected_entry_count": entries[@"rejected_count"] ?: [NSNull null],
        @"unapplied_entry_count": entries[@"unapplied_count"] ?: [NSNull null],
        @"app_entry_count": entries[@"app_count"] ?: [NSNull null],
        @"site_entry_count": entries[@"site_count"] ?: [NSNull null],
        @"dns_lookup_count": entries[@"dns_lookup_count"] ?: [NSNull null],
        @"dns_resolved_host_count": entries[@"dns_resolved_host_count"] ?: [NSNull null],
        @"dns_resolved_address_count": entries[@"dns_resolved_address_count"] ?: [NSNull null],
        @"dns_failure_count": entries[@"dns_failure_count"] ?: [NSNull null],
        @"hosts_ready": hostsReady,
        @"hosts_write_succeeded": hostsWrite,
        @"hosts_verification_succeeded": hostsVerify,
        @"pf_anchor_open_succeeded": pfAnchorOpen,
        @"pf_anchor_write_succeeded": pfAnchorWrite,
        @"pf_main_configuration_write_succeeded": pfMainWrite,
        @"pf_verification_succeeded": pfVerify,
        @"pf_exit_code": packetFilter[@"exit_code"] ?: @0,
        @"blocked_app_count": apps[@"blocked_count"] ?: [NSNull null],
        @"app_monitoring_before": apps[@"monitoring_before"] ?: [NSNull null],
        @"app_monitoring_after": apps[@"monitoring_after"] ?: [NSNull null],
        @"app_kill_attempt_count": apps[@"kill_attempt_count"] ?: [NSNull null],
        @"app_terminate_success_count": apps[@"terminate_success_count"] ?: [NSNull null],
        @"app_force_kill_count": apps[@"force_kill_count"] ?: [NSNull null],
        @"app_kill_failure_count": apps[@"kill_failure_count"] ?: [NSNull null],
    }];

    NSDictionary<NSString*, NSString*> *optionalErrorMappings = @{
        @"hosts_error_code": @"hosts.error_code",
        @"pf_error_code": @"packet_filter.error_code",
        @"app_scan_error_code": @"apps.scan_error_code",
        @"app_kill_error_code": @"apps.kill_error_code",
    };
    for (NSString *destinationKey in optionalErrorMappings) {
        NSArray<NSString*> *pathComponents = [optionalErrorMappings[destinationKey] componentsSeparatedByString:@"."];
        NSDictionary *container = [pathComponents.firstObject isEqualToString:@"hosts"] ? hosts :
                                  ([pathComponents.firstObject isEqualToString:@"packet_filter"] ? packetFilter : apps);
        id value = container[pathComponents.lastObject];
        if (value != nil) flat[destinationKey] = value;
    }

    return [self sanitizedTelemetryFields:flat forEventName:eventName];
}

+ (nullable NSDictionary<NSString*, id>*)sanitizedTelemetryFields:(nullable NSDictionary<NSString*, id>*)fields
                                                      forEventName:(NSString*)eventName {
    NSDictionary<NSString*, id> *schema = SCTelemetryEventSchemas()[eventName];
    if (schema == nil || (fields != nil && ![fields isKindOfClass:[NSDictionary class]])) {
        return nil;
    }

    NSDictionary<NSString*, id> *source = fields ?: @{};
    // Typed schemas still reject every unknown key below. Keep a separate,
    // bounded scalar-field ceiling that is large enough for the intentionally
    // dense support snapshot while preventing arbitrary payload growth.
    if (source.count > 96) return nil;

    NSArray<NSString*> *requiredKeys = schema[@"required"] ?: @[];
    for (NSString *requiredKey in requiredKeys) {
        if (source[requiredKey] == nil || source[requiredKey] == [NSNull null]) {
            return nil;
        }
    }

    NSDictionary<NSString*, NSArray<NSString*>*> *enumRules = schema[@"enums"] ?: @{};
    NSSet<NSString*> *booleanRules = [NSSet setWithArray:schema[@"booleans"] ?: @[]];
    NSSet<NSString*> *unsignedRules = [NSSet setWithArray:schema[@"unsigned"] ?: @[]];
    NSSet<NSString*> *signedRules = [NSSet setWithArray:schema[@"signed"] ?: @[]];
    NSSet<NSString*> *versionRules = [NSSet setWithArray:schema[@"versions"] ?: @[]];
    NSMutableDictionary<NSString*, id> *safe = [NSMutableDictionary dictionaryWithCapacity:source.count];

    for (id candidateKey in source) {
        if (![candidateKey isKindOfClass:[NSString class]]) return nil;
        NSString *key = (NSString*)candidateKey;
        id value = source[key];

        NSArray<NSString*> *allowedEnumValues = enumRules[key];
        if (allowedEnumValues != nil) {
            if (![value isKindOfClass:[NSString class]] || ![allowedEnumValues containsObject:value]) return nil;
            safe[key] = value;
            continue;
        }

        if ([booleanRules containsObject:key]) {
            if (![value isKindOfClass:[NSNumber class]] || !SCTelemetryNumberIsBoolean(value)) return nil;
            safe[key] = value;
            continue;
        }

        if ([unsignedRules containsObject:key]) {
            if (!SCTelemetryNumberIsIntegerInRange(value, 0, 1000000000ULL)) return nil;
            safe[key] = value;
            continue;
        }

        if ([signedRules containsObject:key]) {
            if (!SCTelemetryNumberIsIntegerInRange(value, -1000000000LL, 1000000000ULL)) return nil;
            safe[key] = value;
            continue;
        }

        if ([versionRules containsObject:key]) {
            NSString *safeVersion = [self safeVersionString:value];
            if (safeVersion == nil) return nil;
            safe[key] = safeVersion;
            continue;
        }

        // Unknown keys are a schema error, not something to forward or silently
        // accept. This catches misspelled metrics before they create false data.
        return nil;
    }

    return [safe copy];
}

+ (nullable NSString*)privacySafeTelemetrySignatureForFields:(nullable NSDictionary<NSString*, id>*)fields
                                                    eventName:(NSString*)eventName {
    NSDictionary<NSString *, id> *safeFields = [self sanitizedTelemetryFields:fields
                                                                  forEventName:eventName];
    if (safeFields == nil || ![NSJSONSerialization isValidJSONObject:safeFields]) return nil;

    NSError *serializationError = nil;
    NSData *serialized = [NSJSONSerialization dataWithJSONObject:safeFields
                                                         options:NSJSONWritingSortedKeys
                                                           error:&serializationError];
    if (serialized == nil || serializationError != nil) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(serialized.bytes, (CC_LONG)serialized.length, digest);
    NSMutableString *signature = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [signature appendFormat:@"%02x", digest[index]];
    }
    return [signature copy];
}

+ (BOOL)shouldEmitTelemetrySignature:(nullable NSString*)signature
                   previousSignature:(nullable NSString*)previousSignature
                previousEmissionDate:(nullable NSDate*)previousEmissionDate
                                 now:(NSDate*)now
                 suppressionInterval:(NSTimeInterval)suppressionInterval {
    if (signature.length == 0 || ![now isKindOfClass:[NSDate class]] ||
        !isfinite(suppressionInterval) || suppressionInterval <= 0) return NO;
    if (![previousSignature isKindOfClass:[NSString class]] ||
        ![signature isEqualToString:previousSignature]) return YES;
    if (![previousEmissionDate isKindOfClass:[NSDate class]]) return YES;

    NSTimeInterval elapsed = [now timeIntervalSinceDate:previousEmissionDate];
    // A clock rollback invalidates the old window instead of suppressing for
    // an unbounded duration.
    return elapsed < 0 || elapsed >= suppressionInterval;
}

+ (nullable NSDictionary<NSString*, id>*)sanitizedSpooledTelemetryRecord:(nullable NSDictionary<NSString*, id>*)record {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;

    NSSet<NSString*> *expectedKeys = [NSSet setWithArray:@[
        @"id", @"schema_version", @"event_name", @"level", @"origin", @"created_at_ms", @"fields"
    ]];
    if (![[NSSet setWithArray:record.allKeys] isEqualToSet:expectedKeys]) return nil;

    NSString *recordID = [record[@"id"] isKindOfClass:[NSString class]] ? record[@"id"] : nil;
    NSNumber *schemaVersion = [record[@"schema_version"] isKindOfClass:[NSNumber class]] ? record[@"schema_version"] : nil;
    NSString *eventName = [record[@"event_name"] isKindOfClass:[NSString class]] ? record[@"event_name"] : nil;
    NSString *level = [record[@"level"] isKindOfClass:[NSString class]] ? record[@"level"] : nil;
    NSString *origin = [record[@"origin"] isKindOfClass:[NSString class]] ? record[@"origin"] : nil;
    NSNumber *createdAtMilliseconds = [record[@"created_at_ms"] isKindOfClass:[NSNumber class]] ? record[@"created_at_ms"] : nil;
    NSDictionary *fields = [record[@"fields"] isKindOfClass:[NSDictionary class]] ? record[@"fields"] : nil;

    NSUUID *parsedRecordID = [[NSUUID alloc] initWithUUIDString:recordID];
    NSUUID *zeroRecordID = [[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000000"];
    if (parsedRecordID == nil || [parsedRecordID isEqual:zeroRecordID] ||
        !SCTelemetryNumberIsIntegerInRange(schemaVersion, 1, 1) ||
        ![@[@"info", @"warning", @"error"] containsObject:level] ||
        ![@[@"daemon", @"cli", @"app"] containsObject:origin] ||
        !SCTelemetryNumberIsIntegerInRange(createdAtMilliseconds, 0, 9007199254740991ULL) ||
        eventName == nil || fields == nil) {
        return nil;
    }

    NSDictionary *safeFields = [self sanitizedTelemetryFields:fields forEventName:eventName];
    if (safeFields == nil || ![safeFields isEqualToDictionary:fields]) return nil;

    NSDictionary<NSString*, id> *safeRecord = @{
        @"id": recordID.lowercaseString,
        @"schema_version": @1,
        @"event_name": eventName,
        @"level": level,
        @"origin": origin,
        @"created_at_ms": createdAtMilliseconds,
        @"fields": safeFields,
    };
    return [self payloadPassesTelemetryPrivacyTripwire:safeRecord] ? safeRecord : nil;
}

+ (BOOL)isAllowlistedTelemetryMessage:(nullable NSString*)message {
    if (![message isKindOfClass:[NSString class]]) return NO;
    if (SCTelemetryEventSchemas()[message] != nil) return YES;

    static NSSet<NSString*> *legacyStaticMessages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        legacyStaticMessages = [NSSet setWithArray:@[
            @"User manually cleared SelfControl block from the timer window",
            @"User manually cleared SelfControl block from the SelfControl Killer app",
            @"Checkup ran and no active block found! Removing block, tampering suspected...",
            @"Unsupported operating system version"
        ]];
    });
    return [legacyStaticMessages containsObject:message];
}

+ (BOOL)payloadPassesTelemetryPrivacyTripwire:(nullable id)payload {
    return [self payloadPassesTelemetryPrivacyTripwire:payload depth:0];
}

+ (BOOL)payloadPassesTelemetryPrivacyTripwire:(nullable id)payload depth:(NSUInteger)depth {
    if (depth > 16) return NO;
    if (payload == nil || payload == [NSNull null] ||
        [payload isKindOfClass:[NSNumber class]]) return YES;

    if ([payload isKindOfClass:[NSString class]]) {
        NSString *string = (NSString*)payload;
        if (string.length > 8192) return NO;
        NSString *lowercase = string.lowercaseString;
        NSArray<NSString*> *forbiddenFragments = @[
            @"canary-telemetry-test.example", @"/users/", @"/home/", @"file://", @"mailto:",
            @"authorizationexternalform", @"fencelicensecode", @"deviceidentifierfallback"
        ];
        for (NSString *fragment in forbiddenFragments) {
            if ([lowercase containsString:fragment]) return NO;
        }
        if ([lowercase hasPrefix:@"app:"]) return NO;

        static NSRegularExpression *emailExpression;
        static NSRegularExpression *licenseExpression;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            emailExpression = [NSRegularExpression regularExpressionWithPattern:@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
            licenseExpression = [NSRegularExpression regularExpressionWithPattern:@"FENCE-[A-Z0-9+/=]{20,}"
                                                                          options:NSRegularExpressionCaseInsensitive
                                                                            error:nil];
        });
        NSRange fullRange = NSMakeRange(0, string.length);
        if ([emailExpression firstMatchInString:string options:0 range:fullRange] != nil ||
            [licenseExpression firstMatchInString:string options:0 range:fullRange] != nil) {
            return NO;
        }
        return YES;
    }

    if ([payload isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray*)payload;
        if (array.count > 2048) return NO;
        for (id value in array) {
            if (![self payloadPassesTelemetryPrivacyTripwire:value depth:depth + 1]) return NO;
        }
        return YES;
    }

    if ([payload isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary*)payload;
        if (dictionary.count > 512) return NO;
        for (id candidateKey in dictionary) {
            if (![candidateKey isKindOfClass:[NSString class]]) return NO;
            NSString *key = [(NSString*)candidateKey lowercaseString];
            BOOL isStructuralMetric = [key containsString:@"count"] || [key containsString:@"delta"] ||
                                      [key containsString:@"match"] || [key containsString:@"state"] ||
                                      [key containsString:@"present"] || [key containsString:@"valid"] ||
                                      [key containsString:@"succeeded"] || [key containsString:@"verified"];
            NSArray<NSString*> *forbiddenKeyFragments = @[
                @"license", @"authorization", @"authdata", @"deviceidentifier", @"device_app_hash",
                @"email", @"username", @"user_id", @"request", @"query"
            ];
            for (NSString *fragment in forbiddenKeyFragments) {
                if ([key containsString:fragment] && !isStructuralMetric) return NO;
            }
            if (([key isEqualToString:@"blocklist"] || [key isEqualToString:@"activeblocklist"] ||
                 [key isEqualToString:@"approvedschedules"] || [key isEqualToString:@"entries"] ||
                 [key isEqualToString:@"bundleid"] || [key isEqualToString:@"controllinguid"]) &&
                !isStructuralMetric) {
                return NO;
            }
            if (![self payloadPassesTelemetryPrivacyTripwire:dictionary[candidateKey] depth:depth + 1]) return NO;
        }
        return YES;
    }

    // NSData, NSDate, custom objects, and other non-JSON values are never valid
    // at the final transport boundary.
    return NO;
}

+ (NSError*)sanitizedError:(NSError*)error {
    NSString* domain = [self safeContextString:error.domain] ?: @"UnknownErrorDomain";
    return [NSError errorWithDomain:domain code:error.code userInfo:nil];
}

+ (NSDictionary<NSString*, id>*)sanitizedDefaultsContextFromDictionary:(nullable NSDictionary<NSString*, id>*)defaults {
    NSDictionary* source = [defaults isKindOfClass:[NSDictionary class]] ? defaults : @{};
    NSMutableDictionary<NSString*, id>* safe = [NSMutableDictionary dictionary];

    NSArray<NSString*>* booleanKeys = @[
        @"BlockAsWhitelist", @"HighlightInvalidHosts", @"VerifyInternetConnection",
        @"TimerWindowFloats", @"BadgeApplicationIcon", @"WhitelistAlertSuppress",
        @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay",
        @"ClearCaches", @"AllowLocalNetworks", @"EnableErrorReporting",
        @"ErrorReportingPromptDismissed", @"SuppressLongBlockWarning",
        @"SuppressRestartFirefoxWarning", @"FirstBlockStarted", @"V4MigrationComplete",
        @"SafetyCheckCompleted", @"SCTestBlock_Completed", @"SCHasEverCommitted",
        @"SCEmergencyUnlockCreditsInitialized", @"SCIsCommitted",
        @"SCRepairMigrationPER352CreditsApplied"
    ];
    for (NSString* key in booleanKeys) {
        id value = source[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            safe[key] = @([value boolValue]);
        }
    }

    NSArray<NSString*>* numericKeys = @[@"BlockDuration", @"MaxBlockLength", @"BlockSound"];
    for (NSString* key in numericKeys) {
        id value = source[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            safe[key] = value;
        }
    }

    id credits = source[@"SCEmergencyUnlockCredits"];
    if ([credits isKindOfClass:[NSNumber class]]) {
        safe[@"EmergencyUnlockCreditsCount"] = @(MAX(0, [credits integerValue]));
    }

    NSArray<NSString*>* versionKeys = @[
        @"SCSafetyCheck_LastTestedAppVersion", @"SCSafetyCheck_LastTestedOSVersion",
        @"LastTestedAppVersion", @"SCRepairMigrationPER352AuthRefreshBuild"
    ];
    for (NSString* key in versionKeys) {
        NSString* value = [self safeContextString:source[key]];
        if (value != nil) {
            safe[key] = value;
        }
    }

    safe[@"BlocklistCount"] = @([self countForCollection:source[@"Blocklist"]]);
    safe[@"BundlesCount"] = @([self countForCollection:source[@"SCScheduleBundles"]]);

    NSUInteger weekScheduleKeyCount = 0;
    NSUInteger weekScheduleEntryCount = 0;
    NSUInteger commitmentWeekCount = 0;
    for (id candidateKey in source) {
        if (![candidateKey isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString* key = (NSString*)candidateKey;
        if ([key hasPrefix:@"SCWeekSchedules_"]) {
            weekScheduleKeyCount += 1;
            weekScheduleEntryCount += [self countForCollection:source[key]];
        } else if ([key hasPrefix:@"SCWeekCommitment_"]) {
            commitmentWeekCount += 1;
        }
    }
    safe[@"WeekScheduleKeyCount"] = @(weekScheduleKeyCount);
    safe[@"WeekScheduleEntryCount"] = @(weekScheduleEntryCount);
    safe[@"CommitmentWeekCount"] = @(commitmentWeekCount);
    safe[@"HasWeekCommitment"] = @(commitmentWeekCount > 0);

    return safe;
}

+ (NSDictionary<NSString*, id>*)sanitizedSettingsContextFromDictionary:(nullable NSDictionary<NSString*, id>*)settings {
    NSDictionary* source = [settings isKindOfClass:[NSDictionary class]] ? settings : @{};
    NSMutableDictionary<NSString*, id>* safe = [NSMutableDictionary dictionary];

    NSArray<NSString*>* booleanKeys = @[
        @"BlockIsRunning", @"ActiveBlockAsWhitelist", @"TamperingDetected",
        @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay",
        @"ClearCaches", @"AllowLocalNetworks", @"EnableErrorReporting", @"IsTestBlock",
        @"DebugBlockingDisabled"
    ];
    for (NSString* key in booleanKeys) {
        id value = source[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            safe[key] = @([value boolValue]);
        }
    }

    NSArray<NSString*>* numericKeys = @[@"BlockSound", @"SettingsVersionNumber"];
    for (NSString* key in numericKeys) {
        id value = source[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            safe[key] = value;
        }
    }

    id activeBlocklist = source[@"ActiveBlocklist"];
    safe[@"ActiveBlocklistCount"] = @([self countForCollection:activeBlocklist]);
    safe[@"ActiveBlocklistTypeValid"] = @([activeBlocklist isKindOfClass:[NSArray class]]);

    id approvedValue = source[@"ApprovedSchedules"];
    NSDictionary* approvedSchedules = [approvedValue isKindOfClass:[NSDictionary class]] ? approvedValue : nil;
    safe[@"ApprovedSchedulesCount"] = @(approvedSchedules.count);
    safe[@"ApprovedSchedulesTypeValid"] = @(approvedValue == nil || approvedSchedules != nil);

    NSUInteger approvedEntryCount = 0;
    NSUInteger approvedAllowlistCount = 0;
    for (id scheduleValue in approvedSchedules.allValues) {
        if (![scheduleValue isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary* schedule = (NSDictionary*)scheduleValue;
        approvedEntryCount += [self countForCollection:schedule[@"blocklist"]];
        if ([schedule[@"isAllowlist"] isKindOfClass:[NSNumber class]] && [schedule[@"isAllowlist"] boolValue]) {
            approvedAllowlistCount += 1;
        }
    }
    safe[@"ApprovedScheduleEntryCount"] = @(approvedEntryCount);
    safe[@"ApprovedAllowlistScheduleCount"] = @(approvedAllowlistCount);

    id blockEndDate = source[@"BlockEndDate"];
    NSString* blockEndState = @"missing";
    if ([blockEndDate isKindOfClass:[NSDate class]]) {
        blockEndState = [(NSDate*)blockEndDate timeIntervalSinceNow] > 0 ? @"future" : @"past";
    } else if (blockEndDate != nil && blockEndDate != [NSNull null]) {
        blockEndState = @"invalid";
    }
    safe[@"BlockEndDateState"] = blockEndState;
    safe[@"LastSettingsUpdatePresent"] = @([source[@"LastSettingsUpdate"] isKindOfClass:[NSDate class]]);

    return safe;
}

+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)sanitizedEventContextsFromDictionary:(nullable NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)contexts {
    NSDictionary* source = [contexts isKindOfClass:[NSDictionary class]] ? contexts : @{};
    NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* safe = [NSMutableDictionary dictionary];

    NSDictionary* app = [source[@"app"] isKindOfClass:[NSDictionary class]] ? source[@"app"] : nil;
    if (app != nil) {
        NSMutableDictionary* safeApp = [NSMutableDictionary dictionary];
        for (NSString* key in @[@"app_identifier", @"app_version", @"app_build", @"build_type"]) {
            NSString* value = [self safeContextString:app[key]];
            if (value != nil) safeApp[key] = value;
        }
        if (safeApp.count > 0) safe[@"app"] = safeApp;
    }

    NSDictionary* os = [source[@"os"] isKindOfClass:[NSDictionary class]] ? source[@"os"] : nil;
    if (os != nil) {
        NSMutableDictionary* safeOS = [NSMutableDictionary dictionary];
        for (NSString* key in @[@"name", @"version", @"build"]) {
            NSString* value = [self safeContextString:os[key]];
            if (value != nil) safeOS[key] = value;
        }
        if (safeOS.count > 0) safe[@"os"] = safeOS;
    }

    NSDictionary* defaults = [source[@"NSUserDefaults"] isKindOfClass:[NSDictionary class]] ? source[@"NSUserDefaults"] : nil;
    if (defaults != nil) {
        safe[@"NSUserDefaults"] = [self sanitizedDefaultsContextFromDictionary:defaults];
    }

    NSDictionary* settings = [source[@"SCSettings"] isKindOfClass:[NSDictionary class]] ? source[@"SCSettings"] : nil;
    if (settings != nil) {
        safe[@"SCSettings"] = [self sanitizedSettingsContextFromDictionary:settings];
    }

    NSDictionary *diagnostic = [source[@"diagnostic"] isKindOfClass:[NSDictionary class]] ? source[@"diagnostic"] : nil;
    NSString *eventName = [diagnostic[@"event_name"] isKindOfClass:[NSString class]] ? diagnostic[@"event_name"] : nil;
    NSDictionary *diagnosticFields = [diagnostic[@"fields"] isKindOfClass:[NSDictionary class]] ? diagnostic[@"fields"] : nil;
    NSDictionary *safeDiagnosticFields = eventName == nil ? nil : [self sanitizedTelemetryFields:diagnosticFields
                                                                                           forEventName:eventName];
    if (safeDiagnosticFields != nil) {
        safe[@"diagnostic"] = @{
            @"event_name": eventName,
            @"fields": safeDiagnosticFields
        };
    }

    return safe;
}

+ (nullable NSDictionary<NSString*, NSString*>*)sanitizedBreadcrumbWithMessage:(nullable NSString*)message
                                                                        category:(nullable NSString*)category {
    if (![message isKindOfClass:[NSString class]] || ![category isKindOfClass:[NSString class]]) {
        return nil;
    }

    if ([category isEqualToString:@"appblocker"]) {
        return @{@"category": @"appblocker", @"message": @"Blocked app termination attempted"};
    }

    if ([category isEqualToString:@"settings"]) {
        if ([message hasPrefix:@"Failed to create directory for SCSettings with error "]) {
            return @{@"category": @"settings", @"message": @"Failed to create directory for SCSettings"};
        }
        if ([message hasPrefix:@"Failed to set directory permissions for SCSettings with error "]) {
            return @{@"category": @"settings", @"message": @"Failed to set directory permissions for SCSettings"};
        }
    }

    static NSDictionary<NSString*, NSSet<NSString*>*>* allowedMessagesByCategory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedMessagesByCategory = @{
            @"app": [NSSet setWithArray:@[
                @"Block ended and timer window is closing",
                @"Received configuration changed notification",
                @"Opening preferences window",
                @"Detected out-of-date daemon",
                @"Detected up-to-date daemon",
                @"Reinstalling daemon",
                @"Daemon reinstalled successfully",
                @"Showing domain list",
                @"App running installBlock method",
                @"Daemon installed successfully (en route to installing block)",
                @"Block started successfully",
                @"App running updateActiveBlocklist method",
                @"Blocklist updated successfully",
                @"App running updateBlockEndDate method",
                @"App extended block duration successfully",
                @"Saved blocklist to file",
                @"Opened blocklist from file",
                @"Opened Fence FAQ",
                @"Opened Fence Support Hub",
                @"Exporting logs for support",
                @"Opening Week Schedule window"
            ]],
            @"settings": [NSSet setWithArray:@[
                @"Initialized SCSettings to default settings",
                @"Initialized SCSettings to safe in-memory defaults",
                @"Updated SCSettings to newer settings found on disk",
                @"Successfully wrote SCSettings out to file",
                @"Copied legacy settings to defaults successfully",
                @"Cleared legacy settings successfully"
            ]],
            @"daemon": [NSSet setWithArray:@[
                @"Daemon accepted new connection",
                @"Daemon method startBlock called",
                @"Daemon added block successfully",
                @"Daemon method updateBlocklist called",
                @"Daemon updated blocklist successfully",
                @"Daemon method appendEntriesToActiveBlocklist called",
                @"Daemon method updateBlockEndDate called",
                @"Daemon extended block successfully",
                @"Daemon method checkupBlock called",
                @"Daemon found and cleared expired block",
                @"Daemon method checkBlockIntegrity called",
                @"Daemon found compromised block integrity and re-added rules",
                @"Daemon method stopTestBlock called",
                @"Daemon stopped test block successfully",
                @"Daemon about to unload"
            ]],
            @"cli": [NSSet setWithArray:@[
                @"CLI method --install called",
                @"CLI method --remove called",
                @"CLI method --print-settings called",
                @"CLI method --is-running called",
                @"CLI method --version called"
            ]],
            @"telemetry.consistency": [NSSet setWithArray:@[
                @"Suppressed repeated startup consistency violation",
                @"Startup consistency checks passed"
            ]]
        };
    });

    if (![allowedMessagesByCategory[category] containsObject:message]) {
        return nil;
    }
    return @{@"category": category, @"message": message};
}

#pragma mark - Sentry event boundary

#if SENTRY_ENABLED
+ (nullable SentryBreadcrumb*)sanitizedSentryBreadcrumb:(SentryBreadcrumb*)breadcrumb {
    NSDictionary<NSString*, NSString*>* sanitized = [self sanitizedBreadcrumbWithMessage:breadcrumb.message
                                                                                  category:breadcrumb.category];
    if (sanitized == nil) {
        return nil;
    }

    SentryBreadcrumb* safeBreadcrumb = [[SentryBreadcrumb alloc] initWithLevel:breadcrumb.level
                                                                       category:sanitized[@"category"]];
    safeBreadcrumb.message = sanitized[@"message"];
    safeBreadcrumb.timestamp = breadcrumb.timestamp;
    return safeBreadcrumb;
}

+ (void)sanitizeStacktrace:(nullable SentryStacktrace*)stacktrace {
    if (stacktrace == nil) return;
    for (SentryFrame *frame in stacktrace.frames ?: @[]) {
        frame.fileName = frame.fileName.lastPathComponent;
        frame.package = frame.package.lastPathComponent;
        frame.contextLine = nil;
        frame.preContext = nil;
        frame.postContext = nil;
        frame.vars = nil;
    }
}

+ (BOOL)sanitizeEventBeforeSend:(SentryEvent*)event {
    // The SDK adds a persistent installation identifier immediately before
    // beforeSend. Never let it cross the network boundary.
    event.user = nil;
    event.request = nil;
    event.serverName = nil;
    event.extra = nil;
    event.error = nil;
    event.transaction = nil;
    event.modules = nil;
    event.fingerprint = nil;
    event.logger = @"fence";
    event.context = [self sanitizedEventContextsFromDictionary:event.context];

    NSMutableDictionary<NSString*, NSString*> *safeTags = [NSMutableDictionary dictionary];
    NSSet<NSString*> *allowedTagKeys = [NSSet setWithArray:@[
        @"component", @"event_name", @"origin", @"spooled", @"outcome", @"operation", @"layer"
    ]];
    [event.tags enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        NSString *safeValue = [self safeContextString:value];
        if ([allowedTagKeys containsObject:key] && safeValue != nil) {
            safeTags[key] = safeValue;
        }
    }];
    event.tags = safeTags.count > 0 ? safeTags : nil;

    if (event.message != nil && ![self isAllowlistedTelemetryMessage:event.message.formatted]) {
        event.message = nil;
    }

    for (SentryException *exception in event.exceptions ?: @[]) {
        exception.type = [self safeContextString:exception.type] ?: @"NativeException";
        if (![exception.value hasPrefix:@"Code: "] || exception.value.length > 64) {
            exception.value = @"Native exception";
        }
        exception.module = [self safeContextString:exception.module];
        if (exception.mechanism != nil) {
            exception.mechanism.type = [self safeContextString:exception.mechanism.type] ?: @"native";
            exception.mechanism.desc = nil;
            exception.mechanism.data = nil;
            exception.mechanism.helpLink = nil;
        }
        [self sanitizeStacktrace:exception.stacktrace];
    }

    for (SentryThread *thread in event.threads ?: @[]) {
        thread.name = nil;
        [self sanitizeStacktrace:thread.stacktrace];
    }
    [self sanitizeStacktrace:event.stacktrace];

    for (SentryDebugMeta *debugImage in event.debugMeta ?: @[]) {
        debugImage.codeFile = debugImage.codeFile.lastPathComponent;
    }

    NSMutableArray<SentryBreadcrumb*>* safeBreadcrumbs = [NSMutableArray array];
    for (SentryBreadcrumb* breadcrumb in event.breadcrumbs ?: @[]) {
        SentryBreadcrumb* safeBreadcrumb = [self sanitizedSentryBreadcrumb:breadcrumb];
        if (safeBreadcrumb != nil) {
            [safeBreadcrumbs addObject:safeBreadcrumb];
        }
    }
    event.breadcrumbs = safeBreadcrumbs;

    // Serialize the exact post-sanitization event and fail closed if any
    // protected key/value survived an SDK integration or future call site.
    return [self payloadPassesTelemetryPrivacyTripwire:[event serialize]];
}
#endif

#pragma mark - Context attachment

+ (void)updateDefaultsContext {
    if (!geteuid() || ![self errorReportingEnabled]) {
        return;
    }

    if (![self isSentryReady]) {
        [self synchronizeErrorReportingLifecycle];
        if (![self isSentryReady]) return;
    }

#if SENTRY_ENABLED
    NSDictionary* defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSDictionary* safeContext = [self sanitizedDefaultsContextFromDictionary:defaults];
    if (![self sentrySDKStarted]) return;
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setContextValue:safeContext forKey:@"NSUserDefaults"];
    }];
#endif
}

#pragma mark - Capture APIs

+ (nullable NSString*)captureValidatedTelemetryEvent:(NSString*)eventName
                                               level:(SCTelemetryEventLevel)level
                                          safeFields:(NSDictionary<NSString*, id>*)safeFields
                                              origin:(NSString*)origin
                                             spooled:(BOOL)spooled
                                       stableEventID:(nullable NSString*)stableEventID
                               createdAtMilliseconds:(nullable NSNumber*)createdAtMilliseconds {
    if (level < SCTelemetryEventLevelInfo || level > SCTelemetryEventLevelError ||
        ![@[@"daemon", @"cli", @"app"] containsObject:origin] || ![self isSentryReady]) return nil;
#if SENTRY_ENABLED
    SentryLevel sentryLevel = kSentryLevelInfo;
    if (level == SCTelemetryEventLevelWarning) sentryLevel = kSentryLevelWarning;
    if (level == SCTelemetryEventLevelError) sentryLevel = kSentryLevelError;

    SentryEvent *event = [[SentryEvent alloc] initWithLevel:sentryLevel];
    if (stableEventID != nil) {
        SentryId *eventID = [[SentryId alloc] initWithUUIDString:stableEventID];
        if ([eventID isEqual:SentryId.empty]) return nil;
        event.eventId = eventID;
    }
    event.message = [[SentryMessage alloc] initWithFormatted:eventName];
    event.context = @{
        @"diagnostic": @{
            @"event_name": eventName,
            @"fields": safeFields
        }
    };
    if (createdAtMilliseconds != nil) {
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSTimeInterval proposed = createdAtMilliseconds.doubleValue / 1000.0;
        NSTimeInterval oldest = now - (14 * 24 * 60 * 60);
        NSTimeInterval newest = now + (5 * 60);
        event.timestamp = [NSDate dateWithTimeIntervalSince1970:MIN(MAX(proposed, oldest), newest)];
    }

    NSMutableDictionary<NSString*, NSString*> *tags = [@{
        @"event_name": eventName,
        @"origin": origin
    } mutableCopy];
    if (spooled) tags[@"spooled"] = @"true";
    for (NSString *key in @[@"outcome", @"operation", @"layer"]) {
        NSString *value = [safeFields[key] isKindOfClass:[NSString class]] ? safeFields[key] : nil;
        if (value != nil) tags[key] = value;
    }
    event.tags = tags;

    SentryId *eventID = [SentrySDK captureEvent:event];
    return [eventID isEqual:SentryId.empty] ? nil : eventID.sentryIdString;
#else
    (void)level;
    (void)eventName;
    (void)safeFields;
    (void)origin;
    (void)spooled;
    (void)stableEventID;
    (void)createdAtMilliseconds;
    return nil;
#endif
}

+ (nullable NSString*)captureTelemetryEvent:(NSString*)eventName
                                      level:(SCTelemetryEventLevel)level
                                     fields:(nullable NSDictionary<NSString*, id>*)fields {
    NSDictionary<NSString*, id> *safeFields = [self sanitizedTelemetryFields:fields forEventName:eventName];
    if (safeFields == nil || ![self errorReportingEnabled]) return nil;

    if (![self isSentryReady]) {
        [self synchronizeErrorReportingLifecycle];
        if (![self isSentryReady]) return nil;
    }

    NSString *component = [self safeComponentNameForIdentifier:SCSentryComponentIdentifier ?: @""];
    NSString *origin = [component isEqualToString:@"cli"] ? @"cli" : @"app";
    return [self captureValidatedTelemetryEvent:eventName
                                          level:level
                                     safeFields:safeFields
                                         origin:origin
                                        spooled:NO
                                  stableEventID:nil
                          createdAtMilliseconds:nil];
}

+ (nullable NSString*)captureSpooledTelemetryRecord:(nullable NSDictionary<NSString*, id>*)record {
    NSDictionary<NSString*, id> *safeRecord = [self sanitizedSpooledTelemetryRecord:record];
    if (safeRecord == nil || ![self errorReportingEnabled]) return nil;

    if (![self isSentryReady]) {
        [self synchronizeErrorReportingLifecycle];
        if (![self isSentryReady]) return nil;
    }

    NSString *levelName = safeRecord[@"level"];
    SCTelemetryEventLevel level = SCTelemetryEventLevelInfo;
    if ([levelName isEqualToString:@"warning"]) level = SCTelemetryEventLevelWarning;
    if ([levelName isEqualToString:@"error"]) level = SCTelemetryEventLevelError;
    return [self captureValidatedTelemetryEvent:safeRecord[@"event_name"]
                                          level:level
                                     safeFields:safeRecord[@"fields"]
                                         origin:safeRecord[@"origin"]
                                        spooled:YES
                                  stableEventID:safeRecord[@"id"]
                          createdAtMilliseconds:safeRecord[@"created_at_ms"]];
}

+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category {
    if (![self errorReportingEnabled]) {
        return;
    }

    if (![self isSentryReady]) {
        [self synchronizeErrorReportingLifecycle];
        if (![self isSentryReady]) return;
    }

    NSDictionary<NSString*, NSString*>* sanitized = [self sanitizedBreadcrumbWithMessage:message category:category];
    if (sanitized == nil) {
        return;
    }

#if SENTRY_ENABLED
    if (![self sentrySDKStarted]) return;
    SentryBreadcrumb* breadcrumb = [[SentryBreadcrumb alloc] initWithLevel:kSentryLevelInfo
                                                                   category:sanitized[@"category"]];
    breadcrumb.message = sanitized[@"message"];
    [SentrySDK addBreadcrumb:breadcrumb];
#endif
}

+ (void)logMessage:(NSString*)message
              level:(SCSentryLogLevel)level
           category:(NSString*)category
         attributes:(nullable NSDictionary<NSString*, id>*)attributes {
    // Structured Sentry logs are intentionally disabled for containment. Keep
    // the API so callers compile while explicit, allowlisted breadcrumbs and
    // events remain available.
    (void)message;
    (void)level;
    (void)category;
    (void)attributes;
}

+ (void)logMessage:(NSString*)message category:(NSString*)category {
    [self logMessage:message level:SCSentryLogLevelInfo category:category attributes:nil];
}

+ (BOOL)ensureConsentForCapture {
    if (!geteuid()) {
        return NO;
    }
    if ([self errorReportingEnabled]) {
        [self synchronizeErrorReportingLifecycle];
        return [self isSentryReady];
    }
    return [self showErrorReportingPromptIfNeeded] && [self isSentryReady];
}

+ (void)captureError:(NSError*)error {
    if (![self ensureConsentForCapture]) {
        return;
    }

#if SENTRY_ENABLED
    if (![self sentrySDKStarted]) return;
#endif

    NSError* sanitizedError = [self sanitizedError:error];
    NSLog(@"Reporting error domain=%@ code=%ld to Sentry", sanitizedError.domain, (long)sanitizedError.code);
    [[SCSettings sharedSettings] updateSentryContext];
    [self updateDefaultsContext];
#if SENTRY_ENABLED
    [SentrySDK captureError:sanitizedError];
#endif
}

+ (void)captureMessage:(NSString*)message {
    if (![self isAllowlistedTelemetryMessage:message]) {
        return;
    }
    if (![self ensureConsentForCapture]) {
        return;
    }

#if SENTRY_ENABLED
    if (![self sentrySDKStarted]) return;
#endif

    NSLog(@"Reporting a diagnostic message to Sentry");
    [[SCSettings sharedSettings] updateSentryContext];
    [self updateDefaultsContext];

#if SENTRY_ENABLED
    [SentrySDK captureMessage:message];
#endif
}

@end

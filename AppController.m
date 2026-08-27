//
//  AppController.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/29/09.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "AppController.h"
#import "MASPreferencesWindowController.h"
#import "PreferencesGeneralViewController.h"
#import "PreferencesProtectionViewController.h"
#import "PreferencesAdvancedViewController.h"
#import "SCTimeIntervalFormatter.h"
#import <LetsMove/PFMoveApplication.h>
#import "SCSettings.h"
#import <ServiceManagement/ServiceManagement.h>
#import "SCXPCClient.h"
#import "SCDaemonProtocol.h"
#import "SCBlockFileReaderWriter.h"
#import "SCUIUtilities.h"
#import "Common/Utility/SCBlockUtilities.h"
#import <TransformerKit/NSValueTransformer+TransformerKit.h>
#import "SCDebugUtilities.h"
#import "SCWeekScheduleWindowController.h"
#import "SCScheduleManager.h"
#import "SCBlockBundle.h"
#import "SCMenuBarController.h"
#import "SCStartupSafetyCheck.h"
#import "SCSafetyCheckWindowController.h"
#import "SCVersionTracker.h"
#import "SCTestBlockWindowController.h"
#import "SCLogger.h"
#import "Common/SCLicenseManager.h"
#import "SCLicenseWindowController.h"
#import "SCTravelTimezoneManager.h"
#import <Sparkle/Sparkle.h>

static NSString * const kRepairMigrationPER352AuthRefreshBuildKey = @"SCRepairMigrationPER352AuthRefreshBuild";
static NSString * const kDaemonCompatibilityErrorDomain = @"org.eyebeam.Fence.DaemonCompatibility";
static NSString * const kInstalledDaemonPath = @"/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold";
static NSString * const kBundledDaemonRelativePath = @"Contents/Library/LaunchServices/org.eyebeam.selfcontrold";
static NSString * const kTelemetryConsistencyLastSignatureKey = @"SCTelemetryConsistencyLastSignature";
static NSString * const kTelemetryConsistencyLastEmissionDateKey = @"SCTelemetryConsistencyLastEmissionDate";
static const NSTimeInterval kTelemetryConsistencySuppressionInterval = 7.0 * 24.0 * 60.0 * 60.0;

typedef NS_ENUM(NSInteger, SCDaemonCompatibilityFailureCode) {
    SCDaemonCompatibilityFailureUnknown = 1,
    SCDaemonCompatibilityFailureHandshakeUnavailable = 2,
    SCDaemonCompatibilityFailureProtocolTooOld = 3,
    SCDaemonCompatibilityFailureCapabilitiesMissing = 4,
    SCDaemonCompatibilityFailureActiveAppendMissing = 5,
    SCDaemonCompatibilityFailureApprovedAppendMissing = 6,
    SCDaemonCompatibilityFailureConsistencyProjectionMissing = 7,
    SCDaemonCompatibilityFailureRootScheduleStoreMissing = 8,
    SCDaemonCompatibilityFailureRootScheduleTimerMissing = 9,
};

static SCDaemonCompatibilityFailureCode SCDaemonCompatibilityFailureCodeForReason(NSString *reason) {
    if ([reason isEqualToString:@"handshake-unavailable"]) {
        return SCDaemonCompatibilityFailureHandshakeUnavailable;
    }
    if ([reason isEqualToString:@"protocol-too-old"]) {
        return SCDaemonCompatibilityFailureProtocolTooOld;
    }
    if ([reason isEqualToString:@"capabilities-missing"]) {
        return SCDaemonCompatibilityFailureCapabilitiesMissing;
    }
    if ([reason isEqualToString:@"active-append-missing"]) {
        return SCDaemonCompatibilityFailureActiveAppendMissing;
    }
    if ([reason isEqualToString:@"approved-append-missing"]) {
        return SCDaemonCompatibilityFailureApprovedAppendMissing;
    }
    if ([reason isEqualToString:@"consistency-projection-missing"]) {
        return SCDaemonCompatibilityFailureConsistencyProjectionMissing;
    }
    if ([reason isEqualToString:@"root-schedule-store-missing"]) {
        return SCDaemonCompatibilityFailureRootScheduleStoreMissing;
    }
    if ([reason isEqualToString:@"root-schedule-timer-missing"]) {
        return SCDaemonCompatibilityFailureRootScheduleTimerMissing;
    }
    return SCDaemonCompatibilityFailureUnknown;
}

static NSString *SCDaemonCompatibilityTelemetryReason(NSString *reason) {
    if ([reason isEqualToString:@"handshake-unavailable"]) return @"handshake_unavailable";
    if ([reason isEqualToString:@"protocol-too-old"]) return @"protocol_too_old";
    if ([reason isEqualToString:@"active-append-missing"]) return @"active_append_missing";
    if ([reason isEqualToString:@"approved-append-missing"]) return @"approved_append_missing";
    if ([reason isEqualToString:@"consistency-projection-missing"]) return @"consistency_projection_missing";
    if ([reason isEqualToString:@"root-schedule-store-missing"]) return @"root_schedule_store_missing";
    if ([reason isEqualToString:@"root-schedule-timer-missing"]) return @"root_schedule_timer_missing";
    return @"capabilities_missing";
}

static BOOL SCFileExistsAtPath(NSString *path) {
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

@interface AppController () {}

@property (atomic, strong, readwrite) SCXPCClient* xpc;
@property (nonatomic, strong) SCWeekScheduleWindowController* weekScheduleWindowController;
@property (nonatomic, strong, nullable) SCLicenseWindowController* licenseWindowController;
@property (nonatomic, strong, nullable) SCTestBlockWindowController* testBlockWindowController;
@property (nonatomic, strong, readwrite) SPUStandardUpdaterController* updaterController;

- (void)checkDaemonCompatibilityAllowingRepair:(BOOL)allowRepair;
- (void)reinstallDaemon;
- (void)configureDomainListForCurrentState;
- (void)scheduleManagerDidChange:(NSNotification *)notification;
- (void)emitDaemonUnreachableRepairOutcome:(NSString*)outcome
                                finalError:(nullable NSError*)finalError
                        reinstallSucceeded:(BOOL)reinstallSucceeded
                         reconnectAttempted:(BOOL)reconnectAttempted
              postRepairHandshakeSucceeded:(BOOL)postRepairHandshakeSucceeded
                      postRepairCompatible:(BOOL)postRepairCompatible;
- (void)runTelemetryConsistencyCheckWithDaemonProtocol:(NSInteger)protocolVersion;
- (void)captureStartupDivergenceFields:(NSDictionary<NSString *, id> *)fields;
- (void)synchronizeTelemetryConsentAndDrain;
- (void)drainTelemetrySpoolWithRemainingBatches:(NSUInteger)remainingBatches;
- (void)sendDiagnosticReportFromUserAction;
- (void)presentPermissionsRepairResult:(BOOL)repaired error:(nullable NSError *)error;

@end

@implementation AppController {
    BOOL appDidFinishLaunching_;
    BOOL daemonCompatibilityRepairAttempted_;
    BOOL daemonCompatibilityRepairInFlight_;
    BOOL telemetryStartupCheckCompleted_;
    BOOL telemetryStartupCheckInFlight_;
    NSUInteger telemetryStartupCheckAttempts_;
    NSInteger lastCompatibleDaemonProtocol_;
    BOOL telemetryDrainInFlight_;
    NSError *daemonUnreachableInitialError_;
    BOOL daemonUnreachableInstalledHelperPresentBefore_;
    BOOL daemonUnreachableBundledHelperPresent_;
    BOOL daemonUnreachableTelemetryEmitted_;
    BOOL diagnosticReportInFlight_;
}

@synthesize addingBlock;

- (AppController*) init {
	if(self = [super init]) {

		defaults_ = [NSUserDefaults standardUserDefaults];
		[defaults_ registerDefaults: SCConstants.defaultUserDefaults];

		self.addingBlock = false;

		// refreshUILock_ is a lock that prevents a race condition by making the refreshUserInterface
		// method alter the blockIsOn variable atomically (will no longer be necessary once we can
		// use properties).
		refreshUILock_ = [[NSLock alloc] init];
	}

	return self;
}

- (void)runPostUpdateRepairMigrations {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults stringForKey:kRepairMigrationPER352AuthRefreshBuildKey].length > 0) return;

    NSString *currentBuild = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    if (![self.xpc authorizationRightsNeedRefresh]) {
        [defaults setObject:currentBuild forKey:kRepairMigrationPER352AuthRefreshBuildKey];
        [defaults synchronize];
        NSLog(@"AppController: PER-352 authorization rights already current");
        return;
    }

    // Do not surprise the user with an administrator prompt at app launch.
    // The next authorization-protected action repairs stale managed rights
    // before it asks the helper to mutate protected state.
    NSLog(@"AppController: Deferring stale authorization-right repair until protected action");
}

- (IBAction)updateTimeSliderDisplay:(id)sender {
    NSInteger numMinutes = [defaults_ integerForKey: @"BlockDuration"];

    // if the duration is larger than we can display on our slider
    // chop it down to our max display value so the user doesn't
    // accidentally start a much longer block than intended
    if (numMinutes > blockDurationSlider_.maxDuration) {
        [self setDefaultsBlockDurationOnMainThread: @(floor(blockDurationSlider_.maxDuration))];
        numMinutes = [defaults_ integerForKey: @"BlockDuration"];
    }

    blockSliderTimeDisplayLabel_.stringValue = blockDurationSlider_.durationDescription;

	[submitButton_ setEnabled: (numMinutes > 0) && ([[defaults_ arrayForKey: @"Blocklist"] count] > 0)];
}

- (IBAction)addBlock:(id)sender {
    if ([SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is on so the Start button should be disabled.
        NSError* err = [SCErr errorWithCode: 104];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
		return;
	}
	if (([[defaults_ arrayForKey: @"Blocklist"] count] == 0) && ![defaults_ boolForKey: @"BlockAsWhitelist"]) {
		// Since the Start button should be disabled when the blocklist has no entries (and it's not an allowlist)
		// this should definitely not be happening.  Exit.

        NSError* err = [SCErr errorWithCode: 100];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    // cancel if we pop up a warning about the super long block, and the user decides to cancel
    if (![self showLongBlockWarningsIfNecessary]) {
        return;
    }

	[timerWindowController_ resetStrikes];

    // Check license before allowing block
    if (![[SCLicenseManager sharedManager] canCommit]) {
        [self showLicenseModalWithCompletion:^{
            [NSThread detachNewThreadSelector:@selector(installBlock) toTarget:self withObject:nil];
        }];
        return;
    }

    // Trial still valid or license valid - proceed with block
	[NSThread detachNewThreadSelector: @selector(installBlock) toTarget: self withObject: nil];
}

#pragma mark - License

- (void)showLicenseModalWithCompletion:(void(^)(void))completion {
    // Don't open multiple license windows - bring existing to front
    if (self.licenseWindowController) {
        [initialWindow_ makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    self.licenseWindowController = [[SCLicenseWindowController alloc] init];
    self.licenseWindowController.onLicenseActivated = ^{
        self.licenseWindowController = nil;
        if (completion) {
            completion();
        }
    };
    self.licenseWindowController.onCancel = ^{
        self.licenseWindowController = nil;
        // User cancelled - they can't proceed without a license
    };
    [self.licenseWindowController beginSheetModalForWindow:initialWindow_ completionHandler:nil];
}

// returns YES if we should continue with the block, NO if we should cancel it
- (BOOL)showLongBlockWarningsIfNecessary {
    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [self showLongBlockWarningsIfNecessary];
        });
        return retVal;
    }
    
    NSString* LONG_BLOCK_SUPPRESSION_KEY = @"SuppressLongBlockWarning";
    int LONG_BLOCK_THRESHOLD_MINS = 2880; // 2 days
    int FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS = 480; // 8 hours

    BOOL isFirstBlock = ![defaults_ boolForKey: @"FirstBlockStarted"];
    int blockDuration = [[self->defaults_ valueForKey: @"BlockDuration"] intValue];

    BOOL showLongBlockWarning = blockDuration >= LONG_BLOCK_THRESHOLD_MINS || (isFirstBlock && blockDuration >= FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS);
    if (!showLongBlockWarning) return YES;

    // if they don't want warnings, they don't get warnings. their funeral 💀
    if ([self->defaults_ boolForKey: LONG_BLOCK_SUPPRESSION_KEY]) {
        return YES;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"That's a long block!", "Long block warning title");
    alert.informativeText = [NSString stringWithFormat: NSLocalizedString(@"Remember that once you start the block, you can't turn it back off until the timer expires in %@ - even if you accidentally blocked a site you need. Consider starting a shorter block first, to test your list and make sure everything's working properly.", @"Long block warning message"), [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: blockDuration]];
    [alert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Button to cancel a long block")];
    [alert addButtonWithTitle: NSLocalizedString(@"Start Block Anyway", "Button to start a long block despite warnings")];
    alert.showsSuppressionButton = YES;

    NSModalResponse modalResponse = [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn) {
        // no more warnings, they say
        [self->defaults_ setBool: YES forKey: LONG_BLOCK_SUPPRESSION_KEY];
    }
    if (modalResponse == NSAlertFirstButtonReturn) {
        return NO;
    }
    
    return YES;
}


- (void)refreshUserInterface {
    // UI updates are for the main thread only!
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshUserInterface];
        });
        return;
    }

	if(![refreshUILock_ tryLock]) {
		// already refreshing the UI, no need to wait and do it again
		return;
	}

	BOOL blockWasOn = blockIsOn;
	blockIsOn = [SCUIUtilities blockIsRunning];

	if(blockIsOn) { // block is on
		if(!blockWasOn) { // if we just switched states to on...
			[self closeTimerWindow];
			[initialWindow_ close];
			[self closeDomainList];

			// Always show menu bar when block is running
			[[SCMenuBarController sharedController] setVisible:YES];

			// Set up menu bar action handlers
			__weak typeof(self) weakSelf = self;
			[SCMenuBarController sharedController].onShowSchedule = ^{
				[weakSelf showWeekSchedule:weakSelf];
			};
			[SCMenuBarController sharedController].onShowBlocklist = ^{
				[weakSelf showDomainList:weakSelf];
			};
			[SCMenuBarController sharedController].onEnterLicense = ^{
				[weakSelf showWeekSchedule:weakSelf];
			};
            [SCMenuBarController sharedController].onRepairPermissions = ^{
                [weakSelf repairFencePermissionsFromUserAction];
            };
            [SCMenuBarController sharedController].onSendDiagnosticReport = ^{
                [weakSelf sendDiagnosticReportFromUserAction];
            };

            // apparently, a block is running, so make sure FirstBlockStarted is true
            [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
		}
	} else { // block is off
		SCScheduleManager *manager = [SCScheduleManager sharedManager];
		BOOL recurringCommitmentStillActive = manager.hasRecurringCommitment;
		if(blockWasOn && !recurringCommitmentStillActive) { // a legacy block actually ended
			[timerWindowController_ blockEnded];

			// Makes sure the domain list will refresh when it comes back
			[self closeDomainList];

            // make sure the dock badge is cleared
            [[NSApp dockTile] setBadgeLabel: nil];

            // send a notification letting the user know the block ended
            // TODO: make this sent from a background process so it shows if app is closed
            // (but we can't send it from the selfcontrold process, because it's running as root)
            NSUserNotificationCenter* userNoteCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
            NSUserNotification* endedNote = [NSUserNotification new];
            endedNote.title = @"Your Fence block has ended!";
            endedNote.informativeText = @"All sites are now accessible.";
            [userNoteCenter deliverNotification: endedNote];

			[self closeTimerWindow];
		}

        // UI visibility logic OUTSIDE transition check (runs on every refresh)
        // This ensures UI shows on cold launch, not just state transitions
        if ([manager isCommitted]) {
            // Committed state: show menu bar for access to schedule/settings
            [[SCMenuBarController sharedController] setVisible:YES];
            __weak typeof(self) weakSelf = self;
            [SCMenuBarController sharedController].onShowSchedule = ^{
                [weakSelf showWeekSchedule:weakSelf];
            };
            [SCMenuBarController sharedController].onShowBlocklist = ^{
                [weakSelf showDomainList:weakSelf];
            };
            [SCMenuBarController sharedController].onEnterLicense = ^{
                [weakSelf showWeekSchedule:weakSelf];
            };
            [SCMenuBarController sharedController].onRepairPermissions = ^{
                [weakSelf repairFencePermissionsFromUserAction];
            };
            [SCMenuBarController sharedController].onSendDiagnosticReport = ^{
                [weakSelf sendDiagnosticReportFromUserAction];
            };
        } else if (blockWasOn) {
            // Not committed + just transitioned off: show week schedule
            [self showWeekSchedule:self];
        }

		[self updateTimeSliderDisplay: blockDurationSlider_];

		if([defaults_ integerForKey: @"BlockDuration"] != 0 &&
           ([[defaults_ arrayForKey: @"Blocklist"] count] != 0 || [defaults_ boolForKey: @"BlockAsWhitelist"]) &&
           !self.addingBlock) {
			[submitButton_ setEnabled: YES];
		} else {
			[submitButton_ setEnabled: NO];
		}

		// If we're adding a block, we want buttons disabled.
        if(!self.addingBlock) {
			[blockDurationSlider_ setEnabled: YES];
			[editBlocklistButton_ setEnabled: YES];
			[submitButton_ setTitle: NSLocalizedString(@"Start Block", @"Start button")];
		} else {
			[blockDurationSlider_ setEnabled: NO];
			[editBlocklistButton_ setEnabled: NO];
			[submitButton_ setTitle: NSLocalizedString(@"Starting Block", @"Starting Block button")];
		}

	}

    // finally: if the helper tool marked that it detected tampering, make sure
    // we follow through and set the cheater wallpaper (helper tool can't do it itself)
    if ([settings_ boolForKey: @"TamperingDetected"]) {
        NSURL* cheaterBackgroundURL = [[NSBundle mainBundle] URLForResource: @"cheater-background" withExtension: @"png"];
            NSArray<NSScreen *>* screens = [NSScreen screens];
        for (NSScreen* screen in screens) {
            NSError* err;
            [[NSWorkspace sharedWorkspace] setDesktopImageURL: cheaterBackgroundURL
                                                    forScreen: screen
                                                      options: @{}
                                                        error: &err];
        }
        [settings_ setValue: @NO forKey: @"TamperingDetected"];
    }
    
    // Display "blocklist" or "allowlist" as appropriate
    NSString* listType = [defaults_ boolForKey: @"BlockAsWhitelist"] ? @"Allowlist" : @"Blocklist";
    NSString* editListString = NSLocalizedString(([NSString stringWithFormat: @"Edit %@", listType]), @"Edit list button / menu item");
    
    editBlocklistButton_.title = editListString;
    editBlocklistMenuItem_.title = editListString;

	[refreshUILock_ unlock];
}

- (void)handleConfigurationChangedNotification {
    [SCSentry addBreadcrumb: @"Received configuration changed notification" category: @"app"];
    // if our configuration changed, we should assume the settings may have changed
    [[SCSettings sharedSettings] reloadSettings];

    // A recurring block teardown is the safe boundary for a timezone change
    // that the daemon previously deferred. Retry the accepted timezone only;
    // this path never asks Location Services for another fix.
    if (![SCBlockUtilities modernBlockIsRunning]) {
        [[SCTravelTimezoneManager sharedManager]
            retryPendingDaemonTimeZoneUpdateIfNeeded];
    }
    
    // clean out empty strings from the defaults blocklist (they can end up there occasionally due to UI glitches etc)
    // note we don't screw with the actively running blocklist - that should've been cleaned before it started anyway
    NSArray<NSString*>* cleanedBlocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];

    // update our blocklist teaser string
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 60];
    
    // let the domain list know!
    if (domainListWindowController_ != nil) {
        [self configureDomainListForCurrentState];
        [domainListWindowController_ refreshDomainList];
    }
    
    // let the timer window know!
    if (timerWindowController_ != nil) {
        [timerWindowController_ performSelectorOnMainThread: @selector(configurationChanged)
                                                 withObject: nil
                                              waitUntilDone: NO];
    }
    
    // and our interface may need to change to match!
    [self refreshUserInterface];
}

- (void)scheduleManagerDidChange:(NSNotification *)notification {
    #pragma unused(notification)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (domainListWindowController_ == nil) return;
        [self configureDomainListForCurrentState];
        [domainListWindowController_ refreshDomainList];
    });
}

- (void)showTimerWindow {
	if(timerWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"TimerWindow" owner: self topLevelObjects: nil];
	} else {
		[[timerWindowController_ window] makeKeyAndOrderFront: self];
		[[timerWindowController_ window] center];
	}
}

- (void)closeTimerWindow {
	[timerWindowController_ close];
	timerWindowController_ = nil;
}

- (IBAction)openPreferences:(id)sender {
    [SCSentry addBreadcrumb: @"Opening preferences window" category: @"app"];
	if (preferencesWindowController_ == nil) {
		NSViewController* generalViewController = [[PreferencesGeneralViewController alloc] init];
		NSViewController* protectionViewController = [[PreferencesProtectionViewController alloc] init];
		NSViewController* advancedViewController = [[PreferencesAdvancedViewController alloc] init];
		NSString* title = NSLocalizedString(@"Preferences", @"Common title for Preferences window");

		preferencesWindowController_ = [[MASPreferencesWindowController alloc] initWithViewControllers: @[generalViewController, protectionViewController, advancedViewController] title: title];

		[self applyPreferencesWindowStyle];
	}
	[preferencesWindowController_ showWindow: nil];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // For test runs, we don't want to pop up the dialog to move to the Applications folder, as it breaks the tests
    if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] == nil) {
        PFMoveToApplicationsFolderIfNecessary();
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[NSApplication sharedApplication].delegate = self;

    // The app controller exists for the full login session, unlike the weekly
    // window controller. Own the location refresh wake trigger here so it also
    // fires before the schedule UI has ever been opened.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(systemDidWakeForTravelTimezone:)
               name:NSWorkspaceDidWakeNotification
             object:nil];

    // Initialize Sparkle updater for automatic updates
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
                                                                           updaterDelegate:nil
                                                                        userDriverDelegate:nil];
    NSLog(@"[Sparkle] Updater initialized");

    // Register as login item so app launches at startup
    if (@available(macOS 13.0, *)) {
        SMAppService *appService = [SMAppService mainAppService];
        if (appService.status != SMAppServiceStatusEnabled) {
            NSError *error = nil;
            [appService registerAndReturnError:&error];
            if (error) {
                NSLog(@"Failed to enable launch at login: %@", error);
            } else {
                NSLog(@"Registered as login item");
            }
        }
    }

    [SCSentry startSentry: @"org.eyebeam.SelfControl"];
    // Fence's rebrand changed the application bundle identifier and therefore
    // its NSUserDefaults domain. Restore an orphaned calendar only when the new
    // domain has no schedule state of its own; never overwrite a Fence calendar.
    BOOL restoredLegacyFenceSchedule = [SCMigrationUtilities migrateLegacyFenceScheduleDefaultsIfNeeded];
    if (restoredLegacyFenceSchedule) {
        [SCSentry captureTelemetryEvent:@"state.app_defaults_regressed"
                                  level:SCTelemetryEventLevelError
                                 fields:@{
            @"reason": @"legacy_domain_orphaned",
            @"current_domain_has_state": @NO,
            @"legacy_domain_has_state": @YES,
            @"migration_applied": @YES
        }];
    }

#ifdef DEBUG
    // Listen for debug actions from menu bar
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(toggleDebugBlocking:)
                                                 name:@"SCDebugDisableBlockingRequested"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(triggerSafetyCheck:)
                                                 name:@"SCDebugTriggerSafetyCheckRequested"
                                               object:nil];
#endif

    settings_ = [SCSettings sharedSettings];
    // go copy over any preferences from legacy setting locations
    // (we won't clear any old data yet - we leave that to the daemon)
    if ([SCMigrationUtilities legacySettingsFoundForCurrentUser]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults];
    }

    // Sync trial status with server (prevents trial reset by reinstalling)
    [[SCLicenseManager sharedManager] syncTrialStatusWithCompletion:^(NSInteger daysRemaining) {
        NSLog(@"[AppController] Trial sync complete - %ld days remaining", (long)daysRemaining);
    }];

    // Attempt license recovery (if keychain storage failed previously but server has record)
    [[SCLicenseManager sharedManager] attemptLicenseRecoveryWithCompletion:^(BOOL recovered) {
        if (recovered) {
            NSLog(@"[AppController] License recovered from server!");
            // Refresh UI to reflect licensed state
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SCLicenseStatusChanged" object:nil];
        }
    }];

    // start up our daemon XPC
    self.xpc = [SCXPCClient new];
    [self.xpc connectToHelperTool];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(telemetryConsentDidChange:)
                                                 name:SCTelemetryConsentDidChangeNotification
                                               object:nil];
    [self runPostUpdateRepairMigrations];
    [[SCTravelTimezoneManager sharedManager] requestTimeZoneRefreshIfNeeded];

    // If we don't have a connection within 0.5 seconds, or the installed daemon
    // lacks the protocol/capabilities required by this app, repair it once.
    // something's wrong with our app-daemon connection. This probably means one of three things:
    //   1. The daemon got unloaded somehow and failed to restart. This is a big problem because the block won't come off.
    //   2. The daemon doesn't want to talk to us anymore, potentially because we've changed our signing certificate. This is a
    //      smaller problem, but still not great because the app can't communicate anything to the daemon.
    //   3. There's a daemon but its XPC contract is incompatible and should be replaced.
    // in any case, let's go try to reinstall the daemon
    // (we debounce this call so it happens only once, after the connection has been invalidated for an extended period)
    BOOL blockIsRunning = [SCBlockUtilities modernBlockIsRunning];
    NSLog(@"AppController: Daemon compatibility check - modernBlockIsRunning=%@, appVersion=%@",
          blockIsRunning ? @"YES" : @"NO", SELFCONTROL_VERSION_STRING);

    // Marketing versions cannot be compared here: retained daemon 6.4.5 is
    // numerically newer than app 3.4.7 but lacks the strict append selectors.
    NSLog(@"AppController: Checking daemon protocol capabilities in 0.5s...");
    [NSTimer scheduledTimerWithTimeInterval: 0.5 repeats: NO block:^(NSTimer * _Nonnull timer) {
        [self checkDaemonCompatibilityAllowingRepair:YES];
    }];

    // Register observers on both distributed and normal notification centers
	// to receive notifications from the helper tool and the other parts of the
	// main SelfControl app.  Note that they are divided thusly because distributed
	// notifications are very expensive and should be minimized.
	[[NSDistributedNotificationCenter defaultCenter] addObserver: self
														selector: @selector(handleConfigurationChangedNotification)
															name: @"SCConfigurationChangedNotification"
														  object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(handleConfigurationChangedNotification)
												 name: @"SCConfigurationChangedNotification"
											   object: nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
										 selector:@selector(scheduleManagerDidChange:)
											 name:SCScheduleManagerDidChangeNotification
										   object:nil];

	[initialWindow_ center];

    // Apply frosted glass styling to main window
    [self setupFrostedGlassAppearance];

	// We'll set blockIsOn to whatever is NOT right, so that in refreshUserInterface
	// it'll fix it and properly refresh the user interface.
	blockIsOn = ![SCUIUtilities blockIsRunning];

	// Change block duration slider for hidden user defaults settings
    blockDurationSlider_.maxDuration = [defaults_ integerForKey: @"MaxBlockLength"];
    [blockDurationSlider_ bindDurationToObject: [NSUserDefaultsController sharedUserDefaultsController]
                                       keyPath: @"values.BlockDuration"];
    
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 60];

	[self refreshUserInterface];
    
    NSOperatingSystemVersion minRequiredVersion = (NSOperatingSystemVersion){10,10,0}; // Yosemite
    NSString* minRequiredVersionString = @"10.10 (Yosemite)";
	if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: minRequiredVersion]) {
		NSLog(@"ERROR: Unsupported version for SelfControl");
        [SCSentry captureMessage: @"Unsupported operating system version"];
		NSAlert* unsupportedVersionAlert = [[NSAlert alloc] init];
		[unsupportedVersionAlert setMessageText: NSLocalizedString(@"Unsupported version", nil)];
        [unsupportedVersionAlert setInformativeText: [NSString stringWithFormat: NSLocalizedString(@"This version of SelfControl only supports Mac OS X version %@ or higher. To download a version for older operating systems, please go to www.selfcontrolapp.com", nil), minRequiredVersionString]];
		[unsupportedVersionAlert addButtonWithTitle: NSLocalizedString(@"OK", nil)];
		[unsupportedVersionAlert runModal];
	}

#ifdef DEBUG
    // Set up debug menu (only in DEBUG builds)
    [self setupDebugMenu];
    [self updateDebugIndicator];
#endif

    // Check if safety test is needed (version changed since last test)
    if ([SCStartupSafetyCheck safetyCheckNeeded]) {
        // Delay slightly to let the app finish launching
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showSafetyCheckPrompt];
        });
    } else if ([SCVersionTracker testBlockNeeded] && ![SCVersionTracker hasEverCommitted]) {
        // Safety check passed previously, but user never completed a test block or committed
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showTestBlockAfterSafetyCheck];
        });
    }

    appDidFinishLaunching_ = YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [settings_ synchronizeSettings];
}

- (void)systemDidWakeForTravelTimezone:(NSNotification *)notification {
    [[SCTravelTimezoneManager sharedManager] requestTimeZoneRefreshIfNeeded];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Always allow quit - user should never be trapped in modal state
    // Clean up any open sheets first
    for (NSWindow *window in [NSApp windows]) {
        if (window.attachedSheet) {
            [window endSheet:window.attachedSheet];
        }
    }
    return NSTerminateNow;
}

- (void)showSafetyCheckPrompt {
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Safety Check Required"];
    [alert setInformativeText:@"Your macOS or Fence version has changed since the last safety check. Running a 30-second test to verify blocking works correctly."];
    [alert addButtonWithTitle:@"Continue"];

    [alert runModal];
    [self runSafetyCheck];
}

- (void)runSafetyCheck {
    // Close existing safety check window if one is open
    if (self.safetyCheckWindowController) {
        [self.safetyCheckWindowController cancelCheck];
        [self.safetyCheckWindowController.window close];
        self.safetyCheckWindowController = nil;
    }

    self.safetyCheckWindowController = [[SCSafetyCheckWindowController alloc] init];

    // Set completion handler to show test block after user clicks OK
    __weak typeof(self) weakSelf = self;
    self.safetyCheckWindowController.completionHandler = ^(SCSafetyCheckResult* result) {
        if (result.passed) {
            [weakSelf showTestBlockAfterSafetyCheck];
        }
    };

    [self.safetyCheckWindowController showWindow:self];
    [self.safetyCheckWindowController runSafetyCheck];
}

- (void)showTestBlockAfterSafetyCheck {
    // Clean up safety check controller (window already closed by OK click)
    self.safetyCheckWindowController = nil;

    // Don't show test block if a block is already running
    if ([SCBlockUtilities anyBlockIsRunning]) {
        return;
    }

    // Show alert offering to try test block
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Would you like to try a test block? (Recommended)";
    alert.informativeText = @"You can try this any time from the menu when outside an active block.";
    [alert addButtonWithTitle:@"Try Test Block"];
    [alert addButtonWithTitle:@"Maybe Later"];

    NSModalResponse response = [alert runModal];

    if (response == NSAlertFirstButtonReturn) {
        // Show test block window
        self.testBlockWindowController = [[SCTestBlockWindowController alloc] init];
        self.testBlockWindowController.completionHandler = ^(BOOL didComplete) {
            self.testBlockWindowController = nil;
        };
        [self.testBlockWindowController showWindow:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)checkDaemonCompatibilityAllowingRepair:(BOOL)allowRepair {
    [self.xpc getCompatibilityInfo:^(NSInteger protocolVersion,
                                     NSString *buildVersion,
                                     NSString *marketingVersion,
                                     NSArray<NSString *> *capabilities,
                                     NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *reason = nil;
            BOOL compatible = (error == nil &&
                               [SCXPCClient isDaemonProtocolVersion:protocolVersion
                                                       capabilities:capabilities
                                  compatibleWithCurrentAppWithReason:&reason]);
            if (error != nil) {
                reason = @"handshake-unavailable";
            }

            NSString *safeBuildVersion = buildVersion ?: @"unknown";
            NSString *safeMarketingVersion = marketingVersion ?: @"unknown";
            if (compatible) {
                NSLog(@"AppController: Daemon compatible (protocol=%ld, build=%@, marketing=%@)",
                      (long)protocolVersion, safeBuildVersion, safeMarketingVersion);
                [SCSentry addBreadcrumb:@"Detected up-to-date daemon" category:@"app"];
                if (self->daemonUnreachableInitialError_ != nil) {
                    [self emitDaemonUnreachableRepairOutcome:@"recovered"
                                                  finalError:nil
                                          reinstallSucceeded:YES
                                           reconnectAttempted:YES
                                postRepairHandshakeSucceeded:YES
                                        postRepairCompatible:YES];
                }
                self->daemonCompatibilityRepairInFlight_ = NO;
                self->lastCompatibleDaemonProtocol_ = protocolVersion;
                [self synchronizeTelemetryConsentAndDrain];
                [[SCScheduleManager sharedManager]
                    refreshRecurringRuntimeStateWithCompletion:^(BOOL refreshed, NSError *refreshError) {
                    if (!refreshed) {
                        NSLog(@"AppController: Recurring runtime refresh unavailable (domain=%@ code=%ld)",
                              refreshError.domain, (long)refreshError.code);
                    }
                    SCTravelTimezoneManager *travelManager =
                        [SCTravelTimezoneManager sharedManager];
                    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
                    if (travelManager.status == SCTravelTimezoneStatusDisabled &&
                        scheduleManager.hasRecurringCommitment &&
                        scheduleManager.recurringCommitmentFollowsLocationTimeZone) {
                        // Startup already requested once when local state knew
                        // travel mode was active. Request here only when the
                        // daemon has just recovered an otherwise-missing mode.
                        [travelManager requestTimeZoneRefreshIfNeeded];
                    }
                    [self runTelemetryConsistencyCheckWithDaemonProtocol:protocolVersion];
                }];
                return;
            }

            NSString *legacyReason = nil;
            BOOL legacyRecurringRuntime = error == nil &&
                protocolVersion < SCDaemonProtocolVersionCurrent &&
                [SCXPCClient isDaemonProtocolVersion:protocolVersion
                                         capabilities:capabilities
                        supportsLegacyRecurringRuntimeWithReason:&legacyReason];
            if (legacyRecurringRuntime) {
                // Protocol 6 already owns and enforces the 3.4.12 recurring
                // state. Keep it running until Commit, Extend, or explicit
                // Repair gives us a user-initiated authorization context.
                NSLog(@"AppController: Retaining legacy recurring daemon until a protected user action (protocol=%ld)",
                      (long)protocolVersion);
                [self synchronizeTelemetryConsentAndDrain];
                [[SCScheduleManager sharedManager]
                    refreshRecurringRuntimeStateForDaemonProtocolVersion:protocolVersion
                    completion:^(BOOL refreshed, NSError *refreshError) {
                    if (!refreshed) {
                        NSLog(@"AppController: Legacy recurring runtime refresh unavailable (domain=%@ code=%ld)",
                              refreshError.domain, (long)refreshError.code);
                    }
                }];
                return;
            }

            NSLog(@"AppController: Daemon incompatible (reason=%@, protocol=%ld, build=%@, marketing=%@)",
                  reason, (long)protocolVersion, safeBuildVersion, safeMarketingVersion);

            if (allowRepair && !self->daemonCompatibilityRepairAttempted_ && !self->daemonCompatibilityRepairInFlight_) {
                self->daemonCompatibilityRepairAttempted_ = YES;
                self->daemonCompatibilityRepairInFlight_ = YES;
                if (error != nil) {
                    self->daemonUnreachableInitialError_ = error;
                    self->daemonUnreachableInstalledHelperPresentBefore_ = SCFileExistsAtPath(kInstalledDaemonPath);
                    NSString *bundledDaemonPath = [NSBundle.mainBundle.bundlePath
                        stringByAppendingPathComponent:kBundledDaemonRelativePath];
                    self->daemonUnreachableBundledHelperPresent_ = SCFileExistsAtPath(bundledDaemonPath);
                }
                [SCSentry addBreadcrumb:@"Detected out-of-date daemon" category:@"app"];
                [self reinstallDaemon];
                return;
            }

            self->daemonCompatibilityRepairInFlight_ = NO;
            [SCSentry addBreadcrumb:@"Detected out-of-date daemon" category:@"app"];

            if (self->daemonUnreachableInitialError_ != nil) {
                [self emitDaemonUnreachableRepairOutcome:(error != nil ? @"post_repair_unreachable" : @"post_repair_incompatible")
                                              finalError:error
                                      reinstallSucceeded:YES
                                       reconnectAttempted:YES
                            postRepairHandshakeSucceeded:(error == nil)
                                    postRepairCompatible:NO];
            }

            // This error contains only static binary metadata and an allowlisted
            // reason; SCSentry may sanitize it further. The raw NSXPC error
            // remains in the local log.
            NSError *compatibilityError = [NSError errorWithDomain:kDaemonCompatibilityErrorDomain
                                                               code:SCDaemonCompatibilityFailureCodeForReason(reason)
                                                           userInfo:@{
                NSLocalizedDescriptionKey: @"Daemon remains incompatible after one repair attempt",
                @"reason": reason ?: @"unknown",
                @"daemon_protocol": @(protocolVersion),
                @"daemon_build": safeBuildVersion,
                @"daemon_marketing_version": safeMarketingVersion,
            }];
            [SCSentry captureTelemetryEvent:@"daemon.incompatible"
                                      level:SCTelemetryEventLevelError
                                     fields:@{
                @"reason": SCDaemonCompatibilityTelemetryReason(reason),
                @"repair_attempted": @(self->daemonCompatibilityRepairAttempted_),
                @"repair_succeeded": @NO,
                @"daemon_protocol": @(MAX(0, protocolVersion)),
                @"daemon_build": safeBuildVersion,
                @"daemon_marketing_version": safeMarketingVersion,
            }];
            // Preserve the typed local NSError for the support log without
            // sending a second unstructured remote event.
            NSLog(@"AppController: Daemon compatibility error (domain=%@ code=%ld)",
                  compatibilityError.domain, (long)compatibilityError.code);
        });
    }];
}

- (void)telemetryConsentDidChange:(NSNotification *)notification {
    if (self.xpc == nil) return;
    telemetryStartupCheckCompleted_ = NO;
    telemetryStartupCheckInFlight_ = NO;
    telemetryStartupCheckAttempts_ = 0;
    [self synchronizeTelemetryConsentAndDrain];
    if (lastCompatibleDaemonProtocol_ > 0) {
        [self runTelemetryConsistencyCheckWithDaemonProtocol:lastCompatibleDaemonProtocol_];
    }
}

- (void)synchronizeTelemetryConsentAndDrain {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger storedGeneration = [defaults integerForKey:SCTelemetryConsentGenerationDefaultsKey];
    NSUInteger generation = storedGeneration > 0 ? (NSUInteger)storedGeneration : 1;
    if (storedGeneration <= 0) {
        // An initial off generation lets a current build purge any historical
        // daemon queue without treating unknown consent as enabled.
        [defaults setInteger:(NSInteger)generation forKey:SCTelemetryConsentGenerationDefaultsKey];
        [defaults synchronize];
    }
    BOOL enabled = [SCSentry errorReportingEnabled];
    [self.xpc setTelemetryConsentEnabled:enabled generation:generation reply:^(NSError *error) {
        if (error != nil) {
            NSLog(@"AppController: Telemetry consent propagation failed (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
            return;
        }
        if (enabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self drainTelemetrySpoolWithRemainingBatches:4];
            });
        }
    }];
}

- (void)drainTelemetrySpoolWithRemainingBatches:(NSUInteger)remainingBatches {
    if (remainingBatches == 0 || ![SCSentry errorReportingEnabled]) {
        telemetryDrainInFlight_ = NO;
        return;
    }
    if (telemetryDrainInFlight_ && remainingBatches == 4) return;
    telemetryDrainInFlight_ = YES;

    [self.xpc fetchTelemetryRecordsWithLimit:25
                                       reply:^(NSArray<NSDictionary<NSString *,id> *> *records, NSError *error) {
        if (error != nil) {
            NSLog(@"AppController: Telemetry fetch failed (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
            self->telemetryDrainInFlight_ = NO;
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSString *> *capturedRecordIDs = [NSMutableArray array];
            for (NSDictionary<NSString *, id> *record in records) {
                NSString *eventID = [SCSentry captureSpooledTelemetryRecord:record];
                NSString *recordID = [record[@"id"] isKindOfClass:[NSString class]] ? record[@"id"] : nil;
                if (eventID.length > 0 && recordID.length > 0) [capturedRecordIDs addObject:recordID];
            }

            if (capturedRecordIDs.count == 0) {
                self->telemetryDrainInFlight_ = NO;
                return;
            }
            [self.xpc acknowledgeTelemetryRecordIDs:capturedRecordIDs reply:^(NSError *ackError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ackError != nil) {
                        NSLog(@"AppController: Telemetry acknowledgement failed (domain=%@ code=%ld)",
                              ackError.domain, (long)ackError.code);
                        self->telemetryDrainInFlight_ = NO;
                        return;
                    }
                    if (records.count == 25 && remainingBatches > 1) {
                        [self drainTelemetrySpoolWithRemainingBatches:remainingBatches - 1];
                    } else {
                        self->telemetryDrainInFlight_ = NO;
                    }
                });
            }];
        });
    }];
}

- (void)captureStartupDivergenceFields:(NSDictionary<NSString *, id> *)fields {
    NSString *signature = [SCSentry privacySafeTelemetrySignatureForFields:fields
                                                                  eventName:@"state.app_daemon_diverged"];
    if (signature == nil) {
        NSLog(@"AppController: Rejected invalid startup divergence payload");
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousSignatureValue = [defaults objectForKey:kTelemetryConsistencyLastSignatureKey];
    NSString *previousSignature = [previousSignatureValue isKindOfClass:[NSString class]]
        ? previousSignatureValue : nil;
    id previousDateValue = [defaults objectForKey:kTelemetryConsistencyLastEmissionDateKey];
    NSDate *previousEmissionDate = [previousDateValue isKindOfClass:[NSDate class]]
        ? previousDateValue : nil;
    NSDate *now = [NSDate date];
    BOOL shouldEmit = [SCSentry shouldEmitTelemetrySignature:signature
                                          previousSignature:previousSignature
                                       previousEmissionDate:previousEmissionDate
                                                        now:now
                                        suppressionInterval:kTelemetryConsistencySuppressionInterval];
    if (!shouldEmit) {
        [SCSentry addBreadcrumb:@"Suppressed repeated startup consistency violation"
                       category:@"telemetry.consistency"];
        return;
    }

    NSString *eventID = [SCSentry captureTelemetryEvent:@"state.app_daemon_diverged"
                                                  level:SCTelemetryEventLevelError
                                                 fields:fields];
    if (eventID.length > 0) {
        [defaults setObject:signature forKey:kTelemetryConsistencyLastSignatureKey];
        [defaults setObject:now forKey:kTelemetryConsistencyLastEmissionDateKey];
        [defaults synchronize];
    }
}

- (void)runTelemetryConsistencyCheckWithDaemonProtocol:(NSInteger)protocolVersion {
    if (telemetryStartupCheckCompleted_ || telemetryStartupCheckInFlight_ ||
        telemetryStartupCheckAttempts_ >= 2) return;
    telemetryStartupCheckInFlight_ = YES;
    telemetryStartupCheckAttempts_ += 1;

    SCScheduleManager *scheduleManager = [SCScheduleManager sharedManager];
    NSDictionary<NSString *, NSNumber *> *appSnapshot = [scheduleManager telemetryStructuralSnapshot];
    // This projection stays inside the authenticated local XPC boundary. It
    // may contain entries/dates; only the daemon's aggregate comparison reply
    // is eligible for telemetry.
    NSDictionary<NSString *, id> *expectedState = [scheduleManager daemonConsistencyProjection];
    [self.xpc getSanitizedDaemonSnapshotForExpectedState:expectedState
                                                   reply:^(NSDictionary<NSString *,id> *daemonSnapshot, NSError *error) {
        self->telemetryStartupCheckInFlight_ = NO;
        if (error != nil || daemonSnapshot.count == 0) {
            NSLog(@"AppController: Consistency snapshot unavailable (domain=%@ code=%ld)",
                  error.domain, (long)error.code);
            if (self->telemetryStartupCheckAttempts_ < 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self runTelemetryConsistencyCheckWithDaemonProtocol:protocolVersion];
                });
            } else {
                self->telemetryStartupCheckCompleted_ = YES;
                NSDictionary<NSString *, id> *divergenceFields = @{
                    @"reason": @"projection_mismatch",
                    @"collector_status": @"failed",
                    @"settings_available": @NO,
                    @"block_running": @([SCBlockUtilities modernBlockIsRunning]),
                    @"app_has_schedule_state": appSnapshot[@"app_has_schedule_state"] ?: @NO,
                    @"active_counts_match": @NO,
                    @"approval_counts_match": @NO,
                    @"plist_counts_match": @NO,
                    @"job_counts_match": @NO,
                    @"pf_active": @NO,
                    @"hosts_active": @NO,
                    @"app_monitoring": @NO,
                    @"physical_layers_match": @NO,
                    @"app_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
                    @"app_week_count": appSnapshot[@"decoded_schedule_count"] ?: @0,
                    @"app_commitment_count": appSnapshot[@"commitment_count"] ?: @0,
                    @"daemon_active_entry_count": @0,
                    @"daemon_approval_count": @0,
                    @"daemon_approval_entry_count": @0,
                    @"daemon_plist_count": @0,
                    @"daemon_job_count": @0,
                    @"raw_bundle_count": appSnapshot[@"raw_bundle_count"] ?: @0,
                    @"decoded_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
                    @"rendered_bundle_count": appSnapshot[@"decoded_bundle_count"] ?: @0,
                    @"active_expected_count": @0,
                    @"active_actual_count": @0,
                    @"active_missing_count": @0,
                    @"active_extra_count": @0,
                    @"approval_expected_count": @0,
                    @"approval_actual_count": @0,
                    @"approval_missing_count": @0,
                    @"approval_extra_count": @0,
                    @"plist_expected_count": @0,
                    @"plist_actual_count": @0,
                    @"plist_missing_count": @0,
                    @"plist_extra_count": @0,
                    @"loaded_job_expected_count": @0,
                    @"loaded_job_actual_count": @0,
                    @"loaded_job_missing_count": @0,
                    @"loaded_job_extra_count": @0,
                    @"launchd_probe_failure_count": @0,
                    @"invalid_approval_count": @0,
                    @"invalid_plist_count": @0,
                };
                [self captureStartupDivergenceFields:divergenceFields];
            }
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self->telemetryStartupCheckCompleted_ = YES;
            NSUInteger rawBundleCount = [appSnapshot[@"raw_bundle_count"] unsignedIntegerValue];
            NSUInteger decodedBundleCount = [appSnapshot[@"decoded_bundle_count"] unsignedIntegerValue];
            NSUInteger rawScheduleCount = [appSnapshot[@"raw_schedule_count"] unsignedIntegerValue];
            NSUInteger decodedScheduleCount = [appSnapshot[@"decoded_schedule_count"] unsignedIntegerValue];
            NSUInteger commitmentCount = [appSnapshot[@"commitment_count"] unsignedIntegerValue];
            NSUInteger expectedActiveCount = [appSnapshot[@"expected_active_entry_count"] unsignedIntegerValue];
            NSUInteger expectedActiveAppCount = [appSnapshot[@"expected_active_app_entry_count"] unsignedIntegerValue];
            NSUInteger expectedActiveSiteCount = [appSnapshot[@"expected_active_site_entry_count"] unsignedIntegerValue];
            BOOL expectedRequiresHosts = [appSnapshot[@"expected_requires_hosts"] boolValue];
            BOOL expectedRequiresPacketFilter = [appSnapshot[@"expected_requires_packet_filter"] boolValue];
            BOOL projectionAvailable = [appSnapshot[@"active_projection_available"] boolValue];
            BOOL appHasScheduleState = [appSnapshot[@"app_has_schedule_state"] boolValue];

            BOOL blockRunning = [daemonSnapshot[@"block_running"] boolValue];
            BOOL settingsAvailable = [daemonSnapshot[@"settings_available"] boolValue];
            BOOL pfActive = [daemonSnapshot[@"pf_active"] boolValue];
            BOOL hostsActive = [daemonSnapshot[@"hosts_active"] boolValue];
            BOOL appMonitoring = [daemonSnapshot[@"app_monitoring"] boolValue];
            NSUInteger daemonActiveCount = [daemonSnapshot[@"active_entry_count"] unsignedIntegerValue];
            NSUInteger daemonApprovalCount = [daemonSnapshot[@"approved_schedule_count"] unsignedIntegerValue];
            NSUInteger daemonApprovalEntryCount = [daemonSnapshot[@"approved_entry_count"] unsignedIntegerValue];
            NSUInteger daemonPlistCount = [daemonSnapshot[@"schedule_plist_count"] unsignedIntegerValue];
            NSUInteger daemonJobCount = [daemonSnapshot[@"schedule_job_count"] unsignedIntegerValue];
            NSString *collectorStatus = [daemonSnapshot[@"collector_status"] isKindOfClass:[NSString class]]
                ? daemonSnapshot[@"collector_status"] : @"partial";
            NSString *comparisonStatus = [daemonSnapshot[@"comparison_status"] isKindOfClass:[NSString class]]
                ? daemonSnapshot[@"comparison_status"] : @"unavailable";

            BOOL physicalLayersMatch = blockRunning
                ? ((expectedActiveSiteCount == 0 ||
                  ((!expectedRequiresHosts || hostsActive) &&
                   (!expectedRequiresPacketFilter || pfActive))) &&
                 (expectedActiveAppCount == 0 || appMonitoring))
                : !(pfActive || hostsActive || appMonitoring);
            BOOL activeCountsMatch = SCAppDaemonActiveStateMatches(
                projectionAvailable,
                [daemonSnapshot[@"active_comparison_available"] boolValue],
                [daemonSnapshot[@"active_entries_match"] boolValue],
                blockRunning,
                expectedActiveCount > 0,
                physicalLayersMatch);
            BOOL approvalCountsMatch = [daemonSnapshot[@"approval_schedules_match"] boolValue];
            BOOL plistCountsMatch = [daemonSnapshot[@"plist_schedules_match"] boolValue];
            BOOL jobCountsMatch = [daemonSnapshot[@"loaded_jobs_match"] boolValue];

            if (rawBundleCount > decodedBundleCount || rawScheduleCount > decodedScheduleCount) {
                [SCSentry captureTelemetryEvent:@"state.app_defaults_regressed"
                                          level:SCTelemetryEventLevelError
                                         fields:@{
                    @"reason": @"decode_loss",
                    @"current_domain_has_state": @(appHasScheduleState),
                    @"legacy_domain_has_state": @NO,
                    @"migration_applied": @NO,
                    @"current_bundle_count": @(decodedBundleCount),
                    @"current_week_count": @(decodedScheduleCount),
                    @"current_commitment_count": @(commitmentCount),
                    @"raw_bundle_count": @(rawBundleCount),
                    @"decoded_bundle_count": @(decodedBundleCount),
                }];
            }

            NSString *divergenceReason = nil;
            BOOL daemonHasScheduledState = daemonApprovalCount > 0 || daemonPlistCount > 0 || daemonJobCount > 0;
            if ((blockRunning || daemonHasScheduledState) && !appHasScheduleState) {
                divergenceReason = @"app_state_missing";
            } else if (![collectorStatus isEqualToString:@"complete"] ||
                       ![comparisonStatus isEqualToString:@"exact"]) {
                divergenceReason = @"projection_mismatch";
            } else if (!activeCountsMatch) {
                divergenceReason = @"active_state_mismatch";
            } else if (!approvalCountsMatch || !plistCountsMatch || !jobCountsMatch) {
                divergenceReason = @"schedule_drift";
            }

            if (divergenceReason != nil) {
                NSDictionary<NSString *, id> *divergenceFields = @{
                    @"reason": divergenceReason,
                    @"collector_status": collectorStatus,
                    @"settings_available": @(settingsAvailable),
                    @"block_running": @(blockRunning),
                    @"app_has_schedule_state": @(appHasScheduleState),
                    @"active_counts_match": @(activeCountsMatch),
                    @"approval_counts_match": @(approvalCountsMatch),
                    @"plist_counts_match": @(plistCountsMatch),
                    @"job_counts_match": @(jobCountsMatch),
                    @"pf_active": @(pfActive),
                    @"hosts_active": @(hostsActive),
                    @"app_monitoring": @(appMonitoring),
                    @"physical_layers_match": @(physicalLayersMatch),
                    @"app_bundle_count": @(decodedBundleCount),
                    @"app_week_count": @(decodedScheduleCount),
                    @"app_commitment_count": @(commitmentCount),
                    @"daemon_active_entry_count": @(daemonActiveCount),
                    @"daemon_approval_count": @(daemonApprovalCount),
                    @"daemon_approval_entry_count": @(daemonApprovalEntryCount),
                    @"daemon_plist_count": @(daemonPlistCount),
                    @"daemon_job_count": @(daemonJobCount),
                    @"raw_bundle_count": @(rawBundleCount),
                    @"decoded_bundle_count": @(decodedBundleCount),
                    @"rendered_bundle_count": @(decodedBundleCount),
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
                };
                [self captureStartupDivergenceFields:divergenceFields];
            } else {
                [SCSentry addBreadcrumb:@"Startup consistency checks passed"
                               category:@"telemetry.consistency"];
            }

            NSLog(@"AppController: Consistency snapshot complete (protocol=%ld divergence=%@)",
                  (long)protocolVersion, divergenceReason ?: @"none");
        });
    }];
}

- (void)emitDaemonUnreachableRepairOutcome:(NSString*)outcome
                                finalError:(nullable NSError*)finalError
                        reinstallSucceeded:(BOOL)reinstallSucceeded
                         reconnectAttempted:(BOOL)reconnectAttempted
              postRepairHandshakeSucceeded:(BOOL)postRepairHandshakeSucceeded
                      postRepairCompatible:(BOOL)postRepairCompatible {
    if (daemonUnreachableInitialError_ == nil || daemonUnreachableTelemetryEmitted_) return;

    // The user declining an authorization prompt is not an operational
    // incident. Clear the pending attempt without creating a noisy error.
    if ([SCMiscUtilities errorIsAuthCanceled:finalError]) {
        daemonUnreachableInitialError_ = nil;
        return;
    }

    NSDictionary *fields = [SCXPCClient daemonUnreachableReinstallTelemetryFieldsForOutcome:outcome
                                                                        initialHandshakeError:daemonUnreachableInitialError_
                                                                                   finalError:finalError
                                                                installedHelperPresentBefore:daemonUnreachableInstalledHelperPresentBefore_
                                                                 installedHelperPresentAfter:SCFileExistsAtPath(kInstalledDaemonPath)
                                                                        bundledHelperPresent:daemonUnreachableBundledHelperPresent_
                                                                          reinstallSucceeded:reinstallSucceeded
                                                                           reconnectAttempted:reconnectAttempted
                                                                postRepairHandshakeSucceeded:postRepairHandshakeSucceeded
                                                                        postRepairCompatible:postRepairCompatible];
    if (fields != nil) {
        [SCSentry captureTelemetryEvent:@"daemon.unreachable_reinstall"
                                  level:SCTelemetryEventLevelError
                                 fields:fields];
        daemonUnreachableTelemetryEmitted_ = YES;
    }
    daemonUnreachableInitialError_ = nil;
}

- (void)reinstallDaemon {
    NSLog(@"Attempting to reinstall daemon...");
    [SCSentry addBreadcrumb:@"Reinstalling daemon" category:@"app"];
    [self.xpc installDaemon:^(NSError * _Nonnull error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error == nil) {
                NSLog(@"Reinstalled daemon successfully!");
                [SCSentry addBreadcrumb:@"Daemon reinstalled successfully" category:@"app"];
                NSLog(@"Refreshing helper tool connection and verifying compatibility once...");
                [self.xpc refreshConnectionAndRun:^{
                    [self checkDaemonCompatibilityAllowingRepair:NO];
                }];
            } else {
                self->daemonCompatibilityRepairInFlight_ = NO;
                if (self->daemonUnreachableInitialError_ != nil) {
                    [self emitDaemonUnreachableRepairOutcome:@"install_failed"
                                                  finalError:error
                                          reinstallSucceeded:NO
                                           reconnectAttempted:NO
                                postRepairHandshakeSucceeded:NO
                                        postRepairCompatible:NO];
                }
                if (![SCMiscUtilities errorIsAuthCanceled:error]) {
                    NSLog(@"ERROR: Reinstalling daemon failed with error %@", error);
                    [SCSentry addBreadcrumb:@"Detected out-of-date daemon" category:@"app"];
                    [SCUIUtilities presentError:error];
                }
            }
        });
    }];
}

- (void)configureDomainListForCurrentState {
    if (domainListWindowController_ == nil) return;

    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    BOOL blockRunning = [SCUIUtilities blockIsRunning];
    BOOL isTestBlock = [[[SCSettings sharedSettings] valueForKey:@"IsTestBlock"] boolValue];
    BOOL readOnly = blockRunning || manager.isCommitted;
    domainListWindowController_.readOnly = readOnly;
    domainListWindowController_.readOnlyNoticeText = nil;
    domainListWindowController_.readOnlyNoticeColor = nil;

    if (blockRunning && isTestBlock) {
        NSArray *activeBlocklist = [[SCSettings sharedSettings] valueForKey:@"ActiveBlocklist"];
        domainListWindowController_.displayEntries = [activeBlocklist mutableCopy] ?: @[];
        domainListWindowController_.readOnlyNoticeText =
            @"Locked while the test block is running.";
        return;
    }

    if (manager.isCommitted || blockRunning) {
        NSMutableOrderedSet<NSString *> *underlyingEntries = [NSMutableOrderedSet orderedSet];
        for (SCBlockBundle *bundle in manager.bundles) {
            if (!bundle.enabled || bundle.entries.count == 0) continue;
            if (![manager wouldBundleBeAllowed:bundle.bundleID]) {
                [underlyingEntries addObjectsFromArray:bundle.entries];
            }
        }
        domainListWindowController_.displayEntries = underlyingEntries.array;

        BOOL breakSuspendsEnforcement = manager.hasActiveTimedBreak &&
            !manager.protectedHoursActiveNow;
        if (breakSuspendsEnforcement) {
            domainListWindowController_.readOnlyNoticeText =
                @"Break active — listed apps and sites are allowed.";
            domainListWindowController_.readOnlyNoticeColor = NSColor.systemGreenColor;
        } else {
            domainListWindowController_.readOnlyNoticeText =
                @"Apps and websites currently being fenced";
            domainListWindowController_.readOnlyNoticeColor = NSColor.systemRedColor;
        }
    } else {
        domainListWindowController_.displayEntries = nil;
    }
}

- (IBAction)showDomainList:(id)sender {
    [SCSentry addBreadcrumb: @"Showing domain list" category:@"app"];

	if(domainListWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"DomainList" owner: self topLevelObjects: nil];
	}

    [self configureDomainListForCurrentState];

    [domainListWindowController_ showWindow: self];

    // Activate app to bring window to front (required for LSUIElement apps)
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)presentPermissionsRepairResult:(BOOL)repaired error:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    if (repaired) {
        alert.messageText = NSLocalizedString(@"Fence permissions repaired", @"Permissions repair success title");
        alert.informativeText = NSLocalizedString(@"Try adding the site or app again. Fence will ask macOS for permission if a fresh authorization is needed.", @"Permissions repair success message");
    } else {
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = NSLocalizedString(@"Fence could not repair permissions", @"Permissions repair failure title");
        alert.informativeText = error.localizedDescription ?: NSLocalizedString(@"Restart Fence and try again. If the problem continues, choose Send Diagnostic Report Now from the Fence menu.", @"Permissions repair failure message");
    }
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)repairFencePermissionsFromUserAction {
    [self.xpc ensureCurrentDaemonForUserInitiatedAction:^(NSError *daemonError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (daemonError != nil) {
                [self presentPermissionsRepairResult:NO error:daemonError];
                return;
            }

            NSError *authorizationError = nil;
            BOOL repaired = [self.xpc
                refreshAuthorizationRightsAllowingInteraction:YES
                                                         error:&authorizationError];
            if (!repaired) {
                [self presentPermissionsRepairResult:NO error:authorizationError];
                return;
            }

            // A legacy helper's protocol-6 runtime omits timezone fields. Once
            // an explicit Repair has installed and verified the current helper,
            // refresh the local read model from the upgraded root authority.
            [[SCScheduleManager sharedManager]
                refreshRecurringRuntimeStateWithCompletion:^(BOOL refreshed, NSError *refreshError) {
                if (!refreshed) {
                    NSLog(@"AppController: Permissions repaired but recurring runtime refresh failed (domain=%@ code=%ld)",
                          refreshError.domain, (long)refreshError.code);
                }
                [self presentPermissionsRepairResult:YES error:nil];
            }];
        });
    }];
}

- (void)closeDomainList {
	[domainListWindowController_ close];
	domainListWindowController_ = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed: (NSApplication*) theApplication {
    // Don't terminate if app hasn't finished launching yet
    // (prevents quit when user declines "Move to Applications" dialog)
    if (!appDidFinishLaunching_)
        return NO;

	// Hack to make the application terminate after the last window is closed, but
	// INCLUDE the HUD-style timer window.
	if([[timerWindowController_ window] isVisible])
		return NO;

	// Don't terminate if menu bar UI is active (block is running)
	if([[SCMenuBarController sharedController] isVisible])
		return NO;

    if (PFMoveIsInProgress())
        return NO;

	return YES;
}

- (void)addToBlockList:(NSString*)host lock:(NSLock*)lock {
    NSLog(@"Adding one entry to the blocklist");
    // Note we RETRIEVE the latest list from settings (ActiveBlocklist), but we SET the new list in defaults
    // since the helper daemon should be the only one changing ActiveBlocklist
    NSMutableArray* list = [[settings_ valueForKey: @"ActiveBlocklist"] mutableCopy];
    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: host];
    
    if (cleanedEntries.count == 0) return;
    
    for (NSUInteger i = 0; i < cleanedEntries.count; i++) {
        NSString* entry = cleanedEntries[i];
        // don't add duplicate entries
        if (![list containsObject: entry]) {
            [list addObject: entry];
        }
    }
       
	[defaults_ setValue: list forKey: @"Blocklist"];

	if(![SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is not on.
		// so the Start button should be disabled.
		// Maybe the UI didn't get properly refreshed, so try refreshing it again
		// before we return.
		[self refreshUserInterface];

        NSError* err = [SCErr errorWithCode: 102];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    [NSThread detachNewThreadSelector: @selector(updateActiveBlocklist:) toTarget: self withObject: lock];
}

- (void)extendBlockTime:(NSInteger)minutesToAdd lock:(NSLock*)lock {
    // sanity check: extending a block for 0 minutes is useless; 24 hour should be impossible
    NSInteger maxBlockLength = [defaults_ integerForKey: @"MaxBlockLength"];
    if(minutesToAdd < 1) return;
    if (minutesToAdd > maxBlockLength) {
        minutesToAdd = maxBlockLength;
    }
    
    // ensure block health before we try to change it
    if(![SCUIUtilities blockIsRunning]) {
        // This method shouldn't be getting called, a block is not on.
        // so the Start button should be disabled.
        // Maybe the UI didn't get properly refreshed, so try refreshing it again
        // before we return.
        [self refreshUserInterface];
        
        NSError* err = [SCErr errorWithCode: 103];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        
        return;
    }
  
    [self updateBlockEndDate: lock minutesToAdd: minutesToAdd];
//    [NSThread detachNewThreadSelector: @selector(extendBlockDuration:)
//                             toTarget: self
//                           withObject: @{
//                                         @"lock": lock,
//                                         @"minutesToAdd": @(minutesToAdd)
//                                                                                                    }];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self
											name: @"SCConfigurationChangedNotification"
										  object: nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self
											name:SCScheduleManagerDidChangeNotification
										  object:nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
															   name: @"SCConfigurationChangedNotification"
														 object: nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (id)initialWindow {
	return initialWindow_;
}

- (id)domainListWindowController {
	return domainListWindowController_;
}

- (void)setDomainListWindowController:(id)newController {
	domainListWindowController_ = newController;
}

- (void)installBlock {
    [SCSentry addBreadcrumb: @"App running installBlock method" category:@"app"];
	@autoreleasepool {
		self.addingBlock = true;

        // if there are any ongoing edits in the domain list, make sure they make it in
        if (domainListWindowController_ != nil) {
            [domainListWindowController_ refreshDomainList];
        }
		[self refreshUserInterface];

        [self.xpc installDaemon:^(NSError * _Nonnull error) {
            if (error != nil) {
                [SCUIUtilities presentError: error];
                self.addingBlock = false;
                [self refreshUserInterface];
                return;
            } else {
                [SCSentry addBreadcrumb: @"Daemon installed successfully (en route to installing block)" category:@"app"];
                // helper tool installed successfully, let's prepare to start the block!
                // for legacy reasons, BlockDuration is in minutes, so convert it to seconds before passing it through]
                // sanity check duration (must be above zero)
                NSTimeInterval blockDurationSecs = MAX([[self->defaults_ valueForKey: @"BlockDuration"] intValue] * 60, 0);
                NSDate* newBlockEndDate = [NSDate dateWithTimeIntervalSinceNow: blockDurationSecs];
                
                // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
                [self->settings_ synchronizeSettings];
                [self->defaults_ synchronize];

                // ok, the new helper tool is installed! refresh the connection, then it's time to start the block
                [self.xpc refreshConnectionAndRun:^{
                    NSLog(@"Refreshed connection and ready to start block!");
                    [self.xpc startBlockWithControllingUID: getuid()
                                                 blocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                                               isAllowlist: [self->defaults_ boolForKey: @"BlockAsWhitelist"]
                                                   endDate: newBlockEndDate
                                             blockSettings: @{
                                                                @"ClearCaches": [self->defaults_ valueForKey: @"ClearCaches"],
                                                                @"AllowLocalNetworks": [self->defaults_ valueForKey: @"AllowLocalNetworks"],
                                                                @"EvaluateCommonSubdomains": [self->defaults_ valueForKey: @"EvaluateCommonSubdomains"],
                                                                @"IncludeLinkedDomains": [self->defaults_ valueForKey: @"IncludeLinkedDomains"],
                                                                @"BlockSoundShouldPlay": [self->defaults_ valueForKey: @"BlockSoundShouldPlay"],
                                                                @"BlockSound": [self->defaults_ valueForKey: @"BlockSound"],
                                                                @"EnableErrorReporting": @([SCSentry errorReportingEnabled])
                                                            }
                                                     reply:^(NSError * _Nonnull error) {
                        if (error != nil) {
                            [SCUIUtilities presentError: error];
                        } else {
                            [SCSentry addBreadcrumb: @"Block started successfully" category:@"app"];
                        }
                        
                        // get the new settings
                        [self->settings_ synchronizeSettingsWithCompletion:^(NSError * _Nullable error) {
                            self.addingBlock = false;
                            [self refreshUserInterface];
                        }];
                    }];
                }];
            }
        }];
	}
}

- (void)updateActiveBlocklist:(NSLock*)lockToUse {
	if(![lockToUse tryLock]) {
		return;
	}
    
    [SCSentry addBreadcrumb: @"App running updateActiveBlocklist method" category:@"app"];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        NSLog(@"Refreshed connection updating active blocklist!");
        [self.xpc updateBlocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                            reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeAddSheet:) withObject: self waitUntilDone: YES];
            
            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"Blocklist updated successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

// it really sucks, but we can't change any values that are KVO-bound to the UI unless they're on the main thread
// to make that easier, here is a helper that always does it on the main thread
- (void)setDefaultsBlockDurationOnMainThread:(NSNumber*)newBlockDuration {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread: @selector(setDefaultsBlockDurationOnMainThread:) withObject:newBlockDuration waitUntilDone: YES];
    }

    [defaults_ setInteger: [newBlockDuration intValue] forKey: @"BlockDuration"];
}

- (void)updateBlockEndDate:(NSLock*)lockToUse minutesToAdd:(NSInteger)minutesToAdd {
    if(![lockToUse tryLock]) {
        return;
    }
    [SCSentry addBreadcrumb: @"App running updateBlockEndDate method" category:@"app"];

    minutesToAdd = MAX(minutesToAdd, 0); // make sure there's no funny business with negative minutes
    NSDate* oldBlockEndDate = [settings_ valueForKey: @"BlockEndDate"];
    NSDate* newBlockEndDate = [oldBlockEndDate dateByAddingTimeInterval: (minutesToAdd * 60)];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        // Before we try to extend the block, make sure the block time didn't run out (or is about to run out) in the meantime
        if ([SCBlockUtilities currentBlockIsExpired] || [oldBlockEndDate timeIntervalSinceNow] < 1) {
            // we're done, or will be by the time we get to it! so just let it expire. they can restart it.
            [lockToUse unlock];
            return;
        }

        NSLog(@"Refreshed connection updating active block end date!");
        [self.xpc updateBlockEndDate: newBlockEndDate
                               reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeAddSheet:) withObject: self waitUntilDone: YES];

            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"App extended block duration successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

- (IBAction)save:(id)sender {
	NSSavePanel *sp;
	long runResult;

	/* create or get the shared instance of NSSavePanel */
	sp = [NSSavePanel savePanel];
	sp.allowedFileTypes = @[@"selfcontrol"];

	/* display the NSSavePanel */
	runResult = [sp runModal];

	/* if successful, save file under designated name */
	if (runResult == NSModalResponseOK) {
        NSError* err;
        [SCBlockFileReaderWriter writeBlocklistToFileURL: sp.URL
                                   blockInfo: @{
                                       @"Blocklist": [defaults_ arrayForKey: @"Blocklist"],
                                       @"BlockAsWhitelist": [defaults_ objectForKey: @"BlockAsWhitelist"]
                                       
                                   }
                                   error: &err];

        if (err != nil) {
            NSError* displayErr = [SCErr errorWithCode: 101 subDescription: err.localizedDescription];
            [SCSentry captureError: displayErr];
            NSBeep();
            [SCUIUtilities presentError: displayErr];
			return;
        } else {
            [SCSentry addBreadcrumb: @"Saved blocklist to file" category:@"app"];
        }
	}
}

- (BOOL)openSavedBlockFileAtURL:(NSURL*)fileURL {
    NSDictionary* settingsFromFile = [SCBlockFileReaderWriter readBlocklistFromFile: fileURL];
    
    if (settingsFromFile != nil) {
        [defaults_ setObject: settingsFromFile[@"Blocklist"] forKey: @"Blocklist"];
        [defaults_ setObject: settingsFromFile[@"BlockAsWhitelist"] forKey: @"BlockAsWhitelist"];
        [SCSentry addBreadcrumb: @"Opened blocklist from file" category:@"app"];
    } else {
        NSLog(@"WARNING: Could not read a valid blocklist from file - ignoring.");
        return NO;
    }

    // send a notification so the domain list (etc) updates
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
    
    [self refreshUserInterface];
    return YES;
}

- (IBAction)open:(id)sender {
	NSOpenPanel* oPanel = [NSOpenPanel openPanel];
	oPanel.allowedFileTypes = @[@"selfcontrol"];
	oPanel.allowsMultipleSelection = NO;

	long result = [oPanel runModal];
	if (result == NSModalResponseOK) {
		if([oPanel.URLs count] > 0) {
            [self openSavedBlockFileAtURL: oPanel.URLs[0]];
		}
	}
}

- (BOOL)application:(NSApplication*)theApplication openFile:(NSString*)filename {
    return [self openSavedBlockFileAtURL: [NSURL fileURLWithPath: filename]];
}

- (IBAction)openFAQ:(id)sender {
    [SCSentry addBreadcrumb: @"Opened Fence FAQ" category:@"app"];
	NSURL *url=[NSURL URLWithString: @"https://usefence.app/faq"];
	[[NSWorkspace sharedWorkspace] openURL: url];
}

- (IBAction)openSupportHub:(id)sender {
    [SCSentry addBreadcrumb: @"Opened Fence Support Hub" category:@"app"];
    NSURL *url=[NSURL URLWithString: @"https://usefence.app/support"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}

- (void)sendDiagnosticReportFromUserAction {
    if (diagnosticReportInFlight_) return;

    if (![SCSentry errorReportingEnabled]) {
        NSAlert *consentAlert = [[NSAlert alloc] init];
        consentAlert.messageText = NSLocalizedString(@"Turn On Error Reporting", @"Diagnostic report consent alert title");
        consentAlert.informativeText = NSLocalizedString(@"Enable “Send Anonymized Error Reports” in the Fence menu, then try again.", @"Diagnostic report consent alert body");
        consentAlert.alertStyle = NSAlertStyleInformational;
        [consentAlert addButtonWithTitle:NSLocalizedString(@"OK", @"Alert confirmation button")];
        [NSApp activateIgnoringOtherApps:YES];
        [consentAlert runModal];
        return;
    }

    diagnosticReportInFlight_ = YES;
    [SCSentry addBreadcrumb:@"Requested diagnostic report" category:@"app"];
    NSDictionary<NSString *, NSNumber *> *uiSnapshot = self.weekScheduleWindowController != nil
        ? [self.weekScheduleWindowController telemetryRenderSnapshot]
        : nil;

    NSAlert *progressAlert = [[NSAlert alloc] init];
    progressAlert.messageText = NSLocalizedString(@"Sending Diagnostic Report…", @"Diagnostic report progress title");
    progressAlert.informativeText = NSLocalizedString(@"Fence is collecting anonymized app, calendar, and blocker state. No websites, app names, or blocklist contents are included.", @"Diagnostic report progress body");
    progressAlert.alertStyle = NSAlertStyleInformational;
    NSButton *progressButton = [progressAlert addButtonWithTitle:NSLocalizedString(@"Sending…", @"Diagnostic report progress button")];
    progressButton.enabled = NO;
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.indeterminate = YES;
    progressAlert.accessoryView = spinner;
    [spinner startAnimation:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [progressAlert.window center];
    [progressAlert.window makeKeyAndOrderFront:nil];

    [SCLogger sendDiagnosticReportWithUISnapshot:uiSnapshot
                                      completion:^(NSString *reference, NSError *error) {
        [spinner stopAnimation:nil];
        [progressAlert.window close];
        self->diagnosticReportInFlight_ = NO;

        if (reference.length < 8 || error != nil) {
            NSAlert *failureAlert = [[NSAlert alloc] init];
            failureAlert.messageText = NSLocalizedString(@"Couldn’t Send Diagnostic Report", @"Diagnostic report failure title");
            failureAlert.informativeText = NSLocalizedString(@"Check that anonymized error reporting is enabled and that this Mac is online, then try again.", @"Diagnostic report failure body");
            failureAlert.alertStyle = NSAlertStyleWarning;
            [failureAlert addButtonWithTitle:NSLocalizedString(@"OK", @"Alert confirmation button")];
            [NSApp activateIgnoringOtherApps:YES];
            [failureAlert runModal];
            return;
        }

        NSAlert *successAlert = [[NSAlert alloc] init];
        successAlert.messageText = NSLocalizedString(@"Diagnostic Report Sent", @"Diagnostic report success title");
        successAlert.informativeText = [NSString stringWithFormat:
            NSLocalizedString(@"Reference: %@\n\nShare this reference with Fence support so we can find the report.", @"Diagnostic report success body"),
            reference];
        successAlert.alertStyle = NSAlertStyleInformational;
        [successAlert addButtonWithTitle:NSLocalizedString(@"Copy Reference", @"Copy diagnostic reference button")];
        [successAlert addButtonWithTitle:NSLocalizedString(@"Done", @"Finish diagnostic report button")];
        [NSApp activateIgnoringOtherApps:YES];
        if ([successAlert runModal] == NSAlertFirstButtonReturn) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:reference forType:NSPasteboardTypeString];
        }
    }];
}

#pragma mark - Week Schedule (New UX)

- (IBAction)showWeekSchedule:(id)sender {
    [SCSentry addBreadcrumb: @"Opening Week Schedule window" category:@"app"];

    if (self.weekScheduleWindowController == nil) {
        self.weekScheduleWindowController = [[SCWeekScheduleWindowController alloc] init];
    }

    [self.weekScheduleWindowController showWindow:self];
    [self.weekScheduleWindowController.window makeKeyAndOrderFront:self];
    [self.weekScheduleWindowController.window center];

    // Activate app to bring window to front (required for LSUIElement apps)
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showCommitmentExtension:(id)sender {
    [self showWeekSchedule:sender];
    [self.weekScheduleWindowController presentExtendCommitmentSheet];
}

- (BOOL)commitmentExtensionInFlight {
    return self.weekScheduleWindowController.commitmentExtensionInFlight;
}

#pragma mark - Frosted Glass Appearance

- (void)setupFrostedGlassAppearance {
    [self applyFrostedGlassToWindow:initialWindow_];
}

- (void)applyFrostedGlassToWindow:(NSWindow*)window {
    NSView* contentView = window.contentView;

    // Apply window styling for transparency
    [SCUIUtilities applyFrostedGlassStyleToWindow:window];

    // Create frosted glass background view
    NSVisualEffectView* frostedBackground = [SCUIUtilities createFrostedGlassViewWithFrame:contentView.bounds cornerRadius:16.0];
    frostedBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Insert at the back so all other content appears on top
    [contentView addSubview:frostedBackground positioned:NSWindowBelow relativeTo:nil];

    // Make content view layer-backed for proper compositing
    contentView.wantsLayer = YES;

    // Force shadow recalculation
    [window invalidateShadow];
}

- (void)applyPreferencesWindowStyle {
    NSWindow* prefsWindow = preferencesWindowController_.window;
    if (!prefsWindow) return;
    NSSize contentSize = prefsWindow.contentView.bounds.size;

    prefsWindow.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
    prefsWindow.titlebarAppearsTransparent = NO;
    prefsWindow.titleVisibility = NSWindowTitleHidden;
    prefsWindow.backgroundColor = NSColor.windowBackgroundColor;
    prefsWindow.opaque = YES;
    prefsWindow.hasShadow = YES;
    if (@available(macOS 11.0, *)) {
        prefsWindow.toolbarStyle = NSWindowToolbarStylePreference;
    }
    prefsWindow.toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    prefsWindow.toolbar.showsBaselineSeparator = YES;
    [prefsWindow setContentSize:contentSize];
    [prefsWindow invalidateShadow];
}

#pragma mark - Debug Menu (DEBUG builds only)

#ifdef DEBUG

- (void)setupDebugMenu {
    NSMenu* mainMenu = [NSApp mainMenu];

    // Create Debug menu
    NSMenuItem* debugMenuItem = [[NSMenuItem alloc] initWithTitle:@"Debug"
                                                           action:nil
                                                    keyEquivalent:@""];
    NSMenu* debugMenu = [[NSMenu alloc] initWithTitle:@"Debug"];

    // Add "Disable All Blocking" item
    NSMenuItem* disableBlockingItem = [[NSMenuItem alloc]
        initWithTitle:@"Disable All Blocking"
               action:@selector(toggleDebugBlocking:)
        keyEquivalent:@""];
    disableBlockingItem.target = self;
    [debugMenu addItem:disableBlockingItem];

    // Add "Run Safety Check" item
    NSMenuItem* safetyCheckItem = [[NSMenuItem alloc]
        initWithTitle:@"Run Safety Check..."
               action:@selector(runSafetyCheck)
        keyEquivalent:@""];
    safetyCheckItem.target = self;
    [debugMenu addItem:safetyCheckItem];

    // Add "Reset Week Commitment" item
    NSMenuItem* resetCommitmentItem = [[NSMenuItem alloc]
        initWithTitle:@"Reset Week Commitment"
               action:@selector(resetWeekCommitment:)
        keyEquivalent:@""];
    resetCommitmentItem.target = self;
    [debugMenu addItem:resetCommitmentItem];

    // Add separator
    [debugMenu addItem:[NSMenuItem separatorItem]];

    // Add "Week Schedule (New UX)" item
    NSMenuItem* weekScheduleItem = [[NSMenuItem alloc]
        initWithTitle:@"Week Schedule (New UX)..."
               action:@selector(showWeekSchedule:)
        keyEquivalent:@"w"];
    weekScheduleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    weekScheduleItem.target = self;
    [debugMenu addItem:weekScheduleItem];

    // Add separator
    [debugMenu addItem:[NSMenuItem separatorItem]];

    // Add info label
    NSMenuItem* infoItem = [[NSMenuItem alloc]
        initWithTitle:@"(DEBUG BUILD ONLY)"
               action:nil
        keyEquivalent:@""];
    infoItem.enabled = NO;
    [debugMenu addItem:infoItem];

    debugMenuItem.submenu = debugMenu;

    // Insert before Help menu
    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex != -1) {
        [mainMenu insertItem:debugMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:debugMenuItem];
    }
}

- (IBAction)toggleDebugBlocking:(id)sender {
    BOOL currentState = [SCDebugUtilities isDebugBlockingDisabled];
    BOOL newState = !currentState;

    [SCDebugUtilities setDebugBlockingDisabled:newState];

    // Update the window title to show debug mode is active
    [self updateDebugIndicator];

    // If enabling debug mode, also clear existing blocking rules
    BOOL clearedRules = NO;
    if (newState) {
        clearedRules = [SCDebugUtilities clearExistingBlockingRules];
    }

    // Show alert to confirm
    NSAlert* alert = [[NSAlert alloc] init];
    if (newState) {
        // Just enabled debug mode
        [alert setMessageText:@"Debug Mode Enabled"];
        if (clearedRules) {
            [alert setInformativeText:@"ALL blocking is now disabled AND existing rules have been cleared.\n\n"
                                      @"This includes:\n"
                                      @"- Website blocking (hosts file + firewall)\n"
                                      @"- App blocking\n\n"
                                      @"The block timer will continue but no rules are enforced."];
        } else {
            [alert setInformativeText:@"Debug mode enabled but failed to clear existing rules.\n"
                                      @"You may need to run the emergency.sh script manually."];
        }
        [alert setAlertStyle:NSAlertStyleWarning];
    } else {
        // Just disabled debug mode
        [alert setMessageText:@"Debug Mode Disabled"];
        [alert setInformativeText:@"Blocking is now active again.\n"
                                  @"Note: Previously cleared rules will NOT be restored.\n"
                                  @"Restart the daemon to re-apply blocking."];
    }
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)updateDebugIndicator {
    if ([SCDebugUtilities isDebugBlockingDisabled]) {
        // Show visual indicator - change window title
        [initialWindow_ setTitle:@"Fence [DEBUG - BLOCKING DISABLED]"];
    } else {
        [initialWindow_ setTitle:@"Fence"];
    }
}

- (IBAction)resetWeekCommitment:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (![manager isCommitted]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Active Commitment";
        alert.informativeText = @"You don't have an active week commitment to reset.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }

    // Confirm reset
    NSAlert *confirmAlert = [[NSAlert alloc] init];
    confirmAlert.messageText = @"Reset Week Commitment?";
    confirmAlert.informativeText = @"This will clear your week commitment, allowing you to modify schedules freely.\n\n(DEBUG ONLY - not available in release builds)";
    [confirmAlert addButtonWithTitle:@"Reset"];
    [confirmAlert addButtonWithTitle:@"Cancel"];
    confirmAlert.alertStyle = NSAlertStyleWarning;

    if ([confirmAlert runModal] == NSAlertFirstButtonReturn) {
        [manager clearCommitmentForDebug];

        NSAlert *doneAlert = [[NSAlert alloc] init];
        doneAlert.messageText = @"Commitment Reset";
        doneAlert.informativeText = @"Your week commitment has been cleared. You can now modify schedules.";
        [doneAlert addButtonWithTitle:@"OK"];
        [doneAlert runModal];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
    if (menuItem.action == @selector(toggleDebugBlocking:)) {
        // Update checkmark state
        menuItem.state = [SCDebugUtilities isDebugBlockingDisabled]
                         ? NSControlStateValueOn
                         : NSControlStateValueOff;
        return YES;
    }
    return YES;
}

- (IBAction)triggerSafetyCheck:(id)sender {
    [self runSafetyCheck];
}

#endif

@end

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
#import "PreferencesAdvancedViewController.h"
#import "SCTimeIntervalFormatter.h"
#import <LetsMove/PFMoveApplication.h>
#import "SCSettings.h"
#import <ServiceManagement/ServiceManagement.h>
#import "SCXPCClient.h"
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
#import <Sparkle/Sparkle.h>

static NSString * const kRepairMigrationPER352CreditsAppliedKey = @"SCRepairMigrationPER352CreditsApplied";
static NSString * const kRepairMigrationPER352AuthRefreshBuildKey = @"SCRepairMigrationPER352AuthRefreshBuild";
static NSString * const kEmergencyUnlockCreditsKey = @"SCEmergencyUnlockCredits";
static NSString * const kEmergencyUnlockCreditsInitializedKey = @"SCEmergencyUnlockCreditsInitialized";
static const NSInteger kRepairMigrationEmergencyUnlockCredits = 5;

@interface AppController () {}

@property (atomic, strong, readwrite) SCXPCClient* xpc;
@property (nonatomic, strong) SCWeekScheduleWindowController* weekScheduleWindowController;
@property (nonatomic, strong, nullable) SCLicenseWindowController* licenseWindowController;
@property (nonatomic, strong, nullable) SCTestBlockWindowController* testBlockWindowController;
@property (nonatomic, strong, readwrite) SPUStandardUpdaterController* updaterController;

@end

@implementation AppController {
    BOOL appDidFinishLaunching_;
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

    if (![defaults boolForKey:kRepairMigrationPER352CreditsAppliedKey]) {
        NSInteger existingCredits = [defaults integerForKey:kEmergencyUnlockCreditsKey];
        BOOL creditsInitialized = [defaults boolForKey:kEmergencyUnlockCreditsInitializedKey];
        if (!creditsInitialized || existingCredits < kRepairMigrationEmergencyUnlockCredits) {
            [defaults setInteger:MAX(existingCredits, kRepairMigrationEmergencyUnlockCredits) forKey:kEmergencyUnlockCreditsKey];
        }
        [defaults setBool:YES forKey:kEmergencyUnlockCreditsInitializedKey];
        [defaults setBool:YES forKey:kRepairMigrationPER352CreditsAppliedKey];
        [defaults synchronize];
        NSLog(@"AppController: PER-352 repair migration restored emergency credits to at least %ld", (long)kRepairMigrationEmergencyUnlockCredits);
    }

    NSString *currentBuild = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *lastAuthRefreshBuild = [defaults stringForKey:kRepairMigrationPER352AuthRefreshBuildKey];
    if (![lastAuthRefreshBuild isEqualToString:currentBuild]) {
        NSError *authRepairError = nil;
        if ([self.xpc refreshAuthorizationRights:&authRepairError]) {
            [defaults setObject:currentBuild forKey:kRepairMigrationPER352AuthRefreshBuildKey];
            [defaults synchronize];
            NSLog(@"AppController: Refreshed Fence authorization rights for build %@", currentBuild);
        } else {
            NSLog(@"AppController: Failed to refresh Fence authorization rights: %@", authRepairError);
            if (authRepairError) {
                [SCSentry captureError:authRepairError];
            }
        }
    }
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

            // apparently, a block is running, so make sure FirstBlockStarted is true
            [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
		}
    } else { // block is off
		if(blockWasOn) { // if we just switched states to off...
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
        SCScheduleManager *manager = [SCScheduleManager sharedManager];
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
    
    // clean out empty strings from the defaults blocklist (they can end up there occasionally due to UI glitches etc)
    // note we don't screw with the actively running blocklist - that should've been cleaned before it started anyway
    NSArray<NSString*>* cleanedBlocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];

    // update our blocklist teaser string
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 60];
    
    // let the domain list know!
    if (domainListWindowController_ != nil) {
        domainListWindowController_.readOnly = [SCUIUtilities blockIsRunning];
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
		NSViewController* advancedViewController = [[PreferencesAdvancedViewController alloc] init];
		NSString* title = NSLocalizedString(@"Preferences", @"Common title for Preferences window");

		preferencesWindowController_ = [[MASPreferencesWindowController alloc] initWithViewControllers: @[generalViewController, advancedViewController] title: title];

        // Apply frosted glass styling to preferences window
        [self applyFrostedGlassToPreferencesWindow];
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
    [SCLogger ensureDirectoriesExist];

#ifdef DEBUG
    // Listen for debug actions from menu bar
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(toggleDebugBlocking:)
                                                 name:@"SCDebugDisableBlockingRequested"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resetEmergencyCredits:)
                                                 name:@"SCDebugResetCreditsRequested"
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
    [self runPostUpdateRepairMigrations];

    // if we don't have a connection within 0.5 seconds,
    // OR we get back a connection with an old daemon version
    // AND we're running a modern block (which should have a daemon running it)
    // something's wrong with our app-daemon connection. This probably means one of two things:
    //   1. The daemon got unloaded somehow and failed to restart. This is a big problem because the block won't come off.
    //   2. The daemon doesn't want to talk to us anymore, potentially because we've changed our signing certificate. This is a
    //      smaller problem, but still not great because the app can't communicate anything to the daemon.
    //   3. There's a daemon but it's an old version, and should be replaced.
    // in any case, let's go try to reinstall the daemon
    // (we debounce this call so it happens only once, after the connection has been invalidated for an extended period)
    BOOL blockIsRunning = [SCBlockUtilities modernBlockIsRunning];
    NSLog(@"AppController: Daemon update check - modernBlockIsRunning=%@, appVersion=%@",
          blockIsRunning ? @"YES" : @"NO", SELFCONTROL_VERSION_STRING);

    // Always check daemon version on app launch (cheap operation, ensures daemon stays up-to-date)
    NSLog(@"AppController: Checking daemon version in 0.5s...");
    [NSTimer scheduledTimerWithTimeInterval: 0.5 repeats: NO block:^(NSTimer * _Nonnull timer) {
        [self.xpc getVersion:^(NSString * _Nonnull daemonVersion, NSError * _Nonnull error) {
            if (error == nil) {
                NSLog(@"AppController: Daemon version check - daemonVersion=%@, appVersion=%@",
                      daemonVersion, SELFCONTROL_VERSION_STRING);
                if ([SELFCONTROL_VERSION_STRING compare: daemonVersion options: NSNumericSearch] == NSOrderedDescending) {
                    NSLog(@"AppController: Daemon OUTDATED (%@ < %@) - reinstalling...",
                          daemonVersion, SELFCONTROL_VERSION_STRING);
                    [SCSentry addBreadcrumb: @"Detected out-of-date daemon" category: @"app"];
                    [self reinstallDaemon];
                } else {
                    [SCSentry addBreadcrumb: @"Detected up-to-date daemon" category:@"app"];
                    NSLog(@"AppController: Daemon UP-TO-DATE (%@) - no action needed", daemonVersion);
                }
            } else {
                NSLog(@"AppController: ERROR fetching daemon version: %@ - reinstalling...", error);
                [self reinstallDaemon];
            }
        }];
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

- (void)reinstallDaemon {
    NSLog(@"Attempting to reinstall daemon...");
    [SCSentry addBreadcrumb: @"Reinstalling daemon" category:@"app"];
    [self.xpc installDaemon:^(NSError * _Nonnull error) {
        if (error == nil) {
            NSLog(@"Reinstalled daemon successfully!");
            [SCSentry addBreadcrumb: @"Daemon reinstalled successfully" category:@"app"];
            
            NSLog(@"Retrying helper tool connection...");
            [self.xpc performSelectorOnMainThread: @selector(connectToHelperTool) withObject: nil waitUntilDone: YES];
        } else {
            if (![SCMiscUtilities errorIsAuthCanceled: error]) {
                NSLog(@"ERROR: Reinstalling daemon failed with error %@", error);
                [SCUIUtilities presentError: error];
            }
        }
    }];
}

- (IBAction)showDomainList:(id)sender {
    [SCSentry addBreadcrumb: @"Showing domain list" category:@"app"];

	if(domainListWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"DomainList" owner: self topLevelObjects: nil];
	}

    BOOL blockRunning = [SCUIUtilities blockIsRunning];
    domainListWindowController_.readOnly = blockRunning;

    // When block is running, show the active blocklist
    if (blockRunning) {
        BOOL isTestBlock = [[[SCSettings sharedSettings] valueForKey:@"IsTestBlock"] boolValue];
        if (isTestBlock) {
            // Test block - read from ActiveBlocklist setting (not schedule manager)
            NSArray *activeBlocklist = [[SCSettings sharedSettings] valueForKey:@"ActiveBlocklist"];
            domainListWindowController_.displayEntries = [activeBlocklist mutableCopy];
        } else {
            // Regular block - gather entries from bundles currently blocking
            SCScheduleManager *manager = [SCScheduleManager sharedManager];
            NSMutableArray<NSString *> *allEntries = [NSMutableArray array];
            for (SCBlockBundle *bundle in manager.bundles) {
                // Only include entries from bundles that are currently blocking
                if (![manager wouldBundleBeAllowed:bundle.bundleID]) {
                    [allEntries addObjectsFromArray:bundle.entries];
                }
            }
            domainListWindowController_.displayEntries = allEntries;
        }
    } else {
        domainListWindowController_.displayEntries = nil;
    }

    [domainListWindowController_ showWindow: self];

    // Activate app to bring window to front (required for LSUIElement apps)
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)repairFencePermissionsFromUserAction {
    NSError *error = nil;
    BOOL repaired = [self.xpc refreshAuthorizationRightsAllowingInteraction:YES error:&error];

    NSAlert *alert = [[NSAlert alloc] init];
    if (repaired) {
        alert.messageText = NSLocalizedString(@"Fence permissions repaired", @"Permissions repair success title");
        alert.informativeText = NSLocalizedString(@"Try adding the site or app again. Fence will ask macOS for permission if a fresh authorization is needed.", @"Permissions repair success message");
    } else {
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = NSLocalizedString(@"Fence could not repair permissions", @"Permissions repair failure title");
        alert.informativeText = error.localizedDescription ?: NSLocalizedString(@"Restart Fence and try again. If the problem continues, use Report Bug from this menu.", @"Permissions repair failure message");
        if (error) {
            [SCSentry captureError:error];
        }
    }
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
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
    NSLog(@"addToBlocklist: %@", host);
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
	[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
															   name: @"SCConfigurationChangedNotification"
															 object: nil];
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
                                                                @"EnableErrorReporting": [self->defaults_ valueForKey: @"EnableErrorReporting"]
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

- (IBAction)exportLogsForSupport:(id)sender {
    [SCSentry addBreadcrumb: @"Exporting logs for support" category:@"app"];
    [SCLogger exportLogsForSupport];
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

- (void)applyFrostedGlassToPreferencesWindow {
    // MASPreferences windows need special handling because the content view changes
    // when switching between preference panes. We apply to the window itself.
    NSWindow* prefsWindow = preferencesWindowController_.window;
    if (!prefsWindow) return;

    NSView* contentView = prefsWindow.contentView;

    // Apply window styling for transparency
    [SCUIUtilities applyFrostedGlassStyleToWindow:prefsWindow];

    // Create frosted glass background view
    NSVisualEffectView* frostedBackground = [SCUIUtilities createFrostedGlassViewWithFrame:contentView.bounds cornerRadius:12.0];
    frostedBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Insert at the back so all other content appears on top
    [contentView addSubview:frostedBackground positioned:NSWindowBelow relativeTo:nil];

    // Make content view layer-backed for proper compositing
    contentView.wantsLayer = YES;

    // Force shadow recalculation
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

    // Add "Reset Emergency Credits" item
    NSMenuItem* resetCreditsItem = [[NSMenuItem alloc]
        initWithTitle:@"Reset Emergency Credits"
               action:@selector(resetEmergencyCredits:)
        keyEquivalent:@""];
    resetCreditsItem.target = self;
    [debugMenu addItem:resetCreditsItem];

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

- (IBAction)resetEmergencyCredits:(id)sender {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    [manager resetEmergencyUnlockCredits];

    NSInteger credits = [manager emergencyUnlockCreditsRemaining];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Emergency Credits Reset";
    alert.informativeText = [NSString stringWithFormat:@"Emergency unlock credits have been reset to %ld.\n\n(DEBUG ONLY)", (long)credits];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
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

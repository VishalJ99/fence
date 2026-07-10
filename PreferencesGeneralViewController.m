//
//  PreferencesGeneralViewController.m
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import "PreferencesGeneralViewController.h"
#import "SCSettings.h"
#import "SCUIUtilities.h"

@interface PreferencesGeneralViewController ()
@property (nonatomic, assign) BOOL updatingErrorReportingPreference;
@end

static void *SCErrorReportingPreferenceObservationContext = &SCErrorReportingPreferenceObservationContext;

@implementation PreferencesGeneralViewController

- (instancetype)init {
    return [super initWithNibName: @"PreferencesGeneralViewController" bundle: nil];
}

- (void)viewDidLoad  {
    [super viewDidLoad];
    // set the valid sounds in the Block Sound menu
    [self.soundMenu removeAllItems];
    [self.soundMenu addItemsWithTitles: SCConstants.systemSoundNames];

    // The checkbox is bound through NSUserDefaultsController. Observe explicit
    // user changes so legacy/system defaults can never masquerade as Fence
    // telemetry consent.
    [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
                                                               forKeyPath:@"values.EnableErrorReporting"
                                                                  options:0
                                                                  context:SCErrorReportingPreferenceObservationContext];
}

- (void)dealloc {
    @try {
        [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self
                                                                      forKeyPath:@"values.EnableErrorReporting"
                                                                         context:SCErrorReportingPreferenceObservationContext];
    } @catch (__unused NSException *exception) {
        // The view may be torn down before viewDidLoad in unusual test paths.
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context == SCErrorReportingPreferenceObservationContext) {
        if (self.updatingErrorReportingPreference) return;
        self.updatingErrorReportingPreference = YES;
        BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"EnableErrorReporting"];
        // The lifecycle broker records explicit consent, advances its
        // generation, starts/purges the SDK, and notifies AppController so the
        // daemon spool is enabled/drained or purged in the same transition.
        [SCSentry setUserErrorReportingEnabled:enabled];
        self.updatingErrorReportingPreference = NO;
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (IBAction)soundSelectionChanged:(NSPopUpButton*)sender {
	// Map the tags used in interface builder to the sound
    NSArray<NSString*>* systemSoundNames = SCConstants.systemSoundNames;
	
    NSString* selectedSoundName = sender.titleOfSelectedItem;
    NSUInteger blockSoundIndex = [systemSoundNames indexOfObject: selectedSoundName];
    if (blockSoundIndex == NSNotFound) {
        NSLog(@"WARNING: User selected unknown alert sound %@.", selectedSoundName);
        NSError* err = [SCErr errorWithCode: 310];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        return;
    }

    // now play the sound to preview it for the user
    NSSound* alertSound = [NSSound soundNamed: systemSoundNames[blockSoundIndex]];
	if(!alertSound) {
		NSLog(@"WARNING: Alert sound not found.");
        NSError* err = [SCErr errorWithCode: 311];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
	} else {
		[alertSound play];
	}
}

#pragma mark MASPreferencesViewController

- (NSString*)identifier {
	return @"GeneralPreferences";
}
- (NSImage *)toolbarItemImage {
	return [NSImage imageNamed: NSImageNamePreferencesGeneral];
}

- (NSString *)toolbarItemLabel {
	return NSLocalizedString(@"General", @"Toolbar item name for the General preference pane");
}

@end

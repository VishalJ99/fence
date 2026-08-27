
//
//  DomainListWindowController.m
//  SelfControl
//
//  Created by Charlie Stigler on 2/7/09.
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

#import "DomainListWindowController.h"
#import "AppController.h"
#import "SCBlockEntry.h"
#import "SCUIUtilities.h"
#import "NSString+IPAddress.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat SCReadOnlyBlocklistMinimumWidth = 620.0;
static const CGFloat SCReadOnlyBlocklistPreferredWidth = 680.0;
static const CGFloat SCReadOnlyBlocklistRowHeight = 44.0;

static NSCache<NSString *, NSImage *> *SCBlocklistWebsiteIconCache(void) {
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;
    });
    return cache;
}

static NSString *SCFaviconDomainForBlocklistEntry(NSString *entry) {
    SCBlockEntry *blockEntry = [SCBlockEntry entryFromString:entry];
    NSString *hostname = blockEntry.hostname;
    if (blockEntry == nil || blockEntry.isAppEntry || hostname.length == 0 ||
        blockEntry.maskLen > 0 || [hostname isEqualToString:@"*"] || hostname.isValidIPAddress) {
        return nil;
    }
    return hostname;
}

static NSURL *SCFaviconURLForDomain(NSString *domain) {
    if (domain.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/s2/favicons"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"domain" value:domain],
        [NSURLQueryItem queryItemWithName:@"sz" value:@"64"],
    ];
    return components.URL;
}

static BOOL SCBlocklistUsesDarkAppearance(NSAppearance *appearance) {
    NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua,
    ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

@interface SCBlocklistCardView : NSView
@end

@implementation SCBlocklistCardView

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    [super updateLayer];
    BOOL dark = SCBlocklistUsesDarkAppearance(self.effectiveAppearance);
    self.layer.backgroundColor = (dark
        ? [NSColor colorWithWhite:1.0 alpha:0.075]
        : [NSColor colorWithWhite:0.0 alpha:0.045]).CGColor;
    self.layer.cornerRadius = 12.0;
    self.layer.shadowColor = (dark ? NSColor.whiteColor : NSColor.blackColor).CGColor;
    self.layer.shadowOpacity = dark ? 0.08 : 0.07;
    self.layer.shadowRadius = dark ? 0.0 : 2.0;
    self.layer.shadowOffset = dark ? NSZeroSize : NSMakeSize(0.0, -1.0);
}

- (void)layout {
    [super layout];
    self.layer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                            xRadius:12.0
                                                            yRadius:12.0].CGPath;
}

@end

@interface SCBlocklistIconView : NSImageView
@end

@implementation SCBlocklistIconView

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    [super updateLayer];
    BOOL dark = SCBlocklistUsesDarkAppearance(self.effectiveAppearance);
    self.layer.backgroundColor = (dark
        ? [NSColor colorWithWhite:1.0 alpha:0.06]
        : [NSColor colorWithWhite:0.0 alpha:0.035]).CGColor;
    self.layer.borderColor = (dark
        ? [NSColor colorWithWhite:1.0 alpha:0.10]
        : [NSColor colorWithWhite:0.0 alpha:0.10]).CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.cornerRadius = 7.0;
    self.layer.masksToBounds = YES;
}

@end

@interface SCBlocklistDocumentView : NSView
@end

@implementation SCBlocklistDocumentView

- (BOOL)isFlipped {
    return YES;
}

@end

@interface DomainListWindowController ()

@property (nonatomic, strong) NSScrollView *readOnlyScrollView;
@property (nonatomic, strong) SCBlocklistDocumentView *readOnlyDocumentView;
@property (nonatomic, strong) NSStackView *readOnlyColumnsStackView;
@property (nonatomic, strong) NSLayoutConstraint *readOnlyDocumentHeightConstraint;
@property (nonatomic) NSRect editableWindowFrame;
@property (nonatomic) NSSize editableWindowMinimumSize;
@property (nonatomic) NSWindowStyleMask editableWindowStyleMask;
@property (nonatomic) BOOL preparedReadOnlyWindow;

@end

@implementation DomainListWindowController

- (DomainListWindowController*)init {
	if(self = [super initWithWindowNibName:@"DomainList"]) {

		defaults_ = [NSUserDefaults standardUserDefaults];

        NSArray* curArray = [defaults_ arrayForKey: @"Blocklist"];
		if(curArray == nil)
			domainList_ = [NSMutableArray arrayWithCapacity: 10];
		else
			domainList_ = [curArray mutableCopy];

        [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	}

	return self;
}
- (void)awakeFromNib  {
    NSInteger indexToSelect = [defaults_ boolForKey: @"BlockAsWhitelist"] ? 1 : 0;
    [allowlistRadioMatrix_ selectCellAtRow: indexToSelect column: 0];
    [self updateWindowTitle];

    // Apply frosted glass styling
    [self setupFrostedGlassAppearance];
}

- (void)refreshDomainList {
    // end any current editing to trigger saving blocklist
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshDomainList];
        });
        return;
    }
    
    [[self window] makeFirstResponder: self];
    if (self.readOnly && self.displayEntries != nil) {
        domainList_ = [self.displayEntries mutableCopy];
    } else {
        domainList_ = [[defaults_ arrayForKey: @"Blocklist"] mutableCopy];
    }
    if (self.readOnly) [self setupReadOnlyAppearance];
    else [self setupEditableAppearance];
    [domainListTableView_ reloadData];
}

- (void)showWindow:(id)sender {
	// If displayEntries was provided (e.g., from menu bar during active block),
	// use those instead of NSUserDefaults
	if (self.displayEntries) {
		domainList_ = [self.displayEntries mutableCopy];
		[domainListTableView_ reloadData];
	} else if (!self.readOnly) {
		domainList_ = [[defaults_ arrayForKey:@"Blocklist"] mutableCopy];
		[domainListTableView_ reloadData];
	}

	// In readOnly mode, hide editing UI and show header
	if (self.readOnly) {
		[self setupReadOnlyAppearance];
	} else {
		[self setupEditableAppearance];
	}

	[[self window] makeKeyAndOrderFront: self];

	if ([domainList_ count] == 0 && !self.readOnly) {
		[self addDomain: self];
	}

    [self updateWindowTitle];
}

- (IBAction)addDomain:(id)sender
{
	[domainList_ addObject:@""];
    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];
	NSIndexSet* rowIndex = [NSIndexSet indexSetWithIndex: [domainList_ count] - 1];
	[domainListTableView_ selectRowIndexes: rowIndex
					  byExtendingSelection: NO];
	[domainListTableView_ editColumn: 0 row:((NSInteger)[domainList_ count] - 1)
						   withEvent:nil
							  select:YES];
}

- (IBAction)removeDomain:(id)sender
{
	NSIndexSet* selected = [domainListTableView_ selectedRowIndexes];
	[domainListTableView_ abortEditing];

	// This isn't the most efficient way to do this, but the code is much cleaner
	// than other methods and the domain blocklist will probably never be large
	// enough for it to be an issue.
	NSUInteger index = [selected firstIndex];
	NSUInteger shift = 0;
	while (index != NSNotFound) {
		if ((index - shift) >= [domainList_ count])
			break;
		[domainList_ removeObjectAtIndex: index - shift];
		shift++;
		index = [selected indexGreaterThanIndex: index];
	}

    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];

	[[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
														object: self];
}

- (NSUInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	return [domainList_ count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (rowIndex < 0 || (NSUInteger)rowIndex + 1 > [domainList_ count]) return nil;
	return domainList_[(NSUInteger)rowIndex];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    return !self.readOnly;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
	NSInteger editedRow = [domainListTableView_ editedRow];
	NSString* editedString = [[[[note userInfo] objectForKey: @"NSFieldEditor"] textStorage] string];
	editedString = [editedString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // sometimes we get an edited row index that's out-of-bounds for weird reasons,
    // e.g. if we're editing an empty row and then start a block, the data will get reloaded
    // and the row will not exist by the time this method gets called. We can ignore in that case
	if (editedRow >= 0 && editedRow < domainListTableView_.numberOfRows && !editedString.length) {
		NSIndexSet* indexSet = [NSIndexSet indexSetWithIndex: (NSUInteger)editedRow];
		[domainListTableView_ beginUpdates];
		[domainListTableView_ removeRowsAtIndexes: indexSet withAnimation: NSTableViewAnimationSlideUp];
		[domainList_ removeObjectAtIndex: (NSUInteger)editedRow];
        [defaults_ setValue: domainList_ forKey: @"Blocklist"];
		[domainListTableView_ reloadData];
		[domainListTableView_ endUpdates];
        [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
        object: self];
		return;
	}
}

- (void)tableView:(NSTableView *)aTableView
   setObjectValue:(NSString*)newString
   forTableColumn:(NSTableColumn *)aTableColumn
			  row:(NSInteger)rowIndex {
	if (rowIndex < 0 || (NSUInteger)rowIndex + 1 > [domainList_ count]) {
		return;
	}
    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: newString];
    
    for (NSUInteger i = 0; i < cleanedEntries.count; i++) {
        NSString* entry = cleanedEntries[i];
        if (i == 0) {
            domainList_[(NSUInteger)rowIndex] = entry;
        } else {
            [domainList_ insertObject: entry atIndex: (NSUInteger)rowIndex + i];
        }
    }
    
    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
    [domainListTableView_ reloadData];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
    object: self];
}

- (void)tableView:(NSTableView *)tableView
  willDisplayCell:(id)cell
   forTableColumn:(NSTableColumn *)tableColumn
			  row:(int)row {
	// Initialize the cell's text color
	[cell setTextColor: NSColor.textColor];
	NSString* str = [[cell title] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if([str isEqual: @""]) return;

    // Handle app entries - show them in purple with app name
    if ([str hasPrefix:@"app:"]) {
        NSString* bundleID = [str substringFromIndex:4];
        NSString* appName = [self appNameForBundleID:bundleID];
        if (appName) {
            [cell setStringValue:[NSString stringWithFormat:@"[App] %@ (%@)", appName, bundleID]];
        }
        [cell setTextColor:[NSColor systemPurpleColor]];
        return;
    }

	if([defaults_ boolForKey: @"HighlightInvalidHosts"]) {
		// Validate the value as either an IP or a hostname.  In case of failure,
		// we'll make its text color red.

		int maskLength = -1;
		int portNum = -1;

		NSArray* splitString = [str componentsSeparatedByString: @"/"];

		str = [splitString[0] lowercaseString];

		NSString* stringToSearchForPort = str;

		if([splitString count] >= 2) {
			maskLength = [splitString[1] intValue];
			// If the int value is 0, we couldn't find a valid integer representation
			// in the split off string
			if(maskLength == 0)
				maskLength = -1;

			stringToSearchForPort = splitString[1];
		}

		splitString = [stringToSearchForPort componentsSeparatedByString: @":"];

		if(stringToSearchForPort == str) {
			str = splitString[0];
		}

		if([splitString count] >= 2) {
			portNum = [splitString[1] intValue];
			// If the int value is 0, we couldn't find a valid integer representation
			// in the split off string
			if(portNum == 0)
				portNum = -1;
		}

		BOOL isIP;

		NSString* ipValidationRegex = @"^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$";
		NSPredicate *ipRegexTester = [NSPredicate
									  predicateWithFormat:@"SELF MATCHES %@",
									  ipValidationRegex];
		isIP = [ipRegexTester evaluateWithObject: str];

		if(!isIP) {
			NSString* hostnameValidationRegex = @"^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,6}$";
			NSPredicate *hostnameRegexTester = [NSPredicate
												predicateWithFormat:@"SELF MATCHES %@",
												hostnameValidationRegex
												];

			if(![hostnameRegexTester evaluateWithObject: str] && ![str isEqualToString: @"*"] && ![str isEqualToString: @""]) {
				[cell setTextColor: NSColor.redColor];
				return;
			}
		}

		// We shouldn't have a mask length if it's not an IP, fail
		if(!isIP && maskLength != -1) {
			[cell setTextColor: NSColor.redColor];
			return;
		}

		if(([str isEqualToString: @"*"] || [str isEqualToString: @""]) && portNum == -1) {
			[cell setTextColor: NSColor.redColor];
			return;
		}

		[cell setTextColor: NSColor.textColor];
	}
}

- (IBAction)allowlistOptionChanged:(NSMatrix*)sender {
    switch (sender.selectedRow) {
        case 0:
            [defaults_ setBool: NO forKey: @"BlockAsWhitelist"];
            break;
        case 1:
            [self showAllowlistWarning];
            [defaults_ setBool: YES forKey: @"BlockAsWhitelist"];
            break;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
                                                        object: self];
    
    // update UI to reflect appropriate list type
    AppController* controller = (AppController *)[NSApp delegate];
    [controller refreshUserInterface];
    [self updateWindowTitle];
}

- (void)showAllowlistWarning {
    if(![defaults_ boolForKey: @"WhitelistAlertSuppress"]) {        
        NSAlert* alert = [NSAlert new];
        alert.messageText = NSLocalizedString(@"Are you sure you want an allowlist block?", @"Allowlist block confirmation prompt");
        [alert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        alert.informativeText = NSLocalizedString(@"An allowlist block means that everything on the internet BESIDES your specified list will be blocked.  This includes the web, email, SSH, and anything else your computer accesses via the internet.  This can cause unexpected behavior. If a web site requires resources such as images or scripts from a site that is not on your allowlist, the site may not work properly.", @"allowlist block explanation");
        alert.showsSuppressionButton = YES;

        [alert runModal];

        if (alert.suppressionButton.state == NSOnState) {
            [defaults_ setBool: YES forKey: @"WhitelistAlertSuppress"];
        }
    }
}

- (void)updateWindowTitle {
    if (self.readOnly) {
        self.window.title = NSLocalizedString(@"Apps & Websites", @"Read-only committed blocklist window title");
        return;
    }
    NSString* listType = [defaults_ boolForKey: @"BlockAsWhitelist"] ? @"Allowlist" : @"Blocklist";
    self.window.title = NSLocalizedString(([NSString stringWithFormat: @"Domain %@", listType]), @"Domain list window title");
}

- (void)addHostArray:(NSArray*)arr {
	for(NSUInteger i = 0; i < [arr count]; i++) {
		// Check for dupes
		if(![domainList_ containsObject: arr[i]])
			[domainList_ addObject: arr[i]];
	}
	[defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];
	[[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
														object: self];
}

- (IBAction)importCommonDistractingWebsites:(id)sender {
	[self addHostArray: [HostImporter commonDistractingWebsites]];
}
- (IBAction)importNewsAndPublications:(id)sender {
	[self addHostArray: [HostImporter newsAndPublications]];
}
- (IBAction)importIncomingMailServersFromThunderbird:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromThunderbird]];
}
- (IBAction)importOutgoingMailServersFromThunderbird:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromThunderbird]];
}
- (IBAction)importIncomingMailServersFromMail:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromMail]];
}
- (IBAction)importOutgoingMailServersFromMail:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromMail]];
}
- (IBAction)importIncomingMailServersFromMailMate:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromMailMate]];
}
- (IBAction)importOutgoingMailServersFromMailMate:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromMailMate]];
}

#pragma mark - App Blocking

- (NSString*)appNameForBundleID:(NSString*)bundleID {
    NSString* appPath = [[NSWorkspace sharedWorkspace]
        absolutePathForAppBundleWithIdentifier:bundleID];
    if (appPath) {
        return [[NSFileManager defaultManager] displayNameAtPath:appPath];
    }
    return nil;
}

- (IBAction)addAppToBlocklist:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    panel.message = @"Select applications to block";
    panel.prompt = @"Add to Blocklist";

    // Only allow .app bundles
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[UTTypeApplication];
    } else {
        panel.allowedFileTypes = @[@"app"];
    }

    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSMutableArray* appsToAdd = [NSMutableArray array];

            for (NSURL* appURL in panel.URLs) {
                NSBundle* appBundle = [NSBundle bundleWithURL:appURL];
                NSString* bundleID = appBundle.bundleIdentifier;

                if (bundleID) {
                    NSString* entry = [NSString stringWithFormat:@"app:%@", bundleID];

                    // Avoid duplicates
                    if (![self->domainList_ containsObject:entry]) {
                        [appsToAdd addObject:entry];
                    }
                } else {
                    NSLog(@"Warning: Could not get bundle ID for %@", appURL);
                }
            }

            if (appsToAdd.count > 0) {
                [self addHostArray:appsToAdd];
            }
        }
    }];
}

#pragma mark - Frosted Glass Appearance

- (void)setupFrostedGlassAppearance {
    NSWindow* window = [self window];
    NSView* contentView = window.contentView;

    // Apply window styling for transparency
    [SCUIUtilities applyFrostedGlassStyleToWindow:window];

    // Create frosted glass background view
    NSVisualEffectView* frostedBackground = [SCUIUtilities createFrostedGlassViewWithFrame:contentView.bounds cornerRadius:12.0];
    frostedBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Insert at the back so all other content appears on top
    [contentView addSubview:frostedBackground positioned:NSWindowBelow relativeTo:nil];

    // Make content view layer-backed for proper compositing
    contentView.wantsLayer = YES;

    // Make table view background transparent so frosted glass shows through
    domainListTableView_.backgroundColor = NSColor.clearColor;
    domainListTableView_.enclosingScrollView.drawsBackground = NO;

    // Force shadow recalculation
    [window invalidateShadow];
}

- (void)setupReadOnlyAppearance {
    // Keep the legacy editable table intact, but replace its read-only
    // presentation with the calmer Apps & Websites layout used by Fence iOS.
    allowlistRadioMatrix_.hidden = YES;
    readOnlyMessageLabel_.stringValue = self.readOnlyNoticeText.length > 0
        ? self.readOnlyNoticeText
        : NSLocalizedString(@"Locked during the active commitment.", @"Read-only blocklist notice");
    readOnlyMessageLabel_.textColor = self.readOnlyNoticeColor ?: NSColor.secondaryLabelColor;
    readOnlyMessageLabel_.hidden = NO;
    [self prepareReadOnlyWindow];
    [self installReadOnlyBlocklistViewIfNeeded];
    domainListTableView_.enclosingScrollView.hidden = YES;
    self.readOnlyScrollView.hidden = NO;
    [self rebuildReadOnlyBlocklistView];
    [self updateWindowTitle];
}

- (void)setupEditableAppearance {
    // Restore the inherited standalone blocklist editor unchanged.
    allowlistRadioMatrix_.hidden = NO;
    readOnlyMessageLabel_.hidden = YES;
    domainListTableView_.enclosingScrollView.hidden = NO;
    self.readOnlyScrollView.hidden = YES;
    if (self.preparedReadOnlyWindow) {
        self.window.styleMask = self.editableWindowStyleMask;
        self.window.minSize = self.editableWindowMinimumSize;
        [self.window setFrame:self.editableWindowFrame display:NO];
        self.preparedReadOnlyWindow = NO;
    }
    [self updateWindowTitle];
}

- (void)prepareReadOnlyWindow {
    if (!self.preparedReadOnlyWindow) {
        self.editableWindowFrame = self.window.frame;
        self.editableWindowMinimumSize = self.window.minSize;
        self.editableWindowStyleMask = self.window.styleMask;
        self.preparedReadOnlyWindow = YES;

        NSRect targetFrame = self.window.frame;
        targetFrame.size.width = MAX(targetFrame.size.width, SCReadOnlyBlocklistPreferredWidth);
        if (!NSEqualSizes(targetFrame.size, self.window.frame.size)) {
            [self.window setFrame:targetFrame display:NO];
            [self.window center];
        }
    }
    self.window.styleMask |= NSWindowStyleMaskResizable;
    self.window.minSize = NSMakeSize(SCReadOnlyBlocklistMinimumWidth,
                                     self.editableWindowMinimumSize.height);
}

- (void)installReadOnlyBlocklistViewIfNeeded {
    if (self.readOnlyScrollView != nil) return;

    NSScrollView *legacyScrollView = domainListTableView_.enclosingScrollView;
    NSView *container = legacyScrollView.superview;

    self.readOnlyScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.readOnlyScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.readOnlyScrollView.drawsBackground = NO;
    self.readOnlyScrollView.borderType = NSNoBorder;
    self.readOnlyScrollView.hasVerticalScroller = YES;
    self.readOnlyScrollView.autohidesScrollers = YES;
    self.readOnlyScrollView.hidden = YES;
    [self.readOnlyScrollView setAccessibilityIdentifier:@"committed-blocklist-scroll"];

    self.readOnlyDocumentView = [[SCBlocklistDocumentView alloc] initWithFrame:NSZeroRect];
    self.readOnlyDocumentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.readOnlyScrollView.documentView = self.readOnlyDocumentView;

    self.readOnlyColumnsStackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.readOnlyColumnsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.readOnlyColumnsStackView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.readOnlyColumnsStackView.alignment = NSLayoutAttributeTop;
    self.readOnlyColumnsStackView.distribution = NSStackViewDistributionFillEqually;
    self.readOnlyColumnsStackView.spacing = 16.0;
    [self.readOnlyColumnsStackView setAccessibilityIdentifier:@"committed-blocklist-columns"];
    [self.readOnlyDocumentView addSubview:self.readOnlyColumnsStackView];

    [container addSubview:self.readOnlyScrollView
               positioned:NSWindowAbove
               relativeTo:legacyScrollView];

    self.readOnlyDocumentHeightConstraint =
        [self.readOnlyDocumentView.heightAnchor constraintEqualToConstant:1.0];

    [NSLayoutConstraint activateConstraints:@[
        [self.readOnlyScrollView.leadingAnchor constraintEqualToAnchor:legacyScrollView.leadingAnchor],
        [self.readOnlyScrollView.trailingAnchor constraintEqualToAnchor:legacyScrollView.trailingAnchor],
        [self.readOnlyScrollView.topAnchor constraintEqualToAnchor:legacyScrollView.topAnchor],
        [self.readOnlyScrollView.bottomAnchor constraintEqualToAnchor:legacyScrollView.bottomAnchor],
        [self.readOnlyDocumentView.widthAnchor constraintEqualToAnchor:self.readOnlyScrollView.contentView.widthAnchor],
        self.readOnlyDocumentHeightConstraint,
        [self.readOnlyColumnsStackView.leadingAnchor constraintEqualToAnchor:self.readOnlyDocumentView.leadingAnchor constant:18.0],
        [self.readOnlyColumnsStackView.trailingAnchor constraintEqualToAnchor:self.readOnlyDocumentView.trailingAnchor constant:-18.0],
        [self.readOnlyColumnsStackView.topAnchor constraintEqualToAnchor:self.readOnlyDocumentView.topAnchor constant:8.0],
    ]];
}

- (void)rebuildReadOnlyBlocklistView {
    for (NSView *view in self.readOnlyColumnsStackView.arrangedSubviews.copy) {
        [self.readOnlyColumnsStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *entriesByType =
        [SCMiscUtilities partitionBlocklistEntriesForDisplay:domainList_];
    NSArray<NSDictionary<NSString *, id> *> *apps =
        [self displayItemsForEntries:entriesByType[@"apps"]];
    NSArray<NSDictionary<NSString *, id> *> *websites =
        [self displayItemsForEntries:entriesByType[@"websites"]];

    NSStackView *appsColumn = [self readOnlyColumnWithTitle:NSLocalizedString(@"Apps", @"Blocklist apps section title")
                                                     items:apps
                                                 emptyText:NSLocalizedString(@"No apps.", @"Empty blocklist apps section")];
    NSStackView *websitesColumn = [self readOnlyColumnWithTitle:NSLocalizedString(@"Websites", @"Blocklist websites section title")
                                                         items:websites
                                                     emptyText:NSLocalizedString(@"No websites.", @"Empty blocklist websites section")];
    [self.readOnlyColumnsStackView addArrangedSubview:appsColumn];
    [self.readOnlyColumnsStackView addArrangedSubview:websitesColumn];

    NSUInteger longestColumnCount = MAX(apps.count, websites.count);
    NSUInteger visibleRowCount = MAX(longestColumnCount, (NSUInteger)1);
    CGFloat rowsHeight = visibleRowCount * SCReadOnlyBlocklistRowHeight;
    if (visibleRowCount > 1) rowsHeight += (visibleRowCount - 1) * 6.0;
    self.readOnlyDocumentHeightConstraint.constant = 8.0 + 16.0 + 6.0 + rowsHeight + 6.0;
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayItemsForEntries:(NSArray<NSString *> *)entries {
    NSMutableArray<NSDictionary<NSString *, id> *> *displayItems = [NSMutableArray array];
    for (NSString *entry in entries) {
        [displayItems addObject:[self displayItemForEntry:entry]];
    }
    NSComparator alphabeticalByTitle = ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"title"] localizedCaseInsensitiveCompare:right[@"title"]];
    };
    [displayItems sortUsingComparator:alphabeticalByTitle];
    return displayItems.copy;
}

- (NSDictionary<NSString *, id> *)displayItemForEntry:(NSString *)entry {
    BOOL isApp = entry.length > 4 &&
        [[entry substringToIndex:4] caseInsensitiveCompare:@"app:"] == NSOrderedSame;
    if (!isApp) {
        NSImage *websiteIcon = [NSImage imageWithSystemSymbolName:@"globe"
                                        accessibilityDescription:NSLocalizedString(@"Website", @"Website icon accessibility description")];
        if (websiteIcon == nil) websiteIcon = [NSImage imageNamed:NSImageNameNetwork];
        NSMutableDictionary<NSString *, id> *displayItem = [@{
            @"title": entry,
            @"rawEntry": entry,
            @"icon": websiteIcon ?: [NSImage new],
            @"isApp": @NO,
        } mutableCopy];
        NSString *faviconDomain = SCFaviconDomainForBlocklistEntry(entry);
        if (faviconDomain.length > 0) displayItem[@"faviconDomain"] = faviconDomain;
        return displayItem.copy;
    }

    NSString *bundleID = [entry substringFromIndex:4];
    NSURL *appURL = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:bundleID];
    NSString *title = appURL.path.length > 0
        ? [[NSFileManager defaultManager] displayNameAtPath:appURL.path]
        : bundleID;
    NSImage *icon = appURL.path.length > 0
        ? [[[NSWorkspace sharedWorkspace] iconForFile:appURL.path] copy]
        : [[NSImage imageWithSystemSymbolName:@"app"
                    accessibilityDescription:NSLocalizedString(@"Application", @"Application icon accessibility description")] copy];
    if (icon == nil) icon = [[NSImage imageNamed:NSImageNameApplicationIcon] copy];

    return @{
        @"title": title.length > 0 ? title : bundleID,
        @"rawEntry": entry,
        @"icon": icon ?: [NSImage new],
        @"isApp": @YES,
    };
}

- (NSStackView *)readOnlyColumnWithTitle:(NSString *)title
                                   items:(NSArray<NSDictionary<NSString *, id> *> *)items
                               emptyText:(NSString *)emptyText {
    NSTextField *titleLabel = [NSTextField labelWithString:title];
    titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
    titleLabel.textColor = NSColor.labelColor;

    NSTextField *countLabel = [NSTextField
        labelWithString:[NSString stringWithFormat:@"(%lu)", (unsigned long)items.count]];
    countLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    countLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *header = [NSStackView stackViewWithViews:@[titleLabel, countLabel]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 5.0;

    NSStackView *column = [[NSStackView alloc] initWithFrame:NSZeroRect];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.distribution = NSStackViewDistributionFill;
    column.spacing = 6.0;
    [column addArrangedSubview:header];

    NSStackView *rows = [[NSStackView alloc] initWithFrame:NSZeroRect];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    rows.alignment = NSLayoutAttributeLeading;
    rows.distribution = NSStackViewDistributionFill;
    rows.spacing = 6.0;
    [column addArrangedSubview:rows];
    [header.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
    [rows.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;

    if (items.count == 0) {
        SCBlocklistCardView *emptyCard = [self emptyStateCardWithText:emptyText];
        [rows addArrangedSubview:emptyCard];
        [emptyCard.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    } else {
        for (NSDictionary<NSString *, id> *item in items) {
            SCBlocklistCardView *card = [self cardForDisplayItem:item];
            [rows addArrangedSubview:card];
            [card.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
        }
    }
    return column;
}

- (SCBlocklistCardView *)cardForDisplayItem:(NSDictionary<NSString *, id> *)item {
    SCBlocklistCardView *card = [[SCBlocklistCardView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;

    SCBlocklistIconView *iconView = [[SCBlocklistIconView alloc] initWithFrame:NSZeroRect];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = item[@"icon"];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    if (![item[@"isApp"] boolValue]) {
        iconView.contentTintColor = NSColor.secondaryLabelColor;
        iconView.symbolConfiguration = [NSImageSymbolConfiguration
            configurationWithPointSize:15.0
                             weight:NSFontWeightSemibold];
        [self loadWebsiteIconForDomain:item[@"faviconDomain"] intoImageView:iconView];
    }

    NSTextField *nameLabel = [NSTextField labelWithString:item[@"title"]];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    nameLabel.textColor = NSColor.labelColor;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    nameLabel.maximumNumberOfLines = 1;
    nameLabel.toolTip = item[@"rawEntry"];
    [nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];

    [card addSubview:iconView];
    [card addSubview:nameLabel];
    [iconView setAccessibilityElement:NO];
    [iconView setAccessibilityHidden:YES];
    [nameLabel setAccessibilityElement:NO];
    [nameLabel setAccessibilityHidden:YES];
    [card setAccessibilityElement:YES];
    [card setAccessibilityRole:NSAccessibilityGroupRole];
    [card setAccessibilityLabel:item[@"title"]];
    [card setAccessibilityHelp:[item[@"isApp"] boolValue]
        ? NSLocalizedString(@"Application", @"Application blocklist row accessibility help")
        : NSLocalizedString(@"Website", @"Website blocklist row accessibility help")];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:SCReadOnlyBlocklistRowHeight],
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:28.0],
        [iconView.heightAnchor constraintEqualToConstant:28.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10.0],
        [nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [nameLabel.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}

- (void)loadWebsiteIconForDomain:(NSString *)domain intoImageView:(SCBlocklistIconView *)iconView {
    NSURL *faviconURL = SCFaviconURLForDomain(domain);
    if (faviconURL == nil) return;

    NSImage *cachedIcon = [SCBlocklistWebsiteIconCache() objectForKey:domain];
    if (cachedIcon != nil) {
        iconView.contentTintColor = nil;
        iconView.symbolConfiguration = nil;
        iconView.image = cachedIcon;
        return;
    }

    __weak SCBlocklistIconView *weakIconView = iconView;
    NSURLRequest *request = [NSURLRequest requestWithURL:faviconURL
                                             cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                         timeoutInterval:8.0];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *HTTPResponse = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response
            : nil;
        if (error != nil || data.length == 0 || HTTPResponse.statusCode != 200) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSImage *favicon = [[NSImage alloc] initWithData:data];
            if (favicon == nil) return;
            favicon.template = NO;
            [SCBlocklistWebsiteIconCache() setObject:favicon forKey:domain];

            SCBlocklistIconView *strongIconView = weakIconView;
            if (strongIconView == nil) return;
            strongIconView.contentTintColor = nil;
            strongIconView.symbolConfiguration = nil;
            strongIconView.image = favicon;
        });
    }];
    [task resume];
}

- (SCBlocklistCardView *)emptyStateCardWithText:(NSString *)text {
    SCBlocklistCardView *card = [[SCBlocklistCardView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    label.textColor = NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [card addSubview:label];
    [label setAccessibilityElement:NO];
    [label setAccessibilityHidden:YES];
    [card setAccessibilityElement:YES];
    [card setAccessibilityRole:NSAccessibilityGroupRole];
    [card setAccessibilityLabel:text];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:SCReadOnlyBlocklistRowHeight],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [label.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}

@end

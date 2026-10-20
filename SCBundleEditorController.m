//
//  SCBundleEditorController.m
//  SelfControl
//

#import "SCBundleEditorController.h"
#import "SCMiscUtilities.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - SCBundleEditorContentView (Private)

// Custom content view that handles Cmd+Q to quit even when sheet is modal
@interface SCBundleEditorContentView : NSView
@end

@implementation SCBundleEditorContentView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags];
    NSString *chars = [[event charactersIgnoringModifiers] lowercaseString];

    BOOL cmdPressed = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shiftPressed = (flags & NSEventModifierFlagShift) != 0;

    // Cmd+Q = Quit (close sheet first, then terminate to avoid bonk)
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"q"]) {
        NSWindow *sheet = self.window;
        NSWindow *parent = sheet.sheetParent;
        if (parent) {
            [parent endSheet:sheet];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return YES;
    }

    return [super performKeyEquivalent:event];
}

@end

#pragma mark - SCBundleEditorController

@interface SCBundleEditorController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property (nonatomic, strong, nullable) SCBlockBundle *bundle;
@property (nonatomic, strong) SCBlockBundle *workingBundle;
@property (nonatomic, assign) BOOL isNewBundle;
@property (nonatomic, copy) NSSet<NSString *> *originalEntries;

// UI Elements
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSStackView *colorPicker;
@property (nonatomic, strong) NSSegmentedControl *policyControl;
@property (nonatomic, strong) NSView *policySection;
@property (nonatomic, strong) NSTextField *policyExplanation;
@property (nonatomic, strong) NSView *warningContainer;
@property (nonatomic, strong) NSTableView *entriesTableView;
@property (nonatomic, strong) NSButton *addAppButton;
@property (nonatomic, strong) NSButton *addWebsiteButton;
@property (nonatomic, strong) NSButton *removeEntryButton;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *doneButton;
@property (nonatomic, strong) NSTextField *committedWarningLabel;

@property (nonatomic, strong) NSArray<NSView *> *colorViews;

// Event monitor for click-outside-to-close
@property (nonatomic, strong) id clickOutsideMonitor;

@end

@implementation SCBundleEditorController

- (instancetype)initForNewBundle {
    NSRect frame = NSMakeRect(0, 0, 400, 575);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"New Bundle";

    // Use custom content view that handles Cmd+Q
    SCBundleEditorContentView *customContentView = [[SCBundleEditorContentView alloc] initWithFrame:frame];
    window.contentView = customContentView;

    self = [super initWithWindow:window];
    if (self) {
        _bundle = nil;
        _workingBundle = [SCBlockBundle bundleWithName:@"New Bundle" color:[SCBlockBundle colorBlue]];
        _workingBundle.policy = SCBundlePolicyBlock;
        _isNewBundle = YES;
        _originalEntries = [NSSet set];
        window.delegate = self;

        [self setupUI];
    }
    return self;
}

- (instancetype)initWithBundle:(SCBlockBundle *)bundle {
    NSRect frame = NSMakeRect(0, 0, 400, 575);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Edit Bundle";

    // Use custom content view that handles Cmd+Q
    SCBundleEditorContentView *customContentView = [[SCBundleEditorContentView alloc] initWithFrame:frame];
    window.contentView = customContentView;

    self = [super initWithWindow:window];
    if (self) {
        _bundle = bundle;
        _workingBundle = [bundle copy];
        _isNewBundle = NO;
        _originalEntries = [NSSet setWithArray:bundle.entries];
        window.delegate = self;

        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    CGFloat padding = 16;
    CGFloat y = contentView.bounds.size.height - padding;

    self.warningContainer = [[NSView alloc] initWithFrame:NSMakeRect(padding, y - 54, 368, 54)];
    self.warningContainer.wantsLayer = YES;
    self.warningContainer.layer.cornerRadius = 8;
    self.warningContainer.layer.backgroundColor = [NSColor.systemRedColor colorWithAlphaComponent:0.08].CGColor;
    self.warningContainer.layer.borderColor = [NSColor.systemRedColor colorWithAlphaComponent:0.22].CGColor;
    self.warningContainer.layer.borderWidth = 1;
    NSImageView *lock = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 19, 16, 16)];
    lock.image = [NSImage imageWithSystemSymbolName:@"lock.fill" accessibilityDescription:@"Protected bundle"];
    lock.contentTintColor = [NSColor.systemRedColor colorWithAlphaComponent:0.92];
    [self.warningContainer addSubview:lock];
    self.committedWarningLabel = [NSTextField wrappingLabelWithString:@"Bundle is being used in the current session. Modifications are restricted. Content can be added."];
    self.committedWarningLabel.frame = NSMakeRect(34, 7, 324, 40);
    self.committedWarningLabel.font = [NSFont systemFontOfSize:11];
    self.committedWarningLabel.textColor = [NSColor.systemRedColor colorWithAlphaComponent:0.92];
    [self.warningContainer addSubview:self.committedWarningLabel];
    [contentView addSubview:self.warningContainer];
    y -= 65;

    // Name field
    y -= 30;
    NSTextField *nameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding, y, 60, 20)];
    nameLabel.stringValue = @"Name:";
    nameLabel.font = [NSFont systemFontOfSize:13];
    nameLabel.bezeled = NO;
    nameLabel.editable = NO;
    nameLabel.drawsBackground = NO;
    [contentView addSubview:nameLabel];

    self.nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(80, y - 2, 300, 24)];
    self.nameField.stringValue = self.workingBundle.name;
    self.nameField.font = [NSFont systemFontOfSize:13];
    self.nameField.placeholderString = @"Bundle name";
    [contentView addSubview:self.nameField];

    // Color picker
    y -= 45;
    NSTextField *colorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding, y, 60, 20)];
    colorLabel.stringValue = @"Color:";
    colorLabel.font = [NSFont systemFontOfSize:13];
    colorLabel.bezeled = NO;
    colorLabel.editable = NO;
    colorLabel.drawsBackground = NO;
    [contentView addSubview:colorLabel];

    self.colorPicker = [[NSStackView alloc] initWithFrame:NSMakeRect(80, y - 5, 280, 30)];
    self.colorPicker.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.colorPicker.spacing = 8;
    [contentView addSubview:self.colorPicker];

    NSArray<NSColor *> *colors = [SCBlockBundle allPresetColors];
    NSMutableArray *views = [NSMutableArray array];
    for (NSUInteger i = 0; i < colors.count; i++) {
        // Create a clickable color circle view
        NSView *colorView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 28, 28)];
        colorView.wantsLayer = YES;
        colorView.layer.cornerRadius = 14;
        colorView.layer.backgroundColor = colors[i].CGColor;
        colorView.layer.borderWidth = 2;
        colorView.layer.borderColor = [NSColor clearColor].CGColor;

        // Add click gesture recognizer
        NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(colorCircleClicked:)];
        [colorView addGestureRecognizer:click];

        // Store the color index in the view's tag (need to use identifier since NSView doesn't have tag)
        colorView.identifier = [NSString stringWithFormat:@"%lu", (unsigned long)i];

        // Set explicit size constraints
        [colorView.widthAnchor constraintEqualToConstant:28].active = YES;
        [colorView.heightAnchor constraintEqualToConstant:28].active = YES;

        [self.colorPicker addArrangedSubview:colorView];
        [views addObject:colorView];

        // Highlight current color
        if ([self colorsEqual:colors[i] and:self.workingBundle.color]) {
            colorView.layer.borderColor = [NSColor labelColor].CGColor;
        }
    }
    self.colorViews = views;

    y -= 48;
    self.policySection = [[NSView alloc] initWithFrame:NSMakeRect(padding, y - 18, 368, 50)];
    NSTextField *policyLabel = [NSTextField labelWithString:@"Policy:"];
    policyLabel.frame = NSMakeRect(0, 21, 60, 20);
    [self.policySection addSubview:policyLabel];
    self.policyControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Allow", @"Block"]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self action:@selector(policyChanged:)];
    self.policyControl.frame = NSMakeRect(64, 17, 190, 28);
    self.policyControl.accessibilityLabel = @"Bundle policy";
    self.policyControl.selectedSegment = self.workingBundle.policy;
    [self.policySection addSubview:self.policyControl];
    self.policyExplanation = [NSTextField labelWithString:@""];
    self.policyExplanation.frame = NSMakeRect(0, 0, 368, 16);
    self.policyExplanation.font = [NSFont systemFontOfSize:10];
    self.policyExplanation.textColor = NSColor.secondaryLabelColor;
    [self.policySection addSubview:self.policyExplanation];
    [self updatePolicyExplanation];
    [contentView addSubview:self.policySection];

    // Entries label
    y -= 40;
    NSTextField *entriesLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding, y, 200, 20)];
    entriesLabel.stringValue = @"Apps & Websites:";
    entriesLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    entriesLabel.bezeled = NO;
    entriesLabel.editable = NO;
    entriesLabel.drawsBackground = NO;
    [contentView addSubview:entriesLabel];

    // Entries table
    y -= 200;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(padding, y, 368, 190)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    self.entriesTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    self.entriesTableView.dataSource = self;
    self.entriesTableView.delegate = self;
    self.entriesTableView.rowHeight = 24;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"entry"];
    column.title = @"Entry";
    column.width = 350;
    column.editable = NO;
    [self.entriesTableView addTableColumn:column];
    self.entriesTableView.headerView = nil;

    scrollView.documentView = self.entriesTableView;
    [contentView addSubview:scrollView];

    // Add/Remove buttons
    y -= 35;
    self.addAppButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding, y, 90, 28)];
    self.addAppButton.title = @"+ Add App";
    self.addAppButton.bezelStyle = NSBezelStyleRounded;
    self.addAppButton.target = self;
    self.addAppButton.action = @selector(addAppClicked:);
    [contentView addSubview:self.addAppButton];

    self.addWebsiteButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding + 100, y, 120, 28)];
    self.addWebsiteButton.title = @"+ Add Website";
    self.addWebsiteButton.bezelStyle = NSBezelStyleRounded;
    self.addWebsiteButton.target = self;
    self.addWebsiteButton.action = @selector(addWebsiteClicked:);
    [contentView addSubview:self.addWebsiteButton];

    self.removeEntryButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding + 290, y, 90, 28)];
    self.removeEntryButton.title = @"Remove";
    self.removeEntryButton.bezelStyle = NSBezelStyleRounded;
    self.removeEntryButton.target = self;
    self.removeEntryButton.action = @selector(removeEntryClicked:);
    [contentView addSubview:self.removeEntryButton];

    // Bottom buttons
    y -= 50;

    // Delete button (only for existing bundles)
    if (!self.isNewBundle) {
        self.deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding, y, 80, 30)];
        self.deleteButton.title = @"Delete";
        self.deleteButton.bezelStyle = NSBezelStyleRounded;
        self.deleteButton.contentTintColor = [NSColor systemRedColor];
        self.deleteButton.target = self;
        self.deleteButton.action = @selector(deleteClicked:);
        [contentView addSubview:self.deleteButton];
    }

    // Save button (positioned at right)
    self.doneButton = [[NSButton alloc] initWithFrame:NSMakeRect(310, y, 80, 30)];
    self.doneButton.title = @"Save";
    self.doneButton.bezelStyle = NSBezelStyleRounded;
    self.doneButton.keyEquivalent = @"\r";
    self.doneButton.target = self;
    self.doneButton.action = @selector(doneClicked:);
    [contentView addSubview:self.doneButton];

    self.cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, y, 80, 30)];
    self.cancelButton.title = @"Cancel";
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.keyEquivalent = @"\e";
    self.cancelButton.target = self;
    self.cancelButton.action = @selector(cancelClicked:);
    [contentView addSubview:self.cancelButton];
    [self updateButtonStatesForCommittedState];
}

- (BOOL)selectedEntryCanBeRemoved {
    NSInteger row = self.entriesTableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.workingBundle.entries.count) return NO;
    return !self.isCommitted || ![self.originalEntries containsObject:self.workingBundle.entries[row]];
}

- (void)updateButtonStatesForCommittedState {
    BOOL protected = self.isCommitted;
    self.nameField.editable = !protected;
    self.nameField.enabled = !protected;
    self.nameField.alphaValue = protected ? 0.62 : 1.0;
    self.deleteButton.alphaValue = protected ? 0.42 : 1.0;
    self.policySection.alphaValue = protected ? 0.62 : 1.0;
    self.removeEntryButton.enabled = [self selectedEntryCanBeRemoved];
    self.colorPicker.alphaValue = 1.0;
    for (NSView *colorView in self.colorViews) {
        NSColor *color = [SCBlockBundle allPresetColors][colorView.identifier.integerValue];
        colorView.alphaValue = protected && ![self colorsEqual:color and:self.workingBundle.color] ? 0.42 : 1.0;
        for (NSGestureRecognizer *recognizer in colorView.gestureRecognizers) {
            recognizer.enabled = !protected;
        }
    }
    self.warningContainer.hidden = !protected;
}

- (BOOL)colorsEqual:(NSColor *)c1 and:(NSColor *)c2 {
    if (!c1 || !c2) return NO;
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    [[c1 colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [[c2 colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    return fabs(r1 - r2) < 0.01 && fabs(g1 - g2) < 0.01 && fabs(b1 - b2) < 0.01;
}

#pragma mark - Actions

- (void)updatePolicyExplanation {
    self.policyExplanation.stringValue = self.workingBundle.policy == SCBundlePolicyBlock
        ? @"Block these apps and websites inside their calendar windows."
        : @"Block these apps and websites outside their calendar windows.";
}

- (void)policyChanged:(id)sender {
    if (self.isCommitted) {
        self.policyControl.selectedSegment = self.workingBundle.policy;
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Policy is locked";
        alert.informativeText = @"The policy cannot change while this bundle is in the current session. Content can be added.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    self.workingBundle.policy = self.policyControl.selectedSegment;
    [self updatePolicyExplanation];
}

- (void)colorCircleClicked:(NSClickGestureRecognizer *)gesture {
    if (self.isCommitted) return;
    NSView *clickedView = gesture.view;
    NSArray<NSColor *> *colors = [SCBlockBundle allPresetColors];
    NSInteger index = [clickedView.identifier integerValue];

    if (index >= 0 && index < (NSInteger)colors.count) {
        self.workingBundle.color = colors[index];

        // Update view highlights
        for (NSView *view in self.colorViews) {
            view.layer.borderColor = [NSColor clearColor].CGColor;
        }
        clickedView.layer.borderColor = [NSColor labelColor].CGColor;
    }
}

- (void)addAppClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    panel.message = @"Select apps for this bundle:";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            for (NSURL *url in panel.URLs) {
                NSBundle *appBundle = [NSBundle bundleWithURL:url];
                NSString *bundleID = appBundle.bundleIdentifier;
                if (bundleID) {
                    NSString *entry = [NSString stringWithFormat:@"app:%@", bundleID];
                    [self.workingBundle addEntry:entry];
                }
            }
            [self.entriesTableView reloadData];
        }
    }];
}

- (void)addWebsiteClicked:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add Website";
    alert.informativeText = @"Enter a domain for this bundle (e.g., facebook.com):";

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
    input.placeholderString = @"example.com";
    alert.accessoryView = input;

    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            NSString *canonicalEntry = [SCMiscUtilities canonicalBlockEntryFromString:input.stringValue];
            if (canonicalEntry != nil && ![canonicalEntry hasPrefix:@"app:"]) {
                [self.workingBundle addEntry:canonicalEntry];
                [self.entriesTableView reloadData];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *validationAlert = [[NSAlert alloc] init];
                    validationAlert.messageText = @"Invalid Website";
                    validationAlert.informativeText = @"Enter a valid domain, IP address, or HTTP/HTTPS URL. Fence blocks the whole host, so paths and query text are ignored.";
                    validationAlert.alertStyle = NSAlertStyleWarning;
                    [validationAlert addButtonWithTitle:@"OK"];
                    [validationAlert beginSheetModalForWindow:self.window completionHandler:nil];
                });
            }
        }
    }];
}

- (void)removeEntryClicked:(id)sender {
    if (![self selectedEntryCanBeRemoved]) return;
    [self.workingBundle.entries removeObjectAtIndex:self.entriesTableView.selectedRow];
    [self.entriesTableView reloadData];
    [self updateButtonStatesForCommittedState];
}

- (void)deleteClicked:(id)sender {
    // Block deletion in committed state
    if (self.isCommitted) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cannot Delete Bundle in Committed State";
        alert.informativeText = @"End your commitment before deleting this bundle.";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete Bundle?";
    alert.informativeText = [NSString stringWithFormat:@"Are you sure you want to delete \"%@\"? This cannot be undone.", self.workingBundle.name];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self.delegate bundleEditor:self didDeleteBundle:self.bundle];
            [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
        }
    }];
}

- (void)doneClicked:(id)sender {
    // Validate
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (name.length == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Name Required";
        alert.informativeText = @"Please enter a name for this bundle.";
        [alert runModal];
        return;
    }

    if (!self.isCommitted) self.workingBundle.name = name;

    [self removeClickOutsideMonitor];
    [self.delegate bundleEditor:self didSaveBundle:self.workingBundle];
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
}

- (void)cancelClicked:(id)sender {
    [self closeEditor];
}

- (void)closeEditor {
    [self removeClickOutsideMonitor];
    [self.delegate bundleEditorDidCancel:self];
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel];
}

#pragma mark - NSWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self closeEditor];
    return NO; // We handle closing via endSheet
}

#pragma mark - Click Outside Handling

- (void)setupClickOutsideMonitor {
    __weak typeof(self) weakSelf = self;
    self.clickOutsideMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                                     handler:^NSEvent *(NSEvent *event) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return event;

        NSWindow *eventWindow = event.window;

        // Don't close if click is in our window
        if (eventWindow == strongSelf.window) {
            return event;
        }

        // Don't close if click is in a panel (file picker, alert, etc.)
        if ([eventWindow isKindOfClass:[NSPanel class]]) {
            return event;
        }

        // Don't close if click is in an attached sheet (like our own alerts)
        if (eventWindow.sheetParent != nil) {
            return event;
        }

        // Don't close if there's no window (menu click, etc.)
        if (eventWindow == nil) {
            return event;
        }

        // Click was in the parent window - close the editor
        if (eventWindow == strongSelf.window.sheetParent) {
            [strongSelf closeEditor];
            return nil; // Consume the event
        }

        return event;
    }];
}

- (void)removeClickOutsideMonitor {
    if (self.clickOutsideMonitor) {
        [NSEvent removeMonitor:self.clickOutsideMonitor];
        self.clickOutsideMonitor = nil;
    }
}

- (void)dealloc {
    [self removeClickOutsideMonitor];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.workingBundle.entries.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.workingBundle.entries.count) return nil;

    NSString *entry = self.workingBundle.entries[row];

    // Format for display
    if ([entry hasPrefix:@"app:"]) {
        NSString *bundleID = [entry substringFromIndex:4];
        NSString *appPath = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:bundleID];
        if (appPath) {
            NSString *appName = [[NSFileManager defaultManager] displayNameAtPath:appPath];
            return [NSString stringWithFormat:@"🖥 %@ (%@)", appName, bundleID];
        }
        return [NSString stringWithFormat:@"🖥 %@", bundleID];
    }

    return [NSString stringWithFormat:@"🌐 %@", entry];
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    self.removeEntryButton.enabled = [self selectedEntryCanBeRemoved];
}

#pragma mark - Sheet Presentation

- (void)beginSheetModalForWindow:(NSWindow *)parentWindow
               completionHandler:(void (^)(NSModalResponse))handler {
    // Update button states based on committed state
    [self updateButtonStatesForCommittedState];

    // Set up click-outside-to-close monitor
    [self setupClickOutsideMonitor];

    [parentWindow beginSheet:self.window completionHandler:^(NSModalResponse response) {
        [self removeClickOutsideMonitor];
        if (handler) {
            handler(response);
        }
    }];
}

@end

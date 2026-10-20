//
//  SCBundleSidebarView.m
//  SelfControl
//

#import "SCBundleSidebarView.h"
#import "Block Management/SCBlockBundle.h"
#import "Block Management/SCWeeklySchedule.h"

static const CGFloat kSidebarWidth = 180.0;
static const CGFloat kPillHeight = 40.0;
static const CGFloat kPillSpacing = 8.0;
static const CGFloat kPillCornerRadius = 8.0;
static const CGFloat kDotSize = 10.0;
static const CGFloat kPadding = 12.0;
static const CGFloat kHeaderHeight = 30.0;

#pragma mark - SCBundlePillView (Private)

@interface SCBundlePillView : NSView

@property (nonatomic, strong) SCBlockBundle *bundle;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, assign) BOOL isCommitted;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@property (nonatomic, assign) SEL doubleClickAction;
@property (nonatomic, strong) NSButton *editButton;

@end

@implementation SCBundlePillView {
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frame bundle:(SCBlockBundle *)bundle {
    self = [super initWithFrame:frame];
    if (self) {
        _bundle = bundle;
        _isSelected = NO;
        _isHovered = NO;
        _isCommitted = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = kPillCornerRadius;
        self.editButton = [NSButton buttonWithTitle:@"Edit" target:self action:@selector(editClicked:)];
        self.editButton.frame = NSMakeRect(frame.size.width - 44, 0, 44, kPillHeight);
        self.editButton.bordered = NO;
        self.editButton.font = [NSFont systemFontOfSize:11];
        self.editButton.autoresizingMask = NSViewMinXMargin;
        self.editButton.accessibilityLabel = [NSString stringWithFormat:@"Edit %@ bundle", bundle.name];
        [self addSubview:self.editButton];
        [self updateAppearance];
    }
    return self;
}

- (void)editClicked:(id)sender {
    [NSApp sendAction:self.doubleClickAction to:self.target from:self];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.isHovered = YES;
    [self updateAppearance];
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    [self updateAppearance];
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        // Double-click to edit
        if (self.target && self.doubleClickAction) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.doubleClickAction withObject:self];
            #pragma clang diagnostic pop
        }
    } else {
        // Single click to select/toggle
        if (self.target && self.action) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.action withObject:self];
            #pragma clang diagnostic pop
        }
    }
}

- (void)updateAppearance {
    // Background color
    if (self.isSelected) {
        // Selected: subtle tint with bundle color
        self.layer.backgroundColor = [[self.bundle.color colorWithAlphaComponent:0.15] CGColor];
        self.layer.borderWidth = 2.0;
        self.layer.borderColor = [self.bundle.color CGColor];
    } else if (self.isHovered) {
        // Hovered: darker background
        self.layer.backgroundColor = [[NSColor.whiteColor colorWithAlphaComponent:0.15] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[NSColor.whiteColor colorWithAlphaComponent:0.2] CGColor];
    } else {
        // Normal: subtle background
        self.layer.backgroundColor = [[NSColor.whiteColor colorWithAlphaComponent:0.08] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[NSColor.whiteColor colorWithAlphaComponent:0.1] CGColor];
    }

    if (self.isCommitted) {
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [NSColor.systemRedColor colorWithAlphaComponent:0.62].CGColor;
    }
    self.alphaValue = 1.0;
    self.accessibilityValue = self.isCommitted ? @"In active session" : @"Not in active session";

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGFloat dotX = kPadding;
    CGFloat dotY = (self.bounds.size.height - kDotSize) / 2;

    // Draw colored dot
    NSBezierPath *dotPath = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotX, dotY, kDotSize, kDotSize)];
    [self.bundle.color setFill];
    [dotPath fill];

    // Draw bundle name
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSParagraphStyleAttributeName: paragraphStyle
    };

    CGFloat textX = dotX + kDotSize + 8;
    CGFloat textWidth = self.bounds.size.width - textX - 44;
    CGFloat textY = (self.bounds.size.height - 16) / 2;

    [self.bundle.name drawInRect:NSMakeRect(textX, textY, textWidth, 18) withAttributes:attrs];
}

- (void)setIsSelected:(BOOL)isSelected {
    _isSelected = isSelected;
    [self updateAppearance];
}

- (void)setIsHovered:(BOOL)isHovered {
    _isHovered = isHovered;
    [self updateAppearance];
}

- (void)setIsCommitted:(BOOL)isCommitted {
    _isCommitted = isCommitted;
    [self updateAppearance];
}

@end

#pragma mark - SCBundleSidebarView

@interface SCBundleSidebarView ()

@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSTextField *sessionLegend;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *pillContainer;
@property (nonatomic, strong) NSButton *addButton;
@property (nonatomic, strong) NSMutableArray<SCBundlePillView *> *pillViews;

@end

@implementation SCBundleSidebarView

- (instancetype)initWithFrame:(NSRect)frame {
    // Force width to sidebar width
    frame.size.width = kSidebarWidth;
    self = [super initWithFrame:frame];
    if (self) {
        _bundles = @[];
        _pillViews = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.wantsLayer = YES;

    // Semi-transparent background with rounded corners (matches status bar)
    self.layer.backgroundColor = [[NSColor.whiteColor colorWithAlphaComponent:0.05] CGColor];
    self.layer.cornerRadius = 8.0;

    CGFloat y = self.bounds.size.height - kPadding;

    // Header label
    y -= kHeaderHeight;
    self.headerLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kPadding, y, kSidebarWidth - kPadding * 2, kHeaderHeight)];
    self.headerLabel.stringValue = @"BUNDLES";
    self.headerLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    self.headerLabel.textColor = [NSColor secondaryLabelColor];
    self.headerLabel.bezeled = NO;
    self.headerLabel.editable = NO;
    self.headerLabel.drawsBackground = NO;
    self.headerLabel.autoresizingMask = NSViewMinYMargin;
    [self addSubview:self.headerLabel];

    self.sessionLegend = [NSTextField labelWithString:@"●  In active session"];
    self.sessionLegend.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.sessionLegend.textColor = [NSColor.systemRedColor colorWithAlphaComponent:0.86];
    self.sessionLegend.frame = NSMakeRect(kPadding, y - 18, kSidebarWidth - 2 * kPadding, 18);
    self.sessionLegend.autoresizingMask = NSViewMinYMargin;
    [self addSubview:self.sessionLegend];
    y -= 24;

    // Scroll view for pills
    CGFloat scrollHeight = y - kPadding - 40; // Leave room for add button at bottom
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 40, kSidebarWidth, scrollHeight)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
    self.scrollView.autoresizingMask = NSViewHeightSizable;

    self.pillContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSidebarWidth, scrollHeight)];
    self.pillContainer.wantsLayer = YES;
    self.scrollView.documentView = self.pillContainer;
    [self addSubview:self.scrollView];

    // Add bundle button at bottom
    self.addButton = [[NSButton alloc] initWithFrame:NSMakeRect(kPadding, kPadding, kSidebarWidth - kPadding * 2, 24)];
    self.addButton.title = @"+ Add Bundle";
    self.addButton.bezelStyle = NSBezelStyleRounded;
    self.addButton.font = [NSFont systemFontOfSize:11];
    self.addButton.target = self;
    self.addButton.action = @selector(addButtonClicked:);
    self.addButton.autoresizingMask = NSViewMaxYMargin;
    [self addSubview:self.addButton];
}

- (void)reloadData {
    self.sessionLegend.hidden = self.protectedBundleIDs.count == 0;
    // Remove old pill views
    for (SCBundlePillView *pill in self.pillViews) {
        [pill removeFromSuperview];
    }
    [self.pillViews removeAllObjects];

    // Create pill views for each bundle
    CGFloat y = self.pillContainer.bounds.size.height - kPadding;

    for (SCBlockBundle *bundle in self.bundles) {
        y -= kPillHeight;

        SCBundlePillView *pill = [[SCBundlePillView alloc] initWithFrame:NSMakeRect(kPadding, y, kSidebarWidth - kPadding * 2, kPillHeight)
                                                                  bundle:bundle];
        pill.target = self;
        pill.action = @selector(pillClicked:);
        pill.doubleClickAction = @selector(pillDoubleClicked:);
        pill.isSelected = [bundle.bundleID isEqualToString:self.selectedBundleID];

        pill.isCommitted = [self.protectedBundleIDs containsObject:bundle.bundleID];

        [self.pillContainer addSubview:pill];
        [self.pillViews addObject:pill];

        y -= kPillSpacing;
    }

    // Resize pill container to fit content
    CGFloat contentHeight = self.bundles.count * (kPillHeight + kPillSpacing) + kPadding * 2;
    CGFloat minHeight = self.scrollView.bounds.size.height;
    contentHeight = MAX(contentHeight, minHeight);

    NSRect containerFrame = self.pillContainer.frame;
    containerFrame.size.height = contentHeight;
    self.pillContainer.frame = containerFrame;

    // Reposition pills in flipped-like layout (top to bottom)
    y = contentHeight - kPadding;
    for (SCBundlePillView *pill in self.pillViews) {
        y -= kPillHeight;
        NSRect frame = pill.frame;
        frame.origin.y = y;
        pill.frame = frame;
        y -= kPillSpacing;
    }
}

- (void)pillClicked:(SCBundlePillView *)pill {
    // Keep the focused bundle selected while inspecting a committed calendar.
    if ([pill.bundle.bundleID isEqualToString:self.selectedBundleID]) {
        // Already selected - deselect (return to All-Up)
        self.selectedBundleID = nil;
    } else {
        // Select this bundle (Focus state)
        self.selectedBundleID = pill.bundle.bundleID;
    }

    // Update all pill appearances
    for (SCBundlePillView *p in self.pillViews) {
        p.isSelected = [p.bundle.bundleID isEqualToString:self.selectedBundleID];
    }

    // Notify delegate
    SCBlockBundle *selectedBundle = self.selectedBundleID ? [self bundleForID:self.selectedBundleID] : nil;
    if ([self.delegate respondsToSelector:@selector(bundleSidebar:didSelectBundle:)]) {
        [self.delegate bundleSidebar:self didSelectBundle:selectedBundle];
    }
}

- (void)pillDoubleClicked:(SCBundlePillView *)pill {
    if ([self.delegate respondsToSelector:@selector(bundleSidebar:didRequestEditBundle:)]) {
        [self.delegate bundleSidebar:self didRequestEditBundle:pill.bundle];
    }
}

- (void)addButtonClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(bundleSidebarDidRequestAddBundle:)]) {
        [self.delegate bundleSidebarDidRequestAddBundle:self];
    }
}

- (void)clearSelection {
    self.selectedBundleID = nil;
    for (SCBundlePillView *pill in self.pillViews) {
        pill.isSelected = NO;
    }

    if ([self.delegate respondsToSelector:@selector(bundleSidebar:didSelectBundle:)]) {
        [self.delegate bundleSidebar:self didSelectBundle:nil];
    }
}

- (nullable SCBlockBundle *)bundleForID:(NSString *)bundleID {
    for (SCBlockBundle *bundle in self.bundles) {
        if ([bundle.bundleID isEqualToString:bundleID]) {
            return bundle;
        }
    }
    return nil;
}

- (void)setSelectedBundleID:(NSString *)selectedBundleID {
    _selectedBundleID = [selectedBundleID copy];
    for (SCBundlePillView *pill in self.pillViews) {
        pill.isSelected = [pill.bundle.bundleID isEqualToString:_selectedBundleID];
    }
}

- (void)setIsCommitted:(BOOL)isCommitted {
    _isCommitted = isCommitted;
    self.addButton.enabled = YES;
    self.addButton.toolTip = @"Create a bundle of apps and websites.";
}

@end

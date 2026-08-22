//
//  SCCalendarGridView.m
//  SelfControl
//

#import "SCCalendarGridView.h"
#import "Block Management/SCBlockBundle.h"
#import "Block Management/SCTimeRange.h"

// Layout constants
static const CGFloat kDayHeaderHeight = 40.0;
static const CGFloat kHourLabelWidth = 50.0;
static const CGFloat kTimelineTopPadding = 10.0;
static const CGFloat kSnapMinutes = 15.0;  // Snap to 15-min grid
static const CGFloat kMinBlockDuration = 30.0;  // Minimum 30 min block
static const CGFloat kEdgeDetectionZone = 8.0;  // Pixels for resize detection
static const CGFloat kLanePadding = 2.0;
static const CGFloat kDragThreshold = 5.0;  // Pixels to move before starting drag-to-create

// Opacity for non-focused bundles
static const CGFloat kDimmedOpacity = 0.2;

#pragma mark - SCBlockLayoutInfo (Private)

/// Holds computed layout information for a single allow block
@interface SCBlockLayoutInfo : NSObject
@property (nonatomic, assign) NSInteger bundleIndex;
@property (nonatomic, assign) NSInteger windowIndex;
@property (nonatomic, assign) NSInteger startMinutes;
@property (nonatomic, assign) NSInteger endMinutes;
@property (nonatomic, assign) NSInteger maxOverlap;      // Max concurrent blocks (including self)
@property (nonatomic, assign) NSInteger laneSlot;        // 0-based horizontal slot
@property (nonatomic, assign) NSInteger bundleDisplayOrder;
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation SCBlockLayoutInfo
@end

#pragma mark - SCAllowBlockView (Private)

@interface SCAllowBlockView : NSView

@property (nonatomic, strong) SCTimeRange *timeRange;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *bundleID;  // Track which bundle owns this block
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, assign) BOOL isDimmed;
@property (nonatomic, assign) BOOL isCommitted;
@property (nonatomic, assign) NSInteger timeLabelDisplayMode;  // 0=auto, 1=full, 2=fallback, 3=hidden

@end

@implementation SCAllowBlockView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6;
    }
    return self;
}

- (void)updateLayer {
    [super updateLayer];
    [self updateAppearance];
}

- (void)updateAppearance {
    // Semi-transparent background + border (slightly more solid than status pills)
    CGFloat bgAlpha = 0.4;
    CGFloat borderAlpha = 0.6;

    if (self.isDimmed) {
        bgAlpha = 0.15;
        borderAlpha = 0.3;
    } else if (self.isSelected && !self.isCommitted) {
        bgAlpha = 0.55;
        borderAlpha = 0.85;
    }

    self.layer.backgroundColor = [self.color colorWithAlphaComponent:bgAlpha].CGColor;
    self.layer.borderColor = [self.color colorWithAlphaComponent:borderAlpha].CGColor;
    self.layer.borderWidth = self.isSelected ? 2.0 : 1.0;
}

- (void)setColor:(NSColor *)color {
    _color = color;
    [self updateAppearance];
}

- (void)setIsSelected:(BOOL)isSelected {
    _isSelected = isSelected;
    [self updateAppearance];
}

- (void)setIsDimmed:(BOOL)isDimmed {
    _isDimmed = isDimmed;
    [self updateAppearance];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Early exit if height is insufficient
    if (self.bounds.size.height <= 30 || !self.timeRange) {
        return;
    }

    NSColor *textColor = self.isDimmed ?
        [[NSColor labelColor] colorWithAlphaComponent:0.3] :
        [NSColor labelColor];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: textColor
    };

    // Prepare strings
    NSString *startString = [self.timeRange format12Hour:self.timeRange.startTime];
    NSString *fullStartString = [NSString stringWithFormat:@"%@ -", startString];
    NSString *endString = [self.timeRange format12Hour:self.timeRange.endTime];

    // Measure text widths (ceil to handle fractional pixels)
    CGFloat fullStartWidth = ceil([fullStartString sizeWithAttributes:attrs].width);
    CGFloat endWidth = ceil([endString sizeWithAttributes:attrs].width);

    CGFloat margin = 3.0;
    CGFloat availableWidth = self.bounds.size.width - (margin * 2);

    // Use display mode from column if set, otherwise calculate locally
    NSInteger displayMode = self.timeLabelDisplayMode;
    if (displayMode == 0) {
        // Auto-calculate: 1 = full, 2 = fallback, 3 = hidden
        BOOL canFitFull = (availableWidth >= fullStartWidth) && (availableWidth >= endWidth);
        CGFloat rawStartWidth = ceil([startString sizeWithAttributes:attrs].width);
        BOOL canFitStart = (availableWidth >= rawStartWidth);

        if (canFitFull) displayMode = 1;
        else if (canFitStart) displayMode = 2;
        else displayMode = 3;
    }

    CGFloat lineHeight = 14;
    CGFloat textY = self.bounds.size.height - lineHeight - 4;

    if (displayMode == 1) {
        // Full: "2:00am -" on line 1, "10:00pm" on line 2
        [fullStartString drawAtPoint:NSMakePoint(margin, textY) withAttributes:attrs];
        [endString drawAtPoint:NSMakePoint(margin, textY - lineHeight) withAttributes:attrs];
    } else if (displayMode == 2) {
        // Fallback: just start time
        [startString drawAtPoint:NSMakePoint(margin, textY) withAttributes:attrs];
    }
    // displayMode == 3: hidden, draw nothing
}

@end

#pragma mark - SCCalendarDayColumn (Private)

@interface SCCalendarDayColumn : NSView

@property (nonatomic, assign) SCDayOfWeek day;
@property (nonatomic, copy) NSArray<SCBlockBundle *> *bundles;
@property (nonatomic, copy) NSDictionary<NSString *, SCWeeklySchedule *> *schedules;
@property (nonatomic, copy, nullable) NSString *focusedBundleID;
@property (nonatomic, assign) BOOL isCommitted;
@property (nonatomic, assign) BOOL isToday;
@property (nonatomic, strong, nullable) NSTimeZone *displayTimeZone;
@property (nonatomic, assign) CGFloat timelineHeight;  // Height for 24 hours

// Drag state
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) BOOL isCreatingBlock;
@property (nonatomic, assign) BOOL isResizingTop;
@property (nonatomic, assign) BOOL isResizingBottom;
@property (nonatomic, assign) BOOL isMovingBlock;
@property (nonatomic, assign) BOOL hasPendingEmptyAreaClick;  // Waiting for drag threshold
@property (nonatomic, assign) CGFloat dragStartY;
@property (nonatomic, assign) NSInteger dragStartMinutes;
@property (nonatomic, assign) NSPoint mouseDownPoint;  // For drag threshold detection
@property (nonatomic, strong, nullable) SCTimeRange *draggingRange;
@property (nonatomic, strong, nullable) SCTimeRange *originalDragRange;
@property (nonatomic, copy, nullable) NSString *draggingBundleID;

// Selected block
@property (nonatomic, assign) NSInteger selectedBlockIndex;
@property (nonatomic, copy, nullable) NSString *selectedBundleID;

// Callbacks
@property (nonatomic, copy, nullable) void (^onScheduleUpdated)(NSString *bundleID, SCWeeklySchedule *schedule);
@property (nonatomic, copy, nullable) void (^onEmptyAreaClicked)(void);
@property (nonatomic, copy, nullable) void (^onBlockDoubleClicked)(SCBlockBundle *bundle);
@property (nonatomic, copy, nullable) void (^onNoFocusInteraction)(void);  // Warning when interacting without bundle focus
@property (nonatomic, copy, nullable) void (^onColumnClicked)(void);  // Any click in the column
@property (nonatomic, copy, nullable) void (^onBlockSelected)(void);  // Block was selected (for clearing other selections)

- (void)reloadBlocks;
- (void)clearSelection;
- (CGFloat)yFromMinutes:(NSInteger)minutes;
- (NSInteger)minutesFromY:(CGFloat)y;
- (NSUInteger)renderedBlockCount;
- (NSDictionary<NSString *, NSNumber *> *)telemetryBlockVisibilitySnapshot;

@end

@implementation SCCalendarDayColumn {
    NSMutableArray<SCAllowBlockView *> *_blockViews;
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _blockViews = [NSMutableArray array];
        _selectedBlockIndex = -1;
        _timelineHeight = frame.size.height;
        self.wantsLayer = YES;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (BOOL)isFlipped {
    return YES;  // Origin at top = midnight
}

- (NSView *)hitTest:(NSPoint)point {
    // Let default implementation find the deepest subview
    NSView *hitView = [super hitTest:point];

    // If we hit a block view from a DIFFERENT bundle than the focused one,
    // return self (the DayColumn) instead. This makes non-focused blocks
    // "transparent" to clicks, allowing drag-to-create for the focused bundle.
    // Without this, NSScrollView steals drag events because the original hit
    // target (block view) didn't enter a tracking loop.
    if ([hitView isKindOfClass:[SCAllowBlockView class]]) {
        SCAllowBlockView *blockView = (SCAllowBlockView *)hitView;
        if (self.focusedBundleID && ![blockView.bundleID isEqualToString:self.focusedBundleID]) {
            return self;  // Treat as click on DayColumn background
        }
    }

    return hitView;
}

- (CGFloat)yFromMinutes:(NSInteger)minutes {
    // Map 0-1440 minutes to 0-timelineHeight
    return (minutes / 1440.0) * self.timelineHeight;
}

- (NSInteger)minutesFromY:(CGFloat)y {
    // Map y position to minutes (0-1440)
    NSInteger minutes = (NSInteger)((y / self.timelineHeight) * 1440);
    return MAX(0, MIN(1439, minutes));
}

- (NSUInteger)renderedBlockCount {
    return _blockViews.count;
}

static BOOL SCViewIsEffectivelyVisibleForTelemetry(NSView *view) {
    CGFloat effectiveAlpha = 1.0;
    for (NSView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if (candidate.hidden) return NO;
        effectiveAlpha *= candidate.alphaValue;
        if (effectiveAlpha <= 0.01) return NO;
    }
    return YES;
}

static BOOL SCBlockViewHasVisibleAppearanceForTelemetry(SCAllowBlockView *blockView) {
    CALayer *layer = blockView.layer;
    if (!SCViewIsEffectivelyVisibleForTelemetry(blockView) || layer == nil ||
        layer.hidden || layer.opacity <= 0.01) {
        return NO;
    }
    CGColorRef backgroundColor = layer.backgroundColor;
    CGColorRef borderColor = layer.borderColor;
    BOOL backgroundVisible = backgroundColor != nil && CGColorGetAlpha(backgroundColor) > 0.01;
    BOOL borderVisible = borderColor != nil && layer.borderWidth > 0 && CGColorGetAlpha(borderColor) > 0.01;
    return backgroundVisible || borderVisible;
}

- (NSDictionary<NSString *, NSNumber *> *)telemetryBlockVisibilitySnapshot {
    NSUInteger nonzeroAreaCount = 0;
    NSUInteger intersectingCount = 0;
    NSUInteger appearanceValidCount = 0;
    NSUInteger visibleCount = 0;

    for (SCAllowBlockView *blockView in _blockViews) {
        NSRect frame = blockView.frame;
        BOOL hasNonzeroArea = NSWidth(frame) > 1 && NSHeight(frame) > 1;
        NSRect intersection = hasNonzeroArea ? NSIntersectionRect(frame, self.bounds) : NSZeroRect;
        BOOL intersectsColumn = NSWidth(intersection) > 1 && NSHeight(intersection) > 1;
        BOOL appearanceValid = SCBlockViewHasVisibleAppearanceForTelemetry(blockView);

        if (hasNonzeroArea) nonzeroAreaCount += 1;
        if (intersectsColumn) intersectingCount += 1;
        if (appearanceValid) appearanceValidCount += 1;
        if (hasNonzeroArea && intersectsColumn && appearanceValid) visibleCount += 1;
    }

    return @{
        @"rendered_count": @(_blockViews.count),
        @"nonzero_area_count": @(nonzeroAreaCount),
        @"intersecting_count": @(intersectingCount),
        @"appearance_valid_count": @(appearanceValidCount),
        @"visible_count": @(visibleCount),
    };
}

- (NSInteger)snapToGrid:(NSInteger)minutes {
    // Use lround and integer multiplication to avoid floating-point truncation errors
    // (e.g., round(47.0) * 15.0 = 704.9999... truncates to 704 instead of 705)
    return (NSInteger)lround(minutes / kSnapMinutes) * (NSInteger)kSnapMinutes;
}

- (void)reloadBlocks {
    // Remove old block views
    for (SCAllowBlockView *block in _blockViews) {
        [block removeFromSuperview];
    }
    [_blockViews removeAllObjects];

    if (self.bundles.count == 0) {
        return;
    }

    CGFloat totalWidth = self.bounds.size.width;

    // During drag operations, compute layout for EXISTING blocks only (not the dragging one)
    // The dragged/created block will be overlaid on top
    // This prevents other blocks from shifting during drag
    BOOL isDraggingExistingBlock = self.isDragging && !self.isCreatingBlock && self.draggingBundleID;
    BOOL isCreatingNewBlock = self.isCreatingBlock && self.draggingRange && self.draggingBundleID;

    // Compute layouts for all blocks (excluding the one being dragged if applicable)
    NSArray<SCBlockLayoutInfo *> *layouts = [self computeBlockLayoutsIncludingDragRange:nil
                                                                            forBundleID:nil
                                                                            windowIndex:-1
                                                                             isNewBlock:NO];

    // Build lookup: "bundleID:windowIndex" -> layout
    NSMutableDictionary<NSString *, SCBlockLayoutInfo *> *layoutLookup = [NSMutableDictionary dictionary];
    for (SCBlockLayoutInfo *layout in layouts) {
        NSString *key = [NSString stringWithFormat:@"%@:%ld", layout.bundleID, (long)layout.windowIndex];
        layoutLookup[key] = layout;
    }

    // Render existing blocks using computed layouts
    for (SCBlockBundle *bundle in self.bundles) {
        SCWeeklySchedule *schedule = self.schedules[bundle.bundleID];
        if (!schedule) continue;

        NSArray<SCTimeRange *> *windows = [schedule allowedWindowsForDay:self.day];

        for (NSInteger i = 0; i < (NSInteger)windows.count; i++) {
            SCTimeRange *range = windows[i];

            // Skip rendering the block being dragged here - it will be rendered as overlay
            BOOL isTheDraggedBlock = isDraggingExistingBlock &&
                [bundle.bundleID isEqualToString:self.draggingBundleID] &&
                i == self.selectedBlockIndex;

            if (isTheDraggedBlock) {
                continue;  // Will render as overlay below
            }

            // Get layout info for this block
            NSString *key = [NSString stringWithFormat:@"%@:%ld", bundle.bundleID, (long)i];
            SCBlockLayoutInfo *layout = layoutLookup[key];

            // Calculate position and size using dynamic layout
            CGFloat laneWidth, laneX;
            if (layout && layout.maxOverlap > 0) {
                laneWidth = (totalWidth - kLanePadding * 2) / layout.maxOverlap;
                laneX = kLanePadding + layout.laneSlot * laneWidth;
            } else {
                // Fallback: full width if no layout info
                laneWidth = totalWidth - kLanePadding * 2;
                laneX = kLanePadding;
            }

            CGFloat y = [self yFromMinutes:[range startMinutes]];
            CGFloat height = [self yFromMinutes:[range endMinutes]] - y;

            NSRect blockFrame = NSMakeRect(laneX, y, laneWidth - kLanePadding, height);
            SCAllowBlockView *blockView = [[SCAllowBlockView alloc] initWithFrame:blockFrame];
            blockView.timeRange = range;
            blockView.color = bundle.color;
            blockView.bundleID = bundle.bundleID;
            blockView.isCommitted = self.isCommitted;

            // Dimmed if not focused bundle (and we have a focused bundle)
            if (self.focusedBundleID && ![bundle.bundleID isEqualToString:self.focusedBundleID]) {
                blockView.isDimmed = YES;
            }

            // Selected state
            if ([bundle.bundleID isEqualToString:self.selectedBundleID] && i == self.selectedBlockIndex) {
                blockView.isSelected = YES;
            }

            [self addSubview:blockView];
            [_blockViews addObject:blockView];
        }
    }

    // Calculate unified display mode for all blocks (use the most constrained)
    NSInteger unifiedDisplayMode = [self calculateUnifiedDisplayModeForBlocks:_blockViews];
    for (SCAllowBlockView *blockView in _blockViews) {
        blockView.timeLabelDisplayMode = unifiedDisplayMode;
    }

    // Render dragged existing block as overlay (during move/resize)
    if (isDraggingExistingBlock && self.draggingRange) {
        SCBlockBundle *dragBundle = [self bundleForID:self.draggingBundleID];
        if (dragBundle) {
            // During drag, show at full width as overlay
            CGFloat laneWidth = totalWidth - kLanePadding * 2;
            CGFloat laneX = kLanePadding;

            CGFloat y = [self yFromMinutes:[self.draggingRange startMinutes]];
            CGFloat height = [self yFromMinutes:[self.draggingRange endMinutes]] - y;

            NSRect blockFrame = NSMakeRect(laneX, y, laneWidth - kLanePadding, height);
            SCAllowBlockView *blockView = [[SCAllowBlockView alloc] initWithFrame:blockFrame];
            blockView.timeRange = self.draggingRange;
            blockView.color = dragBundle.color;
            blockView.bundleID = dragBundle.bundleID;
            blockView.isCommitted = NO;
            blockView.isSelected = YES;  // Highlight the dragging block

            [self addSubview:blockView];
            [_blockViews addObject:blockView];
        }
    }

    // Render creation preview block (drag-to-create new block)
    if (isCreatingNewBlock) {
        SCBlockBundle *previewBundle = [self bundleForID:self.draggingBundleID];
        if (previewBundle) {
            // During creation, show at full width as overlay
            CGFloat laneWidth = totalWidth - kLanePadding * 2;
            CGFloat laneX = kLanePadding;

            CGFloat y = [self yFromMinutes:[self.draggingRange startMinutes]];
            CGFloat height = [self yFromMinutes:[self.draggingRange endMinutes]] - y;

            NSRect blockFrame = NSMakeRect(laneX, y, laneWidth - kLanePadding, height);
            SCAllowBlockView *blockView = [[SCAllowBlockView alloc] initWithFrame:blockFrame];
            blockView.timeRange = self.draggingRange;
            blockView.color = previewBundle.color;
            blockView.bundleID = previewBundle.bundleID;
            blockView.isCommitted = NO;

            [self addSubview:blockView];
            [_blockViews addObject:blockView];
        }
    }

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Background - use bounds, not dirtyRect (dirtyRect can have negative origin in scroll views)
    [[NSColor colorWithWhite:0.15 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    // Hour lines
    [[NSColor colorWithWhite:0.25 alpha:1.0] setStroke];
    for (NSInteger hour = 0; hour <= 24; hour++) {
        CGFloat y = [self yFromMinutes:hour * 60];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(0, y)];
        [line lineToPoint:NSMakePoint(self.bounds.size.width, y)];
        line.lineWidth = (hour % 6 == 0) ? 1.0 : 0.5;  // Thicker lines at 6am, 12pm, 6pm
        [line stroke];
    }

    // Right edge separator line (day column divider)
    [[NSColor colorWithWhite:0.3 alpha:1.0] setStroke];
    NSBezierPath *separator = [NSBezierPath bezierPath];
    [separator moveToPoint:NSMakePoint(self.bounds.size.width - 0.5, 0)];
    [separator lineToPoint:NSMakePoint(self.bounds.size.width - 0.5, self.bounds.size.height)];
    separator.lineWidth = 1.0;
    [separator stroke];

    // NOW line (if today)
    if (self.isToday) {
        NSCalendar *calendar = [NSCalendar currentCalendar];
        if (self.displayTimeZone != nil) calendar.timeZone = self.displayTimeZone;
        NSDateComponents *components = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        NSInteger nowMinutes = components.hour * 60 + components.minute;
        CGFloat nowY = [self yFromMinutes:nowMinutes];

        [[NSColor systemRedColor] setStroke];
        NSBezierPath *nowLine = [NSBezierPath bezierPath];
        [nowLine moveToPoint:NSMakePoint(0, nowY)];
        [nowLine lineToPoint:NSMakePoint(self.bounds.size.width, nowY)];
        nowLine.lineWidth = 2.0;
        CGFloat pattern[] = {4, 2};
        [nowLine setLineDash:pattern count:2 phase:0];
        [nowLine stroke];
    }
}

- (void)clearSelection {
    self.selectedBlockIndex = -1;
    self.selectedBundleID = nil;
    [self reloadBlocks];
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    // Notify that this column was clicked (for tracking last clicked day)
    if (self.onColumnClicked) {
        self.onColumnClicked();
    }

    if (self.isCommitted) return;

    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

    // FIRST: Check if clicking on an existing block
    for (SCAllowBlockView *blockView in _blockViews) {
        if (NSPointInRect(loc, blockView.frame)) {
            // Get the bundle this block belongs to
            NSString *blockBundleID = blockView.bundleID;
            if (!blockBundleID) continue;

            // If a bundle is focused and this block belongs to a different bundle,
            // ignore the click - user needs to interact with focused bundle only
            if (self.focusedBundleID && ![blockBundleID isEqualToString:self.focusedBundleID]) {
                // Treat as empty area click - could start drag-to-create on top of dimmed block
                break;  // Fall through to empty area handling
            }

            if (event.clickCount == 2) {
                // Double-click: open editor for THIS block's bundle
                SCBlockBundle *bundle = [self bundleForID:blockBundleID];
                if (bundle && self.onBlockDoubleClicked) {
                    self.onBlockDoubleClicked(bundle);
                }
                return;
            }

            // Single click on block - clear all other selections first, then select this one
            if (self.onBlockSelected) {
                self.onBlockSelected();  // Parent will clear ALL selections
            }
            self.selectedBundleID = blockBundleID;

            // Find index in this bundle's schedule
            SCWeeklySchedule *schedule = self.schedules[blockBundleID];
            NSArray *windows = [schedule allowedWindowsForDay:self.day];
            self.selectedBlockIndex = [windows indexOfObject:blockView.timeRange];

            // Check if near top or bottom edge for resize
            CGFloat relY = loc.y - blockView.frame.origin.y;
            if (relY < kEdgeDetectionZone) {
                self.isResizingTop = YES;
            } else if (relY > blockView.frame.size.height - kEdgeDetectionZone) {
                self.isResizingBottom = YES;
            } else {
                self.isMovingBlock = YES;
            }

            // Don't set isDragging yet - wait until actual drag detected (threshold exceeded)
            // This prevents blocks from going full-width on simple click-to-select
            self.draggingBundleID = blockBundleID;
            self.draggingRange = [blockView.timeRange copy];
            self.originalDragRange = [blockView.timeRange copy];
            self.dragStartY = loc.y;
            // MUST snap dragStartMinutes so delta calculations stay on 15-min grid
            self.dragStartMinutes = [self snapToGrid:[self minutesFromY:loc.y]];

            [self reloadBlocks];

            // Make grid view first responder so it receives keyboard events (for Delete key)
            // DayColumn is transient; grid view is stable and can route keys appropriately
            NSView *gridView = self.superview;
            while (gridView && ![gridView isKindOfClass:[SCCalendarGridView class]]) {
                gridView = gridView.superview;
            }
            [self.window makeFirstResponder:gridView ?: self];

            // Tracking loop - captures all drag events, prevents NSScrollView from stealing them
            BOOL didActuallyDrag = NO;
            NSPoint startPoint = loc;

            while (YES) {
                @autoreleasepool {
                    NSEvent *nextEvent = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                                                  untilDate:[NSDate distantFuture]
                                                                     inMode:NSEventTrackingRunLoopMode
                                                                    dequeue:YES];
                    if (!nextEvent) continue;

                    if (nextEvent.type == NSEventTypeLeftMouseUp) {
                        if (didActuallyDrag) {
                            // Real drag - apply changes
                            [self mouseUp:nextEvent];
                        } else {
                            // Simple click - just reset drag state, keep selection
                            self.isDragging = NO;
                            self.isMovingBlock = NO;
                            self.isResizingTop = NO;
                            self.isResizingBottom = NO;
                            self.draggingRange = nil;
                            self.originalDragRange = nil;
                            self.draggingBundleID = nil;
                        }
                        break;
                    } else if (nextEvent.type == NSEventTypeLeftMouseDragged) {
                        // Hysteresis check - ignore jitters
                        NSPoint currentPoint = [self convertPoint:nextEvent.locationInWindow fromView:nil];
                        CGFloat distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y);

                        if (distance > kDragThreshold) {
                            didActuallyDrag = YES;

                            // Set isDragging and trigger full-width only when actual drag starts
                            if (!self.isDragging) {
                                self.isDragging = YES;
                                [self reloadBlocks];  // Now triggers full-width overlay
                            }

                            [self mouseDragged:nextEvent];
                        }
                    }
                }
            }
            return;
        }
    }

    // SECOND: Clicking on empty area - requires bundle focus to create blocks
    if (!self.focusedBundleID) {
        // No bundle focused - show warning
        if (self.onNoFocusInteraction) {
            self.onNoFocusInteraction();
        }
        // Make grid view first responder so ESC still works
        [self.window makeFirstResponder:self.superview];
        return;
    }

    // Double-click on empty area with focused bundle - open editor
    if (event.clickCount == 2) {
        SCBlockBundle *bundle = [self bundleForID:self.focusedBundleID];
        if (bundle && self.onBlockDoubleClicked) {
            self.onBlockDoubleClicked(bundle);
        }
        return;
    }

    // Empty area click with focus - record position for potential drag-to-create
    // (Don't create block yet - wait for drag threshold)
    // Clear selection in other columns when clicking empty area
    if (self.onBlockSelected) {
        self.onBlockSelected();
    }
    self.hasPendingEmptyAreaClick = YES;
    self.mouseDownPoint = loc;
    self.dragStartY = loc.y;
    self.dragStartMinutes = [self snapToGrid:[self minutesFromY:loc.y]];
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.isCommitted) return;

    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if we should start drag-to-create from a pending empty area click
    if (self.hasPendingEmptyAreaClick && !self.isDragging) {
        // Check if mouse has moved past threshold
        CGFloat dx = loc.x - self.mouseDownPoint.x;
        CGFloat dy = loc.y - self.mouseDownPoint.y;
        CGFloat distance = sqrt(dx * dx + dy * dy);

        if (distance >= kDragThreshold) {
            // Start creating new block via drag
            self.hasPendingEmptyAreaClick = NO;
            self.isCreatingBlock = YES;
            self.isDragging = YES;
            self.draggingBundleID = self.focusedBundleID;
            self.draggingRange = [SCTimeRange rangeWithStart:[self timeStringFromMinutes:self.dragStartMinutes]
                                                         end:[self timeStringFromMinutes:self.dragStartMinutes + 60]];

            // Make the grid view (not DayColumn) first responder so ESC key works after block creation
            // DayColumn is transient (destroyed on reloadData), but grid view is stable
            NSView *gridView = self.superview;
            while (gridView && ![gridView isKindOfClass:[SCCalendarGridView class]]) {
                gridView = gridView.superview;
            }
            [self.window makeFirstResponder:gridView ?: self];
        } else {
            return;  // Not yet past threshold
        }
    }

    if (!self.isDragging) return;

    NSInteger currentMinutes = [self snapToGrid:[self minutesFromY:loc.y]];

    if (self.isCreatingBlock) {
        // Creating new block - adjust end time
        NSInteger start = self.dragStartMinutes;
        NSInteger end = currentMinutes;
        if (end < start) {
            NSInteger temp = start;
            start = end;
            end = temp;
        }
        if (end - start < kMinBlockDuration) {
            end = start + (NSInteger)kMinBlockDuration;
        }
        self.draggingRange = [SCTimeRange rangeWithStart:[self timeStringFromMinutes:start]
                                                     end:[self timeStringFromMinutes:MIN(end, 1440)]];
    } else if (self.isResizingTop) {
        // Resize top edge
        NSInteger newStart = MIN(currentMinutes, [self.originalDragRange endMinutes] - (NSInteger)kMinBlockDuration);
        newStart = MAX(0, newStart);
        self.draggingRange = [SCTimeRange rangeWithStart:[self timeStringFromMinutes:newStart]
                                                     end:self.originalDragRange.endTime];
    } else if (self.isResizingBottom) {
        // Resize bottom edge
        NSInteger newEnd = MAX(currentMinutes, [self.originalDragRange startMinutes] + (NSInteger)kMinBlockDuration);
        newEnd = MIN(1440, newEnd);
        self.draggingRange = [SCTimeRange rangeWithStart:self.originalDragRange.startTime
                                                     end:[self timeStringFromMinutes:newEnd]];
    } else if (self.isMovingBlock) {
        // Move whole block
        NSInteger delta = currentMinutes - self.dragStartMinutes;
        NSInteger newStart = [self.originalDragRange startMinutes] + delta;
        NSInteger newEnd = [self.originalDragRange endMinutes] + delta;

        // Clamp to day boundaries
        if (newStart < 0) {
            newEnd -= newStart;
            newStart = 0;
        }
        if (newEnd > 1440) {
            newStart -= (newEnd - 1440);
            newEnd = 1440;
        }

        self.draggingRange = [SCTimeRange rangeWithStart:[self timeStringFromMinutes:MAX(0, newStart)]
                                                     end:[self timeStringFromMinutes:MIN(1440, newEnd)]];
    }

    // Update visual preview
    [self reloadBlocks];
}

- (void)mouseUp:(NSEvent *)event {
    // Reset pending empty area click state
    self.hasPendingEmptyAreaClick = NO;

    if (!self.isDragging) return;

    // Capture drag state before resetting (needed for building the schedule)
    NSString *bundleID = self.draggingBundleID;
    SCTimeRange *range = self.draggingRange;
    BOOL wasCreating = self.isCreatingBlock;
    NSInteger selectedIdx = self.selectedBlockIndex;

    // Reset drag state BEFORE calling callback
    // This ensures reloadBlocks (called inside handleScheduleUpdate) sees isDragging=NO
    // and renders the final blocks correctly instead of the drag preview
    self.isDragging = NO;
    self.isCreatingBlock = NO;
    self.isResizingTop = NO;
    self.isResizingBottom = NO;
    self.isMovingBlock = NO;
    self.draggingRange = nil;
    self.originalDragRange = nil;
    self.draggingBundleID = nil;

    // Apply the change using captured values
    if (bundleID && range && [range isValid]) {
        SCWeeklySchedule *schedule = [self.schedules[bundleID] copy];
        if (!schedule) {
            schedule = [SCWeeklySchedule emptyScheduleForBundleID:bundleID];
        }

        NSMutableArray *windows = [[schedule allowedWindowsForDay:self.day] mutableCopy];
        if (!windows) windows = [NSMutableArray array];

        if (wasCreating) {
            // Add new block
            [windows addObject:range];
        } else if (selectedIdx >= 0 && selectedIdx < windows.count) {
            // Update existing block
            [windows replaceObjectAtIndex:selectedIdx withObject:range];
        }

        // Merge overlapping blocks
        windows = [[self mergeOverlappingRanges:windows] mutableCopy];

        [schedule setAllowedWindows:windows forDay:self.day];

        if (self.onScheduleUpdated) {
            self.onScheduleUpdated(bundleID, schedule);
        }
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (self.isCommitted) {
        [[NSCursor arrowCursor] set];
        return;
    }

    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if over any block
    for (SCAllowBlockView *blockView in _blockViews) {
        if (NSPointInRect(loc, blockView.frame)) {
            CGFloat relY = loc.y - blockView.frame.origin.y;

            // Near top or bottom edge = resize cursor
            if (relY < kEdgeDetectionZone || relY > blockView.frame.size.height - kEdgeDetectionZone) {
                [[NSCursor resizeUpDownCursor] set];
            } else {
                // Middle of block = grab cursor
                [[NSCursor openHandCursor] set];
            }
            return;
        }
    }

    // Not over a block = arrow cursor
    [[NSCursor arrowCursor] set];
}

- (void)keyDown:(NSEvent *)event {
    // Escape key - progressive: first clear selection, then clear focus
    if (event.keyCode == 53) {  // Escape
        if (self.selectedBlockIndex >= 0) {
            // First: clear block selection
            self.selectedBlockIndex = -1;
            self.selectedBundleID = nil;
            [self reloadBlocks];
        } else if (self.onEmptyAreaClicked) {
            // Second: clear bundle focus
            self.onEmptyAreaClicked();
        }
        return;
    }

    if (self.isCommitted) return;

    // Delete key removes selected block
    if (event.keyCode == 51 || event.keyCode == 117) {  // Backspace or Delete
        if (self.selectedBundleID && self.selectedBlockIndex >= 0) {
            SCWeeklySchedule *schedule = [self.schedules[self.selectedBundleID] copy];
            NSMutableArray *windows = [[schedule allowedWindowsForDay:self.day] mutableCopy];
            if (self.selectedBlockIndex < windows.count) {
                [windows removeObjectAtIndex:self.selectedBlockIndex];
                [schedule setAllowedWindows:windows forDay:self.day];

                if (self.onScheduleUpdated) {
                    self.onScheduleUpdated(self.selectedBundleID, schedule);
                }
            }
            self.selectedBlockIndex = -1;
            self.selectedBundleID = nil;
        }
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

#pragma mark - Helpers

- (NSString *)timeStringFromMinutes:(NSInteger)minutes {
    NSInteger hours = minutes / 60;
    NSInteger mins = minutes % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)hours, (long)mins];
}

- (NSArray<SCTimeRange *> *)mergeOverlappingRanges:(NSArray<SCTimeRange *> *)ranges {
    if (ranges.count <= 1) return ranges;

    // Sort by start time
    NSArray *sorted = [ranges sortedArrayUsingComparator:^NSComparisonResult(SCTimeRange *a, SCTimeRange *b) {
        return [@([a startMinutes]) compare:@([b startMinutes])];
    }];

    NSMutableArray *merged = [NSMutableArray array];
    SCTimeRange *current = [sorted.firstObject copy];

    for (NSInteger i = 1; i < sorted.count; i++) {
        SCTimeRange *next = sorted[i];
        if ([next startMinutes] <= [current endMinutes]) {
            // Overlapping - merge
            NSInteger newEnd = MAX([current endMinutes], [next endMinutes]);
            current = [SCTimeRange rangeWithStart:current.startTime
                                              end:[self timeStringFromMinutes:newEnd]];
        } else {
            [merged addObject:current];
            current = [next copy];
        }
    }
    [merged addObject:current];

    return merged;
}

- (nullable SCBlockBundle *)bundleForID:(NSString *)bundleID {
    for (SCBlockBundle *bundle in self.bundles) {
        if ([bundle.bundleID isEqualToString:bundleID]) {
            return bundle;
        }
    }
    return nil;
}

/// Calculate unified display mode: find the most constrained block and use that mode for all
/// Returns: 1=full, 2=fallback (start only), 3=hidden
- (NSInteger)calculateUnifiedDisplayModeForBlocks:(NSArray<SCAllowBlockView *> *)blockViews {
    if (blockViews.count == 0) return 1;

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    CGFloat margin = 3.0;

    NSInteger worstMode = 1;  // Start with "full" (best case)

    for (SCAllowBlockView *blockView in blockViews) {
        if (!blockView.timeRange || blockView.bounds.size.height <= 30) {
            // Too short for any labels - skip this block but don't affect others
            // (drawRect has its own height check for this block)
            continue;
        }

        NSString *startString = [blockView.timeRange format12Hour:blockView.timeRange.startTime];
        NSString *fullStartString = [NSString stringWithFormat:@"%@ -", startString];
        NSString *endString = [blockView.timeRange format12Hour:blockView.timeRange.endTime];

        CGFloat fullStartWidth = ceil([fullStartString sizeWithAttributes:attrs].width);
        CGFloat endWidth = ceil([endString sizeWithAttributes:attrs].width);
        CGFloat rawStartWidth = ceil([startString sizeWithAttributes:attrs].width);

        CGFloat availableWidth = blockView.bounds.size.width - (margin * 2);

        BOOL canFitFull = (availableWidth >= fullStartWidth) && (availableWidth >= endWidth);
        BOOL canFitStart = (availableWidth >= rawStartWidth);

        NSInteger blockMode;
        if (canFitFull) blockMode = 1;
        else if (canFitStart) blockMode = 2;
        else blockMode = 3;

        worstMode = MAX(worstMode, blockMode);
    }

    return worstMode;
}

#pragma mark - Dynamic Layout Computation

/// Computes layout info for all blocks, optionally including a drag preview range
- (NSArray<SCBlockLayoutInfo *> *)computeBlockLayoutsIncludingDragRange:(SCTimeRange *)dragRange
                                                            forBundleID:(NSString *)dragBundleID
                                                            windowIndex:(NSInteger)dragWindowIndex
                                                           isNewBlock:(BOOL)isNewBlock {
    NSMutableArray<SCBlockLayoutInfo *> *blocks = [NSMutableArray array];

    // Step 1: Collect all blocks from all bundles
    for (NSInteger bundleIndex = 0; bundleIndex < self.bundles.count; bundleIndex++) {
        SCBlockBundle *bundle = self.bundles[bundleIndex];
        SCWeeklySchedule *schedule = self.schedules[bundle.bundleID];
        if (!schedule) continue;

        NSArray<SCTimeRange *> *windows = [schedule allowedWindowsForDay:self.day];

        for (NSInteger windowIndex = 0; windowIndex < windows.count; windowIndex++) {
            SCTimeRange *range = windows[windowIndex];

            // Use drag override if this is the block being dragged/resized
            if (!isNewBlock && dragRange &&
                [bundle.bundleID isEqualToString:dragBundleID] &&
                windowIndex == dragWindowIndex) {
                range = dragRange;
            }

            SCBlockLayoutInfo *info = [[SCBlockLayoutInfo alloc] init];
            info.bundleIndex = bundleIndex;
            info.windowIndex = windowIndex;
            info.startMinutes = [range startMinutes];
            info.endMinutes = [range endMinutes];
            info.maxOverlap = 1;
            info.laneSlot = 0;
            info.bundleDisplayOrder = bundle.displayOrder;
            info.bundleID = bundle.bundleID;

            [blocks addObject:info];
        }
    }

    // Add preview block for new block creation
    if (isNewBlock && dragRange && dragBundleID) {
        SCBlockBundle *previewBundle = [self bundleForID:dragBundleID];
        if (previewBundle) {
            SCBlockLayoutInfo *previewInfo = [[SCBlockLayoutInfo alloc] init];
            previewInfo.bundleIndex = -1;  // Special marker for preview
            previewInfo.windowIndex = -1;
            previewInfo.startMinutes = [dragRange startMinutes];
            previewInfo.endMinutes = [dragRange endMinutes];
            previewInfo.maxOverlap = 1;
            previewInfo.laneSlot = 0;
            previewInfo.bundleDisplayOrder = previewBundle.displayOrder;
            previewInfo.bundleID = dragBundleID;

            [blocks addObject:previewInfo];
        }
    }

    if (blocks.count == 0) return blocks;

    // Step 2: Sweep-line algorithm to compute maxOverlap for each block
    [self computeMaxOverlapForBlocks:blocks];

    // Step 3: Greedy packing to assign lane slots
    [self assignLaneSlotsUsingGreedyPacking:blocks];

    return blocks;
}

/// Sweep-line algorithm to compute maxOverlap for each block
- (void)computeMaxOverlapForBlocks:(NSMutableArray<SCBlockLayoutInfo *> *)blocks {
    // Build sweep events
    NSMutableArray *events = [NSMutableArray array];
    for (SCBlockLayoutInfo *block in blocks) {
        [events addObject:@{@"time": @(block.startMinutes), @"type": @(0), @"block": block}];  // 0 = START
        [events addObject:@{@"time": @(block.endMinutes), @"type": @(1), @"block": block}];    // 1 = END
    }

    // Sort: by time, then END (1) before START (0) at same time
    // This ensures adjacent blocks (one ends when another starts) don't count as overlapping
    [events sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult timeCompare = [a[@"time"] compare:b[@"time"]];
        if (timeCompare != NSOrderedSame) return timeCompare;
        // END (1) before START (0) at same time
        return [b[@"type"] compare:a[@"type"]];
    }];

    // Sweep through events
    NSMutableSet<SCBlockLayoutInfo *> *activeBlocks = [NSMutableSet set];

    for (NSDictionary *event in events) {
        SCBlockLayoutInfo *block = event[@"block"];
        NSInteger type = [event[@"type"] integerValue];

        if (type == 0) {  // START
            [activeBlocks addObject:block];
            NSInteger overlapCount = activeBlocks.count;
            // Update maxOverlap for all currently active blocks
            for (SCBlockLayoutInfo *active in activeBlocks) {
                if (active.maxOverlap < overlapCount) {
                    active.maxOverlap = overlapCount;
                }
            }
        } else {  // END
            [activeBlocks removeObject:block];
        }
    }
}

/// Greedy packing algorithm to assign lane slots respecting displayOrder
- (void)assignLaneSlotsUsingGreedyPacking:(NSMutableArray<SCBlockLayoutInfo *> *)blocks {
    // Sort blocks by displayOrder (primary), then startMinutes (secondary)
    NSArray *sortedBlocks = [blocks sortedArrayUsingComparator:^NSComparisonResult(SCBlockLayoutInfo *a, SCBlockLayoutInfo *b) {
        if (a.bundleDisplayOrder != b.bundleDisplayOrder) {
            return a.bundleDisplayOrder < b.bundleDisplayOrder ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.startMinutes != b.startMinutes) {
            return a.startMinutes < b.startMinutes ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    // Each lane is a list of blocks that don't overlap
    NSMutableArray<NSMutableArray<SCBlockLayoutInfo *> *> *lanes = [NSMutableArray array];

    for (SCBlockLayoutInfo *block in sortedBlocks) {
        NSInteger assignedLane = -1;

        // Try to fit into existing lanes
        for (NSInteger i = 0; i < lanes.count; i++) {
            BOOL overlapsAny = NO;
            for (SCBlockLayoutInfo *placed in lanes[i]) {
                // Check time overlap: a.start < b.end && b.start < a.end
                if (block.startMinutes < placed.endMinutes && placed.startMinutes < block.endMinutes) {
                    overlapsAny = YES;
                    break;
                }
            }
            if (!overlapsAny) {
                [lanes[i] addObject:block];
                block.laneSlot = i;
                assignedLane = i;
                break;
            }
        }

        // Create new lane if needed
        if (assignedLane == -1) {
            [lanes addObject:[NSMutableArray arrayWithObject:block]];
            block.laneSlot = lanes.count - 1;
        }
    }
}

@end

#pragma mark - SCCalendarGridView

@interface SCCalendarGridView ()

@property (nonatomic, strong) NSView *headerContainer;
@property (nonatomic, strong) NSView *hourLabelContainer;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *columnsContainer;
@property (nonatomic, strong) NSMutableArray<SCCalendarDayColumn *> *dayColumns;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *dayLabels;

// Copy/paste state
@property (nonatomic, strong, nullable) SCTimeRange *copiedBlock;
@property (nonatomic, copy, nullable) NSString *copiedBundleID;
@property (nonatomic, assign) SCDayOfWeek lastClickedDay;

// Empty state hint
@property (nonatomic, strong) NSTextField *emptyStateLabel;

@end

@implementation SCCalendarGridView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bundles = @[];
        _schedules = @{};
        _dayColumns = [NSMutableArray array];
        _dayLabels = [NSMutableArray array];
        _undoManager = [[NSUndoManager alloc] init];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.wantsLayer = YES;

    CGFloat availableWidth = self.bounds.size.width - kHourLabelWidth;

    // Header container for day labels
    self.headerContainer = [[NSView alloc] initWithFrame:NSMakeRect(kHourLabelWidth, self.bounds.size.height - kDayHeaderHeight, availableWidth, kDayHeaderHeight)];
    self.headerContainer.wantsLayer = YES;
    self.headerContainer.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:self.headerContainer];

    // Hour labels on the left
    CGFloat timelineHeight = self.bounds.size.height - kDayHeaderHeight - kTimelineTopPadding;
    self.hourLabelContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kHourLabelWidth, timelineHeight)];
    self.hourLabelContainer.wantsLayer = YES;
    self.hourLabelContainer.autoresizingMask = NSViewHeightSizable;
    [self addSubview:self.hourLabelContainer];

    // Scroll view for day columns
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(kHourLabelWidth, 0, availableWidth, timelineHeight)];
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.columnsContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, availableWidth, timelineHeight)];
    self.columnsContainer.wantsLayer = YES;
    self.columnsContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.documentView = self.columnsContainer;
    [self addSubview:self.scrollView];

    // Empty state hint label (centered in columns container)
    self.emptyStateLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.emptyStateLabel.stringValue = @"Select bundle and drag to create allow block";
    self.emptyStateLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.emptyStateLabel.textColor = [NSColor tertiaryLabelColor];
    self.emptyStateLabel.bezeled = NO;
    self.emptyStateLabel.editable = NO;
    self.emptyStateLabel.drawsBackground = NO;
    self.emptyStateLabel.alignment = NSTextAlignmentCenter;
    [self.emptyStateLabel sizeToFit];
    [self.columnsContainer addSubview:self.emptyStateLabel];

    [self setupHourLabels];
}

- (void)setupHourLabels {
    // Remove old labels
    for (NSView *subview in [self.hourLabelContainer.subviews copy]) {
        [subview removeFromSuperview];
    }

    CGFloat timelineHeight = self.hourLabelContainer.bounds.size.height;

    // Create hour labels for key times: 12am, 6am, 12pm, 6pm
    NSArray *hours = @[@0, @6, @12, @18, @24];
    NSArray *labels = @[@"12am", @"6am", @"12pm", @"6pm", @"12am"];

    for (NSInteger i = 0; i < hours.count; i++) {
        NSInteger hour = [hours[i] integerValue];
        CGFloat y = timelineHeight - (hour / 24.0) * timelineHeight - 8;  // Flipped for display

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(4, y, kHourLabelWidth - 8, 16)];
        label.stringValue = labels[i];
        label.font = [NSFont systemFontOfSize:10];
        label.textColor = [NSColor secondaryLabelColor];
        label.bezeled = NO;
        label.editable = NO;
        label.drawsBackground = NO;
        label.alignment = NSTextAlignmentRight;
        [self.hourLabelContainer addSubview:label];
    }
}

- (void)reloadData {
    // Rescue first responder if it's a column we're about to destroy
    // (DayColumns are transient - destroyed and recreated on each reload)
    NSResponder *fr = self.window.firstResponder;
    if ([fr isKindOfClass:[NSView class]] && [(NSView *)fr isDescendantOf:self]) {
        [self.window makeFirstResponder:self];
    }

    // Get days to display
    NSArray<NSNumber *> *days;
    if (self.showOnlyRemainingDays && self.weekOffset == 0) {
        days = [SCWeeklySchedule remainingDaysInWeekStartingMonday:YES];
    } else {
        days = [SCWeeklySchedule allDaysStartingMonday:YES];
    }

    // Remove old day labels and columns
    for (NSTextField *label in self.dayLabels) {
        [label removeFromSuperview];
    }
    [self.dayLabels removeAllObjects];

    for (SCCalendarDayColumn *col in self.dayColumns) {
        [col removeFromSuperview];
    }
    [self.dayColumns removeAllObjects];

    if (days.count == 0) return;

    // Calculate column width and timeline height from scrollView (source of truth for available space)
    CGFloat availableWidth = self.headerContainer.bounds.size.width;
    CGFloat columnWidth = availableWidth / days.count;
    CGFloat timelineHeight = self.scrollView.contentSize.height;

    // Update hour label container and labels for new height
    self.hourLabelContainer.frame = NSMakeRect(0, 0, kHourLabelWidth, timelineHeight);
    [self setupHourLabels];

    // Determine today's day
    NSCalendar *displayCalendar = [NSCalendar currentCalendar];
    if (self.displayTimeZone != nil) displayCalendar.timeZone = self.displayTimeZone;
    NSDateComponents *todayComponents = [displayCalendar
        components:NSCalendarUnitWeekday fromDate:[NSDate date]];
    SCDayOfWeek today = (SCDayOfWeek)(todayComponents.weekday - 1);

    // Create day labels and columns
    for (NSInteger i = 0; i < days.count; i++) {
        SCDayOfWeek day = [days[i] integerValue];
        CGFloat x = i * columnWidth;
        BOOL isToday = (day == today && self.weekOffset == 0);

        // Day label in header
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(x, 0, columnWidth, kDayHeaderHeight)];
        label.stringValue = [SCWeeklySchedule shortNameForDay:day];
        label.font = [NSFont systemFontOfSize:13 weight:isToday ? NSFontWeightBold : NSFontWeightMedium];
        label.textColor = isToday ? [NSColor systemBlueColor] : [NSColor labelColor];
        label.bezeled = NO;
        label.editable = NO;
        label.drawsBackground = NO;
        label.alignment = NSTextAlignmentCenter;
        [self.headerContainer addSubview:label];
        [self.dayLabels addObject:label];

        // Day column
        SCCalendarDayColumn *column = [[SCCalendarDayColumn alloc] initWithFrame:NSMakeRect(x, 0, columnWidth, timelineHeight)];
        column.day = day;
        column.bundles = self.bundles;
        column.schedules = self.schedules;
        column.focusedBundleID = self.focusedBundleID;
        column.isCommitted = self.isCommitted;
        column.isToday = isToday;
        column.displayTimeZone = self.displayTimeZone;
        column.timelineHeight = timelineHeight;

        // Set callbacks
        __weak typeof(self) weakSelf = self;
        SCDayOfWeek capturedDay = day;  // Capture day for callbacks
        column.onScheduleUpdated = ^(NSString *bundleID, SCWeeklySchedule *schedule) {
            if (!weakSelf) return;
            weakSelf.lastClickedDay = capturedDay;
            [weakSelf handleScheduleUpdate:schedule forBundleID:bundleID];
        };
        column.onEmptyAreaClicked = ^{
            weakSelf.lastClickedDay = capturedDay;
            if ([weakSelf.delegate respondsToSelector:@selector(calendarGridDidClickEmptyArea:)]) {
                [weakSelf.delegate calendarGridDidClickEmptyArea:weakSelf];
            }
        };
        column.onBlockDoubleClicked = ^(SCBlockBundle *bundle) {
            weakSelf.lastClickedDay = capturedDay;
            if ([weakSelf.delegate respondsToSelector:@selector(calendarGrid:didRequestEditBundle:forDay:)]) {
                [weakSelf.delegate calendarGrid:weakSelf didRequestEditBundle:bundle forDay:day];
            }
        };
        column.onNoFocusInteraction = ^{
            weakSelf.lastClickedDay = capturedDay;
            if ([weakSelf.delegate respondsToSelector:@selector(calendarGridDidAttemptInteractionWithoutFocus:)]) {
                [weakSelf.delegate calendarGridDidAttemptInteractionWithoutFocus:weakSelf];
            }
        };
        column.onColumnClicked = ^{
            weakSelf.lastClickedDay = capturedDay;
        };
        column.onBlockSelected = ^{
            // Clear selection in ALL columns (single selection only)
            for (SCCalendarDayColumn *col in weakSelf.dayColumns) {
                [col clearSelection];
            }
        };

        [column reloadBlocks];
        [self.columnsContainer addSubview:column];
        [self.dayColumns addObject:column];
    }

    // Update columns container size
    self.columnsContainer.frame = NSMakeRect(0, 0, availableWidth, timelineHeight);

    // Update empty state visibility
    [self updateEmptyStateVisibility];
}

- (void)updateEmptyStateVisibility {
    // Check if any schedules have any windows
    BOOL hasAnyBlocks = NO;
    for (NSString *bundleID in self.schedules) {
        SCWeeklySchedule *schedule = self.schedules[bundleID];
        if ([schedule hasAnyWindows]) {
            hasAnyBlocks = YES;
            break;
        }
    }

    self.emptyStateLabel.hidden = hasAnyBlocks;
    if (!hasAnyBlocks) {
        // Center the label in the columns container
        CGFloat containerWidth = self.columnsContainer.bounds.size.width;
        CGFloat containerHeight = self.columnsContainer.bounds.size.height;
        CGFloat labelWidth = self.emptyStateLabel.frame.size.width;
        CGFloat labelHeight = self.emptyStateLabel.frame.size.height;
        CGFloat x = (containerWidth - labelWidth) / 2;
        CGFloat y = (containerHeight - labelHeight) / 2;
        self.emptyStateLabel.frame = NSMakeRect(x, y, labelWidth, labelHeight);
        [self.emptyStateLabel.superview addSubview:self.emptyStateLabel positioned:NSWindowAbove relativeTo:nil];
    }
}

- (NSUInteger)telemetryDayColumnCount {
    return self.dayColumns.count;
}

- (NSUInteger)telemetryExpectedAllowBlockCount {
    NSUInteger count = 0;
    for (SCCalendarDayColumn *column in self.dayColumns) {
        for (SCBlockBundle *bundle in self.bundles) {
            SCWeeklySchedule *schedule = self.schedules[bundle.bundleID];
            count += [schedule allowedWindowsForDay:column.day].count;
        }
    }
    return count;
}

- (NSUInteger)telemetryRenderedAllowBlockCount {
    NSUInteger count = 0;
    for (SCCalendarDayColumn *column in self.dayColumns) {
        count += [column renderedBlockCount];
    }
    return count;
}

- (NSDictionary<NSString *, NSNumber *> *)telemetryAllowBlockVisibilitySnapshot {
    NSUInteger renderedCount = 0;
    NSUInteger nonzeroAreaCount = 0;
    NSUInteger intersectingCount = 0;
    NSUInteger appearanceValidCount = 0;
    NSUInteger visibleCount = 0;

    for (SCCalendarDayColumn *column in self.dayColumns) {
        NSDictionary<NSString *, NSNumber *> *snapshot = [column telemetryBlockVisibilitySnapshot];
        renderedCount += [snapshot[@"rendered_count"] unsignedIntegerValue];
        nonzeroAreaCount += [snapshot[@"nonzero_area_count"] unsignedIntegerValue];
        intersectingCount += [snapshot[@"intersecting_count"] unsignedIntegerValue];
        appearanceValidCount += [snapshot[@"appearance_valid_count"] unsignedIntegerValue];
        visibleCount += [snapshot[@"visible_count"] unsignedIntegerValue];
    }

    return @{
        @"rendered_count": @(renderedCount),
        @"nonzero_area_count": @(nonzeroAreaCount),
        @"intersecting_count": @(intersectingCount),
        @"appearance_valid_count": @(appearanceValidCount),
        @"visible_count": @(visibleCount),
    };
}

- (BOOL)telemetryEmptyStateVisible {
    return self.emptyStateLabel != nil && !self.emptyStateLabel.hidden;
}

- (void)handleScheduleUpdate:(SCWeeklySchedule *)schedule forBundleID:(NSString *)bundleID {
    // Update internal schedules dictionary
    NSMutableDictionary *newSchedules = [self.schedules mutableCopy];
    newSchedules[bundleID] = schedule;
    self.schedules = newSchedules;

    // Reload affected columns
    for (SCCalendarDayColumn *column in self.dayColumns) {
        column.schedules = self.schedules;
        [column reloadBlocks];
    }

    // Update empty state visibility
    [self updateEmptyStateVisibility];

    // Notify delegate
    if ([self.delegate respondsToSelector:@selector(calendarGrid:didUpdateSchedule:forBundleID:)]) {
        [self.delegate calendarGrid:self didUpdateSchedule:schedule forBundleID:bundleID];
    }
}

- (void)setFocusedBundleID:(NSString *)focusedBundleID {
    _focusedBundleID = [focusedBundleID copy];
    for (SCCalendarDayColumn *column in self.dayColumns) {
        column.focusedBundleID = _focusedBundleID;
        [column reloadBlocks];
    }
}

- (void)setIsCommitted:(BOOL)isCommitted {
    _isCommitted = isCommitted;
    for (SCCalendarDayColumn *column in self.dayColumns) {
        column.isCommitted = isCommitted;
        [column reloadBlocks];
    }
}

- (nullable SCWeeklySchedule *)scheduleForBundleID:(NSString *)bundleID {
    return self.schedules[bundleID];
}

- (nullable SCBlockBundle *)bundleForID:(NSString *)bundleID {
    for (SCBlockBundle *bundle in self.bundles) {
        if ([bundle.bundleID isEqualToString:bundleID]) {
            return bundle;
        }
    }
    return nil;
}

#pragma mark - Keyboard Handling

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSString *chars = [[event charactersIgnoringModifiers] lowercaseString];
    BOOL cmdPressed = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    BOOL shiftPressed = (event.modifierFlags & NSEventModifierFlagShift) != 0;

    // Cmd+Shift+Z = Redo
    if (cmdPressed && shiftPressed && [chars isEqualToString:@"z"]) {
        if ([self.undoManager canRedo]) {
            [self.undoManager redo];
            return YES;
        }
    }

    // Cmd+Z = Undo
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"z"]) {
        if ([self.undoManager canUndo]) {
            [self.undoManager undo];
            return YES;
        }
    }

    // Cmd+S = Disable (schedule auto-saves, don't trigger blocklist save)
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"s"]) {
        return YES;
    }

    // Cmd+C = Copy selected block
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"c"]) {
        // Find the selected block from any day column
        for (SCCalendarDayColumn *column in self.dayColumns) {
            if (column.selectedBundleID && column.selectedBlockIndex >= 0) {
                SCWeeklySchedule *schedule = self.schedules[column.selectedBundleID];
                NSArray *windows = [schedule allowedWindowsForDay:column.day];
                if (column.selectedBlockIndex < (NSInteger)windows.count) {
                    self.copiedBlock = [windows[column.selectedBlockIndex] copy];
                    self.copiedBundleID = column.selectedBundleID;
                    return YES;
                }
            }
        }
    }

    // Cmd+V = Paste block
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"v"]) {
        if (self.copiedBlock) {
            // Determine target bundle: focused bundle OR copied bundle (for non-focus paste)
            NSString *targetBundleID = self.focusedBundleID ?: self.copiedBundleID;
            if (!targetBundleID) return NO;

            // Paste to target day column
            for (SCCalendarDayColumn *column in self.dayColumns) {
                if (column.day == self.lastClickedDay) {
                    SCWeeklySchedule *schedule = [self.schedules[targetBundleID] copy];
                    if (!schedule) {
                        schedule = [SCWeeklySchedule emptyScheduleForBundleID:targetBundleID];
                    }

                    NSMutableArray *windows = [[schedule allowedWindowsForDay:column.day] mutableCopy];
                    if (!windows) windows = [NSMutableArray array];

                    // Check for duplicate time range (prevents multi-paste & same-day duplicates)
                    BOOL isDuplicate = NO;
                    for (SCTimeRange *existing in windows) {
                        if ([existing.startTime isEqualToString:self.copiedBlock.startTime] &&
                            [existing.endTime isEqualToString:self.copiedBlock.endTime]) {
                            isDuplicate = YES;
                            break;
                        }
                    }
                    if (isDuplicate) return NO;  // Silent block

                    // Add and sort by start time
                    [windows addObject:[self.copiedBlock copy]];
                    [windows sortUsingComparator:^NSComparisonResult(SCTimeRange *a, SCTimeRange *b) {
                        return [@([a startMinutes]) compare:@([b startMinutes])];
                    }];

                    // Merge overlapping ranges (same behavior as drag-end)
                    windows = [[column mergeOverlappingRanges:windows] mutableCopy];

                    [schedule setAllowedWindows:windows forDay:column.day];

                    if (column.onScheduleUpdated) {
                        column.onScheduleUpdated(targetBundleID, schedule);
                    }
                    return YES;
                }
            }
        }
    }

    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    // Escape key - progressive: first clear selection, THEN clear focus
    if (event.keyCode == 53) {  // Escape key
        if ([self hasSelectedBlock]) {
            [self clearAllSelections];
        } else if (self.focusedBundleID) {
            [self.delegate calendarGridDidClickEmptyArea:self];
        }
        return;
    }

    // Delete/Backspace key - delete selected block
    if (event.keyCode == 51 || event.keyCode == 117) {
        if (self.isCommitted) return;

        // Find the column with the selected block and forward the delete
        for (SCCalendarDayColumn *column in self.dayColumns) {
            if (column.selectedBundleID && column.selectedBlockIndex >= 0) {
                [column keyDown:event];
                return;
            }
        }
    }

    [super keyDown:event];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)hasSelectedBlock {
    for (SCCalendarDayColumn *column in self.dayColumns) {
        if (column.selectedBlockIndex >= 0) {
            return YES;
        }
    }
    return NO;
}

- (void)clearAllSelections {
    for (SCCalendarDayColumn *column in self.dayColumns) {
        [column clearSelection];
    }
}

@end

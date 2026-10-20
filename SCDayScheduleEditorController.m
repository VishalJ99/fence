//
//  SCDayScheduleEditorController.m
//  SelfControl
//

#import "SCDayScheduleEditorController.h"

// Constants for timeline view (scaled 33% larger)
static const CGFloat kTimelineHeight = 533.0;  // 400 * 1.33
static const CGFloat kTimelineWidth = 80.0;    // 60 * 1.33 - width for time labels
static const CGFloat kSnapMinutes = 15.0;
static const CGFloat kEdgeDetectionZone = 13.0; // Pixels near edge for resize detection
static const CGFloat kTimelinePaddingTop = 16.0;    // Padding so 12am label isn't cut off
static const CGFloat kTimelinePaddingBottom = 16.0; // Padding so bottom 12am label isn't cut off
static const CGFloat kDragThreshold = 5.0;  // Pixels to move before starting drag-to-create

#pragma mark - SCTimelineView (Private)

@interface SCTimelineView : NSView

@property (nonatomic, strong) NSMutableArray<SCTimeRange *> *allowedWindows;
@property (nonatomic) SCBundlePolicy policy;
@property (nonatomic, strong) NSColor *bundleColor;
@property (nonatomic, assign) BOOL isCommitted;
@property (nonatomic, copy, nullable) void (^onWindowsChanged)(void);
@property (nonatomic, copy, nullable) void (^onDragEnded)(void);  // Called after drag completes (for live merge)
@property (nonatomic, copy, nullable) void (^onRequestTimeInput)(NSInteger suggestedMinutes);
@property (nonatomic, copy, nullable) void (^onRequestEditBlock)(NSInteger blockIndex);
@property (nonatomic, copy, nullable) void (^onRequestDeleteBlock)(NSInteger blockIndex);
@property (nonatomic, strong) NSUndoManager *undoManager;

// Selection state
@property (nonatomic, assign) NSInteger selectedBlockIndex;

// Drag state
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) NSInteger draggingWindowIndex;
@property (nonatomic, assign) BOOL draggingStartEdge;
@property (nonatomic, assign) BOOL draggingEndEdge;
@property (nonatomic, assign) BOOL draggingWholeBlock;
@property (nonatomic, assign) BOOL isCreatingNewBlock;
@property (nonatomic, assign) BOOL hasPendingEmptyAreaClick;  // Waiting for drag threshold
@property (nonatomic, assign) NSPoint mouseDownPoint;
@property (nonatomic, assign) CGFloat dragStartY;
@property (nonatomic, assign) NSInteger dragStartMinutes;
@property (nonatomic, strong, nullable) SCTimeRange *originalDragRange;

- (NSInteger)minutesFromY:(CGFloat)y;
- (CGFloat)yFromMinutes:(NSInteger)minutes;
- (NSInteger)snapToGrid:(NSInteger)minutes;
- (NSInteger)windowIndexAtPoint:(NSPoint)point;

@end

@implementation SCTimelineView

@synthesize undoManager = _undoManager;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _allowedWindows = [NSMutableArray array];
        _bundleColor = [NSColor systemBlueColor];
        _draggingWindowIndex = -1;
        _selectedBlockIndex = -1;
        _undoManager = [[NSUndoManager alloc] init];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];

    // Handle Escape key - close the editor
    if (key == 27) { // ESC key
        // Find the window controller and trigger cancel
        NSWindowController *controller = self.window.windowController;
        if ([controller respondsToSelector:@selector(cancelClicked:)]) {
            [controller performSelector:@selector(cancelClicked:) withObject:nil];
        }
        return;
    }

    // Handle Delete and Backspace keys
    if (key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteFunctionKey) {
        if (self.selectedBlockIndex >= 0 && self.selectedBlockIndex < (NSInteger)self.allowedWindows.count) {
            if (self.onRequestDeleteBlock) {
                self.onRequestDeleteBlock(self.selectedBlockIndex);
                self.selectedBlockIndex = -1;
                [self setNeedsDisplay:YES];
            }
        }
        return;
    }
    [super keyDown:event];
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

    // Cmd+W = Close sheet
    if (cmdPressed && !shiftPressed && [chars isEqualToString:@"w"]) {
        NSWindowController *controller = self.window.windowController;
        if ([controller respondsToSelector:@selector(cancelClicked:)]) {
            [controller performSelector:@selector(cancelClicked:) withObject:nil];
            return YES;
        }
    }

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

    // Let other key equivalents propagate
    return NO;
}

- (void)addBlockWithUndo:(SCTimeRange *)block {
    [[self.undoManager prepareWithInvocationTarget:self] removeBlockWithUndo:block];
    [self.undoManager setActionName:@"Add Block"];

    [self.allowedWindows addObject:block];
    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (void)removeBlockWithUndo:(SCTimeRange *)block {
    NSUInteger index = [self.allowedWindows indexOfObject:block];
    if (index == NSNotFound) return;

    [[self.undoManager prepareWithInvocationTarget:self] insertBlockWithUndo:[block copy] atIndex:index];
    [self.undoManager setActionName:@"Delete Block"];

    [self.allowedWindows removeObjectAtIndex:index];

    // Clear or adjust selection
    if (self.selectedBlockIndex == (NSInteger)index) {
        self.selectedBlockIndex = -1;
    } else if (self.selectedBlockIndex > (NSInteger)index) {
        self.selectedBlockIndex--;
    }

    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (void)insertBlockWithUndo:(SCTimeRange *)block atIndex:(NSUInteger)index {
    [[self.undoManager prepareWithInvocationTarget:self] removeBlockAtIndexWithUndo:index];
    [self.undoManager setActionName:@"Add Block"];

    if (index <= self.allowedWindows.count) {
        [self.allowedWindows insertObject:block atIndex:index];
    } else {
        [self.allowedWindows addObject:block];
    }
    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (void)removeBlockAtIndexWithUndo:(NSUInteger)index {
    if (index >= self.allowedWindows.count) return;

    SCTimeRange *block = [self.allowedWindows[index] copy];
    [[self.undoManager prepareWithInvocationTarget:self] insertBlockWithUndo:block atIndex:index];
    [self.undoManager setActionName:@"Delete Block"];

    [self.allowedWindows removeObjectAtIndex:index];

    // Clear or adjust selection
    if (self.selectedBlockIndex == (NSInteger)index) {
        self.selectedBlockIndex = -1;
    } else if (self.selectedBlockIndex > (NSInteger)index) {
        self.selectedBlockIndex--;
    }

    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (void)updateBlockAtIndex:(NSUInteger)index toStart:(NSString *)start end:(NSString *)end {
    if (index >= self.allowedWindows.count) return;

    SCTimeRange *block = self.allowedWindows[index];
    NSString *oldStart = [block.startTime copy];
    NSString *oldEnd = [block.endTime copy];

    [[self.undoManager prepareWithInvocationTarget:self] updateBlockAtIndex:index toStart:oldStart end:oldEnd];
    [self.undoManager setActionName:@"Edit Block"];

    block.startTime = start;
    block.endTime = end;
    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (BOOL)isFlipped {
    return YES; // Origin at top (midnight)
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;

    // Background (blocked = dark gray)
    [[NSColor colorWithWhite:0.2 alpha:1.0] setFill];
    NSRectFill(bounds);

    // Hour lines and labels
    [self drawHourMarkers];

    // Draw allowed windows - sort by duration descending so smaller blocks are drawn on top
    NSArray *sortedIndices = [self windowIndicesSortedByDurationDescending];
    for (NSNumber *indexNum in sortedIndices) {
        NSUInteger i = [indexNum unsignedIntegerValue];
        SCTimeRange *window = self.allowedWindows[i];
        [self drawWindow:window atIndex:i];
    }

    // Draw "now" line
    [self drawNowLine];
}

- (void)drawNowLine {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
    NSInteger nowMinutes = comps.hour * 60 + comps.minute;

    CGFloat nowY = [self yFromMinutes:nowMinutes];

    // Draw dotted red line
    [[NSColor systemRedColor] setStroke];
    NSBezierPath *nowPath = [NSBezierPath bezierPath];
    CGFloat dashPattern[] = {4, 4};
    [nowPath setLineDash:dashPattern count:2 phase:0];
    [nowPath setLineWidth:2.0];
    [nowPath moveToPoint:NSMakePoint(40, nowY)];
    [nowPath lineToPoint:NSMakePoint(self.bounds.size.width, nowY)];
    [nowPath stroke];

    // Draw small "NOW" label
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor systemRedColor]
    };
    [@"NOW" drawAtPoint:NSMakePoint(2, nowY - 4) withAttributes:attrs];
}

- (void)drawHourMarkers {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };

    [[NSColor separatorColor] setStroke];
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path setLineWidth:0.5];

    for (NSInteger hour = 0; hour <= 24; hour++) {
        CGFloat y = [self yFromMinutes:hour * 60];

        // Line
        [path moveToPoint:NSMakePoint(40, y)];
        [path lineToPoint:NSMakePoint(self.bounds.size.width, y)];

        // Label
        NSString *label;
        if (hour == 0 || hour == 24) {
            label = @"12am";
        } else if (hour == 12) {
            label = @"12pm";
        } else if (hour < 12) {
            label = [NSString stringWithFormat:@"%ldam", (long)hour];
        } else {
            label = [NSString stringWithFormat:@"%ldpm", (long)(hour - 12)];
        }

        [label drawAtPoint:NSMakePoint(2, y - 6) withAttributes:attrs];
    }

    [path stroke];
}

- (void)drawWindow:(SCTimeRange *)window atIndex:(NSUInteger)index {
    CGFloat startY = [self yFromMinutes:[window startMinutes]];
    CGFloat endY = [self yFromMinutes:[window endMinutes]];
    CGFloat height = endY - startY;

    NSRect windowRect = NSMakeRect(47, startY, self.bounds.size.width - 53, height);

    BOOL isSelected = (self.selectedBlockIndex == (NSInteger)index);

    // Main fill - darker when selected
    NSColor *fillColor = isSelected
        ? [self.bundleColor colorWithAlphaComponent:0.9]
        : [self.bundleColor colorWithAlphaComponent:0.7];

    // Darken the color itself when selected
    if (isSelected) {
        fillColor = [[self.bundleColor blendedColorWithFraction:0.3 ofColor:[NSColor blackColor]] colorWithAlphaComponent:0.9];
    }

    [fillColor setFill];
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:windowRect xRadius:4 yRadius:4];
    [bgPath fill];

    // Border - thicker when selected
    [[self.bundleColor colorWithAlphaComponent:1.0] setStroke];
    [bgPath setLineWidth:isSelected ? 2.5 : 1.5];
    CGFloat dash[] = {5, 4};
    if (self.policy == SCBundlePolicyAllow) [bgPath setLineDash:dash count:2 phase:0];
    [bgPath stroke];

    // Time labels
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };

    NSString *timeLabel = [window displayString12Hour];
    NSSize labelSize = [timeLabel sizeWithAttributes:attrs];
    NSPoint labelPoint = NSMakePoint(windowRect.origin.x + (windowRect.size.width - labelSize.width) / 2,
                                      startY + height/2 - labelSize.height/2);
    [timeLabel drawAtPoint:labelPoint withAttributes:attrs];
}

#pragma mark - Coordinate Conversion

- (NSInteger)minutesFromY:(CGFloat)y {
    // Account for padding: usable area is between paddingTop and (height - paddingBottom)
    CGFloat usableHeight = self.bounds.size.height - kTimelinePaddingTop - kTimelinePaddingBottom;
    CGFloat adjustedY = y - kTimelinePaddingTop;
    CGFloat percent = adjustedY / usableHeight;
    return (NSInteger)(percent * 24 * 60);
}

- (CGFloat)yFromMinutes:(NSInteger)minutes {
    // Account for padding: map 0-1440 minutes to paddingTop..(height - paddingBottom)
    CGFloat usableHeight = self.bounds.size.height - kTimelinePaddingTop - kTimelinePaddingBottom;
    CGFloat percent = minutes / (24.0 * 60.0);
    return kTimelinePaddingTop + (percent * usableHeight);
}

- (NSInteger)snapToGrid:(NSInteger)minutes {
    return ((NSInteger)round(minutes / kSnapMinutes)) * (NSInteger)kSnapMinutes;
}

#pragma mark - Z-ordering helpers

/// Returns window indices sorted by duration descending (largest first, drawn first = behind)
- (NSArray<NSNumber *> *)windowIndicesSortedByDurationDescending {
    NSMutableArray *indices = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.allowedWindows.count; i++) {
        [indices addObject:@(i)];
    }
    [indices sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        SCTimeRange *rangeA = self.allowedWindows[[a unsignedIntegerValue]];
        SCTimeRange *rangeB = self.allowedWindows[[b unsignedIntegerValue]];
        // Descending by duration (larger blocks first = drawn behind)
        return [@([rangeB durationMinutes]) compare:@([rangeA durationMinutes])];
    }];
    return indices;
}

/// Returns window indices sorted by duration ascending (smallest first = checked first for clicks)
- (NSArray<NSNumber *> *)windowIndicesSortedByDurationAscending {
    NSMutableArray *indices = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.allowedWindows.count; i++) {
        [indices addObject:@(i)];
    }
    [indices sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        SCTimeRange *rangeA = self.allowedWindows[[a unsignedIntegerValue]];
        SCTimeRange *rangeB = self.allowedWindows[[b unsignedIntegerValue]];
        // Ascending by duration (smaller blocks first = topmost = checked first)
        return [@([rangeA durationMinutes]) compare:@([rangeB durationMinutes])];
    }];
    return indices;
}

/// Find window index at point, checking smaller (topmost) blocks first
- (NSInteger)windowIndexAtPoint:(NSPoint)point {
    NSArray *sortedIndices = [self windowIndicesSortedByDurationAscending];
    for (NSNumber *indexNum in sortedIndices) {
        NSInteger i = [indexNum integerValue];
        SCTimeRange *window = self.allowedWindows[i];
        CGFloat startY = [self yFromMinutes:[window startMinutes]];
        CGFloat endY = [self yFromMinutes:[window endMinutes]];
        NSRect windowRect = NSMakeRect(47, startY, self.bounds.size.width - 53, endY - startY);
        if (NSPointInRect(point, windowRect)) {
            return i;
        }
    }
    return -1;
}

#pragma mark - Mouse Handling

- (void)mouseDown:(NSEvent *)event {
    // Become first responder to receive undo/redo and key commands
    [self.window makeFirstResponder:self];

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

    // Find which window is clicked (uses z-order aware hit testing)
    NSInteger clickedIndex = [self windowIndexAtPoint:point];

    // Update selection
    if (clickedIndex != self.selectedBlockIndex) {
        self.selectedBlockIndex = clickedIndex;
        [self setNeedsDisplay:YES];
    }

    // Handle double-click
    if (event.clickCount == 2) {
        if (clickedIndex >= 0) {
            // Double-click on a block - trigger edit
            if (self.onRequestEditBlock) {
                self.onRequestEditBlock(clickedIndex);
            }
            return;
        } else if (!self.isCommitted) {
            // Double-click on empty space - show time picker
            NSInteger minutes = [self snapToGrid:[self minutesFromY:point.y]];
            if (self.onRequestTimeInput) {
                self.onRequestTimeInput(minutes);
            }
            return;
        }
    }

    // Check if clicking on existing window
    if (clickedIndex >= 0) {
        SCTimeRange *window = self.allowedWindows[clickedIndex];
        CGFloat startY = [self yFromMinutes:[window startMinutes]];
        CGFloat endY = [self yFromMinutes:[window endMinutes]];

        self.isDragging = YES;
        self.draggingWindowIndex = clickedIndex;
        self.originalDragRange = [window copy];
        self.dragStartY = point.y;
        self.dragStartMinutes = [self minutesFromY:point.y];

        // Check if near top edge (resize start)
        if (point.y - startY < kEdgeDetectionZone) {
            self.draggingStartEdge = YES;
            self.draggingEndEdge = NO;
            self.draggingWholeBlock = NO;
            return;
        }

        // Check if near bottom edge (resize end)
        if (endY - point.y < kEdgeDetectionZone) {
            self.draggingStartEdge = NO;
            self.draggingEndEdge = YES;
            self.draggingWholeBlock = NO;
            return;
        }

        // Middle of block - drag the whole block
        self.draggingStartEdge = NO;
        self.draggingEndEdge = NO;
        self.draggingWholeBlock = YES;
        return;
    }

    // Click on empty space - wait for drag before creating
    // (Don't create block yet - wait for drag threshold)
    if (!self.isCommitted) {
        self.hasPendingEmptyAreaClick = YES;
        self.mouseDownPoint = point;
        self.dragStartY = point.y;
        self.dragStartMinutes = [self snapToGrid:[self minutesFromY:point.y]];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if we should start drag-to-create from a pending empty area click
    if (self.hasPendingEmptyAreaClick && !self.isDragging) {
        CGFloat dy = point.y - self.mouseDownPoint.y;
        CGFloat distance = fabs(dy);

        if (distance >= kDragThreshold) {
            // Start creating new block via drag
            self.hasPendingEmptyAreaClick = NO;

            // Create the initial block
            NSInteger minutes = self.dragStartMinutes;
            SCTimeRange *newWindow = [SCTimeRange rangeWithStart:[self timeStringFromMinutes:minutes]
                                                             end:[self timeStringFromMinutes:minutes + 15]];
            [self.allowedWindows addObject:newWindow];

            self.isDragging = YES;
            self.isCreatingNewBlock = YES;
            self.draggingWindowIndex = self.allowedWindows.count - 1;
            self.draggingStartEdge = NO;
            self.draggingEndEdge = YES;  // Resize from end as user drags
            self.draggingWholeBlock = NO;

            [self setNeedsDisplay:YES];
            if (self.onWindowsChanged) self.onWindowsChanged();
        }
    }

    if (!self.isDragging || self.draggingWindowIndex < 0) return;
    NSInteger minutes = [self snapToGrid:[self minutesFromY:point.y]];
    minutes = MAX(0, MIN(24 * 60, minutes));

    SCTimeRange *window = self.allowedWindows[self.draggingWindowIndex];

    if (self.isCreatingNewBlock) {
        // ANCHOR PATTERN - use swap like SCCalendarGridView (lines 640-649)
        // Block creation when committed
        if (self.isCommitted) return;

        NSInteger anchor = self.dragStartMinutes;
        NSInteger current = minutes;

        // Swap if dragging backwards (upward)
        NSInteger start = MIN(anchor, current);
        NSInteger end   = MAX(anchor, current);

        // Enforce minimum 15-minute duration
        if (end - start < 15) {
            if (current < anchor) {
                start = end - 15;  // Dragging up - move start up
            } else {
                end = start + 15;  // Dragging down - move end down
            }
        }

        window.startTime = [self timeStringFromMinutes:start];
        window.endTime   = [self timeStringFromMinutes:end];
    } else if (self.draggingStartEdge) {
        // Block all resizing when committed
        if (self.isCommitted) return;

        // Moving start time (resize from top)
        NSInteger endMinutes = [window endMinutes];
        if (minutes < endMinutes - 15) {
            window.startTime = [self timeStringFromMinutes:minutes];
        }
    } else if (self.draggingEndEdge) {
        // Block all resizing when committed
        if (self.isCommitted) return;

        // Moving end time (resize from bottom)
        NSInteger startMinutes = [window startMinutes];
        if (minutes > startMinutes + 15) {
            window.endTime = [self timeStringFromMinutes:minutes];
        }
    } else if (self.draggingWholeBlock) {
        // Moving the whole block
        NSInteger deltaMinutes = minutes - [self snapToGrid:self.dragStartMinutes];
        NSInteger originalStart = [self.originalDragRange startMinutes];
        NSInteger originalEnd = [self.originalDragRange endMinutes];
        NSInteger duration = originalEnd - originalStart;

        NSInteger newStart = originalStart + deltaMinutes;
        NSInteger newEnd = originalEnd + deltaMinutes;

        // Clamp to day bounds
        if (newStart < 0) {
            newStart = 0;
            newEnd = duration;
        }
        if (newEnd > 24 * 60) {
            newEnd = 24 * 60;
            newStart = newEnd - duration;
        }

        // Check commitment constraint - can only move within original bounds
        if (self.isCommitted && self.originalDragRange) {
            // When committed, block can't be moved to allow more time
            // For simplicity, prevent all movement when committed
            return;
        }

        window.startTime = [self timeStringFromMinutes:newStart];
        window.endTime = [self timeStringFromMinutes:newEnd];
    }

    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();
}

- (void)mouseUp:(NSEvent *)event {
    // Reset pending empty area click state
    self.hasPendingEmptyAreaClick = NO;

    NSInteger draggedIndex = self.draggingWindowIndex;
    BOOL wasCreatingNew = self.isCreatingNewBlock;
    SCTimeRange *originalRange = self.originalDragRange;

    self.isDragging = NO;
    self.draggingWindowIndex = -1;
    self.draggingStartEdge = NO;
    self.draggingEndEdge = NO;
    self.draggingWholeBlock = NO;
    self.isCreatingNewBlock = NO;
    self.originalDragRange = nil;

    // Clean up any zero-duration windows
    NSMutableArray *toRemove = [NSMutableArray array];
    for (SCTimeRange *window in self.allowedWindows) {
        if ([window durationMinutes] < 15) {
            [toRemove addObject:window];
        }
    }
    [self.allowedWindows removeObjectsInArray:toRemove];

    // Register undo for successful operations
    if (wasCreatingNew && draggedIndex >= 0) {
        // Find the block we just created (if it survived cleanup)
        if (draggedIndex < (NSInteger)self.allowedWindows.count) {
            SCTimeRange *newBlock = self.allowedWindows[draggedIndex];
            if ([newBlock durationMinutes] >= 15) {
                // Register undo for the new block
                [[self.undoManager prepareWithInvocationTarget:self] removeBlockAtIndexWithUndo:draggedIndex];
                [self.undoManager setActionName:@"Add Block"];
            }
        }
    } else if (!wasCreatingNew && originalRange && draggedIndex >= 0 && draggedIndex < (NSInteger)self.allowedWindows.count) {
        // We were editing an existing block - register undo for the change
        SCTimeRange *currentBlock = self.allowedWindows[draggedIndex];
        if (![currentBlock.startTime isEqualToString:originalRange.startTime] ||
            ![currentBlock.endTime isEqualToString:originalRange.endTime]) {
            [[self.undoManager prepareWithInvocationTarget:self]
                updateBlockAtIndex:draggedIndex toStart:originalRange.startTime end:originalRange.endTime];
            [self.undoManager setActionName:@"Move Block"];
        }
    }

    [self setNeedsDisplay:YES];
    if (self.onWindowsChanged) self.onWindowsChanged();

    // Trigger live merge after drag completes
    if (self.onDragEnded) self.onDragEnded();
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }

    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                                options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow)
                                                                  owner:self
                                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if near any window edges
    for (SCTimeRange *window in self.allowedWindows) {
        CGFloat startY = [self yFromMinutes:[window startMinutes]];
        CGFloat endY = [self yFromMinutes:[window endMinutes]];

        NSRect windowRect = NSMakeRect(47, startY, self.bounds.size.width - 53, endY - startY);
        if (!NSPointInRect(point, windowRect)) continue;

        // Near top or bottom edge - resize cursor
        if (point.y - startY < kEdgeDetectionZone || endY - point.y < kEdgeDetectionZone) {
            [[NSCursor resizeUpDownCursor] set];
            return;
        }

        // Middle of block - open hand (move) cursor
        [[NSCursor openHandCursor] set];
        return;
    }

    // Not over any window - arrow cursor
    [[NSCursor arrowCursor] set];
}

- (NSString *)timeStringFromMinutes:(NSInteger)minutes {
    NSInteger hours = minutes / 60;
    NSInteger mins = minutes % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)hours, (long)mins];
}

#pragma mark - Right-click Context Menu

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger clickedIndex = [self windowIndexAtPoint:point];

    if (clickedIndex < 0) {
        [super rightMouseDown:event];
        return;
    }

    // Create context menu
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Block Actions"];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit..."
                                                      action:@selector(contextMenuEdit:)
                                               keyEquivalent:@""];
    editItem.target = self;
    editItem.tag = clickedIndex;
    [menu addItem:editItem];

    NSMenuItem *deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete"
                                                        action:@selector(contextMenuDelete:)
                                                 keyEquivalent:@""];
    deleteItem.target = self;
    deleteItem.tag = clickedIndex;
    [menu addItem:deleteItem];

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)contextMenuEdit:(NSMenuItem *)sender {
    if (self.onRequestEditBlock) {
        self.onRequestEditBlock(sender.tag);
    }
}

- (void)contextMenuDelete:(NSMenuItem *)sender {
    if (self.onRequestDeleteBlock) {
        self.onRequestDeleteBlock(sender.tag);
    }
}

@end

#pragma mark - SCDayScheduleEditorController

@interface SCDayScheduleEditorController ()

@property (nonatomic, strong) SCBlockBundle *bundle;
@property (nonatomic, assign) SCDayOfWeek day;
@property (nonatomic, strong) SCWeeklySchedule *schedule;
@property (nonatomic, strong) SCWeeklySchedule *workingSchedule;

// UI Elements
@property (nonatomic, strong) SCTimelineView *timelineView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSButton *deleteWindowButton;
@property (nonatomic, strong) NSButton *doneButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *addTimeBlockButton;
@property (nonatomic, strong) NSPopover *timeInputPopover;
@property (nonatomic, strong) NSPopover *editBlockPopover;
@property (nonatomic, strong) NSDatePicker *startTimePicker;
@property (nonatomic, strong) NSDatePicker *endTimePicker;
@property (nonatomic, assign) NSInteger editingBlockIndex;

// Event monitor for click-outside-to-close
@property (nonatomic, strong) id clickOutsideMonitor;

@end

@implementation SCDayScheduleEditorController

- (instancetype)initWithBundle:(SCBlockBundle *)bundle
                      schedule:(SCWeeklySchedule *)schedule
                           day:(SCDayOfWeek)day {
    // Create window programmatically - 800 height for larger timeline (33% larger than original)
    NSRect frame = NSMakeRect(0, 0, 400, 800);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Edit Day Schedule";

    self = [super initWithWindow:window];
    if (self) {
        _bundle = bundle;
        _day = day;
        _schedule = schedule;
        _workingSchedule = [schedule copy];
        _isCommitted = NO;
        _editingBlockIndex = -1;

        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;

    CGFloat y = contentView.bounds.size.height - 13;
    CGFloat padding = 16;

    // Title
    y -= 40;
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding, y, 267, 32)];
    self.titleLabel.stringValue = [NSString stringWithFormat:@"%@ - %@",
                                    self.bundle.name,
                                    [SCWeeklySchedule displayNameForDay:self.day]];
    self.titleLabel.font = [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];
    self.titleLabel.bezeled = NO;
    self.titleLabel.editable = NO;
    self.titleLabel.drawsBackground = NO;
    [contentView addSubview:self.titleLabel];

    // The coloured windows follow the bundle policy.
    NSTextField *legendLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(padding + 267, y + 6, 100, 20)];
    legendLabel.stringValue = self.bundle.policy == SCBundlePolicyBlock ? @"■ = Blocked" : @"■ = Allowed";
    legendLabel.toolTip = self.bundle.policy == SCBundlePolicyBlock
        ? @"These apps and websites are blocked inside the coloured windows."
        : @"These apps and websites are blocked outside the coloured windows.";
    legendLabel.accessibilityLabel = legendLabel.toolTip;
    legendLabel.font = [NSFont systemFontOfSize:13];
    legendLabel.textColor = self.bundle.color;
    legendLabel.bezeled = NO;
    legendLabel.editable = NO;
    legendLabel.drawsBackground = NO;
    [contentView addSubview:legendLabel];

    // Add time block button ("+") - use SF Symbol for cleaner appearance
    y -= 47;
    self.addTimeBlockButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding, y - 2, 45, 32)];
    if (@available(macOS 11.0, *)) {
        NSImage *plusImage = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add"];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightMedium];
        self.addTimeBlockButton.image = [plusImage imageWithSymbolConfiguration:config];
    } else {
        self.addTimeBlockButton.title = @"+";
        self.addTimeBlockButton.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    }
    self.addTimeBlockButton.bezelStyle = NSBezelStyleRounded;
    self.addTimeBlockButton.target = self;
    self.addTimeBlockButton.action = @selector(addTimeBlockClicked:);
    self.addTimeBlockButton.toolTip = @"Add time block with specific times";
    [contentView addSubview:self.addTimeBlockButton];

    // Timeline view - 533pt height for better visibility (33% larger)
    y -= 560;
    self.timelineView = [[SCTimelineView alloc] initWithFrame:NSMakeRect(padding, y, 368, 533)];
    self.timelineView.bundleColor = self.bundle.color;
    self.timelineView.policy = self.bundle.policy;
    self.timelineView.allowedWindows = [[self.workingSchedule allowedWindowsForDay:self.day] mutableCopy];
    self.timelineView.isCommitted = self.isCommitted;

    __weak typeof(self) weakSelf = self;
    self.timelineView.onWindowsChanged = ^{
        [weakSelf timelineWindowsChanged];
    };
    self.timelineView.onDragEnded = ^{
        // Live merge overlapping blocks (silent, like SCCalendarGridView)
        [weakSelf mergeOverlappingBlocks];
        [weakSelf timelineWindowsChanged];  // Update schedule with merged result
    };
    self.timelineView.onRequestTimeInput = ^(NSInteger suggestedMinutes) {
        [weakSelf showTimeInputPopoverAtMinutes:suggestedMinutes];
    };
    self.timelineView.onRequestEditBlock = ^(NSInteger blockIndex) {
        [weakSelf showEditPopoverForBlockAtIndex:blockIndex];
    };
    self.timelineView.onRequestDeleteBlock = ^(NSInteger blockIndex) {
        [weakSelf deleteBlockAtIndex:blockIndex];
    };

    self.timelineView.wantsLayer = YES;
    self.timelineView.layer.cornerRadius = 10;
    self.timelineView.layer.masksToBounds = YES;
    self.timelineView.layer.borderWidth = 1.0;
    self.timelineView.layer.borderColor = [[NSColor separatorColor] CGColor];
    [contentView addSubview:self.timelineView];

    // Buttons
    y -= 60;
    self.cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(padding, y, 106, 40)];
    self.cancelButton.title = @"Cancel";
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.target = self;
    self.cancelButton.action = @selector(cancelClicked:);
    [contentView addSubview:self.cancelButton];

    self.doneButton = [[NSButton alloc] initWithFrame:NSMakeRect(278, y, 106, 40)];
    self.doneButton.title = @"Done";
    self.doneButton.bezelStyle = NSBezelStyleRounded;
    self.doneButton.keyEquivalent = @"\r";
    self.doneButton.target = self;
    self.doneButton.action = @selector(doneClicked:);
    [contentView addSubview:self.doneButton];
}

- (void)timelineWindowsChanged {
    // Update working schedule with current windows
    [self.workingSchedule setAllowedWindows:self.timelineView.allowedWindows forDay:self.day];
}

#pragma mark - Actions

- (void)doneClicked:(id)sender {
    // Merge any overlapping blocks silently (live merge happens on drag, but also handle popover edits)
    if ([self hasOverlappingBlocks]) {
        [self mergeOverlappingBlocks];
    }

    // Save the current timeline state
    [self timelineWindowsChanged];

    [self.delegate dayScheduleEditor:self didSaveSchedule:self.workingSchedule forDay:self.day];
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
}

- (void)cancelClicked:(id)sender {
    [self.delegate dayScheduleEditorDidCancel:self];
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel];
}

#pragma mark - Time Input Popover

- (void)addTimeBlockClicked:(id)sender {
    if (self.isCommitted) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cannot Add Blocks";
        alert.informativeText = @"Your commitment is active. Use Edit Schedule to make changes that increase blocking.";
        [alert runModal];
        return;
    }
    // Show time picker with default times (next hour to +2 hours)
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:NSCalendarUnitHour fromDate:[NSDate date]];
    NSInteger nextHour = (comps.hour + 1) % 24;
    [self showTimeInputPopoverAtMinutes:nextHour * 60];
}

- (void)showTimeInputPopoverAtMinutes:(NSInteger)suggestedMinutes {
    if (self.timeInputPopover && self.timeInputPopover.isShown) {
        [self.timeInputPopover close];
        return;
    }

    // Create popover content view
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 140)];

    // Title label
    NSTextField *titleLabel = [NSTextField labelWithString:@"Add Time Block"];
    titleLabel.frame = NSMakeRect(10, 110, 180, 20);
    titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [contentView addSubview:titleLabel];

    // Start time label
    NSTextField *startLabel = [NSTextField labelWithString:@"Start:"];
    startLabel.frame = NSMakeRect(10, 80, 40, 20);
    startLabel.font = [NSFont systemFontOfSize:12];
    [contentView addSubview:startLabel];

    // Start time picker
    self.startTimePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(55, 78, 130, 24)];
    self.startTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.startTimePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    self.startTimePicker.dateValue = [self dateFromMinutes:suggestedMinutes];
    [contentView addSubview:self.startTimePicker];

    // End time label
    NSTextField *endLabel = [NSTextField labelWithString:@"End:"];
    endLabel.frame = NSMakeRect(10, 50, 40, 20);
    endLabel.font = [NSFont systemFontOfSize:12];
    [contentView addSubview:endLabel];

    // End time picker
    self.endTimePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(55, 48, 130, 24)];
    self.endTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.endTimePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    self.endTimePicker.dateValue = [self dateFromMinutes:MIN(suggestedMinutes + 120, 24 * 60)];
    [contentView addSubview:self.endTimePicker];

    // Create button
    NSButton *createButton = [[NSButton alloc] initWithFrame:NSMakeRect(55, 10, 90, 28)];
    createButton.title = @"Create";
    createButton.bezelStyle = NSBezelStyleRounded;
    createButton.target = self;
    createButton.action = @selector(createTimeBlockFromPopover:);
    [contentView addSubview:createButton];

    // Create and configure popover
    self.timeInputPopover = [[NSPopover alloc] init];
    self.timeInputPopover.contentSize = contentView.frame.size;
    self.timeInputPopover.behavior = NSPopoverBehaviorTransient;
    self.timeInputPopover.animates = YES;

    NSViewController *viewController = [[NSViewController alloc] init];
    viewController.view = contentView;
    self.timeInputPopover.contentViewController = viewController;

    // Show relative to add button
    [self.timeInputPopover showRelativeToRect:self.addTimeBlockButton.bounds
                                       ofView:self.addTimeBlockButton
                                preferredEdge:NSRectEdgeMaxY];
}

- (void)createTimeBlockFromPopover:(id)sender {
    NSInteger startMinutes = [self minutesFromDate:self.startTimePicker.dateValue];
    NSInteger endMinutes = [self minutesFromDate:self.endTimePicker.dateValue];

    // Treat 00:00 (midnight) end time as 24:00 (end of day) when start is non-zero
    if (endMinutes == 0 && startMinutes > 0) {
        endMinutes = 24 * 60;
    }

    // Validate
    if (endMinutes <= startMinutes) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Invalid Time Range";
        alert.informativeText = @"End time must be after start time.";
        [alert runModal];
        return;
    }

    if (endMinutes - startMinutes < 15) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Time Range Too Short";
        alert.informativeText = @"Time blocks must be at least 15 minutes.";
        [alert runModal];
        return;
    }

    // Create the time range with undo support
    NSString *startStr = [NSString stringWithFormat:@"%02ld:%02ld", (long)(startMinutes / 60), (long)(startMinutes % 60)];
    NSString *endStr = [NSString stringWithFormat:@"%02ld:%02ld", (long)(endMinutes / 60), (long)(endMinutes % 60)];
    SCTimeRange *newWindow = [SCTimeRange rangeWithStart:startStr end:endStr];

    [self.timelineView addBlockWithUndo:newWindow];

    [self.timeInputPopover close];
}

- (NSDate *)dateFromMinutes:(NSInteger)minutes {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.hour = minutes / 60;
    comps.minute = minutes % 60;
    return [calendar dateFromComponents:comps];
}

- (NSInteger)minutesFromDate:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return comps.hour * 60 + comps.minute;
}

#pragma mark - Overlap Detection and Merging

- (BOOL)hasOverlappingBlocks {
    NSArray<SCTimeRange *> *windows = self.timelineView.allowedWindows;
    for (NSUInteger i = 0; i < windows.count; i++) {
        for (NSUInteger j = i + 1; j < windows.count; j++) {
            if ([self range:windows[i] overlapsWithRange:windows[j]]) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL)range:(SCTimeRange *)a overlapsWithRange:(SCTimeRange *)b {
    NSInteger aStart = [a startMinutes];
    NSInteger aEnd = [a endMinutes];
    NSInteger bStart = [b startMinutes];
    NSInteger bEnd = [b endMinutes];
    // Overlaps if not disjoint (a ends before b starts or b ends before a starts)
    return !(aEnd <= bStart || bEnd <= aStart);
}

- (void)mergeOverlappingBlocks {
    NSMutableArray<SCTimeRange *> *windows = self.timelineView.allowedWindows;
    if (windows.count < 2) return;

    // Sort by start time
    [windows sortUsingComparator:^NSComparisonResult(SCTimeRange *a, SCTimeRange *b) {
        return [@([a startMinutes]) compare:@([b startMinutes])];
    }];

    NSMutableArray<SCTimeRange *> *merged = [NSMutableArray array];
    SCTimeRange *current = [windows[0] copy];

    for (NSUInteger i = 1; i < windows.count; i++) {
        SCTimeRange *next = windows[i];
        if ([next startMinutes] <= [current endMinutes]) {
            // Overlapping or adjacent - extend current
            if ([next endMinutes] > [current endMinutes]) {
                NSInteger endMins = [next endMinutes];
                current.endTime = [NSString stringWithFormat:@"%02ld:%02ld",
                                   (long)(endMins / 60), (long)(endMins % 60)];
            }
        } else {
            // No overlap - save current and start new
            [merged addObject:current];
            current = [next copy];
        }
    }
    [merged addObject:current];

    [self.timelineView.allowedWindows removeAllObjects];
    [self.timelineView.allowedWindows addObjectsFromArray:merged];
    [self.timelineView setNeedsDisplay:YES];
}

#pragma mark - Edit Block Popover

- (void)showEditPopoverForBlockAtIndex:(NSInteger)blockIndex {
    if (blockIndex < 0 || blockIndex >= (NSInteger)self.timelineView.allowedWindows.count) return;

    if (self.editBlockPopover && self.editBlockPopover.isShown) {
        [self.editBlockPopover close];
    }

    self.editingBlockIndex = blockIndex;
    SCTimeRange *block = self.timelineView.allowedWindows[blockIndex];

    // Create popover content view
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 140)];

    // Title label
    NSTextField *titleLabel = [NSTextField labelWithString:@"Edit Time Block"];
    titleLabel.frame = NSMakeRect(10, 110, 180, 20);
    titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [contentView addSubview:titleLabel];

    // Start time label
    NSTextField *startLabel = [NSTextField labelWithString:@"Start:"];
    startLabel.frame = NSMakeRect(10, 80, 40, 20);
    startLabel.font = [NSFont systemFontOfSize:12];
    [contentView addSubview:startLabel];

    // Start time picker
    self.startTimePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(55, 78, 130, 24)];
    self.startTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.startTimePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    self.startTimePicker.dateValue = [self dateFromMinutes:[block startMinutes]];
    [contentView addSubview:self.startTimePicker];

    // End time label
    NSTextField *endLabel = [NSTextField labelWithString:@"End:"];
    endLabel.frame = NSMakeRect(10, 50, 40, 20);
    endLabel.font = [NSFont systemFontOfSize:12];
    [contentView addSubview:endLabel];

    // End time picker
    self.endTimePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(55, 48, 130, 24)];
    self.endTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.endTimePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    self.endTimePicker.dateValue = [self dateFromMinutes:[block endMinutes]];
    [contentView addSubview:self.endTimePicker];

    // OK button
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(55, 10, 90, 28)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.target = self;
    okButton.action = @selector(updateBlockFromEditPopover:);
    okButton.keyEquivalent = @"\r";
    [contentView addSubview:okButton];

    // Create and configure popover
    self.editBlockPopover = [[NSPopover alloc] init];
    self.editBlockPopover.contentSize = contentView.frame.size;
    self.editBlockPopover.behavior = NSPopoverBehaviorTransient;
    self.editBlockPopover.animates = YES;

    NSViewController *viewController = [[NSViewController alloc] init];
    viewController.view = contentView;
    self.editBlockPopover.contentViewController = viewController;

    // Show relative to the block in timeline
    CGFloat startY = [self.timelineView yFromMinutes:[block startMinutes]];
    CGFloat endY = [self.timelineView yFromMinutes:[block endMinutes]];
    CGFloat midY = (startY + endY) / 2;
    NSRect blockRect = NSMakeRect(47, midY - 13, self.timelineView.bounds.size.width - 53, 26);

    [self.editBlockPopover showRelativeToRect:blockRect
                                       ofView:self.timelineView
                                preferredEdge:NSRectEdgeMaxX];
}

- (void)updateBlockFromEditPopover:(id)sender {
    if (self.editingBlockIndex < 0 || self.editingBlockIndex >= (NSInteger)self.timelineView.allowedWindows.count) {
        [self.editBlockPopover close];
        return;
    }

    // Block all edits when committed
    if (self.isCommitted) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Schedule Locked";
        alert.informativeText = @"You're committed to this week. The schedule cannot be modified.";
        [alert runModal];
        [self.editBlockPopover close];
        return;
    }

    NSInteger startMinutes = [self minutesFromDate:self.startTimePicker.dateValue];
    NSInteger endMinutes = [self minutesFromDate:self.endTimePicker.dateValue];

    // Treat 00:00 (midnight) end time as 24:00 (end of day) when start is non-zero
    if (endMinutes == 0 && startMinutes > 0) {
        endMinutes = 24 * 60;
    }

    // Validate
    if (endMinutes <= startMinutes) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Invalid Time Range";
        alert.informativeText = @"End time must be after start time.";
        [alert runModal];
        return;
    }

    if (endMinutes - startMinutes < 15) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Time Range Too Short";
        alert.informativeText = @"Time blocks must be at least 15 minutes.";
        [alert runModal];
        return;
    }

    // Update the block with undo support
    NSString *newStart = [NSString stringWithFormat:@"%02ld:%02ld", (long)(startMinutes / 60), (long)(startMinutes % 60)];
    NSString *newEnd = [NSString stringWithFormat:@"%02ld:%02ld", (long)(endMinutes / 60), (long)(endMinutes % 60)];
    [self.timelineView updateBlockAtIndex:self.editingBlockIndex toStart:newStart end:newEnd];

    [self.editBlockPopover close];
    self.editingBlockIndex = -1;
}

#pragma mark - Delete Block

- (void)deleteBlockAtIndex:(NSInteger)blockIndex {
    if (blockIndex < 0 || blockIndex >= (NSInteger)self.timelineView.allowedWindows.count) return;

    // Block all deletion when committed
    if (self.isCommitted) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Schedule Locked";
        alert.informativeText = @"You're committed to this week. Time blocks cannot be deleted.";
        [alert runModal];
        return;
    }

    // Use undo-aware deletion
    [self.timelineView removeBlockAtIndexWithUndo:blockIndex];
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

        // Don't close if click is in a popover (time input, edit block)
        if (strongSelf.timeInputPopover.isShown || strongSelf.editBlockPopover.isShown) {
            return event;
        }

        // Don't close if click is in an alert
        if ([eventWindow.className containsString:@"Alert"]) {
            return event;
        }

        // Click is in parent window (the background) - close editor
        if (eventWindow == strongSelf.window.sheetParent) {
            [strongSelf cancelClicked:nil];
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

#pragma mark - Sheet Presentation

- (void)beginSheetModalForWindow:(NSWindow *)parentWindow
               completionHandler:(void (^)(NSModalResponse))handler {
    [self setupClickOutsideMonitor];

    [parentWindow beginSheet:self.window completionHandler:^(NSModalResponse response) {
        [self removeClickOutsideMonitor];
        if (handler) {
            handler(response);
        }
    }];
}

@end

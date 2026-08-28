//
//  SCCountdownWarningController.m
//  SelfControl
//

#import "SCCountdownWarningController.h"
#import <QuartzCore/QuartzCore.h>

static const NSTimeInterval SCCountdownWarningDuration = 90.0;
static const CGFloat SCCountdownPillHeight = 52.0;
static const CGFloat SCCountdownPillMinimumWidth = 200.0;
static const CGFloat SCCountdownPillMaximumWidth = 520.0;
static const CGFloat SCCountdownPillMeasuredWidthPadding = 96.0;
static const CGFloat SCCountdownEntranceOffset = 12.0;
static const NSTimeInterval SCCountdownEntranceDuration = 0.30;

@interface SCCountdownRingView : NSView
@property (nonatomic, assign) CGFloat progress;
@end

@implementation SCCountdownRingView

- (BOOL)isFlipped {
    return YES;
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0.0, MIN(1.0, progress));
    self.accessibilityValue = @(_progress);
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    #pragma unused(dirtyRect)
    NSRect ringRect = NSInsetRect(self.bounds, 3.0, 3.0);
    NSPoint center = NSMakePoint(NSMidX(ringRect), NSMidY(ringRect));
    CGFloat radius = MIN(NSWidth(ringRect), NSHeight(ringRect)) / 2.0;

    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:ringRect];
    track.lineWidth = 3.0;
    [[[NSColor secondaryLabelColor] colorWithAlphaComponent:0.28] setStroke];
    [track stroke];

    if (self.progress <= 0.0) return;
    NSBezierPath *remaining = [NSBezierPath bezierPath];
    remaining.lineWidth = 3.0;
    remaining.lineCapStyle = NSLineCapStyleRound;
    [remaining appendBezierPathWithArcWithCenter:center
                                          radius:radius
                                      startAngle:90.0
                                        endAngle:90.0 - (360.0 * self.progress)
                                       clockwise:YES];
    [[NSColor systemRedColor] setStroke];
    [remaining stroke];
}

@end


@interface SCCountdownPillView : NSVisualEffectView

@property (nonatomic, strong) SCCountdownRingView *ringView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSButton *dismissButton;
@property (nonatomic, strong) NSView *attentionTintView;
@property (nonatomic, copy, nullable) void (^onDismiss)(void);

@end


@implementation SCCountdownPillView {
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.material = NSVisualEffectMaterialHUDWindow;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.state = NSVisualEffectStateActive;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor separatorColor].CGColor;

        _attentionTintView = [[NSView alloc] initWithFrame:NSZeroRect];
        _attentionTintView.wantsLayer = YES;
        _attentionTintView.layer.cornerRadius = 18.0;
        _attentionTintView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
        _attentionTintView.layer.opacity = 0.0;
        [self addSubview:_attentionTintView];

        _ringView = [[SCCountdownRingView alloc] initWithFrame:NSZeroRect];
        _ringView.wantsLayer = YES;
        _ringView.accessibilityElement = YES;
        _ringView.accessibilityRole = NSAccessibilityProgressIndicatorRole;
        _ringView.accessibilityLabel = @"Time remaining";
        _ringView.accessibilityMinValue = @0.0;
        _ringView.accessibilityMaxValue = @1.0;
        [self addSubview:_ringView];

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
        _titleLabel.textColor = NSColor.labelColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.maximumNumberOfLines = 1;
        [self addSubview:_titleLabel];

        _dismissButton = [NSButton buttonWithTitle:@"×" target:self action:@selector(dismissClicked:)];
        _dismissButton.bordered = NO;
        _dismissButton.font = [NSFont systemFontOfSize:17.0 weight:NSFontWeightMedium];
        _dismissButton.contentTintColor = NSColor.secondaryLabelColor;
        _dismissButton.toolTip = @"Dismiss warning";
        _dismissButton.accessibilityLabel = @"Dismiss warning";
        _dismissButton.hidden = YES;
        [self addSubview:_dismissButton];

        self.toolTip = @"Fence countdown warning";
    }
    return self;
}

- (void)layout {
    [super layout];
    self.attentionTintView.frame = self.bounds;
    self.ringView.frame = NSMakeRect(14.0, 13.0, 26.0, 26.0);
    self.dismissButton.frame = NSMakeRect(NSWidth(self.bounds) - 46.0, 6.0, 40.0, 40.0);
    self.titleLabel.frame = NSMakeRect(50.0, 16.0, NSWidth(self.bounds) - 96.0, 20.0);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea != nil) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited |
                      NSTrackingActiveAlways |
                      NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    #pragma unused(event)
    self.dismissButton.hidden = NO;
}

- (void)mouseExited:(NSEvent *)event {
    #pragma unused(event)
    self.dismissButton.hidden = YES;
}

- (void)dismissClicked:(id)sender {
    #pragma unused(sender)
    if (self.onDismiss != nil) self.onDismiss();
}

- (void)animateStrongAttentionRespectingReduceMotion:(BOOL)reduceMotion {
    [self.ringView.layer removeAnimationForKey:@"attentionPulse"];
    [self.attentionTintView.layer removeAnimationForKey:@"attentionFlash"];
    [self.layer removeAnimationForKey:@"attentionBorder"];
    self.attentionTintView.layer.opacity = 0.0;

    if (!reduceMotion) {
        CAKeyframeAnimation *ringPulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        ringPulse.values = @[@1.0, @1.22, @1.0, @1.22, @1.0];
        ringPulse.keyTimes = @[@0.0, @0.21, @0.42, @0.69, @1.0];
        ringPulse.duration = 0.96;
        ringPulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.ringView.layer addAnimation:ringPulse forKey:@"attentionPulse"];
    }

    CAKeyframeAnimation *flash = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    if (reduceMotion) {
        flash.values = @[@0.0, @0.16, @0.0];
        flash.keyTimes = @[@0.0, @0.45, @1.0];
        flash.duration = 0.45;
    } else {
        flash.values = @[@0.0, @0.18, @0.0, @0.18, @0.0];
        flash.keyTimes = @[@0.0, @0.18, @0.42, @0.66, @1.0];
        flash.duration = 1.05;
    }
    flash.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.attentionTintView.layer addAnimation:flash forKey:@"attentionFlash"];

    if (!reduceMotion) {
        CAKeyframeAnimation *border = [CAKeyframeAnimation animationWithKeyPath:@"borderColor"];
        border.values = @[(id)[NSColor separatorColor].CGColor,
                          (id)[[NSColor systemRedColor] colorWithAlphaComponent:0.9].CGColor,
                          (id)[NSColor separatorColor].CGColor];
        border.keyTimes = @[@0.0, @0.35, @1.0];
        border.duration = 0.80;
        [self.layer addAnimation:border forKey:@"attentionBorder"];
    }
}

@end


@interface SCCountdownWarningController ()

@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SCCountdownPillView *pillView;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, copy, nullable) NSString *eventIdentifier;
@property (nonatomic, copy, nullable) NSString *lastAnnouncedEventIdentifier;
@property (nonatomic, strong, nullable) NSDate *targetDate;
@property (nonatomic, strong, nullable) NSScreen *preferredScreen;

- (BOOL)consumeAttentionForEventIdentifier:(NSString *)eventIdentifier;

@end


@implementation SCCountdownWarningController

- (instancetype)init {
    self = [super init];
    if (self) [self buildPanel];
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
}

- (void)buildPanel {
    NSWindowStyleMask style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0,
                                                                 SCCountdownPillMinimumWidth,
                                                                 SCCountdownPillHeight)
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.level = NSStatusWindowLevel;
    self.panel.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary);
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;

    self.pillView = [[SCCountdownPillView alloc]
        initWithFrame:NSMakeRect(0, 0, SCCountdownPillMinimumWidth, SCCountdownPillHeight)];
    __weak typeof(self) weakSelf = self;
    self.pillView.onDismiss = ^{
        [weakSelf dismissClicked];
    };
    self.panel.contentView = self.pillView;
}

- (void)showWarningWithTitle:(NSString *)title
                  targetDate:(NSDate *)targetDate
             eventIdentifier:(NSString *)eventIdentifier
                      screen:(NSScreen *)screen {
    if (title.length == 0 || targetDate == nil || eventIdentifier.length == 0) {
        [self hideWarning];
        return;
    }
    if ([targetDate timeIntervalSinceNow] <= 0.0) {
        [self hideWarning];
        return;
    }

    NSString *expectedEventIdentifier = [eventIdentifier copy];
    self.eventIdentifier = expectedEventIdentifier;
    self.targetDate = targetDate;
    self.preferredScreen = screen;
    self.pillView.titleLabel.stringValue = title;
    self.panel.accessibilityLabel = title;

    NSDictionary *attributes = @{NSFontAttributeName: self.pillView.titleLabel.font};
    CGFloat measuredWidth = ceil([title sizeWithAttributes:attributes].width);
    CGFloat panelWidth = MAX(SCCountdownPillMinimumWidth,
                             MIN(SCCountdownPillMaximumWidth,
                                 measuredWidth + SCCountdownPillMeasuredWidthPadding));
    [self.panel setContentSize:NSMakeSize(panelWidth, SCCountdownPillHeight)];
    self.pillView.frame = NSMakeRect(0, 0, panelWidth, SCCountdownPillHeight);
    [self positionPanel];

    [self updateCountdown:nil];
    if (![self.eventIdentifier isEqualToString:expectedEventIdentifier]) return;
    BOOL isNewEvent = [self consumeAttentionForEventIdentifier:expectedEventIdentifier];
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (!self.panel.isVisible) {
        if (isNewEvent && !reduceMotion) {
            NSPoint finalOrigin = self.panel.frame.origin;
            [self.panel setFrameOrigin:NSMakePoint(finalOrigin.x,
                                                   finalOrigin.y + SCCountdownEntranceOffset)];
            self.panel.alphaValue = 0.0;
            [self.panel orderFrontRegardless];

            CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            scale.fromValue = @0.96;
            scale.toValue = @1.0;
            scale.duration = SCCountdownEntranceDuration;
            scale.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.0 :0.0 :1.0];
            [self.pillView.layer addAnimation:scale forKey:@"entranceScale"];

            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = SCCountdownEntranceDuration;
                context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.0 :0.0 :1.0];
                self.panel.animator.alphaValue = 1.0;
                [self.panel.animator setFrameOrigin:finalOrigin];
            } completionHandler:nil];
        } else {
            self.panel.alphaValue = reduceMotion ? 1.0 : 0.0;
            [self.panel orderFrontRegardless];
            if (!reduceMotion) {
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.16;
                    self.panel.animator.alphaValue = 1.0;
                } completionHandler:nil];
            }
        }
    }
    if (isNewEvent) {
        [self.pillView animateStrongAttentionRespectingReduceMotion:reduceMotion];
        [[NSSound soundNamed:@"Ping"] play];
        NSAccessibilityPostNotificationWithUserInfo(
            NSApp,
            NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey: title,
              NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)});
    }

    if (self.timer == nil) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateCountdown:)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}

- (BOOL)consumeAttentionForEventIdentifier:(NSString *)eventIdentifier {
    if (eventIdentifier.length == 0 ||
        [self.lastAnnouncedEventIdentifier isEqualToString:eventIdentifier]) {
        return NO;
    }
    self.lastAnnouncedEventIdentifier = [eventIdentifier copy];
    return YES;
}

- (void)positionPanel {
    NSScreen *screen = self.preferredScreen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (screen == nil) return;
    NSRect visibleFrame = screen.visibleFrame;
    NSRect screenFrame = screen.frame;
    NSRect frame = self.panel.frame;
    CGFloat safeTop = NSMaxY(screenFrame) - screen.safeAreaInsets.top;
    CGFloat usableTop = MIN(NSMaxY(visibleFrame), safeTop);
    frame.origin.x = round(NSMidX(screenFrame) - NSWidth(frame) / 2.0);
    frame.origin.y = round(usableTop - NSHeight(frame) - SCCountdownEntranceOffset);
    [self.panel setFrame:frame display:NO];
}

- (void)updateCountdown:(NSTimer *)timer {
    #pragma unused(timer)
    if (self.targetDate == nil) return;
    NSTimeInterval remaining = [self.targetDate timeIntervalSinceNow];
    if (remaining <= 0.0) {
        [self hideWarning];
        if (self.onExpire != nil) self.onExpire();
        return;
    }
    self.pillView.ringView.progress = remaining / SCCountdownWarningDuration;
}

- (void)dismissClicked {
    NSString *dismissedIdentifier = self.eventIdentifier;
    [self hideWarning];
    if (dismissedIdentifier.length > 0 && self.onDismiss != nil) {
        self.onDismiss(dismissedIdentifier);
    }
}

- (void)hideWarning {
    [self.timer invalidate];
    self.timer = nil;
    self.targetDate = nil;
    self.eventIdentifier = nil;
    self.pillView.dismissButton.hidden = YES;
    [self.pillView.ringView.layer removeAnimationForKey:@"attentionPulse"];
    [self.pillView.attentionTintView.layer removeAnimationForKey:@"attentionFlash"];
    [self.pillView.layer removeAnimationForKey:@"attentionBorder"];
    [self.pillView.layer removeAnimationForKey:@"entranceScale"];
    [self.panel orderOut:nil];
}

@end

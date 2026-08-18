//
//  PreferencesProtectionViewController.m
//  SelfControl
//

#import "PreferencesProtectionViewController.h"

#import "Block Management/SCProtectionPolicy.h"
#import "Block Management/SCScheduleManager.h"

@interface PreferencesProtectionViewController ()

@property (nonatomic, strong) NSTextField *creditsField;
@property (nonatomic, strong) NSStepper *creditsStepper;
@property (nonatomic, strong) NSTextField *remainingCreditsLabel;
@property (nonatomic, strong) NSTextField *creditConstraintLabel;
@property (nonatomic, strong) NSButton *protectedHoursToggle;
@property (nonatomic, strong) NSDatePicker *protectedStartPicker;
@property (nonatomic, strong) NSDatePicker *protectedEndPicker;
@property (nonatomic, strong) NSTextField *protectedHoursStatusLabel;
@property (nonatomic, assign) BOOL protectedHoursUpdateInFlight;
@property (nonatomic, assign) BOOL protectedHoursConfirmationInFlight;
@property (nonatomic, strong, nullable) NSTimer *stateRefreshTimer;

@end

@implementation PreferencesProtectionViewController

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (void)loadView {
    NSView *rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 420)];

    NSTextField *titleLabel = [NSTextField labelWithString:@"Protection"];
    titleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];

    NSTextField *summaryLabel = [NSTextField wrappingLabelWithString:
        @"Choose how much flexibility a committed recurring schedule allows."];
    summaryLabel.textColor = NSColor.secondaryLabelColor;
    summaryLabel.font = [NSFont systemFontOfSize:12];

    NSBox *creditsBox = [self breakCreditsBox];
    NSBox *protectedHoursBox = [self protectedHoursBox];

    NSStackView *mainStack = [NSStackView stackViewWithViews:@[
        titleLabel, summaryLabel, creditsBox, protectedHoursBox
    ]];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.alignment = NSLayoutAttributeLeading;
    mainStack.spacing = 12;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [rootView addSubview:mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [mainStack.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor constant:24],
        [mainStack.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor constant:-24],
        [mainStack.topAnchor constraintEqualToAnchor:rootView.topAnchor constant:22],
        [creditsBox.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [creditsBox.heightAnchor constraintEqualToConstant:118],
        [protectedHoursBox.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [protectedHoursBox.heightAnchor constraintEqualToConstant:188],
    ]];

    self.view = rootView;
}

- (NSBox *)breakCreditsBox {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.title = @"Break Credits";
    box.boxType = NSBoxPrimary;

    NSTextField *allowanceLabel = [NSTextField labelWithString:@"Daily allowance:"];
    allowanceLabel.font = [NSFont systemFontOfSize:13];

    self.creditsField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.creditsField.alignment = NSTextAlignmentRight;
    self.creditsField.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.creditsField.target = self;
    self.creditsField.action = @selector(breakAllowanceChanged:);
    self.creditsField.cell.sendsActionOnEndEditing = YES;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.allowsFloats = NO;
    formatter.minimum = @0;
    formatter.maximum = @10;
    self.creditsField.formatter = formatter;

    self.creditsStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    self.creditsStepper.minValue = 0;
    self.creditsStepper.maxValue = 10;
    self.creditsStepper.increment = 1;
    self.creditsStepper.valueWraps = NO;
    self.creditsStepper.autorepeat = YES;
    self.creditsStepper.target = self;
    self.creditsStepper.action = @selector(breakAllowanceChanged:);

    NSStackView *allowanceRow = [NSStackView stackViewWithViews:@[
        allowanceLabel, self.creditsField, self.creditsStepper
    ]];
    allowanceRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    allowanceRow.alignment = NSLayoutAttributeCenterY;
    allowanceRow.spacing = 8;
    [self.creditsField.widthAnchor constraintEqualToConstant:52].active = YES;

    self.remainingCreditsLabel = [NSTextField labelWithString:@""];
    self.remainingCreditsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12
                                                                    weight:NSFontWeightMedium];

    self.creditConstraintLabel = [NSTextField wrappingLabelWithString:@""];
    self.creditConstraintLabel.font = [NSFont systemFontOfSize:11];
    self.creditConstraintLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *content = [NSStackView stackViewWithViews:@[
        allowanceRow, self.remainingCreditsLabel, self.creditConstraintLabel
    ]];
    [self installContentStack:content inBox:box];
    return box;
}

- (NSBox *)protectedHoursBox {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.title = @"Protected Hours";
    box.boxType = NSBoxPrimary;

    self.protectedHoursToggle = [NSButton checkboxWithTitle:
        @"Prevent breaks and ordinary commitment ending during these hours"
                                                      target:self
                                                      action:@selector(protectedHoursChanged:)];

    NSTextField *startLabel = [NSTextField labelWithString:@"Start:"];
    NSTextField *endLabel = [NSTextField labelWithString:@"End:"];
    self.protectedStartPicker = [self timePicker];
    self.protectedEndPicker = [self timePicker];

    NSStackView *timeRow = [NSStackView stackViewWithViews:@[
        startLabel, self.protectedStartPicker, endLabel, self.protectedEndPicker
    ]];
    timeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    timeRow.alignment = NSLayoutAttributeCenterY;
    timeRow.spacing = 8;
    [self.protectedStartPicker.widthAnchor constraintEqualToConstant:116].active = YES;
    [self.protectedEndPicker.widthAnchor constraintEqualToConstant:116].active = YES;

    self.protectedHoursStatusLabel = [NSTextField wrappingLabelWithString:@""];
    self.protectedHoursStatusLabel.font = [NSFont systemFontOfSize:11];
    self.protectedHoursStatusLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *content = [NSStackView stackViewWithViews:@[
        self.protectedHoursToggle, timeRow, self.protectedHoursStatusLabel
    ]];
    [self installContentStack:content inBox:box];
    return box;
}

- (NSDatePicker *)timePicker {
    NSDatePicker *picker = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
    picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    picker.datePickerMode = NSDatePickerModeSingle;
    picker.datePickerElements = NSDatePickerElementFlagHourMinute;
    picker.target = self;
    picker.action = @selector(protectedHoursChanged:);
    return picker;
}

- (void)installContentStack:(NSStackView *)stack inBox:(NSBox *)box {
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:10],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:box.contentView.bottomAnchor constant:-10],
    ]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scheduleManagerDidChange:)
                                                 name:SCScheduleManagerDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(calendarDayDidChange:)
                                                 name:NSCalendarDayChangedNotification
                                               object:nil];
    [self refreshFromManager];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    [manager reconcileBreakCreditsForDate:[NSDate date] forceReset:NO];
    [self refreshFromManager];
    [self.stateRefreshTimer invalidate];
    self.stateRefreshTimer = [NSTimer timerWithTimeInterval:15.0
                                                    target:self
                                                  selector:@selector(stateRefreshTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.stateRefreshTimer forMode:NSRunLoopCommonModes];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.stateRefreshTimer invalidate];
    self.stateRefreshTimer = nil;
}

- (void)dealloc {
    [self.stateRefreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)stateRefreshTimerFired:(NSTimer *)timer {
    #pragma unused(timer)
    [self refreshFromManager];
}

- (void)scheduleManagerDidChange:(NSNotification *)notification {
    #pragma unused(notification)
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromManager]; });
        return;
    }
    [self refreshFromManager];
}

- (void)calendarDayDidChange:(NSNotification *)notification {
    #pragma unused(notification)
    dispatch_async(dispatch_get_main_queue(), ^{
        SCScheduleManager *manager = [SCScheduleManager sharedManager];
        [manager reconcileBreakCreditsForDate:[NSDate date] forceReset:NO];
        [self refreshFromManager];
    });
}

- (void)refreshFromManager {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    NSInteger allowance = manager.breakCreditsPerDay;
    BOOL commitmentSurvives = manager.hasRecurringCommitment;
    self.creditsField.integerValue = allowance;
    self.creditsStepper.integerValue = allowance;
    self.creditsStepper.maxValue = commitmentSurvives ? allowance : 10;
    NSNumberFormatter *formatter = (NSNumberFormatter *)self.creditsField.formatter;
    formatter.maximum = @(commitmentSurvives ? allowance : 10);
    self.remainingCreditsLabel.stringValue = [NSString stringWithFormat:
        @"%ld of %ld remaining today", (long)manager.breakCreditsRemainingToday, (long)allowance];
    self.creditConstraintLabel.stringValue = commitmentSurvives
        ? @"You can lower this allowance now; increases require ending the commitment."
        : @"Credits refill at local midnight and when a new commitment starts.";

    self.protectedHoursToggle.state = manager.protectedHoursEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.protectedStartPicker.dateValue = [self dateForMinuteOfDay:manager.protectedHoursStartMinute];
    self.protectedEndPicker.dateValue = [self dateForMinuteOfDay:manager.protectedHoursEndMinute];

    BOOL canEdit = manager.canEditProtectedHours &&
        !self.protectedHoursUpdateInFlight && !self.protectedHoursConfirmationInFlight;
    self.protectedHoursToggle.enabled = canEdit;
    // Times stay configurable while the feature is off, so enabling it never
    // traps the user in an unreviewed default range.
    BOOL canEditTimes = canEdit;
    self.protectedStartPicker.enabled = canEditTimes;
    self.protectedEndPicker.enabled = canEditTimes;
    if (self.protectedHoursConfirmationInFlight) {
        self.protectedHoursStatusLabel.stringValue = @"Confirm before saving…";
    } else if (self.protectedHoursUpdateInFlight) {
        self.protectedHoursStatusLabel.stringValue = @"Updating…";
    } else if (!manager.canEditProtectedHours) {
        SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(
            manager.protectedHoursStartMinute, manager.protectedHoursEndMinute);
        NSInteger protectedDuration = range.startMinute < range.endMinute
            ? range.endMinute - range.startMinute
            : SCProtectedHoursMinutesPerDay - range.startMinute + range.endMinute;
        BOOL lockedContinuously = protectedDuration + SCProtectedHoursEditLockLeadMinutes >=
            SCProtectedHoursMinutesPerDay;
        self.protectedHoursStatusLabel.stringValue = lockedContinuously
            ? @"Locked until the current commitment ends."
            : @"Locked from two hours before Protected Hours until they end.";
    } else if (manager.protectedHoursActiveNow) {
        self.protectedHoursStatusLabel.stringValue = @"Active now.";
    } else if (manager.protectedHoursEnabled) {
        self.protectedHoursStatusLabel.stringValue = @"Uses your current local time zone.";
    } else {
        self.protectedHoursStatusLabel.stringValue = @"Off";
    }
}

- (void)breakAllowanceChanged:(id)sender {
    NSInteger requested = [sender integerValue];
    [[SCScheduleManager sharedManager] setBreakCreditsPerDay:requested];
    [self refreshFromManager];
}

- (void)protectedHoursChanged:(id)sender {
    #pragma unused(sender)
    if (self.protectedHoursUpdateInFlight || self.protectedHoursConfirmationInFlight) return;
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    if (!manager.canEditProtectedHours) {
        [self refreshFromManager];
        return;
    }

    BOOL enabled = self.protectedHoursToggle.state == NSControlStateValueOn;
    NSInteger startMinute = [self minuteOfDayForDate:self.protectedStartPicker.dateValue];
    NSInteger endMinute = [self minuteOfDayForDate:self.protectedEndPicker.dateValue];
    SCProtectedHoursRange range = SCNormalizeProtectedHoursRange(startMinute, endMinute);
    BOOL wouldImmediatelyLock = enabled && manager.hasRecurringCommitment &&
        SCProtectedHoursEditLockIsActive(YES, range, [NSDate date], [NSCalendar currentCalendar]);
    if (wouldImmediatelyLock) {
        [self presentImmediateProtectedHoursLockWarningForStartMinute:range.startMinute
                                                           endMinute:range.endMinute];
        return;
    }
    [self performProtectedHoursUpdateEnabled:enabled
                                 startMinute:range.startMinute
                                   endMinute:range.endMinute];
}

- (void)performProtectedHoursUpdateEnabled:(BOOL)enabled
                                startMinute:(NSInteger)startMinute
                                  endMinute:(NSInteger)endMinute {
    SCScheduleManager *manager = [SCScheduleManager sharedManager];
    self.protectedHoursUpdateInFlight = YES;
    self.protectedHoursToggle.enabled = NO;
    self.protectedStartPicker.enabled = NO;
    self.protectedEndPicker.enabled = NO;
    self.protectedHoursStatusLabel.stringValue = @"Updating…";

    __weak typeof(self) weakSelf = self;
    [manager updateProtectedHoursEnabled:enabled
                             startMinute:startMinute
                               endMinute:endMinute
                              completion:^(BOOL updated, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.protectedHoursUpdateInFlight = NO;
            [strongSelf refreshFromManager];
            if (!updated) [strongSelf presentProtectedHoursError:error];
        });
    }];
}

- (void)presentImmediateProtectedHoursLockWarningForStartMinute:(NSInteger)startMinute
                                                       endMinute:(NSInteger)endMinute {
    self.protectedHoursConfirmationInFlight = YES;
    [self refreshFromManager];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.dateStyle = NSDateFormatterNoStyle;
    NSString *endText = [formatter stringFromDate:[self dateForMinuteOfDay:endMinute]];
    NSInteger protectedDuration = startMinute < endMinute
        ? endMinute - startMinute
        : SCProtectedHoursMinutesPerDay - startMinute + endMinute;
    BOOL locksForEntireDay = protectedDuration + SCProtectedHoursEditLockLeadMinutes >=
        SCProtectedHoursMinutesPerDay;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Protected Hours will lock";
    alert.informativeText = locksForEntireDay
        ? @"Saving this range will prevent further Protected Hours changes until you end the current commitment."
        : [NSString stringWithFormat:
            @"Saving this range will prevent further Protected Hours changes until %@.", endText];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Save"];

    __weak typeof(self) weakSelf = self;
    void (^handleResponse)(NSModalResponse) = ^(NSModalResponse response) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.protectedHoursConfirmationInFlight = NO;
        if (response == NSAlertSecondButtonReturn) {
            [strongSelf performProtectedHoursUpdateEnabled:YES
                                               startMinute:startMinute
                                                 endMinute:endMinute];
        } else {
            [strongSelf refreshFromManager];
        }
    };
    if (self.view.window != nil) {
        [alert beginSheetModalForWindow:self.view.window completionHandler:handleResponse];
    } else {
        handleResponse([alert runModal]);
    }
}

- (NSInteger)minuteOfDayForDate:(NSDate *)date {
    NSDateComponents *components = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return components.hour * 60 + components.minute;
}

- (NSDate *)dateForMinuteOfDay:(NSInteger)minute {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *startOfDay = [calendar startOfDayForDate:[NSDate date]];
    return [calendar dateByAddingUnit:NSCalendarUnitMinute value:minute
                               toDate:startOfDay options:0] ?: startOfDay;
}

- (void)presentProtectedHoursError:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Couldn’t update Protected Hours";
    alert.informativeText = error.localizedDescription.length > 0
        ? error.localizedDescription : @"Please try again.";
    if (self.view.window != nil) {
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

#pragma mark - MASPreferencesViewController

- (NSString *)identifier {
    return @"ProtectionPreferences";
}

- (NSImage *)toolbarItemImage {
    return [NSImage imageWithSystemSymbolName:@"shield.lefthalf.filled"
                     accessibilityDescription:@"Protection"] ?: [NSImage imageNamed:NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel {
    return @"Protection";
}

- (NSView *)initialKeyView {
    return self.creditsField;
}

- (BOOL)hasResizableWidth {
    return NO;
}

- (BOOL)hasResizableHeight {
    return NO;
}

@end

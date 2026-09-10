//
//  SCCalendarGridView.h
//  SelfControl
//
//  7-day calendar view showing allow blocks as events.
//  Supports Focus/All-Up states for bundle editing.
//

#import <Cocoa/Cocoa.h>
#import "Block Management/SCWeeklySchedule.h"

@class SCBlockBundle;
@class SCCalendarGridView;

NS_ASSUME_NONNULL_BEGIN

@protocol SCCalendarGridViewDelegate <NSObject>

/// Called when user creates/modifies/deletes an allow block
- (void)calendarGrid:(SCCalendarGridView *)grid
    didUpdateSchedule:(SCWeeklySchedule *)schedule
          forBundleID:(NSString *)bundleID;

/// Called when user clicks an empty area (clears bundle focus)
- (void)calendarGridDidClickEmptyArea:(SCCalendarGridView *)grid;

/// Called when user double-clicks a block (for detailed editing)
- (void)calendarGrid:(SCCalendarGridView *)grid
didRequestEditBundle:(SCBlockBundle *)bundle
              forDay:(SCDayOfWeek)day;

@optional

/// Called when user tries to interact with empty area without a bundle selected
/// Use this to show a "select a bundle first" warning
- (void)calendarGridDidAttemptInteractionWithoutFocus:(SCCalendarGridView *)grid;

/// Active editing attempted creation, panning, paste, or another restricted
/// action. Resize-edge clamping stays silent; this is for explicit actions.
- (void)calendarGridDidAttemptRestrictedEdit:(SCCalendarGridView *)grid;

@end

@interface SCCalendarGridView : NSView

/// Delegate for handling events
@property (nonatomic, weak, nullable) id<SCCalendarGridViewDelegate> delegate;

/// Array of bundles to display
@property (nonatomic, copy) NSArray<SCBlockBundle *> *bundles;

/// Dictionary mapping bundleID → SCWeeklySchedule
@property (nonatomic, copy) NSDictionary<NSString *, SCWeeklySchedule *> *schedules;

/// Currently focused bundle ID (nil = All-Up state, all bundles at 100%)
@property (nonatomic, copy, nullable) NSString *focusedBundleID;

/// Whether editing is locked (committed state)
@property (nonatomic, assign) BOOL isCommitted;

/// Non-nil enables a draft-only, stricter Allow editor while committed. The
/// setter deep-copies this immutable opening snapshot. Nil restores the normal
/// committed read-only grid. Reset by assigning copies of this baseline to
/// schedules and reloading; accepting an edit must happen outside the grid.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, SCWeeklySchedule *> *activeEditBaselineSchedules;

/// Root-owned timezone while committed. Nil keeps draft display on the live
/// system timezone.
@property (nonatomic, strong, nullable) NSTimeZone *displayTimeZone;

/// Week offset: 0 = current week, 1 = next week
@property (nonatomic, assign) NSInteger weekOffset;

/// Show only remaining days in current week (for weekOffset 0)
@property (nonatomic, assign) BOOL showOnlyRemainingDays;

/// Reload all data
- (void)reloadData;

/// Get schedule for a bundle
- (nullable SCWeeklySchedule *)scheduleForBundleID:(NSString *)bundleID;

/// Get the bundle object for a bundleID
- (nullable SCBlockBundle *)bundleForID:(NSString *)bundleID;

/// Undo manager for undo/redo support
@property (nonatomic, strong) NSUndoManager *undoManager;

/// Check if any block is currently selected
- (BOOL)hasSelectedBlock;

/// Clear all block selections
- (void)clearAllSelections;

/// Privacy-safe render counters used only by the user-triggered diagnostic
/// snapshot. These expose counts, never bundle IDs, names, or schedule times.
- (NSUInteger)telemetryDayColumnCount;
- (NSUInteger)telemetryExpectedAllowBlockCount;
- (NSUInteger)telemetryRenderedAllowBlockCount;
- (NSDictionary<NSString *, NSNumber *> *)telemetryAllowBlockVisibilitySnapshot;
- (BOOL)telemetryEmptyStateVisible;

@end

NS_ASSUME_NONNULL_END

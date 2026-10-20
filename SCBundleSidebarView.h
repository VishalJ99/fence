//
//  SCBundleSidebarView.h
//  SelfControl
//
//  LHS sidebar showing bundle pills for selection.
//  Supports Focus/All-Up state model for calendar editing.
//

#import <Cocoa/Cocoa.h>

@class SCBlockBundle;
@class SCBundleSidebarView;
@class SCWeeklySchedule;

NS_ASSUME_NONNULL_BEGIN

@protocol SCBundleSidebarViewDelegate <NSObject>

/// Called when user clicks a bundle pill to select/focus it
- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didSelectBundle:(nullable SCBlockBundle *)bundle;

/// Called when user clicks the add bundle button
- (void)bundleSidebarDidRequestAddBundle:(SCBundleSidebarView *)sidebar;

/// Called when user clicks Edit or double-clicks a bundle
- (void)bundleSidebar:(SCBundleSidebarView *)sidebar didRequestEditBundle:(SCBlockBundle *)bundle;

@end

@interface SCBundleSidebarView : NSView

/// Delegate for handling selection events
@property (nonatomic, weak, nullable) id<SCBundleSidebarViewDelegate> delegate;

/// Array of bundles to display
@property (nonatomic, copy) NSArray<SCBlockBundle *> *bundles;

/// Currently selected bundle ID (nil = All-Up state, showing all bundles)
@property (nonatomic, copy, nullable) NSString *selectedBundleID;

/// Whether editing is locked (committed state)
@property (nonatomic, assign) BOOL isCommitted;

/// Membership remains protected until the commitment is explicitly ended.
@property (nonatomic, copy) NSSet<NSString *> *protectedBundleIDs;

/// Schedules dictionary for determining which bundles are active (bundleID -> schedule)
@property (nonatomic, copy, nullable) NSDictionary<NSString *, SCWeeklySchedule *> *schedules;

/// Reload the sidebar display
- (void)reloadData;

/// Clear selection (return to All-Up state)
- (void)clearSelection;

/// Get the bundle object for a given ID
- (nullable SCBlockBundle *)bundleForID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END

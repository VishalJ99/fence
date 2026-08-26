//
//  SCBundleEditorController.h
//  SelfControl
//
//  Sheet controller for creating/editing a bundle.
//  Allows setting name, color, and adding apps/websites.
//

#import <Cocoa/Cocoa.h>
#import "Block Management/SCBlockBundle.h"

NS_ASSUME_NONNULL_BEGIN

@class SCBundleEditorController;

@protocol SCBundleEditorDelegate <NSObject>

/// Called when user saves the bundle
- (void)bundleEditor:(SCBundleEditorController *)editor didSaveBundle:(SCBlockBundle *)bundle;

/// Called when user cancels editing
- (void)bundleEditorDidCancel:(SCBundleEditorController *)editor;

/// Called when user deletes the bundle
- (void)bundleEditor:(SCBundleEditorController *)editor didDeleteBundle:(SCBlockBundle *)bundle;

@end

@interface SCBundleEditorController : NSWindowController

@property (nonatomic, weak, nullable) id<SCBundleEditorDelegate> delegate;

/// The bundle being edited (nil for new bundle)
@property (nonatomic, strong, readonly, nullable) SCBlockBundle *bundle;

/// Whether this is a new bundle (vs editing existing)
@property (nonatomic, readonly) BOOL isNewBundle;

/// Whether we're in committed state (presents the existing bundle read-only)
@property (nonatomic, assign) BOOL isCommitted;

/// Initialize for creating a new bundle
- (instancetype)initForNewBundle;

/// Initialize for editing an existing bundle
- (instancetype)initWithBundle:(SCBlockBundle *)bundle;

/// Show the editor as a sheet on the given window
- (void)beginSheetModalForWindow:(NSWindow *)parentWindow
               completionHandler:(nullable void (^)(NSModalResponse))handler;

@end

NS_ASSUME_NONNULL_END

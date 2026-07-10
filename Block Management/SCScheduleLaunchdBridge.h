//
//  SCScheduleLaunchdBridge.h
//  SelfControl
//
//  Bridge between Weekly Schedule UX and selfcontrol-cli via launchd.
//  Creates and manages launchd jobs that invoke the CLI at scheduled times.
//

#import <Foundation/Foundation.h>
#import "SCBlockBundle.h"
#import "SCWeeklySchedule.h"

NS_ASSUME_NONNULL_BEGIN

/// Static internal error metadata used only to classify a typed diagnostic.
/// The associated value is one of schedule_register or job_install.
FOUNDATION_EXPORT NSString * const SCScheduleLaunchdBridgeFailureStageKey;

/// Represents a calculated block window (inverted from allowed windows)
@interface SCBlockWindow : NSObject

/// Absolute start date/time for this block
@property (nonatomic, strong) NSDate *startDate;

/// Absolute end date/time for this block
@property (nonatomic, strong) NSDate *endDate;

/// Which day of the week this block falls on
@property (nonatomic, assign) SCDayOfWeek day;

/// Start time as minutes from midnight (for launchd StartCalendarInterval)
@property (nonatomic, assign) NSInteger startMinutes;

/// Duration in minutes
- (NSInteger)durationMinutes;

/// Create a block window
+ (instancetype)windowWithStartDate:(NSDate *)start endDate:(NSDate *)end day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes;

@end


/// Bridge for connecting Weekly Schedule UX to CLI via launchd
@interface SCScheduleLaunchdBridge : NSObject

#pragma mark - Directory Paths

/// Returns ~/Library/Application Support/SelfControl/Schedules/
/// Creates directory if it doesn't exist
+ (NSURL *)schedulesDirectory;

/// Returns ~/Library/LaunchAgents/
+ (NSURL *)launchAgentsDirectory;

/// Returns path to selfcontrol-cli inside the app bundle
+ (nullable NSString *)cliPath;

#pragma mark - Blocklist File Management

/// Writes a .selfcontrol blocklist file for a bundle
/// @param bundle The bundle containing entries to block
/// @param error Error output if write fails
/// @return URL of the written file, or nil on failure
- (nullable NSURL *)writeBlocklistFileForBundle:(SCBlockBundle *)bundle error:(NSError **)error;

/// Deletes the blocklist file for a bundle
- (BOOL)deleteBlocklistFileForBundleID:(NSString *)bundleID error:(NSError **)error;

/// Returns the expected blocklist file URL for a bundle ID
+ (NSURL *)blocklistFileURLForBundleID:(NSString *)bundleID;

#pragma mark - Block Window Calculation

/// Calculates block windows from a schedule for a specific day
/// Block windows are the inverse of allowed windows (when blocking should be active)
/// @param schedule The weekly schedule containing allowed windows
/// @param day The day to calculate windows for
/// @param weekOffset 0 = current week, 1 = next week
/// @return Array of SCBlockWindow representing when blocks should be active
- (NSArray<SCBlockWindow *> *)blockWindowsForSchedule:(SCWeeklySchedule *)schedule
                                                  day:(SCDayOfWeek)day
                                           weekOffset:(NSInteger)weekOffset;

/// Calculates all block windows for an entire week
- (NSArray<SCBlockWindow *> *)allBlockWindowsForSchedule:(SCWeeklySchedule *)schedule
                                              weekOffset:(NSInteger)weekOffset;

#pragma mark - launchd Job Management

/// Installs launchd jobs for a bundle's schedule
/// Creates one job per block window (daily granularity)
/// @param bundle The bundle to create jobs for
/// @param schedule The schedule defining when to block
/// @param weekOffset 0 = current week, 1 = next week
/// @param error Error output if installation fails
/// @return YES on success
- (BOOL)installJobsForBundle:(SCBlockBundle *)bundle
                    schedule:(SCWeeklySchedule *)schedule
                  weekOffset:(NSInteger)weekOffset
                       error:(NSError **)error;

/// Uninstalls all launchd jobs for a specific bundle
- (BOOL)uninstallJobsForBundleID:(NSString *)bundleID error:(NSError **)error;

/// Starts a block immediately by invoking the CLI directly
/// Used when committing during an in-progress block window
- (BOOL)startBlockImmediatelyForBundle:(SCBlockBundle *)bundle
                               endDate:(NSDate *)endDate
                                 error:(NSError **)error;

/// Uninstalls all SelfControl schedule-related launchd jobs
- (BOOL)uninstallAllScheduleJobs:(NSError **)error;

/// Unloads and removes the launchd job for one merged schedule segment.
- (BOOL)uninstallJobForSegmentID:(NSString *)segmentID error:(NSError **)error;

/// Returns labels installed for one merged schedule segment.
- (NSArray<NSString *> *)installedJobLabelsForSegmentID:(NSString *)segmentID;

#pragma mark - Segment-Based Merged Job Installation

/// Writes a merged blocklist file for multiple bundles
/// @param bundles Array of bundles whose entries should be merged
/// @param segmentID Unique identifier for this merged segment
/// @param error Error output if write fails
/// @return URL of the written file, or nil on failure
- (nullable NSURL *)writeMergedBlocklistForBundles:(NSArray<SCBlockBundle *> *)bundles
                                         segmentID:(NSString *)segmentID
                                             error:(NSError **)error;

/// Installs a launchd job for a merged segment
/// @param bundles Array of bundles contributing to this segment
/// @param segmentID Unique identifier for this segment
/// @param startDate When the block should start
/// @param endDate When the block should end
/// @param day Which day of the week
/// @param startMinutes Start time as minutes from midnight
/// @param weekOffset 0 = current week, 1 = next week
/// @param error Error output if installation fails
/// @return YES on success
- (BOOL)installJobForSegmentWithBundles:(NSArray<SCBlockBundle *> *)bundles
                              segmentID:(NSString *)segmentID
                              startDate:(NSDate *)startDate
                                endDate:(NSDate *)endDate
                                    day:(SCDayOfWeek)day
                           startMinutes:(NSInteger)startMinutes
                             weekOffset:(NSInteger)weekOffset
                                  error:(NSError **)error;

/// Starts a merged block immediately for multiple bundles
/// Used when committing during an in-progress merged segment
- (BOOL)startMergedBlockImmediatelyForBundles:(NSArray<SCBlockBundle *> *)bundles
                                    segmentID:(NSString *)segmentID
                                      endDate:(NSDate *)endDate
                                        error:(NSError **)error;

/// Returns labels of all installed jobs for a bundle
- (NSArray<NSString *> *)installedJobLabelsForBundleID:(NSString *)bundleID;

/// Returns labels of all installed SelfControl schedule jobs
- (NSArray<NSString *> *)allInstalledScheduleJobLabels;

#pragma mark - Job Label Convention

/// Job label prefix for all schedule-related jobs
+ (NSString *)jobLabelPrefix;

/// Generates a job label for a specific block window
/// Format: org.eyebeam.selfcontrol.schedule.{bundleID}.{day}.{startTime}
+ (NSString *)jobLabelForBundleID:(NSString *)bundleID day:(SCDayOfWeek)day startMinutes:(NSInteger)minutes;

#pragma mark - Plist Generation

/// Generates launchd plist dictionary for a block window
- (NSDictionary *)launchdPlistForBundle:(SCBlockBundle *)bundle
                            blockWindow:(SCBlockWindow *)window;

/// Writes a launchd plist to disk
- (BOOL)writeLaunchdPlist:(NSDictionary *)plist
                  toLabel:(NSString *)label
                    error:(NSError **)error;

/// Loads a launchd job using launchctl
- (BOOL)loadJobWithLabel:(NSString *)label error:(NSError **)error;

/// Unloads a launchd job using launchctl
- (BOOL)unloadJobWithLabel:(NSString *)label error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

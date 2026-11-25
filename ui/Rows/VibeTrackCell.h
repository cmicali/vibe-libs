//
//  VibeTrackCell.h
//  vibe-libs
//

#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"

@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kVibeTrackCellEstimatedHeight = 64;

// The mac playlist table's four columns in one row. It draws the values it is
// given and reads no model, setting or string.
@interface VibeTrackCell : UITableViewCell
// Where the separator starts: under the text, past the gutter and the art.
@property (class, nonatomic, readonly) CGFloat separatorLeadingInset;
// Set at dequeue: the table mints the cell.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerPresentationVisible;
// A transfer outranks the playing marker, including during streamed playback.
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) float loadingProgress;
// At an accessibility text size, the title wraps to as many lines as it
// needs and the subtitle to two, so nothing is cut short. Off by default,
// for a table that gives every row one height. Turn it on only in a table
// whose rows size themselves (UITableViewAutomaticDimension).
@property (nonatomic) BOOL wrapsTextAtAccessibilitySizes;
// YES when the row's height can have moved; a caller rendering in place then
// owes the table a height pass (refreshVisibleRowAtIndex:).
- (BOOL)renderRow:(VibeTrackRow *)row;
@end

NS_ASSUME_NONNULL_END

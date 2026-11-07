//
//  VibeTrackDisplay.h
//  vibe-libs
//
//  What a row shows of a track, a whole file or a CUE window of one, from its
//  tags and its window. A CUE sheet's title and performer name the window,
//  and win over the file's tags, which name the whole image. Each answer
//  reads the metadata installed now, or none while it loads.
//

#import <Foundation/Foundation.h>

@class AudioTrackMetadata;

NS_ASSUME_NONNULL_BEGIN

// The window's title, else the tagged title. nil when only the file name gives
// one: a tagless file's parse keeps its name as its title (NSURL+FilenameTitle),
// so the name shows with no metadata and after it alike. An app that marks a
// title from the name, or numbers a window, does so on nil.
FOUNDATION_EXPORT NSString *_Nullable VibeTrackTitle(AudioTrackMetadata *_Nullable metadata, NSURL *url,
                                                     NSString *_Nullable windowTitle);

// The window's performer, else the tagged artist. nil when neither has one.
FOUNDATION_EXPORT NSString *_Nullable VibeTrackArtist(AudioTrackMetadata *_Nullable metadata,
                                                      NSString *_Nullable windowPerformer);

// The length in seconds. A window with an end is its own length, read from
// its frames, with no metadata. A window to the file's end is the file's
// length less its start. 0 while the file's length is unknown.
FOUNDATION_EXPORT NSTimeInterval VibeTrackDuration(AudioTrackMetadata *_Nullable metadata, NSUInteger cueStart,
                                                   NSUInteger cueEnd);

NS_ASSUME_NONNULL_END

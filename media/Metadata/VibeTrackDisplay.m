//
//  VibeTrackDisplay.m
//  vibe-libs
//

#import "VibeTrackDisplay.h"

#import "AudioTrackMetadata.h"
#import "CueWindowMath.h"
#import "NSURL+FilenameTitle.h"

NSString *_Nullable VibeTrackTitle(AudioTrackMetadata *_Nullable metadata, NSURL *url,
                                   NSString *_Nullable windowTitle) {
    if (windowTitle.length > 0) {
        return windowTitle;
    }
    NSString *title = metadata.title;
    return title.length > 0 && ![title isEqualToString:url.filenameTitle] ? title : nil;
}

NSString *_Nullable VibeTrackArtist(AudioTrackMetadata *_Nullable metadata, NSString *_Nullable windowPerformer) {
    if (windowPerformer.length > 0) {
        return windowPerformer;
    }
    NSString *artist = metadata.artist;
    return artist.length > 0 ? artist : nil;
}

NSTimeInterval VibeTrackDuration(AudioTrackMetadata *_Nullable metadata, NSUInteger cueStart, NSUInteger cueEnd) {
    if (cueEnd > cueStart) {
        return (NSTimeInterval)(cueEnd - cueStart) / kVibeCDFramesPerSecond;
    }
    NSTimeInterval file = metadata.duration;
    return cueStart > 0 && file > 0 ? MAX(0, file - (NSTimeInterval)cueStart / kVibeCDFramesPerSecond) : file;
}

//
//  AlbumGroupingRules.h
//  vibe-libs
//
//  Which album a track belongs to, from the tags AudioTrackMetadata reads.
//  The album's title alone would merge unrelated releases that share one,
//  such as two artists' "Greatest Hits".
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Whose album a track's is, as the key groups it: the album artist, or
// else the track artist unless the track is a compilation. nil for a
// compilation with no album artist, or a track with neither name, whose
// album is "Various Artists" or no one's. An app's album line and its
// artist's albums read it, so they follow the key's own choice.
static inline NSString *_Nullable VibeAlbumGroupArtist(NSString *_Nullable albumArtist, NSString *_Nullable artist,
                                                       BOOL compilation) {
    if (albumArtist.length > 0) {
        return albumArtist;
    }
    return !compilation && artist.length > 0 ? artist : nil;
}

// The key every track of one album shares, or nil for a track that names no
// album. Two tracks group together exactly when their keys are equal.
// - A release identifier is the whole key, so a release groups whatever its
//   other tags say. Its case is ignored.
// - Otherwise the key is the album artist, the album, and the year.
// - The track artist stands in for a missing album artist.
// - A compilation never splits by track artist. With no album artist, its
//   tracks group by album and year alone.
// Text compares as tagged, which the parse has trimmed.
static inline NSString *_Nullable VibeAlbumGroupKey(NSString *_Nullable releaseID, NSString *_Nullable album,
                                                    NSString *_Nullable albumArtist, NSString *_Nullable artist,
                                                    NSInteger year, BOOL compilation) {
    if (releaseID.length > 0) {
        return [@"release\x1F" stringByAppendingString:releaseID.lowercaseString];
    }
    if (album.length == 0) {
        return nil;
    }
    NSString *groupArtist = VibeAlbumGroupArtist(albumArtist, artist, compilation) ?: @"";
    // The unit separator keeps "a" + "bc" apart from "ab" + "c".
    return [NSString stringWithFormat:@"album\x1F%@\x1F%@\x1F%ld", groupArtist, album, (long)year];
}

NS_ASSUME_NONNULL_END

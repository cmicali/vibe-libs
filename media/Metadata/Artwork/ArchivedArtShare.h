//
//  ArchivedArtShare.h
//  vibe-libs
//
//  The archived forms of one picture, shared by every file that embeds it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Makes a picture's two archived forms: its row thumbnail's encoded bytes and
// its display-art rendition. Either may be nil, as when a decode fails.
typedef void (^VibeArchivedArtMaker)(NSData *_Nullable *_Nonnull thumbnail, NSData *_Nullable *_Nonnull rendition);

// A picture's archived forms, made once while its bytes recur, as an
// album's tracks embed one cover, rather than once a track. A parse that
// meets a picture another parse is making waits for it. Any thread.
FOUNDATION_EXPORT void VibeArchivedArtOfPicture(NSData *picture,
                                                VibeArchivedArtMaker make,
                                                NSData *_Nullable *_Nonnull thumbnail,
                                                NSData *_Nullable *_Nonnull rendition);

// How many pictures' forms it keeps, by a digest of their bytes. It empties
// 30 s after its last use, and iOS empties it on a memory warning.
FOUNDATION_EXPORT const NSUInteger kVibeArchivedArtShareCount;
// Test-only: forgets every picture.
FOUNDATION_EXPORT void VibeArchivedArtShareResetForTesting(void);

NS_ASSUME_NONNULL_END

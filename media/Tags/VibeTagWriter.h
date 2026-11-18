//
//  VibeTagWriter.h
//  vibe-libs
//
//  An in-place write of a file's tag fields and front cover through TagLib.
//  Only the fields named change. Plain Objective-C, so Swift and a .m call it.
//  Every call blocks: call it off main. A write that fails part way can leave
//  the file part written, so an app writes a copy, checks it, and swaps it in
//  (media/Tags/AGENTS.md, Writing).
//

#import <Foundation/Foundation.h>
#import "VibeTagFields.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSErrorDomain const VibeTagWriteErrorDomain;

typedef NS_ERROR_ENUM(VibeTagWriteErrorDomain, VibeTagWriteError) {
    // The file could not be opened at all.
    VibeTagWriteErrorOpenFailed = 1,
    // The file opened only for reading.
    VibeTagWriteErrorReadOnly = 2,
    // No parser took the file: an unknown format, or a damaged one.
    VibeTagWriteErrorNoParser = 3,
    // A field name is not one of VibeTagFieldsEdited().
    VibeTagWriteErrorInvalidField = 4,
    // The cover is empty, too large, not a type VibeTagCoverMIMETypes()
    // names, or its bytes do not start as its type says. Or the format cannot
    // hold its type: MP4 holds no TIFF or WebP.
    VibeTagWriteErrorInvalidImage = 5,
    // The format cannot hold a value as given, as MP4 holds no BPM but a
    // whole number, and ID3v2.3 no original date but a year.
    VibeTagWriteErrorUnsupportedValue = 6,
    // TagLib threw. The file may be part written.
    VibeTagWriteErrorTagLibThrew = 7,
    // A read, write, truncate, size check, or flush failed, or TagLib's save
    // returned false. The file may be part written.
    VibeTagWriteErrorSaveFailed = 8,
    // An ID3v2 frame is compressed or encrypted, which TagLib cannot rewrite.
    VibeTagWriteErrorUnsupportedFrame = 9,
    // The save would drop or change what the edit does not name: a frame
    // TagLib discards, an ID3v2.3 genre, an MP4 item TagLib could not parse,
    // or a FLAC's ID3 tags. media/Tags/AGENTS.md lists each.
    VibeTagWriteErrorWouldLoseData = 10,
    // VibeTagLibAudioMatches found the two files' audio differs.
    VibeTagWriteErrorAudioDiffers = 11,
};

// How a write is flushed before it answers YES (media/Tags/AGENTS.md, Sync).
typedef NS_ENUM(NSInteger, VibeTagWriteSync) {
    // F_FULLFSYNC: the drive is asked to put the file's bytes, and what
    // it took before them, on permanent storage before the call answers.
    VibeTagWriteSyncFull = 0,
    // F_BARRIERFSYNC: the file's bytes reach storage ahead of any write
    // that follows, such as the rename that swaps a written copy in. They
    // may still be in the drive's cache when the call answers, so a power
    // loss can lose the write, and the rename with it, but cannot keep the
    // rename without the bytes. Apple promises the order on HFS+ and APFS,
    // on drives that support barriers, as Apple SSDs do.
    VibeTagWriteSyncBarrier = 1,
};

// Values per field. An empty array, or one of empty strings, removes the
// field. A field not named keeps what it holds.
typedef NSDictionary<VibeTagField, NSArray<NSString *> *> VibeTagFieldValues;

// Sets or removes `fields` in the file at path and saves it in place. Every
// argument and every refusal is checked before the first write, so NO leaves
// the file's bytes unchanged, except with SaveFailed or TagLibThrew. YES means
// every write succeeded, the file's size is the one they imply, and it was
// flushed with F_FULLFSYNC, or fsync where the volume refuses that.
FOUNDATION_EXTERN BOOL VibeTagLibWriteFields(NSString *path, VibeTagFieldValues *fields,
                                             NSError *_Nullable __autoreleasing *_Nullable error);

// Sets the embedded front cover, or removes it when data is nil. Other
// pictures stay. mimeType is one of VibeTagCoverMIMETypes(), and the bytes'
// signature must match it. MP4 refuses TIFF and WebP.
FOUNDATION_EXTERN BOOL VibeTagLibWriteFrontCover(NSString *path, NSData *_Nullable data, NSString *_Nullable mimeType,
                                                 NSError *_Nullable __autoreleasing *_Nullable error);

// Both in one save. With changeCover NO, the cover arguments are ignored.
FOUNDATION_EXTERN BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *_Nullable fields, BOOL changeCover,
                                           NSData *_Nullable coverData, NSString *_Nullable coverMIMEType,
                                           NSError *_Nullable __autoreleasing *_Nullable error);

// VibeTagLibWriteTags with a choice of flush. The others flush with
// VibeTagWriteSyncFull. With Barrier, a volume that refuses F_BARRIERFSYNC
// gets F_FULLFSYNC, and one that refuses both gets fsync, which orders
// nothing.
FOUNDATION_EXTERN BOOL VibeTagLibWriteTagsWithSync(NSString *path, VibeTagFieldValues *_Nullable fields,
                                                   BOOL changeCover, NSData *_Nullable coverData,
                                                   NSString *_Nullable coverMIMEType, VibeTagWriteSync sync,
                                                   NSError *_Nullable __autoreleasing *_Nullable error);

// The cover types a write takes: image/jpeg, image/png, image/gif,
// image/bmp, image/tiff, and image/webp.
FOUNDATION_EXTERN NSArray<NSString *> *VibeTagCoverMIMETypes(void);

// The front cover a cover write replaces, so an app can put it back: an
// ID3v2, FLAC, or Xiph comment's first picture of type front cover, or
// MP4's first covr entry. Its MIME type comes from the bytes' signature,
// else from the tag's own type, else nil. YES with nil data is a file with
// no front cover. NO with an error when no parser took the file or TagLib
// threw.
FOUNDATION_EXTERN BOOL VibeTagLibReadFrontCover(NSString *path, NSData *_Nullable __autoreleasing *_Nullable data,
                                                NSString *_Nullable __autoreleasing *_Nullable mimeType,
                                                NSError *_Nullable __autoreleasing *_Nullable error);

// The file's fields as TagLib's property map reads them, keys upper case. A
// number's "3/12" is split into TRACKTOTAL or DISCTOTAL in every format, and
// TOTALTRACKS and TOTALDISCS read as those, so a write reads back by the
// names it wrote. nil with an error when no parser took the file or TagLib
// threw.
FOUNDATION_EXTERN VibeTagFieldValues *_Nullable VibeTagLibReadFields(NSString *path,
                                                                     NSError *_Nullable __autoreleasing *_Nullable error);

// A SHA-256 of the file's audio, read from its bytes without TagLib: an
// MP3's frames between its tags, a FLAC's STREAMINFO and frames, an MP4's
// sound samples where its sample tables put them, a WAV's fmt and data
// chunks, an AIFF's COMM and SSND chunks, and an Ogg stream's
// identification and setup headers and audio pages. A tag write leaves it
// unchanged, so an app compares the original's with its rewritten copy's. It
// maps the file and reads it once. nil with an error when the format's audio
// cannot be found.
FOUNDATION_EXTERN NSData *_Nullable VibeTagLibAudioDigest(NSString *path,
                                                          NSError *_Nullable __autoreleasing *_Nullable error);

// Whether two files hold the same audio, as their digests would say,
// compared byte by byte without hashing. It finds each file's audio as the
// digest does, maps both files, and stops at the first difference. NO with
// AudioDiffers when they differ, and with the digest's error when either
// file's audio cannot be found.
FOUNDATION_EXTERN BOOL VibeTagLibAudioMatches(NSString *pathA, NSString *pathB,
                                              NSError *_Nullable __autoreleasing *_Nullable error);

NS_ASSUME_NONNULL_END

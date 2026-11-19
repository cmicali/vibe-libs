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
    // names, not whole, or its bytes do not start as its type says. Or the
    // format cannot hold its type: MP4 holds no new TIFF or WebP. Or a
    // picture VibeTagLibWritePictures was given is past its limits.
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
    // A read came back short, ran out of memory, or the file changed while
    // the digest or the match read it.
    VibeTagWriteErrorReadFailed = 12,
    // VibeTagLibAudioMatches was given one file twice.
    VibeTagWriteErrorSameFile = 13,
};

// How a write is flushed before it answers YES (media/Tags/AGENTS.md, Sync).
typedef NS_ENUM(NSInteger, VibeTagWriteSync) {
    // F_FULLFSYNC: the drive is asked to put the file's bytes, and what it
    // took before them, on permanent storage before the call answers.
    VibeTagWriteSyncFull = 0,
    // LIMIT FIRST: honored only on an APFS volume in the boot disk's
    // container, which is local and not removable. Every other volume, an
    // external drive or a disk image among them, gets Full, since a drive
    // that ignores barriers still answers success. There, F_BARRIERFSYNC:
    // the file's bytes reach storage ahead of any write that follows, such
    // as the rename that swaps a written copy in. They may still be in the
    // drive's cache when the call answers, so a power loss can lose the
    // write, and the rename with it, but cannot keep the rename without the
    // bytes.
    VibeTagWriteSyncBarrier = 1,
};

// Values per field. An empty array, or one of empty strings, removes the
// field. A field not named keeps what it holds.
typedef NSDictionary<VibeTagField, NSArray<NSString *> *> VibeTagFieldValues;

// Sets or removes `fields` in the file at path, and with changeCover, sets
// or removes its cover, in one save in place. Every argument and every
// refusal is checked before the first write, so NO leaves the file's bytes
// unchanged, except with SaveFailed or TagLibThrew. YES means every write
// succeeded, the file's size is the one they imply, and it was flushed as
// `sync` says.
//
// The cover is every front cover, or when the file has none, the one
// picture the art read shows, whatever its type. A cover write takes it and
// adds a front cover. coverMIMEType is one of VibeTagCoverMIMETypes(), the
// bytes' signature must match it, and the image must be whole. MP4 refuses
// TIFF and WebP. With coverData nil, the cover is removed: each removal
// takes what shows, so a second removal takes the next picture that shows.
// A picture that never showed stays, whatever its type.
FOUNDATION_EXTERN BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *_Nullable fields, BOOL changeCover,
                                           NSData *_Nullable coverData, NSString *_Nullable coverMIMEType,
                                           VibeTagWriteSync sync,
                                           NSError *_Nullable __autoreleasing *_Nullable error);

// The cover types a write takes: image/jpeg, image/png, image/gif,
// image/bmp, image/tiff, and image/webp.
FOUNDATION_EXTERN NSArray<NSString *> *VibeTagCoverMIMETypes(void);

// What a picture is: ID3v2's APIC numbering, which FLAC and Xiph pictures
// share, from 0 to 20. MP4's pictures have no type.
typedef NS_ENUM(NSInteger, VibeTagPictureType) {
    VibeTagPictureTypeUntyped = -1,
    VibeTagPictureTypeOther = 0,
    VibeTagPictureTypeFrontCover = 3,
    VibeTagPictureTypeBackCover = 4,
};

// One embedded picture as its tag stores it. A value: isEqual: and hash
// cover every field.
@interface VibeTagPicture : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithData:(NSData *)data mimeType:(nullable NSString *)mimeType type:(VibeTagPictureType)type
                 description:(nullable NSString *)pictureDescription;
- (instancetype)initWithData:(NSData *)data mimeType:(nullable NSString *)mimeType type:(VibeTagPictureType)type
                 description:(nullable NSString *)pictureDescription width:(NSUInteger)width
                      height:(NSUInteger)height colorDepth:(NSUInteger)colorDepth
                  colorCount:(NSUInteger)colorCount NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSData *data;
// The tag's own MIME string, unchanged, or nil for none. MP4's is its
// typed format, or nil when untyped.
@property (nonatomic, readonly, nullable) NSString *mimeType;
// The type the bytes' signature names, else mimeType in the writer's
// spelling, else nil. Taggers often name a PNG image/jpeg.
@property (nonatomic, readonly, nullable) NSString *imageMIMEType;
@property (nonatomic, readonly) VibeTagPictureType type;
// Empty in MP4.
@property (nonatomic, readonly) NSString *pictureDescription;
// FLAC's and a Xiph picture's fields, as stored. 0 elsewhere.
@property (nonatomic, readonly) NSUInteger width, height, colorDepth, colorCount;

@end

// Every picture with bytes in the file, in its order, and the index of the
// one the art read shows (TagLibAudioFile.h), or NSNotFound. A picture with
// no bytes is never shown or listed. An MPEG, WAV, or AIFF file's are its
// ID3v2 tag's. YES with an empty array is a file with none. NO with an error
// when no parser took the file or TagLib threw.
FOUNDATION_EXTERN BOOL VibeTagLibReadPictures(NSString *path,
                                              NSArray<VibeTagPicture *> *_Nullable __autoreleasing *_Nullable pictures,
                                              NSUInteger *_Nullable shownIndex,
                                              NSError *_Nullable __autoreleasing *_Nullable error);

// Replaces every picture in the file with `pictures`, in order, each as
// given. An exact undo writes back what VibeTagLibReadPictures answered
// before the edit, a snapshot taken then, since the edit's own result
// cannot say what it took. The bytes are not checked against the type.
// Untyped is "other" outside MP4. In MP4 a picture's type is Untyped or
// FrontCover, its description is ignored, and a MIME type MP4 does not type
// is written untyped. VibeTagLibPicturesFit says which lists fit, and every
// refusal of VibeTagLibWriteTags holds.
// media/Tags/AGENTS.md lists what the write does not keep.
// Whether VibeTagLibWritePictures would take `pictures` for the file at
// path, by the same checks: each picture holds 1 to 16,000,000 bytes and a
// type from -1 to 20, all of them at most 250,000,000 bytes, and in MP4
// each is Untyped or FrontCover. NO with InvalidImage when one fails, and
// NoParser or TagLibThrew when the file cannot be read. It opens the file
// for reading only. It does not ask whether the file is writable.
FOUNDATION_EXTERN BOOL VibeTagLibPicturesFit(NSString *path, NSArray<VibeTagPicture *> *pictures,
                                             NSError *_Nullable __autoreleasing *_Nullable error);

FOUNDATION_EXTERN BOOL VibeTagLibWritePictures(NSString *path, NSArray<VibeTagPicture *> *pictures,
                                               VibeTagWriteSync sync,
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
// reads the file once, with pread. nil with NoParser when the format's
// audio cannot be found, and with ReadFailed when a read comes back short
// or the file changes while it is read.
FOUNDATION_EXTERN NSData *_Nullable VibeTagLibAudioDigest(NSString *path,
                                                          NSError *_Nullable __autoreleasing *_Nullable error);

// Whether two files hold the same audio, as their digests would say,
// compared byte by byte without hashing. It finds each file's audio as the
// digest does, reads both with pread into two buffers of at most 1 MiB,
// uninitialized and uncached, and stops at the first difference. NO with
// AudioDiffers when they differ,
// SameFile when both paths name one file, and the digest's errors.
FOUNDATION_EXTERN BOOL VibeTagLibAudioMatches(NSString *pathA, NSString *pathB,
                                              NSError *_Nullable __autoreleasing *_Nullable error);

NS_ASSUME_NONNULL_END

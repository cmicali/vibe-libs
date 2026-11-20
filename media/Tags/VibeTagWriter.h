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
    // picture VibeTagLibWritePictures was given is past its limits, or one
    // APE cannot hold, which keeps one front and one back cover.
    VibeTagWriteErrorInvalidImage = 5,
    // The format cannot hold a value as given, as MP4 holds no BPM but a
    // whole number. An ID3v2.3 tag that cannot becomes 2.4 instead.
    VibeTagWriteErrorUnsupportedValue = 6,
    // TagLib threw. The file may be part written.
    VibeTagWriteErrorTagLibThrew = 7,
    // A read, write, truncate, size check, or flush failed, or TagLib's save
    // returned false. The file may be part written.
    VibeTagWriteErrorSaveFailed = 8,
    // An ID3v2 frame is compressed or encrypted, which TagLib cannot rewrite.
    VibeTagWriteErrorUnsupportedFrame = 9,
    // The save would drop or change what the edit does not name: a frame
    // TagLib discards, an MP4 item TagLib could not parse, or a FLAC's ID3
    // tags. media/Tags/AGENTS.md lists each.
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

// What a write did beyond the edit it was asked for, so an app can say so.
// ID3v2UpgradedTo24: the file's ID3v2 tag was 2.2 or 2.3 and is now 2.4. A
// 2.2 tag always is, since TagLib cannot write 2.2. A 2.3 tag is when its
// 2.3 render would not read back what it holds after the edit: its genres,
// its dates, or a frame it holds twice (media/Tags/AGENTS.md, ID3v2.3). The
// upgrade is permanent: an undo, even back to one genre, leaves it 2.4.
typedef NS_OPTIONS(NSUInteger, VibeTagWriteChanges) {
    VibeTagWriteChangeNone = 0,
    VibeTagWriteChangeID3v2UpgradedTo24 = 1 << 0,
};

// Values per field. An empty array, or one of empty strings, removes the
// field. A field not named keeps what it holds.
typedef NSDictionary<VibeTagField, NSArray<NSString *> *> VibeTagFieldValues;

// Sets or removes `fields` in the file at path, and with changeCover, sets
// or removes its cover, in one save in place. Every argument and every
// refusal is checked before the first write, so NO leaves the file's bytes
// unchanged, except with SaveFailed or TagLibThrew. YES means every write
// succeeded, the file's size is the one they imply, and it was flushed as
// `sync` says. `changes`, when given, is set to what the write did beyond
// the edit. On a refusal it is None, since nothing was written. On
// SaveFailed or TagLibThrew it says what may be on disk, since the file may
// be part written. An ID3v2 tag keeps its version, except as
// VibeTagWriteChanges says.
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
                                           VibeTagWriteSync sync, VibeTagWriteChanges *_Nullable changes,
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
// no bytes is never shown or listed. An MPEG, WAV, AIFF, or DSF file's are
// its ID3v2 tag's. A WavPack or Monkey's Audio file's are its APE tag's
// front cover, then its back cover, with no MIME string, since APE stores
// none. YES with an empty array is a file with none. NO with an error when
// no parser took the file or TagLib threw.
FOUNDATION_EXTERN BOOL VibeTagLibReadPictures(NSString *path,
                                              NSArray<VibeTagPicture *> *_Nullable __autoreleasing *_Nullable pictures,
                                              NSUInteger *_Nullable shownIndex,
                                              NSError *_Nullable __autoreleasing *_Nullable error);

// The picture home of a file's tag: an MPEG, WAV, AIFF, or DSF file's ID3v2
// tag, a FLAC's picture blocks, an Ogg Vorbis or Opus file's Xiph comment, an
// MP4's covr item, or a WavPack or Monkey's Audio file's APE tag. TRAP:
// VibeAudioFileFormat names the codec, so FLAC in an MP4 reads FLAC, and
// cannot say this.
typedef NS_ENUM(NSInteger, VibeTagContainer) {
    VibeTagContainerUnknown = 0,
    VibeTagContainerID3v2 = 1,
    VibeTagContainerFLAC = 2,
    VibeTagContainerXiph = 3,
    VibeTagContainerMP4 = 4,
    VibeTagContainerAPE = 5,
};

// Whether VibeTagLibWritePictures would take `pictures` for a file of
// `container`, by the checks it makes of the list. Each picture holds bytes
// and a type from -1 to 20, and fits a FLAC block of under 16 MiB with its
// MIME type and description, in every format, so a list fits any file. All
// of them, counted as blocks, hold at most 250,000,000 bytes. In MP4 each
// is Untyped or FrontCover. In APE each is FrontCover or BackCover, one of
// each at most. NO with InvalidImage and the reason. It reads
// no file, so it checks the list alone, not the file's own refusals: a file
// that is read-only, damaged, or holds what TagLib would drop is refused by
// the write alone.
FOUNDATION_EXTERN BOOL VibeTagLibPicturesFit(NSArray<VibeTagPicture *> *pictures, VibeTagContainer container,
                                             NSError *_Nullable __autoreleasing *_Nullable error);

// Replaces every picture in the file with `pictures`, in order, each as
// given. An exact undo writes back what VibeTagLibReadPictures answered
// before the edit, a snapshot taken then, since the edit's own result
// cannot say what it took. The bytes are not checked against the type.
// Untyped is "other" outside MP4. In MP4 a picture's description is
// ignored, and a MIME type MP4 does not type is written untyped. APE keeps
// no MIME string and writes its front cover before its back cover. A list
// VibeTagLibPicturesFit refuses for the file's container is refused, and
// every refusal of VibeTagLibWriteTags holds, and `changes` says what it
// says there. media/Tags/AGENTS.md lists what the write does not keep.
FOUNDATION_EXTERN BOOL VibeTagLibWritePictures(NSString *path, NSArray<VibeTagPicture *> *pictures,
                                               VibeTagWriteSync sync, VibeTagWriteChanges *_Nullable changes,
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
// chunks, an AIFF's COMM and SSND chunks, an Ogg stream's identification
// and setup headers and audio pages, a WavPack file's blocks, a Monkey's
// Audio file's header, seek table, and frames, and a DSF's fmt and data
// chunks. A tag write leaves it
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

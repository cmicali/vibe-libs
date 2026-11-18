//
//  VibeTagWriter.h
//  vibe-libs
//
//  An in-place write of a file's tag fields and front cover through TagLib.
//  Only the fields named change. Plain Objective-C, so Swift and a .m call it.
//  Every call blocks: call it off main. The write is not atomic, so an app
//  writes a copy and swaps it in (media/Tags/AGENTS.md, Writing).
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
    // A field name is empty, holds '=', or is PICTURE, which the cover
    // arguments set.
    VibeTagWriteErrorInvalidField = 4,
    // The cover is empty, or its MIME type is neither image/jpeg nor image/png.
    VibeTagWriteErrorInvalidImage = 5,
    // The format cannot hold a field's value, as MP4 holds no BPM but a number.
    VibeTagWriteErrorUnsupportedValue = 6,
    // TagLib threw. The file may be partly written.
    VibeTagWriteErrorTagLibThrew = 7,
    // TagLib's save returned false. The file may be partly written.
    VibeTagWriteErrorSaveFailed = 8,
};

// Values per field. An empty array removes the field. A field not named
// keeps what it holds.
typedef NSDictionary<VibeTagField, NSArray<NSString *> *> VibeTagFieldValues;

// Sets or removes `fields` in the file at path and saves it in place.
// Validates every argument before it opens the file. NO with an error leaves
// the file untouched, except for TagLibThrew and SaveFailed.
FOUNDATION_EXTERN BOOL VibeTagLibWriteFields(NSString *path, VibeTagFieldValues *fields, NSError *_Nullable __autoreleasing *_Nullable error);

// Sets the embedded front cover from JPEG or PNG bytes, or removes it when
// data is nil. Other pictures stay.
FOUNDATION_EXTERN BOOL VibeTagLibWriteFrontCover(NSString *path, NSData *_Nullable data, NSString *_Nullable mimeType,
                               NSError *_Nullable __autoreleasing *_Nullable error);

// Both in one save. With changeCover NO, the cover arguments are ignored.
FOUNDATION_EXTERN BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *_Nullable fields, BOOL changeCover,
                         NSData *_Nullable coverData, NSString *_Nullable coverMIMEType,
                         NSError *_Nullable __autoreleasing *_Nullable error);

// The file's fields as TagLib's property map reads them, keys upper case. A
// total ID3v2, MP4, or APE holds in its number's "3/12" is split into
// TRACKTOTAL or DISCTOTAL, so a write reads back by the names it wrote. nil
// with an error when no parser took the file or TagLib threw.
FOUNDATION_EXTERN VibeTagFieldValues *_Nullable VibeTagLibReadFields(NSString *path, NSError *_Nullable __autoreleasing *_Nullable error);

NS_ASSUME_NONNULL_END

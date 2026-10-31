//
//  CloudListingFetcher.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const VibeCloudFetchErrorDomain;
typedef NS_ERROR_ENUM(VibeCloudFetchErrorDomain, VibeCloudFetchError) {
    // The file is larger than the fetch's limit, so it was not fetched.
    VibeCloudFetchErrorTooLarge = 1,
    // The provider answered, and the directory or file is still not here.
    VibeCloudFetchErrorStillDataless,
};

// Brings what a background walk could not list or read to this Mac: a
// directory's listing, and a small file such as a CUE sheet. Each call blocks
// until the provider answers, so it never runs on main. TRAP: the wait cannot
// be interrupted. The thread waits inside the provider, so a caller that
// stops abandons the call, and the thread ends when the provider answers.
@interface CloudListingFetcher : NSObject

// Lists directory with materialization on, which lets the provider fetch its
// listing, then each directory under it that is not fetched yet, so one call
// brings a subtree's listings. It reads no file. NO, with the error of the
// first listing that failed, when one did. What was listed before stays
// listed.
+ (BOOL)fetchListingOfDirectory:(NSURL *)directory error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Downloads the file, when its size is at most limit bytes. A file already
// here is a fetch that succeeded. NO, with VibeCloudFetchErrorTooLarge, for a
// larger file, which is not fetched.
+ (BOOL)fetchFile:(NSURL *)file
            limit:(unsigned long long)limit
            error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

//
//  CloudListingFetcher+Debug.h
//  vibe-libs
//
//  Stand-in fetches, for tests with no file provider in reach: each answers in
//  place of the real listing or download. VibeFakeCloud is the only installer.
//  Implemented in CloudListingFetcher+Debug.m.
//

#import "CloudListingFetcher.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^VibeFakeListingFetch)(NSURL *directory, NSError *__autoreleasing _Nullable *_Nullable error);
typedef BOOL (^VibeFakeFileFetch)(NSURL *file, NSError *__autoreleasing _Nullable *_Nullable error);

@interface CloudListingFetcher (Debug)

// nil means the real fetch. The file fetch runs after the limit is checked,
// so the limit is real under the fake too.
+ (void)setFakeListingFetch:(nullable VibeFakeListingFetch)listingFetch
                  fileFetch:(nullable VibeFakeFileFetch)fileFetch;

@end

// The fetches' hooks, read under a lock.
VibeFakeListingFetch _Nullable VibeFakeListingFetchHook(void);
VibeFakeFileFetch _Nullable VibeFakeFileFetchHook(void);

NS_ASSUME_NONNULL_END

//
//  CloudListingFetcher+Debug.m
//  vibe-libs
//

#import "CloudListingFetcher+Debug.h"

#if DEBUG

#include <os/lock.h>

// Set by a test or the debug channel, read on the fetch's thread.
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static VibeFakeListingFetch sListingFetch;
static VibeFakeFileFetch sFileFetch;

VibeFakeListingFetch VibeFakeListingFetchHook(void) {
    os_unfair_lock_lock(&sLock);
    VibeFakeListingFetch fetch = sListingFetch;
    os_unfair_lock_unlock(&sLock);
    return fetch;
}

VibeFakeFileFetch VibeFakeFileFetchHook(void) {
    os_unfair_lock_lock(&sLock);
    VibeFakeFileFetch fetch = sFileFetch;
    os_unfair_lock_unlock(&sLock);
    return fetch;
}

@implementation CloudListingFetcher (Debug)

+ (void)setFakeListingFetch:(VibeFakeListingFetch)listingFetch fileFetch:(VibeFakeFileFetch)fileFetch {
    os_unfair_lock_lock(&sLock);
    sListingFetch = [listingFetch copy];
    sFileFetch = [fileFetch copy];
    os_unfair_lock_unlock(&sLock);
}

@end

#endif

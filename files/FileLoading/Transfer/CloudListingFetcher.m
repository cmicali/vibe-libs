//
//  CloudListingFetcher.m
//  vibe-libs
//

#import "CloudListingFetcher.h"
#import "CloudListingFetcher+Debug.h"
#import "PlaceholderFiles.h"
#import "VibeMacros.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const VibeCloudFetchErrorDomain = @"VibeCloudFetchErrorDomain";

static NSError *VibeFetchError(VibeCloudFetchError code, NSURL *url) {
    return [NSError errorWithDomain:VibeCloudFetchErrorDomain code:code userInfo:@{NSURLErrorKey: url}];
}

static NSError *VibePOSIXError(int code, NSURL *url) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSURLErrorKey: url}];
}

// Runs block with this thread able to materialize, whatever its queue set.
// TRAP: thread scope, restored after, since the thread runs other work next.
static BOOL VibeMaterializing(NS_NOESCAPE BOOL (^block)(void)) {
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    BOOL set = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                              IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0;
    if (!set) {
        LogWarn(@"Could not turn materialization on for a fetch: %s", strerror(errno));
    }
    BOOL result = block();
    if (set && previous >= 0) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
    }
    return result;
}

// Lists one directory, and gives its subdirectories that are not fetched yet.
static BOOL VibeListDirectory(NSURL *directory, NSMutableArray<NSURL *> *unfetched, NSError **error) {
    DIR *dir = opendir(directory.fileSystemRepresentation);
    if (!dir) {
        if (error) {
            *error = VibePOSIXError(errno, directory);
        }
        return NO;
    }
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (entry->d_type != DT_DIR || strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        NSURL *child = [directory URLByAppendingPathComponent:@(entry->d_name) isDirectory:YES];
        if ([PlaceholderFiles isDatalessDirectory:child]) {
            [unfetched addObject:child];
        }
    }
    int failed = errno;
    closedir(dir);
    if (failed != 0) {
        if (error) {
            *error = VibePOSIXError(failed, directory);
        }
        return NO;
    }
    return YES;
}

@implementation CloudListingFetcher

+ (BOOL)fetchListingOfDirectory:(NSURL *)directory error:(NSError *__autoreleasing *)error {
#if DEBUG
    VibeFakeListingFetch fake = VibeFakeListingFetchHook();
    if (fake) {
        return fake(directory, error);
    }
#endif
    return VibeMaterializing(^BOOL {
        NSMutableArray<NSURL *> *pending = [NSMutableArray arrayWithObject:directory];
        NSError *firstError = nil;
        while (pending.count > 0) {
            NSURL *next = pending.lastObject;
            [pending removeLastObject];
            NSError *listError = nil;
            if (!VibeListDirectory(next, pending, &listError) && !firstError) {
                firstError = listError;
            }
        }
        if (!firstError && [PlaceholderFiles isDatalessDirectory:directory]) {
            firstError = VibeFetchError(VibeCloudFetchErrorStillDataless, directory);
        }
        if (firstError && error) {
            *error = firstError;
        }
        return firstError == nil;
    });
}

+ (BOOL)fetchFile:(NSURL *)file limit:(unsigned long long)limit error:(NSError *__autoreleasing *)error {
    struct stat st;
    if (stat(file.fileSystemRepresentation, &st) != 0) {
        if (error) {
            *error = VibePOSIXError(errno, file);
        }
        return NO;
    }
    if ((unsigned long long)st.st_size > limit) {
        if (error) {
            *error = VibeFetchError(VibeCloudFetchErrorTooLarge, file);
        }
        return NO;
    }
#if DEBUG
    VibeFakeFileFetch fake = VibeFakeFileFetchHook();
    if (fake) {
        return fake(file, error);
    }
#endif
    if (![PlaceholderFiles isDatalessFile:file]) {
        return YES;
    }
    // One byte read asks the provider for the whole file.
    return VibeMaterializing(^BOOL {
        int fd = open(file.fileSystemRepresentation, O_RDONLY);
        if (fd < 0) {
            if (error) {
                *error = VibePOSIXError(errno, file);
            }
            return NO;
        }
        char byte;
        ssize_t read = pread(fd, &byte, 1, 0);
        int failed = read < 0 ? errno : 0;
        close(fd);
        if (failed != 0) {
            if (error) {
                *error = VibePOSIXError(failed, file);
            }
            return NO;
        }
        if ([PlaceholderFiles isDatalessFile:file]) {
            if (error) {
                *error = VibeFetchError(VibeCloudFetchErrorStillDataless, file);
            }
            return NO;
        }
        return YES;
    });
}

@end

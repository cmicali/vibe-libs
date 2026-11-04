//
//  FolderArtFileIO.m
//  vibe-libs
//

#import "FolderArtFileIO.h"

#import <errno.h>
#import <sys/resource.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

BOOL VibeFolderArtFileInfo(NSString *path, unsigned long long *size) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_size <= 0 || (unsigned long long)info.st_size > kMaxArtFileBytes) {
        return NO;
    }
    if (size) {
        *size = (unsigned long long)info.st_size;
    }
    return YES;
}

// TRAP: O_NONBLOCK belongs on the open and nowhere else. It keeps a FIFO or
// device named cover.jpg from wedging the open (S_ISREG is known only after
// it); left on across the reads, a file whose bytes are not resident answers
// EAGAIN, which says nothing about the image.
// The read itself, as VibeReadFolderArt runs it.
static NSData *VibeReadFolderArtBytes(NSString *path);

// A cover the provider frees after the resolver's test must fail its read,
// not download: the read runs with materialization off for its thread, as
// the metadata parse's does. TRAP: the policy is the thread's, so it is put
// back after, since the queue's thread runs other work next.
NSData *VibeReadFolderArt(NSString *path) {
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    BOOL set = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                              IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0;
    NSData *data = VibeReadFolderArtBytes(path);
    if (set && previous >= 0) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
    }
    return data;
}

static NSData *VibeReadFolderArtBytes(NSString *path) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) {
        return nil;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
            (unsigned long long)info.st_size > kMaxArtFileBytes) {
        close(descriptor);
        return nil;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        // The reads would answer EAGAIN; the caller's retry budget covers this.
        close(descriptor);
        return nil;
    }
    NSUInteger length = (NSUInteger)info.st_size;
    void *bytes = malloc(length);
    if (!bytes) {
        close(descriptor);
        return nil;
    }
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t count = read(descriptor, (char *)bytes + offset, length - offset);
        if (count > 0) {
            offset += (NSUInteger)count;
        }
        else if (count < 0 && errno == EINTR) {
            continue;
        }
        else {
            break;
        }
    }
    close(descriptor);
    if (offset != length) {
        free(bytes);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}
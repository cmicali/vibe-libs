//
//  FilePaths.m
//  vibe-libs
//

#import "FilePaths.h"

// Where root ends in path, or 0 when path is neither root nor under it. APFS
// matches names in any case, so the root does too.
static NSUInteger VibeAliasRootEnd(NSString *path, NSString *root) {
    NSRange found = [path rangeOfString:root options:NSAnchoredSearch | NSCaseInsensitiveSearch];
    if (found.location == NSNotFound) {
        return 0;
    }
    NSUInteger rootEnd = NSMaxRange(found);
    if (rootEnd < path.length && [path characterAtIndex:rootEnd] != '/') {
        return 0;
    }
    return rootEnd;
}

NSString *VibeAliasFreePath(NSString *path) {
    NSUInteger dataVolumeEnd = VibeAliasRootEnd(path, @"/System/Volumes/Data");
    if (dataVolumeEnd == path.length) {
        return @"/";
    }
    if (dataVolumeEnd > 0) {
        path = [path substringFromIndex:dataVolumeEnd];
    }
    NSUInteger privateEnd = VibeAliasRootEnd(path, @"/private");
    if (privateEnd == 0 || privateEnd == path.length) {
        return path;
    }
    // /private itself is real; only these roots are aliases.
    NSString *underPrivate = [path substringFromIndex:privateEnd];
    for (NSString *root in @[@"/tmp", @"/var", @"/etc"]) {
        if (VibeAliasRootEnd(underPrivate, root) > 0) {
            return underPrivate;
        }
    }
    return path;
}

// TRAP: never stringByStandardizingPath here. It stats the path to decide
// whether to drop /private, and on a provider's folder that stat is IPC on
// whichever thread asked: the Files browser named and compared folders with
// it on main as each one opened.
NSString *VibeComparablePath(NSString *path) {
    if (!path) {
        return nil;
    }
    // Only a path with something to resolve pays for the URL round trip.
    BOOL resolves = [path containsString:@"/."] || [path containsString:@"//"]
            || (path.length > 1 && [path hasSuffix:@"/"]);
    NSString *standard = path;
    if (resolves) {
        standard = [NSURL fileURLWithPath:path isDirectory:NO].standardizedURL.path ?: path;
        standard = [NSString pathWithComponents:standard.pathComponents];
    }
    return VibeAliasFreePath(standard);
}

// TRAP: never URLByStandardizingPath here. It stats a path that starts with
// /private or holds "..", so it can stall the player or the claim's state
// queue before the bounded probe begins. Every path an iOS provider hands over
// starts with /private.
NSString *VibeStandardizedAudioOpenPath(NSURL *url) {
    if (url.isFileURL) {
        return VibeComparablePath(url.path) ?: @"";
    }
    return url.absoluteString ?: @"";
}

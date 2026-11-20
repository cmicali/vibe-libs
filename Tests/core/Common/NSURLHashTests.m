#import <XCTest/XCTest.h>

#import "NSURL+Hash.h"
#import "VibeTestVolumes.h"

@interface NSURLHashTests : XCTestCase
@end

@implementation NSURLHashTests {
    NSURL *_dir;
}

- (void)setUp {
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"vibe-hash-%@",
                                            NSUUID.UUID.UUIDString]]];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
}

- (NSURL *)writeFileNamed:(NSString *)name contents:(NSString *)contents {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    [[contents dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    return url;
}

#pragma mark - Shape

- (void)testKeyIsSizeMtimeAndPathHash {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *key = file.cacheKey;
    XCTAssertNotNil(key);

    NSError *error = nil;
    NSRegularExpression *shape =
            [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+-[0-9]+-[0-9a-f]{40}$"
                                                      options:0
                                                        error:&error];
    XCTAssertEqual([shape numberOfMatchesInString:key options:0
                                            range:NSMakeRange(0, key.length)], 1,
                   @"unexpected key shape: %@", key);
    XCTAssertTrue([key hasPrefix:@"5-"], @"leads with the byte size: %@", key);
}

// The stat a key was made from comes back with it: the file's size, and the
// date the key rounds.
- (void)testTheKeyHandsBackItsStat {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    struct stat info;
    memset(&info, 0, sizeof info);
    NSString *key = [file cacheKeyWithStat:&info];
    XCTAssertEqualObjects(key, file.cacheKey);
    XCTAssertEqual(info.st_size, 5);
    XCTAssertGreaterThan(info.st_mtimespec.tv_sec, 0);
    XCTAssertNil([[NSURL fileURLWithPath:@"/no/such/file"] cacheKeyWithStat:&info]);
}

- (void)testKeyIsStableAcrossReads {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    XCTAssertEqualObjects(file.cacheKey, file.cacheKey);
}

#pragma mark - What moves the key

- (void)testRewritingTheFileMovesTheKey {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = file.cacheKey;

    [self writeFileNamed:@"a.mp3" contents:@"a different length entirely"];
    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testSameSizeRewriteStillMovesTheKeyViaMtime {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"aaaaa"];
    NSString *before = file.cacheKey;

    usleep(20000); // outrun the mtime's microsecond resolution
    [self writeFileNamed:@"a.mp3" contents:@"bbbbb"];

    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testMovingTheFileMovesTheKey {
    NSURL *original = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = original.cacheKey;

    NSURL *moved = [_dir URLByAppendingPathComponent:@"b.mp3"];
    [NSFileManager.defaultManager moveItemAtURL:original toURL:moved error:NULL];

    XCTAssertNotEqualObjects(before, moved.cacheKey);
}

- (void)testIdenticalContentAtDifferentPathsKeysSeparately {
    NSURL *first = [self writeFileNamed:@"a.mp3" contents:@"same bytes"];
    NSURL *second = [self writeFileNamed:@"b.mp3" contents:@"same bytes"];
    XCTAssertNotEqualObjects(first.cacheKey, second.cacheKey);
}

- (void)testSymlinkResolvesToItsTargetsIdentity {
    NSURL *target = [self writeFileNamed:@"real.mp3" contents:@"hello"];
    NSURL *link = [_dir URLByAppendingPathComponent:@"link.mp3"];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:link
                                       withDestinationURL:target
                                                    error:NULL];

    XCTAssertEqualObjects(link.cacheKey, target.cacheKey);
}

#pragma mark - No identity

- (void)testMissingFileHasNoKey {
    // Callers read nil as "don't cache".
    NSURL *missing = [_dir URLByAppendingPathComponent:@"nope.mp3"];
    XCTAssertNil(missing.cacheKey);
}

- (void)testNonFileURLHasNoKey {
    XCTAssertNil([NSURL URLWithString:@"https://example.com/a.mp3"].cacheKey);
}

#pragma mark - The place (CH32)

static NSString *SHA1(NSString *text) {
    return [[text dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
}

static NSString *PlaceHash(NSString *key) {
    return [key componentsSeparatedByString:@"-"].lastObject;
}

// A file on a volume with a UUID is keyed by the UUID and its path within
// the volume.
- (void)testAFileIsKeyedByItsVolumeAndItsPathWithin {
    NSString *mount = _dir.path.stringByResolvingSymlinksInPath;
    VibeTestUseVolume(self, @"0e1d2c3b-4a59-6877-8695-a4b3c2d1e0f0", mount);
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    XCTAssertEqualObjects(PlaceHash(file.cacheKey), SHA1(@"0e1d2c3b-4a59-6877-8695-a4b3c2d1e0f0:/a.mp3"));
}

// A drive that mounts under another name gives the same keys.
- (void)testADriveMountedUnderAnotherNameKeepsItsKeys {
    NSURL *first = [_dir URLByAppendingPathComponent:@"Music"];
    NSURL *second = [_dir URLByAppendingPathComponent:@"Music 1"];
    for (NSURL *volume in @[first, second]) {
        [NSFileManager.defaultManager createDirectoryAtURL:[volume URLByAppendingPathComponent:@"Album"]
                               withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *file = [volume URLByAppendingPathComponent:@"Album/a.flac"];
        XCTAssertTrue([[@"audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:NO]);
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:700000000];
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: date}
                                                     ofItemAtPath:file.path error:NULL]);
    }
    VibeTestUseVolume(self, @"uuid-of-the-drive", first.path.stringByResolvingSymlinksInPath);
    NSString *key = [first URLByAppendingPathComponent:@"Album/a.flac"].cacheKey;
    VibeTestUseVolume(self, @"uuid-of-the-drive", second.path.stringByResolvingSymlinksInPath);
    XCTAssertEqualObjects([second URLByAppendingPathComponent:@"Album/a.flac"].cacheKey, key);
    VibeTestUseVolume(self, @"uuid-of-another-drive", second.path.stringByResolvingSymlinksInPath);
    XCTAssertNotEqualObjects([second URLByAppendingPathComponent:@"Album/a.flac"].cacheKey, key,
                             @"another drive is another place");
}

// A volume with no UUID keeps the absolute path, so its keys are as before.
- (void)testAVolumeWithNoUUIDKeepsTheAbsolutePath {
    VibeTestUseVolume(self, nil, @"/");
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *key = file.cacheKey;
    XCTAssertEqualObjects(PlaceHash(key), SHA1(file.path.stringByResolvingSymlinksInPath));
    XCTAssertNil([file previousCacheKeyForKey:key], @"the previous key is the key");
}

// A file under the app's home is keyed by its path from the home, so a move
// of the home, as iOS makes at each install, keeps its keys.
- (void)testAFileUnderTheHomeIsKeyedFromTheHome {
    VibeTestUseVolume(self, @"uuid-of-the-home-volume", @"/");
    NSString *relative = [@"Library/Caches/" stringByAppendingString:_dir.lastPathComponent];
    NSURL *folder = [[NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:relative];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    NSURL *file = [folder URLByAppendingPathComponent:@"a.mp3"];
    XCTAssertTrue([[@"hello" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:NO]);
    NSString *key = file.cacheKey;
    [NSFileManager.defaultManager removeItemAtURL:folder error:NULL];
    XCTAssertEqualObjects(PlaceHash(key), SHA1([NSString stringWithFormat:@"~/%@/a.mp3", relative]));
}

// The previous key is the same version's key as it was before the place, the
// absolute path's hash, and it keeps a suffix such as a cue window.
- (void)testThePreviousKeyHashesTheAbsolutePath {
    VibeTestUseVolume(self, @"uuid", @"/");
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *key = file.cacheKey;
    NSString *previous = [file previousCacheKeyForKey:key];
    NSString *prefix = [key substringToIndex:key.length - 40];
    XCTAssertEqualObjects(previous,
                          [prefix stringByAppendingString:SHA1(file.path.stringByResolvingSymlinksInPath)]);
    NSString *window = [key stringByAppendingString:@"-750-1500"];
    XCTAssertEqualObjects([file previousCacheKeyForKey:window], [previous stringByAppendingString:@"-750-1500"]);
    XCTAssertEqualObjects([NSURL previousCacheKeyForKey:key], previous, @"this process made the key");
    XCTAssertEqualObjects([NSURL previousCacheKeyForKey:window], [previous stringByAppendingString:@"-750-1500"]);
    XCTAssertNil([NSURL previousCacheKeyForKey:@"5-1-0123456789abcdef0123456789abcdef01234567"],
                 @"a key this process never made");
    XCTAssertNil([file previousCacheKeyForKey:@"not a key"]);
}

// A date before 1970 is a negative time, which the key still reads.
- (void)testAKeyBefore1970HasAPreviousKey {
    VibeTestUseVolume(self, @"uuid", @"/");
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:-86400]}
                                                 ofItemAtPath:file.path error:NULL]);
    NSString *key = file.cacheKey;
    XCTAssertTrue([key hasPrefix:@"5--86400000000-"], @"%@", key);
    NSString *previous = [file previousCacheKeyForKey:key];
    XCTAssertEqualObjects(previous, [@"5--86400000000-" stringByAppendingString:SHA1(file.path.stringByResolvingSymlinksInPath)]);
}

@end

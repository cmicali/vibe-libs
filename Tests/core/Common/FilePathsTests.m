#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "FilePaths.h"

@interface FilePathsTests : XCTestCase
@end

@implementation FilePathsTests

- (void)testEquivalentFilePathsShareOneClaimSpelling {
    NSURL *direct = [NSURL fileURLWithPath:@"/tmp/vibe/audio.flac"];
    NSURL *lexicalAlias = [NSURL fileURLWithPath:@"/tmp/vibe/part/../audio.flac"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(direct),
                          VibeStandardizedAudioOpenPath(lexicalAlias));
}

- (void)testNonFileURLUsesItsAbsoluteIdentity {
    NSURL *url = [NSURL URLWithString:@"https://example.com/audio.flac?take=2"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), url.absoluteString);
}

- (void)testFileIdentityNormalizesAliasesWithoutProbingTheFilesystem {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *path = [@"/var/vibe-open-" stringByAppendingString:identifier];
    NSArray<NSString *> *aliases = @[
        path,
        [@"/private" stringByAppendingString:path],
        [@"/System/Volumes/Data/private" stringByAppendingString:path],
        [path stringByAppendingString:@"/folder/.."],
        [path stringByReplacingOccurrencesOfString:@"/var/" withString:@"/var//./"]
    ];
    Method method = class_getInstanceMethod(NSURL.class, @selector(URLByStandardizingPath));
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^NSURL *(NSURL *url) {
        if ([url.path containsString:identifier]) {
            XCTFail(@"Audio-open identity must not use filesystem-aware path normalization");
            return url;
        }
        return ((NSURL *(*)(id, SEL))original)(url, @selector(URLByStandardizingPath));
    });
    method_setImplementation(method, replacement);
    @try {
        for (NSString *alias in aliases) {
            NSURL *url = [NSURL fileURLWithPath:alias isDirectory:NO];
            XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), path, @"%@", alias);
        }
        NSURL *otherPrivateRoot = [NSURL fileURLWithPath:@"/private/music/track.flac" isDirectory:NO];
        XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(otherPrivateRoot), @"/private/music/track.flac");
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

- (void)testAliasesDropInAnyCase {
    NSDictionary<NSString *, NSString *> *expected = @{
        @"/PRIVATE/var/folders/a.flac": @"/var/folders/a.flac",
        @"/Private/tmp/a.flac": @"/tmp/a.flac",
        @"/private/TMP/a.flac": @"/TMP/a.flac",
        @"/pRiVaTe/Etc": @"/Etc",
        @"/system/volumes/data/Users/me/a.flac": @"/Users/me/a.flac",
        @"/SYSTEM/VOLUMES/DATA/Users/me/a.flac": @"/Users/me/a.flac",
        @"/System/Volumes/data/PRIVATE/var/a.flac": @"/var/a.flac",
    };
    for (NSString *alias in expected) {
        XCTAssertEqualObjects(VibeAliasFreePath(alias), expected[alias], @"%@", alias);
        XCTAssertEqualObjects(VibeComparablePath(alias), expected[alias], @"%@", alias);
    }
}

- (void)testDataVolumeRootSpellsAsTheRoot {
    for (NSString *alias in @[@"/System/Volumes/Data", @"/System/Volumes/Data/",
                              @"/system/volumes/data"]) {
        XCTAssertEqualObjects(VibeComparablePath(alias), @"/", @"%@", alias);
    }
    XCTAssertEqualObjects(VibeAliasFreePath(@"/System/Volumes/Data"), @"/");
}

- (void)testOnlyWholeAliasRootsDrop {
    for (NSString *path in @[@"/PRIVATE", @"/Private/music/a.flac", @"/privateer/tmp/a.flac",
                             @"/private/tmpfiles/a.flac", @"/System/Volumes/DataSet/a.flac",
                             @"/System/Volumes/Preboot", @"/Volumes/Data/a.flac"]) {
        XCTAssertEqualObjects(VibeAliasFreePath(path), path, @"%@", path);
    }
    XCTAssertEqualObjects(VibeAliasFreePath(@"/System/Volumes/Data/private"), @"/private");
}

@end

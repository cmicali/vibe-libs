//
//  VibeFakeDropboxTests.m
//
//  The fake account as an app's checks use it: the real client and mirror
//  over a directory, with no stub and no network. A listing, a download, a
//  dropped connection's resend, and the sign-out. The fake's state is
//  process-wide, so only this class drives it.
//

#import <XCTest/XCTest.h>

#include <sys/stat.h>

#import "DropboxMirror.h"
#import "HTTPStub.h"
#import "VibeFakeDropbox.h"

@interface VibeFakeDropboxTests : XCTestCase
@end

@implementation VibeFakeDropboxTests {
    NSURL *_temp;
    NSURL *_account;
    DropboxClient *_client;
    DropboxMirror *_mirror;
    NSData *_song;
}

- (void)setUp {
    NSFileManager *files = NSFileManager.defaultManager;
    _temp = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    _account = [_temp URLByAppendingPathComponent:@"account" isDirectory:YES];
    NSURL *album = [_account URLByAppendingPathComponent:@"Album" isDirectory:YES];
    XCTAssertTrue([files createDirectoryAtURL:album withIntermediateDirectories:YES attributes:nil error:NULL]);
    _song = PatternBytes(300 * 1024);
    XCTAssertTrue([_song writeToURL:[album URLByAppendingPathComponent:@"01 One.flac"] atomically:YES]);
    XCTAssertTrue([PatternBytes(100) writeToURL:[album URLByAppendingPathComponent:@"notes.txt"] atomically:YES]);
    _client = [[DropboxClient alloc] initWithAppKey:@"testkey"
                                    keychainService:nil
                                      configuration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    _mirror = [[DropboxMirror alloc] initWithClient:_client
                                            rootURL:[_temp URLByAppendingPathComponent:@"mirror" isDirectory:YES]
                                     indexAttribute:@"vibe-libs.tests.fake-dropbox"
                                     downloadBudget:1LL << 30];
    [VibeFakeDropbox installWithDirectory:_account transferSeconds:0 client:_client];
}

- (void)tearDown {
    [VibeFakeDropbox uninstallFromClient:_client];
    [NSFileManager.defaultManager removeItemAtURL:_temp error:NULL];
}

- (NSURL *)listAlbum {
    XCTestExpectation *listed = [self expectationWithDescription:@"listed"];
    __block NSURL *folder = nil;
    [_mirror refreshDropboxFolder:@"/Album" completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(error);
        folder = folderURL;
        [listed fulfill];
    }];
    [self waitForExpectations:@[listed] timeout:10];
    return folder;
}

- (BOOL)fetch:(NSURL *)url {
    XCTestExpectation *fetched = [self expectationWithDescription:@"fetched"];
    __block BOOL ok = NO;
    DropboxMirror *mirror = _mirror;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        ok = [mirror fetchPlaceholderAtURL:url onReadable:nil onCancel:^(dispatch_block_t cancel) {} error:&error];
        XCTAssertNil(error);
        [fetched fulfill];
    });
    [self waitForExpectations:@[fetched] timeout:10];
    return ok;
}

- (void)testInstallLinksTheFakeAccount {
    XCTAssertTrue(VibeFakeDropbox.isInstalled);
    XCTAssertTrue(_client.isLinked);
    XCTAssertEqualObjects(_client.accountID, @"dbid:fake");
}

- (void)testListingMakesAPlaceholderForAudioOnly {
    NSURL *folder = [self listAlbum];
    XCTAssertNotNil(folder);
    NSURL *song = [folder URLByAppendingPathComponent:@"01 One.flac"];
    // A placeholder: the remote size, and no permissions, so nothing reads it.
    struct stat info;
    XCTAssertEqual(stat(song.fileSystemRepresentation, &info), 0);
    XCTAssertEqual(info.st_size, (off_t)_song.length);
    XCTAssertEqual(info.st_mode & 0777, 0);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:@"notes.txt"].path]);
    XCTAssertEqualObjects([_mirror dropboxPathForURL:song], @"/Album/01 One.flac");
    XCTAssertEqualObjects(VibeFakeDropbox.statistics[@"requests"][@"/2/files/list_folder"], @1);
}

- (void)testDownloadReplacesThePlaceholderWithTheFile {
    NSURL *song = [[self listAlbum] URLByAppendingPathComponent:@"01 One.flac"];
    XCTAssertTrue([self fetch:song]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:song], _song);
}

- (void)testDroppedConnectionResendsFromItsLastByte {
    NSURL *song = [[self listAlbum] URLByAppendingPathComponent:@"01 One.flac"];
    XCTAssertTrue([VibeFakeDropbox addFaultOfKind:@"drop" file:@"01 One.flac" after:128 * 1024 seconds:0 rate:0]);
    XCTAssertTrue([self fetch:song]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:song], _song);
    XCTAssertEqualObjects(VibeFakeDropbox.statistics[@"downloads"][@"resume"], @1);
}

- (void)testUnknownFaultIsRefused {
    XCTAssertFalse([VibeFakeDropbox addFaultOfKind:@"meteor" file:nil after:0 seconds:0 rate:0]);
}

- (void)testUninstallSignsOut {
    [VibeFakeDropbox uninstallFromClient:_client];
    XCTAssertFalse(VibeFakeDropbox.isInstalled);
    XCTAssertFalse(_client.isLinked);
}

@end

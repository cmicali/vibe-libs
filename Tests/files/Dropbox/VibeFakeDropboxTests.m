//
//  VibeFakeDropboxTests.m
//
//  The fake account as an app's checks use it: the real client and mirror
//  over a directory, with no network. A listing, a download, a dropped
//  connection's resend, a failed download and its retry, offline, a folder
//  listed in pages, and an uninstall that sends nothing. The client's own
//  sessions run over DropboxStubProtocol, which records anything that would
//  have reached Dropbox. The fake's state is process-wide, so only this class
//  drives it.
//

#import <XCTest/XCTest.h>

#include <sys/stat.h>

#import "DropboxMirror.h"
#import "DropboxStubProtocol.h"
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
    // The real sessions: anything sent on them is a request that would have
    // reached Dropbox.
    os_unfair_lock_lock(&sStubLock);
    [sStubRequests removeAllObjects];
    sStubHandler = ^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        return DropboxStubJSON(500, @{});
    };
    os_unfair_lock_unlock(&sStubLock);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[DropboxStubProtocol.class];
    _client = [[DropboxClient alloc] initWithAppKey:@"testkey" keychainService:nil configuration:configuration];
    _mirror = [[DropboxMirror alloc] initWithClient:_client
                                            rootURL:[_temp URLByAppendingPathComponent:@"mirror" isDirectory:YES]
                                     indexAttribute:@"vibe-libs.tests.fake-dropbox"
                                     downloadBudget:1LL << 30];
    [VibeFakeDropbox installWithDirectory:_account transferSeconds:0 client:_client];
}

- (void)tearDown {
    [VibeFakeDropbox uninstallFromClient:_client];
    os_unfair_lock_lock(&sStubLock);
    sStubHandler = nil;
    os_unfair_lock_unlock(&sStubLock);
    [NSFileManager.defaultManager removeItemAtURL:_temp error:NULL];
}

- (NSURL *)list:(NSString *)path error:(NSError **)error {
    XCTestExpectation *listed = [self expectationWithDescription:@"listed"];
    __block NSURL *folder = nil;
    __block NSError *failure = nil;
    [_mirror refreshDropboxFolder:path completion:^(NSURL *folderURL, NSError *listError) {
        folder = folderURL;
        failure = listError;
        [listed fulfill];
    }];
    [self waitForExpectations:@[listed] timeout:10];
    if (error) {
        *error = failure;
    }
    return folder;
}

- (NSURL *)listAlbum {
    NSError *error = nil;
    NSURL *folder = [self list:@"/Album" error:&error];
    XCTAssertNil(error);
    return folder;
}

- (BOOL)fetch:(NSURL *)url {
    XCTestExpectation *fetched = [self expectationWithDescription:@"fetched"];
    __block BOOL ok = NO;
    DropboxMirror *mirror = _mirror;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ok = [mirror fetchPlaceholderAtURL:url onReadable:nil onCancel:^(dispatch_block_t cancel) {} error:NULL];
        [fetched fulfill];
    });
    [self waitForExpectations:@[fetched] timeout:10];
    return ok;
}

// The remote size, and no permissions, so nothing reads it.
- (BOOL)isPlaceholder:(NSURL *)url size:(NSUInteger)size {
    struct stat info;
    return stat(url.fileSystemRepresentation, &info) == 0 && info.st_size == (off_t)size && (info.st_mode & 0777) == 0;
}

- (NSArray<NSURLRequest *> *)realRequests {
    os_unfair_lock_lock(&sStubLock);
    NSArray<NSURLRequest *> *requests = [sStubRequests copy];
    os_unfair_lock_unlock(&sStubLock);
    return requests;
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
    XCTAssertTrue([self isPlaceholder:song size:_song.length]);
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

- (void)testFailedDownloadFailsThenItsRetryDownloads {
    NSURL *song = [[self listAlbum] URLByAppendingPathComponent:@"01 One.flac"];
    XCTAssertTrue([VibeFakeDropbox addFaultOfKind:@"fail" file:@"01 One.flac" after:1 seconds:0 rate:0]);
    XCTAssertFalse([self fetch:song]);
    XCTAssertTrue([self isPlaceholder:song size:_song.length]);
    XCTAssertTrue([self fetch:song]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:song], _song);
}

- (void)testOfflineFailsListingsAndDownloads {
    NSURL *song = [[self listAlbum] URLByAppendingPathComponent:@"01 One.flac"];
    XCTAssertTrue([VibeFakeDropbox addFaultOfKind:@"offline" file:nil after:0 seconds:0 rate:0]);
    NSError *error = nil;
    [self list:@"/Album" error:&error];
    XCTAssertNotNil(error);
    XCTAssertFalse([self fetch:song]);
    XCTAssertTrue([self isPlaceholder:song size:_song.length]);
    [VibeFakeDropbox clearFaults];
    XCTAssertTrue([self fetch:song]);
}

- (void)testFolderLargerThanAPageListsWhole {
    NSURL *big = [_account URLByAppendingPathComponent:@"Big" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:big withIntermediateDirectories:NO attributes:nil
                                                               error:NULL]);
    for (NSUInteger track = 1; track <= 5; track++) {
        NSString *name = [NSString stringWithFormat:@"%02lu Track.flac", (unsigned long)track];
        XCTAssertTrue([PatternBytes(1000) writeToURL:[big URLByAppendingPathComponent:name] atomically:YES]);
    }
    // The tree is indexed at the install, so install again over the new files.
    [VibeFakeDropbox installWithDirectory:_account transferSeconds:0 client:_client];
    [VibeFakeDropbox setListPageSize:2];
    NSError *error = nil;
    NSURL *folder = [self list:@"/Big" error:&error];
    XCTAssertNil(error);
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder.path error:NULL];
    XCTAssertEqual([names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.flac'"]].count,
                   5u);
    XCTAssertEqualObjects(VibeFakeDropbox.statistics[@"requests"][@"/2/files/list_folder/continue"], @2);
}

// An account the fake adopted has no access token, so a sign-out would
// refresh one, then revoke it on the real session.
- (void)testUninstallSendsNothing {
    [VibeFakeDropbox uninstallFromClient:_client];
    XCTAssertFalse(VibeFakeDropbox.isInstalled);
    XCTAssertFalse(_client.isLinked);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    XCTAssertNil(VibeFakeDropbox.statistics[@"requests"][@"/oauth2/token"]);
    XCTAssertEqual([self realRequests].count, 0u);
}

@end

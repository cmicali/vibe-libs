//
//  AudioErrorTests.m
//
//  The play path's error vocabulary: the domain an app pushes, the code, the
//  underlying error, the failing track's URL, and whose error it is.
//

#import <XCTest/XCTest.h>

#import "AudioError.h"

static NSString *const kTestDomain = @"vibe-libs.PlayerTests";

// An app pushes its domain once, at launch. This bundle has no app, so it
// pushes one at image load, before any test can make an error.
__attribute__((constructor)) static void PushTheTestDomain(void) {
    VibeAudioErrorSetDomain(kTestDomain);
}

@interface AudioErrorTests : XCTestCase
@end

@implementation AudioErrorTests

- (void)testAnErrorCarriesThePushedDomainAndItsCode {
    NSError *error = VibeAudioError(VibeAudioErrorFileOpenFailed, @"could not open", nil);
    XCTAssertEqualObjects(VibeAudioErrorDomain(), kTestDomain);
    XCTAssertEqualObjects(error.domain, kTestDomain);
    XCTAssertEqual(error.code, VibeAudioErrorFileOpenFailed);
    XCTAssertEqualObjects(error.localizedDescription, @"could not open");
}

- (void)testAnUnderlyingErrorIsKeptAndNamedInTheDescription {
    NSError *underlying = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50
                                          userInfo:@{NSLocalizedDescriptionKey: @"bad parameter"}];
    NSError *error = VibeAudioError(VibeAudioErrorEngineStartFailed, @"could not start", underlying);
    XCTAssertEqualObjects(error.userInfo[NSUnderlyingErrorKey], underlying);
    XCTAssertEqualObjects(error.localizedDescription, @"could not start (bad parameter)");
}

- (void)testATrackErrorCarriesItsURLAndOnlyThen {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.wav"];
    NSError *error = VibeAudioErrorForTrack(VibeAudioErrorFileOpenTimedOut, @"timed out", nil, url);
    XCTAssertEqualObjects(error.domain, kTestDomain);
    XCTAssertEqual(error.code, VibeAudioErrorFileOpenTimedOut);
    XCTAssertEqualObjects(error.userInfo[kVibeAudioErrorTrackURLKey], url);
    XCTAssertNil(VibeAudioErrorForTrack(VibeAudioErrorNotPlaying, @"idle", nil, nil)
                         .userInfo[kVibeAudioErrorTrackURLKey]);
}

- (void)testEachCodeHasItsKind {
    NSDictionary<NSNumber *, NSNumber *> *kinds = @{
        @(VibeAudioErrorFileOpenFailed): @(VibeAudioErrorKindTrack),
        @(VibeAudioErrorFileOpenTimedOut): @(VibeAudioErrorKindTrack),
        @(VibeAudioErrorConnectionLost): @(VibeAudioErrorKindTrack),
        @(VibeAudioErrorEngineStartFailed): @(VibeAudioErrorKindOutput),
        @(VibeAudioErrorDeviceUnavailable): @(VibeAudioErrorKindOutput),
        @(VibeAudioErrorDeviceInUse): @(VibeAudioErrorKindOutput),
        @(VibeAudioErrorNotPlaying): @(VibeAudioErrorKindNotPlaying),
    };
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.wav"];
    [kinds enumerateKeysAndObjectsUsingBlock:^(NSNumber *code, NSNumber *kind, BOOL *stop) {
        XCTAssertEqual(VibeAudioErrorKindOf(VibeAudioError(code.integerValue, @"e", nil)), kind.integerValue, @"%@", code);
        XCTAssertEqual(VibeAudioErrorKindOf(VibeAudioErrorForTrack(code.integerValue, @"e", nil, url)), kind.integerValue,
                       @"%@", code);
    }];
}

// One code, two owners: the engine says which.
- (void)testAWrappedOutputStartIsTheOutputsAndADecodeTheTracks {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.wav"];
    NSError *inUse = VibeAudioError(VibeAudioErrorDeviceInUse, @"held", nil);
    NSError *start = VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed, @"could not start", inUse, url);
    XCTAssertEqual(VibeAudioErrorKindOf(start), VibeAudioErrorKindOutput);
    NSError *noOutput = VibeAudioError(VibeAudioErrorEngineStartFailed, @"no output", nil);
    XCTAssertEqual(VibeAudioErrorKindOf(VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed, @"could not start",
                                                               noOutput, url)), VibeAudioErrorKindOutput);
    NSError *read = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
    NSError *decode = VibeAudioErrorOfKind(VibeAudioErrorKindTrack, VibeAudioErrorEngineStartFailed, @"could not decode",
                                           read, url);
    XCTAssertEqual(decode.code, VibeAudioErrorEngineStartFailed);
    XCTAssertEqual(VibeAudioErrorKindOf(decode), VibeAudioErrorKindTrack);
    XCTAssertEqualObjects(decode.userInfo[NSUnderlyingErrorKey], read);
    XCTAssertEqualObjects(decode.userInfo[kVibeAudioErrorTrackURLKey], url);
}

- (void)testAnErrorTheEngineDidNotMakeHasNoKind {
    XCTAssertEqual(VibeAudioErrorKindOf(nil), VibeAudioErrorKindUnknown);
    XCTAssertEqual(VibeAudioErrorKindOf([NSError errorWithDomain:kTestDomain code:VibeAudioErrorFileOpenFailed userInfo:nil]),
                   VibeAudioErrorKindUnknown);
    XCTAssertEqual(VibeAudioErrorKindOf([NSError errorWithDomain:NSCocoaErrorDomain code:1
                                                        userInfo:@{kVibeAudioErrorKindKey: @"track"}]),
                   VibeAudioErrorKindUnknown);
}

@end

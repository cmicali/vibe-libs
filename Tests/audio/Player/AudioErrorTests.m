//
//  AudioErrorTests.m
//
//  The play path's error vocabulary: the domain an app pushes, the code, the
//  underlying error, and the failing track's URL.
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

@end

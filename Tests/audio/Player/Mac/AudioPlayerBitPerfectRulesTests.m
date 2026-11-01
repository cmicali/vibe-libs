//
//  AudioPlayerBitPerfectRulesTests.m
//
//  The player's report of bit-perfect output, folded into one status, and when
//  a saved device may bind.
//

#import <XCTest/XCTest.h>

#import "AudioPlayerInternal.h"

@interface AudioPlayerBitPerfectRulesTests : XCTestCase
@end

@implementation AudioPlayerBitPerfectRulesTests

#pragma mark - The fold

// Everything perfect; each test below breaks one input and expects the fold
// to name it.
static VibeBitPerfectReport Perfect(void) {
    return (VibeBitPerfectReport){
        .enabled = YES, .eligibleDevice = YES, .hasTrack = YES,
        .rateExact = YES, .formatConfirmed = YES, .channelsMatch = YES,
        .depthOK = YES, .softwareVolume = 1.0f, .balance = 0.5f, .playerVolume = 1.0f,
        .hogWanted = YES, .exclusive = YES, .sourceBits = 16,
    };
}

- (void)testEverythingPerfectIsActive {
    XCTAssertEqual(VibeBitPerfectFold(Perfect()), VibeBitPerfectStatusActive);
}

- (void)testFailedSwitchIsNotAnUnsupportedRate {
    VibeBitPerfectReport r = Perfect();
    r.rateExact = NO;
    r.formatConfirmed = NO; // the supported rate was requested but never reached
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
    r.formatConfirmed = YES; // a confirmed fallback to an offered multiple
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusRateUnsupported);
}

- (void)testUnconfirmedOutputCannotBeActiveEvenAtTheRightRateAndUnityVolume {
    VibeBitPerfectReport r = Perfect();
    r.formatConfirmed = NO; // wrong route or a failed format/volume/mute read
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
}

// The app is told about a report only when it differs. So every field it
// shows must count. The volume is the one a user moves mid-track.
- (void)testReportEqualityCountsEveryRenderedField {
    XCTAssertTrue(VibeBitPerfectReportsEqual(Perfect(), Perfect()));
    VibeBitPerfectReport r = Perfect();
    r.softwareVolume = 0.5f;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.balance = 0;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.sampleRate = 96000;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.exclusive = NO;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.status = VibeBitPerfectStatusIdle;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.channelsMatch = NO;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.muted = YES;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.playerVolume = 0.5f;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.fileGainScaled = YES;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
}

// A file gain other than 1 changes every sample. It has its own reason, so
// an app never says the volume is below full while it is full.
- (void)testAFileGainHasItsOwnReason {
    VibeBitPerfectReport r = Perfect();
    r.fileGainScaled = YES;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusFileGain);
    r.sourceBits = 0;
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusFileGain);
    r.playerVolume = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
}

- (void)testMuteAndChannelConversionEachPreventAnActiveReport {
    VibeBitPerfectReport r = Perfect();
    r.muted = YES; // volume is still exactly 1.0
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusMuted);
    r = Perfect();
    r.channelsMatch = NO; // rate, precision and every gain check still pass
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusChannelConversion);
}

// One assertion per adjacent pair of the priority order, so a reorder fails:
// each report carries every breaker below it in the order as well.
- (void)testFoldPriority {
    VibeBitPerfectReport r = Perfect();
    r.sourceBits = 0;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSourceLossy);
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusExclusiveRefused);
    r.fileGainScaled = YES;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusFileGain);
    r.playerVolume = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
    r.softwareVolume = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
    r.muted = YES;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusMuted);
    r.depthOK = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusDepthInsufficient);
    r.channelsMatch = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusChannelConversion);
    r.rateExact = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusRateUnsupported);
    r.formatConfirmed = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
    r.hasTrack = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusIdle);
    r.eligibleDevice = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusOff);
    VibeBitPerfectReport off = Perfect();
    off.enabled = NO;
    XCTAssertEqual(VibeBitPerfectFold(off), VibeBitPerfectStatusOff);
}

- (void)testBalanceAwayFromCenterPreventsActiveAtFullVolume {
    VibeBitPerfectReport r = Perfect();
    for (NSNumber *balance in @[@0.0f, @0.25f, @0.75f, @1.0f]) {
        r.balance = balance.floatValue;
        XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
    }
    r.balance = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusActive);
}

- (void)testSharedOutputCanStillBeActive {
    VibeBitPerfectReport r = Perfect();
    r.hogWanted = NO;
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusActive);
}

#pragma mark - Deferred saved-device bind races

// Arguments: stopped, loading, paused, outputRunning, audioActive.
- (void)testSavedDeviceMayBindAtIdleOrSilentLaunchButNotUnderAnOutgoingFade {
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, NO, NO, NO));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, NO, YES, NO));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, YES, NO, NO, NO));
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, YES, NO, YES, YES)); // under an outgoing fade
}

- (void)testSavedDeviceNeverBindsUnderPlayback {
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, NO, YES, YES));
}

// A vanished device parks playback as Paused, so this is the case that decides
// whether it can be re-adopted when it comes back without waiting for a stop.
- (void)testSavedDeviceBindsOnceAPauseHasSettledButNotDuringItsFade {
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, NO, YES, NO, NO));  // idle-stopped
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, NO)); // output running, fade done
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, YES)); // pause fade still audible
}

@end

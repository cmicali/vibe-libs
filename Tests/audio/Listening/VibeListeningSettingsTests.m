//
//  VibeListeningSettingsTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "VibeListeningSettings.h"

@interface VibeListeningSettingsTests : XCTestCase
@end

@implementation VibeListeningSettingsTests

static VibeEQBand *Peak(double hz, double dB, double q) {
    return [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:hz gainDB:dB q:q];
}

static VibeListeningSettings *Edited(void (^edit)(VibeMutableListeningSettings *settings)) {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    edit(settings);
    return [settings copy];
}

#pragma mark - Bands

- (void)testABandHoldsEachValueToItsRange {
    VibeEQBand *band = [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:5 gainDB:40 q:50];
    XCTAssertEqual(band.frequency, 20);
    XCTAssertEqual(band.gainDB, 24);
    XCTAssertEqual(band.q, 10);
    XCTAssertTrue(band.enabled);
    band = [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:30000 gainDB:-40 q:0.01];
    XCTAssertEqual(band.frequency, 20000);
    XCTAssertEqual(band.gainDB, -24);
    XCTAssertEqual(band.q, 0.1);
}

- (void)testABandTakesTheDefaultForAValueThatIsNotANumber {
    VibeEQBand *band = [VibeEQBand bandWithType:(VibeEQBandType)99 frequency:NAN gainDB:INFINITY q:NAN];
    XCTAssertEqual(band.type, VibeEQBandTypePeak);
    XCTAssertEqual(band.frequency, 1000);
    XCTAssertEqual(band.gainDB, 0);
    XCTAssertEqualWithAccuracy(band.q, 0.707, 1e-12);
}

- (void)testBandsCompareByContent {
    XCTAssertEqualObjects(Peak(1000, 3, 1), Peak(1000, 3, 1));
    XCTAssertEqual(Peak(1000, 3, 1).hash, Peak(1000, 3, 1).hash);
    XCTAssertNotEqualObjects(Peak(1000, 3, 1), Peak(1000, 3.5, 1));
    XCTAssertNotEqualObjects(Peak(1000, 3, 1), [Peak(1000, 3, 1) bandWithEnabled:NO]);
}

- (void)testABandIsNeutralOffOrAtZeroDecibels {
    XCTAssertTrue(Peak(1000, 0, 1).neutral);
    XCTAssertTrue([Peak(1000, 6, 1) bandWithEnabled:NO].neutral);
    XCTAssertFalse(Peak(1000, 6, 1).neutral);
    XCTAssertFalse([VibeEQBand bandWithType:VibeEQBandTypeHighPass frequency:80 gainDB:0 q:0.7].neutral);
}

- (void)testABandSurvivesSecureCoding {
    VibeEQBand *band = [[VibeEQBand alloc] initWithType:VibeEQBandTypeHighShelf
                                              frequency:8000
                                                 gainDB:-4.5
                                                      q:0.7
                                                enabled:NO];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:band requiringSecureCoding:YES error:nil];
    VibeEQBand *read = [NSKeyedUnarchiver unarchivedObjectOfClass:[VibeEQBand class] fromData:data error:nil];
    XCTAssertEqualObjects(read, band);
}

#pragma mark - Settings

- (void)testNeutralSettingsAreNeutral {
    VibeListeningSettings *neutral = [VibeListeningSettings neutralSettings];
    XCTAssertTrue(neutral.neutral);
    XCTAssertFalse(neutral.eqEnabled);
    XCTAssertTrue(neutral.preampAutomatic);
    XCTAssertEqual(neutral.bands.count, 0u);
    XCTAssertEqual(neutral.crossfeed, VibeCrossfeedOff);
    XCTAssertEqual(neutral.balance, 0);
    XCTAssertEqual(neutral.effectivePreampDB, 0);
    XCTAssertEqualObjects(neutral, [[VibeListeningSettings alloc] init]);
}

- (void)testEachToolMakesTheSettingsNotNeutral {
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) { s.mono = YES; }).neutral);
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) { s.swapChannels = YES; }).neutral);
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) { s.balance = 0.2; }).neutral);
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) { s.crossfeed = VibeCrossfeedLight; }).neutral);
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) {
                       s.eqEnabled = YES;
                       s.bands = @[Peak(1000, -3, 1)];
                   }).neutral);
    XCTAssertFalse(Edited(^(VibeMutableListeningSettings *s) {
                       s.eqEnabled = YES;
                       s.preampAutomatic = NO;
                       s.preampDB = -3;
                   }).neutral);
}

- (void)testAnEQThatChangesNoSampleIsNeutral {
    // Bands while the EQ is off, an EQ of flat bands, and a manual preamp
    // while the EQ is off.
    XCTAssertTrue(Edited(^(VibeMutableListeningSettings *s) { s.bands = @[Peak(1000, 6, 1)]; }).neutral);
    XCTAssertTrue(Edited(^(VibeMutableListeningSettings *s) {
                      s.eqEnabled = YES;
                      s.bands = [VibeListeningSettings graphicBandsWithGains:@[]];
                  }).neutral);
    XCTAssertTrue(Edited(^(VibeMutableListeningSettings *s) {
                      s.preampAutomatic = NO;
                      s.preampDB = -6;
                  }).neutral);
}

- (void)testTheSettersHoldEachValueToItsRange {
    VibeMutableListeningSettings *settings = [[VibeMutableListeningSettings alloc] init];
    settings.preampDB = 6;
    XCTAssertEqual(settings.preampDB, 0);
    settings.preampDB = -40;
    XCTAssertEqual(settings.preampDB, -24);
    settings.balance = 3;
    XCTAssertEqual(settings.balance, 1);
    settings.balance = NAN;
    XCTAssertEqual(settings.balance, 0);
    settings.crossfeed = (VibeCrossfeed)9;
    XCTAssertEqual(settings.crossfeed, VibeCrossfeedOff);
    NSMutableArray *bands = [NSMutableArray array];
    for (int i = 0; i < 25; i++) {
        [bands addObject:Peak(100 + i, 1, 1)];
    }
    settings.bands = bands;
    XCTAssertEqual(settings.bands.count, kVibeListeningMaxBands);
    XCTAssertEqualObjects(settings.bands.lastObject, Peak(119, 1, 1));
}

- (void)testCopiesAreImmutableAndCompareByContent {
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = @[Peak(1000, 3, 1)];
        s.crossfeed = VibeCrossfeedMedium;
        s.balance = -0.25;
    });
    XCTAssertTrue([settings isMemberOfClass:[VibeListeningSettings class]]);
    XCTAssertEqual([settings copy], settings);
    VibeMutableListeningSettings *edit = [settings mutableCopy];
    XCTAssertEqualObjects(edit, settings);
    XCTAssertEqual(edit.hash, settings.hash);
    edit.mono = YES;
    XCTAssertNotEqualObjects(edit, settings);
    XCTAssertFalse(settings.mono);
}

- (void)testTheEffectivePreampIsTheManualOrTheAutomaticValue {
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = @[Peak(1000, 6, 1)];
        s.preampDB = -2;
    });
    XCTAssertEqualWithAccuracy(settings.effectivePreampDB, -6, 1e-6);
    VibeMutableListeningSettings *manual = [settings mutableCopy];
    manual.preampAutomatic = NO;
    XCTAssertEqual(manual.effectivePreampDB, -2);
    manual.eqEnabled = NO;
    XCTAssertEqual(manual.effectivePreampDB, 0);
}

- (void)testSettingsSurviveSecureCodingAndTheirPropertyList {
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = @[Peak(1000, 3, 1), [VibeEQBand bandWithType:VibeEQBandTypeLowPass frequency:15000 gainDB:0 q:0.7]];
        s.preampAutomatic = NO;
        s.preampDB = -4;
        s.crossfeed = VibeCrossfeedStrong;
        s.mono = YES;
        s.swapChannels = YES;
        s.balance = 0.5;
    });
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:settings requiringSecureCoding:YES error:nil];
    XCTAssertEqualObjects([NSKeyedUnarchiver unarchivedObjectOfClass:[VibeListeningSettings class]
                                                            fromData:data
                                                               error:nil],
                          settings);

    NSDictionary *plist = settings.propertyList;
    XCTAssertTrue([NSPropertyListSerialization propertyList:plist isValidForFormat:NSPropertyListBinaryFormat_v1_0]);
    XCTAssertEqualObjects([[VibeListeningSettings alloc] initWithPropertyList:plist], settings);
}

- (void)testABadPropertyListReadsAsNeutral {
    VibeListeningSettings *neutral = [VibeListeningSettings neutralSettings];
    XCTAssertEqualObjects([[VibeListeningSettings alloc] initWithPropertyList:nil], neutral);
    XCTAssertEqualObjects([[VibeListeningSettings alloc] initWithPropertyList:@"eq"], neutral);
    XCTAssertEqualObjects([[VibeListeningSettings alloc] initWithPropertyList:@{}], neutral);
    NSDictionary *bad = @{
        @"eqEnabled": @"yes",
        @"bands": @[@"peak", @{@"type": @"notch"}, @{@"type": @"peak", @"frequency": @"loud"}],
        @"preampAutomatic": @[],
        @"preampDB": @"-6",
        @"crossfeed": @3,
        @"mono": [NSDate date],
        @"balance": @{},
    };
    VibeListeningSettings *read = [[VibeListeningSettings alloc] initWithPropertyList:bad];
    XCTAssertTrue(read.neutral);
    XCTAssertTrue(read.preampAutomatic);
    XCTAssertEqual(read.crossfeed, VibeCrossfeedOff);
    // The one band with a known type stays, with its bad frequency at the default.
    XCTAssertEqual(read.bands.count, 1u);
    XCTAssertEqual(read.bands.firstObject.frequency, 1000);
}

#pragma mark - The graphic face

- (void)testTheGraphicFaceHasTenPeaks {
    NSArray<VibeEQBand *> *bands = [VibeListeningSettings graphicBandsWithGains:@[@1, @2, @3]];
    XCTAssertEqual(bands.count, 10u);
    XCTAssertEqual(bands[2].gainDB, 3);
    XCTAssertEqual(bands[3].gainDB, 0);
    XCTAssertEqual(bands[9].frequency, 16000);
    XCTAssertEqual(bands[0].q, 1.41);
    VibeListeningSettings *graphic = Edited(^(VibeMutableListeningSettings *s) { s.bands = bands; });
    XCTAssertTrue(graphic.graphic);
    VibeListeningSettings *moved = Edited(^(VibeMutableListeningSettings *s) {
        NSMutableArray *edited = [bands mutableCopy];
        edited[4] = Peak(510, 0, 1.41);
        s.bands = edited;
    });
    XCTAssertFalse(moved.graphic);
    XCTAssertFalse([VibeListeningSettings neutralSettings].graphic);
}

#pragma mark - The response

- (void)testAPeakReachesItsGainAtItsCenter {
    NSArray *bands = @[Peak(1000, 6, 1)];
    for (NSNumber *rate in @[@44100, @48000, @96000]) {
        XCTAssertEqualWithAccuracy(VibeListeningResponseDB(bands, 1000, rate.doubleValue), 6, 1e-9);
        XCTAssertEqualWithAccuracy(VibeListeningResponseDB(bands, 20, rate.doubleValue), 0, 0.05);
    }
}

- (void)testShelvesAndPassFiltersHaveTheirShape {
    VibeEQBand *low = [VibeEQBand bandWithType:VibeEQBandTypeLowShelf frequency:200 gainDB:6 q:0.707];
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[low], 20, 48000), 6, 0.1);
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[low], 200, 48000), 3, 0.01);
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[low], 10000, 48000), 0, 0.05);
    VibeEQBand *high = [VibeEQBand bandWithType:VibeEQBandTypeHighShelf frequency:5000 gainDB:-6 q:0.707];
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[high], 20000, 48000), -6, 0.3);
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[high], 5000, 48000), -3, 0.01);
    // The pass filters ignore the gain, and fall by 3 dB at the corner for a Q of 0.707.
    VibeEQBand *hp = [VibeEQBand bandWithType:VibeEQBandTypeHighPass frequency:100 gainDB:12 q:M_SQRT1_2];
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[hp], 100, 48000), -3.01, 0.01);
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[hp], 5000, 48000), 0, 0.01);
    VibeEQBand *lp = [VibeEQBand bandWithType:VibeEQBandTypeLowPass frequency:5000 gainDB:12 q:M_SQRT1_2];
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(@[lp], 5000, 48000), -3.01, 0.01);
    XCTAssertLessThan(VibeListeningResponseDB(@[lp], 20000, 48000), -20);
}

- (void)testTheResponseSumsTheEnabledBands {
    NSArray *bands = @[Peak(1000, 6, 1), Peak(1000, 3, 1), [Peak(1000, 12, 1) bandWithEnabled:NO]];
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(bands, 1000, 48000), 9, 1e-9);
}

- (void)testTheAutomaticPreampCutsTheHighestBoost {
    XCTAssertEqual(VibeListeningAutomaticPreampDB(@[]), 0);
    XCTAssertEqual(VibeListeningAutomaticPreampDB(@[Peak(1000, -6, 1)]), 0);
    XCTAssertEqualWithAccuracy(VibeListeningAutomaticPreampDB(@[Peak(1000, 6, 1)]), -6, 1e-6);
    // A narrow peak between two grid points still counts in full.
    XCTAssertEqualWithAccuracy(VibeListeningAutomaticPreampDB(@[Peak(1234.5, 9, 10)]), -9, 1e-4);
    // Two overlapping boosts sum.
    NSArray *overlap = @[Peak(1000, 4, 0.5), Peak(1100, 4, 0.5)];
    double peak = -INFINITY;
    for (double hz = 900; hz < 1200; hz += 0.5) {
        peak = fmax(peak, VibeListeningResponseDB(overlap, hz, 48000));
    }
    XCTAssertEqualWithAccuracy(VibeListeningAutomaticPreampDB(overlap), -peak, 1e-3);
}

@end

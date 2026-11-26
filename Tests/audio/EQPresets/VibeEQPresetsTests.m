//
//  VibeEQPresetsTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "VibeEQPresetFile.h"
#import "VibeEQPresetLibrary.h"

@interface VibeEQPresetsTests : XCTestCase
@end

@implementation VibeEQPresetsTests

// The layout of AutoEQ's ParametricEQ.txt, with values written for this test.
static NSString *const kAutoEQText = @"Preamp: -5.4 dB\n"
                                     @"Filter 1: ON LSC Fc 105 Hz Gain 5.2 dB Q 0.70\n"
                                     @"Filter 2: ON PK Fc 2140 Hz Gain -2.8 dB Q 1.95\n"
                                     @"Filter 3: ON PK Fc 61 Hz Gain 0.9 dB Q 2.31\n"
                                     @"Filter 4: ON HSC Fc 10000 Hz Gain -1.6 dB Q 0.70\n";

static VibeEQBand *Band(VibeEQBandType type, double hz, double dB, double q) {
    return [VibeEQBand bandWithType:type frequency:hz gainDB:dB q:q];
}

static VibeEQPreset *Headphone(NSString *name) {
    return [[VibeEQPreset alloc] initWithIdentifier:[@"test." stringByAppendingString:name]
                                               name:name
                                               kind:VibeEQPresetKindHeadphone
                                             source:@"Test Lab"
                                              bands:@[ Band(VibeEQBandTypePeak, 1000, -2, 1) ]
                                           preampDB:-2];
}

- (NSArray<NSString *> *)namesFromSearch:(NSString *)query limit:(NSUInteger)limit library:(VibeEQPresetLibrary *)library {
    XCTestExpectation *done = [self expectationWithDescription:@"search"];
    __block NSArray<NSString *> *names;
    [library searchHeadphones:query
                        limit:limit
                   completion:^(NSArray<VibeEQPreset *> *results) {
                       XCTAssertTrue(NSThread.isMainThread);
                       names = [results valueForKey:@"name"];
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:10];
    return names;
}

#pragma mark - Reading

- (void)testItReadsAutoEQsParametricText {
    NSError *error;
    VibeEQPreset *preset = [VibeEQPresetFile presetFromEqualizerAPOText:kAutoEQText name:@"Mine" error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(preset.name, @"Mine");
    XCTAssertEqual(preset.kind, VibeEQPresetKindUser);
    XCTAssertTrue([preset.identifier hasPrefix:@"user."]);
    XCTAssertNil(preset.source);
    XCTAssertEqual(preset.preampDB, -5.4);
    NSArray *expected = @[
        Band(VibeEQBandTypeLowShelf, 105, 5.2, 0.7), Band(VibeEQBandTypePeak, 2140, -2.8, 1.95),
        Band(VibeEQBandTypePeak, 61, 0.9, 2.31), Band(VibeEQBandTypeHighShelf, 10000, -1.6, 0.7)
    ];
    XCTAssertEqualObjects(preset.bands, expected);
}

- (void)testItReadsEveryFilterTypeAndOff {
    NSString *text = @"Filter 1: ON PEQ Fc 100 Hz Gain 1 dB Q 1\n"
                     @"Filter 2: OFF LS Fc 200 Hz Gain 2 dB Q 0.5\n"
                     @"Filter 3: ON HS Fc 8000 Hz Gain -2 dB Q 0.5\n"
                     @"Filter 4: ON LP Fc 18000 Hz\n"
                     @"Filter 5: ON LPQ Fc 16000 Hz Q 0.9\n"
                     @"Filter 6: ON HP Fc 25 Hz\n"
                     @"Filter 7: ON HPQ Fc 30 Hz Q 1.2\n"
                     @"Filter: on pk fc 500 hz gain 3 db q 2\r\n";
    VibeEQPreset *preset = [VibeEQPresetFile presetFromEqualizerAPOText:text name:@"All" error:NULL];
    NSArray *expected = @[
        Band(VibeEQBandTypePeak, 100, 1, 1),
        [[VibeEQBand alloc] initWithType:VibeEQBandTypeLowShelf frequency:200 gainDB:2 q:0.5 enabled:NO],
        Band(VibeEQBandTypeHighShelf, 8000, -2, 0.5), Band(VibeEQBandTypeLowPass, 18000, 0, 0.707),
        Band(VibeEQBandTypeLowPass, 16000, 0, 0.9), Band(VibeEQBandTypeHighPass, 25, 0, 0.707),
        Band(VibeEQBandTypeHighPass, 30, 0, 1.2), Band(VibeEQBandTypePeak, 500, 3, 2)
    ];
    XCTAssertEqualObjects(preset.bands, expected);
    XCTAssertEqual(preset.preampDB, 0);
}

- (void)testItSkipsWhatItCantReadAndNeverThrows {
    NSString *text = @"# a comment\n"
                     @"Device: all\n"
                     @"Preamp: loud dB\n"
                     @"Filter 1: ON Modal Fc 100 Hz Gain 1 dB Q 1\n"
                     @"Filter 2: MAYBE PK Fc 100 Hz Gain 1 dB Q 1\n"
                     @"Filter 3: ON PK Gain 1 dB Q 1\n"
                     @"Filter 4: ON PK Fc 1,5 Hz Gain 1 dB Q 1\n"
                     @"Filter 5: ON PK Fc nan Hz Gain 1 dB Q 1\n"
                     @"Filter 6: ON PK Fc 300 Hz Gain x dB Q 1\n"
                     @"Filter 7:\n"
                     @"Filter 8: ON PK Fc 90000 Hz Gain 99 dB Q 0\n";
    VibeEQPreset *preset = [VibeEQPresetFile presetFromEqualizerAPOText:text name:@"Odd" error:NULL];
    NSArray *expected = @[ Band(VibeEQBandTypePeak, 300, 0, 1), Band(VibeEQBandTypePeak, 20000, 24, 0.1) ];
    XCTAssertEqualObjects(preset.bands, expected);
    XCTAssertEqual(preset.preampDB, 0);

    for (NSString *bad in @[ @"", @"\n\n", @"Preamp: -3 dB\n", @"garbage", @"Filter 1: ON", @"Filter 1: ON PK:::" ]) {
        NSError *error;
        XCTAssertNil([VibeEQPresetFile presetFromEqualizerAPOText:bad name:@"Bad" error:&error]);
        XCTAssertEqualObjects(error.domain, VibeEQPresetFileErrorDomain);
        XCTAssertEqual(error.code, VibeEQPresetFileErrorNoFilters);
    }
    XCTAssertNil([VibeEQPresetFile presetFromEqualizerAPOText:@"" name:@"Bad" error:NULL]);
}

- (void)testItReadsAFileThatStartsWithAByteOrderMark {
    NSString *text = [@"\uFEFF" stringByAppendingString:kAutoEQText];
    XCTAssertEqual([VibeEQPresetFile presetFromEqualizerAPOText:text name:@"BOM" error:NULL].preampDB, -5.4);
}

- (void)testItReadsAtMostTwentyFiltersAndHoldsThePreampToItsRange {
    NSMutableString *text = [NSMutableString stringWithString:@"Preamp: 6 dB\n"];
    for (int i = 1; i <= 25; i++) {
        [text appendFormat:@"Filter %d: ON PK Fc %d Hz Gain 1 dB Q 1\n", i, i * 100];
    }
    VibeEQPreset *preset = [VibeEQPresetFile presetFromEqualizerAPOText:text name:@"Many" error:NULL];
    XCTAssertEqual(preset.bands.count, 20u);
    XCTAssertEqual(preset.bands.lastObject.frequency, 2000);
    XCTAssertEqual(preset.preampDB, 0);
    preset = [VibeEQPresetFile presetFromEqualizerAPOText:@"Preamp: -40 dB\nFilter: ON PK Fc 1000 Hz" name:@"Cut" error:NULL];
    XCTAssertEqual(preset.preampDB, -24);
}

#pragma mark - Writing

- (void)testWritingReadsBackToTheSameBands {
    NSArray *bands = @[
        Band(VibeEQBandTypePeak, 1000.5, -3.1, 0.707), Band(VibeEQBandTypeLowShelf, 105, 6.4, 0.7),
        Band(VibeEQBandTypeHighShelf, 10000, -2.1, 0.7), Band(VibeEQBandTypeLowPass, 18000, 0, 0.5),
        [[VibeEQBand alloc] initWithType:VibeEQBandTypeHighPass frequency:25 gainDB:0 q:1.2 enabled:NO]
    ];
    VibeEQPreset *preset = [[VibeEQPreset alloc] initWithIdentifier:@"x"
                                                               name:@"Round"
                                                               kind:VibeEQPresetKindUser
                                                             source:nil
                                                              bands:bands
                                                           preampDB:-6.25];
    NSString *text = [VibeEQPresetFile equalizerAPOTextForPreset:preset];
    XCTAssertEqualObjects(text, @"Preamp: -6.25 dB\n"
                                @"Filter 1: ON PK Fc 1000.5 Hz Gain -3.1 dB Q 0.707\n"
                                @"Filter 2: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.7\n"
                                @"Filter 3: ON HSC Fc 10000 Hz Gain -2.1 dB Q 0.7\n"
                                @"Filter 4: ON LPQ Fc 18000 Hz Q 0.5\n"
                                @"Filter 5: OFF HPQ Fc 25 Hz Q 1.2\n");
    VibeEQPreset *read = [VibeEQPresetFile presetFromEqualizerAPOText:text name:@"Round" error:NULL];
    XCTAssertEqualObjects(read.bands, bands);
    XCTAssertEqual(read.preampDB, -6.25);

    VibeEQPreset *autoEQ = [VibeEQPresetFile presetFromEqualizerAPOText:kAutoEQText name:@"A" error:NULL];
    NSString *again = [VibeEQPresetFile equalizerAPOTextForPreset:autoEQ];
    XCTAssertEqualObjects([VibeEQPresetFile presetFromEqualizerAPOText:again name:@"A" error:NULL].bands, autoEQ.bands);
}

- (void)testWritingUsesAPointInAnyLocale {
    VibeEQPreset *preset = [[VibeEQPreset alloc] initWithIdentifier:@"x"
                                                               name:@"P"
                                                               kind:VibeEQPresetKindUser
                                                             source:nil
                                                              bands:@[ Band(VibeEQBandTypePeak, 100, -0.0001, 1) ]
                                                           preampDB:-0.0001];
    XCTAssertEqualObjects([VibeEQPresetFile equalizerAPOTextForPreset:preset],
                          @"Preamp: 0 dB\nFilter 1: ON PK Fc 100 Hz Gain 0 dB Q 1\n");
}

#pragma mark - Presets

- (void)testTheBuiltInsAreTheGraphicFace {
    VibeEQPresetLibrary *library = [VibeEQPresetLibrary sharedLibrary];
    XCTAssertEqualObjects([library.builtInPresets valueForKey:@"name"],
                          (@[ @"Flat", @"Bass Boost", @"Treble Boost", @"Vocal", @"Loudness", @"Bass Cut" ]));
    XCTAssertEqualObjects([library.builtInPresets valueForKey:@"identifier"],
                          (@[ @"builtin.flat", @"builtin.bass-boost", @"builtin.treble-boost", @"builtin.vocal",
                              @"builtin.loudness", @"builtin.bass-cut" ]));
    for (VibeEQPreset *preset in library.builtInPresets) {
        XCTAssertEqual(preset.kind, VibeEQPresetKindBuiltIn);
        XCTAssertNil(preset.source);
        XCTAssertEqual(preset.preampDB, 0);
        XCTAssertTrue([preset applyingToSettings:[VibeListeningSettings neutralSettings]
                                      sampleRate:kVibeListeningPreviewRate].isGraphic, @"%@", preset.name);
    }
    VibeEQPreset *flat = library.builtInPresets.firstObject;
    XCTAssertTrue([flat applyingToSettings:[VibeListeningSettings neutralSettings]
                                sampleRate:kVibeListeningPreviewRate].isNeutral);
    VibeEQPreset *bassBoost = library.builtInPresets[1];
    XCTAssertGreaterThan(VibeListeningResponseDB(bassBoost.bands, 40, 48000), 4);
    XCTAssertEqualWithAccuracy(VibeListeningResponseDB(bassBoost.bands, 8000, 48000), 0, 0.5);
    VibeEQPreset *bassCut = library.builtInPresets[5];
    XCTAssertLessThan(VibeListeningResponseDB(bassCut.bands, 40, 48000), -4);
}

- (void)testApplyingKeepsEverythingButTheEQ {
    VibeMutableListeningSettings *start = [[VibeListeningSettings neutralSettings] mutableCopy];
    start.crossfeed = VibeCrossfeedMedium;
    start.mono = YES;
    start.balance = 0.25;
    start.preampAutomatic = NO;
    start.preampDB = -3;
    VibeEQPreset *bassBoost = [VibeEQPresetLibrary sharedLibrary].builtInPresets[1];
    VibeListeningSettings *applied = [bassBoost applyingToSettings:start sampleRate:kVibeListeningPreviewRate];
    XCTAssertTrue(applied.eqEnabled);
    XCTAssertEqualObjects(applied.bands, bassBoost.bands);
    XCTAssertTrue(applied.preampAutomatic);
    XCTAssertEqual(applied.crossfeed, VibeCrossfeedMedium);
    XCTAssertTrue(applied.mono);
    XCTAssertEqual(applied.balance, 0.25);
    XCTAssertFalse([applied isKindOfClass:[VibeMutableListeningSettings class]]);
}

- (void)testAHeadphonesPreampTurnsManualOnlyWhenItCutsMore {
    NSArray *bands = @[ Band(VibeEQBandTypePeak, 1000, 4, 1) ];
    double automatic = VibeListeningAutomaticPreampDBAtRate(bands, kVibeListeningPreviewRate);
    VibeEQPreset *deeper = [[VibeEQPreset alloc] initWithIdentifier:@"a"
                                                               name:@"A"
                                                               kind:VibeEQPresetKindHeadphone
                                                             source:@"Lab"
                                                              bands:bands
                                                           preampDB:automatic - 2];
    VibeListeningSettings *applied = [deeper applyingToSettings:[VibeListeningSettings neutralSettings]
                                                     sampleRate:kVibeListeningPreviewRate];
    XCTAssertFalse(applied.preampAutomatic);
    XCTAssertEqualWithAccuracy(applied.preampDB, automatic - 2, 1e-9);

    VibeEQPreset *shallower = [[VibeEQPreset alloc] initWithIdentifier:@"b"
                                                                  name:@"B"
                                                                  kind:VibeEQPresetKindHeadphone
                                                                source:@"Lab"
                                                                 bands:bands
                                                              preampDB:-1];
    XCTAssertTrue([shallower applyingToSettings:[VibeListeningSettings neutralSettings]
                                     sampleRate:kVibeListeningPreviewRate].preampAutomatic);
}

- (void)testAPresetCodesAndCompares {
    VibeEQPreset *preset = Headphone(@"Coded");
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:preset requiringSecureCoding:YES error:NULL];
    VibeEQPreset *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[VibeEQPreset class] fromData:data error:NULL];
    XCTAssertEqualObjects(decoded, preset);
    XCTAssertEqual(decoded.hash, preset.hash);
    XCTAssertEqualObjects(decoded.source, @"Test Lab");
    XCTAssertNotEqualObjects(Headphone(@"Other"), preset);
}

- (void)testAPresetRoundTripsThroughItsPropertyList {
    VibeEQPreset *headphone = Headphone(@"Listed");
    XCTAssertEqualObjects([[VibeEQPreset alloc] initWithPropertyList:headphone.propertyList], headphone);
    VibeEQPreset *builtIn = [VibeEQPresetLibrary sharedLibrary].builtInPresets[3];
    XCTAssertEqualObjects([[VibeEQPreset alloc] initWithPropertyList:builtIn.propertyList], builtIn);
    XCTAssertNil(builtIn.propertyList[@"source"]);
    XCTAssertTrue([NSPropertyListSerialization propertyList:headphone.propertyList
                                           isValidForFormat:NSPropertyListBinaryFormat_v1_0]);
}

- (void)testABadPropertyListReadsAsNil {
    NSDictionary *good = Headphone(@"Good").propertyList;
    XCTAssertNil([[VibeEQPreset alloc] initWithPropertyList:nil]);
    XCTAssertNil([[VibeEQPreset alloc] initWithPropertyList:@"preset"]);
    XCTAssertNil([[VibeEQPreset alloc] initWithPropertyList:@{}]);
    for (NSString *key in @[ @"identifier", @"name", @"kind" ]) {
        NSMutableDictionary *missing = [good mutableCopy];
        [missing removeObjectForKey:key];
        XCTAssertNil([[VibeEQPreset alloc] initWithPropertyList:missing], @"%@", key);
        NSMutableDictionary *wrong = [good mutableCopy];
        wrong[key] = @42;
        XCTAssertNil([[VibeEQPreset alloc] initWithPropertyList:wrong], @"%@", key);
    }
    NSMutableDictionary *odd = [good mutableCopy];
    odd[@"source"] = @7;
    odd[@"bands"] = @[ @"not a band", @{@"type" : @"nope"} ];
    odd[@"preampDB"] = @"loud";
    VibeEQPreset *read = [[VibeEQPreset alloc] initWithPropertyList:odd];
    XCTAssertNil(read.source);
    XCTAssertEqualObjects(read.bands, @[]);
    XCTAssertEqual(read.preampDB, 0);
}

- (void)testAUserPresetComesFromTheSettings {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    settings.eqEnabled = YES;
    settings.bands = @[ Band(VibeEQBandTypePeak, 1000, 5, 1), Band(VibeEQBandTypeLowShelf, 100, -3, 0.7) ];
    VibeEQPreset *automatic = [VibeEQPreset presetWithName:@"Mine" settings:settings];
    XCTAssertEqualObjects(automatic.name, @"Mine");
    XCTAssertEqual(automatic.kind, VibeEQPresetKindUser);
    XCTAssertTrue([automatic.identifier hasPrefix:@"user."]);
    XCTAssertEqualObjects(automatic.bands, settings.bands);
    XCTAssertEqualWithAccuracy(automatic.preampDB,
                               VibeListeningAutomaticPreampDBAtRate(settings.bands, kVibeListeningPreviewRate), 1e-9);
    XCTAssertTrue([automatic matchesSettings:settings sampleRate:kVibeListeningPreviewRate]);
    XCTAssertTrue([[automatic applyingToSettings:settings sampleRate:kVibeListeningPreviewRate] preampAutomatic]);

    settings.preampAutomatic = NO;
    settings.preampDB = -12;
    VibeEQPreset *manual = [VibeEQPreset presetWithName:@"Quiet" settings:settings];
    XCTAssertEqual(manual.preampDB, -12);
    XCTAssertTrue([manual matchesSettings:settings sampleRate:kVibeListeningPreviewRate]);
    XCTAssertNotEqualObjects(manual.identifier, automatic.identifier);

    // A manual preamp that cuts less than the automatic one still matches the
    // settings it came from, though applying it turns the preamp automatic.
    settings.preampDB = 0;
    VibeEQPreset *loud = [VibeEQPreset presetWithName:@"Loud" settings:settings];
    XCTAssertEqual(loud.preampDB, 0);
    XCTAssertTrue([loud matchesSettings:settings sampleRate:kVibeListeningPreviewRate]);
    XCTAssertTrue([loud applyingToSettings:settings sampleRate:kVibeListeningPreviewRate].preampAutomatic);
}

// The automatic preamp for a treble boost differs at each rate. A preset saved
// with it stays automatic and keeps its name at every rate.
- (void)testAPresetSavedAsAutomaticStaysAutomaticAtEveryRate {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    settings.eqEnabled = YES;
    settings.bands = [VibeListeningSettings graphicBandsWithGains:@[ @0, @0, @0, @0, @0, @0, @1, @3, @5, @6 ]];
    VibeEQPreset *preset = [VibeEQPreset presetWithName:@"Mine" settings:settings];
    XCTAssertGreaterThan(VibeListeningAutomaticPreampDBAtRate(settings.bands, 44100), preset.preampDB + 0.05);
    XCTAssertLessThan(VibeListeningAutomaticPreampDBAtRate(settings.bands, 96000), preset.preampDB - 0.4);
    for (NSNumber *rate in @[ @22050, @44100, @48000, @96000, @192000 ]) {
        XCTAssertTrue([preset matchesSettings:settings sampleRate:rate.doubleValue], @"%@", rate);
        XCTAssertTrue([preset applyingToSettings:settings sampleRate:rate.doubleValue].preampAutomatic, @"%@", rate);
    }
    // One saved as manual stays manual where it cuts more than automatic does.
    settings.preampAutomatic = NO;
    settings.preampDB = -9;
    VibeEQPreset *quiet = [VibeEQPreset presetWithName:@"Quiet" settings:settings];
    for (NSNumber *rate in @[ @44100, @192000 ]) {
        VibeListeningSettings *applied = [quiet applyingToSettings:settings sampleRate:rate.doubleValue];
        XCTAssertFalse(applied.preampAutomatic, @"%@", rate);
        XCTAssertEqual(applied.preampDB, -9);
    }
}

- (void)testAPresetMatchesOnlySettingsItWouldMake {
    VibeEQPreset *bassBoost = [VibeEQPresetLibrary sharedLibrary].builtInPresets[1];
    VibeListeningSettings *neutral = [VibeListeningSettings neutralSettings];
    const double rate = kVibeListeningPreviewRate;
    VibeListeningSettings *applied = [bassBoost applyingToSettings:neutral sampleRate:rate];
    XCTAssertTrue([bassBoost matchesSettings:applied sampleRate:rate]);
    XCTAssertFalse([bassBoost matchesSettings:neutral sampleRate:rate]);
    XCTAssertFalse([[VibeEQPresetLibrary sharedLibrary].builtInPresets[0] matchesSettings:applied sampleRate:rate]);

    VibeMutableListeningSettings *edited = [applied mutableCopy];
    edited.crossfeed = VibeCrossfeedStrong;
    XCTAssertTrue([bassBoost matchesSettings:edited sampleRate:rate], @"the channel tools don't count");
    edited.eqEnabled = NO;
    XCTAssertFalse([bassBoost matchesSettings:edited sampleRate:rate]);
    edited.eqEnabled = YES;
    edited.preampAutomatic = NO;
    edited.preampDB = -20;
    XCTAssertFalse([bassBoost matchesSettings:edited sampleRate:rate]);
    // A manual preamp at the automatic value plays the same, so it matches.
    edited.preampDB = VibeListeningAutomaticPreampDBAtRate(bassBoost.bands, rate);
    XCTAssertTrue([bassBoost matchesSettings:edited sampleRate:rate]);
    edited.preampAutomatic = YES;
    edited.bands = [VibeListeningSettings graphicBandsWithGains:@[ @6, @5, @4, @2, @0, @0, @0, @0, @0, @1 ]];
    XCTAssertFalse([bassBoost matchesSettings:edited sampleRate:rate]);

    // A preset that applies a manual preamp matches only that preamp.
    VibeEQPreset *quiet = [[VibeEQPreset alloc] initWithIdentifier:@"q"
                                                              name:@"Q"
                                                              kind:VibeEQPresetKindHeadphone
                                                            source:@"Lab"
                                                             bands:bassBoost.bands
                                                          preampDB:-20];
    edited.bands = bassBoost.bands;
    XCTAssertFalse([quiet matchesSettings:edited sampleRate:rate], @"automatic");
    edited.preampAutomatic = NO;
    edited.preampDB = VibeListeningAutomaticPreampDBAtRate(bassBoost.bands, rate);
    XCTAssertFalse([quiet matchesSettings:edited sampleRate:rate], @"manual at the automatic value");
    edited.preampDB = -20;
    XCTAssertTrue([quiet matchesSettings:edited sampleRate:rate]);
}

#pragma mark - Search

- (void)testTheSharedLibraryHoldsNoHeadphones {
    VibeEQPresetLibrary *library = [VibeEQPresetLibrary sharedLibrary];
    XCTAssertEqualObjects([self namesFromSearch:@"" limit:0 library:library], @[]);
    XCTAssertEqualObjects([self namesFromSearch:@"Sennheiser" limit:10 library:library], @[]);
    XCTAssertNil([library headphoneWithIdentifier:@"anything"]);
}

- (void)testSearchRanksPrefixThenWordThenContainsThenEveryWord {
    NSArray *names = @[
        @"Sennheiser HD 650", @"Sennheiser HD 600", @"AKG K371", @"Beyerdynamic DT 770 Pro", @"Vision Ears Erlkönig",
        @"HDX Studio", @"Philips Fidelio X2HD", @"Moondrop HDR", @"Apple AirPods Pro", @"RØDE NTH-100"
    ];
    VibeEQPresetLibrary *library = [[VibeEQPresetLibrary alloc] initWithHeadphonesLoader:^NSArray<VibeEQPreset *> * {
        NSMutableArray *presets = [NSMutableArray array];
        for (NSString *name in names) {
            [presets addObject:Headphone(name)];
        }
        return presets;
    }];
    XCTAssertEqualObjects([self namesFromSearch:@"hd" limit:0 library:library],
                          (@[ @"HDX Studio", @"Moondrop HDR", @"Sennheiser HD 600", @"Sennheiser HD 650", @"Philips Fidelio X2HD" ]));
    XCTAssertEqualObjects([self namesFromSearch:@"  SENNHEISER hd 6 " limit:0 library:library],
                          (@[ @"Sennheiser HD 600", @"Sennheiser HD 650" ]));
    XCTAssertEqualObjects([self namesFromSearch:@"pro" limit:0 library:library],
                          (@[ @"Apple AirPods Pro", @"Beyerdynamic DT 770 Pro" ]));
    XCTAssertEqualObjects([self namesFromSearch:@"erlkonig" limit:0 library:library], @[ @"Vision Ears Erlkönig" ]);
    XCTAssertEqualObjects([self namesFromSearch:@"nth" limit:0 library:library], @[ @"RØDE NTH-100" ]);
    XCTAssertEqualObjects([self namesFromSearch:@"rode" limit:0 library:library], @[ @"RØDE NTH-100" ]);
    XCTAssertEqualObjects([self namesFromSearch:@"650 sennheiser" limit:0 library:library], @[ @"Sennheiser HD 650" ]);
    XCTAssertEqualObjects([self namesFromSearch:@"hd" limit:2 library:library], (@[ @"HDX Studio", @"Moondrop HDR" ]));
    XCTAssertEqualObjects([self namesFromSearch:@"zzz" limit:0 library:library], @[]);
    XCTAssertEqual([self namesFromSearch:@"" limit:0 library:library].count, names.count);
    XCTAssertEqualObjects([self namesFromSearch:@"" limit:1 library:library], @[ @"AKG K371" ]);
    XCTAssertEqualObjects([library headphoneWithIdentifier:@"test.AKG K371"].name, @"AKG K371");
    XCTAssertNil([library headphoneWithIdentifier:@"test.missing"]);
}

- (void)testSearchIsFastOverFiveThousandHeadphones {
    __block NSUInteger loads = 0;
    VibeEQPresetLibrary *library = [[VibeEQPresetLibrary alloc] initWithHeadphonesLoader:^NSArray<VibeEQPreset *> * {
        loads++;
        NSMutableArray *presets = [NSMutableArray array];
        for (int i = 0; i < 5000; i++) {
            [presets addObject:Headphone([NSString stringWithFormat:@"Model %d Édition", i])];
        }
        return presets;
    }];
    [self namesFromSearch:@"warm up" limit:1 library:library];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSArray *names = [self namesFromSearch:@"model 49" limit:0 library:library];
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
    // 49, 490 to 499, and 4900 to 4999 start with it. Every other number with
    // 49 in it holds both words.
    NSUInteger holding = 0;
    for (int i = 0; i < 5000; i++) {
        holding += [[NSString stringWithFormat:@"%d", i] containsString:@"49"];
    }
    XCTAssertEqual(names.count, holding);
    for (NSUInteger i = 0; i < names.count; i++) {
        XCTAssertEqual([names[i] hasPrefix:@"Model 49"], i < 111, @"%@", names[i]);
    }
    XCTAssertEqual(loads, 1u);
    XCTAssertLessThan(elapsed, 0.25);
    XCTAssertEqual([self namesFromSearch:@"edition" limit:10 library:library].count, 10u);
}

@end

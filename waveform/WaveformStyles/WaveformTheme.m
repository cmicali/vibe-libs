//
//  WaveformTheme.m
//  vibe-libs
//

#import "WaveformTheme.h"
#import "PlatformColor.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

// The target change in weighted RGB brightness, limited by the contrast pole.
static const CGFloat kHoverLuminanceDelta = 0.25;

// The built-in themes' resting alpha levels.
static const CGFloat kMonochromePlayedAlpha = 0.75;
static const CGFloat kMonochromeUnplayedAlpha = 0.375;
static const CGFloat kColoredUnplayedAlpha = 0.89;

// Nearly gray artwork falls back to Mono. The clamp uses weighted RGB
// brightness. HSB brightness would accept a dark pure blue.
static const CGFloat kArtworkSaturationFloor = 0.15;
static const CGFloat kArtworkDarkMinLuminance = 0.55;
static const CGFloat kArtworkLightMaxLuminance = 0.45;

// Toward the color's own luminance gray, which leaves the clamp above intact.
static const CGFloat kArtworkUnplayedDesaturation = 0.5;

// Seven opaque fills in painter's order. Shaded overlaps darken low+mid
// and tint combinations with highs toward the lower bands. Unshaded highs
// blend in 6% of the bands beneath them.
static const CGFloat kBandLowMidShade = 0.3;
static const CGFloat kBandHighTintDark = 0.18;
static const CGFloat kBandHighTintLight = 0.35;
static const CGFloat kBandAllThreeTint = 0.6;
static const CGFloat kBandHighTintUnshaded = 0.06;

static NSArray<VibeColor *> *VibeBandColors(VibeColor *low, VibeColor *mid, VibeColor *high, BOOL shade,
                                            BOOL isDark) {
    VibeColor *lowMid = shade ? VibeColorBlended(mid, [VibeColor blackColor], kBandLowMidShade) : mid;
    CGFloat tint = !shade ? kBandHighTintUnshaded : isDark ? kBandHighTintDark : kBandHighTintLight;
    return @[low, mid, high, lowMid, VibeColorBlended(high, low, tint), VibeColorBlended(high, mid, tint),
             VibeColorBlended(high, lowMid, shade ? tint * kBandAllThreeTint : tint)];
}

// The built-in palettes. Rekord Bin's is shaded. A theme draws it until it
// sets its own bands, and an app's theme editor may show it for unset bands.
// Dengine's is Engine DJ's deck, unshaded; its dark bands are the Dengine theme's, and its
// light ones darken the mid and the high so they read on white.
static NSArray<VibeColor *> *VibeBuiltInBandColors(BOOL dengine, BOOL isDark) {
    static NSArray<VibeColor *> *colors[2][2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger dark = 0; dark < 2; dark++) {
            VibeColor *high = VibeColorFromHexString(dark ? @"FFFFFF" : @"262626");
            colors[0][dark] = VibeBandColors(VibeColorFromHexString(@"0055E1"),
                                             VibeColorFromHexString(dark ? @"FFA600" : @"D97706"),
                                             high, YES, dark);
            colors[1][dark] = VibeBandColors(VibeColorFromHexString(@"2F69E0"),
                                             VibeColorFromHexString(dark ? @"4CDF80" : @"16A34A"),
                                             high, NO, dark);
        }
    });
    return colors[dengine ? 1 : 0][isDark ? 1 : 0];
}

// RGB's highs lean toward cyan to remain visible on black.
// Each palette's light set is darker for white backgrounds.
// TRAP: Blue's and Green's low stands farthest from the background, light
// on dark and dark on white. Most music is mostly low, so a low near the
// background hides the whole waveform.
static NSArray<VibeColor *> *VibeBuiltInSpectrumColors(NSString *palette, BOOL isDark) {
    static NSDictionary<NSString *, NSArray<NSArray<VibeColor *> *> *> *palettes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Per palette, the light set and then the dark one, each low to high.
        NSDictionary<NSString *, NSArray<NSArray<NSString *> *> *> *hex = @{
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB: @[@[@"D8300F", @"15802A", @"2A60E0"],
                                                            @[@"FF4018", @"30C828", @"5296FF"]],
            // The dark set is the Kinda Blue theme's buttons, info line and artist.
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE: @[@[@"134E6C", @"0075A3", @"367396"],
                                                             @[@"A8D8F0", @"00A8E8", @"3F86B0"]],
            // Blue's lightness at a green hue.
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN: @[@[@"136C38", @"008A3A", @"2F8050"],
                                                              @[@"A8F0C6", @"00C060", @"3F9A68"]],
        };
        NSMutableDictionary *built = [NSMutableDictionary dictionary];
        [hex enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSArray<NSArray<NSString *> *> *sets, BOOL *stop) {
            NSMutableArray *colorSets = [NSMutableArray array];
            for (NSArray<NSString *> *set in sets) {
                [colorSets addObject:@[VibeColorFromHexString(set[0]), VibeColorFromHexString(set[1]),
                                       VibeColorFromHexString(set[2])]];
            }
            built[name] = colorSets;
        }];
        palettes = built;
    });
    NSArray<NSArray<VibeColor *> *> *sets = palettes[palette] ?: palettes[SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB];
    return sets[isDark ? 1 : 0];
}

static CGFloat VibeLuminance(CGFloat r, CGFloat g, CGFloat b) {
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

static NSString *VibeIdentifierIn(NSArray<NSString *> *list, NSString *identifier) {
    return identifier && [list containsObject:identifier] ? identifier : list.firstObject;
}

@implementation WaveformThemeChoice
@end

@implementation WaveformTheme

- (instancetype)initWithPlayed:(VibeColor *)played unplayed:(VibeColor *)unplayed isDark:(BOOL)isDark {
    self = [super init];
    if (self) {
        _playedColor = played;
        _unplayedColor = unplayed;
        _hoverColor = [WaveformTheme hoverColorForPlayed:played isDark:isDark];
        _bandColors = VibeBuiltInBandColors(NO, isDark);
        _spectrumColors = VibeBuiltInSpectrumColors(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, isDark);
    }
    return self;
}

- (NSString *)paletteSignature {
    NSMutableString *signature = [NSMutableString string];
    NSArray<VibeColor *> *colors = [[@[_playedColor, _unplayedColor] arrayByAddingObjectsFromArray:_bandColors]
            arrayByAddingObjectsFromArray:_spectrumColors];
    for (VibeColor *color in colors) {
        [signature appendFormat:@"%@,", VibeHexStringFromColor(color) ?: @""];
    }
    if (_spectrumColorsBySection) {
        [signature appendString:@"sections"];
    }
    return signature;
}

+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark {
    return [self themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_MONO isDark:isDark
                       artworkColor:nil customPlayed:nil customUnplayed:nil];
}

+ (NSArray<NSString *> *)themeIdentifiers {
    return @[SETTINGS_VALUE_WAVEFORM_THEME_MONO, SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
             SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART, SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
}

+ (NSArray<NSString *> *)bandThemeIdentifiers {
    return @[SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN, SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE,
             SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM];
}

+ (NSArray<NSString *> *)spectrumPaletteIdentifiers {
    return @[SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE,
             SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN, SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM];
}

+ (NSArray<NSString *> *)spectrumColoringIdentifiers {
    return @[SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS, SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_PRECISE];
}

+ (WaveformTheme *)themeForChoice:(WaveformThemeChoice *)choice
                           isDark:(BOOL)isDark
                     artworkColor:(VibeColor *)artworkColor {
    WaveformTheme *resolved = [self themeForIdentifier:VibeIdentifierIn(self.themeIdentifiers, choice.theme)
                                                isDark:isDark
                                          artworkColor:artworkColor
                                          customPlayed:choice.customPlayed
                                        customUnplayed:choice.customUnplayed];
    NSString *bandTheme = VibeIdentifierIn(self.bandThemeIdentifiers, choice.bandTheme);
    NSString *spectrumPalette = VibeIdentifierIn(self.spectrumPaletteIdentifiers, choice.spectrumPalette);
    // An unset well draws Rekord Bin's band, the theme's default bands.
    NSArray<VibeColor *> *rekordBin = resolved.bandColors;
    NSArray<VibeColor *> *custom = @[choice.customLow ?: rekordBin[0], choice.customMid ?: rekordBin[1],
                                     choice.customHigh ?: rekordBin[2]];
    resolved.bandColors = [self bandColorsForIdentifier:bandTheme isDark:isDark customBands:custom];
    resolved.spectrumColors = [self spectrumColorsForIdentifier:spectrumPalette isDark:isDark customBands:custom];
    resolved.spectrumColorsBySection = [VibeIdentifierIn(self.spectrumColoringIdentifiers, choice.spectrumColoring)
            isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS];
    return resolved;
}

+ (NSArray<VibeColor *> *)swatchColorsForPaletteKind:(VibeWaveformPaletteKind)kind
                                          identifier:(NSString *)identifier
                                              isDark:(BOOL)isDark {
    switch (kind) {
        case VibeWaveformPaletteKindTheme:
            return @[];
        case VibeWaveformPaletteKindBands:
            if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM]) {
                return @[];
            }
            return [[self bandColorsForIdentifier:identifier isDark:isDark customBands:@[]]
                    subarrayWithRange:NSMakeRange(0, 3)];
        case VibeWaveformPaletteKindSpectrum:
            if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM]) {
                return @[];
            }
            return [self spectrumColorsForIdentifier:identifier isDark:isDark customBands:@[]];
    }
    return @[];
}

#if !TARGET_OS_OSX
+ (UIImage *)swatchImageForPaletteKind:(VibeWaveformPaletteKind)kind
                            identifier:(NSString *)identifier
                                isDark:(BOOL)isDark {
    if (kind == VibeWaveformPaletteKindTheme) {
        return nil;
    }
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    NSString *key = [NSString stringWithFormat:@"%ld/%@/%d", (long)kind, identifier, isDark];
    if (cache[key]) {
        return cache[key];
    }
    NSArray<VibeColor *> *colors = [self swatchColorsForPaletteKind:kind identifier:identifier isDark:isDark];
    const CGFloat barWidth = 8, barGap = 3, height = 22;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(barWidth * 3 + barGap * 2, height) format:format];
    UIImage *swatch = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (NSUInteger band = 0; band < colors.count; band++) {
            [colors[band] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(band * (barWidth + barGap), 0, barWidth, height)
                                        cornerRadius:2] fill];
        }
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cache[key] = swatch;
    return swatch;
}
#endif

+ (NSArray<VibeColor *> *)spectrumColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                          customBands:(NSArray<VibeColor *> *)custom {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM] && custom.count == 3) {
        return [custom copy];
    }
    // Custom without its wells, and any unknown, are RGB.
    return VibeBuiltInSpectrumColors(identifier, isDark);
}

+ (NSArray<VibeColor *> *)bandColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                      customBands:(NSArray<VibeColor *> *)custom {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE]) {
        return VibeBuiltInBandColors(YES, isDark);
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM] && custom.count == 3) {
        return [self bandColorsForWells:custom shaded:YES isDark:isDark];
    }
    return VibeBuiltInBandColors(NO, isDark);
}

+ (NSArray<VibeColor *> *)bandColorsForWells:(NSArray<VibeColor *> *)wells shaded:(BOOL)shaded isDark:(BOOL)isDark {
    return VibeBandColors(wells[0], wells[1], wells[2], shaded, isDark);
}

+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(VibeColor *)artworkColor
                         customPlayed:(VibeColor *)played
                       customUnplayed:(VibeColor *)unplayed {
    VibeColor *base = isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    VibeColor *coloredUnplayed = [base colorWithAlphaComponent:kColoredUnplayedAlpha];

    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE]) {
        VibeColor *orange = [VibeColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        return [[self alloc] initWithPlayed:orange unplayed:coloredUnplayed isDark:isDark];
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]) {
        VibeColor *clamped = [self legibleArtworkColor:artworkColor isDark:isDark];
        if (clamped) {
            // Orange's pairing reversed: the base carries the played side at
            // full strength and the art's hue colors what is still to come.
            VibeColor *muted = [self color:clamped desaturatedBy:kArtworkUnplayedDesaturation];
            return [[self alloc] initWithPlayed:base
                                       unplayed:[muted colorWithAlphaComponent:kColoredUnplayedAlpha]
                                         isDark:isDark];
        }
        // No art, or art too gray to yield a hue: mono's answer.
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM] && played && unplayed) {
        // As stored, alpha included: the wells' alpha IS the side's resting
        // level.
        return [[self alloc] initWithPlayed:played unplayed:unplayed isDark:isDark];
    }
    // mono, and every fallback.
    return [[self alloc] initWithPlayed:[base colorWithAlphaComponent:kMonochromePlayedAlpha]
                               unplayed:[base colorWithAlphaComponent:kMonochromeUnplayedAlpha]
                                 isDark:isDark];
}

// nil for a color with no legible hue; otherwise blended toward the
// appearance's contrast pole until its luminance clears the bar — the only
// move that reaches every hue, at the cost of a little saturation.
+ (VibeColor *)legibleArtworkColor:(VibeColor *)color isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!color || !VibeColorGetSRGB(color, &r, &g, &b)) {
        return nil;
    }
    CGFloat maxc = MAX(r, MAX(g, b));
    CGFloat minc = MIN(r, MIN(g, b));
    CGFloat saturation = maxc > 0 ? (maxc - minc) / maxc : 0;
    if (saturation < kArtworkSaturationFloor) {
        return nil;
    }
    CGFloat pole = isDark ? 1 : 0;
    CGFloat luminance = VibeLuminance(r, g, b);
    CGFloat shortfall = isDark ? kArtworkDarkMinLuminance - luminance
                               : luminance - kArtworkLightMaxLuminance;
    if (shortfall > 0) {
        // Weighted RGB brightness is linear in this blend.
        CGFloat headroom = fabs(pole - luminance);
        CGFloat t = headroom > 0 ? MIN(shortfall / headroom, 1) : 0;
        r += (pole - r) * t;
        g += (pole - g) * t;
        b += (pole - b) * t;
    }
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

+ (VibeColor *)color:(VibeColor *)color desaturatedBy:(CGFloat)amount {
    CGFloat r, g, b;
    if (!VibeColorGetSRGB(color, &r, &g, &b)) {
        return color;
    }
    CGFloat gray = VibeLuminance(r, g, b);
    return [VibeColor colorWithRed:r + (gray - r) * amount
                             green:g + (gray - g) * amount
                              blue:b + (gray - b) * amount
                             alpha:1];
}

+ (VibeColor *)hoverColorForPlayed:(VibeColor *)played isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!VibeColorGetSRGB(played, &r, &g, &b)) {
        return isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    }
    // Move toward the contrast pole by the available brightness delta.
    // Full alpha keeps the hover visible over a translucent unplayed color and
    // over the bands.
    CGFloat pole = isDark ? 1 : 0;
    CGFloat luminance = VibeLuminance(r, g, b);
    CGFloat headroom = fabs(pole - luminance);
    CGFloat t = headroom <= kHoverLuminanceDelta ? 1 : kHoverLuminanceDelta / headroom;
    r += (pole - r) * t;
    g += (pole - g) * t;
    b += (pole - b) * t;
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

@end

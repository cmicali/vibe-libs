//
//  VibeListeningSettings.h
//  vibe-libs
//
//  What the listening stage plays: an EQ of up to 20 bands, a preamp, headphone
//  crossfeed, and the channel tools (swap, mono, and balance). The values are
//  immutable and compare by content. VibeMutableListeningSettings edits a copy.
//  Every setter holds its value to its range, so a bad value never reaches the
//  render.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeEQBandType) {
    VibeEQBandTypePeak,
    VibeEQBandTypeLowShelf,
    VibeEQBandTypeHighShelf,
    VibeEQBandTypeLowPass,
    VibeEQBandTypeHighPass,
};

// One filter of the EQ.
@interface VibeEQBand : NSObject <NSCopying, NSSecureCoding>

@property (nonatomic, readonly) VibeEQBandType type;
@property (nonatomic, readonly) double frequency;  // Hz, 20 to 20000
@property (nonatomic, readonly) double gainDB;     // -24 to +24; the pass filters ignore it
@property (nonatomic, readonly) double q;          // 0.1 to 10
@property (nonatomic, readonly) BOOL enabled;

// Enabled. Each value is held to its range, and a value that isn't a number
// takes the default: 1000 Hz, 0 dB, and a Q of 0.707.
+ (instancetype)bandWithType:(VibeEQBandType)type frequency:(double)frequency gainDB:(double)gainDB q:(double)q;
- (instancetype)initWithType:(VibeEQBandType)type
                   frequency:(double)frequency
                      gainDB:(double)gainDB
                           q:(double)q
                     enabled:(BOOL)enabled NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A copy with one field changed.
- (instancetype)bandWithEnabled:(BOOL)enabled;
- (instancetype)bandWithGainDB:(double)gainDB;

// Changes no sample: off, or a peak or shelf at 0 dB.
@property (nonatomic, readonly, getter=isNeutral) BOOL neutral;

@end

typedef NS_ENUM(NSInteger, VibeCrossfeed) {
    VibeCrossfeedOff,
    VibeCrossfeedLight,
    VibeCrossfeedMedium,
    VibeCrossfeedStrong,
};

// The most bands an EQ holds. A longer array is cut to this.
enum { kVibeListeningMaxBands = 20 };
// The manual preamp's range, in dB.
static const double kVibeListeningPreampMinDB = -24;
static const double kVibeListeningPreampMaxDB = 0;

@interface VibeListeningSettings : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

@property (nonatomic, readonly) BOOL eqEnabled;
@property (nonatomic, readonly, copy) NSArray<VibeEQBand *> *bands;  // at most 20
@property (nonatomic, readonly) BOOL preampAutomatic;                // YES by default
@property (nonatomic, readonly) double preampDB;                     // the manual value, 0 to -24
@property (nonatomic, readonly) VibeCrossfeed crossfeed;
@property (nonatomic, readonly) BOOL mono;
@property (nonatomic, readonly) BOOL swapChannels;
@property (nonatomic, readonly) double balance;                      // -1 full left to +1 full right

// Everything off, with the automatic preamp. The same as -init.
+ (instancetype)neutralSettings;

// Nothing would change a sample, so a stage can pass the signal through.
@property (nonatomic, readonly, getter=isNeutral) BOOL neutral;
// The automatic or the manual preamp, in dB; 0 when the EQ is off.
@property (nonatomic, readonly) double effectivePreampDB;
- (double)effectivePreampDBAtRate:(double)sampleRate;

// A dictionary of plists, for an app's defaults. A missing or bad value reads
// as neutral, and -initWithPropertyList: never throws.
- (NSDictionary<NSString *, id> *)propertyList;
- (instancetype)initWithPropertyList:(nullable id)propertyList;

// The graphic face's ten bands: peaks at these centers, with a Q of 1.41.
+ (NSArray<NSNumber *> *)graphicFrequencies;
// Ten gains in dB, in the order of graphicFrequencies. A missing or bad gain
// reads as 0 dB, and gains past the tenth are ignored.
+ (NSArray<VibeEQBand *> *)graphicBandsWithGains:(NSArray<NSNumber *> *)gains;
// The bands are exactly the graphic layout, every one enabled.
@property (nonatomic, readonly, getter=isGraphic) BOOL graphic;

@end

@interface VibeMutableListeningSettings : VibeListeningSettings

@property (nonatomic) BOOL eqEnabled;
@property (nonatomic, copy) NSArray<VibeEQBand *> *bands;
@property (nonatomic) BOOL preampAutomatic;
@property (nonatomic) double preampDB;
@property (nonatomic) VibeCrossfeed crossfeed;
@property (nonatomic) BOOL mono;
@property (nonatomic) BOOL swapChannels;
@property (nonatomic) double balance;

@end

#ifdef __cplusplus
extern "C" {
#endif

// The combined magnitude, in dB, of the enabled bands at `frequency`, as the
// stage plays them at `sampleRate`.
double VibeListeningResponseDB(NSArray<VibeEQBand *> *bands, double frequency, double sampleRate);

// Used for a preview before the host has a playback format.
static const double kVibeListeningPreviewRate = 48000;

// Minus the highest boost from DC to Nyquist at the playback rate.
double VibeListeningAutomaticPreampDBAtRate(NSArray<VibeEQBand *> *bands, double sampleRate);
// Uses the preview rate for callers without a playback format.
double VibeListeningAutomaticPreampDB(NSArray<VibeEQBand *> *bands);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

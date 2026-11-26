//
//  VibeEQPreset.h
//  vibe-libs
//
//  A named set of EQ bands and a preamp, which applies to a listener's
//  settings. Immutable, and compares by content.
//

#import <Foundation/Foundation.h>
#import "VibeListeningSettings.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeEQPresetKind) {
    VibeEQPresetKindBuiltIn,
    VibeEQPresetKindHeadphone,
    VibeEQPresetKindUser,
};

@interface VibeEQPreset : NSObject <NSSecureCoding>

@property (nonatomic, readonly, copy) NSString *identifier;  // stable, so an app can save it
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) VibeEQPresetKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *source;  // a headphone's measurement source
@property (nonatomic, readonly, copy) NSArray<VibeEQBand *> *bands;  // at most 20
@property (nonatomic, readonly) double preampDB;  // 0 to -24

// The bands past 20 are dropped, and the preamp is held to its range.
- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                              kind:(VibeEQPresetKind)kind
                            source:(nullable NSString *)source
                             bands:(NSArray<VibeEQBand *> *)bands
                          preampDB:(double)preampDB NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A user preset with a new identifier, from the settings' bands and preamp: the
// automatic preamp's value at the preview rate when it is automatic, so the
// preset is the same whatever rate was playing.
+ (instancetype)presetWithName:(NSString *)name settings:(VibeListeningSettings *)settings;

// A dictionary of plists, for an app's defaults. The bands are in the settings'
// property list format. A missing or bad identifier, name, or kind reads as
// nil, and -initWithPropertyList: never throws.
- (NSDictionary<NSString *, id> *)propertyList;
- (nullable instancetype)initWithPropertyList:(nullable id)propertyList;

// A copy of `settings` with these bands, the EQ on, and the preamp automatic.
// The preset's preamp turns the preamp manual only when it cuts more than the
// automatic one would, at the preview rate and at `sampleRate`. Everything
// else in `settings` stays.
- (VibeListeningSettings *)applyingToSettings:(VibeListeningSettings *)settings;
- (VibeListeningSettings *)applyingToSettings:(VibeListeningSettings *)settings sampleRate:(double)sampleRate;

// The settings' EQ is on with these bands, at the preamp this preset applies
// or at this preset's own manual preamp, so an app can show this preset's name.
- (BOOL)matchesSettings:(VibeListeningSettings *)settings;
- (BOOL)matchesSettings:(VibeListeningSettings *)settings sampleRate:(double)sampleRate;

@end

NS_ASSUME_NONNULL_END

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

// A copy of `settings` with these bands, the EQ on, and the preamp automatic.
// The preset's preamp turns the preamp manual only when it cuts more than the
// automatic one would. Everything else in `settings` stays.
- (VibeListeningSettings *)applyingToSettings:(VibeListeningSettings *)settings;

@end

NS_ASSUME_NONNULL_END

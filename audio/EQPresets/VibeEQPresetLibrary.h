//
//  VibeEQPresetLibrary.h
//  vibe-libs
//
//  The built-in presets, and a search over headphone presets. The shared
//  library holds no headphone presets: its AGENTS.md says why.
//

#import <Foundation/Foundation.h>
#import "VibeEQPreset.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeEQPresetLibrary : NSObject

+ (instancetype)sharedLibrary;

// A library whose headphones come from `loader`, run once, off main, on first
// use.
- (instancetype)initWithHeadphonesLoader:(NSArray<VibeEQPreset *> * (^)(void))loader NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Flat, Bass Boost, Treble Boost, Vocal, Loudness, and Bass Cut.
@property (nonatomic, readonly, copy) NSArray<VibeEQPreset *> *builtInPresets;

// The headphones whose names match `query`, case- and diacritic-insensitive,
// best first, at most `limit` of them (0 for no limit). A name that starts with
// the query comes first, then one with a word that starts with it, then one
// that holds it, then one that holds every word of it. Ties sort by name. An
// empty query matches every headphone. `completion` runs on main.
- (void)searchHeadphones:(NSString *)query
                   limit:(NSUInteger)limit
              completion:(void (^)(NSArray<VibeEQPreset *> *results))completion;

// Waits for the headphones to load, the first time.
- (nullable VibeEQPreset *)headphoneWithIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END

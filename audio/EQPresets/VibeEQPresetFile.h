//
//  VibeEQPresetFile.h
//  vibe-libs
//
//  Equalizer APO's parametric text, the format of AutoEQ's ParametricEQ.txt:
//
//      Preamp: -6.2 dB
//      Filter 1: ON PK Fc 105 Hz Gain -3.1 dB Q 0.70
//

#import <Foundation/Foundation.h>
#import "VibeEQPreset.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const VibeEQPresetFileErrorDomain;

typedef NS_ERROR_ENUM(VibeEQPresetFileErrorDomain, VibeEQPresetFileError) {
    VibeEQPresetFileErrorNoFilters = 1,  // the text holds no filter this reads
};

@interface VibeEQPresetFile : NSObject

// A user preset with a new identifier, or nil and an error when the text holds
// no filter this reads. A line this can't read is skipped. It never throws.
+ (nullable VibeEQPreset *)presetFromEqualizerAPOText:(NSString *)text
                                                 name:(NSString *)name
                                                error:(NSError *_Nullable *_Nullable)error;

// A Preamp line and a Filter line for each band, to three decimals, which reads
// back to the same bands.
+ (NSString *)equalizerAPOTextForPreset:(VibeEQPreset *)preset;

@end

NS_ASSUME_NONNULL_END

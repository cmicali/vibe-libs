//
//  VibeListeningStage.h
//  vibe-libs
//
//  The realtime stage that plays a VibeListeningSettings. Neutral, it is a
//  bit-perfect pass-through, and a change crossfades over 10 ms. This piece's
//  AGENTS.md has the math.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>
#import "VibeListeningSettings.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeListeningStage VibeListeningStage;

// The most channels a stage takes.
enum { kVibeListeningMaxChannels = 8 };

#pragma mark - The queue

// A neutral stage for `channels` (1 to 8) at `sampleRate` (8 kHz or more).
// NULL when the arguments are out of range or it cannot be allocated.
VibeListeningStage *_Nullable VibeListeningStageCreate(uint32_t channels, double sampleRate);
// With no render inside it.
void VibeListeningStageFree(VibeListeningStage *_Nullable stage);

// Builds the settings' filters and publishes them; the render crossfades to
// them at its next slice. One thread at a time. It frees the filters of
// earlier settings the render has left. NO when they can't be allocated: the
// last settings play on.
BOOL VibeListeningStageSetSettings(VibeListeningStage *stage, VibeListeningSettings *settings);

// From any thread, the audio thread included: fixed at create.
uint32_t VibeListeningStageChannels(const VibeListeningStage *stage) CA_REALTIME_API;
double VibeListeningStageSampleRate(const VibeListeningStage *stage);
// In the signal path: settings that change samples, or a crossfade.
BOOL VibeListeningStageEngaged(const VibeListeningStage *stage);
// Output samples past ±1.0, counted while engaged, the input's own included.
uint64_t VibeListeningStageClips(const VibeListeningStage *stage);
// Engaged, with a clip in the last second of the frames it rendered.
BOOL VibeListeningStageClipping(const VibeListeningStage *stage);
uint64_t VibeListeningStageRenders(const VibeListeningStage *stage);  // slices it processed

#pragma mark - The audio thread

// `frames` of `channels`, the stage's channel count of buffers, in place.
void VibeListeningStageRender(VibeListeningStage *stage, float *_Nonnull const *_Nonnull channels,
                              uint32_t frames) CA_REALTIME_API;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

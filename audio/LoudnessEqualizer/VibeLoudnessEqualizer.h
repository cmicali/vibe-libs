//
//  VibeLoudnessEqualizer.h
//  vibe-libs
//
//  Loudness equalization: a slow automatic gain that plays quiet and loud
//  passages at a similar level, then a look-ahead peak limiter that keeps its
//  boost, up to +20 dB, from clipping. It follows the method of Windows'
//  Loudness Equalization as pw-loudness-eq documents it. It does not change
//  the spectrum. This piece's AGENTS.md has the math.
//
//  Off, it is a bit-perfect pass-through: nothing is read, copied, or delayed.
//  On, it plays N + L frames late (576 at 44.1 and 48 kHz). Turning it on or
//  off crossfades over 10 ms, so neither clicks.
//
//  The queue half creates the stage at a rate and sets its switch and its
//  release from any thread. The audio-thread half renders slices in place.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeLoudnessEqualizer VibeLoudnessEqualizer;

// The release setting: how slowly the gain rises again after a loud passage.
// 2 is fastest and 7 slowest. 4, the default, rises with a time constant of
// about 4.6 s.
static const int kVibeLoudnessReleaseFastest = 2;
static const int kVibeLoudnessReleaseSlowest = 7;
static const int kVibeLoudnessReleaseDefault = 4;

// The most channels a stage takes.
enum { kVibeLoudnessMaxChannels = 8 };

#pragma mark - The queue

// A stage, off, for `channels` (1 to 8) at `sampleRate` (800 Hz or more).
// NULL when the arguments are out of range or it cannot be allocated.
VibeLoudnessEqualizer *_Nullable VibeLoudnessEqualizerCreate(uint32_t channels, double sampleRate);
// With no render inside it.
void VibeLoudnessEqualizerFree(VibeLoudnessEqualizer *_Nullable stage);

// From any thread. The render picks the change up at its next slice.
void VibeLoudnessEqualizerSetEnabled(VibeLoudnessEqualizer *stage, BOOL enabled);
BOOL VibeLoudnessEqualizerEnabled(const VibeLoudnessEqualizer *stage);
// Held to kVibeLoudnessReleaseFastest...kVibeLoudnessReleaseSlowest.
void VibeLoudnessEqualizerSetRelease(VibeLoudnessEqualizer *stage, int release);
int VibeLoudnessEqualizerRelease(const VibeLoudnessEqualizer *stage);

// From any thread, the audio thread included: fixed at create.
uint32_t VibeLoudnessEqualizerChannels(const VibeLoudnessEqualizer *stage) CA_REALTIME_API;
// From any thread, for the reports.
double VibeLoudnessEqualizerSampleRate(const VibeLoudnessEqualizer *stage);
// In the signal path: on, or still fading out.
BOOL VibeLoudnessEqualizerEngaged(const VibeLoudnessEqualizer *stage);
// The leveler's last gain, linear; 1 while not engaged.
float VibeLoudnessEqualizerGain(const VibeLoudnessEqualizer *stage);
// The limiter's last gain, linear; 1 while it is not limiting.
float VibeLoudnessEqualizerLimiterGain(const VibeLoudnessEqualizer *stage);
// How late the stage plays its input while engaged: the analysis frame and
// the limiter's look-ahead. 0 while it is not.
uint32_t VibeLoudnessEqualizerLatencyFrames(const VibeLoudnessEqualizer *stage);
uint64_t VibeLoudnessEqualizerRenders(const VibeLoudnessEqualizer *stage);  // slices it processed

#pragma mark - The audio thread

// `frames` of `channels`, the stage's channel count of buffers, in place.
// Off and settled, it returns at once. Turning on, it plays the input as it
// is until the stage holds a full analysis frame and look-ahead, then
// crossfades to the leveled signal. Turning off, it crossfades back.
void VibeLoudnessEqualizerRender(VibeLoudnessEqualizer *stage, float *_Nonnull const *_Nonnull channels,
                                 uint32_t frames) CA_REALTIME_API;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

//
//  AudioPlayer+BitPerfect.h
//  vibe-libs
//
//  Bit-perfect and exclusive output, macOS only: the setter an app calls and
//  the report it reads. (BitPerfect) is the public API an app imports beside
//  AudioPlayer.h. The queue-side mechanism, (BitPerfectInternal), is declared
//  in AudioPlayer+DevicesInternal.h. It lives under Mac/ so only the macOS
//  target compiles it.
//

#import "AudioPlayer.h"
#import "OutputFormatRules.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeBitPerfectStatus) {
    // The setting is off, or the device is ineligible. This is defensive. An
    // app should never let the two coincide.
    VibeBitPerfectStatusOff,
    // On, device chosen, nothing playing.
    VibeBitPerfectStatusIdle,
    VibeBitPerfectStatusActive,
    // The device does not offer the file's rate; a multiple was used when it
    // offered one.
    VibeBitPerfectStatusRateUnsupported,
    // The output route, format or gain could not be confirmed.
    VibeBitPerfectStatusSwitchFailed,
    VibeBitPerfectStatusChannelConversion,
    VibeBitPerfectStatusDepthInsufficient,
    VibeBitPerfectStatusMuted,
    // Software volume below 1.0, balance away from center, or the player's
    // own volume below full.
    VibeBitPerfectStatusVolumeScaled,
    // Exclusive output requested but ownership not confirmed.
    VibeBitPerfectStatusExclusiveRefused,
    // Everything held, but the file is lossy: its decoded audio plays at its
    // own rate with no volume change, rounded only to the device's depth.
    VibeBitPerfectStatusSourceLossy,
};

// Every input to the fold plus what it produced. Every reader of the status
// reads one snapshot, so no two can disagree about why.
typedef struct {
    VibeBitPerfectStatus status;
    double sampleRate;      // the device's, after the switch
    UInt32 bitsPerChannel;  // the physical format's width
    UInt32 sourceBits;      // the file's depth (VibeSourceBitDepth), 0 for lossy
    BOOL isFloat;
    float softwareVolume;
    float balance;         // 0 = left, 0.5 = center, 1 = right
    float playerVolume;    // the player's own volume, 1 at full
    BOOL fileGainScaled;   // the current file plays at a file gain other than 1
    // The fold's inputs.
    BOOL enabled;
    BOOL eligibleDevice;
    BOOL hasTrack;
    BOOL rateExact;
    BOOL formatConfirmed;   // the bound device has the requested format; its gain reads succeeded
    BOOL channelsMatch;     // unchanged source channels, verified output routing
    BOOL depthOK;
    BOOL muted;
    BOOL hogWanted;
    BOOL exclusive;
} VibeBitPerfectReport;

// Every field, so a publication that changed nothing is not announced.
static inline BOOL VibeBitPerfectReportsEqual(VibeBitPerfectReport a, VibeBitPerfectReport b) {
    return a.status == b.status && a.sampleRate == b.sampleRate
            && a.bitsPerChannel == b.bitsPerChannel && a.sourceBits == b.sourceBits && a.isFloat == b.isFloat
            && a.softwareVolume == b.softwareVolume && a.balance == b.balance
            && a.playerVolume == b.playerVolume && a.fileGainScaled == b.fileGainScaled && a.enabled == b.enabled
            && a.eligibleDevice == b.eligibleDevice && a.hasTrack == b.hasTrack
            && a.rateExact == b.rateExact
            && a.formatConfirmed == b.formatConfirmed && a.channelsMatch == b.channelsMatch
            && a.depthOK == b.depthOK && a.muted == b.muted
            && a.hogWanted == b.hogWanted && a.exclusive == b.exclusive;
}

// The fold over the report's inputs, in priority order, so two breakers never
// race for the caption: Off > Idle > SwitchFailed >
// RateUnsupported > ChannelConversion > DepthInsufficient > Muted > VolumeScaled > ExclusiveRefused >
// SourceLossy > Active. SourceLossy is last
// before Active because it is the only status that says the chain is perfect
// and the file is not. There is no pitch input: under the mode there is no
// varispeed to have a pitch.
static inline VibeBitPerfectStatus VibeBitPerfectFold(VibeBitPerfectReport r) {
    if (!r.enabled || !r.eligibleDevice) {
        return VibeBitPerfectStatusOff;
    }
    if (!r.hasTrack) {
        return VibeBitPerfectStatusIdle;
    }
    if (!r.formatConfirmed) {
        return VibeBitPerfectStatusSwitchFailed;
    }
    if (!r.rateExact) {
        return VibeBitPerfectStatusRateUnsupported;
    }
    if (!r.channelsMatch) {
        return VibeBitPerfectStatusChannelConversion;
    }
    if (!r.depthOK) {
        return VibeBitPerfectStatusDepthInsufficient;
    }
    if (r.muted) {
        return VibeBitPerfectStatusMuted;
    }
    if (r.softwareVolume < 1.0f || r.balance != 0.5f || r.playerVolume < 1.0f || r.fileGainScaled) {
        return VibeBitPerfectStatusVolumeScaled;
    }
    if (r.hogWanted && !r.exclusive) {
        return VibeBitPerfectStatusExclusiveRefused;
    }
    if (r.sourceBits == 0) {
        return VibeBitPerfectStatusSourceLossy;
    }
    return VibeBitPerfectStatusActive;
}

@interface AudioPlayer (BitPerfect)

// Bit-perfect output requests the file's rate and a suitable physical format.
// OutputFormatRules.h selects a fallback when the device cannot match them.
// The bus follows the device rate and has no varispeed or FX. Declick controls
// the transport ramps. Player volume still applies and is reported when below
// full. The app owns the rest of the pruning, such as a minimum crossfade and
// a hidden pitch control. It turns this on only for an eligible device: one
// explicitly chosen, on a transport that carries bits unchanged
// (OutputFormatRules.h). Either direction
// restores the current track in place, as a device switch onto the same
// device; off also puts the device's format back and releases the hog. Main
// thread, like every other transport-facing setter; the work lands on the
// player queue. The delegate rereads the current UID's modes on the player
// queue; explicit flags supply submission-time FX cleanup and the fallback
// without a provider. Bit-perfect outranks the saved FX choice. Exclusive
// access applies only in bit-perfect mode.
// allowAnyDevice bypasses only transport eligibility, for testing.
- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput
                  enableFX:(BOOL)enableFX allowAnyDevice:(BOOL)allowAnyDevice;

// The newest published report — a locked snapshot, no queue hop, like
// outputAudioActive. Recomputed from its owners at every settlement, hog
// edge, mode toggle, playback-state publication, volume/balance/mute change
// and default change, and announced through
// audioPlayerDidChangeBitPerfectReport: when it differs.
@property (readonly) VibeBitPerfectReport bitPerfectReport;

// The same report as a dictionary with its status named: every input to the
// fold, so a reader can say why a lock is open. A debug report reads it.
- (NSDictionary<NSString *, id> *)bitPerfectReportDictionary;

@end

NS_ASSUME_NONNULL_END

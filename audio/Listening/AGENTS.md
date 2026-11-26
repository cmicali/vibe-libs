# audio/Listening

What a listener sets to suit their ears and headphones: a parametric EQ of up to 20 bands, a preamp, headphone crossfeed, and the channel tools (swap, mono, and balance). It holds the settings as values, `VibeListeningSettings.h`, and the response math an editor draws from. It depends on nothing but Foundation. It reads no app's settings, strings, or types.

## The settings

**`VibeEQBand` and `VibeListeningSettings` are immutable values** that compare by content. `VibeMutableListeningSettings` edits a copy, and `-copy` hands back an immutable one. They are NSSecureCoding, and `propertyList` gives plists for an app's defaults.

**Every value is held to its range where it enters**: a band's frequency to 20 Hz to 20 kHz, its gain to ±24 dB, its Q to 0.1 to 10, the manual preamp to 0 to −24 dB, the balance to ±1, and the bands to 20. A value that isn't a number takes the default. A property list that is missing a value, or holds a bad one, reads as neutral there, and never throws. A band with an unknown type is dropped. The plist names the band types and crossfeed levels by word, so the enums can grow.

**`isNeutral` means no sample would change**, so a stage can pass the signal through bit for bit. An EQ changes samples only when it is on and has a band that is not neutral, or a preamp that isn't 0 dB. A band is neutral when it is off, or a peak or shelf at 0 dB. A pass filter is never neutral.

**The preamp belongs to the EQ.** `effectivePreampDB` is 0 while the EQ is off. Automatic, it is `VibeListeningAutomaticPreampDB`: minus the curve's highest boost from 20 Hz to 20 kHz at 48 kHz, found on a log grid of 1,024 points and then by a golden-section search beside the best one, so a narrow peak between two points still counts in full.

**The graphic face** is ten peaks at 31 Hz to 16 kHz, with a Q of 1.41. `isGraphic` is true only for exactly that layout, every band on, so an editor knows which face can show the settings.

## The response

**`VibeListeningBiquad.h` holds the RBJ cookbook's biquads**, which the response math uses, so the curve an editor draws is the one that plays. A band's center is held under 0.48 of the rate. The shelves take the band's Q in the cookbook's alpha. The pass filters ignore the gain.

## Tests

`Tests/audio/Listening/VibeListeningSettingsTests.m` covers each range, equality and the copies, the coding and the plist round trips, a bad plist, the graphic face, each filter's shape, and the automatic preamp.

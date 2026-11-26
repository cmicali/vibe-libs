# audio/EQPresets

EQ presets for `audio/Listening`'s settings: the built-in presets, a reader and a writer for Equalizer APO's parametric text, and a library that searches headphone presets. It depends on `audio/Listening`. It reads no app's settings, strings, or types.

## The presets

**A preset is a value.** `VibeEQPreset` is immutable and NSSecureCoding. It holds a stable `identifier`, a `name`, a `kind`, a `source` (the measurement source of a headphone preset, nil otherwise), its `bands`, and its `preampDB`.

**Applying a preset keeps everything but the EQ.** `-applyingToSettings:` returns a copy of the given settings with the preset's bands, the EQ on, and the preamp automatic. A preset's own preamp turns the preamp manual only when it cuts more than the automatic preamp would for those bands. The crossfeed, the channel tools, and the balance stay as they were.

**An app saves and names presets through the preset.** `propertyList` and `initWithPropertyList:` keep a preset in an app's defaults, with its bands in the settings' property list format. A missing or bad identifier, name, or kind reads as nil, and it never throws. `+presetWithName:settings:` makes a user preset from the settings' bands and preamp, with the automatic preamp's value when it is automatic. `-matchesSettings:` is true when the settings' EQ is on, with this preset's bands, at the preamp this preset applies, so an app can show the preset's name. A manual preamp equal to the preset's own matches too, so a preset saved with a manual preamp that cuts less than the automatic one still matches the settings it came from. Applying that preset turns the preamp back to automatic, by the rule above. The crossfeed and the channel tools don't count.

**The built-ins are Flat, Bass Boost, Treble Boost, Vocal, Loudness, and Bass Cut**, in that order. Each is a set of the graphic face's ten bands, so the graphic editor shows them as they are. Their identifiers start with `builtin.` and never change, since an app saves them.

## Equalizer APO's text

`VibeEQPresetFile` reads and writes the format of AutoEQ's `ParametricEQ.txt` and of Equalizer APO's configuration:

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 105 Hz Gain -3.1 dB Q 0.70
```

- **It reads** PK and PEQ as a peak, LSC and LS as a low shelf, HSC and HS as a high shelf, LP and LPQ as a low pass, and HP and HPQ as a high pass. A filter marked OFF reads as a band that is not enabled. A line it can't read, a comment, or a filter type it doesn't know is skipped. A filter with no gain or Q takes `VibeEQBand`'s default, 0 dB or 0.707. A byte order mark at the start is skipped. Numbers read with a point as the decimal mark, whatever the locale.
- **It never throws.** Text with no filter it can read returns nil and an error. Values outside a band's range are clamped by `VibeEQBand`. Past 20 filters, the rest are skipped.
- **It writes** a `Preamp:` line and one `Filter N:` line for each band, with PK, LSC, HSC, LPQ, or HPQ, to three decimals with a point. A band that is not enabled is written OFF. What it writes reads back to the same bands, for values of three decimals or fewer, which covers every AutoEQ result.

## Headphone presets, and why none are bundled

`VibeEQPresetLibrary` searches headphone presets, ranked, case- and diacritic-insensitive, off main, and calls back on main. A name that starts with the query ranks first, then a name with a word that starts with it, then any name that contains it, then a name that contains every word of it. Ties sort by name. Folding also spells out the letters that carry no mark to strip, so "rode" finds RØDE. Names are folded once, when the headphones load, so a search over 5,000 takes a few milliseconds. **A library's headphones come from a loader block**, which runs once, off main, on first use. `+sharedLibrary`'s loader returns **no headphone presets**, so its search returns nothing. The tests make a library of their own.

**The AutoEQ list is not bundled.** No measurement source's terms clearly allow redistribution in an app that charges for itself or keeps its code closed, so nothing is bundled. A source would join only if its terms clearly allow that. One that forbids it or says nothing stays out. This was checked on 2026-11-26, at AutoEQ commit [7ae0f56](https://github.com/jaakkopasanen/AutoEq/tree/7ae0f56d53074872b028649617a22bbb4232feb7):

- **AutoEQ itself** is [MIT](https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE), but the license covers its code. Its maintainer [says](https://github.com/jaakkopasanen/AutoEq/issues/1101) that he does not own the measurement data and cannot give permission to distribute it. A [question](https://github.com/jaakkopasanen/AutoEq/issues/1107) about commercial use of the results has no answer. So each result's terms are its measurement source's.
- **oratory1990** ([his list](https://www.reddit.com/r/oratory1990/wiki/index/list_of_presets/)): left out. His list prohibits unlicensed commercial use, as [quoted in AutoEQ's issue 1101](https://github.com/jaakkopasanen/AutoEq/issues/1101).
- **crinacle** ([crinacle.com](https://crinacle.com/)): left out. The site states no license for its measurements, and his tools' [guide](https://mlochbaum.github.io/CrinGraph) says to get his permission before using his data.
- **Rtings** ([terms of use](https://www.rtings.com/company/terms-of-use)): left out. The terms limit the site to non-commercial use, and forbid reproducing its contents and downloading them into a database.
- **Innerfidelity** ([Stereophile's archive](https://www.stereophile.com/content/innerfidelity-headphone-measurements)): left out. The [measurement book](https://www.stereophile.com/images/ifmeasure/AllGraphs.pdf) says all rights are reserved, and no license is published.
- **Headphone.com Legacy**: left out. No terms are published for the legacy measurements.
- **The community sources**: Auriculares Argentina, Bakkwatan, DHRME, Fahryst, Filk, Harpo, Hi End Portable, HypetheSonics, Jaytiss, Kazi, Kuulokenurkka, Regan Cipher, RikudouGoku, Super Review, Ted's Squig Hoard, ToneDeafMonk, freeryder05, and kr0mka. Left out. Most publish on [squig.link](https://squig.link) sites, and none publishes a license for its measurements, in AutoEQ or on its site.

**A source joins only with written terms** that allow redistribution in an app that charges for itself or keeps its code closed. Then a script in `tools/` rebuilds a bundled file from AutoEQ at a pinned commit, with only those sources, and `+sharedLibrary` loads it lazily, off main. `THIRD-PARTY-NOTICES.md` then lists each source and its terms. Until then, a user imports a headphone's `ParametricEQ.txt` from AutoEQ's site through `VibeEQPresetFile`, which is the user's own download.

## Tests

`Tests/audio/EQPresets/` covers the reader on text in AutoEQ's format and on bad input, a round trip through the writer, the built-ins, applying a preset, a preset's property list and a bad one, a user preset from settings, matching settings, the search's ranking over a library made in the test, and that the shared library has no headphone presets. The fixtures are written for the tests. No AutoEQ result is copied here, for the reasons above.

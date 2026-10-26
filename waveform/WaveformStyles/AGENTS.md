# waveform/WaveformStyles

Each waveform style's look: its columns, its levels, its colors, the zoom math, and the morph engine that eases between them. It depends on `waveform/Waveform` for the summary it draws, on `core/Graphics` for the platform colors, and on `core/Common` for the log, signpost, and helper macros. It holds the six renderers and their base, the registry, the morph engine, the bar and level math, the theme, and the zoom math. It came from Vibe. It names no app type. It reads no setting and no string. The views that host a renderer, the mac view and the iOS scrubber, are `waveform/WaveformView`.

| File | Owns |
| --- | --- |
| `WaveformRenderer.h`, `.mm` | the base: the window, the morph, the pictures, Normalize and Gain, and the convert sweep |
| `DetailedWaveformRenderer`, `OversamplingDetailedWaveformRenderer` | Detailed, its three oversampled types, and Wiggle |
| `BasicWaveformRenderer`, `CupertinoWaveformRenderer` | Bars, Cupertino, and Progress, the pill |
| `SonicCirrusWaveformRenderer` | Sonic Cirrus |
| `ThreeBandWaveformRenderer` | 3-Band, and Spectrum, its subclass |
| `WaveformRendererRegistry.h`, `.mm` | identifier to renderer, the fallback chain, what each style supports, and the bakes |
| `WaveformMorphEngine.h`, `.mm` | the displayed and target samples, the 60 Hz ease, and the retarget decisions |
| `WaveformLevelMath.h`, `WaveformBarMath.h` | the level mapping, and the bar geometry. Header-only and tested |
| `WaveformTheme.h`, `.m` | the rules from a theme identifier to colors |
| `WaveformZoomMath.h` | the scrubber's zoom floor, which three renderers read. Header-only and tested |

## How an app uses it

List `VibeLibsWaveformStyles`. It lists Waveform's, Graphics', and Common's templates. The renderers are Objective-C++, so **the app builds C++ as C++17 or later**, as Waveform needs. The template links Foundation, QuartzCore, and CoreGraphics itself, since Xcode builds Objective-C++ with `-fno-cxx-modules`. The template's comment carries the trap.

```objc
// A renderer draws into a host layer of the app's own, with no window.
CALayer *host = [CALayer layer];
host.bounds = CGRectMake(0, 0, 400, 60);
WaveformRenderer *renderer = [WaveformRendererRegistry rendererForResolvedIdentifier:@"three_band"
                                                                               layer:host
                                                                              bounds:host.bounds
                                                                              isDark:YES];
renderer.theme = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:YES
                                      artworkColor:nil customPlayed:nil customUnplayed:nil];
[renderer updateWaveform:host.bounds progress:0.5 waveform:summary];   // an AudioWaveform
```

**The app owns the policy.** It persists a style's identifier and resolves it once through `resolveStyleIdentifier:`. It names each style in its choosers, since display names are the app's. It maps its settings onto a `WaveformTheme`, and it pushes Normalize, Gain, Centered, and the bar density and width into the renderer.

## ObjC++ boundary

**Keep C++ types out of any header a plain Objective-C `.m` imports.** `WaveformTheme.h`, `WaveformZoomMath.h`, `WaveformRendererRegistry.h`, and the two math headers are plain Objective-C. `WaveformBarMath.h` needs CoreGraphics for its rects. `WaveformRenderer.h` and `WaveformMorphEngine.h` bring in `AudioWaveform.h` and `<vector>`, so only `.mm` files may import them.

## The theme

The theme beats the style's palette. The style is the geometry, and the theme is the colors. Each view resolves its theme, and the album-art color rides the view's artwork install.

**`WaveformTheme`'s `themeForIdentifier:isDark:artworkColor:customPlayed:customUnplayed:` is the only home of the rules from identifier to colors.** It returns `playedColor`, `unplayedColor`, and `hoverColor`. The app maps its store onto it in one place, so the theme reads no store. A view resolves only through the `WaveformThemeProvider` block its shell installs, with the appearance it draws in and the artwork color settled on it. A view with none resolves Mono.

**Each color carries its side's resting level in its alpha. Renderers own only their ramp shapes**, and scale every stop against that level (`VibeColorWithScaledAlpha`, `core/Graphics`' `PlatformColor.h`). `WaveformTheme.m` names the built-in levels. A custom well's alpha sets its side's whole intensity and persists in the hex (`#RRGGBBAA`). A renderer that hard-codes an alpha breaks every theme at once.

**`flatFill` drops the ramp, never the level.** Spectrum and the pill draw no ramp either way (`WaveformRendererRegistry.supportsGradientForIdentifier:`).

**3-Band's fills are the theme's `bandColors`. They are opaque and outside the alpha rule**, since 3-Band's layers stack. Seven colors come from three bands by one rule, `bandColorsForWells:shaded:isDark:`. Shaded, they follow a CDJ. Unshaded, each band paints plainly over the ones below, as Engine DJ does. Rekord Bin's bands are the default. `bandColorsForIdentifier:isDark:customBands:` resolves a band palette's identifier: Rekord Bin, Dengine, or Custom. Custom is shaded, and an unknown identifier draws Rekord Bin's. `WaveformThemeTests` holds the built-in palettes to the CDJ's colors.

**Spectrum's primaries are the theme's `spectrumColors`. They are opaque and outside the alpha rule too.** `spectrumColorsForIdentifier:isDark:customBands:` resolves Spectrum's palette: RGB, the default, Blue, Green, or Custom. RGB is red, green, and blue for the low, mid, and high bands, close in lightness. Blue's dark set is pale blue lows, bright cyan mids, and steel blue highs. Green is the same lightness at a green hue. Each built-in light set is darker, so it reads on white. **TRAP: Blue's and Green's low stands farthest from the background.** It is the lightest color on dark and the darkest on white. Most music is mostly low, so a low near the background hides the whole waveform. Custom is the band wells as they are, the same wells 3-Band's Custom reads.

**Spectrum's coloring rides the theme as `spectrumColorsBySection`.** By section is an app's default, and Precise is the other choice. `paletteSignature` carries it, so every bake keyed by the palette redraws when it changes. A bare `WaveformTheme` draws Precise.

**`playheadColor` is the playhead line, and nil means no line.** With nil, the played and unplayed boundary is the playhead. With a color, the whole waveform draws as played, and a solid line the height of the seek band marks the position. **No renderer reads it.** Each view hands its renderer a progress of 1 and draws the line itself (`VibePlayheadLineRect`, `WaveformBarMath.h`). `WaveformRendererRegistry`'s `drawsPlayheadLineForIdentifier:chosen:` answers a style's default while the app has no choice: the line for 3-Band and Spectrum.

**The album-art clamp tests weighted RGB brightness.** It uses `0.299R + 0.587G + 0.114B` without linearizing the components. HSB brightness would accept a dark pure blue. The clamp blends toward the appearance's contrast pole. Desaturation preserves the same weighted brightness. The hover color moves toward the contrast pole by up to 0.25 at full alpha. A color already at that pole has no headroom. `WaveformThemeTests` pins these rules.

## The renderers

`WaveformRenderer` is the base. `WaveformRendererRegistry` is the one home of identifier to renderer and of the fallback chain for a persisted style, so two platforms cannot drift on which styles exist.

**Compare styles by identifier, never by class.** Variants share classes. Wiggle is `DetailedWaveformRenderer`, the oversampled types share a file, Cupertino subclasses Bars, and Spectrum subclasses 3-Band in 3-Band's file. The resolved registry identifier is what persists. **TRAP: Wiggle's is `wiggle_centered` whatever Centered says.** It persists, so renaming it orphans every saved Wiggle. Bars persists as `basic` and its class is `BasicWaveformRenderer`. Progress persists as `cupertino_basic` and its class is `CupertinoBasicWaveformRenderer`. Both keep the names they shipped under. The retired `wiggle` (Wiggle MC) is read only by an app's migrations, which turn it into Wiggle with Centered off.

The registry's bake renders the real style into a bitmap with the caller's palette, density, width, and levels. An app's settings preview or widget can use it. Its synthetic preview sample includes fine transients, because a smooth envelope hides the Detailed family's sampling differences at thumbnail size. A bake never changes a live renderer's geometry. Under a theme's `playheadColor` the bake draws what the views draw: the waveform wholly played and the line at the progress (The theme, above).

## Families

Two families and one flat style, split by how progress and hover quantize:

- **Continuous**: Detailed in every type, Wiggle, 3-Band, and Spectrum. The played clip edge is the playhead. Hover lights a thin slice, or a whole loop for Wiggle so it does not flicker into dots between strokes.
- **Block**: Bars, Cupertino, and Sonic Cirrus. Hover lights the whole block under the cursor, and the played fill advances a block at a time. `VibeBlockIndexForX` and `VibeBlockBoundaryForProgress` hold both rules. Their one home is `WaveformBarMath.h`. **This is presentation only. The seek a hover or click reports stays continuous.**
- **Progress** is the Apple Music pill, the one style that never reads the samples. It has no morph engine, so settle and the convert dip are base no-ops. The registry can still render its layers into a bitmap. Having a waveform decides only whether the pill shows.

**Detailed is one style with four types**: Detailed and Oversampled 2x, 4x, and 8x. Each type keeps its own identifier and class. The type is the persisted style. It needs no setting of its own. `styleIdentifiers` lists every style once, in registration order, with the family under its 4x type. An app's chooser sorts the styles by the names it gives them. Choosing Detailed from another style lands on the 4x type. Choosing Detailed while it is current keeps the type. `typeIdentifiersForIdentifier:` feeds a Type chooser. Every other registry query takes the type's identifier.

## Pictures

**Every style but Sonic Cirrus and Progress draws a picture into a layer's contents.** The Detailed family draws coverage, white and premultiplied, into its mask, which cuts both gradients and the hover slice to the waveform. 3-Band and Spectrum paint their colors into one layer under the sides' mask. A rebuild draws the picture once, from the displayed samples, and installs it with actions off. The layer tree never holds a path, so a moving or scrolling waveform costs the render server no scan conversion. `VibeNewLayerImage` (`WaveformRenderer.h`) is the image factory of the bar styles and Wiggle. The step styles draw through a picture they keep (below). **A picture is painted in its window's color space** (`pictureColorSpace`, which a mac view sets). Core Animation color-matched an sRGB picture at every commit, which took half the main thread while a long file loaded on an external display. 3-Band and Spectrum convert their fills into it once.

- **TRAP: a picture is 32-bit premultiplied ARGB, never an alpha-only image.** An alpha-only mask draws nothing under `renderInContext:`, which the registry's bake uses.
- **TRAP: in a `geometryFlipped` tree a layer shows its contents upside down.** `waveform/WaveformView`'s iOS scrubber is one. A picture for a layer whose `contentsAreFlipped` is written bottom-up, which `VibeNewLayerImage` does from the flag.

**The picture covers `renderRect`, by default the whole bounds** (`renderPixelsForSize:`). The layer's frame is that window, so a view far wider than the screen can draw only the stretch it shows. The window is part of the geometry the morph engine compares, so a window that moves with nothing else changed redraws.

**A step style keeps its last picture and redraws only what changed** (`VibeStepPicture`). A rebuild compares the samples with those it last drew. It redraws the pixel columns whose samples changed, those a moved window newly shows, and those by either window's edges, where 3-Band's reads between column centers are cut off. It copies the rest, but only the rows the last picture inked. A streaming load changes only its front, and every frame of its ease drew the whole picture again. While the samples ease, the pixels are recycled once the layer lets an image go. At rest a picture is a fresh `calloc` that faults in only the rows it inks, so a spare would only double the memory.

- **TRAP: everything the raster reads but the samples and the window's pixels goes in the picture's `Look`.** An input left out draws stale wherever the samples did not change. The tests draw each step style in part and whole, and compare the bytes.
- **Each style says when copying stops paying** (the share of the picture to draw, past which it draws it all). Detailed's coverage costs less than a copy. Scrolled by half its width, copying the other half cost a third more than drawing it, so Detailed copies only while under a quarter changes: a load's front. 3-Band paints seven spans a column, so it copies up to three quarters.
- **A picture's raster is called inline in its renderer.** Called through a pointer, the same loop cost 3 to 9% more.

**Wiggle draws its centerline directly.** Core Graphics strokes `VibeNewWigglePath` into the mask's picture. The path includes only the loops near the render window. It keeps a loop beyond each stroke edge to leave the end caps outside the picture. Never expand it into a filled outline first. That repeats the stroker's work on every resize and morph frame.

## Zoom steps

**The Detailed types, 3-Band, and Spectrum read the waveform only at zoom steps** (`waveform/Waveform/AGENTS.md`). A step's columns cover fixed frames of the track. Each view draws the two steps around its scale and crossfades them by how near it is to each. A resize inside a step reads nothing new. It only resamples the same columns onto the new pixels, so every pixel changes continuously and nothing reshuffles. Columns read per pixel instead re-partition the track on every resize, and fine texture ripples.

**A style wants a number of columns a point** (`columnsPerPoint`, or the rate it passes to `updateStepTargetForSize:`). Detailed wants 2, and Oversampled 2x, 4x, and 8x want 4, 8, and 16. That oversampling is their look, the same at every width, until their columns are finer than a bin. There each column is a slice of the stream's own line, and a pixel holding several drew the mean of their slices, so the line went faint. So below a bin their columns are no finer than a pixel (`columnsPerPixelForWaveform:width:`), a floor that rises with the zoom. 3-Band wants one a point, so zoomed in it resolves each hit, and one a pixel at deep zoom (3-Band, below). Spectrum wants one a pixel, since its colors change from pixel to pixel. The Detailed types land each column in the pixels it overlaps by its share, so a pixel's coverage is the mean of its columns' spans (`ColumnCoverage`). 3-Band and Spectrum read their levels linearly between column centers, as their polygons did.

**The samples are laid out by the window's columns** (`_window`, part after part). `updateStepTargetForSize:` tells the morph engine when the columns change. A settled change installs at once. One that eases first moves the displayed samples to the new layout by the track's frames (`RemapStepSamples`), so a resize across a step or a scroll mid-morph keeps its motion.

**The base renderer owns the window.** It hands the window to the morph engine with the size, so a scroll alone redraws. It dips a step style's columns for the convert sweep. It refills the columns when deep zoom's blocks land in the waveform's detail, and they ease to the finer picture.

**Each style says how deep a zoom may show it** (`minimumFramesPerPointForWaveform:`). The bar styles stop where their 1,024 bars stop growing in number, since past that they only widen. 3-Band, Spectrum, and Wiggle stop at a bin a point. The Detailed types reach the stream's own frames once the waveform is complete.

`WaveformZoomMath.h` is the zoom floor of the iOS scrubber, `waveform/WaveformView`'s. It sits here because three renderers read it.

## Level mapping

**A height draws the loudest short window, not the mean and not the peak.** Every style reads a column's `loudest` (`waveform/Waveform/AGENTS.md`): the RMS of the loudest 20 ms it covers. `VibeWaveformBarLevel` (`WaveformLevelMath.h`, pinned by `WaveformLevelMathTests`) is the one level mapping: that RMS against `kVibeWaveformFullScaleRMS`. **Transients outrank energy.** A mean over a coarse column averages each hit into the sound around it, so zoomed out the kicks vanish. Peaks peg on limited masters, and the strip reads as a block. The loudest window still rises on each kick. It is a union, so a resize that moves a column's edges cannot hide a hit or ripple the levels.

**The bar styles read count bars' own levels across the track** (`fillLevels:`, and Bars through Detailed's `fillColumns:`). Bars, Cupertino, Sonic Cirrus, and Wiggle never draw more than 1,024, so a bar is never finer than `kVibeWaveformLevelColumns`. Bars keeps each bar's min and max as its shape, scaled so its peak draws its level. Cupertino draws ±level.

**The Detailed types scale each column's own min and max by the level around it** (`fillColumns:`). DC-offset asymmetry and fine texture survive, and the heights still follow the level. The level is read on a grid of its own, no finer than 1/1024 of the track, so zoomed in the stream's own shape draws under one smooth gain. A column scales by the level over its peak, read linearly between the grid columns' centers, so no edge of the grid shows when zoomed in. **TRAP: the level grid is never finer than four pixels** (`kLevelPixels`). Its levels change from column to column, and finer than a pixel they alias into a comb that slides as a resize moves it. The grid is a multiple of the step's own columns, so a step keeps one grid at every width. **TRAP: a column scales its own peaks by the level over its peak, capped at the louder level beside it** (`fillColumns:`). A column holding a transient then draws the transient's level, and the quiet columns beside it stay quiet. Scaled to the level directly, they would be drawn up to the transient's.

**Normalize and Gain are the renderer's `normalizesLevels` and `gainDB`.** Each view hands them over as it does the theme. In the mix styles Normalize only raises. `VibeWaveformFullScaleRMSForWaveform` caps the track's loudest window at the fixed reference. **The reference is the track's, never the drawn bars'**, so a resize cannot move it. Read from the drawn bars, it moved 2 to 11% as their count changed, and the whole picture breathed. Every column's level is a union, so the column holding the loudest window reaches full height in every style. 3-Band and Spectrum measure their own reference on the same rule (below).

**The mix styles' Normalize waits for the whole track** (`AudioWaveform`'s `isComplete`). A streaming load's loudest window is only the loudest so far, so a reference re-measured per delivery would shrink bars already drawn. A partial waveform draws at the fixed reference, and the completing delivery raises it. 3-Band and Spectrum differ, because their Normalize also lowers (below). Gain is a display gain ahead of the clamp plus a curve bend (`kVibeWaveformGainDBPerExponentDoubling`). **A level change is a target change under the same identity**, which the morph's fast path would skip. So both setters call `invalidateTarget`, and the bars ease to their new heights. Progress ignores both.

## Centered

**`centered`, on by default, draws about the midline. Off grounds every bar on the band's foot (`VibeBarBaseline`)** at the height it had about the midline. The level mapping and the seek band stay as they are. **The ramp reaches below the band, so a grounded foot is as bright as the midline it left** (`VibeBarRampDrop`). Without the drop, every quiet grounded bar sat in its dimmest stretch. Three geometry homes read `centered`: `VibeFillSpans` (Detailed, Bars, and Cupertino), 3-Band's `rebuildPicture`, and `VibeNewWigglePath`. Cupertino's fade mirrors its bars about the midline, so grounded it takes Bars' ramp. Sonic Cirrus and Progress ignore it (`supportsCenteringForIdentifier:`). The app pushes it, as it does the theme. An app's switch dims for a style that ignores it.

## Bar count and thickness

**The count follows the drawn width at the style's designed pitch**, so a resize adds bars rather than stretching them. Bars, Cupertino, and Sonic Cirrus share `blockBarCountForWidth:` (4 pt, capped at 1,024). Wiggle uses `numBarsForWidth:`. `barDensity` multiplies the block and Wiggle counts. Detailed in every type and Progress ignore it. The step styles draw their columns a point instead. `barWidthScale` scales bar thickness, or Wiggle's stroke, without changing the count. Discrete bars share `scaledBarWidth:pitch:` to stop at their slot edges. Width also scales Progress's pill heights. The registry gates density and width separately. Wiggle's count reads `samplingWidth` when set, so a pinch on `waveform/WaveformView`'s iOS scrubber stretches its loops instead of resampling them.

## The morph engine

`WaveformMorphEngine` owns the displayed and target vectors, the 60 Hz ease, and the retarget decision tree. Each family installs a geometry callback and a fill. **Do not duplicate it per family.** Its header states the decision tree. The rules a caller is checked against:

- **`identity` is compare-only and never dereferenced.** It cannot false-match, because the view retains the old waveform while the new one is allocated.
- **A geometry change rebuilds at once. A content change eases.** The geometry is the size and the render window. A settled waveform's count or layout change installs the new samples in one rebuild. A resize mid-morph carries the displayed samples over and keeps easing, so loading, gain, and the convert sweep survive a resize. A step style carries them by the track's frames (Zoom steps, above). The others carry them by nearest bar.
- **A nil to non-nil identity flip rebuilds even when the samples are unchanged.** A silent track's all-zero waveform equals the collapsed target, but it draws hairlines. `barMinHeight` is 1 with a waveform and 0 without, and the Detailed family reads it from the engine.
- **The Detailed family pixel-rounds only when settled.** Rounding mid-morph quantizes the motion into visible steps.
- **A sample within the ease's threshold of its target lands on it.** Each frame then changes only the samples still moving, so a picture redraws only them. Eased forever toward their targets, every sample a load had reached kept changing by a hair.
- **`settleImmediately` exists because every morph frame is a full repaint.** Settling an unseen renderer avoids that work. The base forwards it as `settleMorphImmediately`.
- **An empty view keeps no buffers sized for the waveform it last drew.** A cleared picture eases flat, and once it settles the engine drops its samples and keeps an empty target until a waveform arrives. The families then drop their own fill and span buffers, and the picture's contents go. Kept, they held about 7 MB at rest with no track loaded.

## The convert sweep

**An app can draw a long job's progress with the waveform itself.** `dipBarsFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span and rebuilds once, so the notch shows at zero. The standard ease then carries them back to the unchanged target, which draws the graded trail. The span rounds outward to whole bars, or for a step style to whole columns of each step, so an edge bar is never half-zeroed. Keeping the front and feeding only the new span is the view's job.

## 3-Band

A DJ player's 3-band display: the low, mid, and high bands' levels. **It is its own class because its fill is seven colors.** The Detailed family uses a theme gradient and one mask. Sonic Cirrus colors discrete layers. The morph engine carries three samples per column. **The bands exist only in a waveform decoded for a request that asked for them** (`readsBandsForIdentifier:`). A waveform without them draws the silent hairline until the band decode lands.

**Each height shows the set of bands reaching it.** Each pixel column paints seven spans, each out to the lowest band of its set, mirrored about the midline or standing on the baseline. The spans paint in order: the three bands alone, the three pairs, then all three. A set's lowest band is never above a subset's, so the envelopes nest and the painter's order alone colors them. **A row takes each color by the area it shows there** (`ColumnPaint`). Painting coverage over coverage would stack edges that coincide, such as silence's hairline, into a bolder line. The levels read linearly between the columns' centers, so the tops are smooth. 3-Band shares Detailed's band, seek band, and hover slice (`VibeBarVScale`). The hover slice is masked by the picture itself.

**3-Band and Spectrum keep the all-bands hairline even after a clear**, so a cleared picture collapses onto it, as they draw silence. With the engine's floor, the hairline dropped at the clear, and 3-Band's stacked bands blended into stray colors as they shrank below a pixel. An empty view that has settled still draws nothing, because every settle to empty releases the samples. The Detailed family's collapse still vanishes, and Wiggle still fades its baseline.

**At deep zoom each height is raised toward the peaks' shape** (`fillBandLevels:`). A kick's low band builds for 40 to 60 ms after its attack, while its peaks jump at once. Zoomed in, the bands alone drew each kick rising late and round. So a column's peak is scaled by each band's level and the peak in the next 60 ms (`kPeakShapeReachSeconds`). Spectrum scales its tallest band the same way. The attack then stands at the level the kick builds to. The shape only raises a height, and never above the level ahead, so the quiet columns before a hit stay quiet. **The window looks only ahead.** One reaching behind as well raised a kick's body to the hi-hat just after it, and its tail to its plateau. It is a window per column, not Detailed's grid, because a grid edge inside an attack cut the attack down.

**The shape trusts the peaks to mark a hit.** A master limited so hard that its peaks stay pinned between kicks would raise each column to the kick ahead, up to 60 ms early. Real kicks still move the peaks on the loudest tracks checked. **Its weight fades in as pixels narrow from 20 ms to 5 ms** (`VibeWaveformPeakShapeWeight`). So the rest zoom keeps the bands' heights, and a pinch changes them continuously. The weight is by the pixel, not the column, so both styles take the same share of it. As it fades in, 3-Band moves from a column a point to a column a pixel, as Spectrum reads. Read three pixels wide, each attack rose over them. The window costs a deep-zoom redraw up to about 10% more instructions.

**Each band tops out at its own ceiling** (`kBandCeiling`): the lows the whole band, the mids three quarters, the highs half. So the bands nest as a DJ's waveform does, the lows outside and the highs as each hit's tip. Measured against one shared reference, a band's loudest windows jump with its percussion: on a hot club master the mids and highs pegged with the lows, and the whole strip read as the all-bands color.

**Normalize measures each band against its own loudest window.** Each band reaches its ceiling at its loudest column, raised or lowered, so a hot master's bands fill their ceilings rather than pegging. Without Normalize, each band is measured against its share of the fixed full scale (`kVibeWaveformBandShares`). Measured against the whole full scale, the mids and highs all but vanished. **While a load streams, each band takes the louder of its share and its loudest window so far** (`VibeWaveformReference`, the mix styles' rule too). With the share alone, a hot master's bands pegged until the decode completed, and then the whole strip shrank at once. The reference now settles once the loudest part has decoded, usually the first drop. The references are the whole track's, whatever the width, so a resize measures nothing. No renderer keeps a reference of its own, because a view can drop its waveform without telling the renderer. Gain moves all three bands alike.

**The fills are the theme's `bandColors`, in painter's order.** The theme also gives the gradient and the hover slice. The gradient is Detailed's ramp over Detailed's band, which `flatFill` drops. It is not a fade mirrored about the midline, because the outer ring is most of what 3-Band shows. The palettes are `WaveformTheme`'s (The theme, above). A change of fills redraws the picture. **The picture is drawn once, under one mask with two sides** split at the playhead. The played side is at full level, the unplayed at half, and each carries the ramp. The mask dims the composited picture, so the outer rings never show through the inner ones.

## Spectrum

`SpectrumWaveformRenderer` subclasses 3-Band in `ThreeBandWaveformRenderer.mm`. It shares the height mapping, normalization, and morph. Spectrum reads a column a pixel. A backing-scale change takes effect on the next waveform update.

**Each column is as tall as its tallest band.** At deep zoom 3-Band's rings and Spectrum's outline take the peaks' shape (3-Band, above).

Each column carries its outline's height and three color levels. **Colors use a tent window of their own, centered on the column, 2 s from centre to foot and never narrower than two columns** (`kVibeWaveformSpectrumColorSeconds`, read through `tentBandMeanSquares`), without the height mapping's clamp. A column's color is its bar's mix, while its height still shows each hit. A window shorter than a bar leaks the bar's own pattern. On a drum loop it drew stripes a bar apart. At 2 s a side, the beat, the backbeat, and a one-bar pattern each leak under 5% from 100 to 174 BPM. **The window is fixed in time, not a share of the track.** At 1/256 of the track it spanned a beat on a short track, and it leaked 69% of a one-bar pattern on a 5-minute track at 128 BPM. A column-long window alternates between the kick's and the hats' hues from pixel to pixel, and the comb crawls as a resize slides the windows. A window locked to the tempo would cancel these exactly. It would also change the colors at the end of every first decode, since detection answers only then.

**Precise's tents stop at the section edges** (`keepTents:`), the sections By section finds. A tent that would cross an edge moves inside its section whole, or narrows to a section shorter than it. Crossing, it colored the two seconds before a kick came back by the kick. So both colorings change at the same place. Precise then fits the sections on every fill, about 2M instructions, a tenth of a deep-zoom redraw.

Each color level is RMS divided by its band's share (`kVibeWaveformBandShares`), which weighs the mids and highs up against music's falling spectrum. Display gain affects only heights. `VibeSpectrumColor` weights the primaries by the fourth power of these levels. It restores the weighted brightness of the primaries after mixing. Silence uses their plain mean. Only the level ratios affect color. Precise involves no beat detection, and reads the sections only for their edges.

**By section colors each section of the track by its whole mix** (`WaveformTheme.spectrumColorsBySection`). The track is a grid of half-second columns, or of 512 columns when it is longer than 256 s (`VibeWaveformSectionFramesPerColumn`). Each column reads its bands under a tent one column from centre to foot. `VibeWaveformSectionStarts` fits the columns' mixes with sections that are constant inside. The fit pays a penalty for each section and keeps each section at least 8 columns long. It is exact dynamic programming and takes about 0.25 ms for 512 columns.

**The grid finds a section, and the bins place its edge** (`VibeSpectrumSections`). A grid column is half a second or more, and the minimum length can push an edge a whole column late. So each edge moves to where the bands' levels change, within two columns of it, read a bin at a time (`VibeWaveformSectionSplit`). The levels lag a kick's attack by its 40 to 60 ms build, so the peaks then move the edge onto the hit itself (`VibeWaveformSectionSnapToHit`). The edge lands on the first kick's attack, not on the column it falls in, nor partway into its build. **The color follows the height.** A drawn column an edge falls inside takes the side holding its loudest peak, since that peak sets its height (`VibeSectionOfColumn`). A pixel read between two columns takes the colors of the one giving it more height. By a column's center or a blend, a kick's first pixel drew tall in the color before it. A section is colored by the mean of the grid columns whose centers it holds. Each drawn column takes the section under its center.

The grid and the bins follow the track, so a zoom, a scroll, or a resize never moves a section's edge. It spans `totalFrames`, so a streaming load's columns stay where they land. A change of mix shorter than about three columns cannot pay for a section, so a drum fill keeps its neighbors' color. The fit runs once per fill, and both step parts read it. It keeps nothing between fills, so a view that drops its waveform leaves nothing stale. **The coloring is part of the target.** A change calls `invalidateTarget`, which only marks the target stale. So a view draws after every theme refresh.

Each pixel column paints its outline in its own mix, the color levels read between column centers like the heights. Spectrum always uses a flat fill. The unplayed side has half the played side's opacity.

Spectrum reads `spectrumColors`. Each renderer declares its palette through `paletteKind`. The registry uses that choice for an app's settings palettes and theme-list swatches. Spectrum's palettes are RGB, Blue, Green, and Custom (The theme, above). Custom shares 3-Band's Low, Mid, and High wells.

## Tests

`Tests/waveform/WaveformStyles/` holds the tests of the styles, the theme, and the math. `AudioWaveformTests` keeps its name from Vibe. It draws every style into a layer with no window and checks its pixels: the bakes, the played side and the hover, Centered, the bar count and width, Normalize, the morph across a resize, 3-Band's rings and ceilings, Spectrum's colors and sections, the convert sweep, and every step style drawn in part and whole. `WaveformThemeTests` holds the palettes and the clamps. It sits in the tests' `Mac/` half, since it imports AppKit. `WaveformLevelMathTests` and `WaveformZoomMathTests` hold the math. The waveforms they draw are built bin by bin through `Tests/Support/WaveformTestSupport.h`. The minimal consumer draws a tone in every style and reads back that each drew.

Vibe keeps the tests of its own mapping onto the theme, `WaveformThemeSettingsTests`. The views' tests are `waveform/WaveformView`'s.

**Measuring.** A change that could move cost is measured in Vibe, with its `vibe-perf` skill, before and after. Its `ui-waveform` benchmarks draw every style, and dump every picture for a byte comparison. A change that could move a picture is drawn with its `vibe-waveform` skill at both commits, and the pictures are compared with `cmp`.

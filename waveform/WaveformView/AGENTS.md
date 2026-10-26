# waveform/WaveformView

The views that host a waveform renderer. It depends on `waveform/WaveformStyles` for the renderers, the registry, the morph engine, the theme, and the zoom math, on `waveform/Waveform` for the summary, on `ui/Controls` for the loading indicator, on `core/Graphics` for the appearance helpers, and on `core/Common` for the signpost and tally macros. It holds the mac view in its `Mac/` half, the iOS scrubber in its `iOS/` half, and the accessibility contract both share. It came from Vibe. It names no app type. It reads no setting and no string. It loads nothing: the app owns the loader and hands each view what to draw.

| File | Owns |
| --- | --- |
| `WaveformAccessibility.h` | the slider's step and its spoken value, shared by both views |
| `Mac/WaveformView` | the mac's `NSView`: the renderer's layer tree, progress, hover, click and drag, the playhead line, accessibility, and the convert sweep |
| `Mac/WaveformView+Loading` | the mac view's two states with no waveform: loading and empty |
| `Mac/WaveformViewInternal.h` | the private surface the mac view's files share |
| `Mac/WaveformView+Debug.h` | the mac view's seam: whether the renderer still eases |
| `iOS/WaveformScrubberView` | the iOS scrubber: the scroll, the zoom, the renderer and theme, the window it draws, progress, and accessibility |
| `iOS/WaveformScrubberView+Loading.mm` | the scrubber's loading indicator and the span it covers |
| `iOS/WaveformScrubberView+Gestures.mm` | the touch scrub, the tap, and the pinch |
| `iOS/WaveformScrubberViewInternal.h` | the private surface the scrubber's files share |

## How an app uses it

List `VibeLibsWaveformView`. It lists WaveformStyles', Waveform's, Controls', Graphics', and Common's templates. Its sources are Objective-C++, so **the app builds C++ as C++17 or later**, as Waveform needs. The template links QuartzCore, and AppKit or UIKit, itself, since Xcode builds Objective-C++ with `-fno-cxx-modules`. The platform's framework is `VIBE_LIBS_UI_FRAMEWORK`, which Common's template sets for each SDK, because a conditional `OTHER_LDFLAGS` would replace every other template's flags. The comment at that setting carries the trap.

```objc
WaveformView *view = [[WaveformView alloc] initWithFrame:frame];
view.themeProvider = ^WaveformTheme *(BOOL isDark, NSColor *artworkColor) {
    return [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:isDark
                                artworkColor:artworkColor customPlayed:nil customUnplayed:nil];
};
view.delegate = self;                    // the seek, and each theme resolution
[view setWaveformStyle:@"detailed"];
[view prepareForWaveformLoad];
[view showWaveform:summary];             // a CodableAudioWaveform, from the app's loader
view.progress = 0.25;
```

**The app owns the policy.** It owns the loader and the cache, and it hands each view a reset, then each delivery. It maps its settings onto a theme in the `themeProvider` block. It pushes the style, the levels, Centered, the bar density and width, and the drag behavior. It labels each view for accessibility where it builds it, so the views read no strings. A view with no provider draws Mono.

## The theme

**Each view resolves its theme only through the `themeProvider` block an app installs** (`WaveformThemeProvider`, `WaveformTheme.h`). It passes the appearance it draws in and the artwork color settled on it. It resolves again on an appearance flip. The theme beats the style's built-in palette. `waveform/WaveformStyles/AGENTS.md` holds the theme's own rules.

**The artwork color is per view, not per app**, because a pager shows a different track on every page. An app sets `artworkThemeColor` as it installs the art, so the color rides the art's install. On the mac, the color waits for the install's `refreshThemeColors`. The scrubber re-resolves from the setter.

**`flatFill` is the mac's alone.** The scrubber never sets it.

**The playhead line.** With a `playheadColor` on the resolved theme, each view tells its renderer a progress of 1, so the whole track draws as played. The view draws the line itself, in one layer of its own above the renderer's tree. The mac's line moves across the waveform. The scrubber's stays at center while the content moves.

## The loading indicator

The control is `ui/Controls`' `LoadingIndicator`, and its traps are in `ui/Controls/AGENTS.md`. **Each view owns only when it shows and how wide.** The mac view hands it the whole width. The scrubber hands it the span its content occupies.

**The fill eases to each reported fraction and never runs past it.** An app reports a download's fraction, which arrives about once a second. Snapping would stutter, and running ahead would hide a stall. Each ease takes half the previous gap, capped, then holds.

## Accessibility

**Both views are sliders** (`NSAccessibilitySliderRole`, `UIAccessibilityTraitAdjustable`). The waveform is the only pointer or touch seek, so there is no other control to fall back to. The step and the spoken value are `WaveformAccessibility.h`.

- **The step is 5% of the track (`kWaveformAccessibilityStep`), not seconds.** Each view knows a 0 to 1 progress and reports a 0 to 1 seek, never the duration.
- **An adjustment reports the seek and waits for the position to come back** through the owner's normal progress write. Writing local progress would show a playhead that has not moved, and it would fight the next tick.
- **The value is a whole percentage** (`VibeWaveformAccessibilityValue`), since VoiceOver reads a bare 0.5 as "zero point five".

Neither view is adjustable with nothing loaded. The scrubber's `accessibilityIdentifier`, `waveform-scrubber`, names the element for a UI test's pinch and is unrelated to the above.

## ObjC++ boundary

The views are `.mm` for the C++ sample vectors. **Keep C++ types out of any header a plain Objective-C `.m` imports.** `WaveformView.h`, `WaveformView+Loading.h`, `WaveformScrubberView.h`, and `WaveformAccessibility.h` are plain Objective-C. They forward-declare `CodableAudioWaveform`. The two `Internal.h` headers import `WaveformRenderer.h`, so only `.mm` files may import them.

## Mac/: the waveform view

`WaveformView` is a CALayer-based `NSView` that draws through a renderer. **It is a pure rendering surface.** The app owns the cache and requests loads. It forwards deliveries: `prepareForWaveformLoad` to reset, then `showWaveform:`.

### The three states

- **Waveform**: the renderer's layer tree.
- **Loading**: `showLoadingIndicator`, the loading control in its waveform style. When it shows is the app's.
- **Empty**: `showEmptyPlaceholder`, a static midline for the no-track state. It is the same control at rest.

Loading and empty are mutually exclusive, and `prepareForWaveformLoad` clears both.

**TRAP: feed every delivery directly into the running morph, completion included.** Holding the first leaves an empty strip after a skip as the outgoing bars collapse. Settling partials breaks the continuous ease. A window no one can see settles each delivery at once, since every eased frame is a full raster on main. With no window, that is every delivery. The morph eases from the displayed bars at 60 Hz, so a newer snapshot bends the motion rather than snapping it. A loader that limits its partial snapshots to about 10 Hz needs no pacing here. Normalize's completing raise uses the same morph.

### Progress

`setProgress:` repaints only on **device-pixel crossings**, using `devicePixelWidth`. That self-gating is what makes a fast tick rate affordable. An app may read `devicePixelWidth` to choose its tick rate, so a resize resyncs it.

**Under a playhead line the renderer is told 1, and the line carries the position** (`playedProgress`, `layoutPlayheadLine`). The line moves on the same pixel crossings and is clamped inside the bounds, so it shows at both ends of the track. It is hidden with nothing loaded.

### Hover and click

While the cursor is over a loaded waveform, the waveform marks the column under it. Nothing is drawn on top, and there is no tooltip. The view only passes the cursor's x to `setHoverHighlightX:`, where a negative value clears it. Each renderer family marks it its own way (`waveform/WaveformStyles/AGENTS.md`).

**Over the unplayed side the column is lit in the theme's `hoverColor`. Over the played side it shows the unplayed side.** Under a playhead line the whole waveform is played, so there the column always shows the unplayed side. `updateProgress:` re-places the column, because the playhead can cross a still cursor.

**Hover and click-to-seek are gated on having a waveform.** That is how the empty, loading, and parked states opt out. Every presentation reset (`resetWaveformContentState`) also clears a press or drag in flight, so a mouse-up cannot seek after the track changed.

### Pushed settings

**The view reads no store.** An app pushes everything it draws from: the bar density, the bar width and Centered, Normalize and gain, `dragSeeks`, and last the style. The style's set is the one draw, so the bars ease to a new level mapping under a slider drag.

### Drag behavior

`dragSeeks` decides what a drag that starts on the waveform does. The view stashes it once per mouse-down, so a push cannot change a drag mid-flight.

**TRAP: `mouseDownCanMoveWindow` is a constant NO.** AppKit caches the answer in the window's movable region when the view joins the window. An answer derived from the setting or the loaded state goes stale, and seek mode then scrubbed while the window moved. Moving the window is per gesture, through `performWindowDragWithEvent:`.

- **Off**, the default: a stationary click seeks. A drag past the 4 pt hysteresis (`kWaveformDragHysteresis`) disarms the press and hands the gesture to `performWindowDragWithEvent:`. `mouseUp:` also bails when the window origin or the cursor moved, for a release that still arrives after the handoff.
- **On**: the window stays put and the drag scrubs. Past the hysteresis the column under the cursor shows through `setHoverHighlightX:`, clamped to the bounds, while real progress keeps painting. The audio seeks once on release, to the clamped fraction. The release skips the containment test, since the drag may end outside the view.

With no waveform, or outside the renderer's seek hit band, `mouseDown:` hands the event to `performWindowDragWithEvent:` at once in every mode. So the empty and loading states and the view's margins always drag the window. A window that declines the handoff, as an app's locked window does, leaves a disarmed drag doing nothing. A stationary click still seeks.

### The convert sweep

`convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed while they recover. A value at or below the front only moves the front, which is the reset after a conversion. It is gated on having a waveform and resets with every presentation reset. The mechanism is in `waveform/WaveformStyles/AGENTS.md`, The convert sweep.

### The seam

`WaveformView+Debug.h` declares `debugWaveformEasing`: whether the renderer still eases. A cleared picture keeps its buffers until it settles flat, so a resting sample waits for it. The header carries no `#if DEBUG`. The method compiles only under `DEBUG`, in the view's own file. `Tests/waveform/WaveformView/Mac/WaveformViewProbe.m` compiles the header.

## iOS/: the scrubber

`WaveformScrubberView` is the renderers on UIKit, DJ style. **The play position is fixed at the view's horizontal center, and the waveform scrolls beneath it.**

The renderer draws the whole track across a *virtual* width: the view width divided by `visibleFraction` (0.48 at rest). **A `UIScrollView` carries it.** The virtual width is the content size, and the insets are half a view on each side. So `contentOffset.x == progress·virtualWidth - centerX`, and both ends of the track park under the center. UIKit supplies the drag, the deceleration, and the rubber-band at both ends. `decelerationRate` is `Fast`.

The view is split like the mac's. `WaveformScrubberView.mm` is the core: the scroll, the zoom, the renderer and theme, the window it draws, progress, accessibility, `cancelInteraction`, `resetWaveformContentState`, layout, and showing a waveform. `+Loading.mm` is the loading indicator. `+Gestures.mm` is the touch scrub, the tap, and the pinch. `WaveformScrubberViewInternal.h` holds the ivars and the cross-file methods. It is Objective-C++ only, because it imports `WaveformRenderer.h`.

### Zoom

**`visibleFraction` is the user's request, not what is drawn.** A pinch drives it. `effectiveVisibleFraction` is a computed accessor that clamps it to the deepest zoom the waveform can draw. `virtualWidth` reads the effective value, so the content size, the offset mapping, and the buckets are all clamped without knowing it.

**The floor is derived, not a constant** (`waveform/WaveformStyles/WaveformZoomMath.h`). Each style answers its own (`minimumFramesPerPointForWaveform:`). A style that reads the summary alone stops at a bin a point, three pixels a bin at 3x. Finer, the summary has nothing more to draw. The bar styles stop sooner, where their bars stop growing in number. The floor is also no wider than float geometry keeps sharp. So it moves with the track, the style, and the view's width. Clamping the stored value there would shallow the user's zoom for good on one short track. **An app persists the request, never the effective value.**

**A pinch frame draws again.** The step styles read fixed columns at zoom steps, so a frame inside a step only resamples them, and every frame stays sharp. A pinch frame draws no margin, since the next frame draws again. The gesture's end draws the margins back.

**A complete waveform zooms past its bins on the stream's own frames** in the Detailed types, down to eight points a frame (`kVibeWaveformMinimumDetailFramesPerPoint`). The width cap stops a 4:40 song near 12 frames a point, and a loop reaches its samples, drawn as the line through them. A draw that finds detail blocks missing leaves them in the waveform's detail. After the draw the view takes them and asks its delegate for them, one request at a time (`needsDetailBlocks:`). The app reads them through its cache, and the view refills as they land. Until then the bins draw. A block that cannot be read is asked for again only by a later draw that lacks it, so a file gone from disk cannot loop. A streaming waveform keeps the bins' floor.

The fraction is written live, so the content size and end stops are honest on every frame. `UIScrollView`'s own `zoomScale` is the wrong shape. It scales both axes and anchors on the pinch centroid, but the playhead must stay at center.

**TRAP: park the content offset unconditionally on every pinch frame** (`parkContentOffsetAtProgress`). `syncContentOffsetToProgress` declines while `isScrubbing`, and the pinch's own fingers keep the scroll's pan reporting `isTracking`. Without the park, the playhead drifts off center as the zoom changes.

#### Pinch and scrub are one continuous gesture

A finger already scrubbing must be able to start a zoom. Lifting back to one finger must return to scrubbing without the hand leaving the glass. Four traps make that work.

**TRAP: the pinch needs `shouldRecognizeSimultaneouslyWithGestureRecognizer:`, or it cannot start during a scrub.** By the time a second finger lands, the scroll's pan has recognized. By default one gesture belongs to one recognizer, so the pinch is refused.

**TRAP: `UIScrollView`'s pan cannot carry a gesture across a change in touch count.** It ends the instant a finger is added or lifted. An ended recognizer is never handed touches that were already down. `UIPinchGestureRecognizer` stays in `Changed` with one touch left. **So from its first frame the pinch owns the gesture to its end.** `trackZoomGestureScrub:` moves the track from the pinch's centroid only when exactly one touch remains. With two, the centroid is the zoom's anchor. It re-anchors on any touch-count change, or the 2-to-1 centroid jump lands as one huge scrub. The pan has no `maximumNumberOfTouches` cap on purpose, because a cap only makes it die sooner.

**TRAP: the dying pan must not finish anything.** Its `endScrub` arrives mid-gesture. Left alone, it would seek to where the finger was when the second one lifted and release an enclosing pager under a live drag. `endScrub` declines while `_isPinching`. `endZoomGesture` settles the seek, the haptics, and the scrubbing callback when the hand leaves. It also stops the pan's coast before clearing `_isPinching`. Otherwise `scrollViewDidScroll:` reads a position out of the coast that no seek follows.

**TRAP: a pure zoom is not a scrub. It must neither freeze the position nor seek.** Two fingers landing start the scroll's pan too, so nearly every pinch sets `_seekPending`. Counting the whole pinch as a scrub froze the picture while the audio played on. The lift then seeked back to the frozen spot, an audible skip. So a pinch scrubs only once it has a seek to commit. `beginZoomGesture` drops a pan scrub that moved less than `kZoomScrubSlop` from `_scrubStartProgress`. `scrollViewWillBeginDragging:` ignores a pan that starts under a live pinch. The one-finger phase needs the same slop before it scrubs, because the finger left behind always wobbles. Until then `isScrubbing` is NO, and playback keeps writing the position.

### Layers and the playhead

**Everything that scrolls is a sublayer of the scroll's layer. Everything that does not is a sublayer of the view's.** The loading indicator must not move with the content. The renderer's tree is in the scroll's layer, at virtual size.

The played and unplayed boundary is the playhead marker. It stays at center **by construction**. The played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates.

**The playhead line replaces that boundary at no cost per frame.** With a `playheadColor` on the resolved theme, the played side spans the whole track (`playedProgress`). The line is one layer of the view's own at its center. So no progress write or zoom frame touches it, and it holds still through a bounce. Whether to draw it is the app's: it pushes `drawsPlayheadLine`. The choice is part of `themeSignature`, so `syncWaveformTheme` applies a flip of the switch.

**The off-track space is empty on purpose.** A hairline continuing the midline past the content's ends reads as a stray line across the view near the start of a track.

**The loading track obeys the same rule.** `loadingTrackBounds` spans only the part of the view the content occupies, clipped to the view. A page swiped onto is at progress 0, so drawn full-width it would put half of itself in the empty space. Showing the indicator on an empty view resets its progress to 0, and the app's next tick restores the real position.

**TRAP: keep the "did the span actually move" test in `syncLoadingTrackToProgress`.** It is the one relayout that can land mid-download. A duration-0 relayout snaps an easing fill to its target. While a file downloads, progress is parked, so the test declines.

The renderer tree hangs off a `geometryFlipped` sublayer that gives the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

### Loading and interaction state

**`cancelInteraction` ends a drag or pinch without seeking or discarding pixels.** An app calls it when the view stops being the current one, and cell reuse calls it through the content reset. It drops the pending seek before disabling the recognizers, since cancellation can send their end callbacks. A pinch still active afterward is ended through `endZoomGesture`, so the shared zoom update still happens.

**Showing a loading indicator keeps an existing waveform.** Cell reuse clears the previous track explicitly. Starting playback on a prepared page must keep its pixels. A positive transfer update creates the indicator if needed.

**Outside a pending playback open, the first waveform shown ends the shimmer but not the fill.** A cached waveform can land while the audio file is still downloading. Then the fill over the drawn waveform is the only sign of the download. That is `ui/Controls`' `endSweepKeepingFill`, whose answer says whether anything is left to keep. This scrubber is its only caller.

### Style and theme

**The view reads no store.** An app pushes the style, `centered`, `drawsPlayheadLine`, and the `themeProvider` block on every configure and on a settings change. `syncWaveformStyle:` is the live swap. It resolves the identifier through the registry's fallback chain, as on the mac, and rebuilds only when the result differs from the current renderer's, since a pager may call it on every cell. A view never synced installs the registry's default. `centered` and `drawsPlayheadLine` land on the next `syncWaveformTheme`, which the push ends with. The new style lands settled, in the same turn.

**TRAP: the swap lays the view out again whatever the zoom floor did.** Installing sizes the renderer's host before the renderer exists, at the floor of no style. Two Detailed types share a deeper floor, so a swap between them at deep zoom kept a host far narrower than the content, and the played side ended far from the playhead.

The scrubber sets `normalizesLevels` on at renderer creation and reads no level setting.

**`syncWaveformTheme` compares against `themeSignature`, which is an instance method.** `album_art` draws from `artworkThemeColor`, which is per view. The setter re-resolves through `syncWaveformTheme` itself, and an unchanged signature costs nothing. **The color is in the signature only under `album_art`.** Left out there, a swipe onto a track with different art would compare equal and keep the previous palette. Under every other theme it is left out on purpose, so late art recolors nothing.

### The live renderer

**The scrubber shows the renderer's own tree**, as the mac view does. Its pictures are layer contents (`waveform/WaveformStyles/AGENTS.md`, Pictures), so scrolling moves textures and the render server scan-converts nothing. A track change discards the renderer, so the next waveform grows out of the midline rather than morphing from the last track's.

**The renderer draws only a window around what the view shows** (`drawRendererWindowForcing:`, the renderer's `renderRect`). It is the visible stretch and half a view either side. A scroll redraws once the visible stretch leaves the window. That redraw leads the scroll: it reaches a whole view ahead and a quarter behind. So playback redraws after a whole view of travel, not half of one, and draws 2.25 views for each view it travels rather than 4. A 3-Band or Spectrum redraw copies the stretch it already drew and draws only the rest. A resize, a zoom, and a new waveform redraw at once. A step style draws the same pixels for the same content wherever its window lands, so a redraw cannot be seen. The content can be far wider than any texture, and it is never drawn whole.

**TRAP: no explicit `CATransaction` on the progress or window path.** On the display link's tick an explicit transaction is top-level and commits the whole tree a second time. `applyPlayedClip` and the window's redraw disable actions on the implicit transaction instead, which nests the renderers' own transactions inside it.

**Each delivery eases in through the morph engine, as on the mac.** The first grows from the midline. A streaming load's newly decoded stretch rises, since undecoded bins read as silence. The complete waveform eases to Normalize's heights. A page hydrated with `animated:NO` lands settled, so a swipe onto a cached page shows it at once. A page handed the complete waveform it already shows does nothing.

### Scrubbing

A drag moves the content 1:1 under the fixed center, with no hover highlight. A tap nudges to the tapped point within the visible window, which also keeps tap-to-start on a parked track. `isScrubbing` is the scroll's `isDragging || isDecelerating || isTracking`, or under a pinch whether it has a seek to commit. So it spans the whole content motion, coast and bounce included. An app keeps its progress writers off while it holds. A tap mid-coast stops the scroll and sends the scrub-end callback itself. Cancelling deceleration does not guarantee `scrollViewDidEndDecelerating:`, and without the callback an enclosing pager stays disabled.

**The time a scrub will land on is delivered, not what is playing.** The playhead never moves, so an app's time labels are the only reading of a scrub's target. `didScrubToProgress:` delivers it per frame.

**TRAP: a scrub seeks only when its gesture ends**, in `endScrub`, or in `endZoomGesture` for a pinch-carried scrub. A seek to 1.0 mid-gesture finishes the track and auto-advances with the finger still down. `UIScrollView` also reports `isDecelerating` during a drag, so no "still moving" test separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment.** So the "no waveform, nothing to scrub" gate rides `scrollEnabled`, set from `setWaveform:`, not `gestureRecognizerShouldBegin:`. The gate is needed because an enclosing pager requires the scrubber's pan to fail. A pan that always begins never fails, which turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed.

**TRAP: that failure requirement is not enough at a content edge.** When the scroll sits *exactly* at an edge, UIKit's nested-scroll arbitration stops its pan from beginning so an ancestor can have the gesture. The pager then inherits the drag, and pushing against an end turns the page instead of bouncing. Arriving at an edge mid-drag is fine. Only *starting* parked at an end fails. So an enclosing pager declines its own pan for touches that hit-test into a loaded scrubber. Both halves are needed. `scrollEnabled` says whether the scrubber wants the drag, and the pager's override stops it being taken away.

**TRAP: an enclosing pager must be held still for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, decided from geometry rather than from which recognizer won. So while the pager could still scroll the way the finger goes, the scrubber clamps at its end instead of bouncing. `didChangeScrubbing:` exists for this. The app holds the pager for the scrub's duration. **It must release it on every path out, including a track change mid-scrub**, or the pager stays locked.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered. The progress write can then skip its park and leave a recycled cell at the previous track's position.

**TRAP: clamp before the cast in `progressBucket`.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end. Converting a negative or overlarge double to `NSUInteger` is undefined.

## Tests

`Tests/waveform/WaveformView/Mac/` holds Vibe's tests of the mac view. `WaveformViewTests` draws the real view into a bitmap with no window server, through `Tests/Support/DrawnViewTestSupport.h`, over waveforms built bin by bin through `Tests/Support/WaveformTestSupport.h`. It checks what the view adds over the renderers: the theme it resolves through a provider of the test's own, the playhead line, the three states, the click and the seeking drag, and the accessibility steps. `WaveformViewProbe.m` compiles the mac view's seam.

The scrubber needs a window, a simulator, and touches, so its tests stay in Vibe, which hosts them in its iOS app. The minimal consumer lays the mac view out with a tone's summary and reads back that both sides drew.

**Measuring.** A change that could move a picture is drawn in Vibe with its `vibe-waveform` skill at both commits, and the pictures are compared with `cmp`. Vibe's debug channel screenshots its main window for the mac view.

# ui/Controls

Controls an app draws itself. It depends on `core/Graphics`, and on `core/Common` for the weak proxy and the helper macros. It came from Vibe. Its shared files are the equalizer bars and the loading indicator, which both platforms draw the same way. Its `Mac/` half holds the symbol button, the drawn slider and switch, the detent slider, the pitch fader and its panel, two image views, the link label, and the window resize timing. None of it reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `EqualizerIndicatorView` | the playing-row marker: five retained pill layers and the level poller |
| `EqualizerLevelSource.h` | what the bars read their levels from, and how they declare demand |
| `EqualizerActivityRules.h`, `EqualizerAnimationMath.h` | when the poller may run, and each bar's target and timing. Header-only and tested |
| `EqualizerIndicatorView+Debug.h` | the bars' seam: process-wide counts of display links, ticks, layouts, and transform writes |
| `LoadingIndicator` | the loading control, in two styles and both modes |
| `LoadingIndicatorMath.h` | each style's metrics. Header-only and tested |
| `LoadingIndicatorView` | the loading control's row style, hosted in a row's gutter |
| `Mac/` | the mac's drawn controls, below |

## How an app uses it

List `VibeLibsControls`. It lists Graphics' and Common's templates. A macOS target sets `excludedPlatform: iOS` and compiles both halves. An iOS target sets `Mac` and compiles only the shared files.

## The indicators

**An app owns placement and visibility. A shared control owns its retained layers, its visual state, and its animation.** Neither indicator imports an audio piece. Each view uses `#if TARGET_OS_OSX` only for its superclass and its layout, appearance, window, alpha, and backing hooks.

### The equalizer bars

`EqualizerIndicatorView` draws five pill bars. Five is the indicator's shape, not a tunable. It owns five retained pill `CALayer`s. It never redraws a bitmap or path for live motion. A material level change writes only the affected layer's model `transform.scale.y`. It replaces one keyed explicit animation that starts from the presentation scale. Core Animation interpolates at display cadence with no app callback per frame. Stable bounds make `layoutBars` a no-op. The poll path never invalidates layout, its row, or any sibling view. The bar color follows the view's own appearance, white on dark and black on light, unless `barColor` overrides it.

**The renderer contract.** The bars do no work while unseen, and they never invent motion:

- `EqualizerLevelSource` is producer-agnostic. It supplies a level snapshot with a monotonic sequence and accepts balanced demand. The control's poller runs at 20 to 30 Hz and reads only that snapshot and the staleness clock. It is a `CADisplayLink` on macOS 14+ and iOS, and a tolerant `NSTimer` on macOS 13. The timer is confined to `startLevelLink`'s `@available` else-branch, which goes when macOS 13 support does. A repeated sequence writes nothing. The threshold and the attack and release durations are in `EqualizerAnimationMath.h`. Activity is the fail-closed decision in `EqualizerActivityRules.h`.
- `audioOutputActive` and `presentationVisible` both default to NO. The poller also needs a source, a window, and nonempty geometry. Starting it declares one consumer. **A nil source is inactive, never a synthetic animation.**
- When audio stops while the row stays visible, the control stops the poller and balances demand at once. It writes the collapsed model scales and lets one keyed release per bar finish on the compositor. That release owns no display link, FFT, timer, callback, or completion.
- Visibility loss, detachment, empty geometry, and source replacement cancel the animations and settle to dots at once. Source replacement releases the old source before requesting the new one.

**What feeds the source is the app's.** `audio/Meter` produces levels and never imports this protocol. An app adopts it in its playback model, over the meter's publisher, and counts the consumers to switch the meter on and off (`audio/Player/AGENTS.md`). The app also decides when audio is output and when a row is materially visible, and pushes both.

`EqualizerIndicatorView+Debug.h` is the bars' seam. It declares four process-wide counters for an app's debug report. The view's hot paths increment them as relaxed atomics. The header carries no `#if DEBUG`. The counters and their getters compile only under `DEBUG`, in the view's own file.

### The loading indicator

`LoadingIndicator` is one control with **two styles and both modes**. It draws a faint track across its bounds, a solid fill over `[0, fraction]`, and, in the waveform style only, a shimmer band sweeping the unfilled rest. Indeterminate is the case where nothing is filled.

**`layoutInBounds:` honors the origin, not just the size.** The iOS scrubber hands it only the span its content occupies (`waveform/WaveformView/AGENTS.md`). Every other site hands it full bounds.

The **waveform style** is the hairline midline both waveform views draw. The views own when it shows and how wide. Its traps are the control's own:

**TRAP: the band sweeps in from before its span and out past the end, and the host layer does not mask to bounds.** So the shimmer rides inside a `masksToBounds` clip layer (`_shimmerClip`) sized to that span. Without it the band draws over whatever sits on one side and out to the window edge on the other.

**TRAP: reinstall the sweep only when its endpoints actually change.** Live resize lands in `installSweepAcrossRemainder:bandWidth:` every frame. An unconditional remove and re-add restarts the 1.2 s sweep each time and freezes the band at the left edge.

**TRAP: when the sweep is reinstalled, carry the running animation's phase over**, or the band snaps back to the left edge. The phase is elapsed time plus the previous carry-over. `animationForKey:` returns a copy that keeps `timeOffset`, so dropping it loses the phase on every reinstall after the first. `beginTime` is 0 until the first transaction commit stamps it. Treat elapsed as 0 then.

The **row style** is a small round-ended pill for a 16 pt number gutter. **It builds no shimmer** (`hasShimmer`). A sweep that small reads as flicker. Its indeterminate motion is a slow whole-pill alpha pulse (`pulseAlpha`). The pulse continues through zero and sub-point progress. A fill at least one point wide retires it.

`LoadingIndicatorMath.h` holds the metrics of each style and is the seam under test. **`LoadingIndicatorMathTests` pins the waveform style's numbers**, so adding or tuning a style cannot move what both waveform views draw. The mac view's empty-state line reads the waveform style's height and track alpha from the same header, so it cannot drift from the loading track.

`LoadingIndicatorView` hosts the row style in a gutter. It is built like `EqualizerIndicatorView`. Its only motion is one repeating `CABasicAnimation` on one layer. **It must not hold a live animation for a row nobody can see.** So an app's row wiring sets `active` to NO on cell reuse and on hiding. The view also drops it when it leaves its window (`viewDidMoveToWindow`, `didMoveToWindow`), which covers scroll-out and detachment. A row scrolled back in is configured again by its table. `endSweepKeepingFill` is never used here. It serves only the iOS scrubber.

## Mac/

AppKit controls drawn with CALayers or in `drawRect:`. None reads an app's settings, strings, or types. An app pushes in what a control shows.

### SymbolButton

A borderless momentary push button (`NSControl`) that draws an SF Symbol. It rasterizes the symbol at the backing scale into a CALayer **mask** over a flat color layer. CALayer cannot tint its contents. The mask keeps the hover, press, and disabled transitions as color fades on the render server.

It fades to its highlight color on hover and dims to half that while pressed. It tracks a drag off and back, sends its action on mouse-up inside, and lets clicks through when disabled. Swapping `symbolName` redraws at once with no fade. Each button sets its own `symbolPointSize`, and the icon draws centered in the frame.

**The state colors keep one relationship**: the factory ratios of the resting alpha (0.55) to hover (0.8), pressed (half of hover), and disabled (0.19). `setSymbolColorsFromRestingColor:` derives all of them from one color, alpha included. So an app dresses a button with one color. **A custom `image` replaces the symbol.** A second layer draws the picture in its own colors, aspect-fit into the box a glyph of the configured size fills. The same states fade its opacity by the same ratios, over full strength at hover. While an image is set, the symbol and colors are ignored. nil returns to the mask.

### Drawn controls

`DrawnControls.h` holds controls drawn in `drawRect:` in place of AppKit's, to AppKit's measured metrics and colors. They draw gray while the window is not key, and at half alpha when disabled.

**TRAP: draw a control yourself to avoid AppKit's SwiftUI control hosts and their Metal startup cost on macOS 26.** A slider subclass that draws itself stays unhosted. `VibeDetentSlider` uses that path. Check the view tree for `_NSCoreHostingView` before changing a control.

- **`VibeSlider`** runs from 0 to 1. Its fill is `trackFillColor`, or the system accent when that is nil. `knobColor` replaces the system knob. It is a VoiceOver slider that steps 5%. Its spoken value is whatever `accessibilityValueFormatter` returns, so the control formats nothing. It sends its action from the mouse-down, from every drag that moves it, and always from the mouse-up, each from its own event handler. So `NSApp.currentEvent` tells a target which one it was. `moveBySteps:` moves it by whole or fractional 5% steps, and sends the action when it moved.
- **`VibeSwitch`** matches the small `NSSwitch`, with its slide, Space under full keyboard access, and a VoiceOver checkbox of the switch subrole. Setting `state` neither slides nor sends the action.
- **`VibeDetentSlider`** is an `NSSlider` with a detent, in a file of its own. It draws ticks above and below the track at `detentValue`, where its action snaps.

### The pitch fader

`PitchFaderView` is a turntable's pitch fader: minus at the top, plus at the bottom, a detent at 0, and a quartz-lock LED that lights at exactly 0. It is drawn like hardware, the same in both appearances. Its pitch is a percent, clamped to `±maxPitch`. `maxPitch` is 8 by default and never reaches 0. Setting the pitch never fires the delegate.

`PitchControlPanel` is the strip around it: a title, a live readout, and the fader. **It is what an app talks to. The fader inside is an implementation detail, so gestures report the panel as the sender.** It vends `kPitchPanelWidth`, its fixed width. As the panel gets short, its header fades out and the fader takes the room.

- A drag moves in 0.1% steps. Within 0.35% of zero it snaps to 0. A click on the scale jumps the knob there and keeps dragging. A double-click resets to 0.
- **Both delegates fire `…DidEndAdjusting:` once per gesture**: on the mouse-up after a click or a drag, on a double-click reset, or after an accessibility step. It is the hook for work too heavy for every drag tick. The per-tick callback is `didChangePitch:`.
- **A click on the title or the readout reports `pitchControlPanelDidClickHeader:`.** The labels pass clicks through to the panel. The panel refuses the window drag, so that click is its own. It drags the window itself from everywhere else. A faded header is not a target.
- `VibeQuartzLockGreen(a)` is the green of the zero LED and of the readout at zero. It takes an alpha, so the LED's glow can use a faint variant.

**The fader is an accessibility slider** (`NSAccessibilitySliderRole`). It is a custom `NSView` with no control to inherit from. Without this the pitch is unreachable with VoiceOver. Its step is **0.5%, not the 0.1% a drag moves by.** Stepping at 0.1% would take 160 presses to cross ±8%. Half a percent divides both 8 and 16 evenly, so stepping always lands back on exactly 0. A step takes the drag's path, with the detent, the rounding, and `didChangePitch:`. It then fires `…DidEndAdjusting:`, since one press is the whole gesture.

**An app pushes everything the panel shows except the hardware look.** It sets the `title` and the fader's VoiceOver label (`faderAccessibilityLabel`). It sets `pitchFormatter`, which writes both the readout and the fader's spoken value, so the two always agree. With no formatter the readout is empty. It sets `cornerRadius` to its window's corner radius. The panel draws only its right corners, strictly inside its bounds. Its left edge is a hairline seam against the app's content. The range is the app's too. It sets `maxPitch` and keeps its player's range in step.

### Image views

- **`CrossfadingImageView`** is a layer-backed `NSImageView`. `setImage:` cross-fades the new image over the old. It vends `kVibeArtCrossfadeDuration`, so an app can fade other views on the same clock. The new image sits beneath the outgoing fade layers. At most two outgoing layers remain, and a third drops the oldest. An in-flight fade never resets to opaque. It is opted out of drag and drop, so file drops fall through to the window.
- **`ScaledImageView`** is an `NSImageView` with a `drawImageOverlayInRect:` hook for subclasses.

### VibeLinkLabel

An `NSTextField` with **one clickable range**, hit-tested against the link's own glyphs. A selectable `NSTextField` would give links for free. But a label can span its window's full width while its text is short and centered. Selectability would turn that strip into an I-beam that also swallows the window's background drag. Hit-testing the glyphs means only those characters take the click, the pointing-hand cursor, and the focus ring.

With no link set it is an ordinary label. It is not focusable, not an accessibility link, and transparent to hits. With a link it is a link named by its visible line, focusable *only* while it carries one, and activated by Return and Space alone. The link's glyphs take the click, and the rest of the line does not.

**TRAP: a reused window (`releasedWhenClosed = NO`) keeps its first responder across a close.** A focused link would come back with its ring drawn on a window the user just opened. The window's owner clears it in `windowWillClose:` with `makeFirstResponder:nil`.

### WindowAnimation.h

`kWindowResizeAnimationDuration` is 0.12 s, the one timing for every resize an app performs itself. AppKit's default scales with the distance, which drags on big jumps. It sits here, the base mac UI piece, because an app's main window and SettingsWindow both read it. A window answers it from `animationResizeTime:`, or sets it as its animation context's duration.

## Tests

`Tests/ui/Controls/` holds the indicators' math and rule tests: `EqualizerActivityRulesTests`, `EqualizerAnimationMathTests`, and `LoadingIndicatorMathTests`. It also holds `ControlsProbe.m`, which compiles the bars' seam, so `Controls-iOS` builds it for iOS too.

`Tests/ui/Controls/Mac/` holds the tests that draw. They run on macOS with no window server. A view renders into a bitmap through `Tests/Support/DrawnViewTestSupport.h`, and the tests assert facts about the pixels. They never compare against a stored image, which breaks on every OS change.

- `EqualizerIndicatorViewTests` runs the bars in a deferred window with a recording `EqualizerLevelSource`. Every gate, a source swap, a reentrant restart, and deallocation must leave one balanced consumer per running poller.
- `LoadingIndicatorTests` covers the loading control's layers, pulse, sweep, and palette, and its row view.
- `PitchFaderViewTests` draws the fader and checks the knob, the LED, and the hardware look. It sends the gestures and the accessibility steps, and checks that each gesture ends once. It also checks what an app pushes into the fader and the panel: the label, the spoken value, the readout, and the corners.
- The drawn-control, symbol-button, and link-label tests, and one that compiles `WindowAnimation.h`. A deferred window is never key, so the fills drawn here are the not-key ones. NSApp is nil, so a sent action is not asserted. A dragging session and a key window need a window server, so the app checks them in its running build.

`DrawnViewTestSupport.h` is shared with SettingsWindow's and WaveformView's tests. Vibe keeps its own copy for its other view tests. The minimal consumer draws the bars from a level source of its own, and checks they ask it once and let go when they leave their window. It draws the pitch fader and its panel, and steps the fader once through its accessibility action.

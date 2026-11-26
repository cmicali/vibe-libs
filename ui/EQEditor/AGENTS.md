# ui/EQEditor

The view an app edits an EQ's bands with, in two faces: a graphic face of ten sliders, and a parametric face that draws the curve, with a node and a row for each band. It depends on `audio/Listening`, for the bands and the curve's math, and on `ui/Controls` and `core/Graphics`, for the drawn switch and the dark-mode check. It was built here for Vibe and another app. **It is macOS only.** Its files sit in its `Mac/` half. None reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `VibeEQEditorView` | the view an app makes: the settings, the face, enabled, the delegate, and the words. It holds the parts and passes each edit between them |
| `VibeEQEditorParts.h` | the parts' calls, which the view and the tests use, not an app |
| `VibeEQGraphicView` | the graphic face: ten sliders drawn in one view |
| `VibeEQCurveView` | the parametric graph: the grid, the curve, and the nodes |
| `VibeEQBandListView` | the parametric list: a row per band, and add and remove |
| `VibeEQFaceTabs` | the faces' tabs, drawn |
| `VibeEQEditorMath.h` | the axes, the steps, the rounding, the hit test, and the Q gestures. Header-only and tested |
| `VibeEQEditorFormat` | how a number is written and read, in a locale's digits |

## How an app uses it

List `VibeLibsEQEditor` in a macOS target. Make a `VibeEQEditorView`, set its `delegate`, `settings`, and `face`, and put it in a window of the app's.

- **It edits only the bands.** The settings it hands back are the app's last ones with new bands. The preamp, crossfeed, the channel tools, the EQ's switch, the presets, and the window are the app's.
- **The delegate hears every change live** (`eqEditorView:didChangeSettings:`), during a drag too, so the app can play it at once. It hears **`eqEditorViewDidEndEditing:` once an edit is over**: a drag let go, a key step, a field committed, a band added or removed, or a slider reset. The app records its undo and saves there. Setting `settings` or `face` calls the delegate never.
- **The face is the app's choice, but the graphic face shows only while the bands fit it**: none, or exactly `+graphicBandsWithGains:`'s layout. Otherwise the parametric face shows, `face` reads so, and the graphic tab is disabled with `graphicUnavailable` as its tooltip and its VoiceOver help. When the bands fit again, the chosen face comes back. Switching a graphic setting to the parametric face keeps its ten bands. `eqEditorViewDidChangeFace:` tells the app the user switched.
- **A flat setting's first graphic edit writes the ten graphic bands**, so an empty EQ opens in the graphic face.
- **`enabled` NO dims every part to half and ignores every click, key, and VoiceOver action.** An app turns it off while the EQ doesn't apply, as under bit-perfect output.
- **The words are the app's.** `strings` holds English defaults. An app sets its own, localized, before the view shows. `locale` sets the numbers' digits.

## The faces

**The graphic face's sliders run ±12 dB in 0.5 dB steps.** A click on a track jumps the knob there, and a grab on the knob keeps its offset. A double-click resets one to 0. A slider's value shows over its knob while it's dragged, and while it has the keys. Left and right choose a slider, up and down move it 0.5 dB, Page Up and Page Down 3 dB, and 0 resets it.

**The parametric graph's frequency axis is log, 20 Hz to 20 kHz. Its dB axis is ±12, and widens to ±24 when a band's gain or the curve passes 12.** The curve is `VibeListeningResponseDB` at 48 kHz, one sample a point. A node sits at its band's frequency and gain. A pass filter has no gain, so its node sits on 0 dB.

- **A drag moves a node's frequency and gain**, to three figures and 0.1 dB. Option-drag changes Q, doubling every 60 points up. A scroll over a node, or the selected one, changes Q too. A pass filter's drag moves only its frequency.
- **TRAP: a drag holds the dB axis.** It may widen when the drag passes 12 dB, and then measures the grab again, but it never narrows until the release. Otherwise every node would jump under the pointer.
- **A trackpad's momentum is ignored**, since it would edit after the edit ended.
- With the keys, Tab moves between the nodes and then out of the graph. Left and right move a node a twelfth of an octave (a third with Shift). Up and down move its gain 0.5 dB (0.1 with Shift). Option with up and down changes Q. Delete removes the band.

**The list edits every band by typing**: its switch, its type, its frequency, its gain, and its Q. A field accepts the locale's digits, and "2.5k" for 2,500. A word that holds no number puts the value back. A pass filter's gain field is empty and can't be edited. **Add** puts a peak at 0 dB in the middle of the widest gap between the bands, on the log axis, up to 20 bands. **Remove** removes the selected band. The graph and the list share the selection.

## Drawing and work

**Everything is drawn in the system's colors and its accent**, so it follows light and dark mode and the user's accent. **TRAP: a grid line is the label color at an alpha** (`VibeEQGridColor`). A separator color given an alpha of its own turns brighter in dark mode, not fainter.

**TRAP: no part is a control that macOS 26 hosts in SwiftUI**, with its Metal startup (ui/Controls/AGENTS.md). The tabs are drawn, the on switch is `VibeSwitch`, and the list's pop-ups and fields are borderless, which stay unhosted. The +/- buttons are small square buttons, which stay unhosted too. A test walks the view tree for a hosting view.

**No work while hidden.** The curve is sampled only when it draws, once for each change. The list fills only when it shows: a change while the editor or the parametric face is hidden waits until it shows.

## VoiceOver

Each graphic slider and each node is a VoiceOver slider of its own. A slider reads its frequency as its name and its gain as its value: "1,000 Hz", "+3.0 dB". A node reads "Band 3" and its band: "1,000 Hz, +3.0 dB, Q 1.4", or "30 Hz, Q 0.71" for a pass filter. A step moves a gain 0.5 dB, or a pass filter's frequency a twelfth of an octave. Each field, pop-up, and switch is named by its band and its column. The tabs read as a tab group of radio buttons.

## Tests

`Tests/ui/EQEditor/Mac/` holds `VibeEQEditorMathTests`, the math both ways and the number formats, and `VibeEQEditorViewTests`, the editor in a window kept off every display. They cover which face shows and when, the delegate's calls through drags, keys, fields, and add and remove, the axis held through a drag, the hit test, the disabled and hidden editor, the VoiceOver values, the drawing in both appearances, and the hosted-control check.

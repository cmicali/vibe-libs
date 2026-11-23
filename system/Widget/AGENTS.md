# system/Widget

The app's side of a Home Screen widget: the publisher that writes `system/WidgetState`'s snapshot, its images, and the reload requests. **The publisher is iOS only**, in the `iOS/` half. The rule of when to publish is Foundation only, so both platforms build it and its tests run on macOS. A widget extension never lists this piece. It takes `system/WidgetState` alone.

| File | Owns |
| --- | --- |
| `iOS/WidgetPublisher` | the only writer of the app group: the snapshot, the artwork, the waveform bake, the sweep of old images, the reload throttle, and whether a widget is placed |
| `VibeWidgetPublishRules.h` | `VibeWidgetNeedsPublish`, whether a tick publishes, and its seek tolerance |

It depends on `system/WidgetState`, `system/NowPlaying` for the change tests the lock screen shares, `waveform/WaveformStyles` and `waveform/Waveform` for the bake, `audio/AudioTypes` for the track and its cue window, `core/Graphics` for the art's color, and `core/Common` for the path key.

## How an app uses it

List `VibeLibsWidget` in the iOS app's target. The app keeps everything tied to its extension, its app group, its settings, and its strings. It hands the piece these:

- **Its app group and read signal**, set on `VibeWidgetState` before it makes the publisher (`system/WidgetState/AGENTS.md`).
- **WidgetKit's two calls, as blocks**, at `initWithThemeProvider:reloadTimelines:queryPlaced:`. WidgetKit has no Objective-C API, so the app wraps `WidgetCenter.shared.reloadAllTimelines()` and `getCurrentConfigurations` in a few lines of Swift of its own. `reloadTimelines` runs on the publisher's queue. `queryPlaced` answers on any queue, with WidgetKit's error when it fails.
- **Its tracks**, each a `VibeWidgetTrack`: a `VibePlayableItem` with its display title and artist and its decoded art. The publisher keeps the object it is given and tells tracks apart by identity. It spells `trackKey` from the item's path and window itself, so the file names stay the piece's. The app feeds it on each tick with `updateWithTrack:position:duration:playing:startPending:`, and calls `refreshPlaced` on every return to the foreground.
- **The strip's look.** The theme provider comes once, at init. The style, Centered, and the playhead line come through `updateWaveformStyle:centered:drawsPlayheadLine:`, once before the first publish and again on every change to a setting the app reads. The app offers each track's envelope with `offerWaveform:forTrack:`.

The buttons are each app's own. Their App Intents must name their titles as literals, which the metadata processor reads, and those titles are the app's strings. An intent that plays or seeks is an `AudioPlaybackIntent`, so the system performs it in the app's process. A seek drops a tap whose `trackKey` is not the displayed track's, which `trackKeyForTrack:` spells.

## Writing

- **Writes are gated on `widgetPlaced`. The bookkeeping is not.** The publisher keeps its snapshot current either way, so a widget that appears mid-track gets the current snapshot at once (`republish`).
- **Two sources decide `widgetPlaced`, each right about one direction.** WidgetKit's configurations, asked at launch and on every return to the foreground, turn it off. The extension's read signal turns it on the instant a widget renders. The query fails open.
- **TRAP: artwork lands before the plist.** The waveform bake can follow later. The widget reads the plist first. The sweep of old images runs last and spares the outgoing track's, which a plist just read may still name.
- **TRAP: `cachedArt` is nil until the art decodes**, so a track change usually writes nil and deletes the file. `_artworkOnDisk` re-fires the write on the first tick with decoded art.
- One serial queue orders file writes and reload requests. Requests are throttled to four a second. The first of a quiet period is queued at once. A burst schedules one trailing request. WidgetKit decides when to refresh.
- **While a placed widget shows a playing track, the publisher requests a timeline reload every minute** (`updatePlayingReloads`). It writes no new state. The extension's timeline should keep coarse entries through the track's end, in case a reload is delayed.
- Artwork is bounded to 576 px and never cropped. The widget crops where it draws.

## When to publish

`VibeWidgetNeedsPublish` takes the last snapshot and the tick's values. A publish happens on a track change, a play or pause, a duration, title, or artist change, or a seek. The seek test is the lock screen's (`VibeNowPlayingPositionIsDirty`) with a 2 s tolerance. While an open runs the playhead is pinned at 0, so the position alone publishes nothing.

## The waveform bake

The publisher bakes the current track's envelope twice, once in each half of the palette, at the medium widget's aspect. The widget reveals the played image up to the playhead, so nothing re-renders per entry. The theme is always asked for dark, because the widget's background is.

**Under a playhead line both images are the whole strip as played, and the widget draws the line.** `VibeWidgetState.playheadLine` says so. The bake sets it, and commits the plist again when it changed, after the images.

A waveform is baked only for the published track, so a page swiped past cannot overwrite the strip. A bake runs only when its signature changes: the resolved style, alignment, playhead line, palette, and waveform object. **TRAP: an app's color wells can push a new look on every step of a drag.** The signature compare and the cancel of a queued bake keep a drag from queuing dozens.

**Each trap is written twice, and the `TRAP:` beside the code is the authority.** Changing a trap means changing both copies.

## Tests

`VibeWidgetPublishRulesTests` covers when to publish, on macOS. The publisher needs UIKit, so `Widget-iOS` only builds it. Vibe's `WidgetPublisherTests`, in its simulator suite, covers `trackKeyForTrack:`. The rest of the publisher has no test. Run Vibe's `make test-ios`, and place a widget, before a change to the publisher merges.

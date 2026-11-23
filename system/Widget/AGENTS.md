# system/Widget

The app's side of a Home Screen widget: the publisher that writes `system/WidgetState`'s snapshot, its images, and the reload requests. **The publisher is iOS only**, in the `iOS/` half. The rules beside it are Foundation only, so both platforms build them and their tests run on macOS. A widget extension never lists this piece. It takes `system/WidgetState` alone.

| File | Owns |
| --- | --- |
| `iOS/WidgetPublisher` | the only writer of the app group: the snapshot, the artwork, the waveform bake, the sweep of old images, the reload throttle, and whether a widget is placed |
| `VibeWidgetPublishRules.h` | `VibeWidgetNeedsPublish`, whether a tick publishes, with its seek tolerance, and `VibeWidgetTrackKey`, the key that names a track's files |

It depends on `system/WidgetState`, `system/NowPlaying` for the change tests the lock screen shares, `waveform/WaveformStyles` and `waveform/Waveform` for the bake, `audio/AudioTypes` for the track and its cue window, `core/Graphics` for the art's color, and `core/Common` for the path key and the log.

## How an app uses it

List `VibeLibsWidget` in the iOS app's target. The app keeps everything tied to its extension, its app group, its settings, and its strings. It hands the piece these:

- **Its app group and read signal**, set on `VibeWidgetState` before it makes the publisher (`system/WidgetState/AGENTS.md`). The publisher's init asserts that they are set, and logs when the container does not resolve, as in a build without the group's entitlement.
- **WidgetKit's two calls, as blocks**, at `initWithThemeProvider:reloadTimelines:queryPlaced:`. WidgetKit has no Objective-C API, so the app wraps `WidgetCenter.shared.reloadAllTimelines()` and `getCurrentConfigurations` in a few lines of Swift of its own. `reloadTimelines` runs on the publisher's queue. `queryPlaced` answers on any queue, with WidgetKit's error when it fails.
- **Its tracks**, each a `VibeWidgetTrack`: a `VibePlayableItem` with its display title and artist and its decoded art. The publisher keeps the object it is given and tells tracks apart by identity. **It reads `displayTitle`, `displayArtist`, and `cachedArt` on every tick**, so each must be cheap and return the same answer until the track's tags or art change. The app feeds it on each tick with `updateWithTrack:position:duration:playing:startPending:`, and calls `refreshPlaced` on every return to the foreground.
- **The strip's look.** The theme provider comes once, at init. The style, Centered, and the playhead line come through `updateWaveformStyle:centered:drawsPlayheadLine:`, once before the first publish and again on every change to a setting the app reads.
- **The envelope.** `offerWaveform:forTrack:` takes **only a complete envelope, and only for the current track or the one about to become current.** Each new waveform object costs a bake. An offer for another track, such as a neighboring page's, replaces the current track's, so a later change of look cannot re-bake it.

## What each app writes

The piece ends at the app group. Each app writes the rest, and Vibe's are the reference: `VibeWidget/AGENTS.md`, `Vibe/iOS/Widget/VibeWidgetIntents.swift`, and `Vibe/iOS/Widget/VibeWidgetReloader.swift` in [Vibe](https://github.com/cmicali/vibe).

- **Its buttons' App Intents.** Their titles must be literals, which the metadata processor reads, and those literals are the app's strings. An intent that plays or seeks is an `AudioPlaybackIntent`, so the system performs it in the app's process. A seek drops a tap whose key is not the displayed track's `VibeWidgetTrackKey`.
- **An intent's body does nothing in the extension.** The bodies act through an object the app installs, so the app installs it at launch, before any intent can run.
- **A tap can be the app's launch.** An intent that finds no connected scene continues in the foreground, then waits for the launch's restore to settle before it acts. Skipping the wait seems to work for local files and loses the tap for a cloud folder.
- **A button that opens a screen is a plain `AppIntent` whose `supportedModes` is `.foreground`**, so the system opens the app and performs it there.
- **The extension's timeline.** It decodes the artwork and both strips once per timeline and shares them across entries, since the extension has a hard memory cap. It blurs at a small size. It keeps 5 s entries, then coarse ones to the track's end, so a delayed reload never freezes the playhead.
- **The strip.** With `playheadLine` set, the extension draws the line over a strip that is wholly played. Otherwise it reveals the played image up to the playhead, over the unplayed one.

## Writing

- **Writes are gated on `widgetPlaced`. The bookkeeping is not.** The publisher keeps its snapshot current either way, so a widget that appears mid-track gets the current snapshot at once (`republish`).
- **Two sources decide `widgetPlaced`, each right about one direction.** WidgetKit's configurations, asked at launch and on every return to the foreground, turn it off. The extension's read signal turns it on the instant a widget renders. The query fails open.
- **TRAP: artwork lands before the plist**, and the sweep of old images runs last.
- **TRAP: `cachedArt` is nil until the art decodes**, so `_artworkOnDisk` re-fires the write on the first tick with decoded art.
- **A committed snapshot is never changed.** A commit queued on the publisher's queue saves the object it was given, so a later change commits a copy.
- One serial queue orders file writes and reload requests. Requests are throttled to four a second. WidgetKit decides when to refresh. A failed save is logged once.
- **While a placed widget shows a playing track, the publisher requests a timeline reload every minute** (`updatePlayingReloads`). It writes no new state.
- Artwork is bounded to 576 px, measured in pixels, and never cropped. Art already within the bound is encoded as it is. The widget crops where it draws.

## When to publish

`VibeWidgetNeedsPublish` takes the last snapshot and the tick's values. A publish happens on a track change, a play or pause, a duration, title, or artist change, or a seek. The seek test is the lock screen's (`VibeNowPlayingPositionIsDirty`) with a 2 s tolerance. While an open runs the playhead is pinned at 0, so the position alone publishes nothing, but every other change still does.

## The waveform bake

The publisher bakes the current track's envelope twice, once in each half of the palette, at the medium widget's aspect. The widget reveals the played image up to the playhead, so nothing re-renders per entry. The theme is always asked for dark, because the widget's background is. Under a playhead line both images are the whole strip as played. `VibeWidgetState.playheadLine` says so, and the plist is committed again after the images when it changed.

A bake runs only for the published track, and only when its signature changes: the resolved style, alignment, playhead line, palette, and waveform object. **TRAP: an app's color wells can push a new look on every step of a drag.** A queued bake that a newer one superseded skips, by its generation. The queued bake holds the publisher weakly.

**Each trap is written twice, and the `TRAP:` beside the code is the authority.** Changing a trap means changing both copies.

## Tests

`VibeWidgetPublishRulesTests` covers when to publish and the track key, on macOS. The publisher needs UIKit, so `Widget-iOS` only builds it. The rest of the publisher has no test here. Run Vibe's `make test-ios`, and place a widget, before a change to the publisher merges.

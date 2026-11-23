# system/WidgetState

The snapshot a Home Screen widget draws. The app writes it into an app group's container, and the widget extension reads it. **It is Foundation only, and it depends on nothing**, not even `core/Common`. So an extension that takes it compiles nothing else from here. It builds on both platforms. The app's side, the publisher, is `system/Widget`.

| File | Owns |
| --- | --- |
| `VibeWidgetState` | the snapshot's fields, its plist and image files in the container, the read signal, and the playhead it extrapolates |

## How an app uses it

List `VibeLibsWidgetState` in the app's target and in its widget extension's. The app takes it through `VibeLibsWidget` too, which lists it.

**Each process names the app group and the read signal once**, with `useAppGroup:readNotification:`, before its first read or write. The app does it at launch. The extension does it when its widget bundle is made. Until then `containerURL` is nil, and the widget draws its empty state. The names are the app's, so they stay in the app. Both targets' entitlements must carry the group. Vibe keeps its names in a header both targets compile, as C string macros, since Swift imports those as `String`.

The extension reads with `VibeWidgetState.load()`, then draws the playhead with `position(at:)` and `progress(at:)`. The images sit at `artworkURL`, `waveformPlayedURL`, and `waveformUnplayedURL`.

## The snapshot

`VibeWidgetState` is what was true at `positionDate`. The widget advances the playhead itself, so ordinary playback publishes nothing. When to publish is `system/Widget`'s rule.

The state is a plist in the container, with up to three images beside it: the artwork JPEG and the played and unplayed waveform PNGs. **The images are named by `trackKey`**, so a publish that lands between the extension's reads can leave an image missing, but never pair one track's title with another's cover. The key also rides in every seek button the widget draws, so a tap on a stale render cannot seek a different track.

**`loadState` posts the read signal before it reads, even when it returns nil.** An empty container is still a widget asking, and the publisher turns its writes on at that signal.

`kStateVersion` is bumped when a field's meaning changes. An unknown version draws the empty state until the next publish. **The Swift names on `loadState`, `positionAtDate:`, and `progressAtDate:` are pinned**, because a rename breaks the extension, a build the app never runs.

## Tests

`VibeWidgetStateTests` covers the playhead's arithmetic. It reaches no app group, so it writes nothing on disk.

# ui/Rows

The rows an iOS music app lists files and tracks in, and the mini player strip. **It is iOS only.** It depends on `ui/Controls`, for the equalizer bars and the loading indicator in a track row's gutter. None of it reads an app's settings, strings, or model. The app fills a value or pushes a label in. The strip lives here because it draws a `VibeTrackRow` and the file tile, so a piece of its own would save no dependency.

| File | Owns |
| --- | --- |
| `VibeTrackRow` | the value a track row draws: title, subtitle, thumbnail, duration text, number text, and the playing marker. The strip draws its title, subtitle, and thumbnail |
| `VibeTrackCell` | a track's table row: the gutter, the art, the title over the subtitle, and the duration |
| `VibeMiniPlayerView` | the strip in the tab bar's bottom accessory: the art, the title over the subtitle, play or pause, and next |
| `FileRow` | what every file and track row shares: the file tile, the icon slot, the name style, the opening spinner, the not-downloaded mark, a menu action, and the viewport test |

## How an app uses it

List `VibeLibsRows` in an iOS target.

**The app turns its model into a `VibeTrackRow`**, and formats the number and the duration itself. The cell keeps a copy of the row it drew and skips a render whose row is unchanged.

**The cell's gutter has three states, in this order: loading, playing, number.** Loading is pushed on its own, through `loading` and `loadingProgress`, since a transfer changes without the row. The app also pushes the equalizer's level source, whether audio is output, and whether the row is materially visible. A loading row should be told that audio is not output and that it is not visible, so its hidden marker holds no poller (`ui/Controls/AGENTS.md`).

**The strip takes its four VoiceOver labels in one call.** The play button names what a tap will do: play while paused, and pause while playing.

**An icon slot is told whether the file is a playlist.** The piece does not know a playlist's extensions.

## TRAPs

- **TRAP: UIKit displays a prepared cell without asking the data source again.** An app that renders only in `cellForRowAtIndexPath:` shows a stale row when art or tags arrive in that window. Render in `willDisplayCell:` too. The unchanged check keeps the second render cheap.
- **TRAP: rendering in place does not re-measure an automatic-dimension row.** `renderRow:` returns YES when the row's height can have moved. The app then owes the table an empty `performBatchUpdates:`.
- **TRAP: the strip is 48 pt, not negotiable.** `UITabAccessory` frames its content at a fixed height and ignores `intrinsicContentSize` and height constraints, with no logged conflict.
- **TRAP: the strip's row needs a designated give, and the simulator never shows it.** On a device the accessory reports width zero on at least one pass. The art's leading inset is the give, at `UILayoutPriorityRequired - 1`. Any new required constraint across the row reopens this.
- **TRAP: in a regular width, the accessory fits the strip's width once, not per song.** UIKit measures the strip when it is installed and when the size class changes, never when the song changes. So the strip has a preferred width of at least 360 pt, at `UILayoutPriorityDefaultHigh`. It is off in a compact width, where the system frames the strip, and inline, where there is no room. It is on while the size class is unspecified, because UIKit fits the strip on install before the strip has the window's traits. Every song then gets at least that room, and a name longer than it can still be cut. It stays below required, so the give above still holds.

The strip's three traps are written beside its code too, and those comments are the authority for them.

## Tests

These views need a hosted app and a window, so their tests run in the consuming app's simulator suite, as the iOS scrubber's do. Vibe's are its `RowViewsTests`. Here, `Rows-iOS` only builds the piece. So a change to a view passes this repo's checks without proving its behavior. Run Vibe's `make test-ios` against the change before it merges.

# ui/Rows

The rows an iOS music app lists files and tracks in. **It is iOS only.** It depends on `ui/Controls`, for the equalizer bars and the loading indicator in a track row's gutter. It came from Vibe. None of it reads an app's settings, strings, or model. The app fills a value or pushes a label in.

| File | Owns |
| --- | --- |
| `VibeTrackRow` | the value a track row and the mini player draw: title, subtitle, thumbnail, duration text, number text, and the playing marker |
| `PlaylistTrackCell` | a track's table row: the gutter, the art, the title over the subtitle, and the duration |
| `MiniPlayerView` | the strip in the tab bar's bottom accessory: the art, the title over the subtitle, play or pause, and next |
| `FileRow` | what every file and track row shares: the file tile, the icon slot, the name style, the opening spinner, the not-downloaded mark, a menu action, and the viewport test |

## How an app uses it

List `VibeLibsRows` in an iOS target, with `excludedPlatform: Mac`. It lists Controls' template. No macOS target may list it.

**The app turns its model into a `VibeTrackRow`.** A row draws the title, and the subtitle below it when it has one. A row with no subtitle draws one line, centred, in the title's color. Nil art draws the file tile. The app formats the number and the duration, so a row shows whatever text it is given. The cell keeps a copy of the row it drew and skips a render whose row is unchanged. So the app can render on every appearance at little cost.

**The cell's gutter has three states, in this order: loading, playing, number.** Loading is pushed on its own, through `loading` and `loadingProgress`, since a transfer changes without the row. The app pushes the equalizer's level source, whether audio is output, and whether the row is materially visible. A loading row should be given neither, so a hidden marker holds no poller (`ui/Controls/AGENTS.md`).

**The strip takes its four VoiceOver labels in one call.** The play button names what a tap will do: play while paused, and pause while playing.

**An icon slot is told whether the file is a playlist.** The piece does not know a playlist's extensions. The app decides, so the tile follows the app's rule.

## TRAPs

- **TRAP: UIKit displays a prepared cell without asking the data source again.** An app that renders only in `cellForRowAtIndexPath:` shows a stale row when art or tags arrive in that window. Render in `willDisplayCell:` too. The unchanged check keeps the second render cheap.
- **TRAP: rendering in place does not re-measure an automatic-dimension row.** `renderRow:` returns YES when the row's height can have moved. The app then owes the table an empty `performBatchUpdates:`.
- **TRAP: the strip is 48 pt, not negotiable.** `UITabAccessory` frames its content at a fixed height and ignores `intrinsicContentSize` and height constraints, with no logged conflict.
- **TRAP: the strip's row needs a designated give, and the simulator never shows it.** On a device the accessory reports width zero on at least one pass. The art's leading inset is the give, at `UILayoutPriorityRequired - 1`. Any new required constraint across the row reopens this.

The `TRAP:` comments beside the code are the authority.

## Tests

These views need a hosted app and a window, so their tests run in the consuming app's simulator suite, as the iOS scrubber's do. Vibe's are its `RowViewsTests`. Here, `Rows-iOS` builds every file and a probe that imports every header.

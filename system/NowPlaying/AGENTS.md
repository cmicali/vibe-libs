# system/NowPlaying

The bridge to the system's Now Playing info and remote commands, over MediaPlayer's `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. It publishes what is playing and takes transport commands back. It owns no playback state. It depends on `core/Graphics` for the image alias and the mac's artwork resize, on `media/PlayQueue` for the repeat mode, and on `core/Common` for the log and main-thread macros. **Today it holds what Vibe moved here.** None of it reads an app's settings, strings, or types. It builds on both platforms.

| File | Owns |
| --- | --- |
| `NowPlayingController.{h,m}` | the update's record, the publish path, its dirty check, the artwork's rasterization, and the remote command handlers |
| `NowPlayingRules.h` | the header-only rules: the state from a player's flags, the string comparison, and the position's dirty check |
| `NowPlayingController+Debug.h` | the seam: the source image of the published artwork |

## The driver

**The app drives it, and takes the commands back through the delegate.** The app hands it each track's values and timing on every transport event. The delegate routes each command to the same transport entry points the app's own buttons use. Each command is delivered on main.

**It takes values, never the app's row.** `updateWithRecord:` takes one `VibeNowPlayingRecord`: the track's source key, its title, its artist, one image, the timing, the state, and whether next and previous are available. The source key is the dirty check's identity, so a cue row of the same file is a change. A nil source key means no track. A nil title publishes as empty, and a nil artist publishes none.

**The record is the one type the piece adds.** It is a C struct of the ten values one update needs. The app fills a fresh one on every transport event and passes it by value. So each call site names its values, a value left out reads as nil, zero, or NO, and the controller holds its own copy. A later change on the app's side never reaches what was published. The plan once named a snapshot type for this piece and said it was not needed, since the update took its values loose. Ten loose parameters proved too many, so the record is that snapshot. It holds plain values, and the piece still has no edge to `audio/AudioTypes`.

**Nothing is published until the first track plays.** The update withholds every publish before its first Playing one: no track, a parked start and a paused start alike. A launch into a restored session therefore cannot claim the system slot. Next and previous availability is applied before that return regardless. After the first play, a nil source key clears the slot once.

**The image is the app's choice, and the dirty check compares its identity.** An app reads each image it passes without blocking: the track's art, say, else its thumbnail, else a placeholder. Pass the same object while it is unchanged. A new object on every tick republishes on every tick. A placeholder must already match the app's appearance, since the drawing appearance here is the system's.

**Shuffle and repeat are commands, not Now Playing info.** `changeShuffleModeCommand` and `changeRepeatModeCommand` take the system's controls (Siri, the Watch, accessories) to the delegate's `setShuffleEnabled:` and `setRepeatMode:`. The app writes its setting and applies it exactly as its own control does. The state the system shows is `currentShuffleType` and `currentRepeatType` on the commands. `updateShuffleEnabled:repeatMode:available:` writes them, so the app calls it wherever it applies the modes. A shuffle request of Items or Collections is on, since there is no album-level shuffle. `available` sets both commands' `enabled`. An app that hides its own shuffle and repeat controls passes NO, so CarPlay hides its buttons too. `VibeRepeatMode` has `MPRepeatType`'s raw values, and static asserts hold the cast.

**TRAP: the command center is process-global, and the system picks which enabled commands fill the compact transport.** The lock screen, Control Center, CarPlay, AirPods and the mac's media keys share it. The shuffle and repeat pair leaves next and previous in place. The iPhone lock screen and both platforms' Control Center draw no shuffle or repeat at all. The mac's media keys and AirPods taps still skip, and Siri reaches the pair. The skip-interval pair would take their place, so it stays disabled with the other unsupported commands. Check any further command on a device first.

`MPNowPlayingInfoCenter.playbackState` is written on macOS only, under `TARGET_OS_OSX`. iOS derives the state from the audio session and the published rate.

**TRAP: the published artwork must be rasterized privately on the main thread, and that result must be the only thing the `MPMediaItemArtwork` request handler returns.** The handler runs on MediaPlayer's threads. The source is the live `NSImage` the app's UI is drawing, and `NSImage` is not safe to draw from two threads at once. `VibeArtworkForPublishing` always redraws, even a small thumbnail. It caps art at 512px and hands over a private copy. iOS passes the image through.

**The republish rules are `NowPlayingRules.h`**, header-only and tested. The system extrapolates the elapsed time from the last publish at the published rate, so only a jump it cannot explain republishes. A buffering hold publishes Playing at rate 0, so the system's clock holds with the audio. An app's widget can share the string comparison.

**TRAP: making a controller claims the system's media slot.** `initWithDelegate:` registers the commands, and the first Playing update publishes. Either can pull AirPods from another device, even while the app renders to a virtual output. So an app's test launch makes no controller. The controller reads no launch flag. Verifying it needs a launch that makes one.

## The seam

`NowPlayingController+Debug.h` declares `debugPublishedArtwork`, the source image of the published artwork by identity, or nil. Its body reads state private to the controller, so it sits in `NowPlayingController.m` under one `#if DEBUG`. The header carries none.

## Tests

`Tests/system/NowPlaying/` holds `NowPlayingRulesTests`. They cover the position rule, and the publication path through `initWithClock:publish:commandAvailability:`, which registers no command. An injected clock and sinks stand in for the system's centers. The tests cover the first-play gate, the clear, the dirty check, a buffering hold, and command availability. Each track is a path, which is its source key, with its file name as its title. The minimal consumer registers the commands through `initWithDelegate:`, pushes a title and a duration, and reads `MPNowPlayingInfoCenter`'s dictionary back.

The artwork tests use plain images. The same image object publishes once, and a new object publishes again. The published art is a private copy, capped at 512 px in its own proportions. Vibe keeps its test of the values its row pushes (`AudioTrackTests`). The commands' delivery on a device is a live-app check.

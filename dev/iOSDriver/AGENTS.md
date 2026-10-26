# dev/iOSDriver

Taps, drags, and pinches in the iOS simulator, for scripts. No public API synthesizes a `UITouch` in-process. Touch synthesis exists only inside XCUITest. So the driver is one resident XCUITest, `VibeiOSDriverTests`, whose one "test" serves commands until it is told to quit. It is not a test suite. It came from Vibe. **It is iOS only**, and it depends on nothing.

| File | Owns |
| --- | --- |
| `VibeiOSDriverTests.m` | the command loop, the gestures, and the self-heal |

## How an app runs it

**An app compiles the template into an iOS UI-testing bundle of its own.** That bundle links XCTest. The app's script starts it with `xcodebuild test` and leaves it running. It passes four values as `TEST_RUNNER_<name>`, which `xcodebuild` hands the runner as `<name>`:

| Value | Means |
| --- | --- |
| `VIBE_DRIVER_DIR` | a host directory for the command files. Required. |
| `VIBE_DRIVER_APP` | the bundle identifier of the app to drive. Required. |
| `VIBE_DRIVER_RELAUNCH_ARGS` | the arguments a self-heal relaunch passes, separated by spaces. Optional. |
| `VIBE_DRIVER_PINCH_ELEMENT` | the accessibility identifier that `pinch` acts on. Optional, and `pinch` refuses without it. |

**The bundle needs no host app.** The driver drives an app by its bundle identifier, so any installed app can be driven. `iOSDriver` here builds with no host. Run by hand against Settings, it served an attach, a tap, and a quit. An app's bundle may still depend on its app target, so `xcodebuild test` builds the app first. **TRAP: `xcodebuild test` builds a host app without installing it.** The app's script installs the build after the driver is ready, or the driver drives whatever the device already held.

Use a host directory, never the app's container. Every `simctl install` moves the data container, and a driver holding the old path stops seeing commands. The runner is not sandboxed, so it reads host paths directly.

## The protocol

The client writes `vibe-touch-<id>.json`, in the debug channel's `{id, args}` shape, into the directory. It renames a complete file into place, since a file read mid-write is deleted unexecuted. The driver replies with one JSON object in `vibe-touch-response-<id>.txt`. A bad command replies `{"error": …}` and the loop keeps serving. An exception from XCTest, such as an off-screen coordinate or a dead app proxy, becomes an error reply too. The driver writes `vibe-driver-ready` once it serves, and removes it when it ends. At start it deletes every `vibe-touch-` file a dead client left. The loop's absolute lifetime is four hours. The `quit` verb is the normal exit.

**Coordinates are app-window points, top-left origin**: screenshot pixels divided by the screen scale. The unknown-command reply lists every verb. A reply means the gesture was performed, not that it landed. The caller verifies the result in the app.

## TRAPs

**TRAP: XCTest snapshots only a process it launched or activated.** Against an app the app's own launcher started, every query retries for 60 seconds and then relaunches the app itself, without the launcher's arguments. So the driver activates the app, which attaches without a relaunch, on the first gesture and on `attach`. An app's launcher sends `attach` after every relaunch. A dead app is relaunched with `VIBE_DRIVER_RELAUNCH_ARGS`, so a self-heal launches the app as its launcher does.

**TRAP: the keyboard lives in its own window**, so a coordinate tap on a key lands on the app behind it. `type` goes through `typeText:`, which uses the responder chain.

**XCUITest synthesizes multi-touch only through an element.** So `pinch` acts on the element named by `VIBE_DRIVER_PINCH_ELEMENT`. A scale above 1 opens the fingers. The velocity is scale factors per second, and it must be negative to close them.

**The quiescence waits are switched off.** XCTest waits for the app to go idle around every event. Continuous playback or a display link never lets it. So the driver replaces six of XCTest's private methods, inside the test runner only. Two answer yes, and four do nothing. An Xcode that renames them leaves gestures slow but working. Nothing here ships in an app.

`springboard <gesture>` runs one gesture against the Home screen, for widgets and their gallery. `rotate` names the device's physical rotation, as the Simulator's menu does.

## Tests

None run here. The loop waits for commands until told to quit, so `make build-ios` builds `iOSDriver` and nothing runs it. Vibe runs the loop through its vibe-debug skill's `drive-ios.sh`, which is the live check.

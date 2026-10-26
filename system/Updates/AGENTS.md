# system/Updates

Sparkle for a mac app that is downloaded directly and updates itself. It depends on `third_party/Sparkle`, the prebuilt framework. **It is macOS only**, and its files sit in its `Mac/` half. It came from Vibe. None of it reads an app's settings, strings, or launch arguments. The app passes them in.

| File | Owns |
| --- | --- |
| `VibeUpdater.{h,m}` | Sparkle's standard controller, unstarted until the app starts it, and the updater's delegate |
| `UpdaterRules.h` | the header-only rules: the allowed channels, the interval Sparkle's store means, the check periods, and the feed parameters |

## The one class

**`VibeUpdater` is the only type here, and it is small.** Sparkle asks its updater's delegate at every check, and the updater only weakly holds that delegate. So something must outlive the controller and answer for the app. In Vibe that was a category on the app's delegate, which cannot leave the app. Free functions would leave every app to write the delegate again. So the class owns the controller, answers each delegate question from the values the app gave it, and keeps a check's periods until its feed loads. It carries the `Vibe` prefix, since a bare `Updater` would read as Sparkle's own.

## What the app passes in

- **The feed override**, at init. A nil one keeps the Info.plist's `SUFeedURL`.
- **The beta switch**, as a block. Sparkle asks at every check, so a change needs no push. The block decides both the allowed channels and the feed's `channel` parameter. An item with no channel is stable, and it always qualifies.
- **When it starts.** `start` starts the updater. Before that, it stores its settings, and a check it is asked for logs and does nothing.
- **The check interval**, through `checkInterval`, in seconds. 0 turns Sparkle's automatic checks off, and keeps the stored interval. Any other value turns them on at that interval. The getter answers 0 while they are off. The default interval is the app's to choose.
- **Check for Updates…** targets `controller` with `checkForUpdates:`. The controller validates the menu item. It is disabled while the updater is unstarted.

## The feed parameters

**Each check appends the macOS version, the architecture, the channel, and the app's language to the feed URL.** Sparkle's User-Agent already names the app and its version. Nothing here identifies the Mac. An app that publishes a privacy policy lists every key.

**A period's flag goes with a copy's first check in it.** The check adds `d=1`, `w=1`, or `m=1` on its first check in a UTC day, ISO week, or month. It compares each period with the ones its last loaded feed saved, so a site can count active copies with no identifier. `updater:didFinishLoadingAppcast:` saves all three. So a check that fails offline flags them again on the next one.

**TRAP: the saved periods live in standard user defaults under `VibeReportedUpdateCheckPeriods`.** Shipped builds of Vibe wrote that key. A rename would flag every period again on each copy's next check.

## What an app adds

- **Its macOS target lists `VibeLibsUpdates`** with `excludedPlatform: iOS`. No iOS target may list it. The template lists `VibeLibsSparkle`, which links, embeds, and signs the framework (`third_party/Sparkle/AGENTS.md`).
- **Its Info.plist names the feed and the key**: `SUFeedURL` and `SUPublicEDKey`. Sparkle refuses an update its key did not sign.
- **A sandboxed app runs Sparkle's installer as its XPC service.** It sets `SUEnableInstallerLauncherService`. Its entitlements add the mach-lookup exceptions `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`, and outgoing network connections.
- **A configuration with no updater excludes both files by name.** It sets `EXCLUDED_SOURCE_FILE_NAMES` to `Sparkle.framework` and `VibeUpdater.m`. The first unlinks and unembeds the framework. The second leaves out the class that links it. **It must exclude every source here that links Sparkle**, and `VibeUpdater.m` is the only one. `make check-pieces` fails when another source of this piece reaches Sparkle, by its own import or through `VibeUpdater.h`. It also fails when `VibeUpdater.m` is renamed. Either would break every app's exclude list. So every Sparkle import stays in `VibeUpdater.m`. A source here that reaches no Sparkle needs no exclude. The app compiles out its own references with a switch of its own, and strips the `SU` keys from its built Info.plist. A Mac App Store build does all three, since App Review rejects an app that updates itself.

## Tests

`Tests/system/Updates/` holds `UpdaterRulesTests`. They cover the channels, the interval's reading, the periods across a UTC day and an ISO year, and which flags a check adds. They also make an updater unstarted and ask it as Sparkle would: the feed override, the channels as the block changes, and the parameters. Nothing starts it, so no feed is read and no setting is written. A real update needs two signed builds and a feed, so it is a check in the app (Vibe's `Mac/App/AGENTS.md`, Updates).

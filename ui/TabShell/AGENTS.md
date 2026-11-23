# ui/TabShell

An iOS music app's tab shell: the tabs, the mini player in the tab bar's `bottomAccessory`, and the now-playing card above them, with the card's expand and minimize. **It is iOS only.** It depends on `ui/Rows`, for the mini player.

| File | Owns |
| --- | --- |
| `RootViewController` | the scene's root: the tabs, the strip, the card and its transition, the backdrop snapshot, and the appearance forwarding |

## How an app uses it

List `VibeLibsTabShell` in an iOS target.

**The app makes the root with `initWithTabs:card:`** and sets it as the window's root view controller. It reads nothing of the app's. The app hands it these:

- **The tabs, as `UITab` values with lazy providers.** A tab's view controller is built on its first visit. Ask the app's own reference, never `UITab.viewController`, whether a tab exists, since the getter resolves the provider. A `UISearchTab` among them keeps UIKit's behavior. Its circle sits outside the capsule, and `automaticallyActivatesSearch` collapses the bar behind a field and restores the previous tab on cancel. Its identifier is UIKit's, so the app matches it by kind.
- **The card's view controller.** It adopts `RootViewControllerCard`: `presented` and `sceneActive`. The root keeps both current. The app forwards the card's downward drag to `cardDidPanWithTranslation:velocity:state:` and its grabber to `minimizeCardAnimated:`.
- **The strip's row.** The root owns the `VibeMiniPlayerView` (`ui/Rows`) and installs it. The app sets its VoiceOver labels and pushes its row with `setMiniPlayerRow:playing:`. Nil takes the strip away. Push it from `rootViewControllerDidLoad:` on.
- **A delegate** (`RootViewControllerDelegate`), held weakly, so the app keeps it.
  - `rootViewControllerDidLoad:` comes once the view, the tabs and the card are built, after the card has loaded its view. An observer the app registers here hears each event after one the card registered in its own `viewDidLoad`.
  - `rootViewControllerCanExpandCard:` is asked on every expand. NO keeps the card down, as for an empty playlist.
  - The strip's play, pause and next arrive as `rootViewControllerDidTapPlayPause:` and `rootViewControllerDidTapNext:`. A tap on the strip itself expands the card.
  - `rootViewController:didSelectTab:previousTab:` comes on every tab change, so the app can pop a stack the user left.
  - `rootViewControllerDidChangeExposure:` says `tabsExposed` or `cardAtRest` may have changed. It comes often, and the app pushes what its screens need, such as whether a playing row's equalizer is seen.

The app sets `sceneActive` from its scene delegate. Foreground-inactive counts as off. The root passes it to the card and folds it into `tabsExposed`.

## The card

**It is a container, not a `UITabBarController` subclass**, so it can put the card and the backdrop snapshot above the tab bar controller's whole view. A card at rest hides the tabs, or the glass tab bar would keep sampling for nothing.

**The card is built once and never torn down.** Minimize translates it off the bottom. Its own state survives, so an expand re-reads and re-decodes nothing.

**TRAP: what scales under a moving card is a snapshot of the tabs, never the tabs view.** Scaling the view moves its edges off the screen's, and UIKit removes the safe-area insets and edge margins. The bars and rows then re-lay out, and the screen jumps under the card. A snapshot has no layout to lose (`beginBackdropSnapshot`, taken as the card starts moving and dropped once it rests). **The mini player strip stays installed under the card** (`setMiniPlayerRow:playing:`). Removing the accessory shrinks every tab's bottom inset, and a list scrolled to its end is clamped up under the snapshot.

**TRAP: the card moves by transform, never by frame.** A card whose pages draw waveforms redraws them on any bounds change.

**TRAP: `shouldAutomaticallyForwardAppearanceMethods` is per-parent.** Turning it off for the card turns it off for the tabs, so both are forwarded by hand. Each begin snapshots its exact children and the end consumes that snapshot, because `_expanded` can change between them.

A drag past a quarter of the height, or a flick, minimizes. A shorter drag or a cancelled one springs the card back. `presented` holds through the drag. The custom transition supplies what a presentation would. Reduce Motion settles at once, the card is the modal accessibility surface while up, and completion moves VoiceOver focus.

`getCenterOfTabWithIdentifier:center:` finds a tab's item in the bar by the label it draws, since a `UITab` has no view. An app can fly a view into a tab with it. A bar that is not on screen answers NO.

## Tests

The shell needs a hosted app and a window, so its tests are Vibe's: `RootViewControllerTests` in its simulator suite. Vibe's `check-layout-stability.sh` is the oracle for the snapshot and the strip. Run it on a list scrolled to its end, across an expand and a dismiss. `TabShell-iOS` only builds the piece, so run Vibe's `make test-ios` before a change merges.

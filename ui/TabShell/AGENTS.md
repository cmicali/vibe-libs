# ui/TabShell

An iOS music app's tab shell: the tabs, the mini player in the tab bar's `bottomAccessory`, and the now-playing card above them, with the card's expand and minimize. **It is iOS only.** It depends on `ui/Rows`, for the mini player.

| File | Owns |
| --- | --- |
| `RootViewController` | the scene's root: the tabs, the strip, the card and its transition, the backdrop snapshot, and the appearance forwarding |

## How an app uses it

List `VibeLibsTabShell` in an iOS target.

**The app makes the root with `initWithTabs:card:`** and sets it as the window's root view controller. The root reads nothing of the app's. `RootViewController.h` states the contract. The app hands in these:

- **The tabs, as `UITab` values with lazy providers.** A tab's view controller is built on its first visit. A `UISearchTab` among them keeps UIKit's behavior, and its identifier is UIKit's.
- **The card's view controller**, which adopts `RootViewControllerCard`. The app forwards the card's downward drag to `cardDidPanWithTranslation:velocity:state:` and its grabber to `minimizeCardAnimated:`.
- **The strip's row.** The root owns the `VibeMiniPlayerView` (`ui/Rows`) and installs it. The app sets its VoiceOver labels and pushes its row with `setMiniPlayerRow:playing:`. In a regular width, the accessory fits the strip's width only on install and on a size class change, never per song, so the strip asks for a preferred width (the TRAP on the accessory's fit, in `ui/Rows/AGENTS.md`).
- **A delegate** (`RootViewControllerDelegate`), held weakly, so the app keeps it. Two of its calls exist for an order the app may need. `rootViewControllerDidLoad:` comes after the card loads its view, so an observer registered there hears each event after the card's. `rootViewControllerDidChangeExposure:` lets the app tell each screen whether it is seen, such as a playing row's equalizer. It comes as a move begins, with `cardExpanded` already changed and `cardAtRest` NO, and again when the card lands.

## The card

**It is a container, not a `UITabBarController` subclass**, so the card and the backdrop snapshot sit above the tab bar controller's whole view. An expanded card that has settled hides the tabs, or the glass tab bar would keep sampling for nothing.

**TRAP: what scales under a moving card is a snapshot of the tabs, never the tabs view.** Scaling the view moves its edges off the screen's, and UIKit removes the safe-area insets and edge margins. The bars and rows then re-lay out, and the screen jumps under the card. A snapshot has no layout to lose (`beginBackdropSnapshot`, taken as the card starts moving and dropped once it rests). A drag, or an interrupted move, leaves it up, so the next move's `beginBackdropSnapshot` returns early. So every move tells the delegate itself, once it has begun (`animateCardAnimated:changes:completion:`), and the delegate never reads `cardAtRest` as YES mid-move. **The mini player strip stays installed under the card** (`setMiniPlayerRow:playing:`). Removing the accessory shrinks every tab's bottom inset, and a list scrolled to its end is clamped up under the snapshot.

**TRAP: the card moves by transform, never by frame.** A card that draws waveforms redraws them on any bounds change.

**TRAP: `shouldAutomaticallyForwardAppearanceMethods` is per-parent.** Turning it off for the card turns it off for the tabs, so both are forwarded by hand. Each begin snapshots its exact children and the end consumes that snapshot, because `_expanded` can change between them.

**Each trap is written twice, and the `TRAP:` beside the code is the authority.** Changing a trap means changing both copies.

A drag past a quarter of the height, or a flick, minimizes. A shorter drag or a cancelled one springs the card back. Reduce Motion settles the card at once. The card is the modal accessibility surface while it is up. When a move completes, VoiceOver focus moves to the card or to the strip.

## Tests

The shell needs a hosted app and a window, so its tests are Vibe's: `RootViewControllerTests` in its simulator suite. The oracle for the snapshot and the strip is Vibe's `check-layout-stability.sh`, in its `vibe-debug` skill. Run it on a list scrolled to its end, across an expand and a dismiss. `TabShell-iOS` only builds the piece, so run Vibe's `make test-ios` before a change merges.

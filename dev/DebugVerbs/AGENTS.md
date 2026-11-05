# dev/DebugVerbs

The standard debug verbs: the ones that know nothing of the app, so every app's channel answers them the same way. They read the view tree, the menus, the screenshot, the real capture, process health, and the build, and they answer the sheets, the modal windows, the panels, the popovers, and the open menus. They stall main on purpose, quit the app, and post synthetic input. It came from Vibe. It depends on `dev/DebugChannel`, for the table's shape and the wire, on `core/Graphics`, for the menu dump's image digest, and on `core/Common`. The mac half links ScreenCaptureKit, in a debug build only. It builds on both platforms, with `Mac/` and `iOS/` halves.

| File | Owns |
| --- | --- |
| `DebugStandardVerbs.{h,m}` | `VibeDebugStandardOptions`, `VibeDebugStandardVerbs`, and the shared verbs |
| `DebugProcessHealth.{h,m}` | the process counters, the malloc counter, and the layer count, on both platforms |
| `Mac/DebugStandardMacVerbs.m` | the mac verbs of the standard table |
| `Mac/DebugViewTree.{h,m}` | the window and view tree, the menu dump, the menu item search, and the shown texts and buttons under a view |
| `Mac/DebugScreenshot.{h,m}` | the in-process window render, the PNG writer, and the notifyutil hook |
| `Mac/DebugWindowCapture.{h,m}` | the real capture: the app's own windows as the window server composites them |
| `Mac/DebugModalUI.{h,m}` | the windows that ask: the popovers showing, the menus tracking, a button's press, and the answer to a sheet, an app-modal window, or a panel |
| `Mac/DebugSyntheticInput.{h,m}` | the input table, the activation, the focus check, the key, mouse, drag, and scroll posting, the key-code map, and the modifier parser |
| `iOS/DebugStandardiOSVerbs.m` | the iOS verbs of the standard table |
| `iOS/DebugiOSCapture.{h,m}` | the key window, the view tree, and the screenshot |
| `iOS/DebugFrameProbe.{h,m}` | the display-link frame probe |

## The tables

| Table | Verbs |
| --- | --- |
| standard, shared | `dump_build`, `quit`, `work_tally`, `dump_health`, `block_main`, `block_main_deep` |
| standard, macOS | `dump_view_tree`, `dump_menu`, `click_menu`, `dump_screenshot`, `capture_window`, `raise_window`, `answer_sheet`, `answer_popover`, `answer_menu` |
| standard, iOS | `dump_view_tree`, `dump_screenshot`, `set_clipboard`, `sample_frame_rate`, `dump_frame_rate` |
| input, macOS | `activate`, `key`, `key_down`, `key_up`, `click`, `mouse_down`, `mouse_up`, `mouse_move`, `drag`, `scroll` |

**`VibeDebugStandardVerbs(options)` answers the standard table**: the shared verbs, then the verbs for the platform it is built on. **`VibeDebugInputVerbs(options)` answers the input table**, on macOS. An app opts into it beside the standard table, so a later app can leave synthetic input out. The app builds each table once, at install, and adds it to the tables its dispatcher looks a verb up in. The unknown-command reply lists the same tables. The verbs' names, usages, waits, and reply keys are Vibe's, since its scripts and skills depend on them.

**TRAP: a verb held twice runs from its first spec, silently.** That holds for a verb in two tables and for a verb twice in one table. So an app keeps no verb of its own under a standard verb's name, and no verb twice in its own tables. Its install asserts that `VibeDebugDuplicateVerbs`, in `dev/DebugChannel`, finds none.

## The options

The options are blocks, so the piece holds no app type. Each block runs on main with the controller the app's dispatcher hands every handler. Every one is optional. One is a flag: `requiresKeyWindow`, YES by default (The input, below).

- **`dump_build`** replies `bundleId`, `executable`, `channel`, `version`, `git`, `built`, `pid`, and `path`, plus `buildExtras`. The eight keys win over an extra of the same name.
- **`dump_health`** replies `ok` and `process`, plus `healthExtras`. `VibeJSONString` sorts the keys, so an app that moved its own blocks into `healthExtras` keeps its reply byte-identical. Its wait is 10 s, since an app's extras may read a queue a wedge would hold.
- **`work_tally`** opens and closes `core/Common`'s work tally. The tally exists only where the app defines `VIBE_SIGNPOSTS`, so a build without it answers an error.
- **`block_main`** chains a verb from the shared verbs first, then from `chainableVerbs`. The platform verbs stay unchainable. It refuses itself and an unknown verb. It answers nil when the chained verb replies later.
- **The mouse verbs, `scroll`, `activate`, `dump_screenshot`, `capture_window`, and `raise_window`** aim at `targetWindow`. With no block, or a nil answer, they aim at `NSApp.mainWindow`. `answer_sheet` reads that window's sheet first. The key verbs post into the key window. With none, they send to the target window directly.
- **`dump_screenshot [sheet]`** renders the target window's frame view, so its title bar and toolbar show, or with `sheet`, its attached sheet (The screenshot, below). It replies `ok`, `path`, and the file's `width`, `height`, and `scale`, plus `render`, `VibeDebugRenderNote`. The PNG's resolution is 72 dpi times the scale, and the reply reads the three back from the file.
- **`capture_window [key] [menu|popover] [crop <x> <y> <w> <h>]`** is the real capture (The real capture, below). It replies later, within its 10 s wait. So does `activate`.
- **`DebugClient` treats `dump_screenshot` and `capture_window` as file verbs always**, so an app's `fileVerbs` lists only its own.
- **`click_menu`** searches `NSApp.mainMenu` and calls `performMenuItem`. With no block, NSApp sends the item's action after the validation opening the menu would run. An app passes its own dispatch when a click should prove what a shortcut does. With no key window, as when the app is not active, `click_menu` and `dump_menu` run with the target window standing in for the key window (The input, below). So an item with no target validates and fires as it would with the app in front. `click_menu`'s reply says `behind`: the app has no key window, so the stand-in sent the item. That is the app's state, not the mouse verbs' check, which asks whether the target window is key. `dump_menu`'s reply says `appActive`. **TRAP: AppKit's own lookups skip the stand-in**, such as a window controller's `supplementalTargetForAction:`. So behind, an item with no target can read disabled only because the app is behind, and `click_menu`'s error then says so and to run `activate`.

## The windows that ask

**The standard table's build starts keeping the popovers and the menus**, from their notifications, so a popover or a menu opened before it is missed. A popover counts from its will-show, since its did-show waits for its animation, and `shown` is true from the will-show on. A menu counts from its begin-tracking to its end-tracking: a pop-up, a context menu, or the menu bar's.

- **`answer_sheet [button]`** answers `NSApp.modalWindow`, else the target window's sheet, else any window's, front to back. Its reply's `sheet` and `modal` say which asks, and both are false with none. `panel` says it is an open or save panel. With a button's title, the rest of the tokens, it presses that button. `VibeDebugAnswerModal` is its answer, for an app that wants its windows in its own order.
- **A sandboxed app's panel runs out of process,** so nothing reads its files. Its one button is `Cancel`, which the panel's own `cancel:` ends. An alert's buttons come in the view tree's order, not the alert's.
- **`answer_popover [<index> <close|button>]`** lists the popovers showing, oldest first: each one's `index`, its content controller's class as `content`, its `texts`, and its `buttons`. With an index, `close` closes it with `performClose:`, and a button's title presses that button. A hidden or disabled button is refused.
- **`answer_menu [cancel]`** lists the menus tracking, outermost first, each with its `title` and `dump_menu`'s `items`. `cancel` sends each `cancelTracking`, innermost first, and no item is sent.
- **TRAP: an app-modal session looks at `stopModal` only after its next event,** and a press from the channel is no event. So a press on an app-modal window posts an application-defined event, and the session ends with the button's response.
- **The channel answers inside these loops** (`dev/DebugChannel`, its TRAP on a modal loop).

## It compiles in every configuration and ships in none

**An app lists the template in every configuration.** Each `.m` wraps its body in `#if DEBUG`, so a release build compiles each to an empty object. The headers carry no `#if DEBUG`. So a call from release code compiles and then fails to link. An app keeps every caller under its own `#if DEBUG`.

## The input

**The input verbs post `NSEvent`s into the app's own event queue.** They run real event dispatch, local monitors included, and need no Accessibility permission. They are not containment.

**The focus rule: no verb replies ok for an event that went nowhere.** A window that isn't key swallows a first click as its activation, and an app behind has no key window at all. So with `requiresKeyWindow`, a mouse verb fails while the target window isn't key, posts nothing, names the app in front, and says to run `activate`. The mouse verbs never activate on their own, so a script takes the keyboard from the user only where it says so. A key and a scroll reach a window behind, so they need no key window (below). `VibeDebugInputFocusError` is the check, for an app's own verb that posts a click. A host-less test sets `requiresKeyWindow` NO, since its NSApp is never active.

- **`activate` makes the target window key and the app active, from inside the app**, as a click on the window would, so no script needs `open -a`. It tries the deprecated force spelling, then, after half a second, the running application's own. It replies once the app's did-become-active and the window's did-become-key say both took, or after 5 s, with no run loop spun. Its reply names the app it took the keyboard `from`, and `already` says nothing changed. **TRAP: macOS 14 and later activate cooperatively.** While the user works in another app, macOS may decline, even for seconds, and then the verb fails and says so. A declined request can still land later, so a second `activate` may find it took. A locked screen fails at once. `VibeMakeWindowKeyForInjection` keeps its old one-second spin for Vibe's gesture verb, and is deprecated in its header's comment, not by an attribute, since a caller that treats warnings as errors would stop building.
- **The key verbs need no key window.** An app that is not active has none, and NSApp drops a queued key there. So with no key window, a key goes straight to the target window after the reply, as NSApp hands one to a key window: a key with Command or Control asks the window's views for a key equivalent first, then the window gets it, and its `keyDown:` reaches the main menu through its own responder chain. The app stays behind, and the user keeps the keyboard. Local monitors never see a key sent this way. The reply's `queued` says which road it took.
- **`scroll` needs no key window either**, since a wheel scrolls a window behind, and it sends to the window directly (its TRAP, below).

**TRAP: AppKit finds a nil target's action from the key window, then the main window, and an app that is not active has neither.** So a menu item with no target reads as disabled, and its shortcut does nothing. No public call names a window for that lookup. So `VibeWithStandInKeyWindow` gives NSApplication's `targetForAction:to:from:` and `sendAction:to:from:` a fallback, installed once: where AppKit found no target, they look in the stand-in's responder chain, then its delegate. It answers only while a verb runs with a stand-in, so the app's own dispatch is unchanged at every other moment. A key sent to the window directly, `click_menu`, and `dump_menu` each run with one when the app has no key window. A press on a draggable view can start a native drag. Tracking areas and hover effects never fire, since the window server drives them. The events run after the reply is written, so a caller polls the app's state for the result. Coordinates are content-view points with a top-left origin: `dump_screenshot`'s pixels divided by the backing scale.

**TRAP: a lone `mouse_down` on a control that runs a modal tracking loop stalls the app inside the loop.** The channel cannot deliver the `mouse_up` while it spins. `click` and `drag` queue every event before the loop starts.

**TRAP: an `NSEvent` made from a `CGEvent` has no window.** NSApp drops it. So `scroll` places its point to read as the window point and sends the event to the window directly.

An app's own verbs may call the posting functions, the key-code map, and the modifier parser, as a shortcut verb or a named gesture probe does.

## The screenshot

**The mac render runs in-process, with no window-server capture.** It needs no permission, and it works with the display asleep or the window occluded. It is for layout and text only, and every reply says so with `VibeDebugRenderNote`. It renders the frame view, so the title bar and the toolbar show. **TRAP: a glass view's layer and a `CABackdropLayer` render as opaque white in `renderInContext:`.** So each backdrop gives way, uncommitted, to an opaque, appearance-matched fill in its place, in its z-order, and each glass view is hidden over the same fill, with its content view rendered on top, in its place, so a sidebar's rows show. Only the class's name tells a backdrop apart. So no material, tint, or blending shows, and a selection or a header can read black where the window shows gray. **X5: what scrolls up under a toolbar or a table's header is covered on screen by the scroll view's pocket, whose material is a backdrop.** The fill in its place covers it in the render too, so no clip of the clip view is needed. The fills and hides force a render of the model tree, so such a window's animations land at their target values. **The presentation-tree road still runs for a window with no glass and no backdrop**, and captures animations mid-flight. The render runs the window's pending layout and display first. Metal content does not render.

## The real capture

**`capture_window` captures the target window as the window server composites it, through ScreenCaptureKit**: glass, vibrancy, blending, the title bar, the toolbar, and the window's sheets and child windows. The app's open menus and showing popovers are taken in too, since a user sees them over the window. A menu's window is the app's own, at the pop-up menu's level, and only the window server lists it, so the capture finds it there. A popover's comes from the popovers the standard table keeps. What a sheet owns counts as the sheet, since on macOS 26 a sheet's glass is a child window of its own, which the window server draws in its place. A menu that stopped tracking fades out a moment longer, and is left out.

- **It never captures another app's window, the desktop, the Dock, or the menu bar.** The filter includes the app's own windows alone, over a clear background, so whatever sits behind or in front of them is left out. A region off the windows is transparent.
- **It needs no Screen Recording permission.** Since macOS 14.4, `getCurrentProcessShareableContent` lists the windows a process may capture with no consent, so no user-declined error can come from it. The list names other processes' windows too, redacted, so the capture keeps only its own process's.
- **It needs the window server to draw**: an unlocked screen, an awake display, and the window on screen, not minimized or hidden. `VibeDebugCaptureBlocker` says which is missing, the error's `blocker` names it (`locked`, `asleep`, or `hidden`), and its message names `dump_screenshot` as the fallback. A window behind another app's still captures, and the reply's `occluded` says so: the app may draw such a window late.
- **`key`** runs `activate` first, unless the window is key already, then captures one frame after the window draws as key. The reply's `windowKey` and `appActive` say what the capture shows, either way.
- **`menu` and `popover`** frame the open menus or the showing popovers alone, with a 12-point margin, and fail with none. With neither, the region is the window's frame, grown to take in a menu or popover that sticks out.
- **`crop <x> <y> <w> <h>`** cuts the region, in points from its top left.
- **The reply's keys** are in `DebugWindowCapture.h`. The region is cut to the window's display. The PNG is encoded on ScreenCaptureKit's queue, and only the reply goes to main.

`VibeInstallDebugScreenshotHook` renders to a fixed path whenever its notification is posted, so a terminal can take a screenshot with `notifyutil -p`. `dump_screenshot` writes a file per command instead, under the channel's screenshot path.

The iOS render draws the key window's hierarchy. Blurs render only approximately. `simctl io booted screenshot` is the ground truth for pixels.

## Process health

The counters are for diffing between two readings of a run. None means much alone. **TRAP: a descriptor count lists the open descriptors, never the table's size.** The size grows with peak concurrency and never shrinks, so a burst of opens would read as a leak. iOS has no `libproc`, so it probes each slot of the table. The malloc counter keeps live allocations and the allocator's reservations apart. Under ASan or TSan it reads the sanitizer's own counts.

## The frame probe

On iOS, `sample_frame_rate` counts the frames the app is granted for a few seconds, and how many ran long. `dump_frame_rate` reads the report. `VibeDebugBeginFrameProbe(0)` runs the probe until it is replaced, and logs a report every five seconds. That is the road off a phone, whose console relays the log. An app starts it from a launch flag of its own.

## Tests

`Tests/dev/DebugVerbs/Mac/` holds `DebugVerbsTests`, which defines `DEBUG` and `VIBE_SIGNPOSTS` in every configuration. They run each verb through its handler, as an app's dispatcher does, with options and a controller of their own.

- **The tables**: every verb is unique, every usage parses, and the waits are Vibe's.
- **The shared verbs**: `dump_build` answers its eight keys plus the extras, and its own keys win. `dump_health` answers the process block and the extras, and the malloc counter's live bytes never exceed its reserved bytes. `block_main` holds main for its seconds, chains a shared verb and an app's verb, refuses itself, an unknown verb, and a platform verb, and answers nil when the chained verb replies later. `work_tally` opens and closes a window.
- **The view tree and the menus**: the tree names each view's class, identifier, hidden state, and alpha. The menu dump lists a separator, a submenu, a key equivalent, a hidden item, a disabled item, and a state. `click_menu` hands the app's dispatch the item it found, sends the action itself with none, and answers the disabled, hidden, and submenu errors.
- **The input**: the key verbs post what a real key carries, the shifted character in both fields and the function and numeric-pad flags on an arrow. `click` posts a down and an up per count, with the count ascending. `drag` posts its steps between one down and one up. Each event is read back from the app's own queue. **TRAP: a test calls `[NSApplication sharedApplication]` first, since host-less `NSApp` is nil.** No test asserts key status, since activation may not take on CI. So `TestOptions()` turns `requiresKeyWindow` off, and only the focus check's own test keeps it on. A mouse test makes its window key first, as a run does with `activate`: on CI, a window that isn't key read its events' points as the screen's.
- **The windows that ask**: an alert run app-modal is read, and a press from a main-queue block ends its session with that button. A sheet is read from the first owner that has one, its keys are JSON booleans, and an unknown button is refused. `answer_sheet` looks past a target window with no sheet. A save panel's sheet reads as a panel with one button, Cancel, and its cancel ends it. **TRAP: host-less, NSApp never runs, so a panel's completion never comes**, even after `endSheet:`, and the test checks that the sheet ended. A popover is listed from its show on, before its animation ends, and its button is pressed and it closes. A hidden button is not pressed. A menu popped up is listed from a main-queue block while it tracks, and its cancel sends no item.
- **The screenshot** of a test window is a PNG of its points times its backing scale, and the verb's reply names that size and scale. A glass view's content renders in its place, not as white. Rows scrolled under a window's toolbar stay covered, and a render with no fill fails that test.
- **`dump_screenshot`** renders the target window's frame, or its sheet with `sheet`, and fails with none.
- **The real capture**: its arguments parse, and a bad one is refused, two focuses among them. Its region takes in a menu that sticks out, frames a menu alone with its margin, and crops from its top left. A hidden window fails, with `blocker` hidden, and names the render. A shown window captures at its frame's points times its scale, its content's color and all, with no permission. That test skips while the screen is locked or the display asleep.
- **The focus check**: with `requiresKeyWindow`, its default, each mouse verb behind fails, names `activate`, and posts nothing. `activate` replies later, and its activation answers within 5 s either way. Behind, `click_menu` sends through the stand-in and says `behind`, an item with a target of its own reads disabled plainly, and `dump_menu` says `appActive`.

`DebugVerbs-iOS` builds the iOS half. The minimal consumer answers `dump_build` and `dump_health` from the standard table, beside a command of its own, with no `VIBE_SIGNPOSTS`.

Vibe's contract run checks the verbs in a running app, before and after each change to them (`docs/debug-verbs.md`).

# The standard debug verbs

**Status: done. Planned on 2026-10-30, and every step merged on 2026-10-30 and 2026-10-31: Vibe #428, this repo's #87 and #88, Vibe #429 and #431, the other app's #52, and the third app's #50. Vibe #430 came before #429, to take this repo's #86.** This is the plan for `dev/DebugVerbs`, a new piece holding the debug verbs every app's channel answers, and for the debug client's move into `dev/DebugChannel`. It also covers each app taking them: Vibe, the other app, and the third app. Read [plan.md](plan.md)'s "The work, in order" first. Every rule there holds here.

## Why

Vibe's debug channel answers about 170 verbs. About twenty know nothing of Vibe: the view tree, the menu, the screenshot, synthetic input, process health, the build, quit, and the main-thread stalls. Its CLI client is also mostly generic. The other app already keeps its own copies of `dump_build`, `dump_screenshot`, `quit`, and the client. The third app has no channel yet and would write a third copy. So the second-app rule is met.

## Decided

- **A new piece, `dev/DebugVerbs`, template `VibeLibsDebugVerbs`.** It depends on `dev/DebugChannel` and `core/Graphics`, besides `core/Common`. It builds on both platforms, with `Mac/` and `iOS/` halves. Graphics is for the menu dump's image digest (`NSImage+Util`).
- **DebugChannel stays verbless.** Its job is the transport, and the verbs are a second job. An app may take the transport and write every verb itself.
- **The client joins DebugChannel's `Mac/` half.** It is the transport's other end, and it needs nothing but the wire format. This reverses DebugChannel's "The client. The piece has none." Two apps carry a copy now, and a third would write one.
- **Verb names, usages, waits, and reply keys stay Vibe's.** Vibe's `vibe-debug` and `vibe-stress` skills, its stress runner's allowlist, and its scripts depend on them. The other apps adapt to Vibe's replies, not the reverse.
- **The synthetic input verbs are a second table, which an app opts into.** All three apps take it. It stays separate, so a later app can leave it out. The other app's rules forbid synthetic input today, so step 6 changes that rule first.
- **The API changes happen in Vibe first, in one prep pull request.** The move here then carries the staged files unchanged (plan.md's rule: a move changes nothing but the path).
- **The screenshot's upgrade is a separate change after the move.** The other app's renderer handles backdrop layers and glass content better than Vibe's does. Its logic joins the piece's renderer in its own pull request, with its own screenshot comparison.
- **This repo, Vibe, and the third app never name the other app.** Call it "the other app" in every commit, pull request, comment, and doc. Its own files are not named here either.

## What moves

The standard table is `VibeDebugStandardVerbs(options)`. It holds the shared verbs, then the verbs for the platform it is built on.

| Verb | Table | From, in Vibe | To, in `dev/DebugVerbs` |
| --- | --- | --- | --- |
| `dump_build` | standard, shared | `Verbs/DebugCommonVerbs.m` | `DebugStandardVerbs.m` |
| `quit` | standard, shared | `Verbs/DebugCommonVerbs.m` | `DebugStandardVerbs.m` |
| `work_tally <begin\|end>` | standard, shared | `Verbs/DebugCommonVerbs.m` | `DebugStandardVerbs.m` |
| `dump_health` | standard, shared | `Oracles/DebugHealth.m`, the process block only | `DebugStandardVerbs.m`, `DebugProcessHealth.m` |
| `block_main`, `block_main_deep` | standard, shared | `Verbs/DebugStallVerbs.m` | `DebugStandardVerbs.m` |
| `dump_view_tree`, `dump_menu`, `click_menu` | standard, macOS | `Mac/DebugStateDump.m`, `Mac/DebugMacVerbs.m` | `Mac/DebugViewTree.m`, `Mac/DebugStandardMacVerbs.m` |
| `dump_screenshot` | standard, macOS | `Mac/DebugScreenshot.m`, `Mac/DebugMacVerbs.m` | `Mac/DebugScreenshot.m`, `Mac/DebugStandardMacVerbs.m` |
| `raise_window` | standard, macOS | `Mac/DebugWindowVerbs.m` | `Mac/DebugStandardMacVerbs.m` |
| `dump_view_tree`, `dump_screenshot`, `set_clipboard` | standard, iOS | `iOS/DebugiOSVerbs.m` | `iOS/DebugiOSCapture.m`, `iOS/DebugStandardiOSVerbs.m` |
| `sample_frame_rate`, `dump_frame_rate` | standard, iOS | `iOS/DebugiOSVerbs.m`, `iOS/Seams/RootViewController+Debug.m` | `iOS/DebugFrameProbe.m`, `iOS/DebugStandardiOSVerbs.m` |
| `key`, `key_down`, `key_up`, `click`, `mouse_down`, `mouse_up`, `mouse_move`, `drag`, `scroll` | input, macOS | `Mac/DebugInput.m`, `Mac/DebugMacVerbs.m` | `Mac/DebugSyntheticInput.m` |
| the client: `sleep`, `script`, the poll, a file reply to stdout | none: it runs in the client | `Mac/DebugClient.m` | `dev/DebugChannel/Mac/DebugClient.m` |

**What stays in Vibe:** every verb that reaches the player, the playlist, `AppSettings`, a theme, a fake, or a shell class. That includes `set_appearance`, which writes `AppSettings`, and `set_window_width` and `measure_resize`, which size the pitch panel. `quiesce` stays, since it polls Vibe's pending work, but it reads the piece's malloc counter. `gesture_test`, `select_rows`, and `set_shortcut` stay too, and call the piece's input helpers. The client's local verbs stay: `scan_bpm`, `scan_key`, `clear_disk_caches`, and `set_analysis`.

**Left for later:** the Settings walker's verbs (`settings_open` and the rest) drive `ui/SettingsWindow`, which the third app also uses. They still reach Vibe's app delegate and Themes pane, and they would need a piece of their own over DebugChannel and SettingsWindow. `dump_now_playing` is generic but links MediaPlayer. Neither is in this plan.

## The piece

| File | Holds |
| --- | --- |
| `DebugStandardVerbs.{h,m}` | `VibeDebugStandardOptions`, `VibeDebugStandardVerbs`, and the shared verbs |
| `DebugProcessHealth.{h,m}` | the process counters, the malloc counter, and the layer count, on both platforms |
| `Mac/DebugStandardMacVerbs.m` | the mac verbs of the standard table |
| `Mac/DebugViewTree.{h,m}` | the window and view tree, the menu dump, and the menu item search |
| `Mac/DebugScreenshot.{h,m}` | the in-process window render, and the notifyutil hook |
| `Mac/DebugSyntheticInput.{h,m}` | the input table, the key, mouse, drag, and scroll posting, the key-code map, and the modifier parser |
| `iOS/DebugStandardiOSVerbs.m` | the iOS verbs of the standard table |
| `iOS/DebugiOSCapture.{h,m}` | the key window, the view tree, and the screenshot |
| `iOS/DebugFrameProbe.{h,m}` | the display-link frame probe |
| `AGENTS.md` | the piece's doc |

The options are blocks, so the piece holds no app type. Each block runs on main with the controller the app's dispatcher hands every handler.

```objc
// DebugStandardVerbs.h
@class NSWindow, NSMenuItem;

@interface VibeDebugStandardOptions : NSObject
// Keys merged into dump_build's reply.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *_Nullable (^buildExtras)(id controller);
// Blocks merged into dump_health's reply, beside "ok" and "process".
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *_Nullable (^healthExtras)(id controller);
// The app's verbs block_main may chain, after the shared verbs.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *_Nullable (^chainableVerbs)(void);
// macOS: the window the mouse verbs aim at and raise_window raises. Nil, or a nil answer: NSApp.mainWindow.
@property (nonatomic, copy, nullable) NSWindow *_Nullable (^targetWindow)(id controller);
// macOS: click_menu's dispatch. NO when nothing handled the item. Nil: NSApp sends the item's action.
@property (nonatomic, copy, nullable) BOOL (^performMenuItem)(id controller, NSMenuItem *item);
@end

NSArray<NSDictionary *> *VibeDebugStandardVerbs(VibeDebugStandardOptions *options);

// DebugProcessHealth.h
NSDictionary<NSString *, NSNumber *> *VibeDebugProcessHealth(void);  // dump_health's "process" block
void VibeDebugMallocBytes(uint64_t *live, uint64_t *reserved);
NSUInteger VibeDebugLayerCount(CALayer *layer);

// Mac/DebugViewTree.h
NSString *VibeViewTreeDump(void);
NSArray *VibeMenuArray(NSMenu *menu);
NSMenuItem *_Nullable VibeFindMenuItem(NSMenu *menu, NSString *identifierOrTitle);

// Mac/DebugScreenshot.h
BOOL VibeDumpWindowSnapshot(NSString *path);
void VibeInstallDebugScreenshotHook(NSString *notificationName, NSString *path);

// Mac/DebugSyntheticInput.h
NSArray<NSDictionary *> *VibeDebugInputVerbs(VibeDebugStandardOptions *options);
NSString *VibeInjectKey(NSWindow *window, NSArray<NSString *> *tokens, BOOL down, BOOL up);
NSString *VibeInjectMouse(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectScroll(NSWindow *window, NSArray<NSString *> *tokens);
void VibeMakeWindowKeyForInjection(NSWindow *window);
NSPoint VibeWindowPointForContentPoint(NSWindow *window, double x, double y);
NSPoint VibeContentPointForWindowPoint(NSWindow *window, NSPoint point);
NSNumber *_Nullable VibeKeyCodeForName(NSString *name);
BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start, NSEventModifierFlags *flags,
                        BOOL *repeat, NSString *_Nullable *_Nonnull errorJSON);

// iOS/DebugiOSCapture.h
UIWindow *_Nullable VibeDebugKeyWindow(void);
NSString *VibeViewTreeDump(void);
NSString *VibeScreenshotJSON(NSString *commandId);

// iOS/DebugFrameProbe.h
void VibeDebugBeginFrameProbe(NSTimeInterval seconds);  // 0: until replaced, logging every 5 s
NSDictionary *VibeDebugFrameProbeReport(void);
```

How each verb uses the options:

- **`dump_build`** replies `bundleId`, `executable`, `channel`, `version`, `git`, `built`, `pid`, and `path`, plus `buildExtras`. `NSBundle+BuildInfo` is already in `core/Common`.
- **`dump_health`** replies `ok` and `process`, plus `healthExtras`. Vibe's extras are `ui`, `app`, `pending`, and `materialization`. `VibeJSONString` sorts the keys, so Vibe's reply stays byte-identical.
- **`block_main`** chains a verb from the shared verbs first, then from `chainableVerbs`. The platform verbs stay unchainable, as today.
- **The mouse verbs, `scroll`, and `raise_window`** aim at `targetWindow`. The key verbs post into the key window, or `targetWindow` when none is key, as Vibe's do today.
- **`dump_screenshot`** keeps Vibe's choice of window: the key window, then the main window, then the frontmost visible one. It ignores `targetWindow`.
- **`click_menu`** searches `NSApp.mainMenu` and calls `performMenuItem`. Vibe passes its key monitor's dispatch, so a click still proves what a shortcut does.

**The headers carry no `#if DEBUG`, and each `.m` wraps its body in it**, as DebugChannel's do. An app lists the template in every configuration. A release build compiles each file to an empty object, and a call from release code fails to link.

## The client

```objc
// dev/DebugChannel/Mac/DebugClient.h
@interface VibeDebugClientOptions : NSObject
@property (nonatomic, copy) NSString *channel;                          // the name the app installed
@property (nonatomic, copy) NSString *displayName;                      // "Vibe", in usage and no-reply lines
@property (nonatomic, copy) NSString *messagePrefix;                    // "vibe", before every stderr line
@property (nonatomic, copy, nullable) NSString *timeoutEnvironmentKey;  // "VIBE_DEBUG_TIMEOUT"
// A verb's wait, read from the app's tables. 0: the default, 5 s.
@property (nonatomic, copy, nullable) NSTimeInterval (^waitForVerb)(NSString *verb);
// Verbs whose reply's "path" is a file: written to stdout under "-", and as base64 in a script.
@property (nonatomic, copy) NSArray<NSString *> *fileVerbs;            // Vibe: @[@"dump_screenshot"]
// A verb the client runs in its own process. Answers its exit code, or -1 when it is no local verb.
@property (nonatomic, copy, nullable) int (^localVerb)(NSArray<NSString *> *args, BOOL inScript,
                                                       void (^print)(NSString *json));
@end

// argv[1] is the app's client flag. Answers the exit code: 0 ok, 1 no reply, 2 an error reply, 64 usage.
int VibeDebugClientMain(int argc, const char *_Nonnull argv[_Nonnull], VibeDebugClientOptions *options);
```

`sleep`, `script`, the script tokenizer, compact NDJSON in a script, and the file reply all move unchanged. Vibe's client special-cases `dump_screenshot` by name today. `fileVerbs` carries that name instead, so the transport names no verb. DebugChannel's map row stays "nothing".

## The order

Every change lands here first, then in a consumer's pin, then through that consumer's gates. So the merges go in this order. The work behind them can be written side by side in worktrees, against local branches.

| Step | Repo | Pull request | Merges after |
| --- | --- | --- | --- |
| 1 | Vibe | the prep: the staged files and their API | nothing |
| 2 | here | the move, with history, and the piece's build and tests | step 1 |
| 3 | here | the screenshot's upgrade, and the duplicate-verb check | step 2 |
| 4 | Vibe | pin step 2, take the piece, delete the staged files | step 2 |
| 5 | Vibe | pin step 3 | steps 3 and 4 |
| 6 | the other app | pin step 3, take the piece, delete its copies | step 3 |
| 7 | the third app | pin step 3, take its first pieces, write its verbs | step 3 |

Steps 4, 6, and 7 can go together once their pins exist. Step 1 must merge with a merge commit, not a squash, so its commits survive for the move's history. The prep for Vibe #393 kept its two commits that way.

## Step 1: Vibe's prep

**Merged on 2026-10-30 as Vibe #428**, with a merge commit, `18a23258`.

One pull request in Vibe, under Vibe's gates. It stages every file the piece will hold, at paths filter-repo maps to the piece:

| Staging path in Vibe | Becomes, here |
| --- | --- |
| `Vibe/Debug/Standard/` | `dev/DebugVerbs/` |
| `Vibe/Debug/Mac/Standard/` | `dev/DebugVerbs/Mac/` |
| `Vibe/Debug/iOS/Standard/` | `dev/DebugVerbs/iOS/` |
| `Vibe/Debug/Mac/Channel/` | `dev/DebugChannel/Mac/` |

The platform staging directories sit under `Vibe/Debug/Mac/` and `Vibe/Debug/iOS/`, as `Seams/` does. So `project.yml`'s platform excludes already cover them, and Vibe's layout rule needs no exception.

The commits, in order. Each builds and passes Vibe's tests on its own.

1. **Rename the uptime function in `Oracles/DebugHealth.m` to `VibeDebugUptimeSeconds`.** Its name today is `Vibe` + `ProcessUptimeSeconds`, which this repo's name check matches (TRAPs below).
2. **Move three files with `git mv`, changing nothing inside them.** `Mac/DebugScreenshot.m` goes to `Mac/Standard/DebugScreenshot.m`. `Mac/DebugInput.m` goes to `Mac/Standard/DebugSyntheticInput.m`, since most of its lines are generic. `Mac/DebugClient.m` goes to `Mac/Channel/DebugClient.m`. So blame follows each file, and filter-repo can carry its earlier paths.
3. **Split the input file.** `set_shortcut`, `reset_shortcuts`, `gesture_test`, and `select_rows` go to a new `Mac/DebugShellInput.m`. The new name keeps every live file off a moved file's earlier path (TRAPs below). The posting functions take an `NSWindow`, not `MainPlayerController`. The key-code map and the modifier parser become `VibeKeyCodeForName` and `VibeParseModifiers`.
4. **Split the view tree and the menus** out of `Mac/DebugStateDump.m` into `Mac/Standard/DebugViewTree.{h,m}`. `VibeClickMenuItem` stays in Vibe as a call to `VibeFindMenuItem` and the controller's `performMenuItem:`, until commit 8 moves `click_menu`.
5. **Give the screenshot a header, and its hook two arguments.** Vibe's app delegate passes the same names it derives today: the bundle identifier plus `.debug.screenshot`, and `vibe-screenshot.png` in the tmp directory.
6. **Split the process counters** out of `Oracles/DebugHealth.m` into `Standard/DebugProcessHealth.{h,m}`. `VibeDebugHealthJSON` becomes `VibeDebugHealthExtras`, which answers the `ui`, `app`, `pending`, and `materialization` blocks. `quiesce` reads `VibeDebugMallocBytes`.
7. **Stage the iOS half.** The key window, the view tree, and the screenshot leave `iOS/DebugiOSVerbs.m` for `iOS/Standard/DebugiOSCapture.{h,m}`. The frame probe leaves `RootViewController+Debug` for `iOS/Standard/DebugFrameProbe.{h,m}`, as two functions over a private target object. `DebugiOSEntry.m` starts it with `VibeDebugBeginFrameProbe(0)` under `--frame-rate-probe`.
8. **Build the tables.** `Standard/DebugStandardVerbs.{h,m}`, `Mac/Standard/DebugStandardMacVerbs.m`, and `iOS/Standard/DebugStandardiOSVerbs.m` take the moved verbs. The input table joins `DebugSyntheticInput.m`. Each moved verb leaves Vibe's tables in the same commit. Each dispatcher looks a verb up in the common table, then the standard table, then on macOS the input table, then its own. `VibeCommandSpecForVerb` and the unknown-command reply read the same tables. Vibe's options pass `healthExtras`, `chainableVerbs` (the common table), `targetWindow` (the controller's window), and on macOS `performMenuItem`.
9. **Generalize the client.** `Mac/Channel/DebugClient.{h,m}` takes `VibeDebugClientOptions`. Vibe's four local verbs move to a new `Mac/DebugClientLocalVerbs.m`, which `localVerb` calls. `VibeDebugCommandClientMain` builds the options and calls `VibeDebugClientMain`.
10. **Clean the staged files**, so the move carries them unchanged:
    - Each imports what it uses, never `DebugInternal.h` or another Vibe header. It may import system headers, DebugChannel's three headers, `core/Common`, and `core/Graphics`.
    - Each comment names no Vibe file or class. The input file's notes on `TransportKeyMonitor` and the Q/W/E/R/T keys say what a handler does instead, such as "latches on a tap and reverts on a hold, deciding on key up".
    - No header holds `#if DEBUG`.
    - `Standard/AGENTS.md` is written here, as the piece's doc. It moves with the files.
11. **Update `Vibe/Debug/AGENTS.md`**: the layout, and which verbs are staged for vibe-libs.

Check the staged files before opening the pull request:

```bash
grep -rlE '#import "(DebugInternal|DebugMacEntry|DebugiOSEntry|DebugCommonVerbs|DebugPlayerSurface|AppDelegate|MainPlayerController|RootViewController|AppSettings)' Vibe/Debug/Standard Vibe/Debug/Mac/Standard Vibe/Debug/iOS/Standard Vibe/Debug/Mac/Channel
```

```bash
grep -rniP 'vibe[ ._-]?pro(?!be)' Vibe/Debug/Standard Vibe/Debug/Mac/Standard Vibe/Debug/iOS/Standard Vibe/Debug/Mac/Channel
```

Both must print nothing.

**Done when** Vibe's gates pass, and the contract run (below) gives the same replies before and after on both platforms. The one expected difference is the order of the unknown-command reply's list.

## Step 2: the move here

**Merged on 2026-10-30 as this repo's #87**, `49c8aa4`. It carried 35 commits of the 19 files from `18a23258`.

On a fresh, full clone of Vibe at step 1's merge, list each staged file's earlier paths:

```bash
for f in $(git ls-files Vibe/Debug/Standard Vibe/Debug/Mac/Standard Vibe/Debug/iOS/Standard Vibe/Debug/Mac/Channel); do
  git log --follow --name-only --format= -- "$f" | sort -u
done
```

Pass each earlier path to filter-repo only when `git ls-tree HEAD -- <path>` prints nothing. A live file at an earlier path would be renamed into the piece too. Then:

```bash
git filter-repo \
  --path Vibe/Debug/Standard/ --path Vibe/Debug/Mac/Standard/ \
  --path Vibe/Debug/iOS/Standard/ --path Vibe/Debug/Mac/Channel/ \
  --path <each earlier path> \
  --path-rename Vibe/Debug/Mac/Standard/:dev/DebugVerbs/Mac/ \
  --path-rename Vibe/Debug/iOS/Standard/:dev/DebugVerbs/iOS/ \
  --path-rename Vibe/Debug/Standard/:dev/DebugVerbs/ \
  --path-rename Vibe/Debug/Mac/Channel/:dev/DebugChannel/Mac/ \
  --path-rename <each earlier path>:<its final path> \
  --message-callback 'import runpy; return runpy.run_path("<vibe-libs>/scripts/plan/filter-messages.py")["rewrite"](message)'
```

Before merging, check three things in the filtered clone:

- `git diff --no-index` between each final file and its staged copy in Vibe prints nothing.
- `git log --format=%B | grep -niP 'vibe[ ._-]?pro(?!be)'` prints nothing.
- `git log --format=%B | grep -niE '(clos|fix|resolv)[a-z]*:?[ \t]+(#|GH-)[0-9]'` prints nothing.

Then, in a vibe-libs worktree, with no remote added (plan.md's rule):

```bash
git fetch <path-to-filtered-clone> HEAD
```

```bash
git merge --allow-unrelated-histories FETCH_HEAD -m "Bring dev/DebugVerbs and the debug client from Vibe, with their history"
```

The second commit is "dev: Build and test DebugVerbs on its own". It changes these, as DebugChannel's move did (this repo's #44):

- **`vibe-libs.yml`**: `VibeLibsDebugVerbs`, with `templates: [VibeLibsCommon, VibeLibsDebugChannel, VibeLibsGraphics]`, sources `dev/DebugVerbs` excluding `**/*.md` and `${excludedPlatform}/**`, and header search paths for `dev/DebugVerbs` and both halves. `VibeLibsDebugChannel` adds `dev/DebugChannel/Mac` to its search paths.
- **`project.yml`**: `DebugVerbsTests` (macOS, `DEBUG=1` and `VIBE_SIGNPOSTS=1` in every configuration), and `DebugVerbs-iOS` (a static library, `DEBUG=1`). Both join the scheme's build and test lists beside DebugChannel's.
- **`Tests/dev/DebugVerbs/`**, new:
  - The table: every verb is unique, every usage parses, and the waits match Vibe's: 30 s for `block_main` and `block_main_deep`, and 10 s for `dump_health`.
  - `dump_build` answers its eight keys plus `buildExtras`.
  - `dump_health` answers `process` with nonzero threads, file descriptors, and footprint, plus `healthExtras`. The malloc counter's live bytes never exceed its reserved bytes.
  - `block_main` holds main for at least its seconds. It chains a shared verb and a verb from `chainableVerbs`. It refuses itself and an unknown verb. It answers nil when the chained verb replies later.
  - `work_tally` opens and closes a window.
  - The view tree of a window the test makes names each view's class, identifier, hidden state, and alpha.
  - The menu dump lists a separator, a submenu, a key equivalent, a hidden item, and a state. `click_menu` calls `performMenuItem` with the found item, and answers the disabled and submenu errors.
  - The key verbs post a key event whose characters, key code, and flags match a real one: shifted characters under shift, and the function and numeric-pad flags on an arrow. `click` posts a down and up per count, with the count ascending. `drag` posts its steps between one down and one up. Each event is read back with `nextEventMatchingMask:`. **A test calls `[NSApplication sharedApplication]` first, since host-less `NSApp` is nil. It never asserts key status, since activation may not take on CI.**
  - The screenshot of a test window is a PNG of the window's points times its backing scale.
- **`Tests/dev/DebugChannel/`**: the client's tests. Each runs `VibeDebugClientMain` on a background queue against a channel the test installs, while main drains it. They check each exit code: 0 for a reply, 2 for an error reply, 1 for no reply within 0.5 s, and 64 for usage. A script stops at its first failure, and a file verb's file reaches stdout under `-`.
- **`Tests/Consumer/`**: the consumer's channel answers `dump_build` and `dump_health` from the standard table beside its own.
- **`dev/DebugVerbs/AGENTS.md`** (moved), and **`dev/DebugChannel/AGENTS.md`**: the client section says the client is here, and what an app passes it.
- **`AGENTS.md` and `README.md`**: forty-five pieces, with `dev/DebugVerbs` in the list. The users line becomes "Vibe, another app, and a third app", since the third app takes its first pieces in step 7.
- **`docs/plan.md`**: the tree's `dev/` lines, the map row `dev/DebugVerbs | dev/DebugChannel, core/Graphics`, the Phase 6 entry, the consumer table's mac-app row, and a row in "What the other app needs".

The third commit names this repo's pull request in the plan, as #44's did.

**Done when** CI passes all five jobs, and the moved files' content equals step 1's staged files.

## Step 3: the screenshot, and duplicate verbs

**Merged on 2026-10-31 as this repo's #88**, `ee39d99`. Vibe's player, Settings, and About windows, in light and dark, differ only in the playlist's backdrop, the Settings sidebar's glass, and the Settings toolbar's backdrop. About's pixels are identical.

One pull request here. Two changes, each its own commit.

- **The mac renderer takes the other app's two fixes.** It also hides each `CABackdropLayer`, which renders white in `renderInContext:`. After hiding a glass view's layer, it renders that glass view's content view on top, in its place, so a sidebar's rows show. With no glass and no backdrop, it still renders the presentation tree, as today. The reply gains `ok`, `width`, `height`, and `scale` beside `path`. Every key is added, so Vibe's client and scripts still read `path`.
- **`NSArray<NSString *> *VibeDebugDuplicateVerbs(NSArray<NSArray<NSDictionary *> *> *tables)`** joins `DebugCommandDispatch`. It answers each verb that more than one table holds. A verb in two tables runs from the first one silently, so each app's install asserts this is empty.

**Done when** CI passes, and Vibe's screenshots before and after differ only inside glass and backdrop regions. Take the player, Settings, and About windows, each in light and dark.

## Step 4: Vibe takes the piece

**Merged on 2026-10-31 as Vibe #429**, `f3364d8`, after Vibe #430, `397ae69`. The contract run gave step 1's replies, screenshots byte-identical, on both platforms. `make test-audio` took 21 s before and after. `perf.py compare` from step 1's parent to the branch's working tree moved 69 of 569 benchmarks beyond ±0.5%, through the changes #430 took and the working-tree build's own shift. Between #430's merge and #429's, built from the two commits, 8 of the 52 that a working-tree build had moved stayed beyond ±0.5%, from +1.4% to -1.3%, with mixed signs. TRAP: compare two commits, not a commit and the working tree. A working-tree build moved file loads by up to 11% with identical settings.

One pull request in Vibe.

- Pin step 2's merge.
- Add `VibeLibsDebugVerbs` beside `VibeLibsDebugChannel` on the mac and iOS app targets.
- Delete the four staging directories.
- **`.claude/skills/vibe-debug/scripts/debug-ios.sh` reads each verb's wait from the tables' source.** Its `find` gains `"$ROOT/vibe-libs/dev/DebugVerbs"`. Without it, `block_main` and `block_main_deep` wait 10 s, not 30 s, and nothing fails.
- Update `Vibe/Debug/AGENTS.md`, and every file path the `vibe-debug` and `vibe-stress` references cite.

Report the code removed from Vibe apart from the code added across both repos (plan.md's rule). Run `perf.py compare` between step 1's parent and this pull request, as earlier moves did. No benchmark compiles a debug file, so expect no outlier, and report the run. `make test-audio`'s time stays within noise. The build audit shows only the moved paths.

**Done when** Vibe's gates pass, and the contract run gives step 1's replies, screenshots byte-identical.

## Step 5: Vibe takes the screenshot

**Merged on 2026-10-31 as Vibe #431**, `2780a30`. The contract run gave step 4's replies, and the screenshot differed only in the playlist's backdrop.

Pin step 3's merge. Assert `VibeDebugDuplicateVerbs` is empty at each install. **Done when** the contract run gives step 4's replies, except the screenshot's new keys and its glass regions.

## Step 6: the other app takes the piece

**The other app's #52, merged.** Its gates, its slice check, and its signpost run through the channel pass. Its screenshot matches its old renderer but for the progress bar's position. A `click` named the button it hit, and a `key` reached the key window. Its CI could not start its jobs, for a reason in its account, not in the change. So it merged on its CI's steps, run locally on its branch rebased onto its main: `make check`, `make test`, and the Release build. Its signpost run and its slice check passed there too. Its `test-deep` was not rerun after the rebase. Before it, one suite failed on a locked database while other builds ran, and passed alone.

One pull request in the other app's repository.

- **Change its input rule first, in this pull request.** Its `AGENTS.md` and its debug skill both forbid synthetic clicks today. The new rule allows the channel's input verbs, which post events inside the app. UI scripting from outside the app stays forbidden: no System Events, and no AppleScript UI scripting. The skill also says what the mouse verbs do beyond a click. They activate the app, which takes focus from the frontmost app, and a press on a draggable view can start a native drag.
- Pin step 3's merge, and add `VibeLibsDebugVerbs` beside `VibeLibsDebugChannel` on its app target.
- Its dispatcher looks up its own table, then `VibeDebugStandardVerbs`, then `VibeDebugInputVerbs`. It asserts `VibeDebugDuplicateVerbs` is empty.
- Its options pass `targetWindow` (its main window controller's window), and `buildExtras` with the three keys its launch and slice scripts read from `dump_build`: its stores-open flag and its two output flags.
- Delete its own `dump_build`, `dump_screenshot`, and `quit`, and its screenshot renderer.
- Delete its client. Its client entry builds `VibeDebugClientOptions`: its bundle identifier, its display name, its own message prefix and timeout variable, `waitForVerb` over its table, and `fileVerbs` of `dump_screenshot`.
- Its scripts and skill adapt to Vibe's replies. `dump_build`'s `bundleIdentifier` is now `bundleId`, and `channel` is the notification's name. `dump_screenshot`'s file is `path`, not `file`. `dump_screenshot -` still writes the PNG to stdout.
- Its skill lists the new verbs it gains: `dump_view_tree`, `dump_menu`, `click_menu`, `raise_window`, `dump_health`, `work_tally`, `block_main`, and `block_main_deep`, and the input verbs `key`, `key_down`, `key_up`, `click`, `mouse_down`, `mouse_up`, `mouse_move`, `drag`, and `scroll`.

**Done when** its gates pass, its slice check passes, its signpost run through the channel completes, and `dump_screenshot -` of its main window matches its old renderer's within glass and backdrop regions. A `click` on a control in its main window names that control as `hitView`, and a `key` reaches the key window.

## Step 7: the third app takes its first pieces

**The third app's #50, merged, and its CI passed.** On a Debug build under another bundle identifier, `dump_build` answered, `dump_screenshot -` showed the popover, and a `click` on the popover's Monitors… button named it and opened the window.

One pull request in the third app's repository. The third app takes no piece today, and its pin predates every move.

- Pin step 3's merge.
- `project.yml`: `include: [vibe-libs/vibe-libs.yml]`, `VIBE_LIBS_ROOT`, `templateAttributes: {excludedPlatform: iOS}` on the app target, and `templates: [VibeLibsDebugChannel, VibeLibsDebugVerbs]`. They bring Common and Graphics.
- **Build the pieces before writing a verb.** The third app treats warnings as errors, and the pieces compile under its flags at its macOS 13 target. Fix any warning in this repo first, as its own pull request, then re-pin.
- Its `main.m` routes its client flag to `VibeDebugClientMain` before `NSApplicationMain`, as Vibe's does. The client is the same binary, so it names the same channel.
- Its app delegate installs the channel at launch, under its bundle identifier, with `VibeDebugStandardVerbs` and `VibeDebugInputVerbs` and a table of its own. `targetWindow` answers the popover's window while it shows, and otherwise the key window.
- Its own first verbs call what its menu and popover call: `dump_state` (the latest published snapshot), `popover <show|close>`, `show_monitors`, `show_settings`, and `read_setup`. **Each reaches System only, never the adapter, so every safety rule still holds.** A verb that changes a level waits for its own plan.
- Its `AGENTS.md` and plan say it now takes two pieces.

**Done when** its gates pass, `dump_build` answers from a debug build, `dump_screenshot -` shows the popover, and a `click` in the popover reaches the control it hit-tests.

## The contract run

The same script runs before and after each Vibe step, from Vibe's mac client in script mode. Launch with `--no-audio-hw --no-now-playing`, open nothing, and leave the player window at a fixed size.

```text
set_window_width 600 400
raise_window
dump_build
dump_view_tree
dump_menu
dump_screenshot shot
dump_health
work_tally begin
block_main 0.2 dump_state
block_main_deep 0.2 50
work_tally end
key space
click 20 20
drag 20 20 120 20 4
scroll 100 100 -1
not_a_verb
```

Save each run's NDJSON. Delete the keys that change between builds or runs, then compare the runs line by line:

```bash
jq -cS 'walk(if type == "object" then del(.address, .pid, .built, .git, .version, .path, .pngBase64) else . end)' run.ndjson > run.masked
```

Lines 7 and 11, `dump_health` and `work_tally end`, count live work. Compare only their key paths:

```bash
sed -n '7p;11p' run.ndjson | jq -c '[paths(scalars)] | sort'
```

Decode line 6's `pngBase64` from each run and compare the PNG files by bytes. The script stops at `not_a_verb`, whose error lists every usage. Compare that list sorted. On iOS, `debug-ios.sh` runs `dump_build`, `dump_view_tree`, `dump_screenshot`, `set_clipboard hello`, `sample_frame_rate 1`, `dump_frame_rate`, `dump_health`, and `block_main 0.2 dump_state`, compared the same way.

## What changed in the doing

Each is a small fix to the plan, made while doing it.

- **`work_tally` compiles its tally only under `VIBE_SIGNPOSTS`** (step 1). The work tally exists only where the app defines it. Vibe and the other app do in Debug, and the third app does not. So an unguarded call fails to link there, as the minimal consumer showed. Without the flag, the verb answers an error.
- **`block_main` checks for itself first** (step 1). It is no longer in the table it chains from, so the old order would answer "can only chain a shared verb" for itself. The errors are unchanged.
- **`dump_build`'s eight keys win over `buildExtras` of the same name**, so an app cannot break them. Each `.m` of the standard table declares `VibeDebugStandardPlatformVerbs` in `DebugStandardVerbs.h`, since `-Wmissing-prototypes` needs a prototype. Only `VibeDebugStandardVerbs` calls it.
- **The mouse verbs, `scroll`, `raise_window`, and the key verbs answer an error when there is no window to aim at.** Before, the controller's window was never nil.
- **The client's options have defaults**: the bundle identifier, the process name, and no file verbs. A file verb whose file is missing says "no file at", not "no screenshot at". Every stdout line and exit code is unchanged.
- **Step 1 also fixed the `vibe-debug` skill's paths**, the ones the staging moved, so they were right at every commit. Step 4 moves them to vibe-libs' paths.
- **The filter's earlier paths were six**: `Vibe/Debug/DebugClient.m`, `DebugInput.m`, and `DebugScreenshot.m`, each also under `Vibe/Debug/Mac/`. TRAP: name the filtered clone's branch so no Vibe branch sits under it. A local branch `move` blocked filter-repo from writing Vibe's `move/waveform`.
- **`DebugVerbsTests` lives in `Tests/dev/DebugVerbs/Mac/`**, since a shared test file may not import AppKit unguarded.
- **`DebugChannelTests` names its channel for its process** (step 2). Two runs at once, from two worktrees, share one temporary directory and drained each other's commands. TRAP: never autosquash-rebase a move's branch. It flattens the merge that carries the history, so rebuild the branch from main, the merge, and the commits after it.
- **`dump_screenshot` reads its new keys back from the file** (step 3). The PNG records its scale as its resolution, 72 dpi times the backing scale. So the piece's header is unchanged. The sidebar's search field still renders as a white field inside the glass content.
- **Vibe #430 took this repo's #86 before step 4** (step 4). Step 2's merge sits on #86, so step 4's pin brought it. #86 splits the metadata cache into three stores. Vibe's keep list at launch named the tag store alone, so it would have removed the two art stores on every launch. Vibe's benchmark owner lacked them too, and `perf.py`'s metadata sweep aborted. `clear_caches`' reply still lists only the tag store's name, since a debug verb's reply changes in its own change.
- **An app with no `VIBE_SIGNPOSTS` answers `work_tally` with an error** (step 7). The third app doesn't define it. The other app defines it in Debug, as Vibe does, so its `work_tally` answers with a tally.
- **The other app's `dump_screenshot` renders the key window first** (step 6), as the piece does. Its own rendered the main window always.
- **The third app's `read_setup` reaches Setups as well as System** (step 7), since its Read Again reads the setup file there. It still never reaches the adapter. **TRAP: the third app lists `~/Documents/Genelec` on main at launch.** A Debug build with no Documents grant waits on the permission prompt, and its channel never answers. Its check ran under another bundle identifier, with a local, uncommitted edit that pointed the setup folder at a scratch folder.
- **The mac contract run starts from a reset container and an active app.** Two things outside the app changed its replies between runs of one build: whether the window was key, and whether the transport buttons had faded with no pointer over the window. The drag at (20, 20) can also move the window, whose place persists, or start a native drag. So each run starts with `scripts/build/reset-state.sh --mac -y` and `open -a`, and each line is compared between runs in the same state. The welcome track's path inside each build's bundle is masked. On iOS, `set_clipboard`'s `changeCount` is masked too.

## TRAPs

- **TRAP: `make check-pieces` fails any file here matching `vibe[ ._-]?pro(?!be)`, case-insensitive.** The uptime function in Vibe's `DebugHealth.m` matches, and so does any comment where the app's name is followed by a word starting with those three letters. Step 1 renames the function. Steps 1 and 2 grep the staged files and the carried messages.
- **TRAP: filter-repo's renames apply to every commit.** An earlier path that a live Vibe file still uses would bring that file in under the piece's name. Step 1 gives each split's Vibe side a new file name for this reason.
- **TRAP: Vibe's iOS script reads waits from source, and its lookup never fails.** Step 4 adds the piece to its search, or two verbs silently wait 10 s.
- **TRAP: a verb in two tables runs from the first one, silently.** Step 1 removes each moved verb from Vibe's tables in the commit that stages it. Step 3's check then guards every app.
- **TRAP: a squash merge of step 1 loses the `git mv` commits.** The move's history then starts at the squash. Merge step 1 with a merge commit.
- **TRAP: a header here may not share a basename with one an app keeps.** An app's headermap would pick one. The new headers are `DebugStandardVerbs.h`, `DebugProcessHealth.h`, `DebugViewTree.h`, `DebugScreenshot.h`, `DebugSyntheticInput.h`, `DebugiOSCapture.h`, `DebugFrameProbe.h`, and `DebugClient.h`. None matches a header Vibe, the other app, or the third app keeps.
- **TRAP: the other app regresses if it drops its screenshot before step 3.** Its renderer handles backdrops and glass content, and Vibe's does not yet.

## Done when

The three apps answer the standard verbs from `dev/DebugVerbs`, and none keeps a copy of a verb the piece holds. Vibe and the other app drive their apps through `VibeDebugClientMain`. The third app answers a command from its debug build. Every step's own done-when was met.

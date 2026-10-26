# ui/Shortcuts

Remappable shortcuts for a mac app. It depends on `ui/SettingsWindow`, whose pane base the recorder pane subclasses. It holds the encoding and its matching (`ShortcutRules.h`), a shortcut under the current keyboard layout (`ShortcutLayout`), and the Keyboard Shortcuts pane (`SettingsShortcutsViewController`). It came from Vibe. **It is macOS only.** Its files sit in its `Mac/` half. None reads an app's settings, strings, or types. An app pushes in its commands, its strings, and its store.

## The encoding

**A shortcut is one `NSUInteger`**, stored as an `NSNumber`: the key in the low 16 bits, a character flag above it, and the four modifier flags at AppKit's own bits (`VibeShortcut`). `kVibeShortcutNone` is unassigned, stored over a default to remove it.

- **A key-code shortcut names the physical key**, so a bare default stays put under AZERTY or Greek. Recording always yields one.
- **A character shortcut follows the letter**, as every Mac app's Command shortcuts do. It is only ever a default, and never stored (`VibeShortcutIsStorable`).
- Keypad Enter is Return and Forward Delete is Delete (`VibeShortcutCanonicalKeyCode`). A binding of either answers both.

**The command table is the app's.** It is an array of `@[identifier, @(default)]` pairs, in the order a hand-edited duplicate resolves. Every function that takes `commands` takes that table. The first command wins, in the menu bar as in a key monitor. So an app adds a new default last. An override stored on its key before the default existed then keeps the key.

**The overrides are sparse over the defaults.** `VibeShortcutStoredValue` answers nil at a command's default. `VibeShortcutOverridesByAssigning` gives a command a shortcut, takes it from the command that held it, and names that one, so a recording wins rather than being refused.

**Some keys are reserved and never assignable** (`VibeShortcutIsReserved`): the fixed system shortcuts, matched by character, the arrows with any modifier, Escape, and every keypad key but Enter. An override stored before its key was reserved stays stored and does nothing. A key monitor passes the press on, and `VibeShortcutForMenuItem` gives the item no equivalent.

`ShortcutRules.h` is header-only and Carbon-free, so tests of an app's command table compile it with no layout. The caller looks up a key's character under the layout and passes it in.

## The layout

`ShortcutLayout` reads the current ASCII-capable layout with TIS and `UCKeyTranslate`, once per modifier layer, on main. It answers the character a key types (`VibeShortcutCharacterForKeyCode`), the key that types a character (`VibeShortcutKeyCodeForCharacter`), the key's name (`VibeShortcutKeyLabel`), the display string (`VibeShortcutDisplayString`), and the key equivalent a menu item takes (`VibeShortcutKeyEquivalent`).

- **An app pushes four names once, before the first label** (`VibeShortcutSetKeyNames`): the space bar's, the keypad's form, a key no layout names, and an unassigned shortcut's. Until then they are empty. The arrows, Return, Tab, Delete, Escape, the paging keys, and the F keys are named by glyph or by number.
- **An app calls `VibeShortcutForgetLayout` on `kTISNotifySelectedKeyboardInputSourceChanged`**, before it redraws a shortcut. The piece keeps no observer of its own, so the app's redraw cannot run before the forget.
- **A ⌘ shortcut is named in the layout's Command layer**, for its equivalent, its label, and the reserved check alike. A layout such as Dvorak – QWERTY ⌘ types other letters there, and the press is the letter that layer types. A Greek or Cyrillic user's shortcuts show the Latin letters they type.
- **A key no layout names has no label and no equivalent.** An app refuses to record one, since no menu could draw it (`VibeShortcutAssignmentUnusable`). A key monitor still matches it.
- **TRAP: a shifted key rides in the character Shift types** (`"C"` with Command is ⇧⌘C, `"!"` is ⇧1 on US), per the `NSMenuItem` contract. The unshifted character with Shift in the mask draws right but never matches a real press. `VibeShortcutKeyEquivalent` converts from the layout's Shift layer, so no caller spells it. The special keys keep the flag.
- A key-code equivalent is already the layout's, so an app turns off the item's `allowsAutomaticKeyEquivalentLocalization` for it. A character default localizes as any app's ⌘O.

## The Keyboard Shortcuts pane

`SettingsShortcutsViewController` lists an app's commands in groups and records a shortcut for one. **It reads nothing of the app's.** Its initializer takes the effects sink, then five blocks.

- **`commandRows` answers the groups**, `@[title, @[@[identifier, label], …]]` each. A row is a pair of identifier and label, since the pane needs nothing else about a command. It is asked again on every refresh, since a label can follow a setting.
- **`shortcutForCommand` answers the shortcut a command's menu item carries**, None for none. The pane draws it through `ShortcutLayout`. A key an earlier command holds, or a reserved one, then shows as unassigned rather than twice.
- **`overrides` reads the store and `setOverrides` replaces it whole.** Reset All passes none, and undo passes the set from before a write.
- **`assign` records or clears (None) one command's shortcut.** It refuses or stores, and names in `*loser` the command that lost the shortcut. The app's block does the reserved and unusable checks, writes, and requests its own effects.

The pane's fifteen strings are properties, each set before the view loads.

- Clicking a command's shortcut, Record Shortcut, or a double-click starts recording. Record Shortcut and Clear act on the selected row, and Reset All on the whole list. Escape alone cancels a recording.
- **Every write is undoable.** The pane keeps its own `NSUndoManager` (`paneUndoManager`), which the settings window routes Edit > Undo to while the pane is selected. Each entry restores the whole override set, so a reassignment's loser returns with it.
- **Recording is a state of the pane, not a control.** A local monitor swallows every key in the settings window until the captured key is released. So a recorded ⌘W or bare key never reaches a menu key equivalent, and its repeats are swallowed too. Resigning key or opening a menu cancels it, since the release would never arrive.
- **TRAP: the list's reload and reselection post selection changes**, ignored under `_reloadingList`. Treated as the user's, a refresh on regaining key would cancel the recording it ran under.

## Tests

`Tests/ui/Shortcuts/Mac/` holds the encoding's tests over a table of their own, the layout's, and the pane's. They run on macOS. The layout tests ask the runner's layout what a key types rather than naming a letter, so any ASCII-capable layout passes. The pane's tests host it in a window that is never shown. A local monitor sees only events `NSApp` sends, so they create `NSApp` and send it the key events a press would. Creating a window needs a window server session, which a logged-in Mac and CI's macOS runners have.

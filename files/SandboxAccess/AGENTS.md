# files/SandboxAccess

A sandboxed mac app's folder grants. It keeps every folder the user opens, drops, or adds as an app-scoped security bookmark, starts their scopes again at launch, and answers whether a directory is readable before anything touches the disk. It depends only on `core/Common`, for the path spelling and the log and main-thread macros. It came from Vibe. **It is macOS only.** Its files sit in its `Mac/` half. None reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `FolderAccessManager.{h,m}` | the bookmark store: the launch restore, the waits for a grant, the auto-add, removal, and the read test |
| `FolderAccessManager+GrantPanel.{h,m}` | the one panel that asks for a grant: the folder a playlist file's entries live in |
| `FolderAccessRules.h` | the two path-coverage rules, header-only |
| `FolderAccessManagerInternal.h` | the tests' seams: the resolve, the deadline, and the merge |

## How an app uses it

- **An app makes one store at launch and keeps it** (`initWithDefaults:key:entitledFolders:`). The store reads its grants from that key in those defaults, and writes every change back there. There is no shared instance.
- **The app calls `restoreGrantedAccessWithCompletion:` once at launch**, before any open that may need a remembered grant. The completion runs on main once every scope has started, or at the deadline.
- **Each open waits for the grants that cover it** (`awaitRestoredAccessForURLs:completion:`), then calls `noteOpenedURLs:` with what it opened. That call bookmarks only directories outside an active grant and outside the entitled folders. The caller must hold access to each URL now, from a drag, a panel, or Launch Services. A URL with no access is skipped.
- **Background work asks `canReadInsideDirectory:` first**, from any thread. An unsanctioned read of a protected folder raises a system consent panel. A NO can be stale by one grant, so the change notification is the signal to ask again.
- **A list of grants reads `grantedFolders`**, a snapshot with a state per row, and removes rows with `removeFoldersAtIndexes:`.
- **A list that offers to add a folder asks `coversFolder:`** whether the folder is already granted, on main. An entitled folder counts, and so does a row that is not Unavailable. A restoring row counts, so the list offers no duplicate at launch. An unavailable row does not, since it is the folder worth offering again. It is case-sensitive, as the auto-add's duplicate check is.
- **The app names the folders its entitlements grant**, none by default. The store treats each as granted without a bookmark, in the read test, the auto-add, and `coversFolder:`. None is a row of `grantedFolders`. The piece cannot know an app's entitlements. A store that assumed ~/Music would tell an app without the music entitlement that ~/Music is readable when it is not. Vibe holds the music read-write entitlement, so it passes ~/Music.

## The store

**A row's state costs no I/O to know.** `grantedFolders` answers a `VibeGrantedFolderState` per row (`Active`, `Restoring`, or `Unavailable`) from the resolve the store already did. **Never stat a row to decide it.** A list asks per row on main, and a dead mount can block a stat for an automounter timeout.

**TRAP: launch resolution never mounts a volume or shows UI** (`NSURLBookmarkResolutionWithoutMounting | WithoutUI`). Nobody asked for it. A grant on a server that is not mounted fails at once. It stays Unavailable until a launch finds the volume mounted. Without the flags the resolver tries the mount itself. That can raise a connect dialog at every launch and pin a restore lane for the automounter timeout.

**TRAP: an unresolved stored bookmark is not authority.** A stored row is visible at once but authorizes nothing until restoration has started its security scope. Background work must never probe a directory without an *active* grant, because unasked-for work must never raise a permission panel. `FolderAccessManagerDidChangeNotification` says a scope has settled.

**A failed restore keeps its row.** An unplugged drive is indistinguishable from a deleted folder here. The row stays Unavailable and resolves again at a launch that finds it.

**TRAP: inside the sandbox, `NSHomeDirectory` and `NSHomeDirectoryForUser` both answer the container.** An entitled ~/Music spelled from them names a folder no music sits under. `+realHomeDirectory` uses `getpwuid`, the documented way to the on-disk home. An app spells an entitled folder under the home from it.

**TRAP: coverage has two spellings, and the callers need different ones** (`FolderAccessRules.h`). `path:isCoveredByAnyOf:` is case-**sensitive**. It is the auto-add's duplicate check over canonical spellings, and `coversFolder:` asks it too. A loose match on a case-sensitive volume would skip a bookmark it needs. `readablePath:isCoveredByAnyOf:` is case-**insensitive**. It is the read test, and the same folding decides whether an open must wait for a grant. Those paths come straight off Launch Services, a pasteboard, or a track's URL. Under-matching them would walk a folder before its grant is restored, or refuse a readable one. Both sides of either test drop the alias spellings first: `/private/tmp` and `/tmp`, and the Data volume's firmlinks.

**Every wait for a grant has a two-second deadline**, the launch restore's and each open's alike. Waiting is an optimization. Going on without the grant only risks an unreadable folder, which every open path must handle. Waiting forever on a mount that never answers would hold an open for good.

**Restoration runs three utility workers plus one user-initiated lane for a grant an open is waiting on** (`VibeFolderAccessRestoreConcurrencyLimit`). So a relevant grant never sits behind unrelated blocked restores. When remembered grants nest, the most specific one that covers the open takes that lane. If it fails, the next covering one does. Once an active grant covers each requested URL, a parent still resolving no longer holds the open. **TRAP: promotion cancels and re-enqueues a queued restore, and the cancel can race its start.** A claim on each restoration keeps the two lanes from resolving it twice.

**A removed or reopened row leaves the reserved lane, but its resolve still runs once.** It balances the launch restore's group, and a scope it started must be released. A reopened row reuses its inactive stored entry rather than adding a duplicate. An active one is never overwritten, since that would leak its sandbox extension for the process's life.

**Restoration posts its change notification coalesced to one per run-loop turn**, because it settles one bookmark at a time and an observer may do real work. A user's add and remove post directly, so a list redraws in the same turn as the click.

## The grant panel

**Asking is separate from storing.** `requestAccessForPlaylistFolder:message:prompt:` is the one path that raises a panel. A playlist file grants that file alone, not the audio it names, so a folder walk asks for the folder its entries live in. The app passes the panel's message and its button's title, localized. The store itself never raises a panel.

**It blocks the calling worker until a human answers. Never call it on main: it deadlocks.** The worker waits for main to run the panel. Main never waits on the worker. **Powerbox prompts must not stack, so it serializes on its own gate**, without locking the store that main may need. A granted folder is noted at once, since its extension lasts only this process.

## Tests

`Tests/files/SandboxAccess/Mac/` covers the path rules, the read test's case folding, the alias spellings, an entitled folder and the on-disk home, `coversFolder:` over an entitled folder, a restoring row, and an unavailable one, a stored bookmark that authorizes nothing, a failed restore, and the restore scheduler: the bounded workers, the promoted lane, nested grants, removal racing promotion, duplicate bookmarks, and a reactivated alias. The scheduler tests override the resolve through the internal header, so they need no real bookmark. Each test stores its grants in a defaults suite of its own and removes it. The panel needs a human, so no test reaches it.

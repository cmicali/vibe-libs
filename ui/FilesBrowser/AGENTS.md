# ui/FilesBrowser

A browser of the folders a user granted an iOS app and the app's own sources, such as its Documents or a cloud mirror. **It is iOS only.** It depends on `ui/Rows` for its rows, `ui/Controls` for the playing row's equalizer, `media/Metadata` for album art, `media/FolderScan` for a folder's listing, `media/Playlists` for a playlist file's tile, and `files/FileLoading` to tell a placeholder from a local file. None of it reads an app's settings, strings, or model. The app hands in a host, an object that adopts `VibeBrowserHost`, and configures the Locations store at launch.

| File | Owns |
| --- | --- |
| `VibeBrowserHost.h` | the host protocol, the action and root-row values, the source protocol, the folder source, the observer events, the stack's art cache, and an alert with the host's OK |
| `VibeBrowserRootViewController` | the root: Locations (the host's sources, then the granted folders), the host's rows below them, the plus, the location picker, and the walk to a folder (`showDirectory:highlighting:`) |
| `VibeBrowserFolderViewController` | one folder: its listing, filter, bar, Select, sort, subfolder walk, equalizer, and row actions. `+Art` holds the album art and `+Actions` the bar, Select, a tap, a swipe, and a long press |
| `VibeBrowserArtHolder` | the holder a row's art loads into when the host has none |
| `BrowserRules.h` | a Locations row's folder, which root covers a path, a folder's empty state, and a row's tile. Header only and Foundation only |
| `VibeLocationStore` | the granted folders, as persisted bookmarks whose scopes are held for the session, and the one name each folder is shown under |

## How an app uses it

List `VibeLibsFilesBrowser` in an iOS target.

**At launch, configure the store once**, before it is first used: `configureWithBookmarksKey:suppressionsKey:rootNamer:`. The keys name where the grants live in the standard defaults. The namer names the roots the store cannot name itself, such as Documents as "On My iPhone". It must never touch the disk. Then call `restorePersistedFolders`. An app that opens files from a location holds its scope with `grantCoveringURL:` for as long as it reads them.

**Make a host per stack of screens, and a root over it** (`initWithHost:`). The host supplies:

- **The actions, as values** (`VibeBrowserAction`: a title, a glyph, and a handler that gets the rows' URLs and the screen). A file's tap, the selection's action (Select's bar button and the swipe), the bar button, the subfolder walk's handler, and each row's long press. One app offers Play and Add to Playlist. Another offers Import. A bar button shows the action's glyph, or its title as text when the action sets `showsTitle`. The walk's handler is told the folder the walk started from, so an app can name what it makes after that folder.
- **The words** (`VibeBrowserLabel` and two counted strings), the sheet's look (a prompt over each folder, and optionally one over the root (`rootPrompt`), Close at every level, and whether the sort menu shows), and the one folder sort.
- **The sources** listed before the granted folders (`VibeBrowserSource`). A source that lists from elsewhere refreshes a folder before it is read, and can give its own words for a failed refresh. A source that signs in offers its connect item in the plus.
- **Optionally, its rows below Locations** (`rootSections`), as `VibeBrowserRootRow` values whose handler gets the root. No app subclasses the root.
- **Optionally, playback** (`VibeBrowserPlaybackHost`): the playing file's row carries the equalizer, and the row being opened spins. A host that plays nothing leaves it out.
- **Optionally, an art holder per file.** Without one, a row's art loads into a `VibeBrowserArtHolder`. The browser makes the stack's metadata cache itself (`VibeBrowserArtCache`), so a host gets art with no code.

A host whose playback, sources, or rows change takes the screens as observers (`addBrowserObserver:`). The name avoids `NSObject`'s `addObserver:`.

## TRAPs

- **TRAP: nothing in a folder screen's initializer may touch the disk.** A screen is made on main as a folder opens, and for a provider's folder a stat or name lookup is IPC that can block. A source's `refreshesDirectoryURL:` is asked there, so it must not touch the disk either.
- **TRAP: a placeholder and a provider's dataless file are never parsed for art.** They go to the cache's `loadCachedMetadata:`, which never parses on a miss. A parse would download the file just to browse it.
- **TRAP: the filter field is always shown, never hidden on scroll.** A collapsing search bar re-lays the bar out on appearance callbacks an app may forward by hand, and the folder jumps.
- **TRAP: a row swipe sets `isEditing` too.** Only Select's is multi-select.
- **TRAP: the root's rows read the sources as of its last reload, never the live ones.** An account flips off main before its change is posted. A live read in that gap opens or deletes the folder beside the one shown.
- **TRAP: an action row takes the dynamic tint color**, never `self.view.tintColor`'s value, which is gray while a sheet dims the tint.

Each trap is written beside its code too, and that comment is the authority.

The store's rules are in `VibeLocationStore`'s header and code.

## Known shape, kept on purpose

- A source does not announce its own changes. The host relays them as two observer events, and the files event names no source, so every refreshing screen on screen relists.
- A granted folder is not a source. It is a second kind of Locations row, with its own index rule, its own Remove Location, and its own notification.
- The store is one shared instance, which the app configures once at launch. An app cannot hold a second store, as `files/SandboxAccess`' app can.

Each may change once an app needs it to.

## Later work

- **A default whole-file holder in `media/Metadata`.** `VibeBrowserArtHolder` would move beside `AudioTrackMetadataHolder`, and the two test holders that nearly copy it, `ConsumerTrack` and `VibeLoaderTestTrack`, would share it.
- **The store as a piece of its own: proposed, not started.** `VibeLocationStore` and the coverage rules are Foundation only, and an app's session and search use them without the browser. A cross-platform `files/Locations` piece on `core/Common` alone would hold them. It would cost one pull request here and one in each app: the store's three files and the rules move with `git mv`, the rules leave `BrowserRules.h` for a header of their own, the piece takes its template, targets, map row, and `AGENTS.md`, and Vibe's `LocationStoreTests` and the coverage half of its `BrowserRulesTests` move here with their history. Its macOS tests would be the store's first run on macOS. It waits because every app that uses the store also shows the browser, so the split saves no one a dependency yet. It is worth doing when an app needs the grants without the browser, or on macOS.
- **Comments that still describe Vibe's screens**, such as the Files tab, the Playlist tab's add sheet, and `FolderSession`.

## Tests

These screens need a hosted app and a window, so their tests run in the consuming app's simulator suite, as `ui/Rows`' do. Vibe's are its `FolderScreenHostTests`, whose host is not Vibe's, and its `LocationStoreTests` and `BrowserRulesTests` in its macOS suite. `FolderScreenHostTests` covers a bar button's title, the walk's start folder, and the root's prompt, and `LocationStoreTests` covers `grantCoveringURL:`. Here, `FilesBrowser-iOS` only builds the piece, so this repo's checks don't prove its behavior. Run Vibe's `make test-ios` and `make test` against the change before it merges.

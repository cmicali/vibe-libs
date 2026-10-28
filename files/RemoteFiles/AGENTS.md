# files/RemoteFiles

Files on a server kept as local placeholders under one root, so everything that plays, tags, waveforms, and caches a file works on them unchanged. Playing one downloads it, and the file is readable while it streams. Tags are read by range. Past a download budget the oldest downloads go back to placeholders. It came from Vibe. It depends on `core/Common`, `files/FileLoading` for the placeholder rule, the remote backend, and the availability it publishes, `files/HTTP` for the client, and `audio/Decode` for the tail window's math. It is Foundation only, and no file needs a platform half. It reads no app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `RemotePlaceholderStore` | the placeholder and the install, the directory index, the fetch that streams, the ranged read, the download budget, and the backend it installs |
| `RemotePlaceholderStoreInternal.h` | the hooks a subclass overrides, and what a subclass and the tests reach: the disk queue, the index, the downloads, and the budget |

**What an app gives it.** A subclass that says which remote file a placeholder stands for (the hooks, below). A client, any `HTTPTransferClient`. A root, an index xattr's name, and a budget. A store is used through a subclass: an app's store of a web API's files, or its store of links. **TRAP: an app that also takes `VibeLibsTaglib` lists this template first**, as it would `VibeLibsDecode`, which this one lists (the template's comment).

## The placeholder store

**A placeholder is a sparse file of the remote size and mtime with no permissions** (`writePlaceholderAtURL:…`, `PlaceholderFiles`' remote placeholder). Its stat is the real one, and a direct open fails rather than reading zeros. It is written whole and renamed into place. Downloaded bytes are renamed into place too (`installPart:…`). No reader ever sees either half made. **The install's mtime keeps the cache key.** The key is size, mtime, and path (`NSURL+Hash`), so cached tags and waveforms match the downloaded file. The default mtime is the placeholder's. A subclass may take its API's own date instead.

**The store makes its root once and keeps it out of backups** (`prepareRoot`). It is a cache of what the server holds. `containsURL:` says whether a file lies under the root, from its path alone.

**Each directory carries an index in an xattr**, named at init. It is on the directory, because a placeholder's attributes are as unreadable as its bytes. Its contents are the subclass's. The store caches parsed indexes in memory, since a ranged read asks for one per block, and rewrites one only when it changed. A removed directory takes its cached index with it (`forgetCachedIndexes`).

**The hooks say which remote file a placeholder stands for and how to read its answers** (`RemotePlaceholderStoreInternal.h`). `remoteTargetForURL:error:` is the target the client fetches. The download goes through `downloadTarget:…`. The ranged read goes through `readTarget:…`, which calls the client by default. An answer's version is always the client's `versionOfMetadata:`. `readsByRangeAtURL:` NO means no tail read. A ranged read then answers only from a live stream that holds the whole range. Any other fails with `ENOTSUP` and sends no request. The tags come once the file is local. `budgetRootURL` is where the budget counts. `downloadsUnder:` is what it counts. `downloadsDidChangeWithTotal:` is told each new total.

**The fetch streams into a hidden part file** (`PlaceholderFiles remotePlaceholderPartURL:`). The part file's own rules are the client's (`files/HTTP/AGENTS.md`). The fetch publishes it while it writes it (`availabilityForURL:`, the streaming lookup, `files/FileLoading/AGENTS.md`): a `CloudFileAvailability` per transfer, keyed by the file's comparable path. It is made at the first accepted response, with that response's size. That is the version being downloaded, which may differ from the placeholder's. It is kept across every resend. A response naming no size streams nothing and downloads whole. The fetch's `onReadable` fires once, past 256 KB of head and short of the size. A file that completes first never fires it.

**A stream reads its tail once, beside the download.** The window is sized by `VibeAudioFileTailWindowBytes`, from what each format's open reads (`audio/Decode/TailWindowMath.h`). It is a ranged read on the call session, of the same target, at the same moment. It lands about when the head does. It is installed as the availability's tail window, from which the handle reads past the download's edge. Readable does not wait for it. A failed tail read logs one line and leaves the window absent. Reads there wait for the download. The finish cancels a tail read still running.

**TRAP: a read of the target answers whatever version is current.** The window is therefore installed only by whichever answer lands second. It is installed only when the ranged answer names the download's version, and the download's size is the placeholder's its offset came from. A version missing on either side drops it (`installTail:…`). Installed unchecked, another version's tail would decode as this one's.

**TRAP: finished after the install, forgotten after the finish.** A reader whose part open missed the rename waits for the finish, then opens the URL. A failure's part is deleted or kept by the client. Either way that same wait turns into the failure, never a missing file or a short read.

**The fetch's cancel keeps the part.** FileLoading's coordinator cancels when nothing reads the stream any more. A stall's replay then continues the download where it stopped.

**Tags are read by range, never by download** (`readPlaceholderAtURL:…`, installed as the read `CloudFileMaterializer`'s `remoteReadForURL:` answers). **A file streaming now is read from its stream first** (`streamedBytesOfURL:…`). A range in its first MB or its tail window waits up to 3 s for the stream to hold it. Any other range takes the part file's prefix below the bytes noted. The server is asked only for the rest. A read past 30 s is given up, and the parse fails, to be retried by a later scan.

**Past the download budget the oldest downloads go back to placeholders**, oldest first by download time, never the file just fetched. Size and mtime are kept, so the cache key still matches when the file comes back. A smaller budget applies at once. `removeDownloadsWithCompletion:` does the same to every download. A player still reading an evicted file keeps its open descriptor. **The default counts every regular file under the budget's root that is no placeholder.** A subclass that keeps a file whole, such as a playlist it downloads to read, drops it from `downloadsUnder:`, so the budget never evicts it.

**`installAsRemoteBackend` registers the store for its root** (`CloudFileMaterializer setRemoteRoot:…`): the fetch, the ranged read, and the streaming lookup. An app calls it at launch, before anything opens a file under the root. Each root has its own backend, and FileLoading sends each placeholder to the backend of the longest root holding it. **TRAP: a store with no root installs nothing.** Application Support can fail to resolve. A nil root would remove every backend, another store's too, once a release build compiles out `setRemoteRoot:`'s assert.

The disk queue is named `vibe-libs.remotefiles.<log name>-store`.

## Tests

`Tests/files/RemoteFiles/` holds the store's tests, over a test subclass, a temporary root, and `HTTPStub`. The stub is HTTP's, in `Tests/files/HTTP/`. The test bundle compiles it from there and searches that directory for its header. The stub serves through `files/HTTP`'s fake, which the piece's template already lists. The tests install the store as FileLoading's remote backend and read through `CloudFileMaterializer`, as an app's open does. The subclass keeps a CUE sheet whole through `downloadsUnder:`. **The tail read's Range is checked against `TailWindowMath.h`**, for a small window and two chunked ones. Decode's streaming tests open on that same window, so together they check that the store fetches what the opens read.

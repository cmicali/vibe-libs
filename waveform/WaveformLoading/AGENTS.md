# waveform/WaveformLoading

A file decoded into a waveform summary, with observers on the same pass, cached on disk and shared between requests. It holds `AudioWaveformLoader`, `AudioWaveformCache`, and `AudioWaveformObserver`, with their two seams. It came from Vibe's `Audio/Waveform`. It depends on `core/Common`, `waveform/Waveform` for the summary and its cache entry, `audio/AudioTypes` for the playable item and the CUE window math, `audio/Decode` for the file handle, `files/FileLoading` for a file's materialization, and `files/DiskCache` for the store, `VibeCacheStore`, and for the names of the PINCache store it imports. PINCache itself is gone. It reads no app's settings, strings, or types. A request names its file through `VibePlayableItem`, and every delivery hands that item back.

Decoding without caching has no second user, so the two are one piece. The summary itself, its reads, and the entry's format are `waveform/Waveform/AGENTS.md`'s. What an app's analyzers compute is the app's. An app may bind `audio/Analysis`' tempo and key as its observers.

| File | Owns |
| --- | --- |
| `AudioWaveformLoader` | one decode of one file or window: the open, the pipelined pass, the observers' sinks, the progressive snapshots, the completeness rule, and deep zoom's block reads |
| `AudioWaveformLoaderInternal.h` | the pass's phases, declared so the tests can reach them one at a time |
| `AudioWaveformCache` | the loaders' lifecycle: the claims, the lanes, the detached decodes, the scans, the store, the version check, and the deliveries on main |
| `AudioWaveformCacheInternal.h` | the state, the entry key, and the lookup-or-decode path the cache's seam shares |
| `VibeWaveformStore` | the entries: a `VibeCacheStore` that lists each waveform's file, one per folder in a process, and the import of the PINCache store before it |
| `AudioWaveformObserver` | what rides the decode beside the summary: an identifier and a block that makes one sink per decode |
| `AudioWaveformCache+Debug` | the cache's seam: the decode pace, per-track cache control, and the scans' pauses and line |
| `AudioWaveformLoader+Debug` | the loader's seam: each pass's phase timings |

## How an app uses it

List `VibeLibsWaveformLoading`. It lists the templates it needs. **TRAP: an app that also takes `VibeLibsTaglib` lists this template first**, as it would `VibeLibsDecode`, which this one lists. The sources are Objective-C++, and the summary is C++17 (`waveform/Waveform/AGENTS.md`). `AudioWaveformCache.h` and `AudioWaveformLoader.h` forward-declare `CodableAudioWaveform` rather than import `AudioWaveform.h`, so a view that holds a cache compiles as plain Objective-C.

```objc
AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];  // or init, the user's caches
cache.delegate = self;
cache.analysisProvider = ^VibeWaveformAnalysis {
    return (VibeWaveformAnalysis){.bands = NO, .observers = @[tempo]};
};
[cache loadWaveformForTrack:item];  // main thread; deliveries arrive on main with the same item
```

## What rides the pass is an input, not a setting this layer reads

`AudioWaveformLoader` takes a `VibeWaveformAnalysis` value: the bands, and the observers the request lists. `AudioWaveformCache` holds the `VibeWaveformAnalysisProvider` block and asks it **once per request, on main**. The cache lookup and the decode then agree on what the request wants, and a provider reading main-confined settings is never called off main. The cache's owner installs it. An unset provider runs none of it, which is what the tests get.

**An observer is what rides the decode beside the summary** (`AudioWaveformObserver.h`). It has a stable identifier, which names its result in the archive. When a decode starts, the loader asks each listed observer for a sink, given the file's rate and the window's frames. The sink takes each mono block in stream order. When a complete decode finishes, each sink gives one result, filed beside the summary under its identifier. A result is any property-list object, so a beat grid or a loudness curve fits as well as a number. A result that is not one is a sink's bug: it asserts in Debug, and Release drops it with a warning. The loader and the cache never learn what an observer computes. **An app versions an observer by changing its identifier.** A changed algorithm then leaves old results uncovered, and the archive needs no bump.

## The decode pass

The decoder and optional analysis both contribute to the pass cost. The loader **pipelines decoding and processing**: block N+1 decodes while block N runs through the mono mix, the sinks and the summary on a serial queue one block behind. Two buffers ping-pong, gated by per-slot semaphores. The serial queue keeps the stream order a sink's framing depends on, so the output is exact. All processing-side state, the progress throttle included, lives on that queue and is read only after the final drain.

**A local file's first progressive snapshot waits the same 0.1 s of decoding as every later one.** The interval is wall time, which is safe only because a snapshot costs about what main's did. An immediate one would show only a sliver of the track. Completion bypasses the throttle. A file whose reads wait for bytes (`waitsForBytes`: a stream, or a network mount's read-ahead) keeps the immediate first snapshot, since its next read can stall.

## The three bands are decoded only when asked for

Only a style that draws the bands reads them. So **a decode splits them only when its request asks** (`VibeWaveformAnalysis.bands`). The split runs every sample through both crossovers. The summary's builder filters each bin's slice of the mono stream into low, mid and high (`waveform/Waveform`'s `BandSplit`). **One split per decode, on the serial queue**, since its filters carry state across slices.

## The store

`CodableAudioWaveform` is the entry the cache files (`waveform/Waveform/AGENTS.md`). **Only a complete summary is filed.** The entry's bytes are its keyed archive, as PINCache wrote them, so the import lists the old files as they are. A 4:40 track takes about 250 KB, a 33-s loop about 30 KB, and an hour-long mix about 3 MB.

**A hit decodes nothing.** The filed results come back with the summary and are delivered as a decode's are. **An entry without the bands is a miss only for a request that wants them.** Likewise an entry without a result under an observer's identifier is a miss for a request that lists that observer. That decode replaces the entry, so nothing is ever invalidated for what it lacks. **A request joins a decode in flight for the same window only if that decode carries the bands and every observer it lists.** Otherwise it cancels that decode, waits on its claim and starts its own. **An owner that comes to want more asks for its track again**, since the entry on disk may lack what it now wants.

**`loadWaveformForTrack:filed:` says when the entry is on disk.** The final delivery comes before the write, so the UI never queues behind the store. A flag on that delivery could only say "not yet". So the signal is a waiter on the request. It rides the request's claim and runs once, on main, when the claim settles. That is after the write, or once the decode will file nothing. YES means a cache-only lookup from then on hits. A request that joins a decode in flight waits on that decode. A retry the claim starts takes over its waiters. **Only `settleClaim:` ends a claim, and it runs every waiter or hands them all to the retry.** Every way a load ends reaches it: a cancel, a detach, an eviction from the detached pool, a replacement load, a version mismatch, and an admission failure. So each waiter answers once, NO when nothing was filed. An invalidation ends no claim. It only keeps a decode in flight from filing. Only a worker wedged in a stat or an open holds a waiter, until it returns. The seam needed nothing new. It answers through the same settlement, so the lookup-or-decode path has no switch for when to answer. No type was added, since the claim already carries each request.

**A tag-only rewrite moves the entry** (`moveEntriesToNewKeys:completion:`). A tag edit's safe write swaps a rewritten copy in for the file. Its size and date change, and so its key, but its audio frames do not, so its summary and its observers' results still hold. The app takes each file's `cacheKey` before the write and after it, and passes the pairs in one call, so nothing decodes them again. Each move changes one row's key (`VibeCacheStore`'s `moveEntryFromKey:toKey:`), in one transaction, so no entry is lost to a crash, and no file is read, written, or renamed. A cue row's entry is its window's, so the app passes each window's pair too, spelled by `VibeKeyByAppendingCueWindow`. **A window the app leaves out stays under its old key, and decodes again on its next play.** An entry the new key already holds is kept, since `VibeWaveformStore` checks for it first, and the old one goes. During the import, an entry still in the old store moves by its rename into the new store, under the new key. An absent entry is no work. The moves run on a queue of their own, so the store's hop on `_loaderQueue` stays short. Each is checked against the generation, through the same `fileUnderKey:` the decode files with, so a move cannot repopulate an emptied store.

**TRAP: the verb retires no memoized key.** `NSURL invalidateMemoizedCacheKeys` is process-wide, so the app calls it once per batch: after its writes, and after every cache's moves have landed, from the last completion. Two windows can still decode. Until the moves land, a load that stats the file misses under its new key. Until the retirement, a row that memoized its old key misses under it. A load after the retirement hits. A decode of the old version that runs across the move files nothing: at its end its key has changed, and it decodes once more under the new key.

## The store's list

**Each waveform is a file, and the store's rows list it** (CH14): its key, its size, its format, and its last use, in `VibeCacheStore`'s database under `audio_waveforms`. A waveform of 215 KB is over the store's inline limit, so it goes to a file. A short loop's, under 64 KiB, stays in its row. A count, a trim, and the age limit read rows, never the folder. So `diskUsageWithCompletion:` reads one row, and the open counts nothing.

**The format is on the row** (CH15). A hit asks for `kCodableAudioWaveformVersion` alone, so an entry of an older or a newer format is a miss, read with no unarchiving. The decode that follows replaces it. So the store's name never changes with a format, and a bump removes no entry until a decode replaces it or the limits take it. **The results stay versioned by their observer's identifier** (CH18), inside the entry, as before.

**One store per folder in a process.** `VibeCacheStore` opens a folder once (CH21), so `VibeWaveformStore` keeps one for each root, shared by every cache under it, and closes it when the last one lets go. An open under a root whose store is closing waits until it has closed. Any other open that fails tries three times more, 10 ms apart, then the cache keeps no waveforms.

**An invalidation** removes the old store, if the import still runs, and remakes the database, then runs the completion on `_loaderQueue`, as before. The generation check still keeps a decode in flight, or a move, from filing into the emptied store.

## The import (CH19)

**The first open brings the old store's entries over, then removes it.** The old store is PINCache's `com.pinterest.PINDiskCache.audio_waveform_cache_v7`. In the background, each of its files is listed by `adoptFileAtPath:forKey:format:lastUse:`: a rename into the store's `Files/`, dated by its last use as PINDiskCache recorded it, the file's date. A file under the inline limit is read into its row. A key the new store already holds keeps its entry. First, the PINCache stores of older formats go, through `removeOtherAudioCacheVersionsKeeping:`, since an app's own call no longer names them: `audio_waveforms` is of another family. At its end, the old folder moves into the store's directory, and `removeFolderAtPath:` removes it in the background. A quit before then leaves it there, and the store's next open removes it.

**A miss during the import looks in the old store before it decodes.** It lists the old file first, then reads it from the store, so a lookup and the import never both list one file. A debug seam's clear and a move reach the old store too.

**A quit cuts the import short, and the next open carries on** from the files still in the old folder. A file renamed but not yet in a committed row is on the store's pending list, so the next open removes it: that entry decodes again. Nothing else is lost.

**TRAP: during the import, the usage counts only the entries brought over.** A Settings pane that reads it in the first seconds after an update sees a smaller cache.

**Measured** on 2026-11-19 on an M4 Max, at a load of 4 to 8, with a tool of the session's beside PINCache's store as this piece kept it, both built with `-O2`, six runs each. The tool needed PINCache, so it went with it, and these numbers are its record. Each store held 4,700 entries of one real 4:40 waveform's archive, 180 KB, 848 MB in all, as a full store holds at 1 GiB. A hit unarchives the entry and decodes its summary, as `waveformInStore:` does.

| Measure | PINCache | The SQLite store | The bar |
| --- | --- | --- | --- |
| A hit, decoded | 227 to 228 µs median, p99 243 to 248 µs | 229 to 231 µs median, p99 269 to 272 µs | no slower: missed by about 1% |
| A miss | 4 to 5 µs median | 2 µs median | no slower |
| The usage count | 52 to 58 ms | 0.25 to 0.30 ms | under 50 ms |
| A write 50 ms after an open, first then later | 1.1 to 1.7 ms, then 0.3 ms | 0.4 to 0.5 ms, then 0.15 ms | under 1 ms |
| The open, on the loader queue | 0.6 to 0.8 ms, with no count | 2.0 to 2.5 ms | none at launch |
| The import of 4,700 entries | | 3.8 s in the background, by rename | |

The hit's 2 µs are the row's lookup. The first runs, with the files not yet in the system's cache, were 234 to 244 µs for both.

## A cue row's waveform is its window

The loader decodes only the item's window (`cueStart`/`cueEnd` through `VibeCueWindow`), and the observers' sinks see only its frames. A DJ mix gets a waveform, a tempo and a key per track. Everything keyed per file is keyed per window here. The claim (the standardized path), the detached-loader pool and the disk entry all append the window through `VibeKeyByAppendingCueWindow` (`VibePlayableItem.h`). The disk entry's key is `VibeWaveformEntryKey` (`AudioWaveformCacheInternal.h`), the one home of that rule. The shared lookup-or-decode path sets the decode's window from the same item.

## A decode never downloads

**The loader decodes with its thread unable to materialize** (`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`), for a summary and for deep zoom's reads alike. A play downloads its file before the decode is asked for. A file the provider freed since then fails to open or read, rather than downloads again, and the decode delivers a failure. A transfer's part file is local, so a stream still decodes. **TRAP: the policy is the thread's, and is restored after the load**, since the scheduler's thread runs other work next.

## Admission

Cache-key stats, cache lookups, opens and decodes pass through **fixed-slot utility `AudioWorkScheduler`s** (`core/Common`). `stat` and the open can block for minutes on a cloud placeholder and have no cancellation point, so fixed slots are the resource bound. A stat keeps its slot through its disk read. An app's playback opens never pass through these schedulers, so background analysis cannot starve the open the user is waiting on.

**Lookups and decodes use separate lanes.** The lookup lane runs two, the decode lane `kMaxDetachedWaveformLoads + 1` = three. A decode is submitted from *inside* a lookup that still holds its slot. Sharing one scheduler would let a burst of lookups expire the decode they asked for, delivered as that file failing to load. The lookup and decode lanes each hold at most four pending items. A pending request whose lane stays full for ten seconds fails *admission*. A never-returning OS call still owns its slot for the process's life, but retries cannot multiply it.

`cachedWaveformForTrack:completion:` shares entry validation but has its own preview lane: one running, two pending. So a neighbor's uncancellable stat cannot occupy a lookup slot. It starts no open or decode. It answers on main, nil on a miss or admission failure, and rejects a hit invalidated during the read. Its `AudioWorkToken` cancels still-pending work with no completion. It is for previews of items beside the one on screen.

**Deep zoom's reads have a lane of their own** (`loadDetailBlocks:forTrack:waveform:completion:`): one running and one waiting. So a read stuck on a dead mount holds no decode slot, and a zoom cannot starve a decode. Each read opens the file as a decode does and reads the blocks asked for into the waveform's detail (`waveform/Waveform/AGENTS.md`). **A file not on disk is skipped**, a provider's or a remote placeholder, since a zoom must never start a download. Nothing is persisted.

## Scans pause for the open the user waits on

An app that analyzes a whole library asks for each file with `scanWaveformForTrack:completion:`. A scan decodes and files the entry, with its observers' results, as a load does. It delivers no waveform. The results reach the delegate with the scan's own item. Then the completion says whether the entry is on disk. A hit decodes nothing and answers YES. A file that cannot be decoded answers NO, through the completion only.

**Scans run one at a time, in the order asked.** They have a lane of their own at utility priority. The cache holds the line, so an app may ask for many at once. The running scan stays at the head of the line until it completes or is cancelled. A cancelled scan further back is skipped when it reaches the head, so a cancel costs the same however long the line is.

**A scan can ask for its results alone** (`scanResultsForTrack:completion:`). It waits in the same line, pauses the same way, and delivers its results the same way. Its decode files no entry, and splits no bands, since only a waveform shows them. A file whose entry is filed answers from it, with no decode. Its completion says whether the results came, from an entry or a decode. An app that analyzes a library for its tempo and key asks this way, so its store holds the songs the user played, not the last files scanned. `scanWaveformForTrack:completion:` keeps filing, for an app that wants every scanned file's waveform on disk.

**An app keeps a window of scans in flight, say 64, and refills it from each completion.** A waiting token holds its item and its block. **An app skips the files its own index marks analyzed.** A hit still unarchives the entry to answer `filed`.

**The cache observes `materializationCoordinator`**, the shared coordinator unless set. The coordinator publishes each flip of its foreground hold (`files/FileLoading/AGENTS.md`). While the hold is up, no scan starts.

**On the rise, the running scan's decode pauses.** The loader parks before its next read. A read waiting for bytes is interrupted, and the decode parks then. The builder, the sinks, and the handle stay. Nothing is filed while it waits. **TRAP: a scan's loader is made with `init`**, so `init` makes the pause's condition. Without it, a paused decode would spin.

**On the fall, it reads on from the frame where it stopped.** A read the pause interrupted is made again from its start, after `allowReads` and a seek, as `audio/Decode/AGENTS.md` requires. The version check at completion covers a file rewritten during the pause.

**A window is decoded once.** A scan of a window a load decodes, for all the scan asks, waits on that load's filed waiter. Then it looks again, and hits. A load of the window a scan decodes turns the scan back. Its retry waits on the load the same way. A scan holds no claim, so no load reattaches its loader, and its pause never touches the track on screen.

**A scan that finished on another version of its file starts again.** It stays at the head of the line.

**A token's `cancel` drops the completion.** A running decode is cancelled outright, and the lane starts the next scan once its worker returns. **A scan wedged in a stat or an open holds the lane until it returns**, as a deep zoom read holds its own.

**An app sets the store's limits** with `setByteLimit:ageLimit:`, which runs on `_loaderQueue` once the store is made. An app that sets nothing keeps `files/DiskCache`'s defaults.

**Every load takes one path** (`lookUpOrDecode:`): the stat on a lookup lane, the disk read on the same worker, then the decode on a decode lane. The track on screen, the seam, and a scan each pass their own lanes. Only a short hop takes the store from `_loaderQueue`, so no disk read waits behind another there.

## A superseded load is detached, not aborted

`cancelLoad` and a new `loadWaveformForTrack:` stop the old load's *deliveries* but let its decode finish and persist. A later request can use the completed decode from disk. Previews only read existing entries and do not start a decode.

Up to `kMaxDetachedWaveformLoads` (2) detached decodes run behind the active one. Beyond that the oldest loader is cancelled. A claim stays registered until its stat, open or decode worker really returns. Re-requesting a file whose detached decode still runs **reattaches** it. Re-requesting one whose loader was cancelled parks one replacement until the old worker settles. Work not yet holding a scheduler slot is removed with its claim at once, so skip storms cannot queue behind wedged workers.

**The claim is unbounded; the wait on it is not.** A worker blocked in an uncancellable stat or open keeps its slot and claim until it returns. After `kWaveformClaimWaitSeconds` (20) the parked request is dropped with an ordinary terminal failure, and the worker settles whenever it returns. A retry starting later would deliver a waveform for a track the user was told has none.

**TRAP: `detachCurrentLoader` must detach even a loader that reads `isComplete`.** `isComplete` is set on the decode thread *before* its final delivery reaches main, and the detach flag is what `deliverCompleteWaveform` checks. Skipped, that delivery lands as a live one on the track that superseded it. The flag is checked **on delivery, not at enqueue**, so a reattach landing first turns it live again. Detached and cancelled loaders build no progressive snapshots. A reattached loader resumes them.

## A file still downloading rides the play's stream

**The loader opens a streaming file like any other** (`AudioFileHandle` finds the transfer's `CloudFileAvailability`). Its decode fills in as the bytes arrive and completes only once the last byte has. The entry is filed under the placeholder's size and mtime, which the install keeps. A download that installed another version re-keys every item (`files/FileLoading/AGENTS.md`).

**TRAP: a decode's version is checked at its completion, never at its start.** The key is taken before the open, so a decode can read another version than its key names. At completion the cache reads the item's `cacheKey` again, off main, and compares it with the key the decode was looked up under. The re-key has retired the memo by then. On a mismatch the result is neither filed nor delivered, waveform or results, since its bytes may be either version's. A current load decodes once more under the new key, through its claim's retry (`settleClaim:`). The item's key is compared, never a fresh stat, so the retry is keyed as the check is. A fresh stat would see a rewrite the memo hides, and every retry would mismatch again.

**A guessed length is never persisted against.** A streaming MP3 with no VBR header opens on an estimated length (`AudioFileHandle.lengthIsEstimated`, `audio/Decode/AGENTS.md`). The loader decodes on it, but **TRAP:** a pass sized by an estimate is complete only once the length is exact (`decode:`). At its end it waits in `awaitExactLength:`, which `cancel` interrupts. **A bin never depends on the length, so the pass keeps everything it read.** It reads on to the exact length, or it already stopped where the file did. Only a cue window that moved with the exact length starts over. Nothing laid out on an estimate is delivered complete or filed under the file's key. A progress tick stays short of 1, since a receiver reads 1 as completion.

**A waveform never holds a stream: the play's handles do** (`holdStream`, sent only to handles the coordinator serves). When the play lets go (a skip, a stall, a failed open, its track's end), the coordinator cancels the transfer. The decode's next wait then fails as a read error, never complete, never persisted, and delivered as a failure only while current. So a detached streaming decode needs no rule of its own.

**A cancel ends a streaming decode's wait at once** (`cancel`: `interruptReads` on the handle, and the open's `interrupted` block with the file's waiters woken). The cap's eviction frees its slot now. An interruption is not logged. **TRAP: the loader holds that handle only until its load ends** (`load:`). A loader outlives its load, held by its claim and the claim's wait timer. Keeping the handle would also retain its descriptor and read block. **The 20 s claim wait is not a streaming timeout.** A streaming decode has no deadline of its own. The play's stall deadline and the transfer's request timeout bound it, through the cancel.

**A file on a network mount reads ahead for the loader too** (`audio/Decode/AGENTS.md`), on a thread of its own apart from the play's. Only a `cancel` ends its waits. The play's stall lets go of the play's handle, not the loader's. **A read-ahead decode on a dead mount holds its decode slot until it is cancelled**, which the cap's eviction does once newer decodes push it out.

**One decode slot per window for the length of the download.** The claim and reattachment keep a second request off a second slot. Each cue row of a streaming image takes one.

## Every delivery carries the item it was loaded for

`audioWaveform:didLoadData:forTrack:`, `audioWaveformCache:didFailToLoadForTrack:` and `audioWaveformCache:didLoadResults:forTrack:` all carry it, because a delivery can land after the item changed. A receiver matches `sourceKey`, not the URL, since rows of one file share it. A detached decode's waveform reaches no one, but its results are still delivered with its own item. Failure is delivered only while the loader is current, and is made terminal first so a same-window request starts fresh.

Results can also carry the version of the file they hold. A delegate that implements `audioWaveformCache:didLoadResults:forTrack:entryKey:` gets the entry key the results were read or decoded under, in place of the plain delivery. A decode sets it only once its end found the key unchanged, and a hit has the key it was filed under. `CodableAudioWaveform.entryKey` carries it to the delivery, in memory only. A receiver that stores results beside a file's own version compares the two, since the file may change again before its write.

The cache captures the item when the load starts (`_currentLoadTrack`). **The reattach path must set it too**, or a resumed decode delivers under the item it was detached from.

## The seams

Both headers are declaration-only, with no `#if DEBUG`. Each implementation wraps its body in `#if DEBUG`, so a release build ships none of it.

- **`AudioWaveformCache+Debug.h`** paces every decode that starts after it is set (`debugDecodeSeconds`), so a view's progressive fill-in can be watched on any file. The loader reads it in a debug build. It counts each time a rise has told a running scan's decode to pause (`debugScanPausesAsked`), each time a scan's decode parks for the foreground (`debugScanPauses`), and the scans waiting their turn (`debugWaitingScans`). **TRAP:** a rise reaches the decode through the coordinator's observer queue and then the scan queue. On a loaded machine that can take longer than the rest of a short file. So a test that needs the scan still running when the pause lands holds the decode until `debugScanPausesAsked` counts it. It also decodes, dumps, and clears one item's entry through the normal lookup-or-decode path, without touching the current load. The app makes the item. A dump reads the columns it is asked for, or 8,192 for 0: each one's peaks, its loudest window, and each band's. A cue row's entry is its window's, keyed and decoded as a load's is.
- **`AudioWaveformLoader+Debug.h`** is `AudioLoadTiming`: each pass's phase timings, recorded by the loader in a debug build and read afterwards, since a pass has no reply path. The phases are the read, the mix and the summary, each observer's appends and finish, and the whole pass. They can sum past the whole, since the read is pipelined against the rest. The loader's clock reads 0 in Release, so its call sites need no `#if`.

## Tests

`Tests/waveform/WaveformLoading/` holds the tests of the loader and the observers. They write their own WAV files, so none needs an app's generated audio. They run over `Tests/Support`'s `VibeTestTrack`. The re-key test memoizes its key in a track of its own, as an app's row may. They cover the pass's phases and the completeness rule, the progressive snapshots, a streaming file and a network mount's read-ahead, the cancel and the detach, the claims and the lanes, the previews, the filed waiter, deep zoom's reads, the version check, the entry's coverage, the seam's keying of a cue row, a tag-only rewrite's move, with no decode after it for a fresh row or a memoized one, of an absent entry, onto an entry the new key holds, and during a held decode, and, for the observers, a decode, a cache hit, a missing result, a joined decode, a cancellation, a late completion, and a CUE window.

`AudioWaveformStoreTests` covers the store, over an old store that `Tests/Support/LegacyCacheFixtures.h` writes as PINDiskCache filed it: the import of every entry of the old store, byte for byte and with no decode, the removal of the old stores and not another's, a lookup during the import, an import a quit cut short that the next open finishes, and an entry of an older and a newer format, each a miss that a decode replaces. `WaveformWasCached` (`Tests/Support/WaveformLoadingTestSupport`) says whether the seam's load hit, and `VibeWriteNoiseWAV` (`Tests/Support/AudioFileFixtures.h`) writes the noise these tests and the loader's decode. The test seam `holdImportsForTesting:` holds an import before each file.

`AudioWaveformScanTests` covers the scans: what a scan files and delivers, a scan for results alone that files nothing and answers from a filed entry, one at a time in order, a cancel, no start while the foreground is up, a pause within one block on a throttled source, a pause from a stalled read, a pause during the decode's wait for a buffer stopping its next read, the track on screen loading through a pause, a play's download through the fake cloud, and one decode of a window a load and a scan share. The foreground is a coordinator of the test's own, raised by a playback request whose probe waits (`Tests/Support/WaveformLoadingTestSupport`). The pause tests log their latency, and the order test logs the lane's throughput beside bare decodes. The recording observer and the waits the tests share are in that support file too.

**Measuring.** A change that could move cost is measured in Vibe, with its `vibe-perf` skill, before and after: the `waveform` and `chunker` groups. A change that could move a picture is drawn with its `vibe-waveform` skill at both commits, and the pictures are compared with `cmp`.

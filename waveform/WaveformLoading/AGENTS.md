# waveform/WaveformLoading

A file decoded into a waveform summary, with observers on the same pass, cached on disk and shared between requests. It holds `AudioWaveformLoader`, `AudioWaveformCache`, and `AudioWaveformObserver`, with their two seams. It came from Vibe's `Audio/Waveform`. It depends on `core/Common`, `waveform/Waveform` for the summary and its cache entry, `audio/AudioTypes` for the playable item and the CUE window math, `audio/Decode` for the file handle, `files/FileLoading` for a file's materialization, and `files/DiskCache` and `third_party/PINCache` for the store. It reads no app's settings, strings, or types. A request names its file through `VibePlayableItem`, and every delivery hands that item back.

Decoding without caching has no second user, so the two are one piece. The summary itself, its reads, and the entry's format are `waveform/Waveform/AGENTS.md`'s. What an app's analyzers compute is the app's. An app may bind `audio/Analysis`' tempo and key as its observers.

| File | Owns |
| --- | --- |
| `AudioWaveformLoader` | one decode of one file or window: the open, the pipelined pass, the observers' sinks, the progressive snapshots, the completeness rule, and deep zoom's block reads |
| `AudioWaveformLoaderInternal.h` | the pass's phases, declared so the tests can reach them one at a time |
| `AudioWaveformCache` | the loaders' lifecycle: the claims, the lanes, the detached decodes, the store, the version check, and the deliveries on main |
| `AudioWaveformCacheInternal.h` | the state, the entry key, and the lookup-or-decode path the cache's seam shares |
| `AudioWaveformObserver` | what rides the decode beside the summary: an identifier and a block that makes one sink per decode |
| `AudioWaveformCache+Debug` | the cache's seam: the decode pace, and per-track cache control |
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

`CodableAudioWaveform` is the entry the cache files (`waveform/Waveform/AGENTS.md`). **Only a complete summary is filed.** The store's name carries the entry's format, `kCodableAudioWaveformVersion`, so a new format starts an empty store. A 4:40 track takes about 250 KB, a 33-s loop about 30 KB, and an hour-long mix about 3 MB.

**A hit decodes nothing.** The filed results come back with the summary and are delivered as a decode's are. **An entry without the bands is a miss only for a request that wants them.** Likewise an entry without a result under an observer's identifier is a miss for a request that lists that observer. That decode replaces the entry, so nothing is ever invalidated for what it lacks. **A request joins a decode in flight for the same window only if that decode carries the bands and every observer it lists.** Otherwise it cancels that decode, waits on its claim and starts its own. **An owner that comes to want more asks for its track again**, since the entry on disk may lack what it now wants.

**`loadWaveformForTrack:filed:` says when the entry is on disk.** The final delivery comes before the write, so the UI never queues behind PINDiskCache. A flag on that delivery could only say "not yet". So the signal is a waiter on the request. It rides the request's claim and runs once, on main, when the claim settles. That is after the write, or once the decode will file nothing. YES means a cache-only lookup from then on hits. A request that joins a decode in flight waits on that decode. A retry the claim starts takes over its waiters. The seam needed nothing new. It answers through the same settlement, so the lookup-or-decode path has no switch for when to answer. No type was added, since the claim already carries each request.

## A cue row's waveform is its window

The loader decodes only the item's window (`cueStart`/`cueEnd` through `VibeCueWindow`), and the observers' sinks see only its frames. A DJ mix gets a waveform, a tempo and a key per track. Everything keyed per file is keyed per window here. The claim (the standardized path), the detached-loader pool and the disk entry all append the window through `VibeKeyByAppendingCueWindow` (`VibePlayableItem.h`). The disk entry's key is `VibeWaveformEntryKey` (`AudioWaveformCacheInternal.h`), the one home of that rule. The shared lookup-or-decode path sets the decode's window from the same item.

## Admission

Cache-key stats, cache lookups, opens and decodes pass through **fixed-slot utility `AudioWorkScheduler`s** (`core/Common`). `stat` and the open can block for minutes on a cloud placeholder and have no cancellation point, so fixed slots are the resource bound. A stat keeps its slot while it visits the serial cache queue. An app's playback opens never pass through these schedulers, so background analysis cannot starve the open the user is waiting on.

**Lookups and decodes use separate lanes.** The lookup lane runs two, the decode lane `kMaxDetachedWaveformLoads + 1` = three. A decode is submitted from *inside* a lookup that still holds its slot. Sharing one scheduler would let a burst of lookups expire the decode they asked for, delivered as that file failing to load. The lookup and decode lanes each hold at most four pending items. A pending request whose lane stays full for ten seconds fails *admission*. A never-returning OS call still owns its slot for the process's life, but retries cannot multiply it.

`cachedWaveformForTrack:completion:` shares entry validation but has its own preview lane: one running, two pending. So a neighbor's uncancellable stat cannot occupy a lookup slot. It starts no open or decode. It answers on main, nil on a miss or admission failure, and rejects a hit invalidated during the read. Its `AudioWorkToken` cancels still-pending work with no completion. It is for previews of items beside the one on screen.

**Deep zoom's reads have a lane of their own** (`loadDetailBlocks:forTrack:waveform:completion:`): one running and one waiting. So a read stuck on a dead mount holds no decode slot, and a zoom cannot starve a decode. Each read opens the file as a decode does and reads the blocks asked for into the waveform's detail (`waveform/Waveform/AGENTS.md`). **A file not on disk is skipped**, a provider's or a remote placeholder, since a zoom must never start a download. Nothing is persisted.

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

The cache captures the item when the load starts (`_currentLoadTrack`). **The reattach path must set it too**, or a resumed decode delivers under the item it was detached from.

## The seams

Both headers are declaration-only, with no `#if DEBUG`. Each implementation wraps its body in `#if DEBUG`, so a release build ships none of it.

- **`AudioWaveformCache+Debug.h`** paces every decode that starts after it is set (`debugDecodeSeconds`), so a view's progressive fill-in can be watched on any file. The loader reads it in a debug build. It also decodes, dumps, and clears one item's entry through the normal lookup-or-decode path, without touching the current load. The app makes the item. A cue row's entry is its window's, keyed and decoded as a load's is.
- **`AudioWaveformLoader+Debug.h`** is `AudioLoadTiming`: each pass's phase timings, recorded by the loader in a debug build and read afterwards, since a pass has no reply path. The phases are the read, the mix and the summary, each observer's appends and finish, and the whole pass. They can sum past the whole, since the read is pipelined against the rest. The loader's clock reads 0 in Release, so its call sites need no `#if`.

## Tests

`Tests/waveform/WaveformLoading/` holds the tests of the loader and the observers. They write their own WAV files, so none needs an app's generated audio. They run over `Tests/Support`'s `VibeTestTrack`. The re-key test memoizes its key in a track of its own, as an app's row may. They cover the pass's phases and the completeness rule, the progressive snapshots, a streaming file and a network mount's read-ahead, the cancel and the detach, the claims and the lanes, the previews, the filed waiter, deep zoom's reads, the version check, the entry's coverage, the seam's keying of a cue row, and, for the observers, a decode, a cache hit, a missing result, a joined decode, a cancellation, a late completion, and a CUE window. `WaveformLoadingTests` defines `DEBUG` in every configuration, since the tests drive both seams. The minimal consumer writes a WAV of a tone, loads it through the loader, and reads its length and peaks back. It also roots a cache of its own with an observer of its own and loads the tone. Once the load's filed waiter runs, a cache-only lookup hits at once. A second load reads its hit from the cache's seam. A CUE window of the tone then loads through the seam twice, and its second load is a hit too.

**Measuring.** A change that could move cost is measured in Vibe, with its `vibe-perf` skill, before and after: the `waveform` and `chunker` groups. A change that could move a picture is drawn with its `vibe-waveform` skill at both commits, and the pictures are compared with `cmp`.

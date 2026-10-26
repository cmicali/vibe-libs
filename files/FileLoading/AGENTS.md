# files/FileLoading

From a path to bytes an app can read. The file may be local, a cloud placeholder that must download first, a file still downloading, or a file on a slow network share. Every request for one file shares one download and one open. The file the user is waiting on goes first, and background reads step aside. It depends on `core/Common` and on `audio/AudioTypes`, for the extensions whose tags read by range. It came from Vibe. None of it reads an app's settings, strings, or types. It never names the handle it serves. The app's opener makes the handle.

`Claim/` decides which open runs, and when. `Transfer/` moves the bytes and reports how far they have come. `PlaceholderFiles` and the fake cloud sit at the top, because both groups ask them.

| File | Owns |
| --- | --- |
| `PlaceholderFiles` | which files are placeholders: the dataless test and the remote placeholder rule |
| `Claim/AudioFileMaterializationCoordinator` | the claim, stage 1, and the snapshot |
| `Claim/AudioFileMaterializationCoordinator+HandleOpen.m` | stage 2: the handle runs and the six-run ceiling. Its public call, `openURL:…`, is declared in the header's `(HandleOpen)` category |
| `Claim/ServedFileHandle.h` | what stage 2 needs of the handle it serves: `holdStream`. Interrupting is the opener's `interrupted` block. Any object may adopt it |
| `Claim/AudioFileMaterializationCoordinatorInternal.h` | the class extension both files share: the claim, waiter and handle-run records and every ivar. It also holds the test seams and stage 2's cross-file calls |
| `Claim/AudioFileMaterializationTokens` | the request and open tokens. Each delivers its completion at most once, and its cancel detaches it from the coordinator |
| `Claim/AudioLoadingConfiguration` | the immutable limits and the open-timeout seam |
| `Claim/AudioFileOpenDeliveryRules.h` | an open token's one delivery |
| `Claim/AudioFileOpenTimeoutMath.h` | the player's open deadline |
| `Transfer/CloudTransferRegistry` | which files are on the wire |
| `Transfer/DownloadProgressMonitor`, `Transfer/DownloadProgressSourceAdapters`, `Transfer/DownloadProgressRules.h` | how far one transfer has come, for the registry |
| `Transfer/CloudFileMaterializer` | the abortable download of a placeholder, a provider's or a remote one |
| `Transfer/CloudFileAvailability` | how much of a file is readable while a writer fetches it |
| `Transfer/NetworkReadAhead` | the read-ahead of a file on a network mount: its thread, its blocks, its retries, and its orphans. It is a writer of a `CloudFileAvailability` |
| `Transfer/NetworkReadAheadRules.h`, `Transfer/NetworkReadAheadMath.h` | which files read ahead, and how far a play's read-ahead fetches |
| `Transfer/CloudFileMaterializerInternal.h`, `Transfer/CloudTransferRegistryInternal.h`, `Transfer/DownloadProgressMonitorInternal.h`, `Transfer/DownloadProgressSourceAdaptersInternal.h` | what the seams and the tests reach: the materializer's token and cancel, the registry's publication edges and monitor factory, the monitor's two-step start, and the adapters' query and subscriber injection |
| `VibeFakeCloud` and the five `+Debug` seams | the fake file provider and its injection points (The fake cloud, below) |

The player's side of an open, the deadline, progress identity, and prefetch, is in `audio/Player/AGENTS.md`. Vibe's `docs/file-loading-spec.md` states the behavior it observes. Vibe's root `AGENTS.md` keeps three guarantees this piece implements: the foreground open outranks background downloads, the six-run handle ceiling, and a row shows the loading bar only while a transfer is running.

The comments here cite six of that spec's lettered items. In short:

- **A2.** At most one materialization exists per standardized path. Every interested party joins it.
- **B4.** A timed-out open stops with no auto-resume. Its file returns to the metadata sweep at its ordinary rank, and is not chased.
- **C1.** While the coordinator has a foreground claim, metadata-only dataless work yields. A foreground claim is a playback or prefetch waiter, or a readable stream still downloading under a handle it served.
- **C3.** A metadata request for the file playback is downloading joins that materialization.
- **C6.** When the foreground hold rises, a running scan transfer is cancelled, not waited out. The yield spends no retry budget.
- **J8.** A transfer lane ends when its materialization settles, never with the handle open. Handle runs are bounded apart, at six (Admission has two lifetimes, below).

## Placeholder files

**`PlaceholderFiles` answers whether a file is here.** `isDatalessFile:` is the one verdict every background reader asks before it reads.

**TRAP: `isDatalessFile:` is `SF_DATALESS` alone, never an `NSURL` resource value.** NSURL memoizes those per instance, so a placeholder would read "not downloaded" for its item's whole life.

**The one other dataless verdict is the remote placeholder**, and only under a root that a remote backend installs (The remote fetch, below). A regular file its owner may not read (`VibeFileModeIsRemotePlaceholder`) stands for a remote file of its size and mtime. Its stat is real, so listing, sorting, and the disk key treat it as the file. Any direct open fails rather than reading zeros, so a decoder or a tag reader may open without asking. `remotePlaceholderPartURL:` names the hidden sibling its bytes stream into. The path is tested before any stat, so a file under no root pays nothing. Under no root an unreadable file is merely unreadable. `readsRemotePlaceholderByRange:` says a remote placeholder's tags read by range. It asks `audio/AudioTypes`' `PlayableExtensions.tagParsed`.

## One claim, two stages

**A file's journey from dataless placeholder to handle is one path-keyed claim in two stages.** Stage 1 is the one operation that can make a standardized path local. Playback, Prefetch, and the two metadata roles affect admission, never identity. Stage 2 is the purpose-keyed handle runs riding it. There is one current handle waiter per `(purpose, path)`. Playback and prefetch therefore keep independent handles and delivery while they share the path's transfer. Only a stage-1 Ready or readable claim dispatches a handle open. Yielded, AdmissionExhausted, and Failed become terminal outer errors without opening a handle. **The open is the caller's.** Each `openURL:` passes an opener, and a run calls the opener of its latest request. `audio/Player` passes its own, which makes `audio/Decode`'s file handle.

`VibeAudioFileOpenBeginDelivery` and `VibeAudioFileOpenDetachDelivery` (`AudioFileOpenDeliveryRules.h`) are the two sides of the race for the one Waiting transition. Whichever changes it first owns the outcome. `VibeStandardizedAudioOpenPath` (`core/Common`'s `FilePaths.h`) is the one spelling every claim is keyed by. It uses `VibeComparablePath`, with no filesystem I/O. **TRAP: `URLByStandardizingPath` stats a path that starts with `/private` or holds `..`**, so it can stall the player or state queue before the bounded probe begins. Every path an iOS provider hands over starts with `/private`. Compare spelling alone.

**The stage-1 state queue owns in-memory claim state and performs no filesystem or provider I/O.** A first waiter synchronously installs a `Probing` claim. Then one private `AudioWorkScheduler` classifies the path off the queue. Same-path waiters join and share the probe. A fresh answer starts an immediately admitted claim. A dataless claim that had to wait, or was readmitted, reserves its lane and enters `Refreshing`. It re-probes in that admitted worker, and becomes `Running` only when the state queue accepts the fresh answer. The successful paths are `Probing → Running` and `Probing → Pending → Refreshing → Running`. Dataless readmission routes through `Pending` or `Refreshing` the same way.

**A fresh local answer is the run's answer.** An initial probe's settles the claim Ready in the next state turn, with no operation, lane, or worker. A start refresh's settles it from that worker, without running the operation it made. A local verdict carried from an earlier run is not fresh. It runs an operation that probes again, since the file may have been evicted since. Object identity drops a result from a cancelled or replaced probe. A ready operation records the path local before any cancellation or rebind restart decision.

The accepted dataless verdict is reported through `onDataless` at most once per open token. It arrives on the token's completion queue, and only while delivery is still waiting. Joining an already-classified claim reports it too, and so does rebinding a handle run. Rebinding cancels the superseded token, which drops its queued callback.

**A remote transfer is readable before it is complete, and readable is a field of `Running`, not a state.** The operation's `onReadable` comes from a remote backend's fetch. A provider never calls it. **TRAP: it runs on the backend's own delivery queue, which every download shares, and it can race a cancel.** So it never blocks there, and only hops to the state queue. There `claimBecameReadable:` matches the run by generation. It drops a readable whose transfer already finished, which the lookup answers nil for. Otherwise it keeps the run's `CloudFileAvailability`, which marks the claim readable. It serves every playback and prefetch waiter as a Ready would. A handle run's open is dispatched in that same turn, never through its token. The claim stays `Running`, and its metadata waiters wait for complete. A playback or prefetch waiter that joins a readable claim is served on the next state turn, once its run holds its token. Complete then settles the claim Ready and delivers to nobody new. A failure settles the remaining waiters Failed, and the availability fails the delivered handles' reads with the transfer's error.

**A readable stream is held by what it served, counted in one place: the availability's holders** (`addReader`). Each open dispatched while readable holds it from dispatch until its result is delivered on the state queue. Each handle it returned holds it from its open until its dealloc (`holdStream`, sent on the open's worker before the open lets go). The count therefore never dips to zero across the handoff. **TRAP: the delivery's turn settles the run first, before the open's hold lets go.** A rebound run's restart then installs its waiter, which holds the stream. The last holder's `onLastReaderGone` asks again, and reaches the state queue behind that turn. Only served handles hold. Any other reader of the part file, such as a waveform decode's, rides the stream and fails with it.

That count stands in for the served waiters wherever a playback or prefetch waiter counted (`claimServesForeground:`). The foreground hold stays raised, so a metadata scan's ranged reads stay off the wire while the user's stream downloads. A metadata waiter may still join. A run with no waiter and no reader is cancelled (`cancelRunIfAbandoned:`, the one place where a last waiter leaving cancels too). **TRAP: an empty waiter table alone does not abandon a readable stream**, since its served handles hold it. Its last reader leaving, or a failed or interrupted open, must ask again. A skip away from a stream therefore stops its download and frees its lane. A track's natural end does the same, since a stopped player lets its file go. A metadata waiter still on the claim keeps it running.

**The eight initial-probe slots are process-wide, and their exhaustion is a bounded failure by design.** Vibe can present about eleven distinct claims at once: playback, prefetch, the scan and priority metadata slots, and seven artwork requests. Eight wedged probes can make a later healthy path expire after the five-second grace. That settles as `AdmissionExhausted`, spends one of a metadata caller's attempts, and can drop the path from its scan. It replaces an unbounded tail of uncancellable system calls. Refresh probes do not use the slots. A never-returning refresh stays state-isolated, but holds its reserved transfer lane, the one-wide background lane included.

## Admission has two lifetimes

**A transfer lane ends when its materialization run settles. The handle-run ceiling is a separate lifetime.** For a stream the run settles when the download completes or fails, not when its handles open. A readable claim keeps its lane and its registry entry while the handles it served read the part file. A lane can therefore be held for the whole download under a playing track. The lane counts bound transfers, not opens. The abandoned-stream cancel keeps a rapid skipper from filling the interactive lane with downloads nobody hears.

**Transfer-lane admission is the coordinator's own** (`admitClaim:…`). Running claims count against the lane's maximum. Pending claims count against the pending bound, with a deadline at the grace. A file already local starts at once outside the lanes, so only dataless claims are bounded. **Only a dataless run holds a lane slot** (`holdsLane`). A start refresh that finds its file local hands the reserved slot back. Nothing times a running read out. A counted local read stalled on a network share or a sleeping disk would hold the one-wide background lane for as long as it blocked, and every cloud file's metadata would expire behind it. `AudioWorkScheduler` and its tested `AudioWorkAdmissionRules.h` are `core/Common`'s. The coordinator uses one scheduler for the dataless probe. Transfer exhaustion and the handle-run refusal both map to `VibeAudioFileOpenErrorAdmissionExhausted`. The file never began, which is not that file's playback timeout.

### The handle-run ceiling, and how it is derived

**Each coordinator permits at most six live handle runs.** An app shares one coordinator, `sharedCoordinator`, so the bound is process-wide. It is derived from two facts about the app, and it holds only while both hold.

- **One player with two open sources.** An app has one production player per process, with a playback slot and a prefetch slot. Its gapless successor is the parked prefetch handle, never a third open. So at most two runs are ever wanted at once.
- **Every wait for a file's bytes can be interrupted.** A streaming open and a read-ahead open end at every wait when their run is cancelled (below). So the only opens that can strand a run are those that make no waits: a whole-file open on a local volume, a provider's file included, and Apple's QuickTime reader's URL open. A symlinked path, and any path the mount table cannot place, takes the direct road and can strand a run too.

The six are the two sources plus room for four opens stranded in the OS. A run ends when its open returns. A streaming run leaves the ceiling at delivery, and its transfer runs on. A read-ahead thread that a dead mount strands is bounded apart from the runs: at eight orphans, a new read-ahead open waits until one exits, and that wait can be interrupted too. **An app that adds a player or an open source, makes a source multi-flight, or adds a wait that cannot be interrupted must derive the ceiling again, with its tests.** A wait for bytes happens only on decode, loader, and open workers, never on a render thread or main.

An existing `(purpose, path)` run is looked up and rebound before the ceiling is checked. Saturation therefore never duplicates or rejects work in flight. A seventh key is refused at once with `VibeAudioFileOpenErrorAdmissionExhausted`, counted in `requestsAdmissionExhausted`, before materialization starts. The ceiling is a private, purpose-blind safety bound over `_handleRuns.count`, not loading policy. It has no queue, grace, configuration value, or per-handle counter. Prefetch can exhaust it and get a later playback key refused. A waveform decode opens its own handle outside the ceiling, on its own fixed-slot schedulers.

**A run stays registered until its handle open really returns.** A timeout or a superseding request detaches the outer delivery and the materialization waiter. A handle open already begun keeps its run until it returns. A cancellation before stage 2 removes it.

**A whole-file open is uncancellable, since it makes no waits. A streaming open and a read-ahead open are cancellable at every wait.** The cancel sets the run's `openInterrupted`, and the open's `interrupted:` block answers it. For a stream the cancel also calls the availability's `wakeWaiters`, so its wait asks the block at once. A read-ahead's wait needs no wake. It asks the block again every 0.25 s. Either open, parked waiting for bytes, then returns with an interruption that reaches no one. The waiter was detached, or a rebound one gets a fresh run. That is how a player's open deadline stops a stalled stream or a stalled read-ahead. Rebind and the abandoned-then-rebound restart keep the same dictionary membership, so repeated retries cannot multiply stranded workers. A never-returning whole-file call stays one of the six until process restart, but it holds no transfer slot.

**Cancelling is the only way to stop waiting, and it cannot be separated from marking an admitted handle-open run abandoned.** `finishHandleRun:…` tells "nobody was waiting" from "this file would not open" by the run's cancelled mark alone. A waiter cleared without the mark would let the first be delivered to a later same-purpose, same-path waiter as a nil file with no error. Every caller reads that as the file failing. Before the handle open is dispatched, cancellation simply detaches the central request and removes the outer claim. A completion therefore always carries a file or a reason there is none.

**A run that installs another version than its placeholder stood for re-keys every item.** The production operation compares the file's `cacheKey` before and after the run. A remote file downloads as it is now, which may differ from what its listing said. When the key moved, the operation sends `NSURL invalidateMemoizedCacheKeys` (`core/Common`'s `NSURL+Hash`). Every memo stamped below the new generation then computes its key again, so nothing is filed under, or served from, the old version's entry. An app's late results must check their version too. `waveform/WaveformLoading`'s loader and `media/Metadata`'s tag parse each compare the key they read under with the item's current one at completion, and drop a mismatch (`waveform/WaveformLoading/AGENTS.md` and `media/Metadata/AGENTS.md`).

## The transfer registry

**`CloudTransferRegistry` is the coordinator's publication surface for "which files are on the wire", and only a dataless verdict publishes.** A fresh initial answer governs an immediately admitted run. A delayed or readmitted dataless claim publishes from its `Refreshing` worker's fresh answer. `Running` plus `dataless` means begin was published, so `finishClaim:` pairs the end without a second flag, readable or not. A stream's file therefore shows as loading until the download ends. A local run, and a claim queued behind lane capacity, publish nothing. That is what makes the lanes bound the loading indicators as they bound the transfers.

**It is the one home of "this file is loading, this far", and it watches each transferring path once.** It is main-thread. Each entry has one `DownloadProgressMonitor`, whose fraction is the best source for the backend (below). Its observers are weak and many. `cloudTransferRegistryDidChange:` is coalesced per main turn, and fires on begin, end, and a shown fraction's change. The optional `didMoveTransferForPath:` is the monitor's uncoalesced movement feed, keyed by the transfer's standardized path. An app matches it against its loading open's path, standardized once, to extend that open's deadline.

**TRAP: no consumer runs a monitor of its own.** A second monitor on the playing file means the registry standing aside for it. A stream starts long before its download ends, so ending that monitor at the start freezes the playing file's fraction for the rest of the download.

## DownloadProgressMonitor

Best-effort download progress for a file being materialized, for `CloudTransferRegistry`. Main thread only. **It observes and must never trigger a download.** The open is what fetches.

**The registry starts the only one per transferring path, through `+monitorForURL:movement:handler:`**, and cancels it at the transfer's end. The two-step init and start it wraps is private (`DownloadProgressMonitorInternal.h`).

**Three sources, and the best wins.**
- Everywhere, a poll of the dataless file's allocated size against its logical size.
- An iCloud `NSMetadataQuery`, when the item is in iCloud's index.
- On macOS, the File Provider `NSProgress` publication. It is exact when the provider publishes, and supersedes the poll. iOS has no consumer-side progress API for third-party providers, so those files have only the poll. The header records why.

**A remote placeholder's poll reads its transfer instead**: `CloudFileAvailability.writtenBytes` against the size being downloaded. Its bytes reach the placeholder only in the install's one rename. The size being downloaded can differ from the placeholder's, after a re-upload since the listing.

`DownloadProgressMonitor` owns only source precedence, movement, and whole-percent coalescing. The private classes in `DownloadProgressSourceAdapters` each own one system lifecycle: the timer, the metadata query, or the File Provider subscription and KVO. Each owns its whole cancellation path. A new observation mechanism goes behind the same fraction callback, never as another lifecycle in the monitor. `DownloadProgressSourceAdaptersInternal.h` narrows the host-less seam to iCloud query construction and File Provider subscriber registration. The tests drive every other path. Only the OS finding a cross-process publication is a live-app check.

**An `NSProgress` unpublish is not completion.** It also covers an abandoned operation or a disappearing provider. It detaches that exact source and lets the poll verify the file. Only a reported 100% or a materialized file publishes completion.

**The UI fraction is whole-percent coalesced. Transfer liveness is not.** Only a finite, strictly positive raw increase is movement. An initial zero, a repeat, a backward step, a negative value, and NaN never extend a player's deadline. The fake source passes zero through the same rule. `DownloadProgressRules.h`, header-only and tested, holds both decisions: `VibeDownloadProgressIsMovement` for liveness, and `VibeDownloadPollShouldPublish` for the poll.

**The poll reports positive partial fractions. It marks the file materialized only when `SF_DATALESS` is clear and allocated bytes reach the logical size.** Every measured provider flags its placeholders: Dropbox on both platforms, and iCloud Drive. The allocated-size check guards providers that do not. With no positive fraction the poll reports nothing.

**The query starts for every transfer except a remote placeholder's**, decided from the path alone (`VibePathIsUnderRemotePlaceholderRoot`). Only a dataless file transfers, and it is a File Provider item or a remote placeholder. Main reads no resource value to decide.

**TRAP: `NSURLIsUbiquitousItemKey` is not an iCloud test.** Every File Provider item answers YES, a Dropbox file included. Only the `NSMetadataQuery` settles it. The query stops on an item iCloud does not index, rather than idling for the length of the download.

## CloudFileMaterializer

Pulls a placeholder down to disk as an explicit, **abortable** step. Background only: it blocks for a transfer, and coordinating on main deadlocks against the app's own presenters.

It exists because an ordinary read cannot be interrupted. Opening a dataless file blocks in the kernel until the provider finishes, whatever the app decides meanwhile. A tag reader's read and a whole-file open both do. `NSFileCoordinator`'s `-cancel` is the one documented way out. So the download is coordinated here, not left inside whatever opens the file next.

Its sole production caller is `AudioFileMaterializationCoordinator`. The coordinator wraps each admitted path-wide run in a fresh materializer. Playback, prefetch, and metadata attach role-bearing waiters to the one standardized-path claim. Consumers cancel their own request tokens. Three things reach the materializer's cancel: the last waiter leaving, a stream's last reader leaving, and a central metadata yield. Nothing else mints one.

**Cancellation has one spelling here**, `VibeMaterializationCancelledError` (`NSCocoaErrorDomain` / `NSUserCancelledError`, which `NSFileCoordinator` also returns for its own `-cancel`). Above this class, the coordinator's result is the policy surface: Ready, Yielded, AdmissionExhausted, or Failed. Callers never infer retries from the underlying error.

**Every transfer hands `-cancel` one block** (`installCancelTransfer:token:`): the coordinator's, the remote fetch's, and the fake cloud's. It is installed only while its token is current. A cancel that came first is run by the caller at once.

**A fresh `NSFileCoordinator` per download.** Cancelling poisons one for good, so reusing it would turn the first abort into a permanent refusal. `materializeURL:` builds one per call.

**TRAP: a cancel can land while the coordinated read's accessor runs, and cannot stop it.** So the accessor only records that the bytes are here. The caller opens the file after coordination ends.

**TRAP: cancelling stops us waiting.** Whether the provider abandons the transfer is its business. A replicated extension's `NSProgress` may be cancelled once nothing waits on it, but nothing promises that. The cancel frees the lane and the thread at once, not the bandwidth.

### The remote fetch

**Stage 1 has two kinds of backend.** A provider's placeholder goes through `NSFileCoordinator`. A remote placeholder goes to the remote fetch installed for its root. An app installs one for each root it keeps, such as a store of links. The coordinator cannot tell them apart and must not. Both are a dataless verdict and a blocking, cancellable operation. Readable is a callback either may make, and only the remote one does.

**An app installs each backend at launch, before any open**, through `setRemoteRoot:fetch:read:availability:`, whose header states the root rules. A file goes to the backend of the longest root holding it. Every change also sets `PlaceholderFiles`' remote placeholder roots, so the dataless verdict and the backend that answers it cannot disagree. An unreadable file under no root is never sent to a backend. It is merely unreadable.

A backend has three blocks (`CloudFileMaterializer.h` states each one's contract).
- **The fetch** blocks the worker until the bytes have replaced the placeholder. **Unlike the provider path, its cancel stops the transfer**, not just the wait. A fetch that can be read before it completes also calls `onReadable`, at most once, from its own thread. `materializeURL:token:onReadable:error:` hands the caller's block straight through. The claim, its lane, the foreground hold, and the registry entry run on until the fetch completes (One claim, two stages, above).
- **The read** reads a placeholder's bytes by range for a tag parse. Opening a folder then costs its tags, not its files. `remoteReadForURL:` answers the read of the file's backend, nil under no root.
- **The availability**, the streaming lookup, answers a `CloudFileAvailability` for a file whose transfer is writing its part file now. A file it answers nil for opens whole. It may answer nil only once the object it handed out has finished, since a reader that looked it up may be waiting on it. Every backend installs one.

### CloudFileAvailability

**It says how much of a file is readable while a writer fetches it.** `CloudFileAvailability.h` states every call's contract. There are two writers.
- A transfer writes a part file from byte 0. Its size is known before the first byte. It notes bytes only after writing them. It may also hold one **tail window**: bytes past the download's edge that it read ahead. The window always lies wholly past the bytes written, so no read mixes the two. A range straddling its start waits for the disk.
- A writer with no part file fetches by range into blocks held in memory (`initWithoutPartFile`). The one such writer is the read-ahead on a network mount (below). It drives itself from `waitForWorkUntil:wanted:length:readerPosition:` and asks `heldEndAt:`, never a wait, what is already held. A wait would move the reader's position.

Each writer finishes once. Complete readies every range on the disk. An error fails every wait, bytes already read included. **TRAP: a writer with no part file always finishes with an error.** Complete would send readers to a disk it never wrote, and `finishWithError:` asserts it.

**Waits run on worker threads only.** Nothing a render reaches touches the availability. A wait ends on its range, on the finish, on the reader's own `interrupted` block, or on an optional deadline. `wakeWaiters` makes every wait ask its block again. `readyBytesAt:length:` never waits. A backend's tag reads take a streaming file's bytes that way.

**TRAP: every block is dropped under the lock a reader copies under.** A wait a block answered has then copied before the block goes.

**Holders are counted** (`addReader`): each handle served from the part, and an open about to become one (One claim, two stages, above). `onLastReaderGone` tells whoever runs the transfer that nobody wants it. That is how the coordinator cancels a stream skipped away from. A read-ahead's availability has no holders.

## The network-mount read-ahead

**`NetworkReadAhead` reads a file on a network mount ahead of its handle.** `audio/Decode`'s file handle is its one caller, and `audio/Decode/AGENTS.md` says when an open reads ahead and how its reads wait. The handle makes six calls: whether the file reads ahead, wait for room, start, size a play's read-ahead, close, and the handle is gone.

**Whether a file reads ahead comes from the kernel's mount table.** `VibeNetworkReadAheadApplies` reads it with `getfsstat(MNT_NOWAIT)` and never stats the path, since a dead mount holds a stat for its timeout. `VibeMountReadsAhead` (`NetworkReadAheadRules.h`) takes the mount with the longest prefix of the path, comparing spellings only as `VibeAliasFreePath` writes them. A mount without `MNT_LOCAL` is a network one. An unreadable table, a symlinked path, or a path no mount holds takes the direct road.

**The read-ahead is one thread per handle**, named `vibe-libs.fileloading.readahead`, at a fixed User Initiated QoS, since a prefetch opens at Utility and then becomes the voice. It is the only thread that enters the kernel for the file. It opens the file with the direct road's flags. It checks the file, and notes its size in an availability with no part file (CloudFileAvailability, above).

It then fetches 256 KB blocks. A range a blocked wait wants comes first, rounded out to whole blocks and started past any bytes already held. Otherwise it fetches ahead of the reader, up to the availability's `readAheadSpan`. An earlier play's read-ahead can hold that back (below). An open that succeeds puts the reader back at the head (`noteReaderPosition:`), or an open that read the tail last would leave nothing fetched ahead of the audio. After each block it drops what lies more than one block behind the reader or past the span. The block behind serves an MP3 seek's preroll and a FLAC decoder's bisection, and the file's first and last blocks are always kept.

**The span is 8 MB until a play's handle sizes it.** The coordinator sends `holdStream` to the playing handle and the parked prefetch. Each then raises its span to 30 s of the file at its byte rate, its size over its duration (`VibeReadAheadSpanBytes`, `NetworkReadAheadMath.h`). The span stays between 8 MB and 64 MB. A file with no duration keeps 8 MB. A rise wakes the thread. 8 MB lasts 3.5 minutes of a 320k MP3 but only 7 s of a 24/192 WAV. A waveform decode's handle keeps 8 MB. Its decode runs faster than real time, and nobody hears it stall. A track on a share has up to three handles. A 24/192 WAV then holds about 35 MB in each of the play's two and 8 MB in the waveform's.

**The playing track's read-ahead goes first.** An app asks for the next track's prefetch as each track starts. Its read-ahead would then fill its span alongside the playing track's. On a slow share that slows the playing track's fill. A play's read-ahead therefore fetches ahead of its reader only while every play's read-ahead sized before it is idle (`VibeNetworkReadAheadSizePlay`). The order is the order of `holdStream`. The playing handle gets it before the app asks for the prefetch. A read-ahead is busy while its last pass found a block to fetch, a wanted range or one ahead. An earlier one whose handle is gone never holds a later one back. **A range a wait wants is always fetched.** An open or a decoder read never waits for an earlier play. A waveform's read-ahead is no play. It never waits, and never holds a play back.

A prefetch's read-ahead fetches ahead freely until its open returns and sizes it. That serves the open. A voice retiring over a crossfade still reads. It can hold the new track's fetch ahead back until its handle goes. A held-back thread asks again every 0.25 s, since no wake crosses from one availability to another. The play read-aheads are a list in `NetworkReadAhead.m`, under the orphan count's lock. Each thread keeps its busy bit in the flags cell it shares with its handle. A cell joins the list when its handle sizes it, unless its thread is gone. It leaves at its thread's exit, before it can be freed.

**A read the server fails never fails the availability, unless the file changed meanwhile.** The thread logs the first failure in a row, waits about 1 s, reopens the file, and tries again, until its handle is gone. A reopened file whose size or mtime differs fails the availability with `ESTALE`, since its bytes would mix with the old file's blocks. The inode is not compared, since some SMB servers renumber a file across a reconnect. A server back within the stall's span plays on by itself. **TRAP: a read of 0 bytes below the size is the file's end only when `fstat` says the file is now that short.** A network mount can read 0 bytes while it reconnects. Any other 0 is a failed read, logged as EIO and retried, since taken as the end it ends the track early. The thread records a real end once (`noteShortenedEnd:`).

**The handle's dealloc closes the availability**, with a "closed" error. The thread exits once its current syscall returns, and closes its descriptor. A dead mount can hold that syscall for minutes, and a slow share for a while. Until it returns the thread is an orphan, counted process-wide. **Once eight are orphaned, a new read-ahead open waits** for one to exit, asking its `interrupted` block every 0.25 s. A player's open deadline still bounds it. The handle-run ceiling counts these threads apart from its six runs (Admission has two lifetimes, above). `Read-ahead:` log lines mark each thread's start, its first failed read, and its end.

- **TRAP: the thread retains the availability only, never the handle**, so the handle's dealloc can finish the availability and end the thread.
- **TRAP: the thread never holds the availability's lock across `open`, `pread`, or `close`.** A player's queue takes that lock through `interruptReads` and `wakeWaiters`.
- **TRAP: the thread never finishes its availability with nil.** Complete would send its readers to a disk it never wrote.
- **TRAP: the orphan count moves only under its own lock, at the handle's dealloc and at the thread's exit.** A thread still running at the dealloc is an orphan until it exits, and no other thread ever is. The two edges share one flags cell, and the second edge frees it. The cell also holds the busy bit. It is no edge, and the edge test masks it out.
- **TRAP: nothing holds the orphan count's lock across an availability call or a syscall.** A handle's dealloc takes it where a player waits.

## Why the monitor and the materializer are not merged

They look like one thing and are opposites in the two ways that matter. The monitor **observes and must never trigger** a download, and is main-thread only. The materializer **causes** one, can abort it, and must never run on main. Merged, "never triggers" and "triggers" would sit behind one name. The real overlap, whether the file is here yet, already lives in one place: `PlaceholderFiles.isDatalessFile:`.

## Configuration

**`AudioLoadingConfiguration` is immutable once built, and its diagnostic surface is for tests and an app's debug channel only.** The safe tuning surface is the background lane width, the local parse concurrency, and the prefetch depth. The interactive lanes, pending bounds, grace, retry count, and `openTimeouts` are diagnostic. The `(Debug)` category and the tests replace them. Production code never does.

**The error domains start `vibe-libs.fileloading`.** They are `vibe-libs.fileloading.materialization`, `vibe-libs.fileloading.open`, and `vibe-libs.fileloading.configuration` (`VibeAudioFileMaterializationErrorDomain`, `VibeAudioFileOpenErrorDomain`, and `VibeAudioLoadingConfigurationErrorDomain`). The fake cloud's failures are `vibe-libs.fileloading.fake-cloud`.

## The debug seams and the fake cloud

**How a seam builds here.** Its header has no `#if DEBUG`, since no header here may carry one. Its `.m` wraps its whole body in `#if DEBUG`, so a release build compiles an empty object and ships none of it. This repo's tests build Debug, so they test it. An app's debug configuration must define `DEBUG`. A call from code that also builds in release fails to link. So only debug-only code calls a seam. The template compiles the seams in every configuration, because a template cannot know an app's configuration names. A shipping file imports a seam's header only to call it in debug code.

The five `+Debug` categories each sit beside the class they open:
- `AudioFileMaterializationCoordinator+Debug` reads the admission counters, and can hang stage 2's opens of one basename until released.
- `AudioLoadingConfiguration+Debug` reads a configuration as a dictionary, and builds one from `key=value` arguments.
- `CloudFileMaterializer+Debug` runs a fake transfer of a fixed duration in place of a coordinated read.
- `DownloadProgressMonitor+Debug` replaces a monitor's sources with a fake fraction.
- `PlaceholderFiles+Debug` installs a dataless probe, and tallies a real provider's stats per directory.

**TRAP: the fake transfer's blocks and the fake progress are set by the debug channel and read on download workers and monitors, so both are read under a lock.** An unlocked read of a block global is a retain racing a release.

**`NetworkReadAhead+Debug.h` declares the read-ahead's own hooks**, so a test plays a local file as if it were on a share. Their statics and functions live in `NetworkReadAhead.m` under `#if DEBUG`. The mount rule forces the rule per URL. The before-read hook runs on the read-ahead thread before each `pread`, outside every lock. It can throttle a read, stall it, fail it with an errno, or end the file there. The retry scale multiplies the pause before a failed read is tried again. Two counts are read back: the threads alive, and those orphaned inside a read. Both are process-wide, so a test sets them for its own URLs and clears them in `tearDown`. **TRAP: the rule and the hook are set on a test's thread and read on open and read-ahead threads, so both are read under a lock.** An unlocked read of a block global is a retain racing a release. `audio/Decode`'s file handle forwards to them, so its read-ahead tests drive the same hooks.

**`VibeFakeCloud` stands in for a file provider.** Chosen files answer as placeholders, each takes a fixed time to download, and a cancel leaves the file a placeholder. It injects at exactly three points: `PlaceholderFiles`' dataless probe, `CloudFileMaterializer`'s transfer, and `DownloadProgressMonitor`'s reporting. Everything above them runs unchanged. An app's debug channel installs it. **TRAP: its progress seam replaces the monitor's real sources rather than joining them** (`DownloadProgressMonitor+Debug.h`). Under a fake transfer the file on disk is genuinely local, so the allocated-size poll would answer 100% on its first tick.

**The fake sees downloads, not reads.** Its statistics and trace count each transfer: requested, started, completed, and cancelled. Under it a placeholder is a local file. So a read that skips `isDatalessFile:` and the materializer succeeds, downloads nothing, and leaves no mark in its counts. No single point opens a placeholder's bytes: a tag parse, a decoder's open, and a sheet's read each open the file themselves. So a test that claims nothing read a placeholder also checks the files' access times. It sets them long before their mtime, and a read it expects shows that the volume records reads (`media/FolderScan`'s `testAScanOverTheFakeCloudReadsNoPlaceholder`).

## Tests

`Tests/files/FileLoading/` holds the tests of every file here, the fake cloud's included. They run on macOS in Debug, with the headermap off, so they prove FileLoading builds and tests alone, with no decoder's header in reach.

- **The coordinator's stage-1 tests** run over a gated dataless probe, hand-completed provider operations, and a clock the test sets. Their harness is `AudioFileMaterializationCoordinatorTestCase`, and their fakes are `Tests/Support/MaterializationTestFakes`. `AudioFileMaterializationCoordinatorTests` covers the path claims, and `…ForegroundTests` the foreground hold.
- **The stage-2 tests**, `AudioFileMaterializationCoordinatorHandleOpenTests`, open `Tests/Support/VibeTestServedFile`, a served handle with no decoder. A missing or empty file fails with an error, as a real handle's open does. The handle-run ceiling's tests are here. `audio/Decode`'s `AudioFileHandleOpenTests` checks that a real handle is delivered through the coordinator.
- **A network mount is forced, never found.** `NetworkReadAheadRulesTests` feeds `VibeMountReadsAhead` a fake `statfs` table and never reads the machine's. The read-ahead's thread is driven by `audio/Decode`'s handle tests, through the hooks above.
- `VibeFakeCloudTests` drives the fake through the production coordinator. The minimal consumer cancels an open over it while the download is in flight, and checks that the claim, the transfer, and the registry entry go.

Each test makes its files under `NSTemporaryDirectory()`, in a directory of its own. **A bounded wait is a hang guard or a gate.** A wait for what must happen uses `VIBE_TEST_HANG_TIMEOUT`. A gate the test releases itself uses `VIBE_TEST_GATE_TIMEOUT`, which outlasts the guards it holds across. The test bundle defines both.

# system/AppOpening

On the mac, one open request from the batches Launch Services splits it into, delivered in order. Launch Services can split one multi-file open into several batches. An app then expands each batch at its own pace, as a folder walk or a playlist read. Two classes handle those two shapes. It depends only on `core/Common`, for the scheduler type. It came from Vibe. None of it reads an app's settings, strings, or types. **It is macOS only**, so its files sit in its `Mac/` half and no iOS target lists its template.

| File | Owns |
| --- | --- |
| `OpenBurstCoalescer.{h,m}` | the burst: the queue before launch, the first batch that replaces, the later batches that append, and the deliberate open that ends a burst; the launch order of drain, restore, and empty state; the paths among a process's arguments |
| `OpenRequestCoordinator.{h,m}` | each request's expanded rows, delivered in submission order: supersession by a replacing request, holds, and the straggler deadline |
| `OpenBurstCoalescer+Debug.h`, `OpenRequestCoordinator+Debug.h` | the seams: the queued URLs and the buffered results |

Both are main-thread only.

## The coalescer

**The first batch of a burst replaces at once, and later batches inside the quiet period append.** So a double-clicked file never waits. The app picks the quiet period. Every event restarts it, even one with nothing to drain. The scheduler is a block the app may inject. The default runs `dispatch_after` on main. A superseded quiet-period block does nothing.

**A system open joins the current burst** (`openBurstURLs:`). The app calls it from `application:openURLs:` and for the files among its arguments. **A deliberate open ends any burst instead** (`openDeliberateURLs:appending:`). The open panel, Open Recent, and a window drop are deliberate. Whether a deliberate open appends is the caller's choice.

**Before start, every open only queues.** `startAndDrainQueue` drains the queue as a burst's first batch. So the rest of an open that straddled launch appends. An empty start arms no burst, so an open a beat later replaces.

**Launch order is drain, then restore, then the empty state** (`finishLaunchRestoring:revealEmpty:`). The app calls it once, when the opens may start. A sandboxed app calls it after its folder grants are restored. A queued open wins, and the restore block does not run. The restore runs only when nothing drained. `revealEmpty` runs only when the restore also found nothing. **A restore is not an open**, so it never arms a burst.

**`fileURLsInArguments:valueOptions:existingPath:` finds the paths among a process's arguments.** It skips the process's name, every dash-prefixed argument, and the value after each option the app lists. The `exists` block runs on the caller's thread. A stat can block for an automounter's timeout, so call it off main.

The sink gets each batch unexpanded, with whether it appends. Expanding it is the app's work.

## The coordinator

**It is a coordinator of ordered, target-matched delivery.** Each result reaches the request it was finished for, in submission order, and only while that request is current.

- **A replacing request supersedes every older one** (`beginRequestAppending:` with NO). It starts a new generation, and every older token stops being current. `isRequestCurrent:` lets an owner stop work it no longer needs.
- **A result may finish out of order** (`finishRequest:rows:folderCount:`). It buffers until every earlier request of its generation has finished. Then each delivers through its own block, on main, in submission order. A superseded token's result is dropped.
- **The rows are the caller's own objects.** The coordinator never reads, copies, or compares them. It hands each array back as it came. The folder count rides with it.
- **`invalidate` supersedes every pending request and buffered result.** Call it before clearing the list the opens land in, so a late result cannot refill it.
- **Use one coordinator for each list the opens land in.** Otherwise a drop could be overwritten by an older, slower open from another funnel. `sharedCoordinator` is that one for an app with one list. `-init` makes an independent one.

**A finished result waits at most ten seconds behind an earlier one.** The deadline is not a bound on expansion. Nothing is armed until a later request has finished. Then the coordinator gives up on the one request at the head, and delivers what that frees. A slow request behind a wedged one still delivers, and each stalled request costs one deadline. A skipped request's late result is dropped. `abandonStalledRequests` is the deadline's action, exposed for tests.

**A held request is never given up on** (`holdRequest:`, `releaseRequest:`). Its owner is still deciding what it opens, in a wait that is bounded and can be cancelled, such as resolving a dropped link. The release gives the head a full deadline from then. A hold or release on a superseded token does nothing.

**TRAP: a deadline that fires late must not disarm a newer one.** A replacement, or a later gap, may have armed its own. Each armed deadline is stamped, and only the latest acts. Disarming from a stale one would strand that missing request.

## The seams

`OpenBurstCoalescer+Debug.h` declares `debugQueuedURLCount`, the URLs still waiting behind the quiet period. It is zero between bursts. `OpenRequestCoordinator+Debug.h` declares `debugBufferedResultCount`, the results finished but buffered behind an earlier request. It is zero after every burst. A floor that creeps upward is a delivery that never happened. Each body reads state private to its class, so it sits in the class's own file under one `#if DEBUG`. The headers carry none.

## Tests

`Tests/system/AppOpening/Mac/` holds `OpenBurstCoalescerTests` and `OpenRequestCoordinatorTests`, 14 each. The coalescer's cover the burst's shape, deliberate opens, a burst that straddles launch, the launch order, and the argument scan. The coordinator's cover ordering, supersession, `invalidate`, the straggler deadline, holds, and a first append that stays an append. Each scheduler is injected and keeps its blocks, so a quiet period or a deadline elapses only when a test fires it. The rows are file URLs.

Vibe keeps its open funnel: what each way of opening calls, its link resolving and holds, the close that invalidates the coordinator, and its launch sequence.

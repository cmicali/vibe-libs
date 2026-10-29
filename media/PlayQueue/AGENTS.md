# media/PlayQueue

The play queue: an order over an app's own entries, with repeat, shuffle, and what follows a track's end. It depends on nothing, not even `core/Common`, since nothing here logs. Beside Foundation, its only import is its own `RepeatMode.h`. It came from Vibe. None of it reads an app's settings, strings, or types. It opens no file and touches no player.

| File | Owns |
| --- | --- |
| `VibePlaylist.{h,m}` | the queue: its rows, the cursor, the two indexes, the structural edits, repeat, shuffle, `nextTrack`, the lookahead, and `trackEndSuccessor`. `VibePlaylist.h` states each method's contract |
| `RepeatMode.h` | `VibeRepeatMode`: Off, One, and All, with MPRepeatType's raw values, so Now Playing converts by cast |

## Entries

`VibePlaylist.h` states each method's contract. This doc holds the rules a caller is checked against.

**A row's identity is the object.** The queue holds opaque entries. It keeps each one, hands the same object back, and never copies or compares it by content. Its entry-to-row map is keyed by pointer, so two entries for one file stay two rows. The app mints a fresh entry per row. Recreating rows from URLs would throw away what the app installed on each one and defeat every identity check.

**The queue reads an entry only through the two key blocks it is made with** (`initWithURLKey:sourceKey:`). The URL key indexes the rows of each file. The source key matches a stamp to the rows sounding one window. An app passes its row's URL and source key. A queue made with plain `init` has no lookup by file. It stamps nothing and replaces nothing by file. The entry type is a lightweight generic, so an app that declares `VibePlaylist<AppRow *>` gets typed rows back. The queue takes no protocol, not even `audio/AudioTypes`' playable item, since it needs only each entry's identity.

**The queue mints no rows.** A replacement takes the caller's fresh entry, and one already in the list is refused. `replaceTracksMatchingTrack:usingBlock:` asks the block for each row's replacement, since each row may be a different cue window. The queue keeps the indexes, both shuffle orders, and one event per replaced row.

**The queue keeps two indexes.** A track-to-row map keeps `getIndexForTrack:` O(1), for an app's sweep over its rows. A URL-to-rows index serves `indexesOfTracksWithURL:`, `stampTracksSounding:usingBlock:`, and the replacement of every row of a file. The URL index holds row sets, because one file can sit in several rows. A delivery stamps every row of that file and window, so a duplicate row is never stranded.

- `replaceAllWithTracks:startingAtIndex:` and `appendTracks:` move no existing row, so they update both indexes incrementally.
- `removeTracksAtIndexes:`, its inverse `insertTracks:atIndexes:`, and `moveTracksAtIndexes:toIndexes:` move rows. They renumber both indexes over the affected span (`unindexRowsFrom:to:`, then `indexRowsFrom:to:`). Remove and insert shift the tail. A move stops at the last source or destination row. All three take index sets. A single row is the one-index case, so there is no single-row path to drift.
- The cursor keeps naming the same object through every edit. A removed current row lands on `forwardTrackAfterRemovingTracksAtIndexes:`'s answer, else on the new last row. Insert clamps a past-the-end index, so an undo after later edits still restores the row.
- A move is set-to-set. Both sets are FINAL row positions, never AppKit's insertion slots, which the app converts. A move is its own inverse with the sets swapped.
- `structureGeneration` changes on a replacement or a clear. An app can stamp its undo registrations with it.
- `advanceFromTrack:toTrack:` adopts a gapless boundary only while both exact objects still name the current row and its `trackEndSuccessor`.

**The queue does not touch a player.** Removing the current row through it alone leaves a player sounding a track the queue no longer contains. The transition is the app's. A move is transport-safe, because the current object survives. Its successor's re-park is still the app's.

**There is one observer slot, and one structural edit sends one event.** A remove, insert, or move does not also fire `currentIndexDidChangeFromIndex:`. Two callbacks would make a table reconcile one edit twice. An app with several views fans the events out itself.

## Repeat and shuffle

**The queue is the one home of "what comes next".** An app pushes the modes in from its settings. The queue reads no setting. `RepeatMode.h` holds only the enum, and the app keeps its stored identifiers. There are two answers, because under Repeat One a skip and a track end differ:

- **`nextTrack`** is where Next lands: the next row, or under shuffle the next entry of the play order. It wraps under Repeat All and is nil at the boundary. `hasNextTrack` is its presence.
- **`trackEndSuccessor`** is what follows a track that plays out. It is nil under `pauseAtTrackEnd`, the current track under Repeat One, and `nextTrack` otherwise. `advanceAtTrackEnd` moves to it, and moves nothing when it is nil.

Previous never wraps.

**`trackAtStep:` reads ahead without moving the cursor.** It answers where next would land after that many calls: step 0 is the current track, and step 1 is `nextTrack`. It walks as next does, so a caller that skips rows can look past them without a write. It is nil past the end without Repeat All. Under shuffled Repeat All it reads into the next cycle, which it makes and keeps as `nextTrack` does, and it is nil past that cycle, so every row appears before the first nil. Repeat All without shuffle never answers nil, and every row appears within `count` steps. Each step is O(1).

**TRAP: a shuffled scan that skips rows runs to the first nil, never `count` steps.** The rest of this cycle can repeat rows of the next one, and a row already played this cycle first comes back after them. With order A B C D at B, and next cycle C D A B, steps 1 to 4 are C, D, C, and D. A is step 5.

**Shuffle is a play order of row objects walked by a cursor.** Entries before the cursor are played, the cursor is the current row, and entries after it are unplayed. The rows themselves never reorder. Because the order holds objects, a move needs nothing, and a remove or insert only drops or adds its own entries. A **manual pick** (`setCurrentIndex:` from outside next and previous) swaps the picked row into the next slot, or moves a played one out of the history. Nothing else repeats. Appends and an undo's inserts join the unplayed part at random. A removal never wraps.

Under Repeat All the next cycle is a fresh shuffle. With more than one row, its first entry cannot be the track that just ended. The next cycle is made on first ask and kept. A gapless splice and Next therefore use the same successor. An edit to the play order drops the next cycle. A replacement replaces its entry in both cycles. `randomBelow` is injectable for seeded tests.

**A shuffled queue saves and restores exactly.** `playOrder`, `playOrderCursor`, and `nextPlayOrder` read the order, the cursor, and the next cycle, if one was made. All are nil or 0 while shuffle is off. `replaceAllWithTracks:playOrder:cursor:nextPlayOrder:` takes them back with the rows in row order. Next then walks the saved order, the played rows stay played, and a splice armed on the next cycle still lands. Each order must hold every row exactly once, by identity, and the cursor must be a position in it. Otherwise the restore answers NO and changes nothing. With shuffle off it lands on the cursor's row and keeps no order, as `replaceAllWithTracks:startingAtIndex:` does. An app sets `shuffleEnabled` before the restore, since turning it on after starts a fresh order. An app that persists rows by its own keys maps both orders through them.

**TRAP: an open passes its start row to `replaceAllWithTracks:startingAtIndex:`. It never sets `currentIndex` after.** Under shuffle that set is a manual pick, which marks the order's random first row played without it ever sounding. `NSNotFound` lets the queue choose: row 0, or under shuffle the order's random first.

## Tests

`Tests/media/PlayQueue/` holds the tests of the queue: the order, the indexes, the edits and their cursor, repeat, shuffle, the lookahead, and the saved order's restore. They run over `TestRow`, a row of the tests' own in `VibePlaylistTestSupport.h`, since the queue reads an entry only through its key blocks. The shuffle tests seed `randomBelow`. The minimal consumer makes a queue of plain `NSURL`s and walks `trackEndSuccessor` under repeat and shuffle.

The tests of Vibe's row, its replacement and its keys, stay in Vibe.

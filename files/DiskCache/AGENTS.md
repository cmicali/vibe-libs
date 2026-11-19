# files/DiskCache

A bounded disk cache over the system's SQLite, `VibeCacheStore`, and what is left of the PINCache stores the releases before it kept. It depends on `core/Common` and links SQLite by flag. It came from Vibe. `media/Metadata`'s cache keeps its tags and art in one `VibeCacheStore`, and `waveform/WaveformLoading`'s cache keeps its entries in another.

## What is left of PINCache

**PINCache and PINOperation are gone** (CH23 of another app's cache spec). Each cache imports the PINCache store it replaced and reads it with no PINDiskCache (`media/Metadata` and `waveform/WaveformLoading`'s AGENTS.md). Three things stay, each because an app or an import still uses it:

- **`removeOtherAudioCacheVersionsKeeping:rootPath:completion:`**, a class method of a tiny `PINCache` class that holds nothing else. Apps call it at launch, and the header keeps its name, so their code builds with no edit. A PINCache store left by an older format is still on users' disks, and this is what removes it.
- **`VibeAudioCacheDefaultAgeLimit`**, 180 days, which an app passes to a cache's `setByteLimit:ageLimit:` to keep the default age. It equals `VibeCacheStore.defaultAgeLimit`.
- **`VibeLegacyCacheNames.h`**: the folder and the file names a PINCache store used, which both imports read their old store by, and the removal and the tests' fixture too. **TRAP: its functions are defined in `PINCache+VibeAudioCache.m`**, since an app's test target lists that file by its path, and a file of their own would leave the target unable to link.

**TRAP: `PINCache` is a class of this piece now.** An app that also links the real PINCache gets two classes of one name. None does.

**The template `VibeLibsPINCache` is empty**, kept for its name, since apps list it and a template an app names must exist.

## Other versions' stores

**`removeOtherAudioCacheVersionsKeeping:rootPath:completion:` removes the PINCache stores other versions left.** A PINCache store's name carried its entry format's version, as `Audio Track Metadata v10` and `audio_waveform_cache_v7` do. A format change renamed the store, so the old one was never opened again, and it kept up to 1 GiB on disk for good. The rule removes a store when its name is a current name's apart from the version suffix, a space or an underscore then `v` and digits, and it is none of the current names. So two current names of one family both stay, as `media/Metadata`'s new store, `Audio Track Metadata`, and `Audio Track Metadata v11`, the store it imports, do. A name with no suffix is a version too. Another store, and a directory that is no store, stay. An app calls it once at launch, with every name its caches give, and it runs off the calling thread. The waveform cache's `cacheName` is `audio_waveforms`, of another family, so the rule removes none of the waveform stores, and the waveform cache removes them itself (`waveform/WaveformLoading/AGENTS.md`).

**The cost is a downgrade's.** An older build keeps only the names it knows. So it removes a newer build's store in the same way.

## Tests

`PINCacheVibeAudioCacheTests` holds the tests of the removal, which came from Vibe. They lay out every name a release shipped, keep the current stores, another store, and a directory that is no store, and remove the rest. A missing directory is a no-op. They also pin the old stores' names to the ones PINDiskCache's key encoder gave, and the default age to the store's. `Tests/Support/LegacyCacheFixtures.h` writes an old store's entry as PINDiskCache filed it, for the imports' tests. `waveform/WaveformLoading`'s tests and `media/Metadata`'s each check that their store's name follows the rule. The minimal consumer makes a `VibeCacheStore` under a temporary root, writes an entry, and reads the usage back, as an app would.

## History: PINDiskCache's measures

Until 2026-11-19 each cache was a PINDiskCache folder of one file for each entry, under the category's `audioCacheWithName:rootPath:`, and this repo carried fixes of its own in it: limits set at once, no record of the entries in memory, writes that never waited for the launch's count, and reads that took no lock. Their measures, kept for the bars `VibeCacheStore` had to meet, were taken on an M4 Max over a store of 200,000 to 250,000 entries:

- **Records on demand:** 3.4 to 3.5 MB of footprint at idle, against 44.7 to 44.8 MB with upstream's records and a peak of 294 MB. A hit took 44 µs and a miss 11 µs. The launch's count took 1.1 s, and a usage count or a trim's listing 1.6 s.
- **A write during the launch's count:** 0.89 to 0.94 s while it waited for the count, and 0.4 to 0.7 ms once it did not. Measured in another app, a new file's tags took 10 to 12 s to answer after a launch under load.
- **Reads with no lock:** a read's worst call during a trim fell from 0.19 to 0.22 s to 20 ms, and during a usage count from 6.1 to 6.4 s to 25 to 54 ms.

## The SQLite store

**`VibeCacheStore` is a bounded store over the system's SQLite.** `waveform/WaveformLoading` keeps its waveforms in one, with no shared items. `media/Metadata` keeps its tags and art in another, under its folder `Audio Track Metadata`, outside PINDiskCache's prefix, so the removal above never reaches it. Each entry is a row keyed by the caller's key, with a blob, the number of its format, the name of a shared item it points into, its size, its last use as a day, and when it was written. **The row's id is the first 8 bytes of the key's SHA-256, and the key is kept in the row**, which every read and change checks. So a lookup is one descent of the table's tree, with no index of the keys to read first, which halves the pages a first read from the disk takes. Two keys of one id replace each other, as a cache may, once in about 10^9 stores of 200,000 entries. The pages are 16 KB, which makes the trees shallower and packs a 1 KB row with less waste. A blob over `inlineLimit`, 64 KiB by default, goes to a file in `Files/` beside the database, and the row lists it. So a count or a trim reads rows, never the folder.

**Formats.** Every row carries its format's number, so a format change never empties a store. `hitForKey:format:` answers only a row of that format. `hitForKey:acceptingFormatsUpTo:` also answers an older row, and the hit says it is older. A newer row is a miss for both, so a downgrade never misreads one.

**Shared items** are a second table, keyed by a name and a part, that an entry names by its name, as a file's entry would name its picture's hash. Two entries that name one item share one copy. An item goes when its last entry goes or names another, through a trigger, or when a trim takes it. `removeSharedItemForName:part:` removes one part, as a trim may, and the entries that name it keep their rows. `setData:forKey:format:sharedName:missingSharedParts:partFormat:` writes an entry and the parts its item lacks in one transaction, so a parse's write commits once. Then the entries that named it read as naming an item that is not cached. The daily work removes an item that no entry ever named.

**Limits.** The creator sets `byteLimit` and `ageLimit`. 0 means none, and the defaults are 1 GiB and 180 days. The bytes are the blobs' and files' sizes, summed. A write over the byte limit starts a trim to 90% of it, least recently used first, entries and shared items together. The age counts from the last use. A read records its use once a day at most, and the uses go to the database together, half a second later. Ties within a day go by the order of writing, by each row's `written` time, since the ids are hashes. **One shared part may have a limit of its own** (`setByteLimit:ofSharedPart:`), as a cache keeps its large art apart from its entries. That part's rows count against it and never against `byteLimit`, a table the triggers keep holds each part's bytes, and its trim takes only that part's rows. So the part never pushes out an entry, and the entries never push out the part. A trim checks the limits again when it ends, so the bytes written during it are trimmed too. The age limit runs in the daily work, ten seconds after an open and then once a day. Each trim or sweep runs 64 rows a transaction, so a write waits for one batch at most.

**The usage is a sum the triggers keep.** `usage` reads one row, so nothing is counted at an open, and it never waits for a write.

**Threads.** Every method may be called from any thread. Writes, removals, and moves run on the store's serial queue and return once they read back. Reads borrow one of a few read connections and never wait for the writer, since the database uses WAL. Each connection's page cache is capped, 256 KiB for a reader and 1 MiB for the writer. A checkpoint runs on the queue, never inside a caller's write. The open prepares the write statements and makes the journal on the queue, so the first write doesn't pay for them.

**One open at a time.** The store holds an exclusive `flock` on `Cache.lock`. A second open, in this process or another, gets nil until the first closes. `close` waits for queued work, then frees the directory. A closed store reads as empty and ignores writes.

**Damage and crashes.** A database that will not open, or that a read or a write finds damaged, is removed with its files and made again, since a cache holds nothing the user made. A file being written is listed in `pending` before it is written, and leaves the list in the transaction that writes its row. A file that a removal, a replacement, or a trim lets go is listed by a trigger in that transaction, and removed once it commits. An open removes every listed file. So a crash at any point leaves no entry that reads as good and no file that is never removed. A file whose size is not its row's reads as a miss, and its row goes. `removeAllWithCompletion:` makes the database again, and removes the old files off the queue.

**An import lists another store's files** (`adoptFileAtPath:forKey:format:lastUse:`), as the waveform cache's does from its PINCache store. A file over `inlineLimit` is renamed into `Files/`, and a smaller one is read into its row and then removed. The new name is listed in `pending` before the rename, so a crash after it leaves a file the next open removes, and that one entry is lost. `lastUse` dates the row, so the limits see the entry's age as the old store recorded it. A key that already holds an entry keeps it, and the file is left for the caller. A rename that fails, as across volumes, answers NO. At an import's end, `removeFolderAtPath:` moves the old store's folder into the store's directory, under the name a removed `Files/` takes, so the same sweep at an open removes it if a quit comes first.

**A file is read into a buffer that is not zeroed first.** Zeroing a waveform's 215 KB took about a tenth of its hit's bytes. A map was tried, and was slower: 50 µs against 41 µs for a 215 KB entry, decoded.

**Measured** on 2026-11-19 on an M4 Max, at a load of 5 to 12, beside PINCache's store with records on demand, built the same way with `-O2` into one tool, three runs each. Each store held 200,000 entries of 200 bytes, as above, kept as a keyed archive, 457 bytes in the store. A hit decodes the archive in both.

| Measure | PINCache | The SQLite store | The bar |
| --- | --- | --- | --- |
| A hit | 130 to 133 µs median | 8 to 9 µs median, 6 µs for the bytes alone | no slower |
| A miss | 6 to 7 µs median | 2 µs median | no slower |
| Footprint at rest, after 20 s of a read each ms | 11.7 to 12.1 MB | 3.09 to 3.14 MB, a peak of 3.45 to 3.50 MB | at most 3.5 MB |
| The count at an open | 1.1 s in the background, from above | none, and the open takes 1.7 to 3.1 ms on the caller's thread | none |
| A write 50 ms after an open | 0.51 to 1.78 ms | 0.16 to 0.21 ms | under 1 ms |
| A removal 50 ms after an open | 0.83 to 0.87 ms | 0.04 to 0.05 ms | |
| A usage count | 4.0 to 9.6 s | 0.29 to 0.30 ms | under 50 ms |
| A tag entry on disk, 928 bytes, at 250,000 | 4 KB, a block | 1.12 KB, 280 MB in all | under 1.5 KB |

Here PINCache measured slower and larger than the numbers above, which came from another tool. The store beats both. Over 250,000 tag entries, with the file not yet in the system's cache, a first hit read from the disk: 111 µs median for the bytes, 220 µs decoded, and the first write 1.4 ms. Run again, they were 7 µs, 10 µs, and 0.21 ms. `media/Metadata`'s AGENTS.md has the store measured under the metadata cache, a cold run of first hits included. The launch to an app's first screen is measured in the app that bumps to it.

**Its tests**, in `VibeCacheStoreTests`, root a store in a temporary directory: writes in a row and in a file, replacements, removals, moves, removing everything, the usage, a trim by use over entries and shared items, the age limit from the last use, a reopening, one open at a time, a closed store, a database that will not open, a crash between a file's write and its row, a file of the wrong size, a read while the writer is busy, the formats, and shared items, one part of which may go alone. `waveform/WaveformLoading`'s `AudioWaveformStoreTests` cover the import's adoption, through that piece. Two seams, each empty outside DEBUG, move the store's today and write the uses now.

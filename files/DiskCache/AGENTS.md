# files/DiskCache

A bounded disk cache over PINCache. It depends on `third_party/PINCache` and on `core/Common`. It holds one category, `PINCache (VibeAudioCache)`. It came from Vibe. `media/Metadata`'s cache and `waveform/WaveformLoading`'s cache build their stores through it, so their entries live and die on the same terms. The category also removes the stores other versions left.

## The store

**`audioCacheWithName:rootPath:` makes a store with the shared byte and age limits.** Each store may hold 1 GiB on disk. An entry written over 180 days ago ages out, read since or not, since a changed file identity can orphan entries and nothing else would remove them. A write makes the entry anew. A nil root puts the store under the user's caches, and a root of the caller's puts it there instead, as a test does. **TRAP: PINDiskCache applies each limit on its own queue**, so a read right after the store is made can still see PINCache's defaults.

**A store keeps no record of its entries in memory.** `audioCacheWithName:rootPath:` sets PINDiskCache's `recordsOnDemand`, a fix this repo carries (`third_party/PINCache`'s AGENTS.md). The byte limit lets a store hold about 250,000 entries, and PINDiskCache's record of each, about 170 bytes with its key, would hold about 40 MB at rest for the app's life. Measured on an M4 Max at 200,000 entries: records of 32.7 to 32.9 MB in a plain store, and none on demand. A hit takes 44 µs on demand, and 31 to 53 µs with records. A miss tries the file, 11 µs, where a record answered in 0.7 µs. A sweep lists the directory, 1.6 s at 200,000 entries where the records took 0.4 s, outside the store's lock. Each launch pays one, for the age limit's trim, and so does a full store once per tenth of its limit written, and each usage count.

**A store's user reads and writes `diskCache` directly, never the memory cache.** On macOS `PINMemoryCache` never evicts. Its cost limit needs a cost for each entry, a disk hit fills it again at cost 0, and its memory-pressure hooks are iOS only. So it would pin every entry ever loaded for the app's life.

**`audioDiskUsageWithCompletion:` counts the entries and their bytes on disk.** The enumeration blocks, so call it on the store's own serial queue. The completion is dispatched to the main thread.

The keys are the caller's. Every store is keyed by `core/Common`'s disk key, `NSURL (Hash)`. `media/Metadata` keeps three stores, the tags, the thumbnails, and the renditions, so each has its own budget. `audioDiskUsageOfCaches:completion:` sums the counts over several stores.

## Other versions' stores

**`removeOtherAudioCacheVersionsKeeping:rootPath:completion:` removes the stores other versions left.** A store's name carries its entry format's version, as `Audio Track Metadata v9` and `audio_waveform_cache_v7` do. A format change renames the store, so the old one is never opened again. Only an open store trims itself, so an old store would keep up to 1 GiB on disk for good. The rule removes a store when its name is a current name's apart from the version suffix, a space or an underscore then `v` and digits, and it is not that name. A name with no suffix is a version too. Another store, and a directory that is no store, stay. An app calls it once at launch, with the name of every store it opens, and it runs off the calling thread. A version bump then needs no edit in the app.

**The cost is a downgrade's.** An older build keeps only the names it knows. So it removes a newer build's store in the same way. Each switch between the two builds then costs one parse or decode of every file.

## Tests

The tests of the store's limits and usage are new here, and so are those of its records on demand: none kept, the byte count through writes, replacements, removals, and a reopening, a trim by use and one by date, and the records a plain store drops. They root a store in a temporary directory, check the limits, and read the usage back on main. The tests of the removal came from Vibe. They lay out every name a release shipped, keep the current stores, another store, and a directory that is no store, and remove the rest. A missing directory is a no-op. `waveform/WaveformLoading`'s tests and `media/Metadata`'s each check that their store's name follows the rule. The minimal consumer makes a store under a temporary root, writes an entry, and reads the usage back, as an app would.

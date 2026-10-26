# files/DiskCache

A bounded disk cache over PINCache. It depends on `third_party/PINCache` and on `core/Common`. It holds one category, `PINCache (VibeAudioCache)`. It came from Vibe. `media/Metadata`'s cache and `waveform/WaveformLoading`'s cache both build their stores through it, so their entries live and die on the same terms. The category also removes the stores other versions left.

## The store

**`audioCacheWithName:rootPath:` makes a store with the shared byte and age limits.** Each store may hold 1 GiB on disk. An entry untouched for 180 days ages out, since a changed file identity can orphan entries and nothing else would remove them. A nil root puts the store under the user's caches, and a root of the caller's puts it there instead, as a test does. **TRAP: PINDiskCache applies each limit on its own queue**, so a read right after the store is made can still see PINCache's defaults.

**A store's user reads and writes `diskCache` directly, never the memory cache.** On macOS `PINMemoryCache` never evicts. Its cost limit needs a cost for each entry, a disk hit fills it again at cost 0, and its memory-pressure hooks are iOS only. So it would pin every entry ever loaded for the app's life.

**`audioDiskUsageWithCompletion:` counts the entries and their bytes on disk.** The enumeration blocks, so call it on the store's own serial queue. The completion is dispatched to the main thread.

The keys are the caller's. Both stores are keyed by `core/Common`'s disk key, `NSURL (Hash)`.

## Other versions' stores

**`removeOtherAudioCacheVersionsKeeping:rootPath:completion:` removes the stores other versions left.** A store's name carries its entry format's version, as `Audio Track Metadata v8` and `audio_waveform_cache_v7` do. A format change renames the store, so the old one is never opened again. Only an open store trims itself, so an old store would keep up to 1 GiB on disk for good. The rule removes a store when its name is a current name's apart from the version suffix, a space or an underscore then `v` and digits, and it is not that name. A name with no suffix is a version too. Another store, and a directory that is no store, stay. An app calls it once at launch, with the name of every store it opens, and it runs off the calling thread. A version bump then needs no edit in the app.

**The cost is a downgrade's.** An older build keeps only the names it knows. So it removes a newer build's store in the same way. Each switch between the two builds then costs one parse or decode of every file.

## Tests

The tests of the store's limits and usage are new here. They root a store in a temporary directory, check the limits, and read the usage back on main. The tests of the removal came from Vibe. They lay out every name a release shipped, keep the current stores, another store, and a directory that is no store, and remove the rest. A missing directory is a no-op. `waveform/WaveformLoading`'s tests and `media/Metadata`'s each check that their store's name follows the rule. The minimal consumer does the same, as an app would.

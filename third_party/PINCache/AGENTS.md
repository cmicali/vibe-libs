# third_party/PINCache

[PINCache](https://github.com/pinterest/PINCache), Pinterest's disk and memory cache for Objective-C. Vibe caches metadata and waveform data in it. Other authors' code: **do not restyle it.** It depends on `third_party/PINOperation`. Its template is `VibeLibsPINCache`, which lists `VibeLibsPINOperation`.

## Building

Its files import each other as `<PINCache/...>` and `<PINOperation/...>`, so the template searches `third_party/` itself. It also searches this directory, for an app that imports `"PINCache.h"`. Its sources build with the static analyzer off and `-Wno-documentation-html`. `PINDiskCache.m` builds with `-fobjc-arc-exceptions` instead, as the pod's ARC-exception-safe subspec did. `LICENSE.txt` and `PrivacyInfo.xcprivacy` stay out of an app's bundle.

## Fixes of our own

**`PINDiskCache.m` is modified.** Each change is marked `Vibe:`, so `grep -rn 'Vibe:' third_party/PINCache third_party/PINOperation` lists them for re-applying after an update.

- The access-count xattr is neither written per hit nor read per file at launch, unless eviction is least-frequently-used.
- A hit re-dates its file, and the date the eviction sorts by, only once that date is a day old.
- Outside a TTL cache, a write removes no age-limit xattr, since none is ever set.
- A hit reads its file outside the cache's one lock, as it already deserialized. So concurrent hits run concurrently.
- An automatic trim cuts to 90% of the byte limit. So a full cache sorts its entries once per tenth of the limit written, not on every write.
- `recordsOnDemand` keeps no record of the entries in memory, reading each from its file. A sweep lists the directory a thousand files to a pool, once the disk state is known, outside the lock, and none runs that has nothing to do: a size trim under its target, or an age trim with no entry made before its date, which lists only those. A write, a removal, and a removal of everything wait for the launch's count. It is one way, set before the first write and the limits, and for a least-recently-used cache that is not a TTL cache: it asserts, and refuses any other. `files/DiskCache`'s AGENTS.md has what it saves and costs.
- With `recordsOnDemand`, a hit takes no lock: it opens the file once and takes its dates from that file, with no second stat. Only a re-date, once a day, first asks whether the file is still there. A trim sorts its listing before it takes the lock, which it then holds only to read the byte count and choose the entries, and each removal takes it again. An enumeration holds no lock while its block runs, so a usage count no longer stalls writes and removals. A trim removes a listed entry only while its file has the listing's creation date, so an entry written again since stays. A file that won't decode is removed as any entry is, so the byte count follows, and only while it is the file the hit read.
- The launch's count enumerates the directory a thousand files to a pool, with no lock held for the listing, not into one array under the lock, which held about 160 MB of URLs at 200,000 entries.
- A wait for a writable disk or a known disk state loops, since a condition's wait can wake for nothing. A trim's loop stops before its count could wrap below zero.

## License

Apache License 2.0, in `LICENSE.txt`. Copyright (c) 2015 Pinterest, and (c) 2013 Tumblr, Inc. `THIRD-PARTY-NOTICES.md` at the repo root has the notice.

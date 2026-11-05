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
- `recordsOnDemand` keeps no record of the entries in memory. A cache keeps one for every entry by default, about 170 bytes each with its key, so 200,000 entries hold about 33 MB for the cache's life. With it set, a miss tries the file, a hit reads the file's dates before it re-dates it, and the byte count is a running total, with the old size read from the file before a write or a removal replaces it. A trim, an expiry, and an enumeration list the directory for the call alone, under the cache's lock, as a trim already sorted under it. It is for a least-recently-used cache that is not a TTL cache, since it keeps neither access counts nor object-level age limits. Setting it drops any records already read.

## License

Apache License 2.0, in `LICENSE.txt`. Copyright (c) 2015 Pinterest, and (c) 2013 Tumblr, Inc. `THIRD-PARTY-NOTICES.md` at the repo root has the notice.

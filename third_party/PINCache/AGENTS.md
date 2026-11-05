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
- `recordsOnDemand` keeps no record of the entries in memory, reading each from its file. A sweep, a trim, an expiry, or an enumeration lists the directory once the disk state is known, outside the lock. It is one way, and for a least-recently-used cache that is not a TTL cache, which it asserts. `files/DiskCache`'s AGENTS.md has what it saves and costs.

## License

Apache License 2.0, in `LICENSE.txt`. Copyright (c) 2015 Pinterest, and (c) 2013 Tumblr, Inc. `THIRD-PARTY-NOTICES.md` at the repo root has the notice.

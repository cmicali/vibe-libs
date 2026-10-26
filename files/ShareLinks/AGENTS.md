# files/ShareLinks

Opening a web link to an audio file: which addresses are fetched, whether the first bytes are audio, the file's name, and share links turned into the address of their bytes. Dropbox and Google Drive links are rewritten. An iCloud Drive link is looked up before each request, by `LinkClient`. What a drop or a paste holds is decided here too. The fake web server, which stands in for these hosts in tests and a debug channel, lives here (the plan's rule 8). It came from Vibe. It depends on `core/Common` and `files/HTTP`. It is Foundation only, and no file needs a platform half. It reads no app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `LinkClient` | the client every link goes through: the plain client, and an iCloud Drive share's lookup before each request. Also the link error's domain and `VibeLinkMakeError` |
| `LinkRules.h` | the address rule, the audio check, the names, the share-link rewrite that asks each host's file, a link directory's name, the pruning choice, the probe's deadline, and the failures |
| `LinkDropRules.h` | what a drop or a paste opens |
| `DropboxLinkRules.h`, `GoogleDriveLinkRules.h`, `ICloudLinkRules.h` | one host's share links each: the rewrite, or iCloud's lookup, and what that host answers. No other link code names a host |
| `VibeFakeHTTP` | the fake web server: its directory, its faults, and its log |

**What an app gives it.** The extensions it plays, as a set, to the audio check and the name (`VibeLinkAudioExtension`, `VibeLinkFileName`). A string of its own for each `VibeLinkError`. A store that keeps what a link opens, which is the app's. It subclasses `files/RemoteFiles`' placeholder store over a `LinkClient`, and keeps the record, the resolve, the budget, and the pruning's call.

## The address rule

**The address rule is `VibeLinkURLAcceptance`.** It answers the `VibeLinkError` a refusal fails with, and None for an address that is fetched. https reaches any host. Plain http reaches only a local host (`VibeLinkHostIsLocal`). That is `localhost`, a name ending in `.local`, `.localhost`, or `.test`, an unqualified name, or an address in 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, 0/8, ::1, ::, fc00::/7, or fe80::/10. Plain http to any other host is insecure. Any other scheme, or no host, is invalid. An app sets `NSAllowsLocalNetworking` for the local side. App Transport Security applies its own rules after this one.

**`VibeLinkRequestIsAllowed` is the client's `allowsURL`** for a link and every redirect. It applies the address rule to each. A redirect from a host classified as public cannot target one classified as local. The rule checks host spelling, not DNS results, so a redirect can still leave the local network.

**TRAP: an IPv4 address is parsed as the resolver parses it** (`inet_aton`). `134744072` and `0x8.8.8.8` are 8.8.8.8, not unqualified names. Read as a name, a bare number would let plain http reach any public address.

**TRAP: keep the unspecified addresses `0.0.0.0` and `::` on the local side of redirect checks.** They can reach this machine. The IPv4 rule covers all `0/8`.

**TRAP: a zone id belongs only to an IPv6 literal** (`fe80::1%en0`). A `%` anywhere else, or a NUL, makes the host not local. Cut there like a zone id, `pi%.example.com` would pass as the unqualified name `pi`.

## The audio check and the name

**`VibeLinkAudioExtension` says whether a link is audio, and which extension it takes.** The first bytes come first: `ID3` or an MPEG sync, ADTS, `fLaC`, `RIFF…WAVE`, `FORM…AIFF` or `AIFC`, the W64 GUID, `OggS`, `ftyp`, or `caff`. Then the URL's extension, the Content-Disposition file name's, and the Content-Type. When the bytes name a family, such as Ogg, MP4, or WAV, the URL's or the file name's extension picks the member. HTML the bytes do not claim is not audio. Only the app's playable set counts. The caller passes the link's own URL, not the redirect's, since a CDN's path carries no name.

**The file name is `VibeLinkFileName`.** It is the link's last path component, percent-decoded, when that has a playable extension. Otherwise the Content-Disposition file name wins, when there is one. The chosen extension is forced on. Cleaning swaps `/` and `:` for `-`, and drops control characters, the bidi controls, and leading dots. An override would show a name's end reversed. The name is cut to 200 UTF-8 bytes. It is `Link.<extension>` when nothing survives.

**A link's directory is its normalized URL's hash** (`VibeLinkDirectoryName`): the first 16 hex digits of that SHA-1. Normalization lowercases the scheme and host and drops the fragment. **`VibeLinkDirectoriesToPrune` picks each link not opened for 30 days that nothing keeps.** A directory with no record counts as long unopened.

**The probe's deadline is `VibeLinkProbeTimeout`**: 15 s for a public host, 30 s for a local one, which may be a NAS spinning up or sit behind the system's local-network prompt. The failures are chosen by `VibeLinkErrorOfStatus`, `VibeLinkErrorOfNetworkError`, and `VibeLinkErrorOfMissingSize`. A 401 or 403 is denied, and a 404 or 410 not found. Any other status is the server's failure. A request with no response is insecure when App Transport Security refused it, and invalid for a bad or unsupported URL. Any other is the local network's when the host is local, and unreachable otherwise. A missing size is a live stream when icy headers or chunked audio say so, and no size otherwise.

**A failure is a `VibeLinkErrorDomain` error, `vibe-libs.sharelinks`, whose code is a `VibeLinkError`** (`LinkClient.h`). `VibeLinkMakeError` carries the cause under `NSUnderlyingErrorKey` and its status under `VibeHTTPErrorStatusCodeKey`. Cancelled has no string: the user's own cancel shows nothing.

## Share links

**A share link is rewritten to the address of its bytes** (`VibeLinkDirectDownloadURL`). **Each host's rules live in its own file, and no other link code names a host.** That file's header also says what the host answers and why. The rewrite asks each file in turn and fetches any other link as typed. A new host is a new file and one more step in the rewrite. An iCloud Drive link is no step in it, since it is looked up before each request (below). Vibe's `docs/future/share-links.md` has the probes.

**An iCloud Drive link is looked up before each request** (`LinkClient`, `ICloudLinkRules.h`). Its share page is a script, not the file, so the rewrite leaves it as typed.
- The lookup states the file's checksum, size, mtime, and name, and a signed download address. It needs no sign-in. `allowsURL` is asked of it too.
- A lookup is reused for 10 minutes, timed by the system's uptime (`VibeICloudLinkAddressIsFresh`). The address's own expiry is in iCloud's clock, so it is never compared with this device's. A clock 15 minutes fast would find every address expired. One lookup per share is in flight at a time, the lookup claim. Every request arriving during it is a waiter on that one. A session swap forgets every lookup, since the old sessions named the old server's addresses. **TRAP: the base's init swaps the sessions before `LinkClient`'s ivars are set.** The lock is then zero, which is its initial value, and the cache is nil.
- A lookup that lost its connection is sent again, twice at most, as a download's dropped connection is. A throttled lookup waits and is sent again, as a request is. Without that, a resend waiting on its lookup would fail the download on one blip.
- A refused address may only have expired (`VibeICloudLinkStatusIsStaleAddress`). Its lookup is forgotten, and the request is sent again on a fresh one (`handleFailureStatus:`). A transfer does that once. A second refusal fails.
- **TRAP: the version is the lookup's checksum, never a header** (`metadataOfResponse:state:`). The checksum stands in the metadata as a strong ETag, which the client takes as the version. iCloud sends no ETag, and its Last-Modified is when it signed the address. Read as a version, every lookup would be another one. A resend after a fresh lookup would fail, and a kept download would be fetched again at every open. The metadata drops Last-Modified, so the CDN case never applies. The mtime and the name are the lookup's too.
- What opens nothing, before any request to the file: a share that needs a sign-in, or has no anonymous access, is `ICloudPrivate`. A folder is `ICloudFolder`. A share that no longer exists is not found. Any other answer is `ICloudUnreadable`, never the server's failure. A lookup that cannot connect fails as itself, so an app can still open a download it kept.
- A log line names neither the share's id nor the address's query, since either one reads the file. The answer also names the owner. Nothing reads that.

## Drops and pastes

**What a drop holds is decided here, as plain data, so the tests need no pasteboard** (`LinkDropRules.h`). `VibeDropURLsOfItems` reads each pasteboard item's strings by type: a file URL wins, then a URL, then text. A URL or text counts only when it is one http or https link (`VibeLinkIsWebLink`). A `.webloc` is a file, and its link is the `URL` key of its property list, XML or binary (`VibeLinkURLOfWebloc`). `VibeDropOpenOrder` swaps each `.webloc` for its link and keeps each link once, by its normalized URL. Files are never merged. Files and links keep drop order. A paste's items are read the same way, and the first web link opens (`VibePasteLinkOfItems`).

## The fake web server

**`VibeFakeHTTP` serves a directory as a web server, over a client's own sessions.** It answers `https://fake.vibe.test/<path>` and `http://fake.local/<path>`. It replaces the client's sessions through `useSessionConfiguration:`, and `uninstallFromClient:` puts the real ones back. While installed it answers every request on those sessions, so a refused link shows zero requests. A file answers as a server with ranges does: 206, 416, and 200, with its length, ETag, Last-Modified, and type. An open range is paced in 64 KB pieces. Faults script what real servers do: a stall, a lost connection, a new version, a throttle, a slow first byte, no ranges, no length, a radio stream, a status, a web page, gzip, and a short-lived iCloud address. **It answers iCloud's lookup too.** `https://www.icloud.com/iclouddrive/<name>` is the root's entry named `<name>` without its extension, and a directory there is a folder share. An app's debug channel installs it.

**Its serving engine is `files/HTTP`'s fake, `VibeFakeHTTPProtocol`, which the tests' `HTTPStub` shares.** The Range rule, the pieces, the hold, and the lost connection are the engine's (`files/HTTP/AGENTS.md`). The directory's answers are a subclass of it in `VibeFakeHTTP.m`. This piece holds only what a service answers.

**How the fake builds here.** Its header has no `#if DEBUG`, since no header here may carry one. Its `.m` wraps its whole body in `#if DEBUG`, so a release build compiles an empty object and ships none of it. Only debug-only code calls it.

## Tests

`Tests/files/ShareLinks/` holds the rules' tests, the drop rules' tests, each host's rules tests, and `VibeFakeHTTPTests`. They run on macOS in Debug, with the headermap off. The rules' tests pass `audio/AudioTypes`' playable extensions, as an app would, so a format added there is checked here too. The test bundle lists that template. The piece never imports it. `VibeFakeHTTPTests` checks each answer on the wire, each fault through the plain client, and an iCloud Drive share looked up through `LinkClient`: a lookup, a probe, and a download, an expired address looked up again, and a folder or a missing share refused. The fake's state is process-wide, so only that class drives it. `ICloudLookupFixtures.h`, beside the tests, builds an iCloud Drive lookup's answer and its signed address. `ICloudLinkRulesTests` and Vibe's link tests read it. `VibeFakeHTTPTests` takes `PatternBytes` from HTTP's `HTTPStub.h` (`Tests/files/HTTP/`), which the test bundle searches. It compiles no stub. Vibe keeps the tests of a link through its own store.

# files/HTTP

Ranged HTTP transfers, for files an app fetches itself rather than through a file provider. A download streams into a file as its bytes arrive. A ranged read and a probe read a file's bytes without downloading it. A resend continues a download rather than starting it over, and only for the same version. It also holds a fake of ranged HTTP serving, for tests and a debug channel (the plan's rule 8). It came from Vibe. It depends only on `core/Common`. It is Foundation only, and no file needs a platform half. It reads no app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `HTTPTransferClient` | the streamed download, the ranged read, and the probe. The resends, the kept part, and the version pin |
| `HTTPTransferClientInternal.h` | the hooks a subclass overrides, and the seams the tests and a debug channel use (`useSessionConfiguration:`, `retryDelayScale`) |
| `HTTPTransferRules.h` | the retry delay, the connection errors, and the size and version a response's headers state |
| `VibeFakeHTTPProtocol` | the fake's serving engine: the one `NSURLProtocol`, the one Range rule, and the one body delivery |

**A client of a web API subclasses the client.** `files/ShareLinks`' `LinkClient` does, and so may an app's own API client. `files/RemoteFiles`' placeholder store fetches through any of them.

**TRAP: a subclass's internal header imports `HTTPTransferClientInternal.h` and never redeclares its seams.** A redeclaration that cannot see the base's gets an ivar of its own. It starts at 0, not 1, and every retry wait would read it.

## The client

**The defaults are plain HTTP.** A target is an `NSURL`, fetched with a `GET`. A 206 gives the size through Content-Range. A 200 uses Content-Length when Content-Encoding is absent or `identity`. The version is a strong ETag, else Last-Modified. A weak ETag (`W/` or `w/`) counts as absent, since it promises equivalent bytes, not the same ones. `VibeHTTPVersionFromHeaders` is the one weak-ETag rule. A subclass changes any of this through the hooks in `HTTPTransferClientInternal.h`. Each hook gets the transfer's own `state` dictionary, which lives across its attempts and which the base never reads. A client of an API keeps its access token and its refresh flag there.

**TRAP: every default request asks for `Accept-Encoding: identity`.** With no such header, `NSURLSession` asks for gzip and inflates the answer. A range's offsets then stop matching the file's bytes.

**Two sessions.** Downloads and probes stream on a delegate session of their own. Ranged reads and a subclass's calls run on the other, so a tag read never queues behind a download's disk writes. The client is the delegate of both. A subclass's call is answered whole by its own handler.

**TRAP: a delegate session retains its delegate until it is invalidated.** A client usually lives as long as the app. Only a session that `useSessionConfiguration:` replaces is invalidated.

**`allowsURL` is asked of every request and every redirect.** It gets the URL that redirected, nil for a request, and the URL to be requested. A request it refuses is never sent. A redirect it refuses completes its task with the 3xx itself, and the transfer fails with `VibeHTTPErrorRefusedURL`.

**A cancel settles a transfer at once when no task is in flight for it** (`cancelTransfer:`). A task is in flight until its completion has reached the delegate. That covers a transfer waiting on the request hook, such as a token refresh, or on a retry's delay. The lane the caller holds is freed now (`files/FileLoading/AGENTS.md`).

**TRAP: a cancel never touches a download's file.** The step that ended the last task may still be reading it. The next step sees the cancel and closes the file. A cancel that closed it raced that step.

**TRAP: a transfer takes its task and enters the delegate's table under one lock** (`startTask:forTransfer:`). A cancel between the two would leave a task whose completion finds no transfer, so the download would never finish. The table is keyed by the task object, because the two sessions number their tasks apart.

**A part file is made once per transfer, at its first accepted response, and only ever appended to.** A descriptor opened on it keeps seeing one inode grow. A resend asks for `Range: bytes=<written>-` and appends. A 200 to that is the whole file, and its prefix is skipped. A 206 starts where its Content-Range says (`VibeHTTPContentRangeStart`). Bytes before the offset are skipped, as a 200's are. One naming no range is taken at its word. A 206 from past the offset would leave a gap. It fails the transfer with `VibeHTTPErrorBadRange`, or starts a kept part over. A dropped connection is resent at most twice in a row with no byte between.

**TRAP: a resend answers whatever version is current.** Every response's version must therefore equal the first one's. A first response with no version is never resumed. A mismatch fails the transfer with `VibeHTTPErrorVersionChanged` and deletes the part. One answer is the same file under another ETag: the first response's size and Last-Modified, both stated (`VibeHTTPIsSameFileUnderAnotherETag`). A CDN's edges can each tag one file with an ETag of their own. The resend then continues, and the client logs it. Only the default metadata carries `lastModified`, so a subclass whose metadata leaves it out never meets this case. A kept part holds only its version, so another ETag starts it over.

**A transfer the link ended keeps its part** (`keepsPartAfterError:`: a cancel, or a connection lost past the resend bound). The part is tagged with its version in the xattr `com.commonwealthrecordings.Vibe.rev`. **TRAP: do not rename it.** Parts already kept on disk carry it, from before the client moved here, and under another name they stop resuming. The next download of that destination continues from its last byte. An answer naming another version, or a 416 because the current version is shorter than the part, starts the transfer over, whole (`restart`). A 416 whose Content-Range total is the part's length, under the part's version, is the whole file. The download completes with the bytes kept. A part with no version tag is replaced. Anything the transfer's own answer ended deletes the part, since the same bytes would only fail again.

**The first response's size is the file's length.** A transfer dropped after its last byte is complete, since `bytes=<size>-` would answer 416. One ending at any other length fails with `VibeHTTPErrorLengthMismatch` and deletes the part.

**A ranged read streams through the delegate and stops at its bytes** (`readTarget:…`). It cancels its own task once it holds them. A server that ignores the range answers 200 with the whole file, and the read keeps only the bytes asked for. It never holds the file in memory. A 206 from another byte than the one asked for fails with `VibeHTTPErrorBadRange`. A failure status goes through `handleFailureStatus:…` like any other. **A probe is a read of the first bytes on the download session** (`probeTarget:length:`). Its completion also carries the response.

**A log line never names a whole link** (`descriptionOfTarget:`). A query or user info can carry a key. The default names a URL by its host and last path component. A subclass names its own targets.

**The error domain is `vibe-libs.http`** (`VibeHTTPErrorDomain`). The client's queues are named `vibe-libs.http.<log name>.<session>`.

## The fake of ranged serving

**`VibeFakeHTTPProtocol` answers a session's requests with no network.** A subclass says what each request gets (`answerForRequest:`): a failure, a redirect, or a response and its body. The engine delivers it. `VibeFakeHTTPRangeStatus` is the one Range rule: 206, 416, or 200. The body goes out in 64 KB pieces after the answer's latency. It can hold, be cut by a lost connection, or be paced. A session takes the fake through `sessionConfiguration`, on the subclass that answers. The client takes that through `useSessionConfiguration:`.

**Two fakes answer through it.** The tests' `HTTPStub` (`Tests/Support`) scripts each answer, on a host of its own per test. `files/ShareLinks`' `VibeFakeHTTP` is the fake web server: a directory that answers as Dropbox, Google Drive, and iCloud would. This piece names no service.

**TRAP: a lost connection waits until the task holds the bytes sent before it.** Sent at once, the failure overtakes them, and the session resends the whole request itself instead of the client's Range resend.

**How the fake builds here.** Its header has no `#if DEBUG`, since no header here may carry one. Its `.m` wraps its whole body in `#if DEBUG`, so a release build compiles an empty object and ships none of it. Only debug-only code calls it. Its delivery queue is `vibe-libs.http.fake`.

## Tests

`Tests/files/HTTP/` holds the client's tests and the rules' tests. They run on macOS in Debug, with the headermap off. The client's tests run over `HTTPStub` (`Tests/Support`), a scripted host per test, over this piece's fake. A wait for what must happen uses `VIBE_TEST_HANG_TIMEOUT`, and a gate the test releases uses `VIBE_TEST_GATE_TIMEOUT`.

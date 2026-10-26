# audio/OutputDevices

What an app plays through, found and described. On the mac it is the HAL's output devices: the list, their names and identifiers, rates, formats, volume, and exclusive use. On iOS it is the audio session and its routes. It knows nothing about a player. It depends only on `core/Common`, for the log macros and the retry scheduler's type. It came from Vibe. None of it reads an app's settings, strings, or types.

There are no shared files. The two halves have nothing in common but their job, since the HAL and `AVAudioSession` share no API.

| File | Owns |
| --- | --- |
| `Mac/AudioDevice` | one output device in a published snapshot, read-only |
| `Mac/AudioDeviceManager` | the device list, its listeners, its snapshot, and finding a saved device |
| `Mac/AudioDeviceEventLog` | the `HAL:` event log, compiled only under `VIBE_VERBOSE_LOGGING` |
| `Mac/CoreAudioUtil` | raw HAL reads and writes, and the bounded read |
| `Mac/CoreAudioUtil+BitPerfect.m` | transport, rate, physical format, volume, hog, and liveness |
| `Mac/CoreAudioUtil+Diagnostics.m` | one device's whole description for a debug report, and the event log's formatter |
| `Mac/CoreAudioUtilInternal.h` | the HAL helpers the three `CoreAudioUtil` files share |
| `Mac/OutputFormatRules.h` | the device decisions, as static inlines: bit-perfect output's format choice and eligibility, and device liveness |
| `iOS/AudioSessionController` | activation, idle release, and the route, interruption, and media-services events, each a delegate verdict |
| `iOS/AudioSessionRecoveryRules.h` | the verdicts, as static inlines |
| `iOS/OutputRouteRules.h` | what a route is, for an indicator and for the verdicts |

`audio/Player` binds its output unit to a device, runs bit-perfect output, and recovers its output on iOS. Those categories read the player's private state, so they sit in its `Mac/` and `iOS/` halves. `audio/Player/AGENTS.md` describes them.

## Mac/: the output devices

### AudioDeviceManager

**A singleton that owns device-change listening.** At init it registers CoreAudio listeners for the default output device and the device list. It keeps them for the process's life, then sweeps. `outputDevices` serves the latest immutable snapshot. It waits at most 250 ms for the first one, so an unavailable `coreaudiod` cannot strand a caller's serial queue. `cachedOutputDevices`, `knowsOutputDeviceIsAbsent:`, and `outputDeviceForId:` never wait, because a player's queue calls them.

**A snapshot is normally published only after every read agrees.** The reads are the device list, the system default, each device's output channels, name, and UID, and the default appearing in the list. A partial result keeps the prior snapshot and takes the two-second retry. So a transient HAL failure cannot look like removal.

**But strictness is bounded, because a persistent failure is not a transient one.** A driver that always fails a property read, a device with an empty name, or a default with no output channels would otherwise keep every device unpublished. After `kMaxIncompleteSweeps` (3) refusals in a row, one sweep publishes what it could read. It omits the devices that failed, and it logs that it did. The list, its size, and the system default have no partial form. They still return nil however many sweeps failed. `AudioDevice.transportType` is an optional refinement that never discards a device.

**TRAP: absence in `outputDevices` is not removal.** It answers `@[]` both for "no output devices exist" and for "no sweep published yet". A decision that treats absence as removal asks `knowsOutputDeviceIsAbsent:` instead. That answers NO until there is a real snapshot, without waiting for one. A caller that falls back to the system default and saves that choice must ask it, or a slow sweep at launch forgets the user's device.

**TRAP: never call `outputDevices` from `_refreshQueue`.** Setup, and the completions its first sweep delivers, run there. A call from inside them waits out the full 250 ms on a setup that cannot finish until it returns.

`refreshOutputDevicesCache` runs only on that serial refresh queue, so an older sweep can never overwrite a newer one. `initWithEnumerator:retryScheduler:` lets a test control the HAL and timer boundaries. `refreshOutputDevicesWithCompletion:` is the shared refresh entry for notifications and tests.

**Observers are told on main in the common run-loop modes**, not with a plain `dispatch_async`. GCD main-queue blocks do not run during menu tracking. This way an open devices menu refreshes on hotplug. Observers (`AudioDeviceManagerObserver`) are held weakly. The manager refreshes before either observer method fires, so a callback reads the new list.

**A saved device is found by its device UID, then its model UID, then its name** (`deviceForUID:modelUID:name:inDevices:`). `resolveOutputDeviceForUID:modelUID:name:completion:` waits for the first successful snapshot without blocking the caller. Its completion runs on the refresh queue.

**TRAP: a class-compliant USB interface's device UID is its USB location, not the unit.** `AppleUSBAudioEngine` builds it from manufacturer, product, and `locationID`. So the same interface has another UID on the next port. `kAudioDevicePropertyModelUID` is the documented, port-independent identifier for the model. It is compared as an opaque token and never parsed. Vendor drivers often key the device UID on a serial, and Bluetooth devices on the MAC address, so for them the UID is already per unit.

### The event log

**With `VIBE_VERBOSE_LOGGING=1`, `AudioDeviceEventLog` writes the `HAL:` log.** It follows published devices, watched device and stream property changes, arrivals and removals, default and alert output changes, and `coreaudiod` restarts. The manager feeds it each published snapshot, except under an injected enumerator.

**TRAP: HAL delivers running and overload notifications synchronously on its IO thread, and a property read there can deadlock its stop.** A delivery queue does not make them asynchronous, because HAL waits for that queue. So the event log's listeners register with a NULL queue. Each copies its addresses and queues its reads on the log's own queue (`listenerForObject:name:queue:`). Playback never waits on that queue.

### CoreAudioUtil

`CoreAudioUtil` is three files. `CoreAudioUtil.m` keeps the bounded read and the device identity reads. Its `+BitPerfect` category holds transport, rate, physical format, volume, and hog. Its `+Diagnostics` category holds the debug report's read and the event log's formatter. All three are declared in `CoreAudioUtil.h`.

**Each read returns whether the HAL answered, apart from its answer.** A successful default read may answer `kAudioObjectUnknown`. A successful UID read may answer nil when that optional property is absent.

**TRAP: a HAL read on a hung device holds its thread up to 30 s.** So a read that a queue cannot do without goes through `performBoundedRead:within:late:`. That is one serial queue of reads, which the caller waits on for a bounded time. A read that is late finishes there on its own, and its `late` block runs after it. While one read is overdue, nothing waits.

**`deviceIsConfirmedDead:` asks the device itself**, not a snapshot that may lag an unplug. A failed read is unknown, never dead (`VibeDeviceIsConfirmedDead`). A false removal would fall back and save that choice.

**TRAP: another process's hog halts a running output unit's IO without stopping it.** The unit reports running and gets no IO cycle until the release. A unit started under the hog plays. So `deviceIsHeldByAnotherProcess:` exists, and a caller refuses its start on that answer.

**TRAP: setting `kAudioDevicePropertyHogMode` ignores the value and toggles ownership.** So `setHogOwnedByThisProcess:` reads first and writes only when the owner has to change. "Owned by this process" is the whole state. A release while another process holds it is already true. `supportsHogModeForDeviceID:` checks that the property exists and is writable. That permits an attempt, not a promise. The owner read back decides success.

`releaseDeviceObligation:attempt:isAbsent:` is a retry loop for a format restore or a hog release. It retries a failure once. A failed attempt keeps the slot unless a published snapshot proves the device gone.

`diagnosticDescriptionOfDeviceID:` is the one read-everything call: formats, declared latency, clock, and exclusive owner. It is for a debug report, and nothing that changes a device reads it. Every read goes through `coreaudiod`, so call it off main.

### Output format rules

`OutputFormatRules.h` holds the decisions, so a test reaches them without a HAL.

- **The rate rule**: exact, else the smallest integer multiple, else untouched. It scans PCM offers carrying every source channel, and continuous ranges. Encoded-only rates cannot hide a usable PCM multiple.
- **The depth rule**: the widest integer depth the device offers, never one below the source's, else the widest float format. Float and lossy sources take the float format first, since what reaches the device is a float32 decode. One depth for every integer source lets a 16-bit and a 24-bit track at one rate share a format.
- **Eligibility is an allowlist of transports** (`VibeBitPerfectDeviceEligible`): built-in, PCI, USB, FireWire, Thunderbolt, HDMI, DisplayPort, AVB, and virtual. Bluetooth, AirPlay, Continuity, the Remote types, aggregates, and Unknown are out, and so is anything Apple adds until argued in. A testing override bypasses the allowlist.

The report these reasons fold into, and when a saved device may bind, are the player's. They read the player's state, and the player is their only caller, so they sit in `audio/Player`'s `Mac/` half.

## iOS/: the audio session

### AudioSessionController

**Main thread only**, except the media-services reset, which is delivered on the notification's thread. The delegate maps each verdict onto its player. The controller never touches an output itself.

**The playback category is activated before every play, never at launch.** It is released with `NotifyOthersOnDeactivation`, so an interrupted podcast gets its resume hint. **It is released once the player's output has stopped, never on a timer of its own.** The release is one rule, `VibeAudioSessionMayDeactivate`, over three facts read when it is asked. A pause or end asked for it, and no `activate` has reclaimed the session since. No interruption is in progress. The delegate says the output is idle (`audioSessionOutputIsIdle:`). It is asked at each edge that can complete it: the request itself, `deactivateIfIdle` at the player's idle edge, and an interruption's Ended with no resume. **TRAP: `setActive:NO` answering NO is not a refusal.** With audio objects running, the session goes inactive anyway and stops them.

Four events, four delegate verdicts:

| Event | Verdict |
| --- | --- |
| Interruption Began / Ended | pause, then resume |
| Route loss (`OldDeviceUnavailable`) | pause |
| Any other route change | classify the output transition, then pause or recover |
| Media services reset | the reset, at notification receipt |

**An interruption whose reason is route-disconnected is a pause and nothing else.** It may have no Ended notification. It sets neither the in-progress flag nor the interruption blocker, so it cannot hold off an idle release. The route loss beside it owns the blocker.

**Was-playing is captured at the interruption's Began edge only.** The route-loss pauses that pile up mid-interruption must not overwrite it, or the resume decides from the wrong state.

**Interruption-ended automatic activation is not user intent.** It checks the route-loss and media-reset blockers before and after the session activation. So unplugging headphones during a call cannot turn the system's `ShouldResume` hint into playback on the speaker. Only an explicit `activate` clears those blockers.

**The route-change notification is the only output trigger.** The controller records whether the last and current outputs are built-in, external, or absent. An external-to-built-in transition is headphone loss and pauses, whatever reason the notification carried. A recorded route loss or media reset blocks recovery until a successful explicit activation. An interruption blocks it until its end or such an activation. Ordinary recoveries are generation-coalesced before main delivery.

**The route pair, its kind and the system's device name, is published on a real change and nowhere else.** `recordOutputRoute:name:` writes both under one lock and reports whether either changed. Each public getter takes the lock separately. Init records without publishing, since the delegate may still be inside its own init. `activate` publishes on change, since a destination picked against an inactive session posts no route notification. **TRAP:** the hop to the delegate is an unconditional `dispatch_async`, not a run-now-if-on-main. `activate` publishes from inside an activation the play path waits on. **Before the first activation the session can report no outputs at all**, which is `None`, a real answer.

### The rules

**The verdicts are decided in a header, not in the controller.** `AudioSessionRecoveryRules.h` is header-only and Foundation-only. It holds:

- `VibeAudioSessionConfigurationActionForRoutes`: recover on the new route, park because the output is disappearing, or ignore while an interruption, route loss, or reset owns the output.
- `VibeAudioSessionMayDeliverConfigurationRecovery`: a later route change coalesces an earlier ordinary recovery, and any safety verdict received before main delivery blocks it.
- `VibeAudioSessionMayAutomaticallyResume`: interruption-ended is a system suggestion, not a fresh user play.

Existing interruption, route-loss, and reset ownership wins in all three, which makes the rules fail closed.

**One scan classifies a route, and two things read the result.** `OutputRouteRules.h` holds the fine kind an indicator draws: speaker, receiver, wired, Bluetooth, AirPlay, CarPlay, other, or none. It also holds the fold onto the coarse none, built-in, or external kind the verdicts use. Deriving one from the other stops a new port from being external to the indicator and built-in to the headphones rule. The `portType` mapping stays in `AudioSessionController.m`, since the `AVAudioSessionPort*` constants are AVFoundation's. **A Bluetooth route's glyph is guessed from its device name**, because no public API says what the device is. An unrecognized name draws the generic glyph.

## Tests

`Tests/audio/OutputDevices/` holds the tests of the manager and the rules. They run on macOS, with the headermap off. The iOS half's rules are Foundation-only, so their tests run on macOS too. The iOS target builds the iOS half. No test assumes a particular output device.

- `Mac/AudioDeviceManagerTests` runs the manager with injected enumeration and retry scheduling, and no HAL registration: snapshot publication, saved-device lookups, and the recovery retry. It also runs the event log's listener, the bounded read, and the release loop with controlled attempts.
- `Mac/OutputFormatRulesTests` covers the rate and depth rules, eligibility, and device liveness.
- `iOS/AudioSessionRecoveryRulesTests` and `iOS/OutputRouteRulesTests` cover the two rule headers.

The session controller has no tests here. Interruptions, route changes, and a media-services reset need a real device. The manager's HAL listeners, a device's property reads, and hardware settlement stay live tests in Vibe. **A bounded wait is a hang guard or a gate.** A wait for what must happen uses `VIBE_TEST_HANG_TIMEOUT`. A gate the test releases itself uses `VIBE_TEST_GATE_TIMEOUT`, which outlasts the guards it holds across. The test bundle defines both.

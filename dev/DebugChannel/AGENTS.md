# dev/DebugChannel

The transport of a debug command channel: a script drives and inspects a running debug build of an app. A command is a file. The client writes one into the app's temporary directory and posts a Darwin notification. The app drains it, runs the verb, and writes a reply file back. **It holds no verbs.** The app owns every verb, its tables, its dispatcher, and its client. It came from Vibe. It depends on `core/Common` for the log macros, and on nothing else. It builds on both platforms.

| File | Owns |
| --- | --- |
| `DebugWireFormat.{h,m}` | the wire: the notification name and the command, reply, and screenshot paths, each derived from the channel's name, the JSON reply serialization, and the two number parsers a verb's arguments share |
| `DebugChannel.{h,m}` | the drain: payload validation, reply writing, the stale-file sweep, and the wake-up listeners. The app supplies one executor block. |
| `DebugCommandDispatch.{h,m}` | a command table's shape, the lookup over it, the unknown-command reply, and the argument helpers. It never invokes a handler. |

## It compiles in every configuration and ships in none

**An app lists the template in every configuration.** Each `.m` wraps its body in `#if DEBUG`, so a release build compiles each to an empty object. The headers carry no `#if DEBUG`, since no header here may. So a call from release code compiles and then fails to link. An app keeps every caller under its own `#if DEBUG`.

`DebugChannelTests` defines `DEBUG` in every configuration, so the analyzer's Release build reaches the code. `DebugChannel-iOS` does too, so the iOS watcher compiles.

## The app's side

- **The name and the executor.** `VibeInstallDebugCommandChannel` takes the channel's name and one block. The name is the app's bundle identifier, or a name of its own. There is no default. The block is called on main with the command's arguments and id. It returns the JSON reply, or nil when the verb replies later through `VibeWriteDebugResponse`. Call it once, at launch. A second call replaces the name and the executor, and adds a second listener. `VibeDebugChannelName()` answers the name, for a verb that names a file on the wire.
- **The tables.** A table is an array of specs built by `VibeDebugCmd`: a usage string, the client's wait, and a handler. The verb is the usage's first word. The app's dispatcher looks the verb up with `VibeDebugSpecForVerb` and calls the handler with its own controller. `controller` is `id`, so each table names its own type. The handler is never handed nil: the dispatcher answers an error first while the app has no controller yet.
- **The command list.** `VibeDebugUnknownCommandReply` lists every usage of the tables it is given, plus the verbs the app's client runs in its own process. It is the authoritative list, so a doc never repeats it.
- **The client.** The piece has none. On the mac, an app's binary can be its own client: it writes the command file, posts the notification, and polls for the reply. It passes the same name to the wire's functions. The client reads a verb's wait from the same table. On iOS a host script writes the file straight into the simulator container's tmp, a plain host directory.

## The contract

- **Every reply is exactly one JSON object.** An error is `{"error": "…"}`. `VibeJSONString` sorts the keys. `VibeErrorJSON` formats the message.
- **Arguments arrive as an array, one token per client argv entry, never re-tokenized.** So a path with spaces is safe. `VibeRestArgument` rejoins the rest with single spaces, so an unquoted title still works.
- **A malformed payload still gets an error reply** whenever its id is recoverable. A silent drop would leave the client polling out its window.
- **Each command has its own files**, named by its id. One fixed path loses a command when two clients write back to back.
- **One wake-up drains every pending file**, in name order. `notify_post` coalesces back-to-back posts.
- **The command is logged before the verb runs**, so a verb that hangs or crashes has still logged it. Every reply is logged, trimmed to bound the log.

**TRAP: a verb that spins the main run loop re-enters the drain.** The drain runs on main, and a spinning verb services the next wake-up. A guard defers that pass until the outer command finishes, so a second client's command never runs inside the first.

**TRAP: the sweep at install deletes every command, reply, and screenshot file of the channel's name.** A command left by a dead client would otherwise run at the next launch and could change files. So a client must not write before the app has installed the channel. A command written too early is swept and never answered.

**TRAP: on iOS a host's `notifyutil` posts into the mac's namespace, not the simulator's.** So on iOS the channel also watches the tmp directory. The watcher fires on every change there, the channel's own reply writes included. A spurious drain costs one directory read. **The host must rename a complete command file into place.** A file read while it is still being written is deleted unexecuted.

**An app's channel is its own.** Every name on the wire derives from the channel's name. The notification is `<name>.debug.command`. The files are `<name>.debug-command-<id>.json`, `<name>.debug-response-<id>.txt`, and `<name>.debug-screenshot-<id>.png`. So one app's post wakes only its own channel. Two unsandboxed apps on one Mac share `$TMPDIR`, and each drains and sweeps only its own files. A sandboxed app's temporary directory is its own container's anyway. Two instances of one app share one name, so either may answer a command.

## Tests

`Tests/dev/DebugChannel/` holds `DebugChannelTests`. They cover the wire's paths, replies, and parsers, the table lookup and the unknown-command reply, the argument helpers, and the drain. A drain test writes a command file as a client does, posts the notification, and reads the reply: a synchronous verb, an asynchronous one, and two malformed payloads. Another channel's command in the same directory is neither run nor answered. The minimal consumer installs the channel under its own name and answers one registered command from its own table.

Vibe's verbs and their dispatchers are live-app checks, through the vibe-debug skill there.

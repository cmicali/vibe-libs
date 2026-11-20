#!/usr/bin/env python3
"""Builds and runs the parsers' fuzz targets (Tests/Fuzz/AGENTS.md).

  fuzz.py list               the targets
  fuzz.py build  [targets]   libFuzzer builds, under Homebrew's clang
  fuzz.py run    [targets]   each built target for --seconds, one at a time
  fuzz.py replay [targets]   Xcode's clang, each target over its seeds and
                             regressions once
  fuzz.py triage [targets]   each saved artifact replayed once, with whether
                             it still fails and its peak memory

Every build is under Address Sanitizer and Undefined Behavior Sanitizer. A
target compiles its pieces' sources, search paths, and flags as their
templates in vibe-libs.yml give them. No target given means every target.
Output goes under build/fuzz/, which git ignores.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FUZZ = os.path.join(ROOT, "Tests", "Fuzz")
OUT = os.path.join(ROOT, "build", "fuzz")
LLVM = os.environ.get("FUZZ_LLVM", "/opt/homebrew/opt/llvm/bin")


def target(template, main, extension=None, seeds=None, dictionary=None):
    return {"template": template, "main": main,
            "defines": [f'FUZZ_EXTENSION="{extension}"'] if extension else [],
            "seeds": seeds, "dict": dictionary}


# Each target names its piece's template. The build takes the templates it lists.
TARGETS = {}
for ext in ["flac", "mp3", "m4a", "wav", "aiff", "ogg", "opus", "wv", "ape", "dsf"]:
    TARGETS[f"tags-{ext}"] = target("VibeLibsMetadata", "FuzzTags.mm", ext, f"tags-{ext}", "tags.dict")
for ext in ["flac", "mp3", "wav", "aiff", "ogg", "wv", "ape", "dsf"]:
    TARGETS[f"decode-{ext}"] = target("VibeLibsDecode", "FuzzDecode.m", ext, f"tags-{ext}", "tags.dict")
TARGETS["cue"] = target("VibeLibsPlaylists", "FuzzCue.m", dictionary="cue.dict")
TARGETS["m3u"] = target("VibeLibsPlaylists", "FuzzM3U.m", dictionary="m3u.dict")
TARGETS["flac-cue"] = target("VibeLibsPlaylists", "FuzzFLACCue.m", dictionary="flac-cue.dict")
TARGETS["art"] = target("VibeLibsGraphics", "FuzzArt.m")

# Xcode links these through modules, so no template names them.
FRAMEWORKS = ["Foundation", "AppKit", "AVFoundation", "AudioToolbox", "CoreAudio", "CoreMedia", "CoreServices",
              "ImageIO", "CoreGraphics", "Accelerate", "UniformTypeIdentifiers", "QuartzCore"]
SANITIZE = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
COMMON = ["-g", "-O1", "-fno-omit-frame-pointer", *SANITIZE, "-mmacosx-version-min=13.0", "-DDEBUG=1",
          "-fobjc-arc", "-Wno-everything"]
# A huge allocation returns null, as malloc may in an app, so only a parser
# that then uses it is a finding. macOS has no leak detection on arm64.
ENV = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:allocator_may_return_null=1", UBSAN_OPTIONS="print_stacktrace=1")


def run_text(*command):
    return subprocess.check_output(command, text=True).strip()


def templates():
    dump = subprocess.run(["xcodegen", "dump", "--type", "json", "--spec", "project.yml"],
                          capture_output=True, text=True, cwd=ROOT)
    if dump.returncode != 0:
        sys.exit(f"fuzz: xcodegen dump failed:\n{dump.stderr}")
    return json.loads(dump.stdout)["targetTemplates"]


def glob_regex(pattern):
    out = ""
    for part in re.split(r"(\*\*/|\*\*|\*)", pattern):
        out += {"**/": "(?:.*/)?", "**": ".*", "*": "[^/]*"}.get(part, re.escape(part))
    return re.compile(out + "$")


def expand(entry):
    """A template's source entry as (file, flags) pairs, as XcodeGen reads it."""
    entry = {"path": entry} if isinstance(entry, str) else entry
    excludes = [glob_regex(e.replace("${excludedPlatform}", "iOS")) for e in entry.get("excludes", [])]
    includes = [glob_regex(i) for i in entry.get("includes", [])]
    base = os.path.join(ROOT, entry["path"])
    if os.path.isfile(base):
        return [(base, entry.get("compilerFlags", []))]
    out = []
    for folder, _, names in os.walk(base):
        for name in names:
            file = os.path.join(folder, name)
            relative = os.path.relpath(file, base)
            if (file.endswith((".c", ".cpp", ".m", ".mm")) and not any(e.match(relative) for e in excludes)
                    and (not includes or any(i.match(relative) for i in includes))):
                out.append((file, entry.get("compilerFlags", [])))
    return sorted(out)


def listed(spec, name):
    """A template and every template it lists, each once."""
    order = []

    def visit(n):
        if n not in order:
            order.append(n)
            for child in spec[n].get("templates", []):
                visit(child)

    visit(name)
    return order


def libraries(spec, name):
    """The libraries a template and those it lists link by flag, as DiskCache links SQLite."""
    out = []
    for n in listed(spec, name):
        flags = spec[n].get("settings", {}).get("base", {}).get("OTHER_LDFLAGS", [])
        for flag in [flags] if isinstance(flags, str) else flags:
            if flag.startswith("-l") and flag not in out:
                out.append(flag)
    return out


def resolve(spec, name):
    """The sources with their flags, and the search paths, of a template and those it lists."""
    sources, includes = {}, []
    for n in listed(spec, name):
        for entry in spec[n].get("sources", []):
            for file, flags in expand(entry):
                # A narrower entry's flags win over a folder's.
                if file not in sources or flags:
                    sources[file] = flags
        paths = spec[n].get("settings", {}).get("base", {}).get("HEADER_SEARCH_PATHS", [])
        for p in [paths] if isinstance(paths, str) else paths:
            if p.startswith("$(VIBE_LIBS_ROOT)/"):
                includes.append(os.path.join(ROOT, p[len("$(VIBE_LIBS_ROOT)/"):].strip('"')))
    return sources, includes


def language(path):
    return {".cpp": ["-x", "c++", "-std=c++17"], ".mm": ["-x", "objective-c++", "-std=c++17"],
            ".m": ["-x", "objective-c"]}.get(os.path.splitext(path)[1], ["-x", "c"])


def stale(obj, dep):
    """Whether an object is older than its source or any header it read."""
    if not os.path.exists(obj) or not os.path.exists(dep):
        return True
    built = os.path.getmtime(obj)
    text = open(dep).read().replace("\\\n", " ")
    inputs = text.split(":", 1)[1].split() if ":" in text else []
    return any(not os.path.exists(p) or os.path.getmtime(p) > built for p in inputs)


def compile_one(compiler, flags, source, obj):
    dep = obj[:-2] + ".d"
    if not stale(obj, dep):
        return None
    os.makedirs(os.path.dirname(obj), exist_ok=True)
    result = subprocess.run([compiler, *flags, *language(source), "-MMD", "-MF", dep, "-c", source, "-o", obj],
                            capture_output=True, text=True)
    return f"{os.path.relpath(source, ROOT)}:\n{result.stderr}" if result.returncode else None


def build(names, fuzzer, jobs):
    if fuzzer:
        compiler = os.path.join(LLVM, "clang++")
        if not os.path.exists(compiler):
            sys.exit(f"fuzz: no {compiler}. Run `brew install llvm`, or set FUZZ_LLVM to its bin directory.")
    else:
        compiler = run_text("xcrun", "-f", "clang++")
    kind = "libfuzzer" if fuzzer else "replay"
    sdk = run_text("xcrun", "--show-sdk-path")
    base = ["-isysroot", sdk, *COMMON, *(["-fsanitize=fuzzer-no-link"] if fuzzer else [])]
    version = run_text(compiler, "--version")
    spec = templates()
    built = {}
    for name in names:
        info = TARGETS[name]
        sources, includes = resolve(spec, info["template"])
        flags = base + [f"-I{d}" for d in includes] + [f"-I{os.path.join(FUZZ, 'Targets')}"]
        # Keyed by all that changes an object but the target's own defines,
        # so the targets of one template share their objects.
        key = hashlib.sha1(json.dumps([compiler, version, flags, sorted(sources.items())]).encode()).hexdigest()[:10]
        objects = os.path.join(OUT, kind, "obj", key)
        work = [(flags + extra, s, os.path.join(objects, os.path.relpath(s, ROOT) + ".o"))
                for s, extra in sources.items()]
        main = os.path.join(FUZZ, "Targets", info["main"])
        work.append((flags + [f"-D{d}" for d in info["defines"]], main,
                     os.path.join(objects, "targets", name, info["main"] + ".o")))
        if not fuzzer:
            work.append((base, os.path.join(FUZZ, "Targets", "FuzzReplayMain.c"),
                         os.path.join(objects, "FuzzReplayMain.c.o")))
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            errors = [e for e in pool.map(lambda w: compile_one(compiler, *w), work) if e]
        if errors:
            sys.exit(f"fuzz: {name} failed to compile:\n" + "\n".join(errors))
        binary = os.path.join(OUT, kind, "bin", name)
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        link = [compiler, "-isysroot", sdk, *SANITIZE, *(["-fsanitize=fuzzer"] if fuzzer else []),
                "-mmacosx-version-min=13.0", *[o for _, _, o in work], *libraries(spec, info["template"]),
                "-o", binary]
        for framework in FRAMEWORKS:
            link += ["-framework", framework]
        result = subprocess.run(link, capture_output=True, text=True)
        if result.returncode:
            sys.exit(f"fuzz: {name} failed to link:\n{result.stderr}")
        print(f"fuzz: built {os.path.relpath(binary, ROOT)}", flush=True)
        built[name] = binary
    return built


def inputs(name):
    folders = [os.path.join(FUZZ, "Seeds", TARGETS[name]["seeds"] or name), os.path.join(FUZZ, "Regressions", name)]
    return [f for f in folders if os.path.isdir(f)]


def run(names, seconds, jobs):
    binaries = build(names, True, jobs)
    for name in names:
        info = TARGETS[name]
        corpus, crashes, logs = (os.path.join(OUT, d, name) for d in ("corpus", "crashes", "logs"))
        for d in (corpus, crashes, logs):
            os.makedirs(d, exist_ok=True)
        command = [binaries[name], corpus, *inputs(name), f"-fork={jobs}", f"-max_total_time={seconds}",
                   "-ignore_crashes=1", "-ignore_ooms=1", "-ignore_timeouts=1", "-timeout=10",
                   "-rss_limit_mb=2048", "-malloc_limit_mb=1024", "-max_len=65536",
                   f"-artifact_prefix={crashes}/", "-print_final_stats=1"]
        if info["dict"]:
            command.append(f"-dict={os.path.join(FUZZ, 'Dictionaries', info['dict'])}")
        log = os.path.join(logs, time.strftime("%Y%m%d-%H%M%S") + ".log")
        print(f"fuzz: {name} for {seconds} s on {jobs} workers, log {os.path.relpath(log, ROOT)}", flush=True)
        with open(log, "w") as out:
            subprocess.run(command, stdout=out, stderr=subprocess.STDOUT, cwd=logs, env=ENV)
        found = sorted(f for f in os.listdir(crashes) if not f.startswith("."))
        print(f"fuzz: {name} done, {len(found)} artifacts in {os.path.relpath(crashes, ROOT)}", flush=True)


def reached(names, since):
    """The targets a change since that commit reaches: their pieces, inputs, or the harness."""
    changed = run_text("git", "-C", ROOT, "diff", "--name-only", since).splitlines()
    shared = ("Tests/Fuzz/Targets/", "Tests/Fuzz/Dictionaries/", "scripts/fuzz/", "project.yml", "vibe-libs.yml")
    if any(p.startswith(shared) for p in changed):
        return names
    spec = templates()
    out = []
    for name in names:
        sources, includes = resolve(spec, TARGETS[name]["template"])
        folders = {os.path.dirname(s) for s in sources} | set(includes) | set(inputs(name))
        if any(os.path.dirname(os.path.join(ROOT, p)) in folders for p in changed):
            out.append(name)
    return out


def replay(names, jobs, since):
    if since:
        names = reached(names, since)
        if not names:
            print(f"fuzz: no target reaches a change since {since}")
            return
    binaries = build(names, False, jobs)
    failed = []
    for name in names:
        result = subprocess.run([binaries[name], *inputs(name)], capture_output=True, text=True, env=ENV)
        last = (result.stderr.strip().splitlines() or [""])[-1]
        if result.returncode:
            failed.append(name)
            print(result.stderr[-6000:])
        print(f"fuzz: {name} {'FAILED' if result.returncode else 'OK'}: {last}", flush=True)
    if failed:
        sys.exit(f"fuzz: replay failed for {', '.join(failed)}")


def peak(command):
    """A command's exit status, its peak resident memory in MB, and its report's first line."""
    with tempfile.TemporaryFile("w+") as err:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=err, env=ENV)
        timer = threading.Timer(TRIAGE_SECONDS, process.kill)
        timer.start()
        _, status, usage = os.wait4(process.pid, 0)
        timer.cancel()
        err.seek(0)
        lines = [l.strip() for l in err if "ERROR:" in l or "runtime error:" in l]
    return os.waitstatus_to_exitcode(status), usage.ru_maxrss / 2**20, (lines or [""])[0]


# An oom- artifact holds memory only when its replay reaches this much: the
# malloc limit also stops an allocation Apple's code makes and never touches.
OOM_MB = 1024
# A replay that runs longer is killed, which also bounds what it can hold.
TRIAGE_SECONDS = 60


def triage(names, jobs):
    named = [n for n in names if os.path.isdir(os.path.join(OUT, "crashes", n))]
    if not named:
        print(f"fuzz: no artifacts under {os.path.relpath(os.path.join(OUT, 'crashes'), ROOT)}")
        return
    binaries = build(named, False, jobs)
    for name in named:
        folder = os.path.join(OUT, "crashes", name)
        for artifact in sorted(f for f in os.listdir(folder) if not f.startswith(".")):
            status, megabytes, report = peak([binaries[name], os.path.join(folder, artifact)])
            verdict = "fails" if status else "passes"
            if artifact.startswith("oom-"):
                verdict += ", holds memory" if megabytes >= OOM_MB else ", no growth"
            print(f"{name} {artifact}: {verdict}, {megabytes:.0f} MB {report}".rstrip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["build", "run", "replay", "triage", "list"])
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--since", default="", help="replay only the targets a change since this commit reaches")
    args = parser.parse_args()
    names = args.targets or list(TARGETS)
    unknown = [n for n in names if n not in TARGETS]
    if unknown:
        sys.exit(f"fuzz: no target {', '.join(unknown)}; the targets are {', '.join(TARGETS)}")
    if args.command == "list":
        print("\n".join(TARGETS))
    elif args.command == "build":
        build(names, True, args.jobs)
    elif args.command == "run":
        run(names, args.seconds, args.jobs)
    elif args.command == "triage":
        triage(names, args.jobs)
    else:
        replay(names, args.jobs, args.since)


if __name__ == "__main__":
    main()

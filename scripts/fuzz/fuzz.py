#!/usr/bin/env python3
"""Builds and runs the parsers' fuzz targets (Tests/Fuzz/AGENTS.md).

  fuzz.py build  [targets]   libFuzzer builds, under Homebrew's clang
  fuzz.py run    [targets]   each built target for --seconds, one at a time
  fuzz.py replay [targets]   Xcode's clang, each target over its seeds and
                             regressions once, under the same sanitizers

Every build is under Address Sanitizer and Undefined Behavior Sanitizer. No
target given means every target. Output goes under build/fuzz/, which git
ignores: each target's grown corpus, its crashes, and its logs.
"""

import argparse
import concurrent.futures
import glob
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FUZZ = os.path.join(ROOT, "Tests", "Fuzz")
OUT = os.path.join(ROOT, "build", "fuzz")
LLVM = os.environ.get("FUZZ_LLVM", "/opt/homebrew/opt/llvm/bin")

TAGLIB_DIRS = ["", "toolkit", "mpeg", "mpeg/id3v1", "mpeg/id3v2", "mpeg/id3v2/frames", "ape", "mp4", "flac",
               "riff", "riff/aiff", "riff/wav", "ogg", "ogg/vorbis", "ogg/opus"]

# Each family's sources and searched directories, from its pieces' templates.
TAGS = {
    "sources": ["third_party/taglib/**/*.cpp", "media/Tags/*.mm", "media/Metadata/NSString+CPPStrings.mm",
                "audio/AudioTypes/*.m"],
    "includes": [f"third_party/taglib/{d}".rstrip("/") for d in TAGLIB_DIRS]
                + ["media/Tags", "media/Metadata", "audio/AudioTypes", "core/Common"],
    "frameworks": ["Foundation", "AppKit", "AudioToolbox"],
}
PLAYLISTS = {
    "sources": ["media/Playlists/*.m", "audio/AudioTypes/*.m", "core/Common/FilePaths.m"],
    "includes": ["media/Playlists", "audio/AudioTypes", "core/Common"],
    "frameworks": ["Foundation", "AppKit", "AudioToolbox"],
}
GRAPHICS = {
    "sources": ["core/Graphics/*.m", "core/Graphics/Mac/*.m"],
    "includes": ["core/Graphics", "core/Graphics/Mac", "core/Common"],
    "frameworks": ["Foundation", "AppKit", "ImageIO", "CoreGraphics", "Accelerate", "UniformTypeIdentifiers"],
}

TAG_EXTENSIONS = ["flac", "mp3", "m4a", "wav", "aiff", "ogg", "opus"]

TARGETS = {f"tags-{ext}": dict(TAGS, main="FuzzTags.mm", defines=[f'FUZZ_EXTENSION="{ext}"'], dict="tags.dict")
           for ext in TAG_EXTENSIONS}
TARGETS["cue"] = dict(PLAYLISTS, main="FuzzCue.m", defines=[], dict="cue.dict")
TARGETS["m3u"] = dict(PLAYLISTS, main="FuzzM3U.m", defines=[], dict="m3u.dict")
TARGETS["flac-cue"] = dict(PLAYLISTS, main="FuzzFLACCue.m", defines=[], dict="flac-cue.dict")
TARGETS["art"] = dict(GRAPHICS, main="FuzzArt.m", defines=[], dict=None)

SANITIZERS = "-fsanitize=address,undefined"
# UBSan's report is a finding only if it stops the run.
COMMON = ["-g", "-O1", "-fno-omit-frame-pointer", SANITIZERS, "-fno-sanitize-recover=all",
          "-mmacosx-version-min=13.0", "-DDEBUG=1", "-Wno-everything"]


def sdk():
    return subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()


def toolchain(fuzzer):
    if fuzzer:
        cc, cxx = os.path.join(LLVM, "clang"), os.path.join(LLVM, "clang++")
        if not os.path.exists(cc):
            sys.exit(f"fuzz: no {cc}. Run `brew install llvm`, or set FUZZ_LLVM to its bin directory.")
        return cc, cxx
    return (subprocess.check_output(["xcrun", "-f", "clang"], text=True).strip(),
            subprocess.check_output(["xcrun", "-f", "clang++"], text=True).strip())


def language(path):
    if path.endswith(".cpp"):
        return ["-x", "c++", "-std=c++17"]
    if path.endswith(".mm"):
        return ["-x", "objective-c++", "-std=c++17", "-fobjc-arc"]
    if path.endswith(".m"):
        return ["-x", "objective-c", "-fobjc-arc"]
    return ["-x", "c"]


def sources_of(spec):
    found = []
    for pattern in spec["sources"]:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True)):
            if "/iOS/" not in path and path not in found:
                found.append(path)
    return found


def stale(obj, dep):
    """Whether an object is older than its source or any header it read."""
    if not os.path.exists(obj) or not os.path.exists(dep):
        return True
    built = os.path.getmtime(obj)
    text = open(dep).read().replace("\\\n", " ")
    inputs = text.split(":", 1)[1].split() if ":" in text else []
    return any(not os.path.exists(p) or os.path.getmtime(p) > built for p in inputs)


def compile_one(cc, cxx, flags, source, obj):
    dep = obj[:-2] + ".d"
    if not stale(obj, dep):
        return None
    os.makedirs(os.path.dirname(obj), exist_ok=True)
    compiler = cc if source.endswith((".m", ".c")) else cxx
    command = [compiler, *flags, *language(source), "-MMD", "-MF", dep, "-c", source, "-o", obj]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        return f"{os.path.relpath(source, ROOT)}:\n{result.stderr}"
    return None


def build(names, fuzzer, jobs):
    cc, cxx = toolchain(fuzzer)
    kind = "libfuzzer" if fuzzer else "replay"
    objects_dir = os.path.join(OUT, kind, "obj")
    instrument = ["-fsanitize=fuzzer-no-link"] if fuzzer else []
    base = ["-isysroot", sdk(), *COMMON, *instrument]
    built = {}
    for name in names:
        spec = TARGETS[name]
        flags = base + [f"-I{os.path.join(ROOT, d)}" for d in spec["includes"]]
        # A target's own defines change only its main, so the shared objects
        # are built once for every target.
        work = [(s, os.path.join(objects_dir, os.path.relpath(s, ROOT) + ".o")) for s in sources_of(spec)]
        main = os.path.join(FUZZ, "Targets", spec["main"])
        main_obj = os.path.join(objects_dir, "targets", name, spec["main"] + ".o")
        jobs_list = [(flags, s, o) for s, o in work] + [(flags + [f"-D{d}" for d in spec["defines"]], main, main_obj)]
        if not fuzzer:
            driver = os.path.join(FUZZ, "Targets", "FuzzReplayMain.c")
            jobs_list.append((base, driver, os.path.join(objects_dir, "FuzzReplayMain.c.o")))
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            errors = [e for e in pool.map(lambda j: compile_one(cc, cxx, *j), jobs_list) if e]
        if errors:
            sys.exit(f"fuzz: {name} failed to compile:\n" + "\n".join(errors))
        binary = os.path.join(OUT, kind, "bin", name)
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        link = [cxx, "-isysroot", sdk(), SANITIZERS, *(["-fsanitize=fuzzer"] if fuzzer else []),
                "-mmacosx-version-min=13.0", *[o for _, _, o in jobs_list], "-o", binary]
        for framework in spec["frameworks"]:
            link += ["-framework", framework]
        result = subprocess.run(link, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"fuzz: {name} failed to link:\n{result.stderr}")
        print(f"fuzz: built {os.path.relpath(binary, ROOT)}")
        built[name] = binary
    return built


def seeds(name):
    return os.path.join(FUZZ, "Seeds", name)


def regressions(name):
    return os.path.join(FUZZ, "Regressions", name)


def run(names, seconds, jobs):
    binaries = build(names, True, jobs)
    for name in names:
        spec = TARGETS[name]
        corpus = os.path.join(OUT, "corpus", name)
        crashes = os.path.join(OUT, "crashes", name)
        logs = os.path.join(OUT, "logs", name)
        for d in (corpus, crashes, logs):
            os.makedirs(d, exist_ok=True)
        command = [binaries[name], corpus, *[d for d in (seeds(name), regressions(name)) if os.path.isdir(d)],
                   f"-fork={jobs}", f"-max_total_time={seconds}", "-ignore_crashes=1", "-ignore_ooms=1",
                   "-ignore_timeouts=1", "-timeout=10", "-rss_limit_mb=2048", "-max_len=65536",
                   f"-artifact_prefix={crashes}/", "-print_final_stats=1"]
        if spec["dict"]:
            command.append(f"-dict={os.path.join(FUZZ, 'Dictionaries', spec['dict'])}")
        log = os.path.join(logs, time.strftime("%Y%m%d-%H%M%S") + ".log")
        print(f"fuzz: {name} for {seconds} s on {jobs} workers, log {os.path.relpath(log, ROOT)}", flush=True)
        env = dict(os.environ, ASAN_OPTIONS="abort_on_error=0:detect_leaks=0:allocator_may_return_null=1",
                   UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1")
        with open(log, "w") as out:
            subprocess.run(command, stdout=out, stderr=subprocess.STDOUT, cwd=logs, env=env)
        found = sorted(f for f in os.listdir(crashes) if not f.startswith("."))
        print(f"fuzz: {name} done, {len(found)} artifacts in {os.path.relpath(crashes, ROOT)}", flush=True)


def replay(names, jobs):
    binaries = build(names, False, jobs)
    failed = []
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:allocator_may_return_null=1",
               UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1")
    for name in names:
        inputs = [d for d in (seeds(name), regressions(name)) if os.path.isdir(d)]
        result = subprocess.run([binaries[name], *inputs], capture_output=True, text=True, env=env)
        last = result.stderr.strip().splitlines()[-1:] or [""]
        if result.returncode != 0:
            failed.append(name)
            print(result.stderr[-6000:])
        print(f"fuzz: {name} {'FAILED' if result.returncode else 'OK'}: {last[0]}")
    if failed:
        sys.exit(f"fuzz: replay failed for {', '.join(failed)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["build", "run", "replay", "list"])
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--seconds", type=int, default=int(os.environ.get("FUZZ_SECONDS", "600")))
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("FUZZ_JOBS", "4")))
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
    else:
        replay(names, args.jobs)


if __name__ == "__main__":
    main()

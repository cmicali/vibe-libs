"""Prints the targets a build takes, one per line.

Usage: python3 -I scripts/checks/targets.py [--ios] [--since REV] [--shard K/N] [--scheme NAME]

By default it prints the macOS test bundles the vibe-libs scheme tests. With
--ios it prints the iOS targets the scheme builds instead.

With --since it keeps only the targets a change since REV can reach. A target
reaches every file under its sources and frameworks, its templates' included,
and under its own header search paths. So a change to a piece reaches every
piece that lists it. A Markdown file, LICENSE, or a tools/ piece reaches no
target. Any other file outside every target, such as a spec, the Makefile, or
a script, reaches them all. Uncommitted and untracked files count too.

With --shard it prints the Kth of N shards. Each target lands in exactly one
shard. A target weighs the source files it compiles, its templates' and its
own, since every target compiles its whole stack again. The heaviest go
first, each to the lightest shard, so a new piece rebalances the shards by
itself. A shard may be empty.

With --scheme it also writes a copy of the generated vibe-libs scheme, named
NAME, that builds and tests only the targets it prints. Run it after
`make project`.

TRAP: xcodebuild's -only-testing picks the tests a scheme runs, not the
targets it builds. A build for testing with it still builds every bundle.
"""
import argparse
import fnmatch
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

SOURCE = (".c", ".cc", ".cpp", ".m", ".mm")
# Files no build reads. check-pieces and the strings test run on every change.
BUILDS_NOTHING = ["*.md", "LICENSE", "tools/*", "Tests/tools/*"]
ROOTS = ("$(SRCROOT)/", "$(VIBE_LIBS_ROOT)/")

parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
parser.add_argument("--ios", action="store_true")
parser.add_argument("--since")
parser.add_argument("--shard")
parser.add_argument("--scheme")
args = parser.parse_args()

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
dump = subprocess.run(["xcodegen", "dump", "--type", "json", "--spec", "project.yml"],
                      capture_output=True, text=True)
if dump.returncode != 0:
    sys.exit(f"xcodegen dump failed:\n{dump.stderr}")
spec = json.loads(dump.stdout)
templates = spec.get("targetTemplates", {})
targets = spec.get("targets", {})
scheme = spec["schemes"]["vibe-libs"]


def name_of(entry):
    return entry if isinstance(entry, str) else entry.get("name", "")


def inside(path, directory):
    path, directory = os.path.normpath(path), os.path.normpath(directory)
    return path == directory or path.startswith(directory + os.sep)


def stack(target):
    """The target and every template it pulls in, each a spec dictionary."""
    seen, todo = set(), list(targets[target].get("templates", []))
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo += templates.get(name, {}).get("templates", [])
    return [targets[target]] + [templates[t] for t in sorted(seen) if t in templates]


def source_paths(entry):
    for source in entry.get("sources", []):
        yield source if isinstance(source, str) else source.get("path", "")


def reads(target):
    """Every file and directory the target's build can read."""
    paths = []
    for entry in stack(target):
        for path in source_paths(entry):
            # A lone source file includes the headers beside it.
            paths.append(path if os.path.isdir(path) else os.path.dirname(path))
        for dependency in entry.get("dependencies", []):
            if "framework" in dependency:
                paths.append(dependency["framework"])
    # A template searches only inside its piece, as check-pieces holds, so
    # only the target's own search paths reach further.
    found = targets[target].get("settings", {}).get("base", {}).get("HEADER_SEARCH_PATHS", [])
    for path in [found] if isinstance(found, str) else found:
        path = path.strip('"')
        for root in ROOTS:
            if path.startswith(root):
                paths.append(path[len(root):])
    return paths


def files(target):
    n = 0
    for entry in stack(target):
        for path in source_paths(entry):
            if os.path.isfile(path):
                n += path.endswith(SOURCE)
            for dirpath, dirs, names in os.walk(path):
                # A macOS target excludes every iOS/ half.
                dirs[:] = [d for d in dirs if d != "iOS"]
                n += sum(1 for f in names if f.endswith(SOURCE))
    return n


def write_scheme(name, keep):
    schemes = "vibe-libs.xcodeproj/xcshareddata/xcschemes"
    tree = ET.parse(f"{schemes}/vibe-libs.xcscheme")
    for parent_tag, child_tag in (("BuildActionEntries", "BuildActionEntry"), ("Testables", "TestableReference")):
        for parent in tree.iter(parent_tag):
            for child in parent.findall(child_tag):
                if child.find("BuildableReference").get("BlueprintName") not in keep:
                    parent.remove(child)
    tree.write(f"{schemes}/{name}.xcscheme", xml_declaration=True, encoding="UTF-8")


def changed(since):
    def git(*command):
        result = subprocess.run(["git", *command], capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"git {' '.join(command)} failed:\n{result.stderr}")
        return result.stdout.split("\n")

    base = git("merge-base", since, "HEAD")[0]
    paths = git("diff", "--name-only", "--no-renames", base) + git("ls-files", "-o", "--exclude-standard")
    return sorted({p for p in paths if p})


if args.ios:
    chosen = [name_of(t) for t in scheme["build"]["targets"] if targets.get(name_of(t), {}).get("platform") == "iOS"]
else:
    chosen = [name_of(t) for t in scheme["test"]["targets"]]

if args.since:
    every = list(targets)
    read = {t: reads(t) for t in every}
    reached = set()
    for path in changed(args.since):
        if any(fnmatch.fnmatch(path, p) for p in BUILDS_NOTHING):
            continue
        by = {t for t in every if any(inside(path, r) for r in read[t])}
        if not by:
            print(f"{path} is outside every target, so every target is in", file=sys.stderr)
            reached = set(every)
            break
        reached |= by
    chosen = [t for t in chosen if t in reached]

if args.shard:
    try:
        k, n = (int(x) for x in args.shard.split("/"))
    except ValueError:
        sys.exit(f"error: a shard is K/N, such as 1/3 (got '{args.shard}')")
    if not 1 <= k <= n:
        sys.exit(f"error: shard {k} is not between 1 and {n}")
    weights = {t: files(t) for t in chosen}
    shards = [[0, []] for _ in range(n)]
    for target in sorted(chosen, key=lambda t: (-weights[t], t)):
        lightest = min(shards, key=lambda s: s[0])
        lightest[0] += weights[target]
        lightest[1].append(target)
    chosen = shards[k - 1][1]

if args.scheme:
    write_scheme(args.scheme, set(chosen))
print("\n".join(sorted(chosen)))

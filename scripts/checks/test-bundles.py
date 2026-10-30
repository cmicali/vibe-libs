"""Prints the macOS test bundles the vibe-libs scheme tests, one per line.

Usage: python3 -I scripts/checks/test-bundles.py [--shard K/N] [--scheme NAME]

With --shard it prints the Kth of N shards. Each bundle lands in exactly one
shard. A bundle weighs the source files it compiles, its templates' and its
own, since every bundle compiles its whole stack again. The heaviest go first,
each to the lightest shard, so a new piece rebalances the shards by itself.

With --scheme it also writes a copy of the generated vibe-libs scheme, named
NAME, that builds and tests only the bundles it prints. Run it after
`make project`.

TRAP: xcodebuild's -only-testing picks the tests a scheme runs, not the
targets it builds. A build for testing with it still builds every bundle.
"""
import argparse
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

SOURCE = (".c", ".cc", ".cpp", ".m", ".mm")

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
dump = subprocess.run(["xcodegen", "dump", "--type", "json", "--spec", "project.yml"],
                      capture_output=True, text=True)
if dump.returncode != 0:
    sys.exit(f"xcodegen dump failed:\n{dump.stderr}")
spec = json.loads(dump.stdout)
templates = spec.get("targetTemplates", {})
targets = spec.get("targets", {})


def name_of(entry):
    return entry if isinstance(entry, str) else entry.get("name", "")


def files(sources):
    n = 0
    for source in sources:
        path = source if isinstance(source, str) else source.get("path", "")
        for dirpath, dirs, names in os.walk(path):
            # A macOS bundle excludes every iOS/ half.
            dirs[:] = [d for d in dirs if d != "iOS"]
            n += sum(1 for f in names if f.endswith(SOURCE))
    return n


def weight(target):
    seen, todo = set(), list(targets[target].get("templates", []))
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo += templates.get(name, {}).get("templates", [])
    return files(targets[target].get("sources", [])) + sum(files(templates[t].get("sources", [])) for t in seen)


def write_scheme(name, keep):
    schemes = "vibe-libs.xcodeproj/xcshareddata/xcschemes"
    tree = ET.parse(f"{schemes}/vibe-libs.xcscheme")
    for parent_tag, child_tag in (("BuildActionEntries", "BuildActionEntry"), ("Testables", "TestableReference")):
        for parent in tree.iter(parent_tag):
            for child in parent.findall(child_tag):
                if child.find("BuildableReference").get("BlueprintName") not in keep:
                    parent.remove(child)
    tree.write(f"{schemes}/{name}.xcscheme", xml_declaration=True, encoding="UTF-8")


parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
parser.add_argument("--shard")
parser.add_argument("--scheme")
args = parser.parse_args()

bundles = [name_of(t) for t in spec["schemes"]["vibe-libs"]["test"]["targets"]]

if args.shard:
    try:
        k, n = (int(x) for x in args.shard.split("/"))
    except ValueError:
        sys.exit(f"error: a shard is K/N, such as 1/3 (got '{args.shard}')")
    if not 1 <= k <= n:
        sys.exit(f"error: shard {k} is not between 1 and {n}")
    weights = {b: weight(b) for b in bundles}
    shards = [[0, []] for _ in range(n)]
    for bundle in sorted(bundles, key=lambda b: (-weights[b], b)):
        lightest = min(shards, key=lambda s: s[0])
        lightest[0] += weights[bundle]
        lightest[1].append(bundle)
    bundles = sorted(shards[k - 1][1])

if args.scheme:
    write_scheme(args.scheme, set(bundles))
print("\n".join(bundles))

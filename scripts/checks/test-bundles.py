"""Prints the macOS test bundles the vibe-libs scheme tests, one per line.

Usage: python3 -I scripts/checks/test-bundles.py [--shard K/N]

With --shard it prints the Kth of N shards. Each bundle lands in exactly one
shard. A bundle weighs the source files it compiles, its templates' and its
own, since every bundle compiles its whole stack again. The heaviest go first,
each to the lightest shard, so a new piece rebalances the shards by itself.
"""
import json
import os
import subprocess
import sys

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


bundles = [name_of(t) for t in spec["schemes"]["vibe-libs"]["test"]["targets"]]

if len(sys.argv) == 1:
    print("\n".join(bundles))
    sys.exit(0)
if len(sys.argv) != 3 or sys.argv[1] != "--shard":
    sys.exit(__doc__)
try:
    k, n = (int(x) for x in sys.argv[2].split("/"))
except ValueError:
    sys.exit(f"error: a shard is K/N, such as 1/3 (got '{sys.argv[2]}')")
if not 1 <= k <= n:
    sys.exit(f"error: shard {k} is not between 1 and {n}")

shards = [[0, []] for _ in range(n)]
for bundle in sorted(bundles, key=lambda b: (-weight(b), b)):
    lightest = min(shards, key=lambda s: s[0])
    lightest[0] += weight(bundle)
    lightest[1].append(bundle)
print("\n".join(sorted(shards[k - 1][1])))

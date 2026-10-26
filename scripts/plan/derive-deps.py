"""Derive vibe-libs' dependency map from a Vibe checkout's imports.

Usage: python3 -I scripts/plan/derive-deps.py <root> [--sites]

<root> is a Vibe checkout with its vibe-libs submodule checked out. The
script reads its Vibe/, vibe-libs/, and project.yml. Run it after each cut and each move, and update the map in
docs/plan.md in the same change.

Each source file is assigned to a piece ("app" for code that stays in Vibe).
A file under vibe-libs/ belongs to the piece its directory names,
vibe-libs/<group>/<piece>/. A file still in Vibe belongs to the piece the
plan moves it into, by the path prefixes below. Every #import and #include,
quoted or angled, is resolved to a file in the tree, and the piece-to-piece
edges are printed. With --sites it also prints the files behind each edge.

Resolution follows the compiler, never the filesystem's order:
  1. A quoted include looks in the including file's own directory first.
  2. Then both kinds look through the macOS app's header search paths, in
     the order its build has them: each template's paths, in the order the
     app target lists its templates, a template's own templates first, and
     then the target's own paths from project.yml's anchor. A template's
     paths come from vibe-libs/vibe-libs.yml.
  3. Then, as Xcode's headermap does, a quoted include may match a header by
     its basename anywhere in the tree, but only if exactly one matches.
  4. An include listed in EXPLICIT resolves to the file named there.
An include that still matches more than one file is reported as ambiguous,
and the script exits 1 without printing a map. Add an EXPLICIT entry, naming
the header the build really uses, to settle it. An angled include that
matches nothing is a system header and is skipped.
"""
import os
import re
import sys
from collections import defaultdict

root = sys.argv[1]
show_sites = "--sites" in sys.argv
inc = re.compile(r'^\s*#\s*(?:import|include)\s+([<"])([^>"]+)[>"]', re.M)

LIBS = "vibe-libs"
GROUPS = ("core", "files", "audio", "media", "waveform", "ui", "system", "dev", "third_party")

# Files still in Vibe: (piece, path prefix relative to root). First match wins.
PIECES = [
    ("app", ""),
]


def piece_of(rel):
    parts = rel.split("/")
    if parts[0] == LIBS:
        return "/".join(parts[1:3])
    for name, prefix in PIECES:
        if rel.startswith(prefix):
            return name
    return "app"


SRC = (".h", ".hpp", ".hh", ".m", ".mm", ".c", ".cc", ".cpp", ".inc", ".tcc")
tops = ["Vibe"] + [f"{LIBS}/{g}" for g in GROUPS]
files = []
for top in tops:
    for dirpath, _, names in os.walk(os.path.join(root, top)):
        for n in names:
            if n.endswith(SRC):
                files.append(os.path.relpath(os.path.join(dirpath, n), root))
if not any(f.startswith(LIBS + "/") for f in files):
    sys.exit(f"no sources under {LIBS}/: check out the submodule first")

by_base = defaultdict(list)
for f in files:
    by_base[os.path.basename(f)].append(f)
file_set = set(files)

# (including file, spelling) -> the file the build uses, for a collision the
# search paths cannot settle. Each entry says why.
EXPLICIT = {}


def yaml_list(lines, i, indent):
    """The list at lines[i], inline or as a block of "- " items below it."""
    head = lines[i].split(":", 1)[1].split("#")[0].strip()
    if head.startswith("["):
        return [v.strip().strip('"') for v in head.strip("[]").split(",") if v.strip()]
    values = []
    for line in lines[i + 1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if len(line) - len(line.lstrip()) <= indent or not stripped.startswith("- "):
            break
        values.append(stripped[2:].split("#")[0].strip().strip('"'))
    return values


def read_templates():
    """Each template's search paths and templates, from vibe-libs.yml."""
    with open(os.path.join(root, LIBS, "vibe-libs.yml")) as fh:
        lines = fh.read().splitlines()
    templates, name = {}, None
    for i, line in enumerate(lines):
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_]*):\s*$", line)
        if m:
            name = m.group(1)
            templates[name] = {"templates": [], "paths": []}
            continue
        if not name:
            continue
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if indent == 4 and stripped.startswith("templates:"):
            templates[name]["templates"] = yaml_list(lines, i, indent)
        elif stripped.startswith("HEADER_SEARCH_PATHS:"):
            for value in yaml_list(lines, i, indent):
                if value.startswith("$(VIBE_LIBS_ROOT)/"):
                    templates[name]["paths"].append(LIBS + "/" + value[len("$(VIBE_LIBS_ROOT)/"):])
    return templates


def app_target():
    """The macOS app target's templates and its anchored search paths."""
    with open(os.path.join(root, "project.yml")) as fh:
        lines = fh.read().splitlines()
    listed, paths, target = [], [], None
    for i, line in enumerate(lines):
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_]*):\s*$", line)
        if m:
            target = m.group(1)
        if target == "Vibe" and line.startswith("    templates:"):
            joined, j = line.split("#")[0], i
            while "]" not in joined:
                j += 1
                joined += lines[j].split("#")[0]
            listed = [v.strip() for v in joined.split("[", 1)[1].split("]")[0].split(",") if v.strip()]
        if "HEADER_SEARCH_PATHS: &vibe-header-search-paths" in line:
            for value in yaml_list(lines, i, len(line) - len(line.lstrip())):
                if value.startswith("$(SRCROOT)/"):
                    paths.append(value[len("$(SRCROOT)/"):])
    if not listed:
        sys.exit("no templates on the Vibe target in project.yml")
    if not paths:
        sys.exit("no app header search paths found in project.yml")
    return listed, paths


def search_paths():
    templates = read_templates()
    listed, own = app_target()
    order, seen = [], set()

    def visit(name):
        if name in seen:
            return
        seen.add(name)
        if name not in templates:
            sys.exit(f"template {name} is not in {LIBS}/vibe-libs.yml")
        for dep in templates[name]["templates"]:
            visit(dep)
        order.extend(templates[name]["paths"])

    for name in listed:
        visit(name)
    return order + own


SEARCH = search_paths()
ambiguous = []


def resolve(src, kind, spelling):
    explicit = EXPLICIT.get((src, spelling))
    if explicit:
        return explicit
    if kind == '"':
        local = os.path.normpath(os.path.join(os.path.dirname(src), spelling))
        if local in file_set:
            return local
    for directory in SEARCH:
        candidate = os.path.normpath(os.path.join(directory, spelling))
        if candidate in file_set:
            return candidate
    if kind != '"':
        return None
    cands = [c for c in by_base.get(os.path.basename(spelling), [])
             if c == spelling or c.endswith("/" + spelling)]
    if len(cands) == 1:
        return cands[0]
    if len(cands) > 1:
        ambiguous.append((src, spelling, cands))
    return None


edges = defaultdict(lambda: defaultdict(set))
for f in files:
    src = piece_of(f)
    if src == "app":
        continue
    with open(os.path.join(root, f), errors="replace") as fh:
        text = fh.read()
    for kind, spelling in inc.findall(text):
        target = resolve(f, kind, spelling)
        if not target:
            continue
        dst = piece_of(target)
        if dst != src:
            edges[src][dst].add(f"{f.split('/')[-1]} -> {spelling}")

if ambiguous:
    for src, spelling, cands in ambiguous:
        print(f"ambiguous: {src} includes \"{spelling}\": {', '.join(cands)}", file=sys.stderr)
    sys.exit(1)

for src in sorted(edges):
    deps = sorted(d for d in edges[src])
    print(f"{src:28} -> {', '.join(deps)}")
    if show_sites:
        for d in deps:
            sites = sorted(edges[src][d])
            print(f"    {d:26} {len(sites):3}  " + "; ".join(sites[:3]) + (" ..." if len(sites) > 3 else ""))

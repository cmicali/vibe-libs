"""The TagLib record check's own tests: each case is a set of changed paths
and whether scripts/checks/taglib-record.py must fail on it.

Usage: python3 -I scripts/checks/taglib-record-test.py   (from the repo root)
"""
import os
import runpy
import sys

problems = runpy.run_path(os.path.join("scripts", "checks", "taglib-record.py"))["problems"]

T = "third_party/taglib/"
CASES = [
    ("a TagLib file changed alone fails", {T + "toolkit/tstring.cpp"}, True),
    ("a TagLib file changed with the record passes", {T + "toolkit/tstring.cpp", T + "CHANGES.md"}, False),
    ("a new TagLib file alone fails", {T + "mp4/mp4new.cpp"}, True),
    ("the piece's doc alone passes", {T + "AGENTS.md"}, False),
    ("the license text alone passes", {T + "LICENSE.MPL"}, False),
    ("a change outside TagLib passes", {"third_party/dr_flac/dr_flac.h", "media/Tags/TagLibAudioFile.mm"}, False),
]

failed = 0
for name, paths, fails in CASES:
    if bool(problems(paths)) != fails:
        print(f"FAIL: {name}")
        failed += 1
print(f"taglib-record: {len(CASES) - failed} of {len(CASES)} cases pass")
sys.exit(1 if failed else 0)

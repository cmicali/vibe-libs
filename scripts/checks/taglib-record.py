"""Fails when a change to a TagLib file leaves TagLib's dated record alone.

MPL 1.1 section 3.3 asks for a dated record of the changes to TagLib's files.
It is third_party/taglib/CHANGES.md. Any other file changed there since REV,
but AGENTS.md and LICENSE.MPL, needs the record changed too. With no --since
it checks nothing.

Usage: python3 -I scripts/checks/taglib-record.py [--since REV]   (from the repo root)
"""
import subprocess
import sys

DIR = "third_party/taglib/"
RECORD = DIR + "CHANGES.md"
EXEMPT = {RECORD, DIR + "AGENTS.md", DIR + "LICENSE.MPL"}


def problems(changed):
    touched = sorted(p for p in changed if p.startswith(DIR) and p not in EXEMPT)
    if not touched or RECORD in changed:
        return []
    return [f"{p} changed, but {RECORD} did not: give the change a dated line there" for p in touched]


def changed(since):
    def git(*command):
        result = subprocess.run(["git", *command], capture_output=True, text=True)
        if result.returncode:
            sys.exit(f"git {' '.join(command)} failed:\n{result.stderr}")
        return [line for line in result.stdout.split("\n") if line]
    base = git("merge-base", since, "HEAD")[0]
    return set(git("diff", "--name-only", "--no-renames", base) + git("ls-files", "-o", "--exclude-standard"))


if __name__ == "__main__":
    if sys.argv[1:2] != ["--since"] or len(sys.argv) != 3:
        print("taglib-record: no --since, so nothing to check")
        sys.exit(0)
    found = problems(changed(sys.argv[2]))
    for problem in found:
        print(problem)
    sys.exit(1 if found else 0)

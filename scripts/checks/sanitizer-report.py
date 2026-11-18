#!/usr/bin/env python3
"""Reads what a sanitized test run reported, and fails on any report.

make test-asan and make test-tsan point each sanitizer's log_path into one
folder, so every report lands in a file of its own, named report.<pid>, from
every test process. A report's stack stays out of the run's own log, which
xcodebuild keeps from its workers. This script prints each distinct report once, keyed by its kind
and its first frame in code built here, with how many times it
came. It exits 1 when there is any.

Address Sanitizer stops its process at its first report. Undefined Behavior
Sanitizer and Thread Sanitizer report and go on, so one process can write
many.

Usage: python3 -I scripts/checks/sanitizer-report.py FOLDER
"""

import os
import re
import sys

# Where a report starts: Address Sanitizer's and Thread Sanitizer's banners,
# and Undefined Behavior Sanitizer's one line, file:line:column: runtime error.
START = re.compile(r"^(==\d+==ERROR: |WARNING: ThreadSanitizer|.*: runtime error: )")
# A frame: "    #3 0x... in function file:line".
FRAME = re.compile(r"^\s*#\d+ 0x[0-9a-f]+ in (.+?)(?: \(([^)]*)\))?$")
# Frames in the sanitizer's own runtime, or in the system, say less about
# where the bug is than the first frame in code built here.
NOT_OURS = re.compile(r"libclang_rt|/usr/lib/|/System/Library/|__tsan|__asan|__ubsan")


def reports(text):
    """Splits one report file into its reports."""
    out, current = [], None
    for line in text.splitlines():
        if START.match(line):
            if current:
                out.append(current)
            current = [line]
        elif current is not None:
            current.append(line)
            if line.startswith("SUMMARY: "):
                out.append(current)
                current = None
    if current:
        out.append(current)
    return out


def key(report):
    """The report's kind and first frame of our own, for counting repeats."""
    head = report[0]
    if "runtime error: " in head:
        # UBSan's line names the place itself.
        return head.split(": runtime error: ")[0].rsplit("/", 1)[-1] + ": " + head.split(": runtime error: ")[1]
    kind = re.sub(r"^==\d+==ERROR: |\(pid=\d+\)|on address 0x[0-9a-f]+.*$| at pc .*$", "", head).strip()
    for line in report[1:]:
        match = FRAME.match(line)
        if match and not NOT_OURS.search(line):
            return kind + " in " + match.group(1)
    return kind


def main(folder):
    if not os.path.isdir(folder):
        print(f"No sanitizer reports: {folder} is missing.")
        return 0
    seen = {}
    for name in sorted(os.listdir(folder)):
        if not name.startswith("report."):
            continue
        with open(os.path.join(folder, name), errors="replace") as handle:
            for report in reports(handle.read()):
                entry = seen.setdefault(key(report), [0, report, name])
                entry[0] += 1
    if not seen:
        print(f"No sanitizer reports in {folder}.")
        return 0
    for title, (count, report, name) in seen.items():
        print(f"--- {title} ({count} times, first in {name})")
        print("\n".join(report[:60]))
    print(f"{len(seen)} distinct sanitizer reports in {folder}.")
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))

#!/usr/bin/env python3
"""Reads what a sanitized test run reported, and fails on any report.

make test-asan and make test-tsan point each sanitizer's log_path into one
folder, so every report lands in a file of its own, named report.<pid>, from
every test process. A report's stack stays out of the run's own log, which
xcodebuild keeps from its workers. This script prints each distinct report
once, keyed by its summary line, which names its kind and its place, with
how many times it came. It exits 1 when there is any. Another app's make
targets run it over their own folder too.

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
    """The report's own summary, which names its kind and place, for counting repeats."""
    for line in report:
        if line.startswith("SUMMARY: "):
            return line[len("SUMMARY: "):]
    return report[0]


def main(folder):
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

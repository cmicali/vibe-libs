"""The message callback for a move's git filter-repo run.

A move carries Vibe's history here (docs/plan.md, The work, in order). Its
filter rewrites every commit message with rewrite() below:

  1. It drops each tool-credit trailer: Co-Authored-By, a session link, and
     a "Generated with" footer. So no tool's credit arrives here.
  2. It rewrites a closing keyword before "#<number>" or "GH-<number>" to
     name Vibe. The keywords are close, fix, and resolve, in every tense and
     any case. "Closes #45" becomes "Closes Vibe #45", and "Closes GH-45"
     becomes "Closes Vibe GH-45". Neither closes anything. A Vibe commit's
     number names Vibe's issue, but GitHub reads it here as this repo's.

Usage, from the fresh clone of Vibe the move filters:

  git filter-repo --path <moved path> ... --message-callback \\
    'import runpy; return runpy.run_path("<vibe-libs>/scripts/plan/filter-messages.py")["rewrite"](message)'

scripts/checks/filter-messages-test.py tests it, and make check-pieces runs
that test.
"""
import re

# A whole line, matched case-insensitively.
CREDIT_LINES = [
    rb"co-authored-by:.*",
    rb"[\w-]*session:\s*https?://\S*",
    rb"\W*generated (with|by) .*(claude|codex|copilot|cursor|chatgpt|gemini|\]\(https?://).*",
]
CREDIT = re.compile(rb"^(?:" + rb"|".join(CREDIT_LINES) + rb")[ \t]*\r?\n?",
                    re.IGNORECASE | re.MULTILINE)

KEYWORD = re.compile(rb"\b(clos(?:e|es|ed)|fix(?:es|ed)?|resolv(?:e|es|ed))(:?[ \t]+)(#|GH-)(\d+)\b",
                     re.IGNORECASE)


def rewrite(message):
    """Returns message, a commit message's bytes, as the move keeps it."""
    kept = CREDIT.sub(b"", message)
    kept = KEYWORD.sub(rb"\1\2Vibe \3\4", kept)
    return kept.rstrip() + b"\n"

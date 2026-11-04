#!/usr/bin/env python3
# bin/check-customer-words.py: fails a pull request that ADDS shop talk to a file a customer can read.
# Reads `git diff -U0 -M --no-color --diff-filter=AMR HEAD^1 HEAD` on stdin; PR_TITLE and PR_BODY (env) are checked whole.
# Exit 0 clean, 1 hits (every hit is printed), 2 any error (bad allowlist, input that is not a diff). Run as `python3 -I`.
# An added line with a hit passes only if .github/policy/customer-words-allow.txt has the exact line `path|text`.
import os
import re
import sys

WORDS = r"\b(owners?|lanes?|orchestrators?|advisors?|handoffs?|ratif(y|ied|ies|ication))\b"
REFS = r"docs/ratify|\bhandoffs?/|\baudits/|/srv/|lane-outbox|\bops#[0-9]+"
RULES = r"\brules? [0-9]+\b"
IDS = r"\b(SB|HS|CR|MC)-[0-9]+"
BANNED = re.compile("|".join("(?:%s)" % p for p in (WORDS, REFS, RULES, IDS)), re.I)
CUSTOMER_FILE = re.compile(r"^(?!bin/|\.github/(?!PULL_REQUEST_TEMPLATE\.md$)).*\.(html|md|txt|svg|xml)$")


def fail(msg):
    print("check-customer-words: " + msg, file=sys.stderr)
    sys.exit(2)


def load_allowlist(path):
    allowed = set()
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, bar, text = line.partition("|")
        if not bar or not name or not text.strip() or "*" in name or "?" in name:
            fail("%s:%d: malformed allowlist line (want path|exact line)" % (path, n))
        allowed.add((name, text.strip()))
    return allowed


def main():
    allowed = load_allowlist(os.environ.get("CUSTOMER_WORDS_ALLOW", ".github/policy/customer-words-allow.txt"))
    hits, path, in_header, saw_diff = [], None, False, False
    data = sys.stdin.read()
    for raw in data.split("\n"):
        if raw.startswith("diff --git "):
            saw_diff, path, in_header = True, None, True
        elif in_header and raw.startswith("+++ "):
            if not raw.startswith("+++ b/"):
                fail("unreadable file name in the diff header: " + raw)
            path = raw[6:]
        elif raw.startswith("@@"):
            in_header = False   # from here on a line that starts with +++ is content, not a header
        elif not in_header and path and raw.startswith("+") and CUSTOMER_FILE.match(path):
            text = raw[1:].strip()
            if BANNED.search(text) and (path, text) not in allowed:
                hits.append("%s: %s" % (path, text))
    if data.strip() and not saw_diff:
        fail("input is not a git diff")
    for label in ("PR_TITLE", "PR_BODY"):
        for line in os.environ.get(label, "").splitlines():
            if BANNED.search(line):
                hits.append("%s: %s" % (label.lower()[3:], line.strip()))
    for h in hits:
        print("customer-words: " + h)
    sys.exit(1 if hits else 0)


try:
    main()
except OSError as e:   # a missing or unreadable allowlist is a failure, never a pass
    fail(str(e))

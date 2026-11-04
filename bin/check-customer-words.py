#!/usr/bin/env python3
# bin/check-customer-words.py: fails a pull request that ADDS shop talk to a file a customer can read.
# Reads `git diff -U0 --no-renames --no-color HEAD^1 HEAD` on stdin; PR_TITLE and PR_BODY (env) are checked whole.
# Exit 0 clean, 1 hits (every hit is printed), 2 any error (bad allowlist, bad text, input that is not a diff, a binary
# change to a customer file or one it cannot read). Run as `python3 -I`.
# An added line with a hit passes only if .github/policy/customer-words-allow.txt has the exact line `path|text`.
import os
import re
import sys

B, A = r"(?<![A-Za-z])", r"(?![A-Za-z])"   # letters only, so _owner_ and owner2 still match
WORDS = B + r"(owners?|lanes?|orchestrators?|advisors?|handoffs?|ratif(y|ied|ies|ication))" + A
REFS = r"docs/ratify|(?<![A-Za-z])handoffs?/|(?<![A-Za-z])audits/|/srv/|lane-outbox|(?<![A-Za-z])ops#[0-9]+"
RULES = B + r"rules?\s+[0-9]+"
IDS = B + r"(SB|HS|CR|MC)-[0-9]+"
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
    hits, path, in_header, saw_diff, is_link = [], None, False, False, False
    data = sys.stdin.buffer.read().decode("utf-8")
    for raw in data.split("\n"):
        if raw.startswith("diff --git "):
            saw_diff, path, in_header, is_link = True, None, True, False
        elif in_header and (raw in ("new file mode 120000", "new mode 120000") or re.match(r"index [0-9a-f]+\.\.[0-9a-f]+ 120000$", raw)):
            is_link = True   # a symbolic link: git shows its target name, not the lines a visitor would read
        elif in_header and raw.startswith("+++ "):
            if raw == "+++ /dev/null":
                path = None   # a deleted file adds nothing
            elif raw.startswith("+++ b/"):
                path = raw[6:].rstrip("\t")   # git ends a name that holds a space with a tab
                if is_link and CUSTOMER_FILE.match(path):
                    fail("symbolic link at a customer file: " + path)
            else:
                fail("unreadable file name in the diff header: " + raw)
        elif raw.startswith("Binary files ") and not raw.endswith(" and /dev/null differ"):   # a deleted file adds nothing
            m = re.match(r"Binary files .* and b/(.*) differ$", raw)
            if not m or CUSTOMER_FILE.match(m.group(1)):   # git quotes non-ASCII names, which the match cannot read
                fail("binary change this check cannot read: " + raw)
        elif raw.startswith("@@"):
            in_header = False   # from here on a line that starts with +++ is content, not a header
        elif not in_header and path and raw.startswith("+") and CUSTOMER_FILE.match(path):
            text = raw[1:].strip()
            if BANNED.search(text) and (path, text) not in allowed:
                hits.append("%s: %s" % (path, text))
    if data.strip() and not saw_diff:
        fail("input is not a git diff")
    for label, name in (("PR_TITLE", "title"), ("PR_BODY", "body")):
        for line in os.environ.get(label, "").splitlines():
            if BANNED.search(line):
                hits.append("%s: %s" % (name, line.strip()))
    for h in hits:
        print("customer-words: " + h)
    sys.exit(1 if hits else 0)


try:
    main()
except (OSError, ValueError) as e:   # an unreadable allowlist or text that is not UTF-8 is a failure, never a pass
    fail(str(e))

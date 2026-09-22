#!/usr/bin/env python3
"""Require translated Markdown files to change together.

`{NAME}.md` is the Chinese source of truth and `{NAME}_{LANG}.md` its
translations in the same directory. A family opts in once it has a second
member; from then on, a change to any member must change every member.
"""
import argparse
import json
import os
import posixpath
import re
import subprocess
import sys


LANGUAGES = {"en"}
SKIP_MARKER = re.compile(r"^\s*doc-i18n-skip:\s*(.+)$", re.MULTILINE)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def family(path):
    if not path.endswith(".md"):
        return None
    directory, filename = posixpath.split(path)
    name, _, suffix = filename[:-3].rpartition("_")
    if not name or suffix not in LANGUAGES:
        name = filename[:-3]
    return posixpath.join(directory, name)


def changed_paths(base, head):
    tokens = iter(git("diff", "--name-status", "-M", "-z", base, head).split("\0"))
    paths = set()
    for status in tokens:
        if status:
            paths.add(next(tokens))
            if status[0] in "RC":
                paths.add(next(tokens))
    return paths


def check(base, head, skip=frozenset()):
    changed = {path for path in changed_paths(base, head) if family(path)}
    members = {}
    for path in set(git("ls-tree", "-r", "-z", "--name-only", head).split("\0")) | changed:
        if key := family(path):
            members.setdefault(key, set()).add(path)
    problems = {}
    for key in sorted({family(path) for path in changed} - skip):
        if len(members[key]) > 1 and members[key] - changed:
            problems[key] = sorted(members[key] - changed)
    return problems


def skip_from_event():
    path = os.environ.get("GITHUB_EVENT_PATH")
    if not path or not os.path.exists(path):
        return frozenset()
    with open(path) as handle:
        body = (json.load(handle).get("pull_request") or {}).get("body") or ""
    return frozenset(token for line in SKIP_MARKER.findall(body) for token in line.replace(",", " ").split())


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args()
    problems = check(args.base, args.head, skip_from_event())
    for key, missing in problems.items():
        print(f"{key}: also update {', '.join(missing)} (or add `doc-i18n-skip: {key}` to the PR body)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

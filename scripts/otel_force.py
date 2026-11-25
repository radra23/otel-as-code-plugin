#!/usr/bin/env python3
"""Write or remove the `--force` sentinel, .claude/.otel-force (#255).

usage: otel_force.py set [--ttl SECONDS] <path> [<path> ...]
       otel_force.py clear

A slash-command flag cannot set an environment variable for the write-guard hook's process, so
a command run with --force lists the files it is about to overwrite in .claude/.otel-force, and
hooks/write-guard.sh allows an overwrite only for a path listed there (matched by
hooks/otel-force-match.py, which normalises both sides). The commands used to write that file
with their own shell snippets, which differed (`printf ... >` in one, `:>` then `>>` in another),
so a change in how paths were written or how the file was cleared changed what --force allowed.
This script is now the one writer.

  set    replaces any earlier sentinel in .claude/ of the current directory (the commands run
         from the repo root, where write-guard looks first) with an expiry line and each path
         made absolute, one per line. The expiry (default 600 s) is what the matcher checks: a
         sentinel left behind by an aborted command stops authorising anything once it passes.
  clear  removes it; not an error when there is none.

Exit 0 on success. Exit 1 with a one-line reason and nothing written when `set` has no paths.
"""
import argparse
import os
import sys
import time

SENTINEL = os.path.join(".claude", ".otel-force")
DEFAULT_TTL = 600


def set_sentinel(paths, ttl):
    if not paths:
        print("otel_force.py: set needs at least one path; nothing written", file=sys.stderr)
        return 1
    expires = int(time.time()) + ttl
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires))
    lines = [f"# otel-as-code --force sentinel; expires {expires} ({stamp})"]
    lines += [os.path.abspath(p) for p in paths]
    os.makedirs(os.path.dirname(SENTINEL), exist_ok=True)
    with open(SENTINEL, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"otel_force.py: --force allows {len(paths)} path(s) until {stamp}")
    return 0


def clear_sentinel():
    try:
        os.remove(SENTINEL)
    except FileNotFoundError:
        pass
    return 0


def main():
    ap = argparse.ArgumentParser(description="Write or remove the --force sentinel.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set", help="list the paths --force may overwrite")
    s.add_argument("--ttl", type=int, default=DEFAULT_TTL, help="seconds until it expires")
    s.add_argument("paths", nargs="*")
    sub.add_parser("clear", help="remove the sentinel")
    args = ap.parse_args()
    if args.cmd == "set":
        return set_sentinel(args.paths, args.ttl)
    return clear_sentinel()


if __name__ == "__main__":
    sys.exit(main())

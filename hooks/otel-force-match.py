#!/usr/bin/env python3
"""Decide whether the `--force` sentinel authorises overwriting one file.

Usage: otel-force-match.py <file_path> <project_dir> <sentinel_file>
Exit 0 = the sentinel lists this file (allow the overwrite). Exit 1 = it does not.

Why this is not `grep -Fxq`: the two sides of the comparison are produced by different
programs on possibly different path conventions, and an exact string match between them
can never succeed on Windows.

  the tool reports   C:\\Users\\me\\repo\\api\\src\\tracing.ts   (Windows, backslashes)
  the sentinel holds /c/Users/me/repo/api/src/tracing.ts        (Git Bash, $PWD)
  Codex reports      api/src/tracing.ts                          (relative to session cwd)

All three name one file. Normalising both sides — drive letter to the Git Bash spelling,
backslashes to forward slashes, relative to absolute, then collapsing `.` / `..` — reduces
them to one comparable string, so `--force` works regardless of which shell wrote the
sentinel or which host reported the path.
"""
import os
import posixpath
import re
import sys

_DRIVE = re.compile(r"^([A-Za-z]):(/.*)?$")


def windows_shaped(raw):
    """True when the raw string is in a Windows convention (backslashes or a drive letter).

    Windows filesystems are case-insensitive and POSIX ones are not, so case is folded
    only when one side is Windows-shaped. That keeps `--force` scoped to the paths the
    command actually listed instead of widening it on every host.
    """
    return "\\" in raw or _DRIVE.match(raw) is not None


def canon(raw, base):
    """Reduce a path to one comparable form. `base` anchors relative paths."""
    p = raw.strip().replace("\\", "/")
    m = _DRIVE.match(p)
    if m:  # C:/Users/... and /c/Users/... name the same file
        p = "/" + m.group(1).lower() + (m.group(2) or "/")
    if not p.startswith("/"):
        p = posixpath.join(base, p)
    return posixpath.normpath(p)


def real(path):
    """realpath when it resolves an existing file, else None.

    Catches the differences normalising alone cannot: symlinked repo roots, a `/tmp` that
    is really `/private/tmp`, a Windows 8.3 short name.
    """
    try:
        resolved = os.path.realpath(path)
        return resolved if os.path.exists(resolved) else None
    except OSError:
        return None


def same(a_raw, a_canon, b_raw, b_canon):
    if a_canon == b_canon:
        return True
    if (windows_shaped(a_raw) or windows_shaped(b_raw)) and a_canon.lower() == b_canon.lower():
        return True
    a_real, b_real = real(a_raw), real(b_raw)
    return a_real is not None and a_real == b_real


def main():
    if len(sys.argv) != 4:
        return 1
    target_raw, project_dir, sentinel = sys.argv[1], sys.argv[2], sys.argv[3]
    base = canon(project_dir, "/") if project_dir else "/"
    target_canon = canon(target_raw, base)
    try:
        with open(sentinel, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return 1
    for line in lines:
        entry = line.strip()
        if not entry or entry.startswith("#"):
            continue
        if same(target_raw, target_canon, entry, canon(entry, base)):
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())

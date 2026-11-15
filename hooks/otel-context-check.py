#!/usr/bin/env python3
"""Business-attribute confirmation check for writes to .claude/otel-context.json.

Run by hooks/write-guard.sh with the PreToolUse payload on stdin, only after the target has been
matched as the context cache. Prints the name of every business attribute the write would leave
without "confirmed": true, one per line; prints nothing when the write is fine or can't be judged.

The check runs on the file as it will be AFTER the write:
  - Write: tool_input.content.
  - Edit: the current file with old_string replaced by new_string (every occurrence when
    replace_all is set, else the first), the same substitution the Edit tool makes. Without this
    an Edit turning `"confirmed": true` into false went through unchecked.
Anything that can't be reconstructed or isn't valid JSON passes: the Edit tool itself refuses an
old_string it can't find, and a partial file is not something this check can judge.

The same rule is applied by scripts/write_context.py, which the commands use to write the cache.
"""
import json
import sys


def content_after(payload):
    tool_input = payload.get("tool_input", {})
    if payload.get("tool_name") == "Edit":
        old = tool_input.get("old_string")
        new = tool_input.get("new_string")
        if not isinstance(old, str) or not isinstance(new, str) or not old:
            return None
        try:
            with open(tool_input.get("file_path", ""), encoding="utf-8") as f:
                current = f.read()
        except (OSError, UnicodeDecodeError):
            return None
        if old not in current:
            return None
        return current.replace(old, new, -1 if tool_input.get("replace_all") else 1)
    return tool_input.get("content")


def main():
    try:
        content = content_after(json.load(sys.stdin))
        data = json.loads(content) if isinstance(content, str) else None
    except Exception:
        return
    if not isinstance(data, dict):
        return
    attrs = data.get("businessAttrs", []) or []
    if not isinstance(attrs, list):
        return
    for a in attrs:
        if isinstance(a, dict) and a.get("confirmed") is not True:
            print(a.get("name", "?"))


if __name__ == "__main__":
    main()

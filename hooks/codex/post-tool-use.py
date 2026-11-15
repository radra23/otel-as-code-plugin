#!/usr/bin/env python3
# hooks/codex/post-tool-use.py
# Codex PostToolUse adapter for otel-as-code.
#
# Runs the advisory hooks/semconv-lint.sh on each written OTel file (semconv-lint.sh reads the
# file from disk, already written by PostToolUse time) and surfaces any warnings back to the
# model via Codex's { hookSpecificOutput.additionalContext }. Shared plumbing lives in _bridge.py.
#
# It also re-checks the context cache on disk after any write that reached it (#254), with the same
# hooks/otel-context-check.py the PreToolUse guard uses: if unconfirmed business attributes got in
# by any route the guard did not foresee, the model is told to revert them. PostToolUse can't undo
# the write, so this backs up the guard rather than replacing it.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bridge import bridge_env, parse_targets, patch_paths, read_payload, resolves_to_cache, run_hook, unconfirmed_on_disk


def cache_after_write(tool_input, cwd):
    """A must-fix message when the write left unconfirmed business attributes in the cache."""
    paths = [p for p in dict.fromkeys(patch_paths(tool_input)) if resolves_to_cache(p, cwd)]
    names = []
    for path in paths:
        names += unconfirmed_on_disk(path, cwd)
    if not names:
        return None
    return ("otel-as-code write-guard: MUST FIX. .claude/otel-context.json now holds business "
            "attribute(s) that are not confirmed: " + ", ".join(dict.fromkeys(names)) + ". Revert "
            "this change, then confirm each attribute with /otel-business-attrs before it is written.")


def main():
    payload = read_payload()
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = bridge_env(cwd)
    out = []
    blocked = False
    for path, _content in parse_targets(tool_input):
        proc = run_hook("semconv-lint.sh", path, None, cwd, env)
        # exit 2 = strict-mode severe block; the actionable details are on stderr. Codex
        # PostToolUse can't deny (the write already happened), so surface it as a strongly
        # framed must-fix additionalContext rather than a silent advisory.
        if proc.returncode == 2:
            blocked = True
            detail = (proc.stderr or proc.stdout).strip()
            if detail:
                out.append(detail)
        elif proc.stdout.strip():
            out.append(proc.stdout.strip())
    cache_note = cache_after_write(tool_input, cwd)
    if out or cache_note:
        header = ("otel-as-code semconv-lint — STRICT: severe violation(s) must be fixed:\n"
                  if blocked else "otel-as-code semconv-lint:\n")
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "\n\n".join(
                ([cache_note] if cache_note else []) + ([header + "\n\n".join(out)] if out else [])),
        }}))


if __name__ == "__main__":
    main()

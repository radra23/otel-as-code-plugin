#!/usr/bin/env python3
# hooks/copilot/post-tool-use.py
# GitHub Copilot CLI postToolUse adapter for otel-as-code.
#
# Runs hooks/semconv-lint.sh, unchanged, on the file a Copilot `create`/`edit` just wrote, and
# hands its findings to the model as Copilot's top-level {"additionalContext": ...}: the lint
# prints to stdout/stderr, and on Copilot CLI 1.0.56 neither reaches the model
# (docs/agents/copilot-spike.md, row 3c). postToolUse can't undo a write, so a strict-mode
# block (exit 2) is framed as a must-fix, as the Codex adapter does.
#
# It also re-reads the context cache from disk after a write to it, with the same
# hooks/otel-context-check.py the preToolUse guard runs, in case unconfirmed business attributes
# got past that guard.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _copilot import bridge_env, claude_tool, read_payload, resolves_to_cache, run_hook, unconfirmed_on_disk


def main():
    payload = read_payload()
    tool = claude_tool(payload)
    if tool is None:
        return
    cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    path = tool[1]["file_path"]
    notes = []
    if resolves_to_cache(path, cwd):
        names = unconfirmed_on_disk(path, cwd)
        if names:
            notes.append(
                "otel-as-code write-guard: MUST FIX. .claude/otel-context.json now holds business "
                "attribute(s) that are not confirmed: " + ", ".join(dict.fromkeys(names)) + ". "
                "Revert this change, then confirm each attribute with /otel-business-attrs before "
                "it is written.")
    proc = run_hook("semconv-lint.sh", path, None, cwd, bridge_env(cwd), tool=tool)
    if proc.returncode == 2:
        detail = (proc.stderr or proc.stdout).strip()
        notes.append("otel-as-code semconv-lint — STRICT: severe violation(s) must be fixed:\n" + detail)
    else:
        detail = (proc.stdout.strip() + "\n" + proc.stderr.strip()).strip()
        if detail:
            notes.append("otel-as-code semconv-lint:\n" + detail)
    if notes:
        print(json.dumps({"additionalContext": "\n\n".join(notes)}))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Rewrite a Copilot CLI `--output-format json` transcript into the stream-json tool calls
score.py reads, so condition (c) is scored by the same unchanged rules as (a) and (b).

usage: copilot_transcript.py <copilot.jsonl> <plugin-root>   (stream-json on stdout)

Copilot emits one `tool.execution_start` per tool call (subagent calls included), in order.
Each becomes an assistant `tool_use` with Claude Code's tool name and input keys:

  skill {skill}                 -> Skill {skill: "otel-as-code:<name>"} when the session listed
                                   that skill with source "plugin" under the plugin root, else
                                   Skill {skill: <name>} (Copilot calls skills by bare name)
  task {agent_type}             -> Agent {subagent_type}
  view {path}                   -> Read {file_path}
  create {path, file_text}      -> Write {file_path, content}
  edit {path, old_str, new_str} -> Edit {file_path, old_string, new_string}
  apply_patch {input}           -> Write {file_path: "", content: <patch>}
  bash {command}                -> Bash {command}
  glob / grep {pattern, path}   -> Glob / Grep {pattern, path}

A tool with no counterpart is written as an `x-unmapped` line, which score.py skips: it is
never guessed into a route event or an OpenTelemetry write. The plugin root goes into the
`system/init` line, as Claude Code's own transcripts carry it.
"""
import json
import os
import sys

PLUGIN = "otel-as-code"


def args_of(data):
    a = data.get("arguments")
    if isinstance(a, str):
        try:
            a = json.loads(a)
        except ValueError:
            a = {"input": a}
    return a if isinstance(a, dict) else {}


def under(path, root):
    return isinstance(path, str) and os.path.realpath(path).startswith(root + os.sep)


def convert(lines, root):
    root = os.path.realpath(root)
    plugin_skills = set()
    yield {"type": "system", "subtype": "init", "plugins": [{"name": PLUGIN, "path": root}]}
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        t, d = ev.get("type"), ev.get("data") or {}
        if t == "session.skills_loaded":
            for s in d.get("skills", []):
                if s.get("source") == "plugin" and under(s.get("path"), root):
                    plugin_skills.add(s.get("name"))
            continue
        if t != "tool.execution_start":
            continue
        name, a = d.get("toolName"), args_of(d)
        if name == "skill":
            sk = str(a.get("skill", "")).lstrip("/")
            out = ("Skill", {"skill": f"{PLUGIN}:{sk}" if sk in plugin_skills else sk})
        elif name == "task":
            out = ("Agent", {"subagent_type": str(a.get("agent_type", ""))})
        elif name == "view":
            out = ("Read", {"file_path": a.get("path", "")})
        elif name == "create":
            out = ("Write", {"file_path": a.get("path", ""), "content": a.get("file_text", "")})
        elif name == "edit":
            out = ("Edit", {"file_path": a.get("path", ""), "old_string": a.get("old_str", ""),
                            "new_string": a.get("new_str", "")})
        elif name == "apply_patch":
            out = ("Write", {"file_path": "", "content": str(a.get("input", ""))})
        elif name == "bash":
            out = ("Bash", {"command": a.get("command", "")})
        elif name in ("glob", "grep"):
            out = (name.capitalize(), {k: a[k] for k in ("pattern", "path") if k in a})
        else:
            yield {"type": "x-unmapped", "name": name}
            continue
        yield {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": out[0], "input": out[1]}]}}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], errors="replace") as fh:
        for rec in convert(fh, sys.argv[2]):
            print(json.dumps(rec))


if __name__ == "__main__":
    main()

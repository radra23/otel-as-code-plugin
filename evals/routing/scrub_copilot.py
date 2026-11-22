#!/usr/bin/env python3
"""Scrub a captured Copilot CLI transcript for evals/routing/fixtures/.

usage: scrub_copilot.py <copilot.jsonl> > fixtures/<name>.jsonl

Rewrites the run's temp directory (where its HOME, COPILOT_HOME and workspace live) to
/work/otel-routing-c, the user's home to /home/user, and any GitHub token to <token>. Drops
`assistant.message_delta` events (the streamed text, repeated in full by `assistant.message`) and
shortens every string longer than 400 characters, which keeps file contents the session read out
of the fixture. Every event copilot_transcript.py reads keeps its type, order, tool names, paths
and short arguments.
"""
import json
import os
import re
import sys

TMP = re.compile(r"(/private)?/var/folders/[^/\"]+/[^/\"]+/T/(otel-routing-pass\.[^/\"]+/)?otel-routing-c\.[^/\"]+")
TOKEN = re.compile(r"\b(gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")
HOME = os.path.expanduser("~")


def scrub(v):
    if isinstance(v, str):
        v = TMP.sub("/work/otel-routing-c", v)
        v = TOKEN.sub("<token>", v).replace(HOME, "/home/user")
        return v if len(v) <= 400 else v[:400] + "...[trimmed]"
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in v.items()}
    return v


for line in open(sys.argv[1], errors="replace"):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "assistant.message_delta":
        continue
    print(json.dumps(scrub(ev)))

# hooks/codex/_bridge.py
# Shared helpers for the Codex hook adapters (pre-/post-tool-use).
# Keeps the apply_patch parsing, repo-root resolution, env setup, and the
# "synthesize a Claude-shaped payload and run a hooks/*.sh subprocess" pattern in ONE place
# so the two adapters cannot drift (and the guard/lint logic stays single-sourced in the .sh).
import json
import os
import re
import subprocess
import sys

# Repo root = two levels up from hooks/codex/.
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

_SECTION = re.compile(r"^\*\*\* (Add|Update|Delete) File: (.+)$")
_MOVE_TO = re.compile(r"^\*\*\* Move to: (.+)$")
_FRAME = re.compile(r"^\*\*\* (End Patch|Begin Patch)")


def read_payload():
    """Parse the Codex hook JSON from stdin; return {} on failure (fail open)."""
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


# An Update hunk whose result is unknown: its lines are not in the file (UNAPPLIED), or they match
# more than one place, so where apply_patch puts the change can't be known for certain (AMBIGUOUS).
UNAPPLIED = object()
AMBIGUOUS = object()


def parse_targets(tool_input, cwd=None):
    """Return [(path, full_content_or_None)] for each write target in a Codex payload.

    Handles the direct Edit/Write shape (tool_input.file_path) and the apply_patch envelope
    (patch text in tool_input.command). Add hunks carry their whole content.

    With `cwd` (the PreToolUse case, before the patch lands) the patch is replayed in order on an
    in-memory copy of the files it touches, starting from disk, so every target carries the file
    as apply_patch will leave it: an Update builds on an earlier Add, Update or Delete of the same
    file in the same patch, and a "*** Move to:" destination gets the moved content. An Update
    whose result can't be known carries UNAPPLIED or AMBIGUOUS. Without `cwd`, Update content is
    None. Callers that only need paths iterate `for path, _ in parse_targets(...)`.
    """
    fp = tool_input.get("file_path")
    if fp:
        return [(fp, tool_input.get("content"))]
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return []
    targets = []
    state = {}  # resolved path -> text, None (deleted), or UNAPPLIED/AMBIGUOUS
    touched = []  # every path the patch names, deletions included
    section = {"kind": None, "path": None, "move_to": None, "lines": []}

    def key(path):
        # One file, one key: symlinks resolved, so an edit through a link replays onto the file.
        return os.path.realpath(os.path.join(cwd, path))

    def current(path):
        if key(path) in state:
            text = state[key(path)]
            return UNAPPLIED if text is None else text
        try:
            with open(key(path), encoding="utf-8") as f:
                return f.read()
        except (OSError, UnicodeDecodeError):
            return UNAPPLIED

    def flush():
        kind, path, move_to, lines = section["kind"], section["path"], section["move_to"], section["lines"]
        touched.extend(p for p in (path, move_to) if p is not None)
        if kind == "Add":
            content = "".join(line[1:] + "\n" for line in lines if line.startswith("+"))
        elif kind == "Update" and cwd is not None:
            base = current(path)
            content = base if base in (UNAPPLIED, AMBIGUOUS) else apply_update(base, lines)
        elif kind == "Update":
            content = None
        elif kind == "Delete" and cwd is not None:
            state[key(path)] = None
            return
        else:
            return
        targets.append((path, content))
        if cwd is not None:
            state[key(path)] = content
        if move_to is not None:
            targets.append((move_to, content))
            if cwd is not None:
                state[key(path)] = None
                state[key(move_to)] = content

    for line in cmd.splitlines():
        # apply_patch trims a line before reading it as a header, so a header with surrounding
        # spaces is still a header; hunk lines keep their leading " ", "-" or "+".
        m = _SECTION.match(line.strip())
        mv = _MOVE_TO.match(line.strip())
        if m:
            flush()
            section = {"kind": m.group(1), "path": m.group(2).strip(), "move_to": None, "lines": []}
        elif _FRAME.match(line.strip()):
            flush()
            section = {"kind": None, "path": None, "move_to": None, "lines": []}
        elif mv and section["kind"] == "Update":
            section["move_to"] = mv.group(1).strip()
        elif section["kind"] is not None:
            section["lines"].append(line)
    flush()
    if cwd is not None:
        # Names that differ only in letter case are one file on macOS and Windows and two on
        # Linux, so what the patch reads can't be known. Then no target's content can be trusted:
        # all of them become AMBIGUOUS (the adapter denies only when one of them is the cache).
        spellings = {}
        for path in touched:
            spellings.setdefault(key(path).casefold(), set()).add(key(path))
        if any(len(keys) > 1 for keys in spellings.values()):
            targets = [(path, AMBIGUOUS) for path, _ in targets]
    return targets


def apply_update(text, hunk_lines):
    """`text` after an apply_patch Update hunk, or UNAPPLIED / AMBIGUOUS.

    Each "@@" starts a chunk; text after "@@ " is a line to find first. In a chunk, " " lines are
    context, "-" lines are removed and "+" lines added, so the chunk's old lines (" " and "-") are
    found and replaced by its new lines (" " and "+"). A chunk followed by "*** End of File" must
    sit at the end of the file. Lines are compared exactly, then ignoring trailing and then
    surrounding whitespace, as apply_patch does. Old lines found in more than one place give
    AMBIGUOUS rather than a guess.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    chunks = []
    for line in hunk_lines:
        if line.startswith("@@"):
            chunks.append({"anchor": line[2:].strip(), "lines": [], "eof": False})
        elif line.startswith("*** End of File"):
            if chunks:
                chunks[-1]["eof"] = True
        else:
            if not chunks:
                chunks.append({"anchor": "", "lines": [], "eof": False})
            chunks[-1]["lines"].append(line)
    pos = 0
    for chunk in chunks:
        if chunk["anchor"]:
            at = _find(lines, [chunk["anchor"]], pos, first=True)
            if at < 0:
                return UNAPPLIED
            pos = at + 1
        old = [l[1:] for l in chunk["lines"] if l[:1] in (" ", "-") or l == ""]
        new = [l[1:] for l in chunk["lines"] if l[:1] in (" ", "+") or l == ""]
        if not old:
            at = len(lines)  # a chunk of additions only is appended
        else:
            at = _find(lines, old, pos, eof=chunk["eof"])
            if at is AMBIGUOUS:
                return AMBIGUOUS
            if at < 0:
                return UNAPPLIED
        lines[at:at + len(old)] = new
        pos = at + len(new)
    return "\n".join(lines) + "\n"


def _find(lines, seq, start, first=False, eof=False):
    """Index of `seq` in `lines` at or after `start`: -1 if absent, AMBIGUOUS if it occurs more
    than once (unless `first`). With `eof`, only the position ending at the last line counts."""
    if eof:
        candidates = [len(lines) - len(seq)] if len(lines) - len(seq) >= start else []
    else:
        candidates = range(start, len(lines) - len(seq) + 1)
    for norm in (lambda s: s, str.rstrip, str.strip):
        want = [norm(s) for s in seq]
        hits = [i for i in candidates if [norm(s) for s in lines[i:i + len(seq)]] == want]
        if hits:
            if first or len(hits) == 1:
                return hits[0]
            return AMBIGUOUS
    return -1


def bridge_env(cwd):
    """Environment for the shell hooks: point them at the plugin root + the session cwd."""
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = ROOT
    env["CLAUDE_PROJECT_DIR"] = cwd
    return env


def run_hook(script_name, path, content, cwd, env, tool=None):
    """Synthesize the Claude-shaped payload for `path` and run hooks/<script_name>.
    `tool` = (tool_name, tool_input) passes a direct Edit/Write through unchanged, so the hook
    sees exactly what Claude Code would send. Returns the CompletedProcess."""
    if tool is not None:
        synth = {"tool_name": tool[0], "tool_input": tool[1]}
    else:
        tool_input = {"file_path": path}
        if content is not None:
            tool_input["content"] = content
        synth = {"tool_name": "Write", "tool_input": tool_input}
    return subprocess.run(
        ["bash", os.path.join(ROOT, "hooks", script_name)],
        input=json.dumps(synth), text=True, capture_output=True, cwd=cwd, env=env,
    )


def is_context_path(path):
    """True when `path` is the context cache, by hooks/otel-force-match.py's own normalisation
    (the one write-guard uses), loaded from that file rather than restated here."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "otel_force_match", os.path.join(ROOT, "hooks", "otel-force-match.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.is_context(path)

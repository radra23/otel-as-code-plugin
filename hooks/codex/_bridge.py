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
import unicodedata

# Repo root = two levels up from hooks/codex/.
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

_ADD_UPDATE = re.compile(r"^\*\*\* (Add|Update) File: (.+)$")
_MOVE_TO = re.compile(r"^\*\*\* Move to: (.+)$")
_FRAME = re.compile(r"^\*\*\* (Delete File|End Patch|Begin Patch)")


def read_payload():
    """Parse the Codex hook JSON from stdin; return {} on failure (fail open)."""
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def parse_targets(tool_input):
    """Return [(path, full_content_or_None)] for each write target in a Codex payload.

    Handles the direct Edit/Write shape (tool_input.file_path) and the apply_patch envelope
    (patch text in tool_input.command), reconstructing whole-file content for Add hunks. Used for
    overwrite protection and the lint; whether a patch may touch the context cache at all is
    decided separately, by reaches_cache() and cache_add().
    Callers that only need paths iterate `for path, _ in parse_targets(...)`.
    """
    fp = tool_input.get("file_path")
    if fp:
        return [(fp, tool_input.get("content"))]
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return []
    targets = []
    cur_path, is_add, buf = None, False, []

    def flush():
        if cur_path is not None:
            targets.append((cur_path, "".join(buf) if is_add else None))

    for line in cmd.splitlines():
        m = _ADD_UPDATE.match(line)
        mv = _MOVE_TO.match(line)
        if m:
            flush()
            cur_path, is_add, buf = m.group(2).strip(), (m.group(1) == "Add"), []
        elif _FRAME.match(line):
            flush()
            cur_path, is_add, buf = None, False, []
        elif mv:
            targets.append((mv.group(1).strip(), None))
        elif cur_path is not None and is_add and line.startswith("+"):
            buf.append(line[1:] + "\n")
    flush()
    return targets


# --- The context cache ----------------------------------------------------------------------
# The confirmation check itself lives in hooks/otel-context-check.py (run by write-guard.sh) and
# needs the whole file as it will be. An apply_patch Update, Move or Delete gives a diff, and
# rebuilding the result here would be a second patch parser that can disagree with apply_patch's
# own (#254: every attempt to mirror it was bypassed by some parsing difference). So a patch that
# could reach the cache is let through only as one full-file Add; anything else is denied, and the
# real file is checked again from disk after a patch lands (post-tool-use.py).

CACHE_NAME = "otel-context.json"
_HEADERISH = re.compile(r"^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+)$")


def _fold(text):
    """Text compared the way a case-insensitive filesystem might: Unicode-normalised, case-folded."""
    return unicodedata.normalize("NFKC", text).casefold()


def resolves_to_cache(path, cwd):
    """True when `path` is the cache, or reaches it through a symlink or hard link."""
    full = os.path.join(cwd, path)
    if is_context_path(_fold(path)) or is_context_path(_fold(os.path.realpath(full))):
        return True
    cache = os.path.join(cwd, ".claude", CACHE_NAME)
    try:
        return os.path.exists(full) and os.path.exists(cache) and os.path.samefile(full, cache)
    except OSError:
        return False


def patch_paths(tool_input):
    """Every path a write names: the direct file_path, or the path on every header-like line of a
    patch, indented or not and inside a hunk or not (more than apply_patch reads, never fewer)."""
    if tool_input.get("file_path"):
        return [tool_input["file_path"]]
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return []
    found = (_HEADERISH.match(line.strip()) for line in cmd.splitlines())
    return [m.group(1).strip() for m in found if m]


def reaches_cache(tool_input, cwd):
    """True when this write could touch the context cache. Errs towards True: every header-like
    line is read, indented or not and inside a hunk or not, and its path counts when it names the
    cache in any case or Unicode form or reaches it through a link. Mentions of the cache in file
    content ("+" lines) don't count, so docs that talk about it can still be edited."""
    return any(resolves_to_cache(path, cwd) for path in patch_paths(tool_input))


def cache_add(cmd):
    """(path, content) when the patch is exactly one "*** Add File:" of the cache, by its own
    name, with nothing but "+" lines; otherwise None. The lines are taken as written, not
    trimmed, so the Add this accepts is the same one parse_targets() reads and write-guard checks;
    only surrounding whitespace and a heredoc wrapper are dropped, as apply_patch drops them."""
    if not isinstance(cmd, str):
        return None
    lines = cmd.strip().splitlines()
    if len(lines) >= 4 and lines[0] in ("<<EOF", "<<'EOF'", '<<"EOF"') and lines[-1].endswith("EOF"):
        lines = lines[1:-1]
    if len(lines) < 3 or lines[0] != "*** Begin Patch" or lines[-1] != "*** End Patch":
        return None
    m = re.match(r"^\*\*\* Add File: (.+)$", lines[1])
    if not m or not is_context_path(m.group(1).strip()):
        return None
    if not all(line.startswith("+") for line in lines[2:-1]):
        return None
    return m.group(1).strip(), "".join(line[1:] + "\n" for line in lines[2:-1])


def unconfirmed_on_disk(path, cwd):
    """Names of unconfirmed business attributes in the cache file at `path` as it is on disk,
    found by hooks/otel-context-check.py. Empty when the file can't be read."""
    try:
        with open(os.path.join(cwd, path), encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return []
    synth = {"tool_name": "Write", "tool_input": {"file_path": path, "content": content}}
    proc = subprocess.run(
        [sys.executable, os.path.join(ROOT, "hooks", "otel-context-check.py")],
        input=json.dumps(synth), text=True, capture_output=True, cwd=cwd,
    )
    return [n for n in proc.stdout.splitlines() if n.strip()]


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

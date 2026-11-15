#!/usr/bin/env python3
"""Apply and remove /otel-why's probe spans, so that removing them is exact rather than left to
a model's memory of what it changed.

A probe is a small edit that wraps one suspect call in a timing span. The agent decides where the
probes go; this script makes the edits and records each one in <root>/.claude/otel-probes.json:
the file, the exact original text and the exact replacement. Removal swaps each replacement back
for its original, newest first, which restores the file byte for byte. The baseline
instrumentation (tracing.js and friends) is never touched.

  probes.py helper --lang nodejs|python --dir DIR [--root R] [--plugin-root P]
      Write the probe helper (otel-probe.js or otel_probe.py) into DIR from the plugin's template,
      stamped with the plugin version and the ownership marker. Refuses to overwrite a file that
      is not the helper this manifest recorded.

  probes.py apply --spec FILE|- [--root R]
      FILE is a JSON list of {"id", "file", "find", "replace"}. Each `find` must occur exactly once
      in its file (after the earlier probes in the list are applied), and each `replace` must
      carry the begin and end marker lines for its id:
          // otel-as-code: probe begin <id>        (# for Python)
          // otel-as-code: probe end <id>
      All probes are checked before anything is written; one bad probe writes nothing.

  probes.py remove [--root R] [--dry-run]
      Restore every probed file and delete the helpers, all or nothing. Refuses, and writes
      nothing, when a probe block or a helper was edited after it was applied: restoring it would
      throw the edit away. --dry-run prints the plan and exits 1 if anything would be removed.

  probes.py list [--root R]
      Print the recorded probes and helpers.

Exit 0 on success, 1 with a one-line REFUSED: reason and nothing written on any refusal.
Standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile

MANIFEST = os.path.join(".claude", "otel-probes.json")
HELPERS = {"nodejs": "otel-probe.js", "python": "otel_probe.py"}
COMMENT = {".py": "#"}  # everything else the probes support uses //
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
MARKER_RE = re.compile(r"otel-as-code: probe (?:begin|end) ")


def fail(msg):
    print(f"REFUSED: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write_atomically(path, text):
    """Temp file beside the target, then rename, so an interrupted write never leaves half a file."""
    target = os.path.realpath(path)
    try:
        mode = os.stat(target).st_mode & 0o7777
    except FileNotFoundError:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(prefix=".otel-probe.", suffix=".tmp", dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def inside(root, rel):
    """rel as a path under root, or None when it escapes root."""
    full = os.path.realpath(os.path.join(root, rel))
    base = os.path.realpath(root)
    return full if full == base or full.startswith(base + os.sep) else None


def load_manifest(root):
    path = os.path.join(root, MANIFEST)
    try:
        doc = json.loads(read(path))
    except FileNotFoundError:
        return {"version": 1, "helpers": [], "probes": []}
    except (OSError, ValueError) as e:
        fail(f"{path} can't be read ({e}); fix or remove it by hand before probing again.")
    if not isinstance(doc, dict) or not isinstance(doc.get("probes"), list) \
            or not isinstance(doc.get("helpers"), list):
        fail(f"{path} is not a probe manifest; fix or remove it by hand.")
    return doc


def save_manifest(root, doc):
    os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
    write_atomically(os.path.join(root, MANIFEST), json.dumps(doc, indent=2) + "\n")


def plugin_version(plugin_root):
    try:
        return json.loads(read(os.path.join(plugin_root, ".claude-plugin", "plugin.json")))["version"]
    except (OSError, ValueError, KeyError) as e:
        fail(f"can't read the plugin version from {plugin_root}: {e}")


def cmd_helper(args):
    root = os.path.abspath(args.root)
    name = HELPERS[args.lang]
    rel = os.path.relpath(os.path.join(os.path.abspath(args.dir), name), root)
    full = inside(root, rel)
    if full is None:
        fail(f"{args.dir} is outside the project root {root}.")
    plugin_root = args.plugin_root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    template = read(os.path.join(plugin_root, "scripts", "probe-templates", name))
    text = template.replace("{{VERSION}}", plugin_version(plugin_root))
    doc = load_manifest(root)
    recorded = {h["path"]: h for h in doc["helpers"]}
    if os.path.exists(full):
        if rel in recorded and sha256(read(full)) == recorded[rel]["sha256"]:
            print(f"OK: {rel} is already in place")
            return 0
        fail(f"{rel} already exists and is not the probe helper this session wrote; "
             f"nothing written. Move it aside or pick another directory.")
    if not os.path.isdir(os.path.dirname(full)):
        fail(f"{os.path.dirname(rel) or '.'} is not a directory.")
    write_atomically(full, text)
    doc["helpers"] = [h for h in doc["helpers"] if h["path"] != rel] + [{"path": rel, "sha256": sha256(text)}]
    save_manifest(root, doc)
    print(f"OK: wrote {rel}")
    return 0


def check_probe(p, i, ids):
    if not isinstance(p, dict) or not all(isinstance(p.get(k), str) for k in ("id", "file", "find", "replace")):
        fail(f"probe {i} needs string fields id, file, find and replace.")
    pid = p["id"]
    if not ID_RE.match(pid):
        fail(f"probe id {pid!r} must be lowercase letters, digits and dashes.")
    if pid in ids:
        fail(f"probe id {pid!r} is used twice.")
    if p["find"] == "" or p["find"] == p["replace"]:
        fail(f"probe {pid}: find must be non-empty and differ from replace.")
    c = COMMENT.get(os.path.splitext(p["file"])[1], "//")
    for edge in ("begin", "end"):
        if not re.search(rf"^[ \t]*{re.escape(c)} otel-as-code: probe {edge} {re.escape(pid)}[ \t]*$",
                         p["replace"], re.M):
            fail(f"probe {pid}: replace must carry the line `{c} otel-as-code: probe {edge} {pid}`.")
    if MARKER_RE.search(p["find"]):
        fail(f"probe {pid}: find overlaps another probe's markers; probes can't nest.")


def cmd_apply(args):
    root = os.path.abspath(args.root)
    try:
        spec = json.loads(sys.stdin.read() if args.spec == "-" else read(args.spec))
    except (OSError, ValueError) as e:
        fail(f"spec can't be read as JSON: {e}")
    if not isinstance(spec, list) or not spec:
        fail("spec must be a non-empty JSON list of probes.")
    doc = load_manifest(root)
    ids = {p["id"] for p in doc["probes"]}
    texts = {}  # rel -> current text, with the earlier probes in this spec applied
    for i, p in enumerate(spec):
        check_probe(p, i, ids)
        ids.add(p["id"])
        full = inside(root, p["file"])
        if full is None or not os.path.isfile(full):
            fail(f"probe {p['id']}: {p['file']} is not a file under {root}.")
        rel = os.path.relpath(full, os.path.realpath(root))
        if rel not in texts:
            texts[rel] = read(full)
        n = texts[rel].count(p["find"])
        if n != 1:
            fail(f"probe {p['id']}: the find text occurs {n} times in {rel}; it must occur exactly once. "
                 f"Nothing written.")
        texts[rel] = texts[rel].replace(p["find"], p["replace"])
        p["file"] = rel
    for rel, text in texts.items():
        write_atomically(os.path.join(os.path.realpath(root), rel), text)
    doc["probes"] += [{"id": p["id"], "file": p["file"], "original": p["find"], "replacement": p["replace"]}
                      for p in spec]
    save_manifest(root, doc)
    print(f"OK: applied {len(spec)} probe(s) in {len(texts)} file(s)")
    return 0


def cmd_remove(args):
    root = os.path.realpath(args.root)
    doc = load_manifest(root)
    if not doc["probes"] and not doc["helpers"]:
        print("OK: no probes recorded; nothing to remove")
        return 0
    texts, problems = {}, []
    for p in reversed(doc["probes"]):
        full = inside(root, p["file"])
        if full is None or not os.path.isfile(full):
            problems.append(f"{p['file']} (probe {p['id']}) is gone")
            continue
        texts.setdefault(p["file"], read(full))
        n = texts[p["file"]].count(p["replacement"])
        if n != 1:
            problems.append(f"probe {p['id']} in {p['file']} was edited after it was applied")
            continue
        texts[p["file"]] = texts[p["file"]].replace(p["replacement"], p["original"])
    helpers = []
    for h in doc["helpers"]:
        full = inside(root, h["path"])
        if full is None or not os.path.exists(full):
            continue  # already gone: nothing to remove
        if sha256(read(full)) != h["sha256"]:
            problems.append(f"{h['path']} was edited after it was written")
        else:
            helpers.append(full)
    if problems:
        fail("nothing removed, because " + "; ".join(problems) +
             ". Undo those edits or remove the probe by hand, then run this again.")
    for rel, text in texts.items():
        print(f"{'would restore' if args.dry_run else 'restored'}: {rel}")
    for full in helpers:
        print(f"{'would delete' if args.dry_run else 'deleted'}: {os.path.relpath(full, root)}")
    if args.dry_run:
        return 1
    for rel, text in texts.items():
        write_atomically(os.path.join(root, rel), text)
    for full in helpers:
        os.unlink(full)
    os.unlink(os.path.join(root, MANIFEST))
    try:
        os.rmdir(os.path.join(root, ".claude"))  # only when the manifest was all it held
    except OSError:
        pass
    left = [rel for rel, text in texts.items() if MARKER_RE.search(text)]
    if left:
        print(f"note: probe markers not in the manifest remain in {', '.join(left)}; remove them by hand.")
    print(f"OK: removed {len(doc['probes'])} probe(s) and {len(helpers)} helper file(s); the baseline is untouched")
    return 0


def cmd_list(args):
    doc = load_manifest(os.path.abspath(args.root))
    for h in doc["helpers"]:
        print(f"helper: {h['path']}")
    for p in doc["probes"]:
        print(f"probe {p['id']}: {p['file']}")
    if not doc["probes"] and not doc["helpers"]:
        print("no probes recorded")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("helper")
    h.add_argument("--lang", choices=sorted(HELPERS), required=True)
    h.add_argument("--dir", required=True)
    h.add_argument("--plugin-root")
    a = sub.add_parser("apply")
    a.add_argument("--spec", required=True)
    r = sub.add_parser("remove")
    r.add_argument("--dry-run", action="store_true")
    sub.add_parser("list")
    for s in (h, a, r, sub.choices["list"]):
        s.add_argument("--root", default=".")
    args = p.parse_args(argv)
    return {"helper": cmd_helper, "apply": cmd_apply, "remove": cmd_remove, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())

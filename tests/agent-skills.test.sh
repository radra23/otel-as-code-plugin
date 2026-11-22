#!/usr/bin/env bash
# tests/agent-skills.test.sh
# #268: the guidance skills are published in the Agent Skills format (https://agentskills.io/specification)
# for `npx skills add radra23/otel-as-code-plugin`, and nothing else is. The `skills` CLI scans
# skills/, .agents/skills/ and .claude/skills/ and hides a skill whose frontmatter has
# `metadata.internal: "true"`. Offline: frontmatter is read here, the CLI is not run.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, os, re, sys

PUBLISHED = {"semconv-discipline", "language-maturity", "collector-topology", "terraform-patterns"}
SPEC_KEYS = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
passed = failed = 0


def check(ok, msg):
    global passed, failed
    print(("PASS: " if ok else "FAIL: ") + msg)
    passed += bool(ok)
    failed += not ok


def frontmatter(path):
    """Top-level keys (one line each) and the `metadata:` block (two-space indented string values)."""
    text = open(path, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, {}, text
    top, meta, in_meta = {}, {}, False
    for line in m.group(1).splitlines():
        if in_meta and line.startswith("  "):
            k, _, v = line.strip().partition(":")
            meta[k.strip()] = v.strip()
            continue
        in_meta = False
        k, _, v = line.partition(":")
        top[k.strip()] = v.strip()
        in_meta = k.strip() == "metadata" and not v.strip()
    return top, meta, text[m.end():]


skills = sorted(glob.glob("skills/*/SKILL.md") + glob.glob(".agents/skills/*/SKILL.md")
                + glob.glob(".claude/skills/*/SKILL.md"))
visible = set()
for path in skills:
    top, meta, body = frontmatter(path)
    d = os.path.basename(os.path.dirname(path))
    if top is None:
        check(False, f"{path} has frontmatter"); continue
    internal = meta.get("internal", "").strip('"') in ("true", "1")
    if not internal:
        visible.add(path)
    if path.startswith("skills/") and d in PUBLISHED:
        name, desc = top.get("name", ""), top.get("description", "").strip('"')
        check(name == d and len(name) <= 64 and NAME.match(name),
              f"{path}: name {name!r} follows the spec and matches its folder")
        check(0 < len(desc) <= 1024, f"{path}: description is 1 to 1024 characters ({len(desc)})")
        extra = set(top) - SPEC_KEYS
        check(not extra, f"{path}: only Agent Skills frontmatter keys (extra: {sorted(extra) or 'none'})")
        check(all(re.match(r'^".*"$', v) for v in meta.values()),
              f"{path}: metadata values are strings")
        check("CLAUDE_PLUGIN_ROOT" not in body, f"{path}: no ${{CLAUDE_PLUGIN_ROOT}}, which only Claude Code sets")
        here = os.path.dirname(path)
        links = [t for t in re.findall(r"\]\(([^)#]+)\)", body) if not re.match(r"[a-z]+:", t)]
        # Data and script files named bare (`runtime-panels.json`) are read from the skill's own folder.
        # A bare `.md` name is not checked: the skills cite upstream docs that way (ntfy's `publish.md`).
        files = re.findall(r"`([A-Za-z0-9_.-]+\.(?:json|yaml|yml|py|sh))`", body)
        missing = [t for t in links + files if not os.path.exists(os.path.join(here, t))]
        check(not missing, f"{path}: every file it links or names by itself is in its own folder (missing: {missing or 'none'})")
    else:
        check(internal, f"{path} is marked metadata.internal, so `npx skills add` does not offer it")

want = {f"skills/{n}/SKILL.md" for n in PUBLISHED}
check(visible == want, f"`npx skills add` sees exactly the four guidance skills (sees: {sorted(visible)})")
print(f"\nagent-skills: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY

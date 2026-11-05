#!/usr/bin/env python3
"""Validate-and-write helper for .claude/otel-context.json (#211).

The scanner (agents/repo-context-scanner.md) is read-only and returns its result as a ~10 KB
JSON string in its final message. Before this script existed, the dispatching command had to
transcribe that string into a Write call by hand -- a long verbatim copy by a model, exactly
where silent truncation, re-ordering, or a dropped field happens. This script takes over the
actual write, and enforces in code the three rules a transcription can't reliably check:

  1. A refresh must never EMPTY a user-owned field that the prior cache had non-empty
     (businessAttrs, confirmedAt, namespace, deploymentEnvironment, per-service
     namespace/team when user-confirmed, scopeOverride) -- the cache ownership contract in
     repo-context-scanner.md, enforced here rather than trusted to be followed.
  2. services going from non-empty to empty is refused by default (#164) -- a legitimate full
     deletion is possible, but it must be an explicit, confirmed decision, not an artifact of a
     scan that happened to come back empty. Pass --allow-empty-services to override once the
     command has confirmed with the user.
  3. scannedAt and pluginVersion must be real, not a copied schema placeholder (#177, #202):
     scannedAt must parse as a real UTC timestamp close to "now" (checked relative to this
     script's own clock -- the scanner has none of its own, which is exactly the bug this
     check exists to catch), and pluginVersion must match the version this plugin's own
     installed plugin.json actually declares, when --plugin-root is given.

Exit 0 and a written file on success. Exit 1 with a one-line reason and NOTHING written on any
safety-rule failure -- refusing to write is always safer than writing something wrong, the same
principle this plugin applies everywhere else (instrumentation-gen's "emitting wrong code is
worse than emitting none").

Usage:
    <scanner JSON on stdin> | python3 scripts/write_context.py \\
        --output .claude/otel-context.json \\
        [--existing .claude/otel-context.json] \\
        [--plugin-root /path/to/plugin] \\
        [--allow-empty-services]
"""
import argparse
import json
import sys
from datetime import datetime, timezone, timedelta

# How far scannedAt may drift from this script's own clock before it's treated as implausible
# (a copied placeholder, or a clock on a very different machine) rather than "just scanned."
MAX_SCANNEDAT_SKEW = timedelta(hours=6)

# User-owned fields per the cache ownership contract (repo-context-scanner.md) -- carried over
# from priorContext verbatim, and the one thing a refresh must never silently empty.
TOP_LEVEL_USER_OWNED = ["businessAttrs", "confirmedAt", "namespace", "deploymentEnvironment"]


def fail(msg):
    print(f"REFUSED: {msg}", file=sys.stderr)
    sys.exit(1)


def is_empty(value):
    return value is None or value == "" or value == [] or value == {}


def check_top_level_user_owned(old, new):
    for key in TOP_LEVEL_USER_OWNED:
        old_val = old.get(key)
        new_val = new.get(key)
        if not is_empty(old_val) and is_empty(new_val):
            fail(
                f"top-level '{key}' would go from {old_val!r} to {new_val!r} -- a refresh must "
                f"never empty a user-owned field. Pass the existing cache as priorContext to the "
                f"scanner so it carries this over, per the cache ownership contract."
            )


def check_per_service_user_owned(old, new):
    old_by_id = {s.get("id"): s for s in old.get("services", []) if s.get("id") is not None}
    for svc in new.get("services", []):
        sid = svc.get("id")
        if sid is None or sid not in old_by_id:
            continue
        old_svc = old_by_id[sid]
        if old_svc.get("namespaceSource") == "user-confirmed" and not is_empty(old_svc.get("namespace")) \
                and is_empty(svc.get("namespace")):
            fail(
                f"services[id={sid}].namespace was user-confirmed ({old_svc.get('namespace')!r}) "
                f"and would be emptied by this refresh."
            )
        if old_svc.get("teamSource") == "user-confirmed" and not is_empty(old_svc.get("team")) \
                and is_empty(svc.get("team")):
            fail(
                f"services[id={sid}].team was user-confirmed ({old_svc.get('team')!r}) and "
                f"would be emptied by this refresh."
            )
        if not is_empty(old_svc.get("scopeOverride")) and is_empty(svc.get("scopeOverride")):
            fail(
                f"services[id={sid}].scopeOverride ({old_svc.get('scopeOverride')!r}) would be "
                f"dropped by this refresh -- #207's override exists specifically to survive a "
                f"re-scan; losing it here defeats the point."
            )


def check_empty_services(old, new, allow_empty_services):
    old_services = old.get("services", []) if old else []
    new_services = new.get("services", [])
    if old_services and not new_services and not allow_empty_services:
        fail(
            f"services would go from {len(old_services)} to 0 (#164). If this is a real, "
            f"confirmed deletion, re-run with --allow-empty-services after confirming with the "
            f"user -- do not pass that flag just to make this check stop complaining."
        )


def check_scanned_at(new):
    scanned_at = new.get("scannedAt")
    if not scanned_at:
        fail("scannedAt is missing or null -- the dispatching command must pass a real scanTime.")
    try:
        parsed = datetime.strptime(scanned_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        fail(f"scannedAt {scanned_at!r} is not a real UTC timestamp (YYYY-MM-DDTHH:MM:SSZ).")
        return
    now = datetime.now(timezone.utc)
    skew = abs(now - parsed)
    if skew > MAX_SCANNEDAT_SKEW:
        fail(
            f"scannedAt {scanned_at!r} is {skew} away from now ({now.strftime('%Y-%m-%dT%H:%M:%SZ')}) "
            f"-- further than the {MAX_SCANNEDAT_SKEW} tolerance. This is exactly the #202 bug: a "
            f"subagent with no clock copying the schema's own example timestamp instead of the "
            f"real scanTime it was passed."
        )
    # Midnight-exactly is the literal example literal this plugin's own docs warn about
    # (#177/#202: "every subagent that has done so has produced midnight"). A real scan
    # landing on the exact second is possible but vanishingly unlikely; flag it rather than
    # silently trust it.
    if parsed.hour == 0 and parsed.minute == 0 and parsed.second == 0:
        fail(
            f"scannedAt {scanned_at!r} is exactly midnight UTC -- the known signature of an "
            f"invented timestamp (#177/#202), not a real scanTime. If this really is a genuine "
            f"scan that happened to land on the second, this check has a false positive; look at "
            f"why scanTime wasn't passed through instead of bypassing it."
        )


def check_plugin_version(new, plugin_root):
    if not plugin_root:
        return  # Not checkable without knowing where the plugin is installed.
    version = new.get("pluginVersion")
    if not version:
        fail("pluginVersion is missing or null -- the dispatching command must pass the real version.")
    manifest_path = f"{plugin_root}/.claude-plugin/plugin.json"
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except OSError as e:
        fail(f"could not read {manifest_path} to verify pluginVersion: {e}")
        return
    real_version = manifest.get("version")
    if version != real_version:
        fail(
            f"pluginVersion {version!r} does not match the installed plugin's real version "
            f"{real_version!r} ({manifest_path}) -- this is the #177 bug: copying the schema's "
            f"own example literal instead of the real installed version."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="Path to write .claude/otel-context.json to")
    parser.add_argument("--existing", help="Path to the existing cache, if any, for merge-safety checks")
    parser.add_argument("--plugin-root", help="${CLAUDE_PLUGIN_ROOT}, to verify pluginVersion against")
    parser.add_argument("--allow-empty-services", action="store_true",
                         help="Allow services to go from non-empty to empty (confirm with the user first)")
    args = parser.parse_args()

    raw = sys.stdin.read()
    try:
        new = json.loads(raw)
    except json.JSONDecodeError as e:
        fail(f"stdin is not valid JSON ({e}) -- nothing written. This is exactly the failure mode "
             f"this script exists to catch before it reaches disk.")
        return

    if not isinstance(new.get("services"), list):
        fail("'services' is missing or not a list -- not a valid context object.")
    if "schemaVersion" not in new:
        fail("'schemaVersion' is missing -- not a valid context object.")

    check_scanned_at(new)
    check_plugin_version(new, args.plugin_root)

    old = None
    if args.existing:
        try:
            with open(args.existing, encoding="utf-8") as f:
                old = json.load(f)
        except FileNotFoundError:
            old = None  # No existing cache is a legitimate first-scan case, not an error.
        except json.JSONDecodeError as e:
            fail(f"--existing {args.existing} is not valid JSON ({e}) -- refusing to merge against "
                 f"a cache that can't actually be read; fix or remove it first.")

    if old is not None:
        check_top_level_user_owned(old, new)
        check_per_service_user_owned(old, new)
        check_empty_services(old, new, args.allow_empty_services)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(new, f, indent=2)
        f.write("\n")
    print(f"OK: wrote {args.output} ({len(new.get('services', []))} service(s))")


if __name__ == "__main__":
    main()

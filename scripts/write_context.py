#!/usr/bin/env python3
"""Validate-and-write helper for .claude/otel-context.json (#211).

The scanner (agents/repo-context-scanner.md) is read-only and returns its result as a ~10 KB
JSON string in its final message. Before this script existed, the dispatching command had to
transcribe that string into a Write call by hand -- a long verbatim copy by a model, exactly
where silent truncation, re-ordering, or a dropped field happens. This script takes over the
actual write, and enforces in code the rules a transcription can't reliably check:

  1. A refresh must never EMPTY a user-owned field that the prior cache had non-empty
     (businessAttrs, confirmedAt, namespace, deploymentEnvironment, per-service
     namespace/team when user-confirmed, scopeOverride, a resolved conflicts[] entry, a
     user-added service) -- the cache ownership contract in repo-context-scanner.md, enforced
     here rather than trusted to be followed.
  2. services going from non-empty to empty is refused by default (#164) -- a legitimate full
     deletion is possible, but it must be an explicit, confirmed decision, not an artifact of a
     scan that happened to come back empty. Pass --allow-empty-services to override once the
     command has confirmed with the user.
  3. scannedAt and pluginVersion must be real, not a copied schema placeholder (#177, #202):
     scannedAt must parse as a real UTC timestamp close to "now" (checked relative to this
     script's own clock -- the scanner has none of its own, which is exactly the bug this
     check exists to catch), and pluginVersion must match the version this plugin's own
     installed plugin.json actually declares, when --plugin-root is given.
  4. Every businessAttrs entry must carry "confirmed": true, on every write, first scan included.
     Business semantics are never assumed: /otel-business-attrs records an attribute only after
     the user approves it. hooks/write-guard.sh enforces the same rule on a Write of this file,
     but the commands write the cache through this script from the shell, which the hook never
     sees, so the rule has to live here too or it is not enforced at all.
  5. Every field scripts/context-schema.json gives a type holds that type or null (#257): a
     confidence written as the string "0.9", or inScope as "false" (truthy), is refused rather
     than handed to every command that reads the cache.

Exit 0 and a written file on success. Exit 1 with a one-line reason and NOTHING written on any
safety-rule failure, including an I/O or parse error encountered while enforcing a rule, or an
input (stdin or --existing) that is not a context object of the expected shape --
refusing to write is always safer than writing something wrong, or crashing with a traceback
instead of the one-line reason this script exists to produce, the same principle this plugin
applies everywhere else (instrumentation-gen's "emitting wrong code is worse than emitting
none"). The file is written to a temp file beside the cache and renamed over it, so an
interrupted write (Ctrl-C, a full disk, a killed session) leaves the old cache whole.

Usage:
    <scanner JSON on stdin> | python3 scripts/write_context.py \\
        --output .claude/otel-context.json \\
        [--existing .claude/otel-context.json] \\
        [--plugin-root /path/to/plugin] \\
        [--allow-empty-services]
"""
import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone, timedelta

# How far scannedAt may drift from this script's own clock before it's treated as implausible
# (a copied placeholder, or a clock on a very different machine) rather than "just scanned."
MAX_SCANNEDAT_SKEW = timedelta(hours=6)

# Who owns each field (#257): scripts/context-schema.json, beside this script, the machine-readable
# form of the cache ownership contract in repo-context-scanner.md (tests/context-schema.test.sh
# holds the two to the same fields). The user-owned fields are carried over from priorContext
# verbatim, and are the one thing a refresh must never silently empty.
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "context-schema.json")
try:
    with open(SCHEMA_PATH, encoding="utf-8") as _f:
        SCHEMA = json.load(_f)
except (OSError, ValueError) as _e:
    print(f"REFUSED: cannot read the ownership schema {SCHEMA_PATH}: {_e}", file=sys.stderr)
    sys.exit(1)
TOP_LEVEL_USER_OWNED = SCHEMA["topLevel"]["user"]
SERVICE_USER_OWNED = SCHEMA["services"]["user"]
SERVICE_USER_WHEN_CONFIRMED = SCHEMA["services"]["userWhenConfirmed"]
CONFIRMED = SCHEMA["services"]["confirmedValue"]
USER_ADDED = SCHEMA["services"]["userAdded"]
CONFLICT_KEY = SCHEMA["conflicts"]["matchBy"]
# Each field's JSON type, or null. bool is excluded from "number" because Python makes it an int.
JSON_TYPES = {"string": (str,), "number": (int, float), "boolean": (bool,), "array": (list,),
              "object": (dict,)}


def fail(msg):
    print(f"REFUSED: {msg}", file=sys.stderr)
    sys.exit(1)


def check_shape(doc, label):
    """Refuse a document the checks below can't safely read: they call .get() on the document,
    on every services[] and conflicts[] entry, and parse scannedAt as a string."""
    if not isinstance(doc, dict):
        fail(f"{label} is a JSON {type(doc).__name__}, not an object -- not a valid context object.")
    for key in ("services", "conflicts"):
        entries = doc.get(key, [])
        if not isinstance(entries, list):
            fail(f"{label} '{key}' is not a list -- not a valid context object.")
        for i, entry in enumerate(entries):
            if not isinstance(entry, dict):
                fail(f"{label} {key}[{i}] is {entry!r}, not an object -- not a valid context object.")
    if "scannedAt" in doc and doc["scannedAt"] is not None and not isinstance(doc["scannedAt"], str):
        fail(f"{label} scannedAt {doc['scannedAt']!r} is not a string timestamp.")


def check_types(doc):
    """Every field the schema types holds that type or null; a field it doesn't list is not
    checked. A wrong type (a confidence written as "0.9", inScope as "true") is refused here
    because every later reader would otherwise act on it: the string "false" is truthy."""
    def check(fields, where, types):
        for key, expected in types.items():
            value = fields.get(key)
            if value is None:
                continue
            ok = isinstance(value, JSON_TYPES[expected])
            if expected == "number" and isinstance(value, bool):
                ok = False
            if not ok:
                fail(f"{where}{key} is {value!r} ({type(value).__name__}), not a JSON {expected} "
                     f"or null, per {SCHEMA_PATH} -- nothing written.")
    check(doc, "", SCHEMA["topLevel"]["types"])
    for key in ("services", "conflicts"):
        for i, entry in enumerate(doc.get(key) or []):
            check(entry, f"{key}[{i}].", SCHEMA[key]["types"])


def write_atomically(path, doc):
    """Write doc to a temp file in path's directory, then rename it over path: os.replace is
    atomic on the same filesystem, so a reader sees the old cache or the new one, never half."""
    target = os.path.realpath(path)  # replace a symlink's target, not the link itself
    try:
        mode = os.stat(target).st_mode & 0o7777
    except FileNotFoundError:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask  # what a plain open(path, "w") would have created
    fd, tmp = tempfile.mkstemp(prefix=".otel-context.", suffix=".tmp", dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)  # mkstemp creates 0600
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
        for field, rule in SERVICE_USER_WHEN_CONFIRMED.items():
            if old_svc.get(rule["sourceField"]) == CONFIRMED and not is_empty(old_svc.get(field)) \
                    and is_empty(svc.get(field)):
                fail(
                    f"services[id={sid}].{field} was user-confirmed ({old_svc.get(field)!r}) "
                    f"and would be emptied by this refresh."
                )
        for field in SERVICE_USER_OWNED:
            if not is_empty(old_svc.get(field)) and is_empty(svc.get(field)):
                why = (" -- #207's override exists specifically to survive a re-scan; losing it "
                       "here defeats the point.") if field == "scopeOverride" else "."
                fail(f"services[id={sid}].{field} ({old_svc.get(field)!r}) would be dropped by "
                     f"this refresh{why}")


def check_conflicts_resolution(old, new):
    old_conflicts = {tuple(c.get(k) for k in CONFLICT_KEY): c for c in old.get("conflicts", [])}
    new_conflicts = {tuple(c.get(k) for k in CONFLICT_KEY): c for c in new.get("conflicts", [])}
    for key, old_c in old_conflicts.items():
        was_resolved = not is_empty(old_c.get("resolvedValue")) or bool(old_c.get("conflict_resolved"))
        if not was_resolved:
            continue
        new_c = new_conflicts.get(key)
        service_id, attribute = key
        if new_c is None:
            fail(
                f"conflicts[serviceId={service_id!r}, attribute={attribute!r}] was resolved "
                f"(resolvedValue={old_c.get('resolvedValue')!r}) and is missing entirely from "
                f"this refresh -- a resolved conflict must be carried forward, matched by "
                f"(serviceId, attribute), per the cache ownership contract."
            )
        elif is_empty(new_c.get("resolvedValue")) and not new_c.get("conflict_resolved"):
            fail(
                f"conflicts[serviceId={service_id!r}, attribute={attribute!r}].resolvedValue "
                f"was {old_c.get('resolvedValue')!r} and would be reset by this refresh -- a "
                f"resolved conflict must survive a rescan."
            )


def check_user_added_services(old, new):
    new_ids = {s.get("id") for s in new.get("services", [])}
    for svc in old.get("services", []):
        if svc.get(USER_ADDED["field"]) == USER_ADDED["value"] and svc.get("id") not in new_ids:
            fail(
                f"services[id={svc.get('id')!r}] was added manually by the user "
                f"(nameSource: \"user-added\") and is absent from this refresh -- a user-added "
                f"service must be kept, not silently dropped, per the cache ownership contract."
            )


def check_empty_services(old, new, allow_empty_services):
    old_services = old.get("services", [])
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
    except json.JSONDecodeError as e:
        fail(f"{manifest_path} is not valid JSON ({e}) -- cannot verify pluginVersion against it.")
    real_version = manifest.get("version")
    if version != real_version:
        fail(
            f"pluginVersion {version!r} does not match the installed plugin's real version "
            f"{real_version!r} ({manifest_path}) -- this is the #177 bug: copying the schema's "
            f"own example literal instead of the real installed version."
        )


def check_business_attrs_confirmed(new):
    """Rule 4: the same test hooks/write-guard.sh applies to a Write of the cache."""
    attrs = new.get("businessAttrs") or []
    if not isinstance(attrs, list):
        fail("'businessAttrs' is not a list -- not a valid context object.")
    unconfirmed = [a.get("name", "?") for a in attrs
                   if isinstance(a, dict) and a.get("confirmed") is not True]
    if unconfirmed:
        fail(f"refusing to write unconfirmed business attribute(s): {', '.join(unconfirmed)}. "
             f"Each needs \"confirmed\": true, set only after the user approves it in "
             f"/otel-business-attrs -- nothing written.")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
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

    check_shape(new, "stdin")
    if not isinstance(new.get("services"), list):
        fail("'services' is missing or not a list -- not a valid context object.")
    if "schemaVersion" not in new:
        fail("'schemaVersion' is missing -- not a valid context object.")
    check_types(new)

    check_scanned_at(new)
    check_plugin_version(new, args.plugin_root)
    check_business_attrs_confirmed(new)

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
        except (OSError, UnicodeDecodeError) as e:
            fail(f"could not read --existing {args.existing}: {e} -- refusing to merge against a "
                 f"cache that can't actually be read; fix or remove it first.")
        if old is not None:
            check_shape(old, f"--existing {args.existing}")

    if old is not None:
        check_top_level_user_owned(old, new)
        check_per_service_user_owned(old, new)
        check_user_added_services(old, new)
        check_conflicts_resolution(old, new)
        check_empty_services(old, new, args.allow_empty_services)

    try:
        write_atomically(args.output, new)
    except OSError as e:
        fail(f"could not write {args.output}: {e}")
    print(f"OK: wrote {args.output} ({len(new.get('services', []))} service(s))")


if __name__ == "__main__":
    main()

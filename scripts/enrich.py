#!/usr/bin/env python3
"""Add and remove /otel-enrich's in-code telemetry: the one place this plugin edits code a person
wrote, so the edit is made by code, shown as a diff first, and removable exactly.

Every enrichment is INSERT-ONLY: new lines between two marker comments, never a changed line.

    // otel-as-code: enrich begin <id>        (# in Python)
    ...lines this script added...
    // otel-as-code: enrich end <id>

So removal needs no record of what was there before: it deletes the marker blocks and nothing
else. That matters because enrichment is committed and lives for months, long after any local
state file is gone. The code it adds calls the plain OpenTelemetry API (no helper file), which
does nothing when no SDK is loaded.

  enrich.py span --file F --function NAME --span-name S --tracer-name T
                 [--line N] [--id ID] [--root R] [--dry-run]
      Wrap one function in a span. NAME is `fn` or `Class.method`; --line picks one when the name
      occurs more than once. Prints the unified diff, then writes it (--dry-run: writes nothing
      and exits 1 if there is a diff). Python gets a decorator above the `def`; JavaScript gets
      one block at the top of the function body and one at the end, the body lines untouched.
      The result must still parse (Python `compile`, `node --check`), or nothing is written.

  enrich.py metric --file F --function NAME --at LINE --where before|after --name METRIC
                   --meter-name T [--value EXPR] [--line N] [--context FILE] [--root R] [--dry-run]
      Emit one confirmed business metric. METRIC must be a confirmed counter, histogram or gauge in
      the context cache (default <root>/.claude/otel-context.json), which also supplies its kind
      and unit: a name the user did not confirm is never emitted. Adds the instrument near the top
      of the file and one line at the call site: before or after line LINE, which must be a place
      inside NAME where a new statement can go. --value is the expression to record (a histogram
      or gauge needs one; a counter adds 1 without it). No metric attributes are added.

  enrich.py clients [--service-root DIR] [--language nodejs|python] [--bootstrap F] [--json] [--root R]
      Report which database and queue clients the service uses and whether each is traced, read
      from its manifest and imports against scripts/client-coverage.json. Writes nothing. A client
      the table does not list is not checked, and the report says so.

  enrich.py client --name CLIENT --bootstrap F [--service-root DIR] [--root R] [--dry-run]
      Python: turn on the instrumentation package for one client the report marks `install` or
      `turn-on`. Adds the requirement to requirements.txt and the two lines that turn it on to the
      end of the GENERATED bootstrap, each in a block with the id client-<name>.

  enrich.py span ... --client CLIENT [--signal db|messaging --system NAME] [--kind producer|consumer]
      The span, as a client span with the system's name as its one attribute, for a client no
      instrumentation package covers. Refused for a client a package covers: one client span per
      call is the rule, and the package's span would be the second.

  enrich.py remove [--id ID ...] [--file F] [--root R] [--dry-run]
      Delete enrichment blocks: all of them, or only the given ids or file. A file's tracer block
      goes when its last span goes, its meter block when its last metric goes. All or nothing: a begin without its end, a line of your
      own that still uses a name the enrichment defined (otelSpan, say), or a result that no
      longer parses, refuses and writes nothing.

  enrich.py list [--root R]
      Print every enrichment block: file, id, line.

Exit 0 done (or nothing to do); 1 --dry-run found changes; 2 REFUSED, with one line saying why and
nothing written. Standard library only.
"""
import argparse
import ast
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

TRACER_ID = "otel-tracer"
METER_ID = "otel-meter"
SHARED_IDS = (TRACER_ID, METER_ID)
METRIC_PREFIX = "metric-"      # ids of metric enrichments; they need the meter block, spans the tracer
METRIC_KINDS = ("counter", "histogram", "gauge")
METRIC_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.\-/]{0,254}$")
# A histogram's default buckets (0, 5, 10, 25, ... 10000) suit milliseconds and counts. In seconds
# everything under 5 s lands in one bucket and every quantile reads 2.5, so a histogram recorded in
# seconds gets the boundaries the HTTP semantic conventions recommend for durations.
SECONDS_BOUNDS = "0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10"
UNIT_RE = re.compile(r"^[A-Za-z0-9{}_/%.*\- ]{1,63}$")
JS_EXTS = (".js", ".cjs", ".mjs")
PY_EXTS = (".py",)
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "env", "dist", "build", "target", "vendor",
             "__pycache__", ".next", ".nuxt", "site-packages", ".tox", "coverage"}
MARKER_RE = re.compile(r"^[ \t]*(//|#) otel-as-code: enrich (begin|end) ([a-z0-9][a-z0-9-]{0,59})[ \t]*$")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,59}$")
SPAN_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.\-/ ]{0,99}$")
JS_OURS = ("otelTracer", "otelSpan", "otelErr", "otelTrace", "OtelStatus")
PY_OURS = ("_otel_tracer", "_otel_trace")
CLIENT_PREFIX = "client-"      # ids of the blocks that turn an instrumentation package on
GENERATED_RE = re.compile(r"generated by otel-as-code", re.I)
COVERAGE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "client-coverage.json")


class Refused(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write_atomically(path, text):
    """Temp file beside the target, then rename: an interrupted write never leaves half a file."""
    target = os.path.realpath(path)
    mode = os.stat(target).st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(prefix=".otel-enrich.", suffix=".tmp", dir=os.path.dirname(target))
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


def lang_of(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in JS_EXTS:
        return "js"
    if ext in PY_EXTS:
        return "py"
    if ext in (".ts", ".tsx", ".mts", ".cts", ".jsx"):
        raise Refused(f"{os.path.basename(path)}: TypeScript and JSX are not supported yet "
                      f"(supported: {', '.join(JS_EXTS + PY_EXTS)}).")
    raise Refused(f"{os.path.basename(path)}: unsupported file type (supported: {', '.join(JS_EXTS + PY_EXTS)}).")


def resolve(root, rel):
    """A source file under root that a person owns: not a dependency, not our own generated file."""
    base = os.path.realpath(root)
    full = os.path.realpath(os.path.join(base, rel))
    if not (full == base or full.startswith(base + os.sep)):
        raise Refused(f"{rel} is outside the project root {base}.")
    if not os.path.isfile(full):
        raise Refused(f"{rel} is not a file under {base}.")
    parts = os.path.relpath(full, base).split(os.sep)
    hit = [p for p in parts[:-1] if p in SKIP_DIRS]
    if hit:
        raise Refused(f"{rel} is under {hit[0]}/, which is not the project's own code.")
    return full, os.path.relpath(full, base)


def split_lines(text):
    nl = "\r\n" if "\r\n" in text else "\n"
    return text.splitlines(keepends=True), nl


def blocks_of(lines, rel):
    """[(id, begin_index, end_index)] for every enrichment block, or Refused when the markers
    don't pair up (a begin without its end, an end without a begin, a block inside a block)."""
    out, open_id, open_at = [], None, None
    for i, line in enumerate(lines):
        m = MARKER_RE.match(line.rstrip("\r\n"))
        if not m:
            continue
        edge, bid = m.group(2), m.group(3)
        if edge == "begin":
            if open_id is not None:
                raise Refused(f"{rel}:{i + 1}: enrichment block {bid} begins inside block {open_id} "
                              f"(line {open_at + 1}); fix the markers by hand.")
            open_id, open_at = bid, i
        else:
            if open_id != bid:
                raise Refused(f"{rel}:{i + 1}: `enrich end {bid}` has no matching begin; fix the markers by hand.")
            out.append((bid, open_at, i))
            open_id = None
    if open_id is not None:
        raise Refused(f"{rel}:{open_at + 1}: `enrich begin {open_id}` has no matching end; fix the markers by hand.")
    return out


def outside_blocks(lines, blocks):
    inside = set()
    for _, b, e in blocks:
        inside.update(range(b, e + 1))
    return "".join(line for i, line in enumerate(lines) if i not in inside)


# --- syntax checks ------------------------------------------------------------------------------

def check_python(text, rel):
    try:
        compile(text, rel, "exec", dont_inherit=True)
    except SyntaxError as e:
        return f"line {e.lineno}: {e.msg}"
    return None


def check_js(text, full):
    """`node --check` on a temp file beside the real one, so module type resolves the same way."""
    node = shutil.which("node")
    if not node:
        raise Refused("node is not on PATH, so the edited file can't be syntax-checked; nothing written.")
    fd, tmp = tempfile.mkstemp(prefix=".otel-enrich-check.", suffix=os.path.splitext(full)[1],
                               dir=os.path.dirname(full))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        r = subprocess.run([node, "--check", tmp], capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(tmp)
    if r.returncode == 0:
        return None
    err = [ln for ln in r.stderr.splitlines() if "Error" in ln]
    return err[0] if err else "does not parse"


def check(lang, text, full, rel):
    if lang == "txt":       # a requirements file: nothing to parse
        return None
    return check_python(text, rel) if lang == "py" else check_js(text, full)


# --- JavaScript: find a function's body without a parser ----------------------------------------
# A small scanner that knows strings, template literals, comments and regex literals, used to match
# brackets. It is not a parser; `node --check` on the result is the backstop.

REGEX_PREV_WORDS = {"return", "typeof", "case", "in", "of", "delete", "void", "throw", "new", "do",
                    "else", "yield", "await"}


def js_code(text, start=0):
    """Yield (index, char) for every character of code from `start`: nothing inside a string, a
    comment, a regex literal, or the text part of a template literal."""
    i, n = start, len(text)
    stack = []          # one entry per open template literal: brace depth inside its ${ }
    prev = ""           # last significant code character
    word = ""           # identifier ending at prev
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in "'\"":
            i += 1
            while i < n and text[i] != c and text[i] != "\n":
                i += 2 if text[i] == "\\" else 1
            i += 1
            prev, word = c, ""
            continue
        if c == "`" or (c == "}" and stack and stack[-1] == 0):
            if c == "}":
                stack.pop()
            i += 1
            while i < n and text[i] != "`":
                if text[i] == "\\":
                    i += 2
                elif text[i:i + 2] == "${":
                    stack.append(0)
                    i += 2
                    break
                else:
                    i += 1
            else:
                i += 1
                prev, word = "`", ""
                continue
            prev, word = "{", ""
            continue
        if c == "/" and (prev == "" or prev in "(,=:[!&|?{};+-*%<>~^" or word in REGEX_PREV_WORDS):
            i += 1
            in_class = False
            while i < n and text[i] != "\n" and (in_class or text[i] != "/"):
                if text[i] == "\\":
                    i += 1
                elif text[i] == "[":
                    in_class = True
                elif text[i] == "]":
                    in_class = False
                i += 1
            i += 1
            prev, word = "/", ""
            continue
        if stack:
            if c == "{":
                stack[-1] += 1
            elif c == "}":
                stack[-1] -= 1
        yield i, c
        if not c.isspace():
            if c.isalnum() or c in "_$":
                glued = i > 0 and (text[i - 1].isalnum() or text[i - 1] in "_$")
                word = word + c if glued else c
            else:
                word = ""
            prev = c
        i += 1


def js_match(text, open_idx):
    """Index of the bracket closing the one at open_idx, or -1."""
    opener = text[open_idx]
    closer = {"(": ")", "{": "}", "[": "]"}[opener]
    depth = 0
    for i, c in js_code(text, open_idx):
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i
    return -1


def js_next(text, idx):
    """(index, char) of the next significant code character at or after idx, or (-1, '')."""
    for i, c in js_code(text, idx):
        if not c.isspace():
            return i, c
    return -1, ""


def js_candidates(text, name):
    """Every place `name` is defined as a function: [(decl_index, body_open_index, is_async)].
    Raises Refused for a shape that can't take an insert-only wrap."""
    n = re.escape(name)
    code_at = {i for i, _ in js_code(text)}
    patterns = [
        rf"(?P<async>async\s+)?function\s*(?P<gen>\*)?\s*{n}\s*(?=\()",
        rf"(?:const|let|var)\s+{n}\s*=\s*(?P<async>async\s+)?(?:function\s*(?P<gen>\*)?\s*[A-Za-z_$\w]*\s*)?(?=\(|[A-Za-z_$][\w$]*\s*=>)",
        rf"(?<![\w$]){n}\s*[:=]\s*(?P<async>async\s+)?(?:function\s*(?P<gen>\*)?\s*[A-Za-z_$\w]*\s*)?(?=\(|[A-Za-z_$][\w$]*\s*=>)",
        rf"(?m)^[ \t]*(?:static\s+)?(?P<async>async\s+)?(?P<gen>\*\s*)?{n}\s*(?=\()",
    ]
    found, refused = {}, []
    for k, pat in enumerate(patterns):
        for m in re.finditer(pat, text):
            start = m.start() + (len(m.group(0)) - len(m.group(0).lstrip()))
            if start not in code_at:
                continue  # inside a string or a comment
            pos = m.end()
            is_method = k == 3
            if text[pos] == "(":
                close = js_match(text, pos)
                if close < 0:
                    continue
                j, c = js_next(text, close + 1)
            else:  # single bare parameter of an arrow function
                j, c = js_next(text, pos + len(re.match(r"[A-Za-z_$][\w$]*", text[pos:]).group(0)))
            arrow = text[j:j + 2] == "=>"
            if arrow:
                j, c = js_next(text, j + 2)
                if c != "{":
                    refused.append(Refused(
                        f"`{name}` is an arrow function with an expression body (no braces); give it a "
                        f"block body first, or enrich the function that calls it."))
                    continue
            if c != "{":
                continue  # a call, not a definition
            if is_method and not arrow and re.match(r"(?:if|for|while|switch|catch|function|return)$", name):
                continue
            if m.group("gen"):
                refused.append(Refused(f"`{name}` is a generator; a span around it would end before it runs."))
                continue
            if j not in found or start < found[j][0]:
                found[j] = (start, j, bool(m.group("async")) or (j in found and found[j][2]))
    return [found[k] for k in sorted(found)] + refused


def js_is_esm(text, full):
    ext = os.path.splitext(full)[1].lower()
    if ext == ".mjs":
        return True
    if ext == ".cjs":
        return False
    d = os.path.dirname(full)
    while True:
        pj = os.path.join(d, "package.json")
        if os.path.isfile(pj):
            try:
                return json.loads(read(pj)).get("type") == "module"
            except (OSError, ValueError):
                return False
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return bool(re.search(r"(?m)^(?:import\s|export\s)", text))


def js_tracer_line(lines):
    """Index to insert the tracer block at: after a shebang, a header comment (comment lines from
    the top of the file up to the first blank line), directives and the leading import statements,
    and before the first other statement."""
    last, header = 0, True
    in_block_comment = in_import = False
    for i, line in enumerate(lines):
        s = line.strip()
        advance = False
        if in_block_comment:
            in_block_comment = "*/" not in s
            advance = header
        elif in_import:
            in_import = not re.search(r"""from\s*['"][^'"]+['"]\s*;?\s*$""", s)
            advance = not in_import
        elif i == 0 and s.startswith("#!"):
            advance = True
        elif s == "":
            header = False
        elif s.startswith("//"):
            advance = header
        elif s.startswith("/*"):
            in_block_comment = "*/" not in s
            advance = header
        elif re.match(r"""['"]use \w+['"];?$""", s):
            advance, header = True, False
        elif re.match(r"import\b", s) and not s.startswith("import("):
            in_import = not re.search(r"""['"][^'"]+['"]\s*;?\s*$""", s)
            advance, header = not in_import, False
        else:
            break
        if advance:
            last = i + 1
    return last


def js_locate(text, rel, args):
    """(decl index, body-open index, body-close index, is_async) of the function args names."""
    name = args.function.split(".")[-1]
    scope_text, offset = text, 0
    if "." in args.function:
        cls = args.function.split(".")[0]
        m = re.search(rf"class\s+{re.escape(cls)}\b[^{{]*{{", text)
        if not m:
            raise Refused(f"class `{cls}` not found in {rel}.")
        end = js_match(text, m.end() - 1)
        scope_text, offset = text[:end + 1], m.end() - 1
    if name == "constructor":
        raise Refused("a constructor can't be wrapped in a span; enrich the method that does the work.")
    cands = []
    for c in js_candidates(scope_text, name):
        if isinstance(c, Refused):
            cands.append(c)
        elif c[0] >= offset:
            cands.append(c)
    line_of = lambda idx: text.count("\n", 0, idx) + 1
    real = [c for c in cands if not isinstance(c, Refused)]
    if args.line:
        real = [c for c in real if line_of(c[0]) == args.line]
        if not real:
            raise Refused(f"no definition of `{args.function}` starts on line {args.line} of {rel}.")
    if not real:
        for c in cands:
            if isinstance(c, Refused):
                raise c
        raise Refused(f"no function named `{args.function}` found in {rel}.")
    if len(real) > 1:
        where = ", ".join(str(line_of(c[0])) for c in real)
        raise Refused(f"`{args.function}` is defined {len(real)} times in {rel} (lines {where}); pass --line.")
    decl, body_open, is_async = real[0]
    body_close = js_match(text, body_open)
    if body_close < 0:
        raise Refused(f"can't find the end of `{args.function}` in {rel}.")
    return decl, body_open, body_close, is_async


def shared_line(at, blocks):
    """Move an insertion index out of any existing enrichment block it would land inside."""
    for _, b, e in blocks:
        if b < at <= e:
            return e + 1
    return at


def js_span(lines, nl, text, full, rel, args, blocks):
    decl, body_open, body_close, is_async = js_locate(text, rel, args)
    line_of = lambda idx: text.count("\n", 0, idx) + 1
    open_line, close_line = line_of(body_open) - 1, line_of(body_close) - 1
    after_open = text[body_open + 1:text.find("\n", body_open) if "\n" in text[body_open:] else len(text)]
    before_close = text[text.rfind("\n", 0, body_close) + 1:body_close]
    if open_line == close_line or after_open.strip() or before_close.strip():
        raise Refused(f"`{args.function}` has code on the same line as its opening or closing brace; "
                      f"put the body on its own lines first (an insert-only edit can't split a line).")
    inside = {i for _, b, e in blocks for i in range(b, e + 1)}
    if any(i in inside for i in (open_line + 1, close_line - 1)) and any(
            b == open_line + 1 for _, b, _ in blocks):
        raise Refused(f"`{args.function}` already has an enrichment block at the top of its body.")
    body = [ln for ln in lines[open_line + 1:close_line] if ln.strip()]
    decl_indent = re.match(r"[ \t]*", lines[line_of(decl) - 1]).group(0)
    indent = re.match(r"[ \t]*", body[0]).group(0) if body else decl_indent + "  "
    a = "async " if is_async else ""
    opts = ""
    if args.client_span:
        kind, key, system = args.client_span
        opts = f"{{ kind: {SPAN_KINDS[kind]} /* SpanKind.{kind.upper()} */, attributes: {{ '{key}': '{system}' }} }}, "
    top = [f"{indent}// otel-as-code: enrich begin {args.id}{nl}",
           f"{indent}return otelTracer.startActiveSpan('{args.span_name}', {opts}{a}(otelSpan) => {{ try {{{nl}",
           f"{indent}// otel-as-code: enrich end {args.id}{nl}"]
    bottom = [f"{indent}// otel-as-code: enrich begin {args.id}{nl}",
              f"{indent}}} catch (otelErr) {{ otelSpan.recordException(otelErr); "
              f"otelSpan.setStatus({{ code: OtelStatus.ERROR }}); throw otelErr; }} "
              f"finally {{ otelSpan.end(); }} }});{nl}",
              f"{indent}// otel-as-code: enrich end {args.id}{nl}"]
    out = lines[:open_line + 1] + top + lines[open_line + 1:close_line] + bottom + lines[close_line:]
    if not any(bid == TRACER_ID for bid, _, _ in blocks):
        if js_is_esm(text, full):
            imp = "import { trace as otelTrace, SpanStatusCode as OtelStatus } from '@opentelemetry/api';"
        else:
            imp = "const { trace: otelTrace, SpanStatusCode: OtelStatus } = require('@opentelemetry/api');"
        at = shared_line(js_tracer_line(lines), blocks)
        tracer = [f"// otel-as-code: enrich begin {TRACER_ID}{nl}", imp + nl,
                  f"const otelTracer = otelTrace.getTracer('{args.tracer_name}');{nl}",
                  f"// otel-as-code: enrich end {TRACER_ID}{nl}"]
        if at > open_line:
            raise Refused(f"can't place the tracer above `{args.function}` in {rel}.")
        out = out[:at] + tracer + out[at:]
    notes = [] if is_async else [f"note: `{args.function}` is not async: if it returns a promise, the span "
                                 f"ends when the function returns, not when the promise settles."]
    return out, notes


# --- Python: the ast module finds the function exactly ------------------------------------------

def py_locate(text, rel, args):
    """(module tree, the function node args names)."""
    try:
        tree = ast.parse(text)
    except SyntaxError as e:
        raise Refused(f"{rel} does not parse with this Python ({e.msg}, line {e.lineno}); nothing written.")
    want = args.function.split(".")
    found = []

    def walk(node, path):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                p = path + [child.name]
                if not isinstance(child, ast.ClassDef) and p[-len(want):] == want:
                    found.append(child)
                walk(child, p)
            else:
                walk(child, path)
    walk(tree, [])
    if args.line:
        found = [f for f in found if f.lineno == args.line]
        if not found:
            raise Refused(f"no definition of `{args.function}` starts on line {args.line} of {rel}.")
    if not found:
        raise Refused(f"no function named `{args.function}` found in {rel}.")
    if len(found) > 1:
        raise Refused(f"`{args.function}` is defined {len(found)} times in {rel} "
                      f"(lines {', '.join(str(f.lineno) for f in found)}); pass --line.")
    return tree, found[0]


def py_top_line(tree):
    """Line index after the module docstring and the leading imports."""
    at = 0
    for node in tree.body:
        is_doc = (node is tree.body[0] and isinstance(node, ast.Expr)
                  and isinstance(getattr(node, "value", None), ast.Constant) and isinstance(node.value.value, str))
        if is_doc or isinstance(node, (ast.Import, ast.ImportFrom)):
            at = node.end_lineno
        else:
            break
    return at


def py_span(lines, nl, text, full, rel, args, blocks):
    tree, fn = py_locate(text, rel, args)

    def yields(node):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
                continue
            if isinstance(child, (ast.Yield, ast.YieldFrom)) or yields(child):
                return True
        return False
    if yields(fn):
        raise Refused(f"`{args.function}` is a generator; a span around it would end before it runs.")
    def_line = fn.lineno - 1
    if any(e == def_line - 1 for _, _, e in blocks):
        raise Refused(f"`{args.function}` already has an enrichment block above it.")
    indent = re.match(r"[ \t]*", lines[def_line]).group(0)
    extra = ""
    if args.client_span:
        kind, key, system = args.client_span
        extra = f', kind=_otel_trace.SpanKind.{kind.upper()}, attributes={{"{key}": "{system}"}}'
    deco = [f"{indent}# otel-as-code: enrich begin {args.id}{nl}",
            f'{indent}@_otel_tracer.start_as_current_span("{args.span_name}"{extra}){nl}',
            f"{indent}# otel-as-code: enrich end {args.id}{nl}"]
    out = lines[:def_line] + deco + lines[def_line:]
    if not any(bid == TRACER_ID for bid, _, _ in blocks):
        at = shared_line(py_top_line(tree), blocks)
        first = min([fn.lineno] + [d.lineno for d in fn.decorator_list]) - 1
        if at > first:
            raise Refused(f"can't place the tracer above `{args.function}` in {rel}.")
        tracer = [f"# otel-as-code: enrich begin {TRACER_ID}{nl}",
                  f"from opentelemetry import trace as _otel_trace{nl}",
                  f'_otel_tracer = _otel_trace.get_tracer("{args.tracer_name}"){nl}',
                  f"# otel-as-code: enrich end {TRACER_ID}{nl}"]
        if at and lines[at - 1].strip() and not lines[at - 1].endswith(("\n", "\r")):
            tracer = [nl] + tracer
        out = out[:at] + tracer + out[at:]
    return out, []


# --- business metrics: an instrument near the top of the file, one line at the call site --------

def confirmed_metric(context_path, name):
    """The confirmed businessAttrs entry for `name`, or Refused. Only what the user approved in
    /otel-business-attrs may be emitted; a name that is not in the cache is never invented here."""
    try:
        doc = json.loads(read(context_path))
    except (OSError, ValueError) as e:
        raise Refused(f"can't read the context cache {context_path} ({e}); run /otel-business-attrs first.")
    attrs = doc.get("businessAttrs") if isinstance(doc, dict) else None
    for a in attrs or []:
        if isinstance(a, dict) and a.get("name") == name:
            if a.get("confirmed") is not True:
                raise Refused(f"`{name}` is in the cache but not confirmed; confirm it in /otel-business-attrs first.")
            if a.get("kind") not in METRIC_KINDS:
                raise Refused(f"`{name}` is a {a.get('kind')!r}, not a counter, histogram or gauge; "
                              f"only those are emitted from code.")
            return a
    raise Refused(f"`{name}` is not a confirmed business attribute in {context_path}; "
                  f"confirm it in /otel-business-attrs first. Nothing written.")


def metric_id(name):
    return METRIC_PREFIX + slug(name)[-(60 - len(METRIC_PREFIX)):].strip("-")


def metric_var(lang, name, taken):
    """A variable name for the instrument, from the metric's last segment (more when taken)."""
    segs = [x for x in re.split(r"[./]+", name) if x]
    for n in range(1, len(segs) + 1):
        words = [w for seg in segs[-n:] for w in re.split(r"[^A-Za-z0-9]+", seg) if w]
        var = ("_otel_" + "_".join(w.lower() for w in words) if lang == "py"
               else "otel" + "".join(w[:1].upper() + w[1:] for w in words))
        if not re.search(rf"(?<![\w$]){re.escape(var)}(?![\w$])", taken):
            return var
    raise Refused(f"can't find a free variable name for `{name}` in this file.")


def js_value_ok(expr):
    depth = 0
    for i, c in js_code(expr):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                return False
        elif c == ";" and depth == 0:
            return False
    return depth == 0 and bool(expr.strip())


def check_value(lang, args, kind):
    v = args.value
    if v is None:
        if kind == "counter":
            return "1"
        raise Refused(f"a {kind} needs --value: the expression to record at the call site.")
    if "\n" in v or "\r" in v or len(v) > 200 or "otel-as-code:" in v:
        raise Refused("--value must be one short expression on one line.")
    if lang == "py":
        try:
            ast.parse(v, mode="eval")
        except SyntaxError:
            raise Refused(f"--value {v!r} is not one Python expression.")
    elif not js_value_ok(v):
        raise Refused(f"--value {v!r} is not one JavaScript expression.")
    return v.strip()


def record_call(lang, var, kind, value):
    method = {"counter": "add", "histogram": "record", "gauge": "set" if lang == "py" else "record"}[kind]
    return f"{var}.{method}({value})" + ("" if lang == "py" else ";")


def py_metric_site(lines, text, rel, args, blocks):
    """(insertion line index, indent) for the call-site line in a Python function."""
    tree, fn = py_locate(text, rel, args)
    stmts = []

    def walk(node):
        for field in ("body", "orelse", "finalbody"):
            for child in getattr(node, field, []) or []:
                if isinstance(child, ast.stmt):
                    stmts.append(child)
                    if not isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                        walk(child)
        for handler in getattr(node, "handlers", []) or []:
            walk(handler)
        for case in getattr(node, "cases", []) or []:
            walk(case)
    walk(fn)
    if args.where == "before":
        hit = [st for st in stmts if st.lineno == args.at]
        if not hit:
            raise Refused(f"line {args.at} does not start a statement inside `{args.function}`.")
        st = hit[0]
        return st.lineno - 1, re.match(r"[ \t]*", lines[st.lineno - 1]).group(0), tree
    hit = [st for st in stmts if st.end_lineno == args.at]
    if not hit:
        raise Refused(f"line {args.at} does not end a statement inside `{args.function}`.")
    st = max(hit, key=lambda x: x.lineno)  # the innermost one: the statement written on that line
    if isinstance(st, (ast.Return, ast.Raise, ast.Break, ast.Continue)):
        raise Refused(f"line {args.at} is a {type(st).__name__.lower()}; a line after it would never run. "
                      f"Use --where before.")
    return st.end_lineno, re.match(r"[ \t]*", lines[st.lineno - 1]).group(0), tree


def js_metric_site(lines, text, rel, args, blocks):
    """(insertion line index, indent) for the call-site line in a JavaScript function."""
    decl, body_open, body_close, _ = js_locate(text, rel, args)
    line_of = lambda idx: text.count("\n", 0, idx) + 1
    first, last = line_of(body_open) + 1, line_of(body_close) - 1
    if not first <= args.at <= last:
        raise Refused(f"line {args.at} is not inside the body of `{args.function}` (lines {first} to {last}).")
    if not lines[args.at - 1].strip():
        raise Refused(f"line {args.at} is blank; name the line of the statement to put this next to.")
    stripped = lines[args.at - 1].strip()
    if args.where == "after" and re.match(r"(return|throw|break|continue)\b", stripped):
        raise Refused(f"line {args.at} is a {stripped.split()[0].rstrip(';')}; a line after it would never run. "
                      f"Use --where before.")
    if args.where == "before" and stripped[0] in "})]":
        raise Refused(f"line {args.at} closes a block; name the line of a statement (or use --where after "
                      f"the block's last statement).")
    if args.where == "after" and stripped.endswith("{"):
        raise Refused(f"line {args.at} opens a block; use --where before on the first line inside it, "
                      f"or name a line after the block.")
    idx = args.at - 1 if args.where == "before" else args.at
    offset = sum(len(ln) for ln in lines[:idx])
    # Our own blocks don't count: a span wrap opens a call at the top of the body and closes it at
    # the bottom, which would otherwise make every line of the function look bracketed.
    ours, pos = set(), 0
    in_block = {i for _, b, e in blocks for i in range(b, e + 1)}
    for n, ln in enumerate(lines):
        if n in in_block:
            ours.update(range(pos, pos + len(ln)))
        pos += len(ln)
    code = {i: c for i, c in js_code(text, body_open) if i not in ours}
    depth, prev = 0, ""
    for i in sorted(code):
        if i >= offset:
            break
        c = code[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        if not c.isspace():
            prev = c
    nxt = next((code[i] for i in sorted(code) if i >= offset and not code[i].isspace()), "")
    in_code = any(i in code for i in range(offset, min(offset + len(lines[idx]) if idx < len(lines) else offset, len(text)))) \
        or not lines[idx].strip()
    if depth != 0 or not in_code or prev in "=+-*/%&|,.?:([<!~" or nxt in ".?:+*/%&|,=)]":
        raise Refused(f"line {args.at} ({args.where}) is in the middle of a statement, a string or a bracketed "
                      f"expression; name a line where a new statement can go.")
    return idx, re.match(r"[ \t]*", lines[args.at - 1]).group(0), None


def cmd_metric(args):
    full, rel = resolve(args.root, args.file)
    lang = lang_of(full)
    if not METRIC_NAME_RE.match(args.name):
        raise Refused(f"metric name {args.name!r} is not a valid instrument name.")
    if not SPAN_NAME_RE.match(args.meter_name):
        raise Refused(f"meter name {args.meter_name!r} must be plain letters, digits, dots, dashes or slashes.")
    context = args.context or os.path.join(args.root, ".claude", "otel-context.json")
    attr = confirmed_metric(context, args.name)
    kind, unit = attr["kind"], attr.get("unit")
    if unit is not None and not (isinstance(unit, str) and UNIT_RE.match(unit)):
        raise Refused(f"unit {unit!r} of `{args.name}` in the cache is not a plain unit string.")
    mid = metric_id(args.name)
    text = read(full)
    if re.search(r"generated by otel-as-code", text, re.I):
        raise Refused(f"{rel} is a file otel-as-code generated; enrich your own code, not the bootstrap.")
    lines, nl = split_lines(text)
    blocks = blocks_of(lines, rel)
    if any(bid == mid for bid, _, _ in blocks):
        raise Refused(f"{rel} already emits `{args.name}` (id {mid}).")
    user_text = outside_blocks(lines, blocks)
    ours = ("_otel_meter", "_otel_metrics") if lang == "py" else ("otelMeter", "otelMetrics")
    clash = [w for w in ours if re.search(rf"(?<![\w$]){re.escape(w)}(?![\w$])", user_text)]
    if clash:
        raise Refused(f"{rel} already uses the name `{clash[0]}`, which this enrichment would add.")
    before = check(lang, text, full, rel)
    if before:
        raise Refused(f"{rel} does not parse before the edit ({before}); nothing written.")
    value = check_value(lang, args, kind)
    inside = {i for _, b, e in blocks for i in range(b, e + 1)}
    if args.at - 1 in inside:
        raise Refused(f"line {args.at} is inside an existing enrichment block; name a line of your own code.")
    site, indent, tree = (py_metric_site if lang == "py" else js_metric_site)(lines, text, rel, args, blocks)
    var = metric_var(lang, args.name, text)
    c = "#" if lang == "py" else "//"
    call = [f"{indent}{c} otel-as-code: enrich begin {mid}{nl}",
            f"{indent}{record_call(lang, var, kind, value)}{nl}",
            f"{indent}{c} otel-as-code: enrich end {mid}{nl}"]
    creator = {"counter": "counter", "histogram": "histogram", "gauge": "gauge"}[kind]
    seconds = kind == "histogram" and unit == "s"
    if lang == "py":
        opts = (f', unit="{unit}"' if unit else "") + \
               (f", explicit_bucket_boundaries_advisory=[{SECONDS_BOUNDS}]" if seconds else "")
        make = f'{var} = _otel_meter.create_{creator}("{args.name}"{opts})'
    else:
        fields = ([f"unit: '{unit}'"] if unit else []) + \
                 ([f"advice: {{ explicitBucketBoundaries: [{SECONDS_BOUNDS}] }}"] if seconds else [])
        opts = f", {{ {', '.join(fields)} }}" if fields else ""
        make = f"const {var} = otelMeter.create{creator.capitalize()}('{args.name}'{opts});"
    instrument = [f"{c} otel-as-code: enrich begin {mid}{nl}", make + nl, f"{c} otel-as-code: enrich end {mid}{nl}"]
    meter_block = next(((b, e) for bid, b, e in blocks if bid == METER_ID), None)
    if meter_block:
        top_at, top = meter_block[1] + 1, instrument
    else:
        top_at = shared_line(py_top_line(tree) if lang == "py" else js_tracer_line(lines), blocks)
        if lang == "py":
            meter = ["from opentelemetry import metrics as _otel_metrics" + nl,
                     f'_otel_meter = _otel_metrics.get_meter("{args.meter_name}")' + nl]
        elif js_is_esm(text, full):
            meter = ["import { metrics as otelMetrics } from '@opentelemetry/api';" + nl,
                     f"const otelMeter = otelMetrics.getMeter('{args.meter_name}');" + nl]
        else:
            meter = ["const { metrics: otelMetrics } = require('@opentelemetry/api');" + nl,
                     f"const otelMeter = otelMetrics.getMeter('{args.meter_name}');" + nl]
        top = [f"{c} otel-as-code: enrich begin {METER_ID}{nl}"] + meter + [f"{c} otel-as-code: enrich end {METER_ID}{nl}"] + instrument
    if top_at > site:
        raise Refused(f"can't place the instrument above line {args.at} in {rel}.")
    out = lines[:top_at] + top + lines[top_at:site] + call + lines[site:]
    new = "".join(out)
    after = check(lang, new, full, rel)
    if after:
        raise Refused(f"the edited {rel} would not parse ({after}); nothing written. "
                      f"Line {args.at} is not a place a new statement can go, or --value is not valid there.")
    sys.stdout.writelines(difflib.unified_diff(lines, out, f"a/{rel}", f"b/{rel}"))
    if kind == "histogram" and not seconds:
        print(f"note: no bucket boundaries are set for unit {unit!r}, so the SDK's defaults apply "
              f"(0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000). If the values "
              f"are much smaller or larger than that, the quantiles will be coarse.")
    note = dependency_note(lang, full, args.root)
    if note:
        print(note)
    what = f"{kind} `{args.name}` in `{args.function}` in {rel} (id {mid})"
    if args.dry_run:
        print(f"dry run: would emit {what}")
        return 1
    write_atomically(full, new)
    print(f"OK: emits {what}")
    return 0


# --- dependency note ----------------------------------------------------------------------------

def dependency_note(lang, full, root):
    base = os.path.realpath(root)
    d = os.path.dirname(full)
    while True:
        if lang == "js" and os.path.isfile(os.path.join(d, "package.json")):
            try:
                pj = json.loads(read(os.path.join(d, "package.json")))
            except (OSError, ValueError):
                return None
            if "@opentelemetry/api" in (pj.get("dependencies") or {}):
                return None
            return (f"dependency: add \"@opentelemetry/api\" to dependencies in "
                    f"{os.path.relpath(os.path.join(d, 'package.json'), base)} (the code now imports it directly).")
        if lang == "py":
            manifests = [f for f in ("requirements.txt", "pyproject.toml", "setup.py", "Pipfile") if
                         os.path.isfile(os.path.join(d, f))]
            if manifests:
                if any(re.search(r"opentelemetry[-_](?:api|sdk)", read(os.path.join(d, f))) for f in manifests):
                    return None
                return (f"dependency: add \"opentelemetry-api\" to {os.path.relpath(os.path.join(d, manifests[0]), base)} "
                        f"(the code now imports it directly).")
        if d == base or os.path.dirname(d) == d:
            return None
        d = os.path.dirname(d)


# --- commands -----------------------------------------------------------------------------------

def slug(s):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", s.lower())).strip("-")[:60]


def cmd_span(args):
    full, rel = resolve(args.root, args.file)
    lang = lang_of(full)
    if not SPAN_NAME_RE.match(args.span_name):
        raise Refused(f"span name {args.span_name!r} must be plain letters, digits, dots, dashes or slashes.")
    if not SPAN_NAME_RE.match(args.tracer_name):
        raise Refused(f"tracer name {args.tracer_name!r} must be plain letters, digits, dots, dashes or slashes.")
    args.id = args.id or slug(args.span_name)
    if not ID_RE.match(args.id) or args.id in SHARED_IDS or args.id.startswith((METRIC_PREFIX, CLIENT_PREFIX)):
        raise Refused(f"id {args.id!r} must be lowercase letters, digits and dashes, and not one of the reserved "
                      f"ids ({', '.join(SHARED_IDS)}, {METRIC_PREFIX}*, {CLIENT_PREFIX}*); pass --id.")
    args.client_span, client_notes = None, []
    if args.client:
        kind, key, system, client_notes = client_span_options(args, lang)
        args.client_span = (kind, key, system)
    elif args.signal or args.system or args.kind:
        raise Refused("--signal, --system and --kind describe a client span; pass --client <library> with them.")
    text = read(full)
    if GENERATED_RE.search(text):
        raise Refused(f"{rel} is a file otel-as-code generated; enrich your own code, not the bootstrap.")
    lines, nl = split_lines(text)
    blocks = blocks_of(lines, rel)
    if any(bid == args.id for bid, _, _ in blocks):
        raise Refused(f"{rel} already has an enrichment with id `{args.id}`.")
    ours = PY_OURS if lang == "py" else JS_OURS
    clash = [w for w in ours if re.search(rf"(?<![\w$]){re.escape(w)}(?![\w$])", outside_blocks(lines, blocks))]
    if clash:
        raise Refused(f"{rel} already uses the name `{clash[0]}`, which this enrichment would add.")
    before = check(lang, text, full, rel)
    if before:
        raise Refused(f"{rel} does not parse before the edit ({before}); nothing written.")
    out, notes = (py_span if lang == "py" else js_span)(lines, nl, text, full, rel, args, blocks)
    new = "".join(out)
    after = check(lang, new, full, rel)
    if after:
        raise Refused(f"the edited {rel} would not parse ({after}); nothing written. "
                      f"This function's shape is not one this command can wrap.")
    sys.stdout.writelines(difflib.unified_diff(lines, out, f"a/{rel}", f"b/{rel}"))
    for note in notes + client_notes + [dependency_note(lang, full, args.root)]:
        if note:
            print(note)
    if args.dry_run:
        print(f"dry run: would add span `{args.span_name}` around `{args.function}` in {rel} (id {args.id})")
        return 1
    write_atomically(full, new)
    print(f"OK: added span `{args.span_name}` around `{args.function}` in {rel} (id {args.id})")
    return 0


def defined_names(block_lines, lang):
    """Names the given enrichment lines define, for the leftover-use check on removal."""
    names = []
    for line in block_lines:
        if lang == "py":
            names += re.findall(r"^\s*(\w+)\s*=", line) + re.findall(r"\bimport\s+\w+\s+as\s+(\w+)", line)
        else:
            names += re.findall(r"\bconst\s+(\w+)\s*=", line)
            for group in re.findall(r"\b(?:const|import)\s*\{([^}]*)\}", line):
                names += [re.split(r":|\bas\b", part)[-1].strip() for part in group.split(",") if part.strip()]
            names += re.findall(r"\((otel\w*)\)\s*=>", line) + re.findall(r"catch\s*\((\w+)\)", line)
    return sorted(set(names))


def enriched_files(root, only=None):
    base = os.path.realpath(root)
    if only:
        full, rel = resolve(root, only)
        return [(full, rel)]
    out = []
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            if os.path.splitext(f)[1].lower() in JS_EXTS + PY_EXTS or f == "requirements.txt":
                full = os.path.join(d, f)
                # A symlink could point outside the project (or at a dependency); writes follow
                # links, so only a real file whose real path is under the root is ever touched.
                real = os.path.realpath(full)
                if os.path.islink(full) or not real.startswith(base + os.sep):
                    continue
                try:
                    if "otel-as-code: enrich begin" in read(full):
                        out.append((full, os.path.relpath(full, base)))
                except (OSError, UnicodeDecodeError):
                    continue
    return out


def cmd_list(args):
    n = 0
    for full, rel in enriched_files(args.root):
        lines, _ = split_lines(read(full))
        seen = set()
        for bid, b, _ in blocks_of(lines, rel):
            if bid not in seen:
                seen.add(bid)
                print(f"{rel}:{b + 1}  {bid}")
                n += bid not in SHARED_IDS
    if not n:
        print("no enrichment found")
    return 0


def cmd_remove(args):
    want = set(args.id or [])
    if want & set(SHARED_IDS):
        raise Refused(f"{', '.join(SHARED_IDS)} are removed with a file's last span or metric, not on their own.")
    plan, removed_ids = [], set()
    for full, rel in enriched_files(args.root, args.file):
        text = read(full)
        lines, _ = split_lines(text)
        blocks = blocks_of(lines, rel)
        gone = [b for b in blocks if b[0] not in SHARED_IDS and (not want or b[0] in want)]
        if not gone:
            continue
        kept = [b for b in blocks if b[0] not in SHARED_IDS and b not in gone]
        # The tracer goes with the file's last span, the meter with its last metric.
        if not [b for b in kept if not b[0].startswith(METRIC_PREFIX)]:
            gone += [b for b in blocks if b[0] == TRACER_ID]
        if not [b for b in kept if b[0].startswith(METRIC_PREFIX)]:
            gone += [b for b in blocks if b[0] == METER_ID]
        drop = {i for _, b, e in gone for i in range(b, e + 1)}
        new = "".join(line for i, line in enumerate(lines) if i not in drop)
        if lines and len(lines) - 1 in drop and not lines[-1].endswith(("\n", "\r")):
            # A block appended to a file that had no final newline (see appended()).
            new = re.sub(r"\r?\n\Z", "", new)
        lang = "txt" if full.endswith(".txt") else lang_of(full)
        # A line the user wrote later may use a name a removed block defined (otelSpan, an
        # instrument variable): removing the block would break that line at run time.
        names = [] if lang == "txt" else defined_names([lines[i] for i in sorted(drop)], lang)
        in_block = {i for _, b, e in blocks for i in range(b, e + 1)}
        for n, line in enumerate(lines):
            if n in in_block:
                continue
            used = [w for w in names if re.search(rf"(?<![\w$]){re.escape(w)}(?![\w$])", line)]
            if used:
                raise Refused(f"{rel}:{n + 1} still uses `{used[0]}`, which the enrichment defines; removing it "
                              f"would break that line. Nothing removed: delete or change that line first.")
        bad = check(lang, new, full, rel)
        if bad:
            raise Refused(f"removing the enrichment from {rel} would leave a file that does not parse ({bad}); "
                          f"nothing removed. The code around a block was changed: remove that block by hand.")
        ids = sorted({b[0] for b in gone if b[0] not in SHARED_IDS})
        removed_ids.update(ids)
        plan.append((full, rel, new, ids))
    missing = want - removed_ids
    if missing:
        raise Refused(f"no enrichment with id {', '.join(sorted(missing))} found; nothing removed.")
    if not plan:
        print("OK: no enrichment found; nothing to remove")
        return 0
    for _, rel, _, ids in plan:
        print(f"{'would remove' if args.dry_run else 'removed'}: {', '.join(ids)} from {rel}")
    if args.dry_run:
        return 1
    for full, _, new, _ in plan:
        write_atomically(full, new)
    print(f"OK: removed {sum(len(p[3]) for p in plan)} enrichment(s) from {len(plan)} file(s)")
    return 0


# --- database and queue clients: who covers what --------------------------------------------------
# Exactly one client span per call is the rule. So: a client an instrumentation package covers is
# never wrapped by hand (two spans per query); a driver under an ORM that is instrumented is left
# alone for the same reason; and a client the table does not know is "not checked", never "no
# package exists".

def load_coverage():
    with open(COVERAGE_FILE, encoding="utf-8") as f:
        return json.load(f)


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def service_dir(args):
    base = os.path.realpath(args.root)
    full = os.path.realpath(os.path.join(base, args.service_root or "."))
    if not (full == base or full.startswith(base + os.sep)) or not os.path.isdir(full):
        raise Refused(f"--service-root {args.service_root} is not a directory under {base}.")
    return base, full


REQ_LINE_RE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*([^;#]*)")


def py_requirements(sdir):
    """({normalised name: version spec}, [manifest file names read]) from requirements.txt and
    pyproject.toml in the service directory."""
    found, read_from = {}, []

    def take(spec_line):
        m = REQ_LINE_RE.match(spec_line)
        if m and not spec_line.lstrip().startswith(("-", "#")) and "://" not in spec_line:
            found.setdefault(norm(m.group(1)), m.group(2).strip())
    req = os.path.join(sdir, "requirements.txt")
    if os.path.isfile(req):
        read_from.append("requirements.txt")
        for line in read(req).splitlines():
            take(line)
    pp = os.path.join(sdir, "pyproject.toml")
    if os.path.isfile(pp):
        read_from.append("pyproject.toml")
        text = read(pp)
        try:
            import tomllib
            data = tomllib.loads(text)
            for dep in (data.get("project") or {}).get("dependencies") or []:
                take(dep)
            for name in ((data.get("tool") or {}).get("poetry") or {}).get("dependencies") or {}:
                found.setdefault(norm(name), "")
        except ImportError:      # Python < 3.11: the quoted requirement strings, and poetry's keys
            for block in re.findall(r"(?ms)^\s*dependencies\s*=\s*\[(.*?)\]", text):
                for dep in re.findall(r"""["']([^"']+)["']""", block):
                    take(dep)
            for block in re.findall(r"(?ms)^\[tool\.poetry\.dependencies\]\s*$(.*?)(?=^\[|\Z)", text):
                for name in re.findall(r"(?m)^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*=", block):
                    found.setdefault(norm(name), "")
        except ValueError as e:
            raise Refused(f"pyproject.toml does not parse ({e}); nothing checked.")
    return found, read_from


def source_files(sdir, exts):
    for d, dirs, files in os.walk(sdir):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            if f.endswith(exts) and not os.path.islink(os.path.join(d, f)):
                try:
                    yield os.path.join(d, f), read(os.path.join(d, f))
                except (OSError, UnicodeDecodeError):
                    continue


def py_sources(sdir):
    return source_files(sdir, PY_EXTS)


def js_sources(sdir):
    return source_files(sdir, JS_EXTS)


def py_clients(sdir):
    cov = load_coverage()["python"]
    reqs, read_from = py_requirements(sdir)
    if not read_from:
        raise Refused(f"no requirements.txt or pyproject.toml in {sdir}, so its clients can't be read.")
    sources = list(py_sources(sdir))
    rows = []
    for row in cov["packages"]:
        if row.get("stdlib"):
            pat = re.compile(rf"(?m)^[ \t]*(?:import|from)[ \t]+{re.escape(row['stdlib'])}\b")
            used = any(pat.search(t) for _, t in sources if not GENERATED_RE.search(t))
        else:
            used = any(norm(c) in reqs for c in row["clients"])
        if not used:
            continue
        installed = norm(row["package"]) in reqs
        where = [os.path.relpath(p, sdir) for p, t in sources if re.search(rf"\b{row['class']}\b", t)]
        rows.append(dict(row, installed=installed, where=where))
    present = {r["label"] for r in rows}
    out = []
    for r in rows:
        layer = next((top for top, under in cov["layers"].items() if top in present and r["label"] in under), None)
        if r["installed"] and r["where"]:
            status, detail = "enabled", f"{r['package']} is installed and turned on in {r['where'][0]}"
        elif layer:
            status, detail = "layered", (f"queries go through {layer}, which is the one to instrument; "
                                         f"turning on both would give two spans per query")
        elif r["installed"]:
            status, detail = "turn-on", f"{r['package']} is installed but nothing turns it on"
        elif r["where"]:
            status, detail = "install", f"{r['where'][0]} turns {r['package']} on, but it is not a declared dependency"
        else:
            status, detail = "install", f"{r['package']} exists and is not installed"
        out.append({"client": r["label"], "signal": r["signal"], "status": status, "detail": detail,
                    "package": r["package"], "turned_on": bool(r["where"])})
    return out, read_from + ["imports"]


def node_installed(sdir, base, pkg):
    """The version of pkg found in a node_modules at or above the service directory (or nested
    under the bundle), or None."""
    d = sdir
    while True:
        for sub in (("node_modules",), ("node_modules", "@opentelemetry", "auto-instrumentations-node", "node_modules")):
            pj = os.path.join(d, *sub, *pkg.split("/"), "package.json")
            if os.path.isfile(pj):
                try:
                    return json.loads(read(pj)).get("version") or "?"
                except (OSError, ValueError):
                    return "?"
        if d == base or os.path.dirname(d) == d:
            return None
        d = os.path.dirname(d)


def node_clients(sdir, base, bootstrap_text):
    cov = load_coverage()["nodejs"]
    pj = os.path.join(sdir, "package.json")
    if not os.path.isfile(pj):
        raise Refused(f"no package.json in {sdir}, so its clients can't be read.")
    try:
        deps = json.loads(read(pj)).get("dependencies") or {}
    except ValueError as e:
        raise Refused(f"package.json does not parse ({e}); nothing checked.")
    loads_bundle = bool(bootstrap_text) and "getNodeAutoInstrumentations" in bootstrap_text
    out = []
    for name in sorted(deps):
        if name in cov["bundle"]:
            pkg = cov["bundle"][name]
            version = node_installed(sdir, base, pkg)
            off = bool(bootstrap_text) and re.search(
                rf"""['"]{re.escape(pkg)}['"]\s*:\s*\{{[^}}]*enabled\s*:\s*false""", bootstrap_text)
            if off:
                status, detail = "disabled", f"{pkg} covers it, but the bootstrap turns that package off"
            elif not loads_bundle:
                status, detail = "not-checked", (f"{pkg} covers it when the bootstrap loads {cov['bundlePackage']}; "
                                                 f"no bootstrap that does was given")
            elif version:
                status, detail = "covered", f"{pkg} {version} is installed and loaded by the bootstrap"
            else:
                status, detail = "not-checked", (f"{pkg} covers it, but it is not in node_modules here "
                                                 f"(run the install, then check again)")
            out.append({"client": name, "signal": "", "status": status, "detail": detail, "package": pkg})
        elif name in cov["manual"]:
            pkg = cov["manual"][name]
            out.append({"client": name, "signal": "", "status": "manual", "package": pkg,
                        "detail": f"{pkg} instruments it; this command does not set that up yet, "
                                  f"and must not wrap it by hand"})
    # A client with no package: a dependency, or a Node built-in the code imports.
    sources = None
    for name, spec in sorted(cov["none"].items()):
        if spec.get("builtin"):
            if sources is None:
                sources = [t for _, t in js_sources(sdir) if not GENERATED_RE.search(t)]
            used = any(re.search(rf"""['"]{re.escape(name)}['"]""", t) for t in sources)
        else:
            used = name in deps
        if used:
            out.append({"client": name, "signal": spec["signal"], "status": "wrap", "package": "",
                        "detail": "no instrumentation package covers it; a client span around the "
                                  "function of yours that makes the call does"})
    return out, ["package.json dependencies", "imports of Node built-ins"]


def service_language(args, sdir):
    if args.language:
        return args.language
    has = lambda *names: any(os.path.isfile(os.path.join(sdir, f)) for f in names)
    if has("requirements.txt", "pyproject.toml"):
        return "python"
    if has("package.json"):
        return "nodejs"
    raise Refused(f"no package.json, requirements.txt or pyproject.toml in {sdir}, so its clients can't be read.")


def clients_of(args):
    base, sdir = service_dir(args)
    boot = None
    if args.bootstrap:
        boot = read(resolve(args.root, args.bootstrap)[0])
    if service_language(args, sdir) == "nodejs":
        return "nodejs", node_clients(sdir, base, boot)
    return "python", py_clients(sdir)


def cmd_clients(args):
    lang, (rows, read_from) = clients_of(args)
    if args.json:
        print(json.dumps({"language": lang, "read": read_from, "clients": rows}, indent=2))
        return 0
    print(f"database and queue clients ({lang}; read: {', '.join(read_from)}):")
    for r in rows:
        print(f"  {r['client']:<24} {r['status']:<12} {r['detail']}")
    if not rows:
        print("  none of the clients in the coverage table are used here")
    print("Only the clients in scripts/client-coverage.json are recognised. Any other database or queue "
          "client is not checked.")
    return 0


def appended(lines, block, nl):
    """lines + block at the end of a file. A file with no final newline gets one to end its last
    line, and the block then ends without one: that is how removal knows to take it back out."""
    if lines and not lines[-1].endswith(("\n", "\r")):
        return lines[:-1] + [lines[-1] + nl] + block[:-1] + [block[-1].rstrip("\r\n")]
    return lines + block


def cmd_client(args):
    """Turn on one Python instrumentation package: a block at the end of the generated bootstrap,
    and the requirement in requirements.txt (or a `dependency:` line for another manifest)."""
    base, sdir = service_dir(args)
    if service_language(args, sdir) != "python":
        raise Refused("turning a package on is for Python services; in Node.js the bootstrap's bundle "
                      "already loads every package it has. Run `enrich.py clients` to see what is covered.")
    rows, _ = py_clients(sdir)
    row = next((r for r in rows if r["client"] == norm(args.name)), None)
    if row is None:
        raise Refused(f"`{args.name}` is not a client this service uses that the coverage table knows; "
                      f"run `enrich.py clients` for the list.")
    if row["status"] not in ("install", "turn-on"):
        raise Refused(f"`{row['client']}`: {row['detail']}. Nothing to add.")
    spec = next(r for r in load_coverage()["python"]["packages"] if r["label"] == row["client"])
    bid = CLIENT_PREFIX + slug(row["client"])
    full, rel = resolve(args.root, args.bootstrap)
    if lang_of(full) != "py":
        raise Refused(f"{rel} is not a Python file.")
    text = read(full)
    lines, nl = split_lines(text)
    enable = [f"from {spec['module']} import {spec['class']}", f"{spec['class']}().instrument()"]
    if not GENERATED_RE.search(text):
        raise Refused(f"{rel} is not a bootstrap otel-as-code generated, so it is not edited. To turn "
                      f"{spec['package']} on yourself, add after the providers are set: {'; '.join(enable)}")
    blocks_of(lines, rel)
    before = check_python(text, rel)
    if before:
        raise Refused(f"{rel} does not parse before the edit ({before}); nothing written.")
    block = [f"# otel-as-code: enrich begin {bid}{nl}",
             f"try:{nl}",
             f"    {enable[0]}{nl}",
             f"    {enable[1]}{nl}",
             f"except ImportError:  # {spec['package']} is not installed: the service still starts{nl}",
             f"    import logging{nl}",
             f'    logging.getLogger("otel-as-code").warning("{spec["package"]} is not installed: no {row["client"]} spans"){nl}',
             f"# otel-as-code: enrich end {bid}{nl}"]
    out = appended(lines, block, nl)
    new = "".join(out)
    after = check_python(new, rel)
    if after:
        raise Refused(f"the edited {rel} would not parse ({after}); nothing written.")
    # "install" with the instrumentor already turned on: only the requirement is missing.
    edits = [] if row["turned_on"] else [(full, rel, lines, out, new)]
    notes = []
    if row["status"] == "install":
        reqs, _ = py_requirements(sdir)
        pin = next((v for k, v in sorted(reqs.items()) if k.startswith("opentelemetry-instrumentation") and v), "")
        requirement = spec["package"] + pin
        req = os.path.join(sdir, "requirements.txt")
        if os.path.isfile(req) and not os.path.islink(req):
            rrel = os.path.relpath(req, base)
            rlines, rnl = split_lines(read(req))
            blocks_of(rlines, rrel)
            rblock = [f"# otel-as-code: enrich begin {bid}{rnl}", requirement + rnl,
                      f"# otel-as-code: enrich end {bid}{rnl}"]
            redited = appended(rlines, rblock, rnl)
            edits.insert(0, (req, rrel, rlines, redited, "".join(redited)))
            if not pin:
                notes.append(f"note: no other opentelemetry-instrumentation package is pinned in {rrel}, so "
                             f"{spec['package']} is added without a version; pin it to the same release as "
                             f"opentelemetry-instrumentation.")
        else:
            manifest = os.path.join(sdir, "requirements.txt" if os.path.isfile(req) else "pyproject.toml")
            notes.append(f'dependency: add "{requirement}" to the dependencies in '
                         f"{os.path.relpath(manifest, base)} (the bootstrap now imports it).")
    for _, erel, old, edited, _ in edits:
        sys.stdout.writelines(difflib.unified_diff(old, edited, f"a/{erel}", f"b/{erel}"))
    for note in notes:
        print(note)
    what = f"{spec['package']} for `{row['client']}` in {rel} (id {bid})"
    if args.dry_run:
        print(f"dry run: would turn on {what}")
        return 1
    for efull, _, _, _, enew in edits:
        write_atomically(efull, enew)
    print(f"OK: turned on {what}")
    return 0


SPAN_KINDS = {"client": 2, "producer": 3, "consumer": 4}     # the API's SpanKind values
SYSTEM_RE = re.compile(r"^[a-z0-9][a-z0-9_.]{0,39}$")


def client_span_options(args, lang):
    """(kind, attribute key, system, notes) for `span --client`, or Refused when a package covers
    the client: a hand-made span on top of the package's own would be the second one per call."""
    cov = load_coverage()["nodejs" if lang == "js" else "python"]
    name = args.client if lang == "js" else norm(args.client)
    if lang == "js":
        covered = cov["bundle"].get(name) or cov["manual"].get(name)
    else:
        covered = next((r["package"] for r in cov["packages"] if name == r["label"] or name in r["clients"]), None)
    if covered:
        raise Refused(f"`{args.client}` is covered by {covered}; a span around the call as well would make two "
                      f"client spans per call. Run `enrich.py clients` to see how to turn the package on.")
    known = cov["none"].get(name)
    signal, system, notes = args.signal, args.system, []
    if known:
        signal, system = signal or known["signal"], system or known["system"]
    else:
        if not (signal and system):
            raise Refused(f"`{args.client}` is not in the coverage table, so whether a package covers it is not "
                          f"checked. If you have checked that none does, pass --signal db|messaging and --system "
                          f"<the system's name, e.g. sqlite>.")
        notes.append(f"note: `{args.client}` is not in the coverage table; that no instrumentation package covers "
                     f"it was not checked here.")
    if not SYSTEM_RE.match(system):
        raise Refused(f"--system {system!r} must be a lowercase system name such as sqlite or rabbitmq.")
    if signal == "db":
        if args.kind not in (None, "client"):
            raise Refused("a database call is a client span; drop --kind.")
        return "client", "db.system.name", system, notes
    if args.kind not in ("producer", "consumer"):
        raise Refused("for a queue, pass --kind producer (the function sends) or --kind consumer (it "
                      "handles a message).")
    return args.kind, "messaging.system", system, notes


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("span")
    s.add_argument("--file", required=True)
    s.add_argument("--function", required=True)
    s.add_argument("--span-name", required=True)
    s.add_argument("--tracer-name", required=True)
    s.add_argument("--line", type=int)
    s.add_argument("--id")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--client")
    s.add_argument("--signal", choices=["db", "messaging"])
    s.add_argument("--system")
    s.add_argument("--kind", choices=sorted(SPAN_KINDS))
    cs = sub.add_parser("clients")
    cs.add_argument("--json", action="store_true")
    c = sub.add_parser("client")
    c.add_argument("--name", required=True)
    c.add_argument("--dry-run", action="store_true")
    for x in (cs, c):
        x.add_argument("--service-root", default=".")
        x.add_argument("--language", choices=["nodejs", "python"])
    cs.add_argument("--bootstrap")
    c.add_argument("--bootstrap", required=True)
    m = sub.add_parser("metric")
    m.add_argument("--file", required=True)
    m.add_argument("--function", required=True)
    m.add_argument("--line", type=int)
    m.add_argument("--at", type=int, required=True)
    m.add_argument("--where", choices=["before", "after"], required=True)
    m.add_argument("--name", required=True)
    m.add_argument("--value")
    m.add_argument("--meter-name", required=True)
    m.add_argument("--context")
    m.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("remove")
    r.add_argument("--id", action="append")
    r.add_argument("--file")
    r.add_argument("--dry-run", action="store_true")
    ls = sub.add_parser("list")
    for x in (s, m, r, ls, cs, c):
        x.add_argument("--root", default=".")
    args = p.parse_args(argv)
    try:
        return {"span": cmd_span, "metric": cmd_metric, "remove": cmd_remove, "list": cmd_list,
                "clients": cmd_clients, "client": cmd_client}[args.cmd](args)
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

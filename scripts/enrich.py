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
    top = [f"{indent}// otel-as-code: enrich begin {args.id}{nl}",
           f"{indent}return otelTracer.startActiveSpan('{args.span_name}', {a}(otelSpan) => {{ try {{{nl}",
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
    deco = [f"{indent}# otel-as-code: enrich begin {args.id}{nl}",
            f'{indent}@_otel_tracer.start_as_current_span("{args.span_name}"){nl}',
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
    if lang == "py":
        opts = f', unit="{unit}"' if unit else ""
        make = f'{var} = _otel_meter.create_{creator}("{args.name}"{opts})'
    else:
        opts = f", {{ unit: '{unit}' }}" if unit else ""
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
    if not ID_RE.match(args.id) or args.id in SHARED_IDS or args.id.startswith(METRIC_PREFIX):
        raise Refused(f"id {args.id!r} must be lowercase letters, digits and dashes, and not one of the reserved "
                      f"ids ({', '.join(SHARED_IDS)}, {METRIC_PREFIX}*); pass --id.")
    text = read(full)
    if re.search(r"generated by otel-as-code", text, re.I):
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
    for note in notes + [dependency_note(lang, full, args.root)]:
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
            if os.path.splitext(f)[1].lower() in JS_EXTS + PY_EXTS:
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
        lang = lang_of(full)
        # A line the user wrote later may use a name a removed block defined (otelSpan, an
        # instrument variable): removing the block would break that line at run time.
        names = defined_names([lines[i] for i in sorted(drop)], lang)
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
    for x in (s, m, r, ls):
        x.add_argument("--root", default=".")
    args = p.parse_args(argv)
    try:
        return {"span": cmd_span, "metric": cmd_metric, "remove": cmd_remove, "list": cmd_list}[args.cmd](args)
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Gate: the two ways a class can silently stop working now that nothing generates CSS from markup.

CHECK 1 SEPARATOR. Class strings are composed at comptime with `++`, so `row_class ++ " is-selected"`
needs that leading space. Without it the two class names weld into one that matches nothing, the build
stays green and the styling just goes missing. This cost 13 damaged literals once; never again.

CHECK 2 UNDEFINED CLASS. Every class name the markup uses must exist in the built stylesheet, or be
allowlisted as a marker (a hook with no styling of its own) or written at runtime. Tailwind used to
generate whatever the markup asked for; nothing does now, so a typo is silent.

Run from client/. Wired into build.sh.
"""
import os
import re
import sys
import pathlib

APP = pathlib.Path("app")
BUILT = pathlib.Path("dist/glue/app.css")

# hooks that carry no styling of their own, or are written by zig/js at runtime
MARKERS = pathlib.Path("glue/css/class-markers.txt")


def allowed():
    """Markers: class names deliberately carrying no styling (test hooks, runtime-written state).
    Reviewed inventory, not a dumping ground: a NEW unstyled class fails until it is added here."""
    if not MARKERS.exists():
        return set()
    return {ln.split("#")[0].strip() for ln in MARKERS.read_text().split("\n") if ln.split("#")[0].strip()}


def markup_files():
    for root, _dirs, files in os.walk(APP):
        for f in files:
            if f.endswith((".zx", ".zig")):
                yield pathlib.Path(root) / f


def leads_with_space(name):
    """True when `const name = " ..."` supplies the separator itself."""
    pat = re.compile(r"const\s+" + re.escape(name) + r"\s*=\s*\"( )")
    for p in markup_files():
        if pat.search(p.read_text(encoding="utf-8")):
            return True
    return False


def check_separators():
    bad = []
    for p in markup_files():
        for i, line in enumerate(p.read_text(encoding="utf-8").split("\n"), 1):
            if "class" not in line and "_cls" not in line:
                continue
            for m in re.finditer(r"(\w+)\s*\+\+\s*\"([^\"]*)\"", line):
                lit = m.group(2)
                if lit and not lit.startswith(" "):
                    bad.append((p, i, f"{m.group(1)} ++ \"{lit[:40]}\""))
            for m in re.finditer(r"\"([^\"]*)\"\s*\+\+\s*(\w+)", line):
                lit, rhs = m.group(1), m.group(2)
                if not lit or lit.endswith(" ") or lit.endswith("-"):
                    continue
                if leads_with_space(rhs):
                    continue
                bad.append((p, i, f"\"...{lit[-40:]}\" ++ {rhs}"))
    return bad


IMPORT_RE = re.compile(r'const\s+(\w+)\s*=\s*@import\("([^"]+)"\)')
QUALIFIED_RE = re.compile(r"(?<![\w.])([a-z_]\w*)\.([a-z_]\w*)(?![\w(])")
BARE_RE = re.compile(r"(?<![\w.])([a-z_]\w*)(?![\w.(])")


def const_rhs(text, name):
    """The right-hand side of `const name = ...;`, or None when it is not a class string.

    Single line only, and no `{`, `[` or `@`: a class const is a flat run of literals joined with
    `++`, while a struct literal, an array of demo rows or an @import is not one. Without that shape
    filter the resolver walks into `const cast = [_]Char{ .{ .name = "Bob" ...`, and every label in
    the app arrives as a class token that no rule defines."""
    m = re.search(r"(?:pub\s+)?const\s+" + re.escape(name) + r"\s*=\s*([^;\n]*);", text)
    if not m:
        return None
    rhs = m.group(1)
    if any(c in rhs for c in "{[@"):
        return None
    # a call is runtime work, not a class string: `const s = datasetUp(target, "groupOpen")` would
    # otherwise hand the stylesheet a dataset key to define
    calls = re.findall(r"\b(\w+)\s*\(", re.sub(r'"[^"]*"', "", rhs))
    return None if any(c not in ("if", "else", "switch", "while", "for") for c in calls) else rhs


def used_classes():
    """Every class token the markup can produce.

    Three sources, and the third is the one that matters: a class attribute rarely holds the tokens
    directly. It names a const (`class={panel_left_in}`), and that const is itself built by
    concatenating other consts (`panel_left_in = "panel-left ..." ++ panel_base`). So the identifiers
    referenced from class= are resolved transitively; scanning only consts whose NAME looks class-ish
    misses panel_base, act_btn, btn_base and every token they carry.

    Resolution is FILE-SCOPED, and a qualified reference (`char_list.avatar_class`) follows that
    file's own @import to the module it names. Searching every file for a matching const name instead
    lets a generic identifier (`body`, `box`, `empty`, `heading`) bind to an unrelated const in a
    distant file, which is how a label string ends up demanded of the stylesheet as a class."""
    texts = {p: p.read_text(encoding="utf-8") for p in markup_files()}
    by_path = {p.resolve(): p for p in texts}
    imports = {}
    for p, text in texts.items():
        mods = {}
        for name, rel in IMPORT_RE.findall(text):
            target = by_path.get((p.parent / rel).resolve())
            if target is not None:
                mods[name] = target
        imports[p] = mods

    used = {}
    PLAUSIBLE = re.compile(r"^[A-Za-z_@\[][A-Za-z0-9_@\[\]!:./%()+*,~-]*$")

    def add(tokens, p):
        for tok in tokens:
            # a class attribute never holds a selector (".panel-resize"), a format string ("/{s}") or
            # a template fragment (".{{"); those reach here from unrelated consts in .zig files
            if not PLAUSIBLE.match(tok) or "{" in tok or "}" in tok or "\\" in tok:
                continue
            used.setdefault(tok, p)

    pending = []

    def refs(expr, p):
        for m in QUALIFIED_RE.finditer(expr):
            pending.append((p, m.group(1), m.group(2)))
        for m in BARE_RE.finditer(expr):
            pending.append((p, None, m.group(1)))

    for p, text in texts.items():
        for m in re.finditer(r'class="([^"]*)"', text):
            add(m.group(1).split(), p)
        for m in re.finditer(r"class=\{([^}]*)\}", text):
            expr = m.group(1)
            for lit in re.findall(r'"([^"]*)"', expr):
                add(lit.split(), p)
            refs(expr, p)
        # a .zig component passes its class through a struct field rather than markup
        for m in re.finditer(r"\bclass\s*=\s*([a-z_]\w*(?:\.[a-z_]\w*)?)(?![\w(])", text):
            refs(m.group(1), p)

    seen = set()
    while pending:
        p, mod, name = pending.pop()
        if (p, mod, name) in seen:
            continue
        seen.add((p, mod, name))
        owner = imports.get(p, {}).get(mod) if mod else p
        if owner is None:
            continue
        rhs = const_rhs(texts[owner], name)
        if rhs is None:
            continue
        for lit in re.findall(r'"([^"]*)"', rhs):
            add(lit.split(), owner)
        refs(re.sub(r'"[^"]*"', " ", rhs), owner)
    return used


def class_probe(css):
    """Return is_defined(token). Tailwind escapes [ ] ( ) : . , % ! + / etc in class selectors, so
    rather than parse selectors we look for the token literally, allowing an optional backslash before
    any non-word character. Exact, and immune to pseudo-element suffixes (.before\\:x\\[8px\\]::before)."""
    def is_defined(tok):
        pat = "".join(
            re.escape(ch) if ch.isalnum() or ch in "_-" else r"\\?" + re.escape(ch)
            for ch in tok
        )
        return re.search(r"(?<![\w.-])\." + pat + r"(?![\w-])", css) is not None
    return is_defined


def main():
    bad = check_separators()
    print(f"check 1 separator: {len(bad)} concatenation(s) missing a class separator")
    for p, i, what in bad[:20]:
        print(f"  MISSING SPACE  {p}:{i}  {what}")

    undefined = []
    if BUILT.exists():
        ALLOW = allowed()
        is_defined = class_probe(BUILT.read_text(encoding="utf-8"))
        used = used_classes()
        for tok, p in sorted(used.items()):
            if tok in ALLOW or is_defined(tok):
                continue
            # a variant token compiles to an escaped selector carrying the WHOLE token, so look for
            # the token itself first; only then fall back to the bare utility after the last colon.
            # (an earlier version stripped [..] off the head, which silently matched top-[var(--x)]
            # against any .top- rule and let a genuinely undefined utility through)
            if is_defined(tok.rstrip("!")) or is_defined(tok.split(":")[-1].rstrip("!")):
                continue
            undefined.append((tok, p))
        print(f"check 2 undefined: {len(undefined)} class(es) used in markup with no rule in the stylesheet")
        for tok, p in undefined[:25]:
            print(f"  NO RULE  {tok}   (first used in {p})")
    else:
        print("check 2 undefined: no built stylesheet yet, skipped")

    if bad or undefined:
        print("\nclass check: FAIL")
        return 1
    print("class check: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

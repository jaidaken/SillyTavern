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


def used_classes():
    used = {}
    for p in markup_files():
        text = p.read_text(encoding="utf-8")
        for m in re.finditer(r'class="([^"]*)"', text):
            for tok in m.group(1).split():
                used.setdefault(tok, p)
        for m in re.finditer(r"class=\{([^}]*)\}", text):
            for lit in re.findall(r'"([^"]*)"', m.group(1)):
                for tok in lit.split():
                    used.setdefault(tok, p)
        # class-string consts: `const x = "a b c";` in a file that also builds markup
        for m in re.finditer(r"const\s+\w*(?:cls|class)\w*\s*=\s*\"([^\"]*)\"", text):
            for tok in m.group(1).split():
                used.setdefault(tok, p)
    return used


def defined_classes(css):
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    css = css.replace("\\", "")          # tailwind escapes . : / [ ] @ % ( ) in class selectors
    names = set()
    for m in re.finditer(r"\.([^\s{},:>+~()\[\]]+)", css):
        names.add(m.group(1))
    # also the escaped-variant forms, which carry their own colons and brackets
    for m in re.finditer(r"\.([^\s{},>+~]+)", css):
        names.add(m.group(1).rstrip(","))
    return names


def main():
    bad = check_separators()
    print(f"check 1 separator: {len(bad)} concatenation(s) missing a class separator")
    for p, i, what in bad[:20]:
        print(f"  MISSING SPACE  {p}:{i}  {what}")

    undefined = []
    if BUILT.exists():
        ALLOW = allowed()
        defined = defined_classes(BUILT.read_text(encoding="utf-8"))
        used = used_classes()
        for tok, p in sorted(used.items()):
            if tok in ALLOW or tok in defined:
                continue
            # variant-carrying tokens compile to escaped selectors; match the head before the colon
            head = tok.split(":")[-1]
            if head in defined or re.sub(r"\[.*", "", head) in defined:
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

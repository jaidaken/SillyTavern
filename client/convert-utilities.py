#!/usr/bin/env python3
"""Move one page's markup off utility classes and onto a semantic class of its own.

Every utility rule in utilities.css has the shape `<wrapper>{ .<escaped-token><suffix>{decls} }`, so a
conversion is a rewrite of the SELECTOR and nothing else: the new rule keeps the wrapper, keeps the
suffix, keeps the declarations byte for byte, and swaps `.<escaped-token>` for `.<semantic-name>`. That
is what makes the result provably identical to what tailwind produced, rather than a re-derivation of
what the utilities were trying to say.

Declaration ORDER is preserved as utilities.css emits it. Two utilities on one element can set the same
property (`.flex` and `group-data-...:flex-col` both touch flex-direction), and the winner is whichever
tailwind emitted last; merging them in emission order keeps that winner.

Run from client/. Writes the page sheet and the .zx files in place; css-parity.mjs is what proves the
rewrite changed nothing a browser renders.

    ./convert-utilities.py app/pages/notify --sheet app/pages/notify/notify.css [--dry-run]
"""
import argparse
import os
import pathlib
import re
import sys

UTILITIES = pathlib.Path("glue/css/utilities.css")
PRIMITIVES = pathlib.Path("glue/css/primitives.css")
MARKERS = pathlib.Path("glue/css/class-markers.txt")


def split_rules(css):
    """Yield (wrapper, selector, decls) for every rule, including ones inside an at-rule block."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    i, n = 0, len(css)
    while i < n:
        brace = css.find("{", i)
        if brace == -1:
            return
        head = css[i:brace].strip()
        if head.startswith("@"):
            depth, j = 1, brace + 1
            while j < n and depth:
                if css[j] == "{":
                    depth += 1
                elif css[j] == "}":
                    depth -= 1
                j += 1
            for _, sel, decls in split_rules(css[brace + 1:j - 1]):
                yield head, sel, decls
            i = j
            continue
        close = css.find("}", brace)
        yield "", head, css[brace + 1:close].strip()
        i = close + 1


def split_selectors(selector):
    """Split a selector list at top-level commas only: a comma inside :is(...) is not a separator."""
    depth, part, out = 0, [], []
    for ch in selector:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(part))
            part = []
            continue
        part.append(ch)
    out.append("".join(part))
    return out


def token_of(selector):
    """The class token a utility selector is built from, unescaped, plus whatever follows it."""
    if not selector.startswith("."):
        return None, None
    out, i = [], 1
    while i < len(selector):
        c = selector[i]
        if c == "\\":
            i += 1
            if i < len(selector):
                out.append(selector[i])
                i += 1
            continue
        if c in ".:[ >+~,(":
            break
        out.append(c)
        i += 1
    return "".join(out), selector[i:]


def load_utilities():
    """token -> ordered list of (wrapper, suffix, decls), in the file's own emission order."""
    table = {}
    order = []
    for path in (UTILITIES, PRIMITIVES):
        if not path.exists():
            continue
        for wrapper, selector, decls in split_rules(path.read_text(encoding="utf-8")):
            for one in split_selectors(selector):
                tok, suffix = token_of(one.strip())
                if not tok:
                    continue
                table.setdefault(tok, []).append((wrapper, suffix, decls))
                if tok not in order:
                    order.append(tok)
    return table, order


def shared_tokens(page_dir):
    """Class tokens that appear in markup OUTSIDE this page, so this page cannot claim them."""
    out = set()
    for root, _dirs, files in os.walk("app"):
        here = pathlib.Path(root)
        if here == page_dir or page_dir in here.parents:
            continue
        for f in files:
            if not f.endswith((".zx", ".zig")):
                continue
            text = (here / f).read_text(encoding="utf-8")
            for lit in re.findall(r'"([^"]*)"', text):
                out.update(lit.split())
    return out


def markers():
    if not MARKERS.exists():
        return set()
    return {ln.split("#")[0].strip() for ln in MARKERS.read_text().split("\n") if ln.split("#")[0].strip()}


CLASS_ATTR = re.compile(r'class="([^"]*)"')
CLASS_CONST = re.compile(r'((?:pub\s+)?const\s+\w+\s*=\s*)"([^"]*)"')


GENERIC = ("base", "class", "cls", "style", "styles")


def semantic_name(tokens, marks, shared, page, used, hint, util):
    """Prefer a name the markup already carries: a marker on the same element IS the element's name.

    A marker only qualifies while it names ONE set of utilities. panel-left sits on both the entering
    and the leaving dock, and letting both claim it put the leaving variant's pointer-events:none on
    the open panel."""
    for t in tokens:
        if t in used and used[t] != util:
            continue
        # A marker carried by ANOTHER page is that page's element name too. Writing this page's
        # declarations under it hands them to the other page's element: system's `.setting-col`
        # (flex column) landed on setup's grid rows and flattened them.
        if t in shared:
            continue
        # A marker can be a VARIANT token the stylesheet happens not to define (focus-visible:outline-2
        # is allowlisted), and one of those as a class name emits `.focus-visible:outline-2`, which a
        # browser reads as a pseudo-class. Only a plain word-and-dash name can be an element's name.
        if t in marks and "-" in t and re.fullmatch(r"[a-z][a-z0-9-]*", t):
            return t
    parts = [p for p in hint.replace("_", "-").split("-") if p]
    while len(parts) > 1 and parts[-1] in GENERIC:
        parts.pop()
    base = "-".join(parts)
    if not base.startswith(page + "-") and base != page:
        base = f"{page}-{base}"
    name, i = base, 2
    while name in used and used[name] != util:
        name = f"{base}-{i}"
        i += 1
    return name


def emit(name, tokens, table):
    """The rules for one semantic class: same wrappers, same suffixes, same declarations."""
    groups = {}
    seq = []
    for tok in tokens:
        for wrapper, suffix, decls in table[tok]:
            key = (wrapper, suffix)
            if key not in groups:
                groups[key] = []
                seq.append(key)
            groups[key].append(decls)
    out = []
    for wrapper, suffix in seq:
        body = "; ".join(d.rstrip(";") for d in groups[(wrapper, suffix)])
        rule = f".{name}{suffix} {{ {body} }}"
        out.append(f"{wrapper} {{ {rule} }}" if wrapper else rule)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("page")
    ap.add_argument("--sheet", required=True)
    ap.add_argument("--dry-run", action="store_true")
    # A page can own more than one sheet (system has backgrounds.css beside system.css); this keeps a
    # component's rules in the sheet its markup belongs to.
    ap.add_argument("--only", default=None, help="convert only files whose name contains this")
    a = ap.parse_args()

    table, _ = load_utilities()
    marks = markers()
    page_dir = pathlib.Path(a.page)
    shared = shared_tokens(page_dir)
    page = page_dir.name
    sheet = pathlib.Path(a.sheet)

    used, rules, converted = {}, [], 0
    for f in sorted(page_dir.glob("*.zx")) + sorted(page_dir.glob("*.zig")):
        if a.only and a.only not in f.name:
            continue
        text = f.read_text(encoding="utf-8")
        original = text

        def rewrite(class_text, hint):
            nonlocal converted
            toks = class_text.split()
            util = [t for t in toks if t in table]
            keep = [t for t in toks if t not in table]
            if not util:
                return None
            key = frozenset(util)
            name = semantic_name(toks, marks, shared, page, used, hint, key)
            if used.get(name) != key:
                used[name] = key
                rules.extend(emit(name, util, table))
            converted += 1
            body = " ".join(keep + ([name] if name not in keep else []))
            # The edge whitespace IS the separator when the const is concatenated with another
            # (`"panel-left ... " ++ panel_base`). Dropping it welds two class names into one that
            # matches nothing, and the build stays green.
            lead = " " if class_text[:1] == " " else ""
            trail = " " if class_text[-1:] == " " else ""
            return lead + body + trail

        def in_comment(pos):
            """A class string quoted inside a `//` comment is prose about the markup, not markup."""
            line_start = text.rfind("\n", 0, pos) + 1
            slashes = text.find("//", line_start)
            return slashes != -1 and slashes < pos

        def attr_sub(m):
            if in_comment(m.start()):
                return m.group(0)
            # Name the element after its own id when it has one; the tag it sits in starts at the last
            # `<` before the attribute.
            tag = text[text.rfind("<", 0, m.start()):m.start()]
            ident = re.search(r'id="([\w-]+)"', tag)
            if ident:
                hint = ident.group(1)
            else:
                # No id of its own: name it after the nearest id ABOVE it, which is the container it
                # belongs to, so a hand pass has a real word to refine rather than a counter.
                above = re.findall(r'id="([\w-]+)"', text[:m.start()])
                hint = f"{above[-1]}-part" if above else f"{f.stem}-part"
            new = rewrite(m.group(1), hint)
            return m.group(0) if new is None else f'class="{new}"'

        def const_sub(m):
            if in_comment(m.start()):
                return m.group(0)
            ident = re.search(r"const\s+(\w+)", m.group(1))
            new = rewrite(m.group(2), ident.group(1).replace("_", "-") if ident else "cls")
            return m.group(0) if new is None else f'{m.group(1)}"{new}"'

        text = CLASS_ATTR.sub(attr_sub, text)
        text = CLASS_CONST.sub(const_sub, text)
        if text != original and not a.dry_run:
            f.write_text(text, encoding="utf-8")

    banner = f"\n/* ---- Converted off the utility classes, {converted} class attributes. Selectors, wrappers and\n" \
             f"   declarations are the ones utilities.css emitted; only the class NAME changed.\n" \
             f"   This block sits ABOVE the page's authored rules because that is where the utilities sat:\n" \
             f"   an authored rule is written to beat a utility at equal specificity (.composer-stop's\n" \
             f"   display:none over btn_base's grid), and appending would have handed the win back. ---- */\n"
    if not a.dry_run and rules:
        text = sheet.read_text(encoding="utf-8")
        head = text.find("*/")
        cut = text.index("\n", head) + 1 if head != -1 else 0
        body = banner + "\n".join(rules) + "\n"
        sheet.write_text(text[:cut] + body + text[cut:], encoding="utf-8")
    print(f"{page}: {converted} class strings converted, {len(rules)} rules emitted -> {sheet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

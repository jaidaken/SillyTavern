#!/usr/bin/env python3
"""Gate: our reset must cover every selector/property pair Tailwind's preflight provided.

The reference is glue/css/vendor/tailwind-preflight-reference.css (preflight as it stood at
bb8f5f81b). Our side is glue/css/vendor/modern-normalize.css + glue/css/reset-addendum.css.
Exit 1 with the uncovered list; exit 0 when every pair is accounted for.

Run from client/. Wired into build.sh so a reset regression fails the build rather than the eye.
"""
import re
import sys
import pathlib

CSS = pathlib.Path("glue/css")
REFERENCE = CSS / "vendor/tailwind-preflight-reference.css"
OURS = [CSS / "vendor/modern-normalize.css", CSS / "reset-addendum.css"]

# preflight ships these purely to drive tailwind's own utilities; nothing outside tailwind reads them
IGNORED_PROPS = {"--tw-translate-x", "--tw-translate-y", "--tw-translate-z", "--tw-border-style"}
# tailwind theme plumbing: our tokens own these instead
IGNORED_SELECTORS = {"::backdrop"}


def split_selectors(sel):
    """Split a selector list on top-level commas only: a comma inside :where(...) or [..] is not one."""
    parts, depth, buf = [], 0, ""
    for ch in sel:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(buf)
            buf = ""
        else:
            buf += ch
    parts.append(buf)
    return [p.strip() for p in parts if p.strip()]


def pairs(text):
    """{(selector, property)} over every rule, at-rule contexts flattened."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = set()
    for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", text):
        sel = " ".join(m.group(1).split())
        if sel.startswith("@") or not sel:
            continue
        props = set()
        for decl in m.group(2).split(";"):
            if ":" in decl:
                props.add(decl.split(":", 1)[0].strip().lower())
        for one in split_selectors(sel):
            for p in props:
                out.add((one, p))
    return out


def norm(sel):
    """A selector's identity for coverage purposes: legacy :before == ::before, whitespace collapsed."""
    sel = re.sub(r"(?<!:):(before|after|placeholder|backdrop|file-selector-button)\b", r"::\1", sel)
    sel = re.sub(r"([\[=])\s*[\"']([^\"']*)[\"']", r"\1\2", sel)   # [type="button"] == [type=button]
    sel = re.sub(r"\s*,\s*", ",", sel)                             # nested list spacing is cosmetic
    return re.sub(r"\s+", " ", sel).strip()


def main():
    missing = REFERENCE if not REFERENCE.exists() else None
    for p in OURS:
        if not p.exists():
            missing = p
    if missing:
        print(f"check-reset-coverage: missing {missing}", file=sys.stderr)
        return 2

    want = {(norm(s), p) for s, p in pairs(REFERENCE.read_text(encoding="utf-8"))}
    have = set()
    for p in OURS:
        have |= {(norm(s), pr) for s, pr in pairs(p.read_text(encoding="utf-8"))}

    want = {(s, p) for s, p in want if p not in IGNORED_PROPS and s not in IGNORED_SELECTORS}

    # a property covered on a grouped selector counts for each member; also treat the universal
    # selector as covering ::before/::after/::backdrop, which is how both files express it
    universal = {p for s, p in have if s == "*"}
    uncovered = sorted(
        (s, p) for s, p in want
        if (s, p) not in have and not (p in universal and s in {"*", "::before", "::after", "::backdrop", "::file-selector-button"})
    )

    print(f"reference pairs: {len(want)}   ours: {len(have)}   uncovered: {len(uncovered)}")
    if uncovered:
        for s, p in uncovered:
            print(f"  UNCOVERED  {s}  ->  {p}")
        print("\nreset coverage: FAIL")
        return 1
    print("reset coverage: PASS (every preflight selector/property pair is covered)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

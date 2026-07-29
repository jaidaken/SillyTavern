#!/usr/bin/env python3
"""Delete the utility definitions no markup asks for any more.

utilities.css is the compiled remainder the per-page conversions drain, so a token that no .zx or .zig
still names is dead weight in every page's download. This finds them with the same resolver the class
gate uses, so a token reached only through a chain of consts still counts as used.

primitives.css is left alone: it is the permanent layout set, not the remainder.

Run from client/.  ./prune-utilities.py [--dry-run]
"""
import importlib.util
import pathlib
import re
import sys

UTILITIES = pathlib.Path("glue/css/utilities.css")


def gate():
    spec = importlib.util.spec_from_file_location("cc", "check-classes.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    dry = "--dry-run" in sys.argv
    cc = gate()
    conv = importlib.util.spec_from_file_location("cu", "convert-utilities.py")
    cu = importlib.util.module_from_spec(conv)
    conv.loader.exec_module(cu)

    used = set(cc.used_classes())
    # Belt and braces on top of the resolver: a token that appears ANYWHERE in the markup as literal
    # text is kept, whatever the resolver made of it. Deleting a rule the resolver failed to see would
    # not fail the class gate either, since the gate is blind to it in exactly the same way.
    literal = "\n".join(p.read_text(encoding="utf-8") for p in cc.markup_files())
    text = UTILITIES.read_text(encoding="utf-8")
    kept, dropped = [], []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("@"):
            kept.append(line)
            continue
        tokens = set()
        for _wrapper, selector, _decls in cu.split_rules(line):
            # A comma inside :is(...) is not a selector separator, so split at depth 0 only. Reading
            # `.selected\:bg-selected:is([data-selected=true],.is-selected)` as two selectors named a
            # token nothing uses and dropped three live rules.
            depth, part, parts = 0, [], []
            for ch in selector:
                if ch in "([":
                    depth += 1
                elif ch in ")]":
                    depth -= 1
                if ch == "," and depth == 0:
                    parts.append("".join(part))
                    part = []
                    continue
                part.append(ch)
            parts.append("".join(part))
            for one in parts:
                tok, _ = cu.token_of(one.strip())
                if tok:
                    tokens.add(tok)
        if tokens and not (tokens & used) and not any(t in literal for t in tokens):
            dropped.append(sorted(tokens)[0])
            continue
        kept.append(line)

    print(f"prune-utilities: {len(dropped)} unused utility line(s)")
    for d in dropped[:40]:
        print(f"  DROP  {d}")
    if dropped and not dry:
        UTILITIES.write_text("\n".join(kept), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

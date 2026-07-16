#!/usr/bin/env bash
# Apply D1 (readString cache stale-read/leak) and D2 (loud DOM glue) to the exported ziex door. The
# door ships as a prebuilt tarball, so patch 03's core.ts diff never reaches the build; this edits
# the compiled JS.
set -euo pipefail

cd "$(dirname "$0")"

DOOR="${1:-dist/vendor/ziex/wasm/index.js}"
[ -f "$DOOR" ] || { echo "patch-door: $DOOR not found (run export first)" >&2; exit 1; }

python3 - "$DOOR" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
changed = False
# Nothing prints until after the write, so an aborted run cannot claim a patch it did not write.
# Errors accumulate so a door bump names every stale expectation in one run, not one per rebuild.
notes, errors = [], []

# ---------------------------------------------------------------------------
# D1: readString cache -> uncached
# ---------------------------------------------------------------------------

cache = """var stringCache = new Map;
function stringCacheKey(ptr, len) {
  return ptr * 65536 + len;
}
function readString(ptr, len) {
  const key = stringCacheKey(ptr, len);
  const cached = stringCache.get(key);
  if (cached !== undefined)
    return cached;
  const str = textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));
  stringCache.set(key, str);
  return str;
}"""

uncached = """function readString(ptr, len) {
  return textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));
}"""

# Patched state is the PRESENCE of the uncached body, never the absence of the cache markers:
# a reformatted or minified door has both markers absent while still carrying the D1 bug.
if uncached in s:
    notes.append("patch-door: D1 already patched, nothing to do")
elif cache not in s:
    errors.append("patch-door: D1 found neither the uncached readString nor the cache block "
                  "verbatim; door version changed, update patch-door.sh")
else:
    s = s.replace(cache, uncached, 1)
    changed = True
    notes.append("patch-door: D1 readString uncached, stringCache removed")

# D2: the DOM glue no-ops silently on a registry miss, so ziex's virtual tree and the real DOM
# drift apart and the crash lands later somewhere unrelated.

# Sentinel = the PRESENCE of the new body (same reasoning as D1: a reformatted door has the old
# markers absent while still carrying the silent no-ops).
D2_SENTINEL = '"[zx:dom] ANOMALY "'

glue_old = """        _ce: (id, vnodeId) => {
          const tagName = TAG_NAMES[id];
          const el = id >= SVG_TAG_START_INDEX ? document.createElementNS("http://www.w3.org/2000/svg", tagName) : document.createElement(tagName);
          el.__zx_ref = Number(vnodeId);
          domNodes.set(vnodeId, el);
          return storeValueGetRef(el);
        },
        _ct: (ptr, len, vnodeId) => {
          const text = readString(ptr, len);
          const node = document.createTextNode(text);
          node.__zx_ref = Number(vnodeId);
          domNodes.set(vnodeId, node);
          return storeValueGetRef(node);
        },
        _sa: (vnodeId, namePtr, nameLen, valPtr, valLen) => {
          domNodes.get(vnodeId)?.setAttribute(readString(namePtr, nameLen), readString(valPtr, valLen));
        },
        _sp: (vnodeId, namePtr, nameLen, valPtr, valLen) => {
          const el = domNodes.get(vnodeId);
          if (el) {
            const name = readString(namePtr, nameLen);
            const val = readString(valPtr, valLen);
            if (name === "checked" || name === "selected" || name === "muted") {
              el[name] = val !== "false";
            } else {
              el[name] = val;
            }
          }
        },
        _ra: (vnodeId, namePtr, nameLen) => {
          domNodes.get(vnodeId)?.removeAttribute(readString(namePtr, nameLen));
        },
        _snv: (vnodeId, ptr, len) => {
          const node = domNodes.get(vnodeId);
          if (node)
            node.nodeValue = readString(ptr, len);
        },
        _srh: (vnodeId, ptr, len) => {
          const el = domNodes.get(vnodeId);
          if (el)
            el.innerHTML = readString(ptr, len);
        },
        _ac: (parentId, childId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          if (parent && child)
            parent.appendChild(child);
        },
        _ib: (parentId, childId, refId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          const ref = domNodes.get(refId) ?? null;
          if (parent && child)
            parent.insertBefore(child, ref);
        },
        _rc: (parentId, childId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          if (parent && child) {
            parent.removeChild(child);
            cleanupDomNodes(child);
          }
        },
        _rpc: (parentId, newId, oldId) => {
          const parent = domNodes.get(parentId);
          const newChild = domNodes.get(newId);
          const oldChild = domNodes.get(oldId);
          if (parent && newChild && oldChild) {
            parent.replaceChild(newChild, oldChild);
            cleanupDomNodes(oldChild);
          }
        },"""

glue_new = """        _ce: (id, vnodeId) => {
          const tagName = TAG_NAMES[id];
          if (domNodes.has(vnodeId))
            zxAnomaly("_ce re-create #" + vnodeId + " as " + tagName + ", id already live as " + zxTag(domNodes.get(vnodeId)) + "; the previous node is now orphaned");
          const el = id >= SVG_TAG_START_INDEX ? document.createElementNS("http://www.w3.org/2000/svg", tagName) : document.createElement(tagName);
          el.__zx_ref = Number(vnodeId);
          domNodes.set(vnodeId, el);
          if (globalThis.__zx_debug)
            zxTrace("_ce #" + vnodeId + " " + tagName);
          return storeValueGetRef(el);
        },
        _ct: (ptr, len, vnodeId) => {
          const text = readString(ptr, len);
          if (domNodes.has(vnodeId))
            zxAnomaly("_ct re-create #" + vnodeId + " as #text, id already live as " + zxTag(domNodes.get(vnodeId)) + "; the previous node is now orphaned");
          const node = document.createTextNode(text);
          node.__zx_ref = Number(vnodeId);
          domNodes.set(vnodeId, node);
          if (globalThis.__zx_debug)
            zxTrace("_ct #" + vnodeId + " #text " + zxSnip(text));
          return storeValueGetRef(node);
        },
        _sa: (vnodeId, namePtr, nameLen, valPtr, valLen) => {
          domNodes.get(vnodeId)?.setAttribute(readString(namePtr, nameLen), readString(valPtr, valLen));
          if (globalThis.__zx_debug)
            zxTrace("_sa " + zxWho(vnodeId) + " " + readString(namePtr, nameLen) + "=" + zxSnip(readString(valPtr, valLen)));
        },
        _sp: (vnodeId, namePtr, nameLen, valPtr, valLen) => {
          const el = domNodes.get(vnodeId);
          if (el) {
            const name = readString(namePtr, nameLen);
            const val = readString(valPtr, valLen);
            if (name === "checked" || name === "selected" || name === "muted") {
              el[name] = val !== "false";
            } else {
              el[name] = val;
            }
            if (globalThis.__zx_debug)
              zxTrace("_sp " + zxWho(vnodeId) + " ." + name + "=" + zxSnip(val));
          } else if (globalThis.__zx_debug) {
            zxTrace("_sp " + zxWho(vnodeId) + " property write dropped");
          }
        },
        _ra: (vnodeId, namePtr, nameLen) => {
          domNodes.get(vnodeId)?.removeAttribute(readString(namePtr, nameLen));
          if (globalThis.__zx_debug)
            zxTrace("_ra " + zxWho(vnodeId) + " -" + readString(namePtr, nameLen));
        },
        _snv: (vnodeId, ptr, len) => {
          const node = domNodes.get(vnodeId);
          if (node) {
            if (globalThis.__zx_debug)
              zxTrace("_snv " + zxWho(vnodeId) + " = " + zxSnip(readString(ptr, len)));
            node.nodeValue = readString(ptr, len);
          } else {
            zxAnomaly("_snv missing node #" + vnodeId + "; text update dropped, the vdom now believes a write landed that did not");
          }
        },
        _srh: (vnodeId, ptr, len) => {
          const el = domNodes.get(vnodeId);
          if (el) {
            // innerHTML destroys every existing child. Prune them from domNodes first: without
            // this they stay registered forever, and a later op on a stale id is exactly the
            // drift that makes _rc throw.
            const pruned = zxPruneChildren(el);
            if (globalThis.__zx_debug)
              zxTrace("_srh " + zxWho(vnodeId) + " innerHTML, pruned " + pruned + " tracked node(s)");
            el.innerHTML = readString(ptr, len);
          } else {
            zxAnomaly("_srh missing node #" + vnodeId + "; innerHTML write dropped, the vdom now believes a write landed that did not");
          }
        },
        _ac: (parentId, childId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          if (parent && child) {
            if (globalThis.__zx_debug)
              zxTrace("_ac " + zxWho(parentId) + " <- " + zxWho(childId));
            parent.appendChild(child);
          } else {
            zxAnomaly("_ac append dropped, missing " + zxMissing(parent, parentId, child, childId) + "; parent " + zxWho(parentId) + ", child " + zxWho(childId));
          }
        },
        _ib: (parentId, childId, refId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          const ref = domNodes.get(refId) ?? null;
          if (parent && child) {
            // The zig side routes a null reference to _ac (render.zig PLACEMENT/MOVE), so _ib is
            // only ever called with a real ref id: a missing or foreign ref is drift, never an
            // append. Recover as an append rather than throw. Appending to the claimed parent is
            // the semantics zig already accepts for a null ref, so this is a position error only.
            let useRef = ref;
            if (!ref) {
              useRef = null;
              zxAnomaly("_ib missing ref #" + refId + "; RECOVERED by appending " + zxWho(childId) + " to " + zxWho(parentId) + " instead of throwing. The node is live under the right parent, but its POSITION may be wrong");
            } else if (ref.parentNode !== parent) {
              useRef = null;
              zxAnomaly("_ib ref " + zxWho(refId) + " is not a child of claimed parent " + zxWho(parentId) + " (actual parent " + zxActual(ref) + "); insertBefore would have thrown. RECOVERED by appending " + zxWho(childId) + " to the claimed parent. The node is live under the right parent, but its POSITION may be wrong");
            }
            if (globalThis.__zx_debug)
              zxTrace("_ib " + zxWho(parentId) + " <- " + zxWho(childId) + " before " + zxWho(refId));
            parent.insertBefore(child, useRef);
          } else {
            zxAnomaly("_ib insert dropped, missing " + zxMissing(parent, parentId, child, childId) + "; parent " + zxWho(parentId) + ", child " + zxWho(childId) + ", ref " + zxWho(refId));
          }
        },
        _rc: (parentId, childId) => {
          const parent = domNodes.get(parentId);
          const child = domNodes.get(childId);
          if (parent && child) {
            if (child.parentNode === parent) {
              if (globalThis.__zx_debug)
                zxTrace("_rc " + zxWho(parentId) + " -x " + zxWho(childId));
              parent.removeChild(child);
              cleanupDomNodes(child);
            } else {
              // Both nodes are live but the tree disagrees: removeChild would throw NotFoundError
              // here and take the page with it. Detach from the real parent (the caller's intent
              // is that this child goes away) and prune, so the page survives and the console
              // names the drift instead of a stack in unrelated code.
              zxAnomaly("_rc TREE DRIFT: child " + zxWho(childId) + " sits under " + zxActual(child) + " but the vdom claims parent " + zxWho(parentId) + "; removing it from its actual parent and pruning");
              if (child.parentNode)
                child.parentNode.removeChild(child);
              cleanupDomNodes(child);
            }
          } else {
            zxAnomaly("_rc remove dropped, missing " + zxMissing(parent, parentId, child, childId) + "; parent " + zxWho(parentId) + ", child " + zxWho(childId));
          }
        },
        _rpc: (parentId, newId, oldId) => {
          const parent = domNodes.get(parentId);
          const newChild = domNodes.get(newId);
          const oldChild = domNodes.get(oldId);
          if (parent && newChild && oldChild) {
            if (globalThis.__zx_debug)
              zxTrace("_rpc " + zxWho(parentId) + ": " + zxWho(oldId) + " -> " + zxWho(newId));
            if (oldChild.parentNode === parent) {
              parent.replaceChild(newChild, oldChild);
            } else {
              // replaceChild would throw NotFoundError and take the page down. Detach the old node
              // from wherever it really is (as _rc does), then append the new one to the claimed
              // parent: node count and liveness stay right, only order can be wrong.
              zxAnomaly("_rpc oldChild " + zxWho(oldId) + " is not a child of claimed parent " + zxWho(parentId) + " (actual parent " + zxActual(oldChild) + "); replaceChild would have thrown. RECOVERED by detaching the old node and appending " + zxWho(newId) + " to the claimed parent. Both nodes are live and the node count is right, but the new node's POSITION may be wrong");
              if (oldChild.parentNode)
                oldChild.parentNode.removeChild(oldChild);
              parent.appendChild(newChild);
            }
            cleanupDomNodes(oldChild);
          } else {
            zxAnomaly("_rpc replace dropped, missing " + zxMissing3(parent, parentId, newChild, newId, oldChild, oldId) + "; parent " + zxWho(parentId) + ", new " + zxWho(newId) + ", old " + zxWho(oldId));
          }
        },"""

helpers_old = """var domNodes = new Map;
function cleanupDomNodes(node) {
  const ref = node.__zx_ref;
  if (ref !== undefined)
    domNodes.delete(BigInt(ref));
  const children = node.childNodes;
  for (let i = 0;i < children.length; i++)
    cleanupDomNodes(children[i]);
}"""

helpers_new = """var domNodes = new Map;
function cleanupDomNodes(node) {
  const ref = node.__zx_ref;
  if (ref !== undefined)
    domNodes.delete(BigInt(ref));
  const children = node.childNodes;
  for (let i = 0;i < children.length; i++)
    cleanupDomNodes(children[i]);
}
function zxTag(node) {
  if (!node)
    return "?";
  if (node.nodeType === 3)
    return "#text";
  if (node.nodeType === 8)
    return "#comment";
  return (node.nodeName || "?").toLowerCase();
}
function zxWho(id) {
  const node = domNodes.get(id);
  return node ? "#" + id + " " + zxTag(node) : "#" + id + " <untracked>";
}
function zxActual(node) {
  const parent = node && node.parentNode;
  if (!parent)
    return "<detached>";
  const ref = parent.__zx_ref;
  return (ref === undefined ? "#<untracked> " : "#" + ref + " ") + zxTag(parent);
}
function zxSnip(text) {
  const str = String(text);
  return JSON.stringify(str.length > 40 ? str.slice(0, 40) + "..." : str);
}
function zxMissing(parent, parentId, child, childId) {
  const out = [];
  if (!parent)
    out.push("parent #" + parentId);
  if (!child)
    out.push("child #" + childId);
  return out.join(" + ");
}
function zxMissing3(parent, parentId, newChild, newId, oldChild, oldId) {
  const out = [];
  if (!parent)
    out.push("parent #" + parentId);
  if (!newChild)
    out.push("new #" + newId);
  if (!oldChild)
    out.push("old #" + oldId);
  return out.join(" + ");
}
function zxPruneChildren(el) {
  const children = el.childNodes;
  let n = 0;
  for (let i = 0;i < children.length; i++)
    n += zxPruneNode(children[i]);
  return n;
}
function zxPruneNode(node) {
  let n = 0;
  const ref = node.__zx_ref;
  if (ref !== undefined && domNodes.delete(BigInt(ref)))
    n++;
  const children = node.childNodes;
  for (let i = 0;i < children.length; i++)
    n += zxPruneNode(children[i]);
  return n;
}
function zxAnomaly(msg) {
  console.error("[zx:dom] ANOMALY " + msg);
}
function zxTrace(msg) {
  console.debug("[zx:dom] " + msg);
}"""

if D2_SENTINEL in s:
    notes.append("patch-door: D2 already patched, nothing to do")
else:
    missing = []
    if glue_old not in s:
        missing.append("the DOM glue block (_ce.._rpc)")
    if helpers_old not in s:
        missing.append("the domNodes/cleanupDomNodes block")
    if missing:
        errors.append("patch-door: D2 could not find " + " and ".join(missing) + " verbatim; "
                      "door version changed, update patch-door.sh")
    else:
        s = s.replace(glue_old, glue_new, 1)
        s = s.replace(helpers_old, helpers_new, 1)
        changed = True
        notes.append("patch-door: D2 DOM glue instrumented "
                     "(anomalies always on, traces behind __zx_debug)")

# All-or-nothing: any stale expectation aborts before the write, so a door bump can never ship a
# half-patched door.
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)

if changed:
    p.write_text(s)
for n in notes:
    print(n)
PY

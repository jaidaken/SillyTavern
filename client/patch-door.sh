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
          // Not on the named list but the same impossible data: appendChild(self) throws
          // HierarchyRequestError, so acting here crashes rather than blanks.
          if (parentId === childId) {
            zxAnomaly("_ac INCOHERENT PATCH: parent and child are both " + zxWho(childId) + "; a node cannot be its own parent, so this patch cannot be true of any tree. REFUSED, nothing touched. Appending a node to itself would throw HierarchyRequestError");
            return;
          }
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
          // _ib cannot blank the page the way _rc can, but the same data is impossible and acting
          // on it would move a live node somewhere the vdom never meant.
          if (parentId === childId) {
            zxAnomaly("_ib INCOHERENT PATCH: parent and child are both " + zxWho(childId) + "; a node cannot be its own parent, so this patch cannot be true of any tree. REFUSED, nothing touched");
            return;
          }
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
          // GARBAGE, not drift: drift is coherent data describing the wrong tree and is worth
          // recovering; this is data that cannot be true under any tree, so the only safe act is
          // none. Recovering here detached Shell's root and blanked the whole page.
          if (parentId === childId) {
            zxAnomaly("_rc INCOHERENT PATCH: parent and child are both " + zxWho(childId) + "; a node cannot be its own parent, so this patch cannot be true of any tree. REFUSED, nothing touched. Recovering from it would detach a live subtree and blank the page");
            return;
          }
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
          // Same split as _rc: only the destructive branch is reachable with impossible data, and
          // detaching on a patch that cannot be true is how a contained fault becomes a blank page.
          if (parentId === oldId || parentId === newId) {
            zxAnomaly("_rpc INCOHERENT PATCH: claimed parent " + zxWho(parentId) + " is also the " + (parentId === oldId ? "old" : "new") + " child; a node cannot be its own parent, so this patch cannot be true of any tree. REFUSED, nothing touched");
            return;
          }
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
}
// Asks what the registry HOLDS, so drift is findable before it surfaces as a throw. Ungated: a
// diagnostic you must switch on first is one you will not have when you need it. REPORTS ONLY;
// pruning here would destroy the evidence it exists to measure.
var ZX_AUDIT_CAP = 50;
globalThis.__zx_audit = function () {
  const orphans = [];
  let orphanCount = 0;
  domNodes.forEach(function (node, id) {
    // A tracked node under an UNTRACKED parent is not drift: #shell, #chat-home and #composer all
    // hang off SSR markup carrying no __zx_ref, so only isConnected separates stranded from fine.
    if (node.isConnected !== false)
      return;
    orphanCount++;
    if (orphans.length >= ZX_AUDIT_CAP)
      return;
    const parent = node.parentNode;
    const parentRef = parent && parent.__zx_ref !== undefined ? parent.__zx_ref : null;
    orphans.push({ id: Number(id), tag: zxTag(node), actualParent: parentRef, connected: false });
  });
  return { tracked: domNodes.size, orphanCount: orphanCount, orphans: orphans };
};"""

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

# ---------------------------------------------------------------------------
# D3: a throw out of wasm strands the render gate -> recover
# ---------------------------------------------------------------------------
# A render that throws through the wasm frames skips every Zig `defer` on the way out, including the
# render gate's `exit`. The gate then stays held by a pass that no longer exists, every later render
# is refused, and the page freezes with no error of its own (measured: all four render counters
# frozen, `uncaught exceptions: 0`). This is the ONLY seam that sees those throws: the sync ones come
# straight out of `fn(...args)`, and the promising-wrapped ones arrive as a REJECTION, which is why
# every instrument reported zero exceptions.

seam_old = """function invokeWasmExport(fn, ...args) {
  if (!fn)
    return;
  const result = fn(...args);
  if (result && typeof result.then === "function") {
    result.then(undefined, (error) => {
      console.error(error);
    });
  }
}"""

seam_new = """var zxRecoverExport = null;
function zxRenderRecover(error) {
  // The STACK, not String(error): concatenating an Error yields its message alone, which names the
  // failure and not the site. That cost a localization pass on a live RangeError.
  const where = (error && error.stack) ? error.stack : String(error);
  zxAnomaly("a render threw out through the wasm frames: " + where + " -- every Zig defer on that " +
    "path was skipped, including the render gate's exit, so the gate is held and NOTHING renders again");
  if (!zxRecoverExport) {
    zxAnomaly("no __zx_render_recover export in this build: the gate stays held and the page is dead until reload");
    return;
  }
  const code = zxRecoverExport();
  if (code === 0) {
    zxAnomaly("render recover: the gate was NOT held, so this throw stranded nothing and nothing was dropped (0)");
  } else if (code === 2) {
    zxAnomaly("render recover: gate cleared and the throwing component's vtree DROPPED (2); the next " +
      "render rebuilds that component from itself, so expect one visible rebuild of that subtree");
  } else {
    zxAnomaly("render recover: gate cleared but NO vtree was dropped (" + code + "); the throwing " +
      "component could not be named, so its vtree may still describe a DOM that never happened");
  }
}
function invokeWasmExport(fn, ...args) {
  if (!fn)
    return;
  let result;
  try {
    result = fn(...args);
  } catch (error) {
    zxRenderRecover(error);
    throw error;
  }
  if (result && typeof result.then === "function") {
    result.then(undefined, (error) => {
      zxRenderRecover(error);
    });
  }
  return result;
}"""

memory_old = """  wasmMemory = instance.exports.memory;"""

memory_new = """  wasmMemory = instance.exports.memory;
  zxRecoverExport = instance.exports.__zx_render_recover ?? null;"""

# The import half of patch 15's `_forgetNode`. Zig calls it from unregisterVElement; a recovery
# rebuild detaches the old tree via clearContent's RAW removeChild, which the tracked glue never
# sees, so without this the door keeps a registry entry per node forever (measured: 178).
# NOT optional: a declared-but-unsupplied import is a LinkError, so 15 and D3 ship together.
forget_old = """        _clearEventHandlerModes: (vnodeId) => {
          bridgeRef.current?.clearEventHandlerModes(vnodeId);
        },"""

forget_new = """        _clearEventHandlerModes: (vnodeId) => {
          bridgeRef.current?.clearEventHandlerModes(vnodeId);
        },
        _forgetNode: (vnodeId) => {
          domNodes.delete(vnodeId);
        },"""

D3_SENTINEL = "zxRenderRecover"

if D3_SENTINEL in s:
    notes.append("patch-door: D3 already patched, nothing to do")
else:
    missing = []
    if s.count(seam_old) != 1:
        missing.append("invokeWasmExport (found %d, want 1)" % s.count(seam_old))
    if s.count(memory_old) != 1:
        missing.append("the wasmMemory assignment in init (found %d, want 1)" % s.count(memory_old))
    if s.count(forget_old) != 1:
        missing.append("the _clearEventHandlerModes import (found %d, want 1)" % s.count(forget_old))
    if missing:
        errors.append("patch-door: D3 could not find " + " and ".join(missing) +
                      " verbatim; door version changed, update patch-door.sh")
    else:
        s = s.replace(seam_old, seam_new, 1)
        s = s.replace(memory_old, memory_new, 1)
        s = s.replace(forget_old, forget_new, 1)
        changed = True
        notes.append("patch-door: D3 wasm entrypoints recover the render gate on a throw, "
                     "and _forgetNode prunes the registry the rebuild strands")

# ---------------------------------------------------------------------------
# D4: scroll delegation binds without capture -> child scroll never delivered
# ---------------------------------------------------------------------------
# Delegation binds on <body>; scroll does NOT bubble so a nested #chat scroll never reaches it, but
# scroll DOES fire in the CAPTURE phase, so capture:true delivers it (shared opts fix remove too).

scroll_old = 'const options = { passive: delegatedEvent.domType.startsWith("touch") || delegatedEvent.domType === "scroll" };'
scroll_new = 'const options = { passive: delegatedEvent.domType.startsWith("touch") || delegatedEvent.domType === "scroll", capture: delegatedEvent.domType === "scroll" };'

D4_SENTINEL = 'capture: delegatedEvent.domType === "scroll"'

if D4_SENTINEL in s:
    notes.append("patch-door: D4 already patched, nothing to do")
elif s.count(scroll_old) != 1:
    errors.append("patch-door: D4 could not find the scroll delegation options object "
                  "verbatim (found %d, want 1); door version changed, update patch-door.sh"
                  % s.count(scroll_old))
else:
    s = s.replace(scroll_old, scroll_new, 1)
    changed = True
    notes.append("patch-door: D4 scroll delegation bound with capture, "
                 "child #chat scroll now reaches its onscroll handler")

# ---------------------------------------------------------------------------
# D5: pointer events are not in the delegation table -> add them
# ---------------------------------------------------------------------------
# The resize drags (reading width, panel dock) need pointerdown/move/up/cancel to reach their Zig
# handlers. setPointerCapture retargets move/up to the handle, which still bubbles to <body>, so no
# capture phase is needed (unlike scroll). Ordinals 19-22 stay in lockstep with the EventType enum
# (source patch 21).

ptr_old = """  { domType: "scroll", eventTypeId: 18 }
];"""
ptr_new = """  { domType: "scroll", eventTypeId: 18 },
  { domType: "pointerdown", eventTypeId: 19 },
  { domType: "pointermove", eventTypeId: 20 },
  { domType: "pointerup", eventTypeId: 21 },
  { domType: "pointercancel", eventTypeId: 22 }
];"""

D5_SENTINEL = 'domType: "pointerdown"'

if D5_SENTINEL in s:
    notes.append("patch-door: D5 already patched, nothing to do")
elif s.count(ptr_old) != 1:
    errors.append("patch-door: D5 could not find the DELEGATED_EVENTS scroll tail verbatim "
                  "(found %d, want 1); door version changed, update patch-door.sh" % s.count(ptr_old))
else:
    s = s.replace(ptr_old, ptr_new, 1)
    changed = True
    notes.append("patch-door: D5 pointer events delegated "
                 "(pointerdown/move/up/cancel, ids 19-22)")

# ---------------------------------------------------------------------------
# D6: gate the ambient pointermove delegation to active drags
# ---------------------------------------------------------------------------
# The door stores a jsz slot per delegated dispatch and never reclaims it (measured: 600 ambient
# pointermove = +2400 live slots, idPool never refilled). pointermove fires on every cursor move over
# the app, so it is gated behind a flag the Zig drag handlers set on pointerdown and clear on
# pointerup/cancel: with no active drag the walk (and its slot leak) never runs. pointerdown/up/cancel
# stay ungated - they fire once per press, like the mousedown/mouseup already in the table.

gate_decl_old = """var eventHandlerModes = new Map;
function initEventDelegation(bridge, rootSelector = "body") {"""
gate_decl_new = """var eventHandlerModes = new Map;
var __stPtrDragActive = false;
globalThis.__stSetPtrDrag = (on) => { __stPtrDragActive = on !== 0; };
function initEventDelegation(bridge, rootSelector = "body") {"""

gate_body_old = """    const listener = (event) => {
      let target = event.target;"""
gate_body_new = """    const listener = (event) => {
      if (delegatedEvent.domType === "pointermove" && !__stPtrDragActive)
        return;
      let target = event.target;"""

D6_SENTINEL = "__stSetPtrDrag"

if D6_SENTINEL in s:
    notes.append("patch-door: D6 already patched, nothing to do")
else:
    d6missing = []
    if s.count(gate_decl_old) != 1:
        d6missing.append("the eventHandlerModes/initEventDelegation head (found %d, want 1)" % s.count(gate_decl_old))
    if s.count(gate_body_old) != 1:
        d6missing.append("the delegation listener head (found %d, want 1)" % s.count(gate_body_old))
    if d6missing:
        errors.append("patch-door: D6 could not find " + " and ".join(d6missing) +
                      " verbatim; door version changed, update patch-door.sh")
    else:
        s = s.replace(gate_decl_old, gate_decl_new, 1)
        s = s.replace(gate_body_old, gate_body_new, 1)
        changed = True
        notes.append("patch-door: D6 pointermove delegation gated behind an active-drag flag")

# ---------------------------------------------------------------------------
# D7: a raw-bytes fetch door op (C4) for multipart uploads + binary responses
# ---------------------------------------------------------------------------
# zx.fetch reads the request body with readString (UTF-8) and returns the response via text(), so it
# corrupts binary both ways. fetchRawAsync reads the body as raw bytes and returns the response as raw
# bytes, reusing __zx_fetch_complete so the app's net layer keeps ONE completion path.

raw_method_old = """  _notifyFetchComplete(fetchId, statusCode, body, isError) {
    const handler = this.#fetchCompleteHandler;
    const encoded = textEncoder.encode(body);
    const ptr = this._alloc(encoded.length);
    writeBytes(ptr, encoded);
    invokeWasmExport(handler, fetchId, statusCode, ptr, encoded.length, isError ? 1 : 0);
  }"""

raw_method_new = raw_method_old + """
  fetchRawAsync(urlPtr, urlLen, ctypePtr, ctypeLen, csrfPtr, csrfLen, clientPtr, clientLen, bodyPtr, bodyLen, timeoutMs, fetchId) {
    const url = readString(urlPtr, urlLen);
    const ctype = ctypeLen > 0 ? readString(ctypePtr, ctypeLen) : "application/octet-stream";
    const csrf = csrfLen > 0 ? readString(csrfPtr, csrfLen) : "";
    const clientId = clientLen > 0 ? readString(clientPtr, clientLen) : "";
    // slice() copies the body out of the growable wasm buffer, so a memory.grow mid-fetch cannot
    // move the bytes the in-flight request is still reading.
    const body = getMemoryView().slice(bodyPtr, bodyPtr + bodyLen);
    const headers = { "Content-Type": ctype };
    if (csrf) headers["X-CSRF-Token"] = csrf;
    if (clientId) headers["X-ST-Client-Id"] = clientId;
    const controller = new AbortController();
    const timeout = timeoutMs > 0 ? setTimeout(() => controller.abort(), timeoutMs) : null;
    fetch(url, { method: "POST", headers, body, signal: controller.signal }).then(async (response) => {
      if (timeout) clearTimeout(timeout);
      const bytes = new Uint8Array(await response.arrayBuffer());
      this._notifyFetchRaw(fetchId, response.status, bytes, false);
    }).catch(() => {
      if (timeout) clearTimeout(timeout);
      this._notifyFetchRaw(fetchId, 0, new Uint8Array(0), true);
    });
  }
  _notifyFetchRaw(fetchId, statusCode, bytes, isError) {
    const handler = this.#fetchCompleteHandler;
    const ptr = this._alloc(bytes.length);
    writeBytes(ptr, bytes);
    invokeWasmExport(handler, fetchId, statusCode, ptr, bytes.length, isError ? 1 : 0);
  }"""

raw_import_old = """        _fetchAsync: (urlPtr, urlLen, methodPtr, methodLen, headersPtr, headersLen, bodyPtr, bodyLen, timeoutMs, fetchId) => {
          bridgeRef.current?.fetchAsync(urlPtr, urlLen, methodPtr, methodLen, headersPtr, headersLen, bodyPtr, bodyLen, timeoutMs, fetchId);
        },"""

raw_import_new = raw_import_old + """
        _fetchRawAsync: (urlPtr, urlLen, ctypePtr, ctypeLen, csrfPtr, csrfLen, clientPtr, clientLen, bodyPtr, bodyLen, timeoutMs, fetchId) => {
          bridgeRef.current?.fetchRawAsync(urlPtr, urlLen, ctypePtr, ctypeLen, csrfPtr, csrfLen, clientPtr, clientLen, bodyPtr, bodyLen, timeoutMs, fetchId);
        },"""

D7_SENTINEL = "fetchRawAsync"

if D7_SENTINEL in s:
    notes.append("patch-door: D7 already patched, nothing to do")
else:
    missing = []
    if s.count(raw_method_old) != 1:
        missing.append("the _notifyFetchComplete method (found %d, want 1)" % s.count(raw_method_old))
    if s.count(raw_import_old) != 2:
        missing.append("the _fetchAsync import registration (found %d, want 2)" % s.count(raw_import_old))
    if missing:
        errors.append("patch-door: D7 could not find " + " and ".join(missing) +
                      " verbatim; door version changed, update patch-door.sh")
    else:
        s = s.replace(raw_method_old, raw_method_new, 1)
        s = s.replace(raw_import_old, raw_import_new)
        changed = True
        notes.append("patch-door: D7 raw-bytes fetch door op added "
                     "(multipart uploads + binary responses ride __zx_fetch_complete)")

# ---------------------------------------------------------------------------
# D8: requestAnimationFrame door binding (ziex binds only setTimeout/setInterval)
# ---------------------------------------------------------------------------
# Mirrors _setTimeout: a bridge method schedules via rAF and delivers through the same #invoke path
# as the timers (CallbackType.Timeout, fire-once), and a browser import member forwards the Zig
# _requestAnimationFrame extern to it. Zig registers the callback as a .timeout, so dispatchCallback
# fires it once and deactivates, exactly as a rAF should.

raf_method_old = """  setInterval(callbackId, intervalMs) {
    const handle = setInterval(() => {
      this.#invoke(CallbackType.Interval, callbackId, null);
    }, intervalMs);
    this.#intervals.set(callbackId, handle);
  }
  clearInterval(callbackId) {"""

raf_method_new = """  setInterval(callbackId, intervalMs) {
    const handle = setInterval(() => {
      this.#invoke(CallbackType.Interval, callbackId, null);
    }, intervalMs);
    this.#intervals.set(callbackId, handle);
  }
  requestAnimationFrame(callbackId) {
    requestAnimationFrame(() => {
      this.#invoke(CallbackType.Timeout, callbackId, null);
    });
  }
  clearInterval(callbackId) {"""

raf_import_old = """        _clearInterval: (callbackId) => {
          bridgeRef.current?.clearInterval(callbackId);
        },
        _wsConnect: (wsId, urlPtr, urlLen, protocolsPtr, protocolsLen) => {"""

raf_import_new = """        _clearInterval: (callbackId) => {
          bridgeRef.current?.clearInterval(callbackId);
        },
        _requestAnimationFrame: (callbackId) => {
          bridgeRef.current?.requestAnimationFrame(callbackId);
        },
        _wsConnect: (wsId, urlPtr, urlLen, protocolsPtr, protocolsLen) => {"""

D8_SENTINEL = "requestAnimationFrame(callbackId) {"

if D8_SENTINEL in s:
    notes.append("patch-door: D8 already patched, nothing to do")
else:
    missing = []
    if s.count(raf_method_old) != 1:
        missing.append("the setInterval/clearInterval bridge methods (found %d, want 1)" % s.count(raf_method_old))
    if s.count(raf_import_old) != 1:
        missing.append("the browser _clearInterval/_wsConnect import members (found %d, want 1)" % s.count(raf_import_old))
    if missing:
        errors.append("patch-door: D8 could not find " + " and ".join(missing) +
                      " verbatim; door version changed, update patch-door.sh")
    else:
        s = s.replace(raf_method_old, raf_method_new, 1)
        s = s.replace(raf_import_old, raf_import_new, 1)
        changed = True
        notes.append("patch-door: D8 requestAnimationFrame bound "
                     "(bridge method + browser import member)")

# ---------------------------------------------------------------------------
# D9: animationend delegation (ziex delegates 19 events, not animationend)
# ---------------------------------------------------------------------------
# The reveal settle keys on the .mes mes-rise animationend. animationend bubbles, so body delegation
# reaches it with no capture (unlike scroll). eventTypeId 23 follows the pointer ids (D5, 19-22) and
# matches Client.zig's EventType (source patch 23). This block runs after D5 has appended the pointer
# entries, so it anchors on the pointercancel=22 tail, not scroll=18.

anim_old = """  { domType: "pointercancel", eventTypeId: 22 }
];"""

anim_new = """  { domType: "pointercancel", eventTypeId: 22 },
  { domType: "animationend", eventTypeId: 23 }
];"""

D9_SENTINEL = 'domType: "animationend"'

if D9_SENTINEL in s:
    notes.append("patch-door: D9 already patched, nothing to do")
elif s.count(anim_old) != 1:
    errors.append("patch-door: D9 could not find the DELEGATED_EVENTS tail (pointercancel=22) verbatim "
                  "(found %d, want 1); door version changed, update patch-door.sh" % s.count(anim_old))
else:
    s = s.replace(anim_old, anim_new, 1)
    changed = True
    notes.append("patch-door: D9 animationend delegated (eventTypeId 23), "
                 "the reveal settle's mes-rise handler now reaches Zig")

# ---------------------------------------------------------------------------
# D10: SSE streaming door op (getReader pump). zx.fetch is whole-body only, so the reader loop is a
# genuine browser IO that must live in the door. Zig (stream_drive.zig) drives __st_stream_open via
# js.global.call, owns the flush batching (rAF), cancel, lifecycle and csrf; the door only pumps.
# ---------------------------------------------------------------------------
# The pump reads response.body.getReader() and hands each raw chunk to the wasm export __st_stream_chunk
# (Zig batches on rAF); __st_stream_closed fires exactly once on natural end / error / cancel, the single
# seal point. Cancel aborts the reader so the awaiting read() rejects and the loop ends.

stream_anchor = "  const bridge = new ZxBridge(instance.exports);"
stream_block = stream_anchor + """
  (function () {
    const exp = instance.exports;
    const streams = new Map();
    globalThis.__st_stream_open = function (streamId, url, body, csrf) {
      const controller = new AbortController();
      const rec = { controller: controller, cancelled: false, reader: null };
      streams.set(streamId, rec);
      const method = body ? "POST" : "GET";
      const headers = { Accept: "text/event-stream" };
      if (body) headers["Content-Type"] = "application/json";
      if (csrf) headers["X-CSRF-Token"] = csrf;
      fetch(url, { method: method, headers: headers, body: body || undefined, signal: controller.signal }).then(async (response) => {
        if (!response.ok || !response.body) { streams.delete(streamId); exp.__st_stream_closed(response.status); return; }
        const reader = response.body.getReader();
        rec.reader = reader;
        for (;;) {
          let step;
          try { step = await reader.read(); } catch (e) { break; }
          if (step.done || rec.cancelled) break;
          const bytes = step.value;
          const ptr = exp.__zx_alloc(bytes.length);
          writeBytes(ptr, bytes);
          exp.__st_stream_chunk(ptr, bytes.length);
        }
        streams.delete(streamId);
        exp.__st_stream_closed(response.status);
      }).catch(() => { streams.delete(streamId); exp.__st_stream_closed(0); });
    };
    globalThis.__st_stream_cancel = function (streamId) {
      const rec = streams.get(streamId);
      if (!rec) return;
      rec.cancelled = true;
      // abort() ends the awaiting read(); reader.cancel() returns a promise that rejects with the same
      // AbortError, so its rejection is swallowed rather than surfacing as an unhandled rejection.
      try { rec.controller.abort(); } catch (e) {}
      if (rec.reader) { try { rec.reader.cancel().catch(() => {}); } catch (e) {} }
    };
  })();"""

D10_SENTINEL = "globalThis.__st_stream_open"

if D10_SENTINEL in s:
    notes.append("patch-door: D10 already patched, nothing to do")
elif s.count(stream_anchor) != 1:
    errors.append("patch-door: D10 could not find the ZxBridge construction anchor verbatim "
                  "(found %d, want 1); door version changed, update patch-door.sh" % s.count(stream_anchor))
else:
    s = s.replace(stream_anchor, stream_block, 1)
    changed = True
    notes.append("patch-door: D10 SSE streaming getReader pump added "
                 "(__st_stream_open/__st_stream_cancel, chunks -> __st_stream_chunk, seal -> __st_stream_closed)")

# ---------------------------------------------------------------------------
# D11: ambient pointer tracking (the edge-tab reveal needs a pointer position, not a drag)
# ---------------------------------------------------------------------------
# D6 gates the DELEGATED pointermove behind an active drag because the delegation walk stores one jsz
# slot per dispatch and never reclaims it (measured: 600 ambient moves = +2400 live slots). That gate
# stays exactly as it is. Ambient tracking rides its OWN window listener instead and crosses FOUR
# NUMBERS per frame (x, y, innerWidth, innerHeight) straight into __st_pointer_move, so it allocates
# no handle, touches no registry, and cannot leak a slot however long the pointer moves.
# Coalesced on rAF: one wasm call per frame at most, whatever the pointer's report rate.
# Policy stays in Zig (pointer_track.zig owns the flank geometry and the reveal state); the door only
# reports where the pointer is. A build with no __st_pointer_move export skips the whole block.

ptr_anchor = "  const bridge = new ZxBridge(instance.exports);"
ptr_block = ptr_anchor + """
  (function () {
    const exp = instance.exports;
    if (!exp.__st_pointer_move) return;
    let px = -1, py = -1, queued = false;
    function flush() {
      queued = false;
      exp.__st_pointer_move(px, py, window.innerWidth, window.innerHeight);
    }
    function mark(x, y) {
      px = x; py = y;
      if (queued) return;
      queued = true;
      requestAnimationFrame(flush);
    }
    window.addEventListener("pointermove", (e) => mark(e.clientX, e.clientY), { passive: true });
    // Pointer left the window (no relatedTarget) or the window lost focus: report it nowhere, so a
    // revealed tab fades instead of latching on at the last coordinate it saw.
    window.addEventListener("pointerout", (e) => { if (!e.relatedTarget) mark(-1, -1); }, { passive: true });
    window.addEventListener("blur", () => mark(-1, -1), { passive: true });
  })();"""

D11_SENTINEL = "__st_pointer_move"

if D11_SENTINEL in s:
    notes.append("patch-door: D11 already patched, nothing to do")
elif s.count(ptr_anchor) != 1:
    errors.append("patch-door: D11 could not find the ZxBridge construction anchor verbatim "
                  "(found %d, want 1); door version changed, update patch-door.sh" % s.count(ptr_anchor))
else:
    s = s.replace(ptr_anchor, ptr_block, 1)
    changed = True
    notes.append("patch-door: D11 ambient pointer tracking added "
                 "(rAF-coalesced window pointermove -> __st_pointer_move, no delegation, no handles)")

# D12: a document-level printable-key report (the command palette's Ctrl-K has to work with nothing
# focused)
# ---------------------------------------------------------------------------
# ziex delegates every event at <body> and walks UP from event.target (initEventDelegation), so a
# keydown whose target is <body> - which is what document.activeElement is after a click on any
# non-focusable text - reaches no handler at all. Measured, not assumed: the palette's own probe
# found Ctrl-K dead from the base surface and live from the composer, which is exactly that walk.
# A global accelerator cannot depend on where focus happens to be, so the door reports the key.
#
# It crosses TWO NUMBERS (the key's code unit and a modifier bitmask) and no handle, the same
# discipline D11 uses, so it cannot leak a jsz slot however long the user types. Only single-
# character keys are reported: Escape, Tab and the arrows stay entirely on the delegated path, so
# this can never reach past an in-region handler that already owns one of them. Policy stays in Zig
# (palette_state.__st_page_key decides); the door only asks. Bubble phase on window, so an in-region
# handler that consumed the key with stopPropagation is never second-guessed here.
# A build with no __st_page_key export skips the whole block.

key_block = ptr_anchor + """
  (function () {
    const exp = instance.exports;
    if (!exp.__st_page_key) return;
    // Bit order is shared with palette_state.zig; the two must be changed together.
    window.addEventListener("keydown", (e) => {
      const k = e.key || "";
      if (k.length !== 1) return;
      const mods = (e.ctrlKey ? 1 : 0) | (e.metaKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.shiftKey ? 8 : 0);
      if (exp.__st_page_key(k.charCodeAt(0), mods) === 1) e.preventDefault();
    });
  })();"""

D12_SENTINEL = "__st_page_key"

if D12_SENTINEL in s:
    notes.append("patch-door: D12 already patched, nothing to do")
elif s.count(ptr_anchor) != 1:
    errors.append("patch-door: D12 could not find the ZxBridge construction anchor verbatim "
                  "(found %d, want 1); door version changed, update patch-door.sh" % s.count(ptr_anchor))
else:
    s = s.replace(ptr_anchor, key_block, 1)
    changed = True
    notes.append("patch-door: D12 document-level printable-key report added "
                 "(window keydown -> __st_page_key, two numbers, no handles)")

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

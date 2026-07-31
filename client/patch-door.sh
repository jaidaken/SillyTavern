#!/usr/bin/env bash
# Apply this application's own door edits to the exported ziex door, after the shared ones.
#
# The shared ziex-patched repository owns every generic ziex runtime fix (D1 through D6, D8, D9) and
# runs first, against the same file. What stays here is SillyTavern feature work that no other
# consumer of ziex wants:
#
#   D7   raw-bytes fetch door op, with this app's own multipart and CSRF headers
#   D10  SSE streaming getReader pump
#   D11  ambient pointer tracking for the edge-tab reveal
#   D12  document-level printable-key report for the command palette
#
# The D numbers are the original identifiers, named by source comments and by patches/README, so
# they are unchanged even though the local set now starts at 7.
set -euo pipefail

cd "$(dirname "$0")"

DOOR="${1:-dist/vendor/ziex/wasm/index.js}"
[ -f "$DOOR" ] || { echo "patch-door: $DOOR not found (run export first)" >&2; exit 1; }

ZIEX_PATCHED="${ZIEX_PATCHED:-$(cd ../.. && pwd)/ziex-patched}"
[ -x "$ZIEX_PATCHED/patch-door.sh" ] || {
    echo "patch-door: no shared ziex-patched at $ZIEX_PATCHED" >&2
    echo "            clone it there, or point ZIEX_PATCHED at it" >&2
    exit 1
}

"$ZIEX_PATCHED/patch-door.sh" "$DOOR"

python3 - "$DOOR" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
changed = False
# Nothing prints until after the write, so an aborted run cannot claim a patch it did not write.
# Errors accumulate so a door bump names every stale expectation in one run, not one per rebuild.
notes, errors = [], []

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
# D10: SSE streaming door op (getReader pump). zx.fetch is whole-body only, so the reader loop is a
# genuine browser IO that must live in the door. Zig (stream_drive.zig) drives __st_stream_open via
# js.global.call, owns the flush batching (rAF), cancel, lifecycle and csrf; the door only pumps.
# ---------------------------------------------------------------------------
# The pump reads response.body.getReader() and hands each raw chunk to the wasm export __st_stream_chunk
# (Zig batches on rAF); __st_stream_closed fires exactly once on natural end / error / cancel, the single
# seal point. Cancel aborts the reader so the awaiting read() rejects and the loop ends.
#
# Both callbacks carry the streamId the map is keyed by (T4): without it two concurrent door streams
# would interleave into one Zig session with nothing able to tell their chunks apart.

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
        if (!response.ok || !response.body) { streams.delete(streamId); exp.__st_stream_closed(streamId, response.status); return; }
        const reader = response.body.getReader();
        rec.reader = reader;
        for (;;) {
          let step;
          try { step = await reader.read(); } catch (e) { break; }
          if (step.done || rec.cancelled) break;
          const bytes = step.value;
          const ptr = exp.__zx_alloc(bytes.length);
          writeBytes(ptr, bytes);
          exp.__st_stream_chunk(streamId, ptr, bytes.length);
        }
        streams.delete(streamId);
        exp.__st_stream_closed(streamId, response.status);
      }).catch(() => { streams.delete(streamId); exp.__st_stream_closed(streamId, 0); });
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
// Custom glue for SillyTavern: message sanitization + SSE streaming + the browser-forced
// adapters (multipart upload, blob download). Data/boot/CRUD live in Zig (char_api.zig).
(function () {
    'use strict';

    // ---- DOM debug channel -------------------------------------------------------------------
    // The door traces its vnode patches on [zx:dom] too, so app writes into framework-owned DOM
    // interleave with the framework's own ops under one console filter. That is the diagnostic.
    // DO NOT MOVE BELOW init(): the door reads globalThis.__zx_debug, and init()'s dynamic import()
    // is the only thing that loads it, so setting the flag here (module scope, before init runs at
    // DOMContentLoaded) is what gets it set before the door boots and before wasm instantiates.
    const ZX_DEBUG_KEY = 'zx:debug';
    const ZX_DOM_PREFIX = '[zx:dom]';

    function zxDebugStore(on) {
        try {
            if (on) localStorage.setItem(ZX_DEBUG_KEY, '1');
            else localStorage.removeItem(ZX_DEBUG_KEY);
        } catch (_) { /* private mode: the flag still holds for this session, it just will not survive */ }
    }

    function zxDebugResolve() {
        let param = null;
        try { param = new URLSearchParams(window.location.search).get('zxdebug'); } catch (_) { /* opaque location */ }
        if (param === '1' || param === '0') {
            const on = param === '1';
            // The operator flips this on the LIVE deployed site, where he cannot rebuild to set a
            // flag. The param therefore writes through to storage: the next plain load keeps it on,
            // and ?zxdebug=0 is the way back off.
            zxDebugStore(on);
            return on;
        }
        try { return localStorage.getItem(ZX_DEBUG_KEY) === '1'; } catch (_) { return false; }
    }

    globalThis.__zx_debug = zxDebugResolve();

    // Mid-session switch: no reload, no redeploy. Reports the state it just set.
    window.__st_debug = function (on) {
        const next = !!on;
        globalThis.__zx_debug = next;
        zxDebugStore(next);
        // eslint-disable-next-line no-console -- the debug channel is a deliberate second console sink
        console.info(ZX_DOM_PREFIX, 'debug', next ? 'ON' : 'OFF', '- filter the console on ' + ZX_DOM_PREFIX);
        return next;
    };

    // The gate here is the contract (a trace never escapes with the flag off, whoever calls it).
    // The gate at each call site is the cost guard (it stops the argument strings being built).
    // Both are deliberate; neither is redundant with the other.
    function zxDomTrace(op, target, detail) {
        if (!globalThis.__zx_debug) return;
        const line = [ZX_DOM_PREFIX, op, target];
        if (detail !== undefined) line.push(detail);
        // eslint-disable-next-line no-console -- the debug channel is a deliberate second console sink
        console.debug.apply(console, line);
    }

    // Name an element the way the door names a vnode, so app writes and framework patches read the
    // same in one filtered console.
    function zxDomName(el) {
        if (!el) return '<null>';
        return (el.tagName ? el.tagName.toLowerCase() : '?') + (el.id ? '#' + el.id : '');
    }

    if (globalThis.__zx_debug) {
        // eslint-disable-next-line no-console -- the debug channel is a deliberate second console sink
        console.info(ZX_DOM_PREFIX, 'debug ON - DOM tracing live. Filter the console on '
            + ZX_DOM_PREFIX + '; window.__st_debug(false) turns it off.');
    }

    const PURIFY_URL = '/client/glue/vendor/purify.es.mjs';
    const HLJS_URL = '/client/glue/vendor/hljs.mjs';

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let wasm = null;
    let DOMPurify = null;
    let hljs = null;

    // Logger, mirrors src/log.js: toggle via localStorage st_log = 'cat:level,cat:level' (same
    // spec as server ST_LOG), read once at load, reload to apply. Default info.
    const LOG_LEVELS = { TRACE: -1, DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3, SILENT: 100 };
    const LEVEL_NAMES = ['trace', 'debug', 'info', 'warn', 'error'];
    const CONSOLE_METHOD = { trace: 'debug', debug: 'debug', info: 'info', warn: 'warn', error: 'error' };
    const DEFAULT_LOG_LEVEL = LOG_LEVELS.INFO;
    const LOG_CATEGORIES = ['boot', 'chars', 'personas', 'panels', 'stream', 'net', 'wasm', 'global'];
    const silentLog = function () {};

    function normalizeLogLevel(value) {
        if (typeof value !== 'string') return undefined;
        const upper = value.trim().toUpperCase();
        return Object.prototype.hasOwnProperty.call(LOG_LEVELS, upper) ? LOG_LEVELS[upper] : undefined;
    }

    function logSpec() {
        const map = {};
        let raw;
        try { raw = localStorage.getItem('st_log'); } catch (_) { return map; }
        if (!raw) return map;
        raw.split(',').forEach(function (part) {
            const bits = part.split(':');
            const cat = bits[0] && bits[0].trim();
            const level = normalizeLogLevel(bits[1]);
            if (cat && level !== undefined) map[cat] = level;
        });
        return map;
    }

    const logOverrides = logSpec();
    const logNodes = {};

    function buildLogNode(category) {
        const threshold = Object.prototype.hasOwnProperty.call(logOverrides, category)
            ? logOverrides[category]
            : DEFAULT_LOG_LEVEL;
        const node = {};
        LEVEL_NAMES.forEach(function (name) {
            node[name] = LOG_LEVELS[name.toUpperCase()] < threshold
                ? silentLog
                // eslint-disable-next-line no-console -- the logger is the one legitimate console binding site
                : console[CONSOLE_METHOD[name]].bind(console, '[st:' + category + ']');
        });
        logNodes[category] = node;
        return node;
    }

    const log = {};
    LOG_CATEGORIES.forEach(function (c) { log[c] = buildLogNode(c); });

    // Window-level listeners are irreducible; they only marshal the resolved prefix + stack to Zig,
    // which logs at global:err via telemetry.zig. Errors before wasm instantiates are dropped.
    function forwardUncaught(head, detail) {
        if (!wasm || !wasm.__st_on_uncaught) return;
        const h = writeBytes(head);
        const d = writeBytes(detail || '');
        try { wasm.__st_on_uncaught(h.ptr, h.len, d.ptr, d.len); } finally { freeRaw(h); freeRaw(d); }
    }
    window.addEventListener('error', function (e) {
        if (e.error) forwardUncaught('uncaught error:', e.error.stack || String(e.error));
        else forwardUncaught('uncaught error:', e.message + ' at ' + (e.filename || '?') + ':' + e.lineno + ':' + e.colno);
    });
    window.addEventListener('unhandledrejection', function (e) {
        const r = e.reason;
        forwardUncaught('unhandled rejection:', r && r.stack ? r.stack : String(r));
    });

    if (window.trustedTypes && window.trustedTypes.createPolicy) {
        try { window.trustedTypes.createPolicy('default', { createHTML: function (s) { return s; } }); } catch (err) { log.boot.debug('trustedTypes default policy not installed:', err); }
    }

    function readString(ptr, len) {
        if (len === 0) return '';
        return decoder.decode(new Uint8Array(wasm.memory.buffer, ptr, len));
    }

    function writeRaw(bytes) {
        if (bytes.length === 0) return { ptr: 0, len: 0 };
        const ptr = wasm.__zx_alloc(bytes.length);
        if (ptr === 0) throw new Error('__zx_alloc returned null');
        new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
        return { ptr: ptr, len: bytes.length };
    }

    function writeBytes(text) { return writeRaw(encoder.encode(text)); }
    function writeString(text) { const buf = writeBytes(text); return (BigInt(buf.ptr) << 32n) | BigInt(buf.len); }
    function freeRaw(buf) { if (buf.len !== 0) wasm.__zx_free(buf.ptr, buf.len); }

    const MESSAGE_CONFIG = {
        RETURN_DOM: false, RETURN_DOM_FRAGMENT: false, RETURN_TRUSTED_TYPE: false, MESSAGE_SANITIZE: true,
        FORBID_TAGS: ['style', 'form', 'input', 'button', 'textarea', 'select', 'option'],
        FORBID_ATTR: ['style'], ALLOW_DATA_ATTR: false, SANITIZE_NAMED_PROPS: true,
    };

    const URL_ATTRS = new Set(['href', 'src', 'action']);

    function isSafeUri(value) {
        const v = String(value).replace(/[\u0000-\u0020]/g, '').toLowerCase();
        if (v.startsWith('javascript:')) return false;
        if (v.startsWith('data:')) {
            const match = /^data:([^;,]*)/.exec(v);
            const mediatype = match ? match[1] : '';
            if (!mediatype.startsWith('image/')) return false;
            if (mediatype === 'image/svg+xml') return false;
        }
        return true;
    }

    function installHooks() {
        DOMPurify.addHook('afterSanitizeAttributes', function (node) {
            if (!('target' in node)) return;
            const href = node.getAttribute && node.getAttribute('href');
            if (href && href.charAt(0) === '#') return;
            node.setAttribute('target', '_blank');
            node.setAttribute('rel', 'noopener noreferrer');
        });

        DOMPurify.addHook('uponSanitizeAttribute', function (node, data) {
            if (URL_ATTRS.has(data.attrName) && !isSafeUri(data.attrValue)) {
                data.keepAttr = false;
            }
        });

        DOMPurify.addHook('uponSanitizeAttribute', function (node, data, config) {
            if (!config.MESSAGE_SANITIZE) return;
            if (data.attrName !== 'class' || !data.attrValue) return;
            data.attrValue = data.attrValue.split(/\s+/).filter(Boolean).map(function (v) {
                if (v.startsWith('language-')) return v;
                return 'custom-' + v;
            }).join(' ');
        });
    }

    const HIGHLIGHT_CACHE_MAX = 128;
    const highlightCache = new Map();
    function highlightKey(lang, source) { return (lang || '') + '\u0000' + source; }
    function cacheHighlight(key, value) {
        if (highlightCache.size >= HIGHLIGHT_CACHE_MAX) highlightCache.delete(highlightCache.keys().next().value);
        highlightCache.set(key, value);
    }

    // Zig (stream_drive) owns the streaming flag now: __st_stream_rendering() is true only while a flush
    // feed is in progress, so the growing last code block is left un-highlighted until the stream seals.
    function streamRendering() { return !!(wasm && wasm.__st_stream_rendering && wasm.__st_stream_rendering()); }

    function highlightElement(el, skipGrow) {
        const tag = Array.from(el.classList).find(function (c) { return c.startsWith('language-'); });
        const lang = tag ? tag.slice(9) : null;
        const source = el.textContent;
        const key = highlightKey(lang, source);
        el.classList.add('hljs');

        const hit = highlightCache.get(key);
        if (hit !== undefined) {
            // allow-raw-html-sink: pre-existing write, unchanged. hljs output over el.textContent; env.sanitize already DOMPurified the source markup.
            el.innerHTML = hit;
            // live=false is the highlightBlocks path (a detached <template>, cannot drift the page);
            // live=true is highlightSealedBlocks writing into the framework's own tree.
            if (globalThis.__zx_debug) {
                zxDomTrace('app.innerHTML', zxDomName(el), 'highlight cache-hit lang=' + (lang || 'auto')
                    + ' live=' + document.contains(el) + ' bytes=' + hit.length);
            }
            return;
        }

        if (skipGrow) return;

        const out = (lang && hljs.getLanguage(lang))
            ? hljs.highlight(source, { language: lang, ignoreIllegals: true })
            : hljs.highlightAuto(source);
        cacheHighlight(key, out.value);
        // allow-raw-html-sink: pre-existing write, unchanged. See the cache-hit branch above.
        el.innerHTML = out.value;
        if (globalThis.__zx_debug) {
            zxDomTrace('app.innerHTML', zxDomName(el), 'highlight computed lang=' + (lang || 'auto')
                + ' live=' + document.contains(el) + ' bytes=' + out.value.length);
        }
    }

    function highlightBlocks(html) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html;
        const blocks = tpl.content.querySelectorAll('pre > code');

        const growing = streamRendering() ? blocks.length - 1 : -1;

        blocks.forEach(function (el, i) {
            highlightElement(el, i === growing);
        });
        return tpl.innerHTML;
    }

    function highlightSealedBlocks(root) {
        if (!root || !hljs) return;
        const blocks = root.querySelectorAll('pre > code');
        if (globalThis.__zx_debug) {
            zxDomTrace('app.highlightSealed', zxDomName(root), blocks.length + ' block(s) live=' + document.contains(root));
        }
        blocks.forEach(function (el) {
            highlightElement(el, false);
        });
    }

    const env = {
        // Console sink only: Zig owns the category thresholds (log.zig), so a message that reaches
        // here already passed its filter. Print it, never re-filter it.
        st_log: function (level, scopePtr, scopeLen, msgPtr, msgLen) {
            const scope = readString(scopePtr, scopeLen) || 'wasm';
            const name = level === 0 ? 'error' : level === 1 ? 'warn' : level === 2 ? 'info' : 'debug';
            // eslint-disable-next-line no-console -- the logger is the one legitimate console binding site
            console[CONSOLE_METHOD[name]]('[st:' + scope + ']', readString(msgPtr, msgLen));
        },
        sanitize: function (ptr, len) {
            let out;
            try {
                const clean = DOMPurify.sanitize(readString(ptr, len), MESSAGE_CONFIG);
                try {
                    out = highlightBlocks(clean);
                } catch (err) {
                    log.stream.error('highlight failed:', err);
                    out = clean;
                }
            } catch (err) {
                log.stream.error('sanitize failed:', err);
                out = '';
            }
            try {
                return writeString(out);
            } catch (err) {
                log.wasm.error('sanitize writeback failed:', err);
                return 0n;
            }
        },
    };

    // Seal glue (Zig stream_drive calls this at stream close): highlight the sealed message's code
    // blocks. Held hljs, so JS owns the how; Zig owns the when and fills the dev #probe-metrics itself.
    window.__st_stream_sealed = function () {
        const chat = document.getElementById('chat');
        const mes = chat ? chat.querySelectorAll('.mes') : null;
        if (mes && mes.length) highlightSealedBlocks(mes[mes.length - 1]);
    };

    /* w3-grp: start a group member rotation from a JSON definition (gate driver + roster UI). */
    window.__st_group_send = function (json) {
        if (!wasm.__st_group_send) return 0;
        const buf = writeBytes(json);
        try {
            return wasm.__st_group_send(buf.ptr, buf.len);
        } finally {
            freeRaw(buf);
        }
    };

    // P1-A: push a notification by level name (gate driver + console debugging). Zig owns the store,
    // the toast expiry, and every real source; this only carries a string across.
    const NOTIFY_LEVELS = { info: 0, success: 1, warning: 2, err: 3 };
    window.__st_notify = function (level, text, ttlMs) {
        if (!wasm.__st_notify) return;
        const buf = writeBytes(String(text));
        try {
            wasm.__st_notify(NOTIFY_LEVELS[level] || 0, buf.ptr, buf.len, ttlMs || 0);
        } finally {
            freeRaw(buf);
        }
    };

    // P1-E: the status poll's arm/disarm. A fallback the live channel stands down, so both
    // directions are product surface; the gate drives the same two calls.
    window.__st_conn_poll = function (on) {
        if (on) { if (wasm.__st_conn_start_poll) wasm.__st_conn_start_poll(); }
        else if (wasm.__st_conn_stop_poll) { wasm.__st_conn_stop_poll(); }
        return wasm.__st_conn_poll_armed ? wasm.__st_conn_poll_armed() : -1;
    };

    // __st_read_file (C4): read a file input to bytes for Zig via __st_file_ready. Non-async so
    // js.global.call(void) succeeds; an empty read (cancelled picker) still calls back to settle Zig.
    window.__st_read_file = function (inputId, tag) {
        function deliver(bytes, name, mime) {
            const b = bytes && bytes.length ? writeRaw(bytes) : { ptr: 0, len: 0 };
            const n = name ? writeBytes(name) : { ptr: 0, len: 0 };
            const m = mime ? writeBytes(mime) : { ptr: 0, len: 0 };
            wasm.__st_file_ready(tag, b.ptr, b.len, n.ptr, n.len, m.ptr, m.len);
        }
        const input = document.getElementById(inputId);
        const file = input && input.files && input.files[0];
        if (!file) { deliver(null, '', ''); return; }
        file.arrayBuffer().then(function (buf) {
            deliver(new Uint8Array(buf), file.name || 'file', file.type || '');
            input.value = '';
        }).catch(function (err) {
            log.net.error('file read failed:', err);
            deliver(null, '', '');
            input.value = '';
        });
    };

    // __st_download (C4): write a fetched blob and click it. Zig passes the bytes by pointer into wasm
    // memory; slice() copies them into the Blob synchronously, before Zig frees the response.
    window.__st_download = function (name, ptr, len, mime) {
        const bytes = new Uint8Array(wasm.memory.buffer, ptr, len).slice();
        const blob = new Blob([bytes], { type: mime || 'application/octet-stream' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
        URL.revokeObjectURL(url);
    };

    // Raw listener stays (framework delegation drops the dead-vnode clicks this is here to catch); it
    // only marshals {tag, id, class, label} to Zig, which formats the selector and logs at ui:debug.
    document.addEventListener('click', function (e) {
        if (!wasm || !wasm.__st_on_click_telemetry) return;
        const ctl = e.target.closest('button, [role=button], a, select, input, textarea, label');
        if (!ctl) return;
        const cls = (ctl.className && typeof ctl.className === 'string') ? ctl.className : '';
        const label = ctl.getAttribute('aria-label') || ctl.textContent.trim().slice(0, 30) || '';
        const t = writeBytes(ctl.tagName);
        const i = writeBytes(ctl.id || '');
        const c = writeBytes(cls);
        const l = writeBytes(label);
        try { wasm.__st_on_click_telemetry(t.ptr, t.len, i.ptr, i.len, c.ptr, c.len, l.ptr, l.len); }
        finally { freeRaw(t); freeRaw(i); freeRaw(c); freeRaw(l); }
    }, false);

    // The reverse-lazy reader now lives entirely in Zig (reader.zig): the scroll watcher, the older-
    // page prefetch (fetch via net.zig, csrf + 403 handled there), the 409 re-sync, and the element-
    // anchored prepend correction. Nothing reader-side is left in the glue.

    // Initialize: load deps, then init wasm
    async function init() {
        log.boot.info('init start');
        try {
            DOMPurify = (await import(PURIFY_URL)).default;
            hljs = (await import(HLJS_URL)).default;
            installHooks();
            log.boot.debug('dependencies loaded');

            var ZIEX_DOOR = '/client/vendor/ziex/wasm/index.js';

            const door = await import(ZIEX_DOOR);
            const started = await door.init({ importObject: { env: env } });

            // The door's own instance is authoritative.
            if (started && started.source && started.source.instance) wasm = started.source.instance.exports;
            if (!wasm || typeof wasm.__zx_alloc !== 'function') {
                throw new Error('door.init exposed no wasm exports: __zx_alloc unreachable');
            }

            log.boot.debug('wasm loaded, exports:', Object.keys(wasm).slice(0, 20));

            // The hydrate/reveal stagger now lives in Zig (reveal.zig, started from bootInit; the
            // mes-rise settle is a delegated onanimationend on #chat via patches 21 + door D6).

            // Boot: Zig owns the data orchestration from here (char_api.boot via bootInit):
            // ?demo fixtures, characters + personas, auto-open, unreachable-backend fallback.
            if (wasm.__st_boot_init) {
                log.boot.debug('boot_init start');
                wasm.__st_boot_init();
                log.boot.debug('boot_init done');
            }

            // Dev-mode streaming (verify.sh ?stream=URL&hold=MS harness) is Zig-driven now:
            // stream_drive.__st_dev_stream_init reads the params, creates #probe-metrics, and drives the
            // streams through the same door pump a real send uses. No-op without ?stream.
            if (wasm.__st_dev_stream_init) wasm.__st_dev_stream_init();

            log.boot.info('init complete');
        } catch (err) {
            log.boot.error('init failed:', err);
        }
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
})();

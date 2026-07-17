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

    function logFor(category) {
        return logNodes[category] || buildLogNode(category);
    }

    // Global capture: uncaught errors and unhandled rejections carry their stack via the Error object.
    window.addEventListener('error', function (e) {
        if (e.error) log.global.error('uncaught error:', e.error);
        else log.global.error('uncaught error:', e.message, 'at', (e.filename || '?') + ':' + e.lineno + ':' + e.colno);
    });
    window.addEventListener('unhandledrejection', function (e) {
        log.global.error('unhandled rejection:', e.reason);
    });

    // Every backend fetch logs start and status at net:debug; failures stay with the call sites.
    function loggedFetch(url, opts) {
        log.net.debug('fetch', url);
        return fetch(url, opts).then(function (res) {
            log.net.debug(url, '->', res.status);
            return res;
        });
    }

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

    let streamRender = false;

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

        const growing = streamRender ? blocks.length - 1 : -1;

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
        sse_start: function (ptr, len) {
            startStream(readString(ptr, len), 'Seraphina').catch(function (err) {
                log.stream.error('stream failed:', err);
            });
        },
    };

    const stats = { chunks: 0, tokens: 0, flushes: 0, sanitizes: 0, mdBytes: 0 };

    let streamActive = false;
    let devMode = false;
    let currentReader = null;

    function setSendStatus(text) {
        const el = document.getElementById('send-status');
        if (el) el.textContent = text;
        if (globalThis.__zx_debug) {
            zxDomTrace('app.textContent', el ? zxDomName(el) : 'span#send-status <absent>', JSON.stringify(text));
        }
    }

    async function startStream(url, name, avatar, opts) {
        if (streamActive) throw new Error('stream already running');
        streamActive = true;
        // A reply follows the bottom only if you were already there; scrolled up, it stays put and the
        // chip appears. Your own send re-pins first (the composer calls scroll_bottom on send).
        streamPinned = readerNearBottom();

        let pending = [];
        let pendingLen = 0;
        let raf = 0;
        let timer = 0;
        let ended = false;
        let begun = false;
        let reader = null;

        function cancelScheduled() {
            if (raf) cancelAnimationFrame(raf);
            if (timer) clearTimeout(timer);
            raf = 0;
            timer = 0;
        }

        function flush() {
            cancelScheduled();
            if (ended || pendingLen === 0) return;
            const merged = new Uint8Array(pendingLen);
            let at = 0;
            for (const chunk of pending) {
                merged.set(chunk, at);
                at += chunk.length;
            }

            try {
                const buf = writeRaw(merged);
                pending = [];
                pendingLen = 0;
                stats.flushes += 1;

                streamRender = true;
                try {
                    wasm.__st_stream_append(buf.ptr, buf.len);
                } finally {
                    streamRender = false;
                }
                readerStreamTick();

                if (wasm.__st_stream_done && wasm.__st_stream_done()) {
                    ended = true;
                    if (reader) reader.cancel().catch(function (err) { log.stream.debug('reader cancel failed:', err); });
                }
            } catch (err) {
                log.stream.error('stream flush failed:', err);
                ended = true;
                if (reader) reader.cancel().catch(function (err) { log.stream.debug('reader cancel failed:', err); });
            }
        }

        function schedule() {
            if (raf || timer) return;
            raf = requestAnimationFrame(flush);
            timer = setTimeout(flush, 16);
        }

        try {
            const n = writeBytes(name);
            const av = writeBytes(avatar || '');
            if (wasm.__st_stream_begin(n.ptr, n.len, av.ptr, av.len) !== 0) {
                freeRaw(av);
                throw new Error('stream begin refused');
            }
            begun = true;

            let init;
            if (opts && opts.method === 'POST') {
                await ensureCsrfToken();
                init = { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json', Accept: 'text/event-stream' }), body: opts.body };
            } else {
                init = { headers: { Accept: 'text/event-stream' } };
            }
            const response = await loggedFetch(url, init);
            // A spun-down .43 behind Pocket-ID answers 502/504 at the edge before ST is reached.
            if (response.status === 502 || response.status === 504) setSendStatus('Backend asleep - unlock at silly');
            if (!response.ok || !response.body) throw new Error('stream failed: ' + response.status);

            reader = response.body.getReader();
            currentReader = reader;
            for (;;) {
                const step = await reader.read();
                if (step.done) break;
                stats.chunks += 1;
                pending.push(step.value);
                pendingLen += step.value.length;
                schedule();
            }
            flush();
        } finally {
            cancelScheduled();
            ended = true;
            streamActive = false;
            currentReader = null;
            if (begun) {
                wasm.__st_stream_end();
                if (streamPinned) window.__st_reader_scroll_bottom();
                const chat = document.getElementById('chat');
                const mes = chat ? chat.querySelectorAll('.mes') : null;
                if (mes && mes.length) highlightSealedBlocks(mes[mes.length - 1]);
                if (devMode) {
                    stats.tokens = wasm.__st_stream_tokens();
                    window.__stStats = stats;
                    const el = document.getElementById('probe-metrics');
                    const json = JSON.stringify(stats);
                    if (el) el.textContent = json;
                    if (globalThis.__zx_debug) {
                        zxDomTrace('app.textContent', el ? zxDomName(el) : 'pre#probe-metrics <absent>', json);
                    }
                }
            }
        }
    }

    // Zig (char_api.sendMessage) builds the request; the SSE pump stays in JS (ZX16). POST + csrf,
    // driving the same __st_stream_* machinery the display half uses.
    window.__st_send_stream = function (url, name, avatar, body) {
        startStream(url, name, avatar, { method: 'POST', body: body }).then(function () {
            // SL4 seam: persist the new turns on seal. Dormant until bridge exports __st_persist_turns.
            if (wasm.__st_persist_turns) wasm.__st_persist_turns();
        }).catch(function (err) {
            log.stream.error('send stream failed:', err);
            /* w3-grp: a failed stream never seals, so tell the rotation or it wedges. */
            if (wasm.__st_group_stream_failed) wasm.__st_group_stream_failed();
        });
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

    // Stop: cancel the reader so the fetch loop ends and the finally seals what already arrived.
    window.__st_send_stop = function () {
        if (currentReader) currentReader.cancel().catch(function (err) { log.stream.debug('send stop cancel failed:', err); });
    };

    // Browser-forced adapters: the data layer lives in Zig (net.zig + char_api.zig); only the
    // multipart uploads + blob download stay here, and this csrf helper serves ONLY those three.
    let csrfToken = null;

    async function ensureCsrfToken() {
        if (csrfToken) return;
        try {
            const res = await loggedFetch('/csrf-token');
            if (res.ok) {
                const data = await res.json();
                csrfToken = data.token;
            } else {
                log.net.warn('csrf token fetch returned', res.status);
            }
        } catch (err) {
            log.net.error('csrf token fetch failed:', err);
        }
    }

    function withCsrf(headers) {
        if (csrfToken) headers['X-CSRF-Token'] = csrfToken;
        return headers;
    }

    // Called from Zig (char_api.importCharacterFile); on success Zig reloads its store via
    // the __st_refresh_characters export.
    window.__st_char_import = async function () {
        const input = document.getElementById('char-import-input');
        if (!input || !input.files || !input.files[0]) return;
        const file = input.files[0];
        const ext = (file.name.split('.').pop() || '').toLowerCase();
        const fd = new FormData();
        fd.append('file', file);
        fd.append('file_type', ext);
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/characters/import', { method: 'POST', headers: withCsrf({}), body: fd });
            if (!res.ok) { log.net.warn('import failed:', res.status); window.alert('Import failed'); } else wasm.__st_refresh_characters();
        } catch (err) { log.chars.error('import failed:', err); }
        input.value = '';
    };

    // Called from Zig (char_api.exportCharacter) with the avatar + display name it owns.
    window.__st_char_export = async function (avatar, name) {
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/characters/export', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: JSON.stringify({ avatar_url: avatar, format: 'png' }) });
            if (!res.ok) { log.net.warn('export failed:', res.status); return; }
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = avatar || (name + '.png');
            document.body.appendChild(a); a.click(); a.remove();
            URL.revokeObjectURL(url);
        } catch (err) { log.chars.error('export failed:', err); }
    };

    // w3-wi: lorebook import stays a JS helper (File/FormData cannot cross the wasm boundary).
    window.__st_wi_import = async function () {
        const input = document.getElementById('wi-import-input');
        if (!input || !input.files || !input.files[0]) return;
        const fd = new FormData();
        fd.append('avatar', input.files[0]);
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/worldinfo/import', { method: 'POST', headers: withCsrf({}), body: fd });
            if (!res.ok) { log.net.warn('wi import failed:', res.status); window.alert('Import failed'); } else wasm.__st_refresh_wi();
        } catch (err) { log.net.error('wi import failed:', err); }
        input.value = '';
    };

    // w3-wi: lorebook export stays a JS helper (a blob download needs objectURL + a.click).
    window.__st_wi_export = async function (name) {
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/worldinfo/get', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: JSON.stringify({ name: name }) });
            if (!res.ok) { log.net.warn('wi export failed:', res.status); return; }
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = name + '.json';
            document.body.appendChild(a); a.click(); a.remove();
            URL.revokeObjectURL(url);
        } catch (err) { log.net.error('wi export failed:', err); }
    };

    // Every upload rides the ONE global multer, `.single('avatar')` (server-main.js:292), so the file
    // field is named 'avatar' whatever the endpoint and each 400s on `!request.file`.
    // The `finally` is load-bearing: a caller that has drawn a wait state is released only by `done`,
    // so a skipped call hangs it forever, and the language guarantees this where discipline would not.
    // `sent` tells "no file picked" apart from "never completed", which a bare 0 status cannot.
    async function postUpload(url, inputId, extra, done) {
        const input = document.getElementById(inputId);
        if (!input || !input.files || !input.files[0]) { done(0, false); return; }
        const fd = new FormData();
        fd.append('avatar', input.files[0]);
        Object.keys(extra).forEach(function (k) { fd.append(k, extra[k]); });
        await ensureCsrfToken();
        let status = 0;
        try {
            const res = await loggedFetch(url, { method: 'POST', headers: withCsrf({}), body: fd });
            status = res.status;
            if (!res.ok) log.net.warn('upload refused:', url, res.status);
        } catch (err) {
            log.net.error('upload never completed:', url, err);
        } finally {
            input.value = '';
            done(status, true);
        }
    }

    // Called from Zig (char_api.replaceAvatarFile) with the avatar_url it owns.
    window.__st_char_avatar = async function (avatar) {
        await postUpload('/api/characters/edit-avatar', 'char-avatar-input', { avatar_url: avatar }, function (status, sent) {
            if (!sent) return;
            if (status >= 200 && status < 300) wasm.__st_refresh_characters();
            else window.alert('Avatar update failed');
        });
    };

    // Card editor's own image replace (C-CARD2). Reports the outcome back to the panel, which says
    // what happened in its own footer instead of an alert. A cancelled picker is not an error.
    window.__st_card_avatar = async function (avatar) {
        await postUpload('/api/characters/edit-avatar', 'card-avatar-input', { avatar_url: avatar }, function (status, sent) {
            if (sent) wasm.__st_card_avatar_done(status);
        });
    };

    // Background upload (C-BG2): FormData cannot cross the wasm boundary, so uploadPick hops here.
    // The server names the file from request.file.originalname and answers with the sanitized name
    // (backgrounds.js:144-155), so only a re-fetch of /all knows what landed; the panel does that.
    // Unlike the two above this reports a cancelled picker too, because uploadPick has already drawn
    // its wait state and this callback is the only thing that clears it.
    window.__st_bg_upload = async function () {
        await postUpload('/api/backgrounds/upload', 'bg-upload-input', {}, function (status) {
            wasm.__st_bg_upload_done(status);
        });
    };

    /* w3-chatmgr */
    // Chat jsonl import: FormData cannot cross the wasm boundary, so importFile hops here. Posts the
    // stock /api/chats/import fields; reports the settle either way (0 = never completed), because
    // the panel has drawn "importing" and the bridge callback is the only thing that clears it.
    window.__st_chat_import = async function (avatar, characterName, userName) {
        const input = document.getElementById('chat-import-input');
        if (!input || !input.files || !input.files[0]) return;
        const file = input.files[0];
        const ext = (file.name.split('.').pop() || '').toLowerCase();
        const fd = new FormData();
        fd.append('avatar', file);
        fd.append('file_type', ext);
        fd.append('avatar_url', avatar);
        fd.append('character_name', characterName);
        fd.append('user_name', userName);
        await ensureCsrfToken();
        let status = 0;
        try {
            const res = await loggedFetch('/api/chats/import', { method: 'POST', headers: withCsrf({}), body: fd });
            status = res.status;
            if (!res.ok) log.net.warn('chat import refused:', res.status);
        } catch (err) {
            log.net.error('chat import never completed:', err);
        } finally {
            input.value = '';
            wasm.__st_chat_import_done(status);
        }
    };

    /* w3-chatmgr */
    // Chat jsonl export: /api/chats/export answers JSON with the raw file text in .result, and the
    // blob download is browser-forced, so both stay here (the __st_char_export shape).
    window.__st_chat_export = async function (avatar, stem) {
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/chats/export', {
                method: 'POST',
                headers: withCsrf({ 'Content-Type': 'application/json' }),
                body: JSON.stringify({ avatar_url: avatar, file: stem + '.jsonl', exportfilename: stem + '.jsonl', format: 'jsonl', is_group: false }),
            });
            if (!res.ok) { log.net.warn('chat export failed:', res.status); return; }
            const data = await res.json();
            const blob = new Blob([data.result || ''], { type: 'application/jsonl' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = stem + '.jsonl';
            document.body.appendChild(a); a.click(); a.remove();
            URL.revokeObjectURL(url);
        } catch (err) { log.chars.error('chat export failed:', err); }
    };

    // Persona avatar replace (C-PERS): FormData cannot cross the wasm boundary, so replaceAvatar hops here.
    // Posts to /api/avatars/upload with the stock frontend's fields ('avatar' file + 'overwrite_name').
    window.__st_persona_avatar = async function (avatar) {
        const input = document.getElementById('persona-avatar-input');
        if (!input || !input.files || !input.files[0]) return;
        const fd = new FormData();
        fd.append('avatar', input.files[0]);
        fd.append('overwrite_name', avatar);
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/avatars/upload', { method: 'POST', headers: withCsrf({}), body: fd });
            if (!res.ok) { log.net.warn('persona avatar upload failed:', res.status); window.alert('Avatar update failed'); } else wasm.__st_persona_avatar_done();
        } catch (err) { log.chars.error('persona avatar upload failed:', err); }
        input.value = '';
    };

    // Click telemetry, deliberate: it sees clicks on dead vnodes too, which is what a silently-dead
    // handler looks like. Motion, autogrow, reading presets and click-outside are zx handlers now.
    document.addEventListener('click', function (e) {
        const ctl = e.target.closest('button, [role=button], a, select, input, textarea, label');
        if (!ctl) return;
        logFor('ui').debug('click',
            ctl.tagName.toLowerCase()
            + (ctl.id ? '#' + ctl.id : '')
            + (ctl.className && typeof ctl.className === 'string' ? '.' + ctl.className.trim().split(/\s+/).join('.') : ''),
            ctl.getAttribute('aria-label') || ctl.textContent.trim().slice(0, 30) || '');
    }, false);

    // Chat reading-width drag: the .chat-resize separator sets an inline --reading-measure override
    // on #chat-root (inline beats the preset data-attribute rules); a preset pick clears it.
    (function initChatResize() {
        const MIN_W = 320;
        const KEY = 'st-reading-measurepx';
        const root = function () { return document.getElementById('chat-root'); };

        function setMeasure(px, persist) {
            const r = root();
            if (!r) return;
            const chat = document.getElementById('chat');
            const max = chat ? chat.clientWidth - 32 : 1200;
            const w = Math.max(MIN_W, Math.min(px, max));
            r.style.setProperty('--reading-measure', w + 'px');
            if (persist) { try { localStorage.setItem(KEY, String(w)); } catch (_) { /* private mode */ } }
        }

        function clearMeasure() {
            const r = root();
            if (r) r.style.removeProperty('--reading-measure');
            try { localStorage.removeItem(KEY); } catch (_) { /* private mode */ }
        }

        let stored = null;
        try { stored = parseInt(localStorage.getItem(KEY), 10); } catch (_) { /* private mode */ }
        if (stored && stored >= MIN_W) setMeasure(stored, false);

        let drag = null;
        document.addEventListener('pointerdown', function (e) {
            const handle = e.target && e.target.closest ? e.target.closest('.chat-resize') : null;
            if (!handle) return;
            e.preventDefault();
            const inner = handle.closest('.chat-inner');
            drag = { startX: e.clientX, startW: inner ? inner.getBoundingClientRect().width : 640, handle: handle };
            handle.classList.add('is-dragging');
            try { handle.setPointerCapture(e.pointerId); } catch (_) { /* synthetic events may lack a capturable id */ }
            document.body.style.userSelect = 'none';
        });
        document.addEventListener('pointermove', function (e) {
            if (!drag) return;
            // Centered column: moving the right edge by dx widens by 2dx.
            setMeasure(Math.round(drag.startW + (e.clientX - drag.startX) * 2), false);
        });
        function endDrag() {
            if (!drag) return;
            const inner = drag.handle.closest('.chat-inner');
            const w = inner ? Math.round(inner.getBoundingClientRect().width) : null;
            if (w) setMeasure(w, true);
            drag.handle.classList.remove('is-dragging');
            document.body.style.userSelect = '';
            logFor('ui').debug('reading width set:', w);
            drag = null;
        }
        document.addEventListener('pointerup', endDrag);
        document.addEventListener('pointercancel', endDrag);

        // Keyboard on the focusable separator (WCAG 2.1.1): arrows nudge, Home returns to preset.
        document.addEventListener('keydown', function (e) {
            const handle = e.target && e.target.closest ? e.target.closest('.chat-resize') : null;
            if (!handle) return;
            const inner = handle.closest('.chat-inner');
            const cur = inner ? inner.getBoundingClientRect().width : 640;
            if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { setMeasure(Math.round(cur + 16), true); e.preventDefault(); } else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { setMeasure(Math.round(cur - 16), true); e.preventDefault(); } else if (e.key === 'Home') { clearMeasure(); e.preventDefault(); }
        });

        document.addEventListener('dblclick', function (e) {
            if (e.target && e.target.closest && e.target.closest('.chat-resize')) clearMeasure();
        });
        // A measure preset pick clears the override in Zig (reading_prefs.handleClick), which owns
        // both halves of that state; no listener here.
    })();

    // Panel dock resize, split per ZX7: the gesture stays here (ziex's delegated events cannot hold
    // a pointer capture; the cursor leaves the vnode mid-drag) and Zig owns the width. The drag
    // paints an inline width for feedback, then hands the final pixels to __st_set_panel_width,
    // which clamps, stores and re-renders. Keyboard resize is Zig's own (ui.onResizeKey).
    (function initPanelResize() {
        const MIN_W = 240;
        const MAX_W = 620;
        let drag = null;

        function widthAt(clientX) {
            const dx = clientX - drag.startX;
            // A left dock widens as the separator moves right; a right dock does the opposite.
            const raw = drag.left ? drag.startW + dx : drag.startW - dx;
            return Math.round(Math.max(MIN_W, Math.min(raw, MAX_W)));
        }

        document.addEventListener('pointerdown', function (e) {
            const handle = e.target && e.target.closest ? e.target.closest('.panel-resize') : null;
            if (!handle) return;
            const panel = handle.closest('#panel-view');
            if (!panel) return;
            e.preventDefault();
            drag = {
                startX: e.clientX,
                startW: panel.getBoundingClientRect().width,
                left: handle.getAttribute('data-side') === 'left',
                panel: panel,
                handle: handle,
                last: null,
            };
            handle.classList.add('is-dragging');
            try { handle.setPointerCapture(e.pointerId); } catch (_) { /* synthetic events may lack a capturable id */ }
            document.body.style.userSelect = 'none';
        });

        document.addEventListener('pointermove', function (e) {
            if (!drag) return;
            drag.last = widthAt(e.clientX);
            drag.panel.style.width = drag.last + 'px';
        });

        function endPanelDrag() {
            if (!drag) return;
            const w = drag.last;
            drag.handle.classList.remove('is-dragging');
            document.body.style.userSelect = '';
            if (w !== null && wasm && wasm.__st_set_panel_width) {
                wasm.__st_set_panel_width(drag.left ? 1 : 0, w);
                logFor('ui').debug('panel width set:', w);
            }
            drag = null;
        }
        document.addEventListener('pointerup', endPanelDrag);
        document.addEventListener('pointercancel', endPanelDrag);
    })();

    // Reverse-lazy reader (ZX16 pump): scroll watcher + older-page fetch here, Zig owns window+parse+prepend.
    // Prepend holds position by ELEMENT-ANCHORED correction (2px), not scrollHeight-delta (~8px under content-visibility).
    const READER_PREFETCH_MARGIN = 600;
    const READER_BOTTOM_SLOP = 80;
    let readerChat = null;
    let readerChip = null;
    let readerPumping = false;
    let readerScheduled = false;
    let streamPinned = false;
    // The scrolled-up anchor a 409 re-sync must restore: its absolute chat index and its pixel offset
    // from the scroller top. -1 = no anchor (reader was near the bottom, so the re-sync tail-jumps).
    let resyncAnchorIndex = -1;
    let resyncAnchorPixel = 0;

    // Scroll the container to its full height across two frames: content-visibility lays out late
    // rows after the first frame, so a single-frame scroll lands short. Called from Zig on open.
    let scrollSettleRaf = 0;
    // A single snap lands short on a cold open (fonts/markdown/content-visibility settle late, so
    // scrollHeight underestimates). Keep snapping until it stops growing; a stream call restarts it.
    window.__st_reader_scroll_bottom = function () {
        const chat = document.getElementById('chat');
        if (!chat) return;
        if (scrollSettleRaf) cancelAnimationFrame(scrollSettleRaf);
        let last = -1;
        let stable = 0;
        let iters = 0;
        function settle() {
            chat.scrollTop = chat.scrollHeight;
            const h = chat.scrollHeight;
            if (h === last) { stable += 1; } else { stable = 0; last = h; }
            iters += 1;
            scrollSettleRaf = (stable < 3 && iters < 40) ? requestAnimationFrame(settle) : 0;
        }
        scrollSettleRaf = requestAnimationFrame(settle);
    };

    function readerNearBottom() {
        if (!readerChat) return true;
        return (readerChat.scrollHeight - readerChat.scrollTop - readerChat.clientHeight) < READER_BOTTOM_SLOP;
    }

    function readerSetState(state) {
        const root = document.getElementById('chat-root');
        if (!root) return;
        if (state) root.setAttribute('data-reader-state', state);
        else root.removeAttribute('data-reader-state');
    }

    function readerEnsureChip() {
        if (readerChip) return readerChip;
        readerChip = document.createElement('button');
        readerChip.type = 'button';
        readerChip.className = 'chat-newmsg-chip';
        readerChip.textContent = 'New message';
        readerChip.addEventListener('click', function () {
            streamPinned = true;
            readerHideChip();
            window.__st_reader_scroll_bottom();
        });
        const host = document.getElementById('chat-root') || document.body;
        host.appendChild(readerChip);
        if (globalThis.__zx_debug) {
            zxDomTrace('app.appendChild', zxDomName(host), 'button.chat-newmsg-chip (app-created node into a framework-owned subtree)');
        }
        return readerChip;
    }
    function readerShowChip() { readerEnsureChip().classList.add('is-visible'); }
    function readerHideChip() { if (readerChip) readerChip.classList.remove('is-visible'); }

    // A streamed reply follows the bottom only if you were already there; scrolled up, it stays put
    // and raises the chip. Called on every stream flush and once on seal.
    function readerStreamTick() {
        if (!readerChat) return;
        if (streamPinned) readerChat.scrollTop = readerChat.scrollHeight;
        else readerShowChip();
    }

    // The first message whose bottom is below the scroller's top edge: the on-screen anchor whose
    // viewport position a prepend must preserve.
    function readerAnchorMes() {
        if (!readerChat) return null;
        const mes = readerChat.querySelectorAll('.mes');
        const top = readerChat.getBoundingClientRect().top;
        for (let i = 0; i < mes.length; i++) {
            if (mes[i].getBoundingClientRect().bottom > top + 1) return mes[i];
        }
        return mes.length ? mes[mes.length - 1] : null;
    }

    // Snapshot the on-screen anchor before a 409 re-sync reload rebuilds the window (Zig calls this
    // from reloadCurrentChat). A near-bottom reader captures nothing, so the re-sync tail-jumps.
    window.__st_reader_capture_anchor = function () {
        if (!readerChat || readerNearBottom()) { resyncAnchorIndex = -1; return; }
        const a = readerAnchorMes();
        const idx = a ? parseInt(a.getAttribute('data-abs-index'), 10) : NaN;
        if (a && Number.isFinite(idx)) {
            resyncAnchorIndex = idx;
            resyncAnchorPixel = a.getBoundingClientRect().top - readerChat.getBoundingClientRect().top;
        } else {
            resyncAnchorIndex = -1;
        }
    };

    // Restore the reader after a 409 re-sync reload (Zig calls this from onChatDone). No anchor ->
    // tail-jump; else force history rows to real height (content-visibility estimates them) + scroll back.
    window.__st_reader_after_resync = function () {
        if (resyncAnchorIndex < 0) { window.__st_reader_scroll_bottom(); return; }
        requestAnimationFrame(function () {
            requestAnimationFrame(function () {
                const hist = readerChat.querySelectorAll('.chat-history .mes');
                for (let i = 0; i < hist.length; i++) hist[i].style.contentVisibility = 'visible';
                void readerChat.offsetHeight;
                const el = readerChat.querySelector('[data-abs-index="' + resyncAnchorIndex + '"]');
                if (el) {
                    readerChat.scrollTop += (el.getBoundingClientRect().top - readerChat.getBoundingClientRect().top) - resyncAnchorPixel;
                } else {
                    window.__st_reader_scroll_bottom();
                }
                for (let i = 0; i < hist.length; i++) hist[i].style.contentVisibility = '';
                resyncAnchorIndex = -1;
            });
        });
    };

    async function readerPrefetch() {
        if (readerPumping || !wasm || !readerChat) return;
        if (!wasm.__st_reader_can_prepend || !wasm.__st_reader_can_prepend()) return;
        const packed = wasm.__st_reader_next_body();
        if (packed === 0n) return;
        readerPumping = true;
        readerSetState('loading');
        const body = readString(Number(packed >> 32n), Number(packed & 0xffffffffn));
        try {
            await ensureCsrfToken();
            const res = await loggedFetch('/api/chats/get', {
                method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: body,
            });
            if (res.status === 409) {
                log.net.warn('history page stale (409) - re-syncing to the tail');
                if (wasm.__st_reader_abort) wasm.__st_reader_abort();
                readerSetState(null);
                readerPumping = false;
                if (wasm.__st_reader_resync) wasm.__st_reader_resync();
                return;
            }
            if (!res.ok) {
                log.net.warn('history page fetch failed:', res.status);
                if (wasm.__st_reader_abort) wasm.__st_reader_abort();
                readerSetState('error');
                readerPumping = false;
                return;
            }
            const text = await res.text();
            const ref = readerAnchorMes();
            const refBefore = ref ? ref.getBoundingClientRect().top : null;
            const beforeCount = readerChat.querySelectorAll('.mes').length;
            const buf = writeBytes(text);
            try { wasm.__st_reader_apply_page(buf.ptr, buf.len); } finally { freeRaw(buf); }
            readerSetState(null);
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    // Force the prepended rows to real height WHILE correcting, then revert: content-
                    // visibility sizes them at the 5rem estimate otherwise, so the anchor measures wrong.
                    const hist = readerChat.querySelectorAll('.chat-history .mes');
                    const added = readerChat.querySelectorAll('.mes').length - beforeCount;
                    for (let i = 0; i < added && i < hist.length; i++) hist[i].style.contentVisibility = 'visible';
                    void readerChat.offsetHeight;
                    if (ref && refBefore !== null && readerChat.contains(ref)) {
                        readerChat.scrollTop += (ref.getBoundingClientRect().top - refBefore);
                    }
                    for (let i = 0; i < added && i < hist.length; i++) hist[i].style.contentVisibility = '';
                    readerPumping = false;
                    if (readerChat.scrollTop < READER_PREFETCH_MARGIN) readerSchedulePrefetch();
                });
            });
        } catch (err) {
            log.net.error('history prefetch failed:', err);
            if (wasm.__st_reader_abort) wasm.__st_reader_abort();
            readerSetState('error');
            readerPumping = false;
        }
    }

    function readerSchedulePrefetch() {
        if (readerScheduled) return;
        readerScheduled = true;
        requestAnimationFrame(function () {
            readerScheduled = false;
            if (readerChat && readerChat.scrollTop < READER_PREFETCH_MARGIN) readerPrefetch();
        });
    }

    function initReaderPaging() {
        readerChat = document.getElementById('chat');
        if (!readerChat) return;
        readerChat.addEventListener('scroll', function () {
            if (readerChat.scrollTop < READER_PREFETCH_MARGIN) readerSchedulePrefetch();
            if (streamActive && streamPinned && !readerNearBottom()) streamPinned = false;
            if (readerNearBottom()) readerHideChip();
        }, { passive: true });
    }

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

            // .hydrated (past the next paint) settles complete messages, not the empty pre-hydrate
            // frames. .revealing gates the stagger to the first settle, dropped on the mes-rise lull so
            // a later arrival (a prepended history page) rises in at once instead of being delay-hidden.
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    const root = document.getElementById('chat-root');
                    if (!root) return;
                    root.classList.add('hydrated', 'revealing');
                    let settleTimer = 0;
                    root.addEventListener('animationend', function (e) {
                        if (e.animationName !== 'mes-rise') return;
                        if (settleTimer) clearTimeout(settleTimer);
                        settleTimer = setTimeout(function () { root.classList.remove('revealing'); }, 120);
                    });
                });
            });

            // Boot: Zig owns the data orchestration from here (char_api.boot via bootInit):
            // ?demo fixtures, characters + personas, auto-open, unreachable-backend fallback.
            if (wasm.__st_boot_init) {
                log.boot.debug('boot_init start');
                wasm.__st_boot_init();
                log.boot.debug('boot_init done');
            }

            // #chat exists after the first boot render; bind the reader scroll pump to it.
            initReaderPaging();

            // Dev-mode streaming: the verify.sh gate drives hostile/markdown/streaming
            // bodies through the real pipeline via ?stream=URL&hold=MS query params.
            var urlParams = new URLSearchParams(window.location.search);
            var streamParam = urlParams.get('stream');
            var holdParam = urlParams.get('hold');
            if (streamParam) {
                devMode = true;
                var probe = document.getElementById('probe-metrics');
                if (!probe) {
                    probe = document.createElement('pre');
                    probe.id = 'probe-metrics';
                    document.body.appendChild(probe);
                }
                var holdMs = parseInt(holdParam, 10) || 0;

                if (streamParam === '1') {
                    // Default: stream 200 tokens from /dev/stream
                    setTimeout(function () {
                        startStream('/dev/stream?n=200', 'Seraphina').catch(function (err) {
                            log.stream.error('dev stream failed:', err);
                        });
                    }, holdMs);
                } else if (streamParam === '2') {
                    // Two consecutive streams with distinct token prefixes
                    setTimeout(function () {
                        startStream('/dev/stream?n=20&prefix=aaa', 'First').then(function () {
                            return startStream('/dev/stream?n=20&prefix=bbb', 'Second');
                        }).catch(function (err) {
                            log.stream.error('dev stream pair failed:', err);
                        });
                    }, holdMs);
                } else {
                    // Custom URL (URL-encoded path from verify.sh)
                    setTimeout(function () {
                        startStream(streamParam, 'Seraphina').catch(function (err) {
                            log.stream.error('dev stream failed:', err);
                        });
                    }, holdMs);
                }
            }

            log.boot.info('init complete');
        } catch (err) {
            log.boot.error('init failed:', err);
        }
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
})();

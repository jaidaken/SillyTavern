// Custom glue for SillyTavern: message sanitization + SSE streaming + store sync
// Plain JavaScript, no zieux door pattern
(function () {
    'use strict';

    const PURIFY_URL = '/client/glue/vendor/purify.es.mjs';
    const HLJS_URL = '/client/glue/vendor/hljs.mjs';

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let wasm = null;
    let DOMPurify = null;
    let hljs = null;

    // Handle map for Zig DOM traversal
    let _nextHandle = 1;
    let _handleMap = new Map();

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
            el.innerHTML = hit;
            return;
        }

        if (skipGrow) return;

        const out = (lang && hljs.getLanguage(lang))
            ? hljs.highlight(source, { language: lang, ignoreIllegals: true })
            : hljs.highlightAuto(source);
        cacheHighlight(key, out.value);
        el.innerHTML = out.value;
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
        root.querySelectorAll('pre > code').forEach(function (el) {
            highlightElement(el, false);
        });
    }

    const env = {
        st_log: function (level, scopePtr, scopeLen, msgPtr, msgLen) {
            const scope = readString(scopePtr, scopeLen);
            const name = level === 0 ? 'error' : level === 1 ? 'warn' : level === 2 ? 'info' : 'debug';
            logFor(scope || 'wasm')[name](readString(msgPtr, msgLen));
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
        // DOM bridge functions (Zig imports these via extern "env")
        st_elem_set_attr: function (idPtr, idLen, namePtr, nameLen, valPtr, valLen) {
            var el = document.getElementById(idLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, idPtr, idLen)));
            if (!el) return;
            el.setAttribute(decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)),
                decoder.decode(new Uint8Array(wasm.memory.buffer, valPtr, valLen)));
        },
        st_elem_remove_attr: function (idPtr, idLen, namePtr, nameLen) {
            var el = document.getElementById(idLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, idPtr, idLen)));
            if (!el) return;
            el.removeAttribute(decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)));
        },
        st_elem_get_attr: function (idPtr, idLen, namePtr, nameLen) {
            var el = document.getElementById(idLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, idPtr, idLen)));
            if (!el) return 0n;
            var val = el.getAttribute(decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)));
            if (val === null) return 0n;
            var bytes = encoder.encode(val);
            var ptr = wasm.__zx_alloc(bytes.length);
            if (ptr === 0) return 0n;
            new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
            return (BigInt(ptr) << 32n) | BigInt(bytes.length);
        },
        st_local_storage_get: function (keyPtr, keyLen) {
            try {
                var val = localStorage.getItem(keyLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, keyPtr, keyLen)));
                if (val === null) return 0n;
                var bytes = encoder.encode(val);
                var ptr = wasm.__zx_alloc(bytes.length);
                if (ptr === 0) return 0n;
                new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
                return (BigInt(ptr) << 32n) | BigInt(bytes.length);
            } catch (err) { log.wasm.debug('localStorage get failed:', err); return 0n; }
        },
        st_local_storage_set: function (keyPtr, keyLen, valPtr, valLen) {
            try {
                localStorage.setItem(keyLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, keyPtr, keyLen)),
                    valLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, valPtr, valLen)));
            } catch (err) { log.wasm.debug('localStorage set failed:', err); }
        },
        st_local_storage_remove: function (keyPtr, keyLen) {
            try { localStorage.removeItem(keyLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, keyPtr, keyLen))); } catch (err) { log.wasm.debug('localStorage remove failed:', err); }
        },
        st_style_remove_property: function (idPtr, idLen, namePtr, nameLen) {
            var el = document.getElementById(idLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, idPtr, idLen)));
            if (!el) return;
            el.style.removeProperty(decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)));
        },
        st_node_by_id: function (idPtr, idLen) {
            var el = document.getElementById(idLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, idPtr, idLen)));
            if (!el) return 0;
            var h = _nextHandle++;
            _handleMap.set(h, el);
            return h;
        },
        st_qsa: function (parentHandle, selPtr, selLen) {
            var parent = _handleMap.get(parentHandle);
            if (!parent) return 0;
            var nodes = parent.querySelectorAll(selLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, selPtr, selLen)));
            var h = _nextHandle++;
            _handleMap.set(h, nodes);
            return h;
        },
        st_node_list_len: function (handle) {
            var v = _handleMap.get(handle);
            return (v && v.length !== undefined) ? v.length : 0;
        },
        st_node_list_item: function (listHandle, index) {
            var list = _handleMap.get(listHandle);
            if (!list || list.length === undefined || index >= list.length) return 0;
            var el = list[index];
            if (!el) return 0;
            var h = _nextHandle++;
            _handleMap.set(h, el);
            return h;
        },
        st_node_get_attr: function (nodeHandle, namePtr, nameLen) {
            var el = _handleMap.get(nodeHandle);
            if (!el) return 0n;
            var val = el.getAttribute(nameLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)));
            if (val === null) return 0n;
            var bytes = encoder.encode(val);
            var ptr = wasm.__zx_alloc(bytes.length);
            if (ptr === 0) return 0n;
            new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
            return (BigInt(ptr) << 32n) | BigInt(bytes.length);
        },
        st_node_set_attr: function (nodeHandle, namePtr, nameLen, valPtr, valLen) {
            var el = _handleMap.get(nodeHandle);
            if (!el) return;
            el.setAttribute(nameLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, namePtr, nameLen)),
                valLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, valPtr, valLen)));
        },
        st_release_handle: function (handle) {
            _handleMap.delete(handle);
        },
        st_save_reading_prefs: function () {
            function defaultForKey(k) {
                if (k === 'size') return 'm';
                if (k === 'measure') return 'normal';
                if (k === 'lh') return 'normal';
                if (k === 'justify') return 'on';
                if (k === 'indent') return 'novel';
                if (k === 'theme') return 'dark';
                if (k === 'tab') return 'reading';
                if (k === 'avatars') return 'on';
                return 'm';
            }
            var prefs = {};
            ['size', 'measure', 'lh', 'justify', 'indent', 'theme', 'tab', 'avatars'].forEach(function (k) {
                var v;
                try { v = localStorage.getItem('st-reading-' + k); } catch (err) { log.panels.debug('localStorage read failed:', err); v = null; }
                prefs[k] = v || defaultForKey(k);
            });
            ensureCsrfToken().then(function () {
                loggedFetch('/api/settings/get', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: '{}' })
                    .then(function (r) { return r.json(); })
                    .then(function (data) {
                        var settings = {};
                        if (data.settings) { try { settings = JSON.parse(data.settings); } catch (err) { log.net.warn('settings JSON parse failed:', err); } }
                        settings.clientReadingPrefs = prefs;
                        loggedFetch('/api/settings/save', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: JSON.stringify(settings) });
                    })
                    .catch(function (err) { log.net.error('reading prefs save failed:', err); });
            });
        },
    };

    const stats = { chunks: 0, tokens: 0, flushes: 0, sanitizes: 0, mdBytes: 0 };

    let streamActive = false;
    let devMode = false;

    async function startStream(url, name, avatar) {
        if (streamActive) throw new Error('stream already running');
        streamActive = true;

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

            const response = await loggedFetch(url, { headers: { Accept: 'text/event-stream' } });
            if (!response.ok || !response.body) throw new Error('stream failed: ' + response.status);

            reader = response.body.getReader();
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
            if (begun) {
                wasm.__st_stream_end();
                const chat = document.getElementById('chat');
                const mes = chat ? chat.querySelectorAll('.mes') : null;
                if (mes && mes.length) highlightSealedBlocks(mes[mes.length - 1]);
                if (devMode) {
                    stats.tokens = wasm.__st_stream_tokens();
                    window.__stStats = stats;
                    const el = document.getElementById('probe-metrics');
                    if (el) el.textContent = JSON.stringify(stats);
                }
            }
        }
    }

    // Characters known to JS (parallel to the wasm store)
    let jsCharacters = [];
    let personas = [];
    let selectedPersona = null;

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

    // 403 = stale CSRF token (server restarted under a long-lived tab): refresh + retry once.
    // NEVER for generation/relay endpoints: the server remaps upstream 401->403 and a blind retry double-submits a paid call.
    async function apiPost(url, body) {
        await ensureCsrfToken();
        const doPost = () => loggedFetch(url, {
            method: 'POST',
            headers: withCsrf({ 'Content-Type': 'application/json' }),
            body: JSON.stringify(body || {}),
        });
        let res = await doPost();
        if (res.status === 403) {
            log.net.warn(url, 'returned 403 - refreshing csrf token and retrying once');
            csrfToken = null;
            await ensureCsrfToken();
            res = await doPost();
        }
        return res;
    }

    function withCsrf(headers) {
        if (csrfToken) headers['X-CSRF-Token'] = csrfToken;
        return headers;
    }

    function initCharacters() {
        wasm.__st_clear_characters();
        jsCharacters = [];
        // Store rebuild invalidates any in-flight chat load: its captured index is now stale.
        chatLoadSeq++;
    }

    function addCharacterToWasm(c) {
        const n = writeBytes(c.name);
        const a = writeBytes(c.avatar);
        const d = writeBytes(c.description || '');
        const ch = writeBytes(c.chat || '');
        const fm = writeBytes(c.first_mes || '');
        wasm.__st_add_character(n.ptr, n.len, a.ptr, a.len, d.ptr, d.len, ch.ptr, ch.len, fm.ptr, fm.len, c.fav ? 1 : 0);
    }

    // Returns 'ok' | 'error' | 'unreachable': only 'unreachable' (network throw, or a dead-proxy
    // 502/504) may fall back to demo fixtures - a reachable backend's failure must stay visible.
    async function fetchCharacters() {
        log.chars.debug('character load start');
        try {
            const res = await apiPost('/api/characters/all', {});
            if (res.status === 502 || res.status === 504) { log.net.warn('char fetch: upstream gone,', res.status); return 'unreachable'; }
            if (!res.ok) { log.net.warn('char fetch failed:', res.status); return 'error'; }
            const list = await res.json();
            if (!Array.isArray(list)) { log.net.warn('char list response is not an array, got', typeof list); return 'error'; }
            initCharacters();
            list.forEach(function (c, i) {
                jsCharacters.push(c);
                addCharacterToWasm(c);
                const cd = writeBytes(c.create_date || '');
                // u64 params cross the wasm boundary as BigInt; Math.trunc guards fractional values.
                const u64 = v => BigInt(Math.trunc(v) || 0);
                wasm.__st_set_character_meta(i, cd.ptr, cd.len, u64(c.date_last_chat), u64(c.chat_size), u64(c.data_size));
            });
            log.chars.info('loaded', list.length, 'characters');
            return 'ok';
        } catch (err) {
            log.chars.error('character load failed:', err);
            return 'unreachable';
        }
    }

    // Boot lands in the most recently used chat (upstream ST behavior); demo mode keeps fixtures.
    function autoOpenRecentChat() {
        if (!jsCharacters.length) { log.chars.debug('auto-open: no characters'); return; }
        let best = 0;
        jsCharacters.forEach(function (c, i) {
            if ((c.date_last_chat || 0) > (jsCharacters[best].date_last_chat || 0)) best = i;
        });
        log.chars.info('auto-opening most recent chat:', jsCharacters[best].name);
        loadCharacterChat(best);
    }

    async function fetchPersonas() {
        log.personas.debug('persona load start');
        try {
            const res = await apiPost('/api/settings/get', {});
            if (!res.ok) {
                log.net.warn('persona settings fetch returned', res.status);
                return;
            }

            const data = await res.json();
            if (!data || typeof data !== 'object') {
                log.personas.warn('settings response is not an object, got', typeof data);
                return;
            }

            if (typeof data.settings !== 'string') {
                log.personas.warn('settings.settings is not a string, got', typeof data.settings);
                return;
            }

            var parsed;
            try {
                parsed = JSON.parse(data.settings);
            } catch (err) {
                log.personas.warn('settings JSON parse failed:', err);
                return;
            }

            if (!parsed || typeof parsed !== 'object') {
                log.personas.warn('parsed settings is not an object');
                return;
            }

            var powerUser = parsed.power_user;
            if (!powerUser || typeof powerUser !== 'object') {
                return;
            }

            var personsDict = powerUser.personas;
            var descsDict = powerUser.persona_descriptions;
            if (!personsDict || typeof personsDict !== 'object' || Array.isArray(personsDict)) {
                return;
            }

            var personaData = [];
            var keys = Object.keys(personsDict);
            for (var i = 0; i < keys.length; i++) {
                var avatarFile = keys[i];
                if (typeof avatarFile !== 'string' || avatarFile.length === 0) continue;

                var name = personsDict[avatarFile];
                if (typeof name !== 'string' || name.length === 0) name = 'Persona';

                var desc = '';
                if (descsDict && typeof descsDict === 'object' && !Array.isArray(descsDict)) {
                    var rawDesc = descsDict[avatarFile];
                    if (typeof rawDesc === 'string') desc = rawDesc;
                }

                personaData.push({ avatar: avatarFile, name: name, description: desc });
            }

            personas = personaData;
            if (personaData.length > 0) {
                selectedPersona = personaData[0];
            } else {
                selectedPersona = null;
            }
            wasm.__st_clear_personas();
            for (i = 0; i < personaData.length; i++) {
                var n = writeBytes(personaData[i].name);
                var a = writeBytes(personaData[i].avatar);
                var d = writeBytes(personaData[i].description || '');
                wasm.__st_add_persona(n.ptr, n.len, a.ptr, a.len, d.ptr, d.len);
            }
        } catch (err) {
            log.personas.error('persona load failed:', err);
        }
    }

    function appendMessageInWasm(name, body, avatar) {
        const n = writeBytes(name);
        const b = writeBytes(body);
        const a = writeBytes(avatar || '');
        wasm.__st_append_message(n.ptr, n.len, b.ptr, b.len, a.ptr, a.len);
    }

    let chatLoadSeq = 0;

    async function loadCharacterChat(index) {
        const c = jsCharacters[index];
        log.chars.debug('load chat request: index', index, c ? c.name : '(none)');
        if (!c) { log.chars.warn('load chat: no character at index', index, 'of', jsCharacters.length); return; }
        // Ticket per load: any await below is a window for a newer click; stale loads abandon
        // before touching the store so two quick clicks cannot interleave their messages.
        const seq = ++chatLoadSeq;
        const chatEl = document.getElementById('chat');
        if (chatEl) chatEl.setAttribute('aria-busy', 'true');
        try {
            const chatName = c.chat || (c.name + ' - ' + new Date().toISOString().slice(0, 10));
            const res = await apiPost('/api/chats/get', { avatar_url: c.avatar, file_name: chatName });
            if (seq !== chatLoadSeq) { log.chars.debug('load chat: superseded mid-fetch, abandoning', c.name); return; }
            // Server contract: 200 [] / 200 {} = no chat yet (fresh chat, seed the greeting below);
            // any error status = the chat may exist but could not be read - keep the current view.
            if (!res.ok) { log.chars.error('chat fetch failed:', res.status, '- keeping current chat'); return; }
            const data = await res.json();
            if (seq !== chatLoadSeq) { log.chars.debug('load chat: superseded mid-parse, abandoning', c.name); return; }
            wasm.__st_clear_messages();
            wasm.__st_select_character(index);
            var charAvatarUrl = c.avatar ? '../thumbnail?type=avatar&file=' + encodeURIComponent(c.avatar) : '';
            var personaAvatarUrl = selectedPersona ? '../thumbnail?type=persona&file=' + encodeURIComponent(selectedPersona.avatar) : '';
            const msgs = Array.isArray(data) && data.length > 1 ? data.slice(1) : [];
            if (msgs.length) {
                for (const m of msgs) {
                    const sender = m.name || (m.is_user ? 'You' : c.name);
                    const body = m.mes || '';
                    const avatar = m.is_user ? personaAvatarUrl : charAvatarUrl;
                    appendMessageInWasm(sender, body, avatar);
                }
            } else if (c.first_mes) {
                const userName = selectedPersona ? selectedPersona.name : 'You';
                const greeting = c.first_mes.replaceAll('{{char}}', c.name).replaceAll('{{user}}', userName);
                appendMessageInWasm(c.name, greeting, charAvatarUrl);
                log.chars.debug('seeded greeting for', c.name);
            }
            log.chars.info('opened chat:', c.name, '(' + msgs.length + ' messages)');
        } catch (err) {
            log.chars.error('chat load failed:', err);
        } finally {
            if (seq === chatLoadSeq && chatEl) chatEl.removeAttribute('aria-busy');
        }
    }

    // --- Character CRUD (client-initiated backend calls) ------------------------------
    // Each op posts to /api/characters/*, then reloads the wasm character store via fetchCharacters()
    // (which re-adds and bumps the shell). The Zig UI triggers these through
    // zx.client.js.global.call(... "__st_char_*" ...). Pure additive; no existing behaviour changed.
    window.__st_load_character_chat = loadCharacterChat;

    async function charApiPost(url, body) {
        const res = await apiPost(url, body);
        if (!res.ok) { log.net.warn(url, 'failed:', res.status); return null; }
        return res;
    }

    window.__st_char_create = async function () {
        const name = window.prompt('New character name:');
        if (!name) return;
        if (await charApiPost('/api/characters/create', { ch_name: name })) await fetchCharacters();
    };

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
            if (!res.ok) { log.net.warn('import failed:', res.status); window.alert('Import failed'); } else await fetchCharacters();
        } catch (err) { log.chars.error('import failed:', err); }
        input.value = '';
    };

    window.__st_char_rename = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        const name = window.prompt('Rename character:', c.name);
        if (!name || name === c.name) return;
        if (await charApiPost('/api/characters/rename', { avatar_url: c.avatar, new_name: name })) await fetchCharacters();
    };

    window.__st_char_duplicate = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        if (await charApiPost('/api/characters/duplicate', { avatar_url: c.avatar })) await fetchCharacters();
    };

    window.__st_char_delete = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        if (!window.confirm('Delete "' + c.name + '"? This cannot be undone.')) return;
        if (await charApiPost('/api/characters/delete', { avatar_url: c.avatar })) await fetchCharacters();
    };

    window.__st_char_export = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/characters/export', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: JSON.stringify({ avatar_url: c.avatar, format: 'png' }) });
            if (!res.ok) { log.net.warn('export failed:', res.status); return; }
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = c.avatar || (c.name + '.png');
            document.body.appendChild(a); a.click(); a.remove();
            URL.revokeObjectURL(url);
        } catch (err) { log.chars.error('export failed:', err); }
    };

    window.__st_char_fav = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        const newFav = !c.fav;
        c.fav = newFav; // optimistic; reverted on failure
        const res = await charApiPost('/api/characters/edit-attribute', { avatar_url: c.avatar, field: 'fav', value: newFav });
        if (res) await fetchCharacters();
        else c.fav = !newFav;
    };

    window.__st_char_avatar = async function (index) {
        const c = jsCharacters[index];
        if (!c) return;
        const input = document.getElementById('char-avatar-input');
        if (!input || !input.files || !input.files[0]) return;
        const file = input.files[0];
        const fd = new FormData();
        fd.append('file', file);
        fd.append('avatar_url', c.avatar);
        await ensureCsrfToken();
        try {
            const res = await loggedFetch('/api/characters/edit-avatar', { method: 'POST', headers: withCsrf({}), body: fd });
            if (!res.ok) { log.net.warn('avatar edit failed:', res.status); window.alert('Avatar update failed'); } else await fetchCharacters();
        } catch (err) { log.chars.error('avatar edit failed:', err); }
        input.value = '';
    };

    // Delegate event listeners
    document.addEventListener('click', function (e) {
        // Click telemetry: identify the pressed control (nearest interactive ancestor) at ui:debug.
        const ctl = e.target.closest('button, [role=button], a, select, input, textarea, label');
        if (ctl) {
            logFor('ui').debug('click',
                ctl.tagName.toLowerCase()
                + (ctl.id ? '#' + ctl.id : '')
                + (ctl.className && typeof ctl.className === 'string' ? '.' + ctl.className.trim().split(/\s+/).join('.') : ''),
                ctl.getAttribute('aria-label') || ctl.textContent.trim().slice(0, 30) || '');
        }
        // Motion toggle
        if (e.target.matches('[data-motion-set]')) {
            const name = e.target.getAttribute('data-motion-set');
            if (name) {
                localStorage.setItem('st-motion', name);
                if (wasm.__st_set_motion) wasm.__st_set_motion(name === 'system' ? 0 : name === 'on' ? 1 : 2);
            }
            return;
        }
        // Character select
        if (e.target.matches('[data-char-select]')) {
            const indexStr = e.target.getAttribute('data-char-select');
            if (indexStr) {
                const index = parseInt(indexStr, 10);
                if (!isNaN(index)) loadCharacterChat(index);
            }
            return;
        }
        // Persona select
        if (e.target.matches('[data-persona-index]')) {
            const indexStr = e.target.getAttribute('data-persona-index');
            if (indexStr) {
                const index = parseInt(indexStr, 10);
                if (!isNaN(index) && index < personas.length) {
                    wasm.__st_select_persona(index);
                }
            }
            return;
        }
    }, false);

    // Composer auto-grow
    document.addEventListener('input', function (e) {
        if (e.target.id === 'send_textarea') {
            const sh = e.target.scrollHeight;
            e.target.style.height = 'auto';
            e.target.style.height = sh + 'px';
        }
    }, false);

    // Click-outside drawer (composite env shim)
    function setupClickOutside() {
        document.addEventListener('click', function (e) {
            if (wasm && wasm.__st_close_panel) {
                const panel = document.querySelector('.panel');
                const drawers = document.querySelector('.drawers');
                if (panel && drawers && !panel.contains(e.target) && !drawers.contains(e.target)) {
                    wasm.__st_close_panel();
                }
            }
        }, false);
    }
    setupClickOutside();

    // Initialize: load deps, then init wasm
    async function init() {
        log.boot.info('init start');
        try {
            DOMPurify = (await import(PURIFY_URL)).default;
            hljs = (await import(HLJS_URL)).default;
            installHooks();
            log.boot.debug('dependencies loaded');

            var ZIEX_DOOR = '/client/vendor/ziex/wasm/index.js';

            // Capture WASM exports by wrapping instantiate
            const originalInstantiate = WebAssembly.instantiate;
            const originalInstantiateStreaming = WebAssembly.instantiateStreaming;

            function capture(result) {
                if (result && result.instance) wasm = result.instance.exports;
                return result;
            }

            WebAssembly.instantiate = async function (source, imports) {
                return capture(await originalInstantiate(source, imports));
            };
            WebAssembly.instantiateStreaming = async function (source, imports) {
                return capture(await originalInstantiateStreaming(source, imports));
            };

            let started;
            try {
                const door = await import(ZIEX_DOOR);
                started = await door.init({ importObject: { env: env } });
            } finally {
                WebAssembly.instantiateStreaming = originalInstantiateStreaming;
                WebAssembly.instantiate = originalInstantiate;
            }

            // The door's own instance is authoritative
            if (started && started.source && started.source.instance) wasm = started.source.instance.exports;
            if (!wasm || typeof wasm.__zx_alloc !== 'function') {
                throw new Error('door.init exposed no wasm exports: __zx_alloc unreachable');
            }

            log.boot.debug('wasm loaded, exports:', Object.keys(wasm).slice(0, 20));

            // door.init filled real bodies into the invisible SSR frames; add .hydrated past the next
            // paint so the CSS staggers the settle on complete messages, not the empty pre-hydrate frames.
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    const root = document.getElementById('chat-root');
                    if (root) root.classList.add('hydrated');
                });
            });

            // Boot
            if (wasm.__st_boot_init) {
                log.boot.debug('boot_init start');
                wasm.__st_boot_init();
                log.boot.debug('boot_init done');
            }

            // Demo fixtures only on explicit ?demo (verify.sh, demos) or when no backend answers;
            // a real deployment boots into the most recently used chat instead.
            const demoMode = new URLSearchParams(window.location.search).has('demo');
            if (demoMode && wasm.__st_seed_demo) {
                wasm.__st_seed_demo();
                log.boot.info('demo fixtures seeded (?demo)');
            }
            // Personas resolve before the auto-open so the seeded chat bakes the right user avatar.
            Promise.all([fetchCharacters(), fetchPersonas()]).then(function (results) {
                if (demoMode) return;
                const outcome = results[0];
                if (outcome === 'ok') { autoOpenRecentChat(); return; }
                if (outcome === 'unreachable' && wasm.__st_seed_demo) {
                    wasm.__st_seed_demo();
                    log.boot.info('backend unreachable - demo fixtures seeded');
                    return;
                }
                log.boot.error('character load failed against a reachable backend - see [st:net] above');
            });

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

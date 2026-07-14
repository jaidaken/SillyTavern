// Custom glue for SillyTavern: message sanitization + SSE streaming + store sync
// Plain JavaScript, no zieux door pattern
(function () {
    'use strict';

    const PURIFY_URL = '/client/glue/vendor/purify.es.mjs';
    const HLJS_URL = '/client/glue/vendor/hljs.mjs';
    const WASM_URL = '/client/assets/_/main.wasm';

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let wasm = null;
    let DOMPurify = null;
    let hljs = null;

    // Handle map for Zig DOM traversal
    let _nextHandle = 1;
    let _handleMap = new Map();

    if (window.trustedTypes && window.trustedTypes.createPolicy) {
        try { window.trustedTypes.createPolicy('default', { createHTML: function (s) { return s; } }); } catch (_) {}
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

    function appendMessage(name, body, avatar) {
        const n = writeBytes(name);
        let b = null;
        let a = null;
        let adopted = false;
        try {
            b = writeBytes(body);
            a = writeBytes(avatar || '');
            wasm.__st_append_message(n.ptr, n.len, b.ptr, b.len, a.ptr, a.len);
            adopted = true;
        } finally {
            if (!adopted) {
                freeRaw(n);
                if (b) freeRaw(b);
                if (a) freeRaw(a);
            }
        }
    }

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
        if (highlightCache.size >= 128) highlightCache.delete(highlightCache.keys().next().value);
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
        sanitize: function (ptr, len) {
            let out;
            try {
                const clean = DOMPurify.sanitize(readString(ptr, len), MESSAGE_CONFIG);
                try {
                    out = highlightBlocks(clean);
                } catch (err) {
                    console.error('[st-client] highlight failed', err);
                    out = clean;
                }
            } catch (err) {
                console.error('[st-client] sanitize failed', err);
                out = '';
            }
            try {
                return writeString(out);
            } catch (err) {
                console.error('[st-client] sanitize writeback failed', err);
                return 0n;
            }
        },
        sse_start: function (ptr, len) {
            startStream(readString(ptr, len), 'Seraphina').catch(function (err) {
                console.error('[st-client] stream failed', err);
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
            } catch (_) { return 0n; }
        },
        st_local_storage_set: function (keyPtr, keyLen, valPtr, valLen) {
            try {
                localStorage.setItem(keyLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, keyPtr, keyLen)),
                    valLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, valPtr, valLen)));
            } catch (_) {}
        },
        st_local_storage_remove: function (keyPtr, keyLen) {
            try { localStorage.removeItem(keyLen === 0 ? '' : decoder.decode(new Uint8Array(wasm.memory.buffer, keyPtr, keyLen))); } catch (_) {}
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
        st_set_timeout: function (ms) {
            return setTimeout(function () {
                if (wasm && wasm.__st_reading_save_timer) wasm.__st_reading_save_timer();
            }, ms);
        },
        st_clear_timeout: function (id) {
            clearTimeout(id);
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
            ['size','measure','lh','justify','indent','theme','tab','avatars'].forEach(function (k) {
                var v;
                try { v = localStorage.getItem('st-reading-' + k); } catch (_) { v = null; }
                prefs[k] = v || defaultForKey(k);
            });
            ensureCsrfToken().then(function () {
                fetch('/api/settings/get', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: '{}' })
                    .then(function (r) { return r.json(); })
                    .then(function (data) {
                        var settings = {};
                        if (data.settings) { try { settings = JSON.parse(data.settings); } catch (_) {} }
                        settings.clientReadingPrefs = prefs;
                        fetch('/api/settings/save', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: JSON.stringify(settings) });
                    })
                    .catch(function (err) { console.error('[st-client] reading prefs save failed', err); });
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
                    if (reader) reader.cancel().catch(function () {});
                }
            } catch (err) {
                console.error('[st-client] stream flush failed', err);
                ended = true;
                if (reader) reader.cancel().catch(function () {});
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

            const response = await fetch(url, { headers: { Accept: 'text/event-stream' } });
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
    let _personasFetched = false;

    let csrfToken = null;

    async function ensureCsrfToken() {
        if (csrfToken) return;
        try {
            const res = await fetch('/csrf-token');
            if (res.ok) {
                const data = await res.json();
                csrfToken = data.token;
            } else {
                console.warn('[st-client] csrf: token fetch returned', res.status);
            }
        } catch (err) {
            console.warn('[st-client] csrf: token fetch error:', err);
        }
    }

    function withCsrf(headers) {
        if (csrfToken) headers['X-CSRF-Token'] = csrfToken;
        return headers;
    }

    function initCharacters() {
        wasm.__st_clear_characters();
        jsCharacters = [];
    }

    function addCharacterToWasm(c) {
        const n = writeBytes(c.name);
        const a = writeBytes(c.avatar);
        const d = writeBytes(c.description || '');
        const ch = writeBytes(c.chat || '');
        const fm = writeBytes(c.first_mes || '');
        wasm.__st_add_character(n.ptr, n.len, a.ptr, a.len, d.ptr, d.len, ch.ptr, ch.len, fm.ptr, fm.len, c.fav ? 1 : 0);
    }

    function addPersonaToWasm(p) {
        const n = writeBytes(p.name);
        const a = writeBytes(p.avatar);
        const d = writeBytes(p.description || '');
        wasm.__st_add_persona(n.ptr, n.len, a.ptr, a.len, d.ptr, d.len);
    }

    async function fetchCharacters() {
        await ensureCsrfToken();
        try {
            const res = await fetch('/api/characters/all', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: '{}' });
            if (!res.ok) { console.warn('[st-client] char fetch failed', res.status); return; }
            const list = await res.json();
            if (!Array.isArray(list)) { console.warn('[st-client] char list response is not an array, got', typeof list); return; }
            initCharacters();
            for (const c of list) {
                jsCharacters.push(c);
                addCharacterToWasm(c);
            }
            console.log('[st-client] loaded', list.length, 'characters');
        } catch (err) {
            console.warn('[st-client] char fetch error (is the backend running?)', err);
        }
    }

    async function fetchPersonas() {
        console.log('[st-client] fetchPersonas: start');
        await ensureCsrfToken();
        try {
            const res = await fetch('/api/settings/get', { method: 'POST', headers: withCsrf({ 'Content-Type': 'application/json' }), body: '{}' });
            if (!res.ok) {
                console.warn('[st-client] persona: settings fetch returned', res.status);
                _personasFetched = true;
                return;
            }

            const data = await res.json();
            if (!data || typeof data !== 'object') {
                console.warn('[st-client] persona: settings response is not an object, got', typeof data);
                _personasFetched = true;
                return;
            }

            if (typeof data.settings !== 'string') {
                console.warn('[st-client] persona: settings.settings is not a string, got', typeof data.settings);
                _personasFetched = true;
                return;
            }

            var parsed;
            try {
                parsed = JSON.parse(data.settings);
            } catch (e) {
                console.warn('[st-client] persona: failed to parse settings JSON:', e.message);
                _personasFetched = true;
                return;
            }

            if (!parsed || typeof parsed !== 'object') {
                console.warn('[st-client] persona: parsed settings is not an object');
                _personasFetched = true;
                return;
            }

            var powerUser = parsed.power_user;
            if (!powerUser || typeof powerUser !== 'object') {
                _personasFetched = true;
                return;
            }

            var personsDict = powerUser.personas;
            var descsDict = powerUser.persona_descriptions;
            if (!personsDict || typeof personsDict !== 'object' || Array.isArray(personsDict)) {
                _personasFetched = true;
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
            _personasFetched = true;

            wasm.__st_clear_personas();
            for (var i = 0; i < personaData.length; i++) {
                var n = writeBytes(personaData[i].name);
                var a = writeBytes(personaData[i].avatar);
                var d = writeBytes(personaData[i].description || '');
                wasm.__st_add_persona(n.ptr, n.len, a.ptr, a.len, d.ptr, d.len);
            }
        } catch (err) {
            console.warn('[st-client] persona fetch error', err);
        }
    }

    function appendMessageInWasm(name, body, avatar) {
        const n = writeBytes(name);
        const b = writeBytes(body);
        const a = writeBytes(avatar || '');
        wasm.__st_append_message(n.ptr, n.len, b.ptr, b.len, a.ptr, a.len);
    }

    async function loadCharacterChat(index) {
        const c = jsCharacters[index];
        if (!c) return;
        await ensureCsrfToken();
        try {
            const chatName = c.chat || (c.name + ' - ' + new Date().toISOString().slice(0, 10));
            const res = await fetch('/api/chats/get', {
                method: 'POST',
                headers: withCsrf({ 'Content-Type': 'application/json' }),
                body: JSON.stringify({ avatar_url: c.avatar, file_name: chatName }),
            });
            if (!res.ok) { console.warn('[st-client] chat fetch failed', res.status); return; }
            const data = await res.json();
            wasm.__st_clear_messages();
            wasm.__st_select_character(index);
            var charAvatarUrl = c.avatar ? '../thumbnail?type=avatar&file=' + encodeURIComponent(c.avatar) : '';
            var personaAvatarUrl = selectedPersona ? '../thumbnail?type=persona&file=' + encodeURIComponent(selectedPersona.avatar) : '';
            if (Array.isArray(data) && data.length > 0) {
                for (let i = 1; i < data.length; i++) {
                    const m = data[i];
                    const sender = m.name || (m.is_user ? 'You' : c.name);
                    const body = m.mes || '';
                    const avatar = m.is_user ? personaAvatarUrl : charAvatarUrl;
                    appendMessageInWasm(sender, body, avatar);
                }
            }
        } catch (err) {
            console.warn('[st-client] chat load error', err);
        }
    }

    // Delegate event listeners
    document.addEventListener('click', function (e) {
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
        // Reading prefs
        if (e.target.matches('[data-reading-set]')) {
            const key = e.target.getAttribute('data-reading-set');
            const val = e.target.getAttribute('data-reading-val');
            if (key && val) {
                if (wasm.__st_reading_click) wasm.__st_reading_click(key, val);
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
        console.log('[custom.js] Starting init...');
        try {
            DOMPurify = (await import(PURIFY_URL)).default;
            hljs = (await import(HLJS_URL)).default;
            installHooks();
            console.log('[custom.js] Dependencies loaded');

            var ZIEX_DOOR = '/client/vendor/ziex/wasm/index.js';

            // Capture WASM exports by wrapping instantiate
            const originalInstantiate = WebAssembly.instantiate;
            const originalInstantiateStreaming = WebAssembly.instantiateStreaming;

            let wasmExports = null;

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
                const door = await import('/client/vendor/ziex/wasm/index.js');
                started = await door.init({ importObject: { env: env } });
            } finally {
                WebAssembly.instantiateStreaming = originalInstantiateStreaming;
                WebAssembly.instantiate = originalInstantiate;
            }

            // The door's own instance is authoritative
            if (started && started.source && started.source.instance) wasm = started.source.instance.exports;
            if (!wasm || typeof wasm.__zx_alloc !== 'function') {
                throw new Error('[st-client] door.init exposed no wasm exports: __zx_alloc unreachable');
            }

            console.log('[custom.js] WASM loaded, exports:', Object.keys(wasm).slice(0, 20));

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
                console.log('[custom.js] Calling __st_boot_init...');
                wasm.__st_boot_init();
                console.log('[custom.js] __st_boot_init done');
            }

            fetchCharacters();
            fetchPersonas();

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
                            console.error('[st-client] dev stream failed', err);
                        });
                    }, holdMs);
                } else if (streamParam === '2') {
                    // Two consecutive streams with distinct token prefixes
                    setTimeout(function () {
                        startStream('/dev/stream?n=20&prefix=aaa', 'First').then(function () {
                            return startStream('/dev/stream?n=20&prefix=bbb', 'Second');
                        }).catch(function (err) {
                            console.error('[st-client] dev stream pair failed', err);
                        });
                    }, holdMs);
                } else {
                    // Custom URL (URL-encoded path from verify.sh)
                    setTimeout(function () {
                        startStream(streamParam, 'Seraphina').catch(function (err) {
                            console.error('[st-client] dev stream failed', err);
                        });
                    }, holdMs);
                }
            }

            console.log('[custom.js] Init complete');
        } catch (err) {
            console.error('[custom.js] init failed:', err);
        }
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
})();
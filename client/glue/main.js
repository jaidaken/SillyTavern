// Classic script: ziex injects this without type="module" (src/build/init.zig:398),
// so every dependency arrives through dynamic import().
(function () {
    'use strict';

    const ZIEX_DOOR = '/vendor/ziex/wasm/index.js';
    const PURIFY_URL = '/glue/vendor/purify.es.mjs';
    const HLJS_URL = '/glue/vendor/hljs.mjs';

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let wasm = null;
    let DOMPurify = null;
    let hljs = null;

    function readString(ptr, len) {
        if (len === 0) return '';
        return decoder.decode(new Uint8Array(wasm.memory.buffer, ptr, len));
    }

    // Empty payload allocates nothing and reports address 0: Allocator.free no-ops on a zero-length
    // slice, so a one-byte buffer reported as len 0 leaks on every empty sanitize.
    function writeRaw(bytes) {
        if (bytes.length === 0) return { ptr: 0, len: 0 };
        const ptr = wasm.__zx_alloc(bytes.length);
        if (ptr === 0) throw new Error('__zx_alloc returned null');
        new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
        return { ptr: ptr, len: bytes.length };
    }

    function writeBytes(text) {
        return writeRaw(encoder.encode(text));
    }

    function writeString(text) {
        const buf = writeBytes(text);
        return (BigInt(buf.ptr) << 32n) | BigInt(buf.len);
    }

    function freeRaw(buf) {
        if (buf.len !== 0) wasm.__zx_free(buf.ptr, buf.len);
    }

    // Wasm adopts both buffers only once __st_append_message returns, so anything that throws before
    // that leaves them with no owner on either side.
    function appendMessage(name, body) {
        const n = writeBytes(name);
        let b = null;
        let adopted = false;
        try {
            b = writeBytes(body);
            wasm.__st_append_message(n.ptr, n.len, b.ptr, b.len);
            adopted = true;
        } finally {
            if (!adopted) {
                freeRaw(n);
                if (b) freeRaw(b);
            }
        }
    }

    // Themes and the custom-CSS box are the only style surfaces, and neither passes through here,
    // so a message body gets no styling power: no <style> element, no style attribute, no scoping.
    const MESSAGE_CONFIG = {
        RETURN_DOM: false,
        RETURN_DOM_FRAGMENT: false,
        RETURN_TRUSTED_TYPE: false,
        MESSAGE_SANITIZE: true,
        FORBID_TAGS: ['style'],
        FORBID_ATTR: ['style'],
    };

    const URL_ATTRS = new Set(['href', 'src', 'xlink:href', 'action', 'formaction']);

    function isSafeUri(value) {
        const v = String(value).replace(/[\u0000-\u0020]/g, '').toLowerCase();
        if (v.startsWith('javascript:')) return false;
        if (v.startsWith('data:')) {
            const match = /^data:([^;,]*)/.exec(v);
            const mediatype = match ? match[1] : '';
            if (!mediatype.startsWith('image/')) return false;
            // SVG carries <script> and onload, and is live the moment a data: URI reaches a navigation API.
            if (mediatype === 'image/svg+xml') return false;
        }
        return true;
    }

    function installHooks() {
        DOMPurify.addHook('afterSanitizeAttributes', function (node) {
            if ('target' in node) {
                node.setAttribute('target', '_blank');
                node.setAttribute('rel', 'noopener');
            }
        });

        DOMPurify.addHook('uponSanitizeAttribute', function (node, data) {
            if (URL_ATTRS.has(data.attrName) && !isSafeUri(data.attrValue)) {
                data.keepAttr = false;
            }
        });

        DOMPurify.addHook('uponSanitizeAttribute', function (node, data, config) {
            if (!config.MESSAGE_SANITIZE) return;
            if (data.attrName !== 'class' || !data.attrValue) return;
            // hljs* and language-* are ours, applied after md4c; namespacing them breaks the theme.
            data.attrValue = data.attrValue.split(/\s+/).filter(Boolean).map(function (v) {
                if (v.startsWith('fa-') || v.startsWith('note-') || v === 'monospace') return v;
                if (v.startsWith('hljs') || v.startsWith('language-')) return v;
                return 'custom-' + v;
            }).join(' ');
        });
    }

    const HIGHLIGHT_CACHE_MAX = 128;
    const highlightCache = new Map();

    function highlightKey(lang, source) {
        return (lang || '') + '\u0000' + source;
    }

    // Insertion order is eviction order, so the oldest settled block goes first.
    function cacheHighlight(key, value) {
        if (highlightCache.size >= HIGHLIGHT_CACHE_MAX) {
            highlightCache.delete(highlightCache.keys().next().value);
        }
        highlightCache.set(key, value);
    }

    // <template> content is inert: no scripts run, no subresources load, so hljs writes into it safely.
    function highlightBlocks(html) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html;
        const blocks = tpl.content.querySelectorAll('pre > code');

        // streamRender is up only inside the rerender a stream chunk drives, and that rerender
        // re-sanitizes the streaming body alone; bytes land at its end, so its last block is growing.
        const growing = streamRender ? blocks.length - 1 : -1;

        blocks.forEach(function (el, i) {
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

            // Next frame would throw this work away, and highlightAuto walks every grammar. DOMPurify
            // already escaped the text, so the tail renders as plain text until the fence settles.
            if (i === growing) return;

            const out = (lang && hljs.getLanguage(lang))
                ? hljs.highlight(source, { language: lang, ignoreIllegals: true })
                : hljs.highlightAuto(source);
            cacheHighlight(key, out.value);
            el.innerHTML = out.value;
        });
        return tpl.innerHTML;
    }

    const env = {
        // Sanitize first, then highlight: the hljs <span>s are injected after the gate, so they
        // never cross it. They are safe because hljs escapes the text it wraps, not because of DOMPurify.
        sanitize: function (ptr, len) {
            stats.sanitizes += 1;
            stats.mdBytes += len;
            const clean = DOMPurify.sanitize(readString(ptr, len), MESSAGE_CONFIG);
            return writeString(highlightBlocks(clean));
        },
        // Zig cannot await, so the rejection has to be absorbed here or it surfaces as unhandled.
        sse_start: function (ptr, len) {
            startStream(readString(ptr, len), 'Seraphina').catch(function (err) {
                console.error('[st-client] stream failed', err);
            });
        },
    };

    const stats = { chunks: 0, tokens: 0, flushes: 0, sanitizes: 0, mdBytes: 0 };

    let streamActive = false;
    let streamRender = false;

    // ziex re-renders synchronously on every state write (reactivity.zig:98), so raw bytes are
    // coalesced into one write per animation frame. Decoding and SSE framing happen in Zig.
    async function startStream(url, name) {
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
                // Dropping pending before the alloc lands would lose the chunk when __zx_alloc fails.
                const buf = writeRaw(merged);
                pending = [];
                pendingLen = 0;
                stats.flushes += 1;

                // __st_stream_append rerenders synchronously, so env.sanitize sees the streaming body.
                streamRender = true;
                try {
                    wasm.__st_stream_append(buf.ptr, buf.len);
                } finally {
                    streamRender = false;
                }

                // The framer seals on a [DONE] sentinel. Stop reading a socket the backend may hold
                // open past it, instead of latching streamActive until the connection eventually drops.
                if (wasm.__st_stream_done && wasm.__st_stream_done()) {
                    ended = true;
                    if (reader) reader.cancel().catch(function () {});
                }
            } catch (err) {
                // rAF and setTimeout drop this frame's throw, so cancelling the reader here is the
                // only way the finally below runs and releases streamActive.
                console.error('[st-client] stream flush failed', err);
                ended = true;
                if (reader) reader.cancel().catch(function () {});
            }
        }

        // rAF is paused in hidden tabs and in headless dumps, so a timer guarantees progress.
        // Whichever fires first cancels the other; a stale one must never touch a dead stream.
        function schedule() {
            if (raf || timer) return;
            raf = requestAnimationFrame(flush);
            timer = setTimeout(flush, 16);
        }

        try {
            const n = writeBytes(name);
            wasm.__st_stream_begin(n.ptr, n.len);
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
            // A fetch reject, a !ok, a null body, or a throwing begin must all clear the flag: a
            // latched streamActive strands the message in Streaming and blocks every later stream.
            cancelScheduled();
            ended = true;
            streamActive = false;
            // __st_stream_end rerenders synchronously, so the flag must already be down for the
            // terminal render to see the tail as settled. A begin that threw has nothing to close.
            if (begun) {
                wasm.__st_stream_end();
                stats.tokens = wasm.__st_stream_tokens();
                window.__stStats = stats;
                const el = document.getElementById('probe-metrics');
                if (el) el.textContent = JSON.stringify(stats);
            }
        }
    }

    async function boot() {
        const [door, purifyMod, hljsMod] = await Promise.all([
            import(ZIEX_DOOR),
            import(PURIFY_URL),
            import(HLJS_URL),
        ]);

        DOMPurify = purifyMod.default;
        hljs = hljsMod.default;
        installHooks();

        // ziex's init() runs mainClient before it returns, and the first client render calls
        // env.sanitize, so __zx_alloc must be reachable before init() resolves.
        const originalStreaming = WebAssembly.instantiateStreaming.bind(WebAssembly);
        const originalPlain = WebAssembly.instantiate.bind(WebAssembly);

        // instantiate(Module) resolves to a bare Instance; instantiate(BufferSource) to {module, instance}.
        function capture(result) {
            const instance = (result && result.instance) ? result.instance : result;
            if (instance && instance.exports) wasm = instance.exports;
            return result;
        }

        WebAssembly.instantiateStreaming = async function (source, imports) {
            return capture(await originalStreaming(source, imports));
        };
        WebAssembly.instantiate = async function (source, imports) {
            return capture(await originalPlain(source, imports));
        };

        let started;
        try {
            started = await door.init({ importObject: { env: env } });
        } finally {
            WebAssembly.instantiateStreaming = originalStreaming;
            WebAssembly.instantiate = originalPlain;
        }

        // The door's own instance is authoritative: a second module instantiated during init would
        // otherwise leave the glue writing into whichever one happened to resolve last.
        if (started && started.source && started.source.instance) wasm = started.source.instance.exports;
        if (!wasm || typeof wasm.__zx_alloc !== 'function') {
            throw new Error('[st-client] door.init exposed no wasm exports: __zx_alloc unreachable');
        }

        window.stAppendMessage = appendMessage;
        window.stStartStream = startStream;

        // Panel resize: drag a .panel-resize handle. Width is set live during the drag to avoid a
        // rerender per pointermove; the final width is persisted to Zig state on release.
        document.addEventListener('pointerdown', function (e) {
            const handle = e.target && e.target.closest ? e.target.closest('.panel-resize') : null;
            if (!handle) return;
            const panel = handle.parentElement;
            if (!panel) return;
            e.preventDefault();
            const isLeft = handle.dataset.side === 'left';
            const rect = panel.getBoundingClientRect();
            const pointerId = e.pointerId;
            let lastW = rect.width;
            function onMove(ev) {
                let w = isLeft ? (ev.clientX - rect.left) : (rect.right - ev.clientX);
                w = Math.max(240, Math.min(620, w));
                panel.style.width = w + 'px';
                lastW = w;
            }
            // pointercancel too: a browser-stolen drag (touch scroll, focus loss) never sends pointerup.
            function onEnd() {
                document.removeEventListener('pointermove', onMove);
                document.removeEventListener('pointerup', onEnd);
                document.removeEventListener('pointercancel', onEnd);
                if (handle.hasPointerCapture && handle.hasPointerCapture(pointerId)) {
                    handle.releasePointerCapture(pointerId);
                }
                if (wasm && wasm.__st_set_panel_width) wasm.__st_set_panel_width(isLeft ? 1 : 0, lastW);
            }
            document.addEventListener('pointermove', onMove);
            document.addEventListener('pointerup', onEnd);
            document.addEventListener('pointercancel', onEnd);
            // Captured moves still bubble to document, and the capture guarantees a terminal event.
            if (handle.setPointerCapture) handle.setPointerCapture(pointerId);
        });

        // Motion preference. Zig owns the reactive class the CSS reads; the glue owns persistence.
        // Default "system" honours the OS prefers-reduced-motion; the settings drawer overrides it.
        const MOTION = { system: 0, on: 1, off: 2 };
        function applyMotion(name) {
            if (wasm && wasm.__st_set_motion) wasm.__st_set_motion(MOTION[name] != null ? MOTION[name] : 0);
        }
        let savedMotion = 'system';
        try { savedMotion = localStorage.getItem('st-motion') || 'system'; } catch (_) {}
        applyMotion(savedMotion);

        document.addEventListener('click', function (e) {
            const btn = e.target && e.target.closest ? e.target.closest('[data-motion-set]') : null;
            if (!btn) return;
            const name = btn.getAttribute('data-motion-set');
            try { localStorage.setItem('st-motion', name); } catch (_) {}
            applyMotion(name);
        });

        // Composer auto-grow: the textarea expands to fit its content up to the CSS max-height, then
        // scrolls. Delegated on input so it survives ziex re-renders replacing the element.
        document.addEventListener('input', function (e) {
            const t = e.target;
            if (!t || t.id !== 'send_textarea') return;
            t.style.height = 'auto';
            t.style.height = t.scrollHeight + 'px';
        });

        // Click-outside closes an open top-bar drawer (docks are persistent and stay put). Only does
        // work when a `.top-drawer` is actually in the DOM.
        document.addEventListener('pointerdown', function (e) {
            const dd = document.querySelector('.top-drawer');
            if (!dd) return;
            const t = e.target;
            if (dd.contains(t)) return;
            if (t.closest && t.closest('.drawers > button')) return; // let the button's own toggle handle it
            if (wasm && wasm.__st_close_panel) wasm.__st_close_panel();
        });

        const params = new URLSearchParams(window.location.search);

        // Proves a message that has no SSR marker still renders: the acceptance gate for streaming.
        if (params.has('growth')) {
            window.__stBoot = Object.assign({}, stats);
            appendMessage('Seraphina', 'FIXTURE_FOUR appended at runtime, no marker existed for it.');
        }

        if (params.has('growth')) {
            const m = document.createElement('pre');
            m.id = 'probe-metrics';
            document.body.appendChild(m);
            m.textContent = JSON.stringify({ boot: window.__stBoot, after: stats });
        }

        if (params.has('stream')) {
            const metrics = document.createElement('pre');
            metrics.id = 'probe-metrics';
            metrics.style.cssText = 'position:fixed;left:8px;bottom:8px;margin:0;padding:6px 8px;'
                + 'font:12px ui-monospace,monospace;color:#8b93a7;background:#00000080;border-radius:6px';
            document.body.appendChild(metrics);

            const hold = params.get('hold');
            if (hold) {
                const img = document.createElement('img');
                img.src = '/dev/hold?ms=' + encodeURIComponent(hold);
                img.style.display = 'none';
                document.body.appendChild(img);
            }

            const arg = params.get('stream');
            if (arg === '2') {
                await startStream('/dev/stream?n=20&prefix=aaa', 'First');
                await startStream('/dev/stream?n=20&prefix=bbb', 'Second');
            } else {
                await startStream((!arg || arg === '1') ? '/dev/stream' : arg, 'Seraphina');
            }
        }
    }

    boot().catch(function (err) {
        console.error('[st-client] boot failed', err);
    });
})();

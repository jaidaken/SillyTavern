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

    function appendMessage(name, body) {
        const n = writeBytes(name);
        const b = writeBytes(body);
        wasm.__st_append_message(n.ptr, n.len, b.ptr, b.len);
    }

    const MESSAGE_CONFIG = {
        RETURN_DOM: false,
        RETURN_DOM_FRAGMENT: false,
        RETURN_TRUSTED_TYPE: false,
        MESSAGE_SANITIZE: true,
        ADD_TAGS: ['custom-style'],
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
            data.attrValue = data.attrValue.split(' ').map(function (v) {
                if (v.startsWith('fa-') || v.startsWith('note-') || v === 'monospace') return v;
                if (v.startsWith('hljs') || v.startsWith('language-')) return v;
                return 'custom-' + v;
            }).join(' ');
        });
    }

    // <template> content is inert: no scripts run, no subresources load. Highlight there, then sanitize.
    function highlightBlocks(html) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html;
        tpl.content.querySelectorAll('pre > code').forEach(function (el) {
            const tag = Array.from(el.classList).find(function (c) { return c.startsWith('language-'); });
            const lang = tag ? tag.slice(9) : null;
            const source = el.textContent;
            const out = (lang && hljs.getLanguage(lang))
                ? hljs.highlight(source, { language: lang, ignoreIllegals: true })
                : hljs.highlightAuto(source);
            el.innerHTML = out.value;
            el.classList.add('hljs');
        });
        return tpl.innerHTML;
    }

    const env = {
        // Sanitize first, then highlight: every byte that renders has crossed DOMPurify, and
        // hljs only ever adds escaped <span>s to text it already owns.
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

    // ziex re-renders synchronously on every state write (reactivity.zig:98), so raw bytes are
    // coalesced into one write per animation frame. Decoding and SSE framing happen in Zig.
    async function startStream(url, name) {
        if (streamActive) throw new Error('stream already running');
        streamActive = true;

        const n = writeBytes(name);
        wasm.__st_stream_begin(n.ptr, n.len);

        let pending = [];
        let pendingLen = 0;
        let raf = 0;
        let timer = 0;
        let ended = false;

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
            pending = [];
            pendingLen = 0;
            stats.flushes += 1;
            const buf = writeRaw(merged);
            wasm.__st_stream_append(buf.ptr, buf.len);
        }

        // rAF is paused in hidden tabs and in headless dumps, so a timer guarantees progress.
        // Whichever fires first cancels the other; a stale one must never touch a dead stream.
        function schedule() {
            if (raf || timer) return;
            raf = requestAnimationFrame(flush);
            timer = setTimeout(flush, 16);
        }

        try {
            const response = await fetch(url, { headers: { Accept: 'text/event-stream' } });
            if (!response.ok || !response.body) throw new Error('stream failed: ' + response.status);

            const reader = response.body.getReader();
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
            // A fetch reject, a !ok, or a null body must still close the stream: leaving it open
            // strands the message in Streaming and blocks every later stream.
            cancelScheduled();
            ended = true;
            wasm.__st_stream_end();
            streamActive = false;
            stats.tokens = wasm.__st_stream_tokens();
            window.__stStats = stats;
            const el = document.getElementById('probe-metrics');
            if (el) el.textContent = JSON.stringify(stats);
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
        const original = WebAssembly.instantiateStreaming.bind(WebAssembly);
        WebAssembly.instantiateStreaming = async function (source, imports) {
            const result = await original(source, imports);
            wasm = result.instance.exports;
            return result;
        };

        try {
            await door.init({ importObject: { env: env } });
        } finally {
            WebAssembly.instantiateStreaming = original;
        }

        window.stAppendMessage = appendMessage;
        window.stStartStream = startStream;

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

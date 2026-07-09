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

    // Buffers come from the wasm heap; sanitized.zig adopt() frees door results, store.zig retains message strings.
    function writeBytes(text) {
        const bytes = encoder.encode(text);
        const ptr = wasm.__zx_alloc(bytes.length || 1);
        if (ptr === 0) throw new Error('__zx_alloc returned null');
        if (bytes.length > 0) new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
        return { ptr: ptr, len: bytes.length };
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
        sse_start: function (ptr, len) {
            startStream(readString(ptr, len), 'Seraphina');
        },
    };

    const stats = { chunks: 0, tokens: 0, flushes: 0, sanitizes: 0, mdBytes: 0 };

    // ziex re-renders synchronously on every state write (reactivity.zig:98), so tokens are
    // coalesced into one write per animation frame rather than one per token.
    async function startStream(url, name) {
        const n = writeBytes(name);
        wasm.__st_stream_begin(n.ptr, n.len);

        let pending = '';
        let scheduled = false;

        function flush() {
            scheduled = false;
            if (pending === '') return;
            const buf = writeBytes(pending);
            pending = '';
            stats.flushes += 1;
            wasm.__st_stream_append(buf.ptr, buf.len);
        }

        // rAF is paused in hidden tabs and in headless dumps, so a timer guarantees progress.
        function schedule() {
            if (scheduled) return;
            scheduled = true;
            let fired = false;
            const once = function () {
                if (fired) return;
                fired = true;
                flush();
            };
            requestAnimationFrame(once);
            setTimeout(once, 16);
        }

        const response = await fetch(url, { headers: { Accept: 'text/event-stream' } });
        if (!response.ok || !response.body) throw new Error('stream failed: ' + response.status);

        const reader = response.body.getReader();
        let carry = '';
        for (;;) {
            const step = await reader.read();
            if (step.done) break;
            stats.chunks += 1;
            carry += decoder.decode(step.value, { stream: true });
            const lines = carry.split('\n');
            carry = lines.pop();
            for (const line of lines) {
                if (!line.startsWith('data:')) continue;
                const payload = line.slice(5).replace(/^ /, '');
                if (payload === '[DONE]') continue;
                stats.tokens += 1;
                pending += payload;
            }
            schedule();
        }

        flush();
        wasm.__st_stream_end();
        window.__stStats = stats;
        const el = document.getElementById('probe-metrics');
        if (el) el.textContent = JSON.stringify(stats);
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

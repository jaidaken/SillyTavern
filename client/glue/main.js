// Classic script: ziex injects this without type="module" (src/build/init.zig:398),
// so every dependency arrives through dynamic import().
(function () {
    'use strict';

    const ZIEX_DOOR = '/client/vendor/ziex/wasm/index.js';
    const PURIFY_URL = '/client/glue/vendor/purify.es.mjs';
    const HLJS_URL = '/client/glue/vendor/hljs.mjs';

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let wasm = null;
    let DOMPurify = null;
    let hljs = null;

    // A default Trusted Types policy: the browser applies it to EVERY innerHTML sink (glue + the ziex
    // door), so the edge require-trusted-types-for does not break rendering. HTML is already sanitized.
    if (window.trustedTypes && window.trustedTypes.createPolicy) {
        try { window.trustedTypes.createPolicy('default', { createHTML: function (s) { return s; } }); } catch (_) {}
    }

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

    // Themes and the custom-CSS box are the only style surfaces; a body gets no styling power and
    // no id/name/data-* it could forge to hijack a delegated listener (send_textarea, data-motion-set).
    const MESSAGE_CONFIG = {
        RETURN_DOM: false,
        RETURN_DOM_FRAGMENT: false,
        RETURN_TRUSTED_TYPE: false,
        MESSAGE_SANITIZE: true,
        // A message body is model output, so form controls would let it draw a fake login box that
        // posts credentials off-origin; chat prose has no legitimate use for them.
        FORBID_TAGS: ['style', 'form', 'input', 'button', 'textarea', 'select', 'option'],
        FORBID_ATTR: ['style'],
        ALLOW_DATA_ATTR: false,
        SANITIZE_NAMED_PROPS: true,
    };

    const URL_ATTRS = new Set(['href', 'src', 'action']);

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
            if (!('target' in node)) return;
            // A fragment link stays in the document, so leave it alone; an outbound link opens a new
            // tab and gets both noopener and noreferrer, not noopener alone.
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
            // language-* is md4c's, emitted upstream of this gate and read by highlightBlocks to pick a
            // grammar; hljs classes are added after the gate so a body's own never need to survive it.
            data.attrValue = data.attrValue.split(/\s+/).filter(Boolean).map(function (v) {
                if (v.startsWith('language-')) return v;
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

    // Highlight one pre>code in place. Source is read from textContent, so a re-run reproduces the
    // same output: the seal pass can call it idempotently on already-highlighted blocks.
    function highlightElement(el, skipGrow) {
        const tag = Array.from(el.classList).find(function (c) { return c.startsWith('language-'); });
        const lang = tag ? tag.slice(9) : null;
        const source = el.textContent;
        const key = highlightKey(lang, source);
        el.classList.add('hljs');

        const hit = highlightCache.get(key);
        if (hit !== undefined) {
            // allow-raw-html-sink: cached hljs output, hljs-escaped; body already DOMPurify-sanitized.
            el.innerHTML = hit;
            return;
        }

        // Growing block changes next frame and highlightAuto walks every grammar, so leave it plain
        // here; highlightSealedBlocks runs hljs on it once the stream seals.
        if (skipGrow) return;

        const out = (lang && hljs.getLanguage(lang))
            ? hljs.highlight(source, { language: lang, ignoreIllegals: true })
            : hljs.highlightAuto(source);
        cacheHighlight(key, out.value);
        // allow-raw-html-sink: hljs output, hljs-escaped; body already DOMPurify-sanitized.
        el.innerHTML = out.value;
    }

    // <template> content is inert: no scripts run, no subresources load, so hljs writes into it safely.
    function highlightBlocks(html) {
        const tpl = document.createElement('template');
        // allow-raw-html-sink: html is the DOMPurify-sanitized string; template content is inert.
        tpl.innerHTML = html;
        const blocks = tpl.content.querySelectorAll('pre > code');

        // streamRender is up only inside the rerender a stream chunk drives, so the streaming body's
        // last block is the growing one; skip it, the seal pass highlights it at stream end.
        const growing = streamRender ? blocks.length - 1 : -1;

        blocks.forEach(function (el, i) {
            highlightElement(el, i === growing);
        });
        return tpl.innerHTML;
    }

    // A lone streamed fence stays plain: the growing-block skip never highlights it and the memo skip
    // means MessageView never re-renders it once sealed. Highlight the sealed message's blocks here.
    function highlightSealedBlocks(root) {
        if (!root || !hljs) return;
        root.querySelectorAll('pre > code').forEach(function (el) {
            highlightElement(el, false);
        });
    }

    const env = {
        // Sanitize first, then highlight: the hljs <span>s are injected after the gate, so they
        // never cross it. They are safe because hljs escapes the text it wraps, not because of DOMPurify.
        sanitize: function (ptr, len) {
            stats.sanitizes += 1;
            stats.mdBytes += len;
            // Never throw back into the wasm door: a sanitize failure fails closed (drop the body,
            // never unsanitized); a highlight failure degrades to the sanitized-but-unhighlighted HTML.
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
            // writeString allocates, and a null __zx_alloc would throw the result back into the door,
            // unwinding past every Zig defer (double-free + leak). Fail closed to the empty contract (0).
            try {
                return writeString(out);
            } catch (err) {
                console.error('[st-client] sanitize writeback failed', err);
                return 0n;
            }
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
    // Set true in boot only when a ?rendercount / ?growth / ?stream param is present; gates every
    // probe surface (window globals, metrics DOM, the harness blocks) off the production path.
    let devMode = false;

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
            // Nonzero = the store refused (stream already live, or alloc failed); the door owns n either
            // way. Do not arm begun, so no fetch runs and no caret spins on a stream that never opened.
            if (wasm.__st_stream_begin(n.ptr, n.len) !== 0) throw new Error('stream begin refused');
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
                // The sealed message never re-renders (memo skip), so highlight its now-settled
                // growing code block in place; the streamed message is the last .mes in the log.
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

    // Render-count replay driver: one token per feed, synchronous, so counter deltas are exact.
    // Reads the per-region counters to prove scoping (token -> MessageLog only, toggle -> Shell only).
    function renderCountProbe(params) {
        if (!wasm.__st_mv_renders) throw new Error('__st_mv_renders missing: build with -Dinstrument');
        const hasRegions = !!(wasm.__st_shell_renders && wasm.__st_messagelog_renders && wasm.__st_composer_renders);

        function snap() {
            return {
                mv: wasm.__st_mv_renders(),
                shell: hasRegions ? wasm.__st_shell_renders() : -1,
                mlog: hasRegions ? wasm.__st_messagelog_renders() : -1,
                composer: hasRegions ? wasm.__st_composer_renders() : -1,
            };
        }
        const stat = function (a) { return { min: Math.min.apply(null, a), max: Math.max.apply(null, a) }; };

        const extra = Math.max(0, parseInt(params.get('msgs') || '0', 10) || 0);
        const tokens = Math.max(1, parseInt(params.get('tokens') || '60', 10) || 60);

        for (let i = 0; i < extra; i++) {
            appendMessage('You', 'seed message ' + i);
        }

        const begin = writeBytes('Seraphina');
        wasm.__st_stream_begin(begin.ptr, begin.len);

        const onscreen = document.querySelectorAll('.mes').length;
        const perToken = [];
        const perTokenShell = [];
        const perTokenMlog = [];
        const perTokenComposer = [];
        for (let i = 0; i < tokens; i++) {
            const buf = writeRaw(encoder.encode('data: {"content":"tok' + i + ' "}\n\n'));
            const pre = snap();
            wasm.__st_stream_append(buf.ptr, buf.len);
            const post = snap();
            perToken.push(post.mv - pre.mv);
            perTokenShell.push(post.shell - pre.shell);
            perTokenMlog.push(post.mlog - pre.mlog);
            perTokenComposer.push(post.composer - pre.composer);
        }
        wasm.__st_stream_end();

        // Panel-toggle scoping + composer/scroll survival (the structurally-fixed left-dock bug):
        // type a draft, note the log node, open a dock. Only Shell must re-render; the composer
        // textarea node and its value and the chat log node must all survive the toggle.
        const DRAFT = 'unsent draft that must survive a panel toggle';
        let toggle = null;
        const textarea = document.getElementById('send_textarea');
        if (hasRegions && textarea) {
            textarea.value = DRAFT;
            const chatBefore = document.getElementById('chat');
            const scrollBefore = chatBefore ? chatBefore.scrollTop : 0;
            const drawerBtn = document.querySelector('.drawers > button');
            const pre = snap();
            if (drawerBtn) drawerBtn.click();
            const post = snap();
            const textareaAfter = document.getElementById('send_textarea');
            const chatAfter = document.getElementById('chat');
            toggle = {
                shell: post.shell - pre.shell,
                mlog: post.mlog - pre.mlog,
                composer: post.composer - pre.composer,
                dockOpened: !!document.querySelector('.panel'),
                composerNodeSame: textareaAfter === textarea,
                composerTextPreserved: !!textareaAfter && textareaAfter.value === DRAFT,
                chatNodeSame: !!chatAfter && chatAfter === chatBefore,
                scrollPreserved: chatAfter ? chatAfter.scrollTop === scrollBefore : true,
            };
        }

        const min = Math.min.apply(null, perToken);
        const max = Math.max.apply(null, perToken);
        const result = {
            mode: 'rendercount',
            onscreen: onscreen,
            tokens: tokens,
            perTokenMin: min,
            perTokenMax: max,
            perTokenSum: perToken.reduce(function (a, b) { return a + b; }, 0),
            constant: min === max,
            streamTokens: wasm.__st_stream_tokens ? wasm.__st_stream_tokens() : -1,
            regions: hasRegions,
            tokenShell: stat(perTokenShell),
            tokenMlog: stat(perTokenMlog),
            tokenComposer: stat(perTokenComposer),
            toggle: toggle,
        };
        window.__stRenderCount = result;
        const el = document.createElement('pre');
        el.id = 'probe-metrics';
        el.textContent = JSON.stringify(result);
        document.body.appendChild(el);
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

        // door.init filled real bodies into the invisible SSR frames; add .hydrated past the next
        // paint so the CSS staggers the settle on complete messages, not the empty pre-hydrate frames.
        requestAnimationFrame(function () {
            requestAnimationFrame(function () {
                const root = document.getElementById('chat-root');
                if (root) root.classList.add('hydrated');
            });
        });

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

        // Keyboard resize (WCAG 2.1.1): the focusable separator must move on arrow keys. Right/Up
        // widen, Left/Down narrow, shift coarser; Zig re-renders the panel + its aria-valuenow.
        document.addEventListener('keydown', function (e) {
            const handle = e.target && e.target.closest ? e.target.closest('.panel-resize') : null;
            if (!handle) return;
            const dir = (e.key === 'ArrowRight' || e.key === 'ArrowUp') ? 1
                : (e.key === 'ArrowLeft' || e.key === 'ArrowDown') ? -1 : 0;
            if (dir === 0) return;
            e.preventDefault();
            const panel = handle.parentElement;
            if (!panel) return;
            const isLeft = handle.dataset.side === 'left';
            const cur = panel.getBoundingClientRect().width;
            const next = Math.max(240, Math.min(620, cur + dir * (e.shiftKey ? 48 : 16)));
            if (wasm && wasm.__st_set_panel_width) wasm.__st_set_panel_width(isLeft ? 1 : 0, next);
        });

        // Drawer overlay: an open drawer covers the content, so the chat log and composer go inert
        // while it is up. The drawer lives in #shell (re-renders on toggle), so observe it and sync.
        function syncDrawerInert() {
            const open = !!document.querySelector('.top-drawer');
            const chat = document.getElementById('chat');
            const composer = document.getElementById('composer');
            if (chat) chat.inert = open;
            if (composer) composer.inert = open;
        }
        const shellEl = document.getElementById('shell');
        if (shellEl) {
            // syncReadingAria too: the settings body (which holds the reading controls) re-renders inside
            // the shell, so re-apply aria-pressed to the active buttons whenever it does.
            new MutationObserver(function () { syncDrawerInert(); syncReadingAria(); }).observe(shellEl, { childList: true, subtree: true });
            syncDrawerInert();
        }

        // Motion preference. Zig owns the reactive class the CSS reads; the glue owns persistence.
        // Default "system" honours the OS prefers-reduced-motion; the settings drawer overrides it.
        const MOTION = { system: 0, on: 1, off: 2 };
        function applyMotion(name) {
            // hasOwn, not MOTION[name] != null: a bare lookup reaches Object.prototype, so "toString"
            // would resolve to a function and pass a null check.
            const code = Object.hasOwn(MOTION, name) ? MOTION[name] : 0;
            if (wasm && wasm.__st_set_motion) wasm.__st_set_motion(code);
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

        // Reading preferences: presentational data-reading-* attributes on #chat-root, which does not
        // re-render with the Shell region, so the values (and the CSS active highlights keyed off them)
        // survive a settings re-render without Zig state. The glue owns persistence; the CSS owns effect.
        const READING_DEFAULT = { size: 'm', measure: 'normal', lh: 'normal', justify: 'on', indent: 'novel', theme: 'dark', tab: 'reading' };
        function applyReading(key, val) {
            const root = document.getElementById('chat-root');
            if (root) root.setAttribute('data-reading-' + key, val);
        }
        // The CSS highlights the active control off #chat-root; mirror that to aria-pressed so a screen
        // reader hears the current selection (the CSS colour alone is invisible to AT).
        function syncReadingAria() {
            const root = document.getElementById('chat-root');
            if (!root) return;
            const btns = document.querySelectorAll('[data-reading-set]');
            for (let i = 0; i < btns.length; i++) {
                const b = btns[i];
                const on = root.getAttribute('data-reading-' + b.getAttribute('data-reading-set')) === b.getAttribute('data-reading-val');
                b.setAttribute('aria-pressed', on ? 'true' : 'false');
            }
        }
        Object.keys(READING_DEFAULT).forEach(function (key) {
            let val = READING_DEFAULT[key];
            try { val = localStorage.getItem('st-reading-' + key) || READING_DEFAULT[key]; } catch (_) {}
            applyReading(key, val);
        });
        syncReadingAria();
        document.addEventListener('click', function (e) {
            const btn = e.target && e.target.closest ? e.target.closest('[data-reading-set]') : null;
            if (!btn) return;
            const key = btn.getAttribute('data-reading-set');
            const val = btn.getAttribute('data-reading-val');
            if (!key || val === null || !Object.hasOwn(READING_DEFAULT, key)) return;
            try { localStorage.setItem('st-reading-' + key, val); } catch (_) {}
            applyReading(key, val);
            syncReadingAria();
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

        // Everything below is the dev + probe harness (render-harness.sh, verify.sh). A production
        // page carries none of these params, so the test globals and probe blocks never load for it.
        devMode = params.has('rendercount') || params.has('growth') || params.has('stream');
        if (!devMode) return;

        window.stAppendMessage = appendMessage;
        window.stStartStream = startStream;

        if (params.has('rendercount')) {
            renderCountProbe(params);
            return;
        }

        // Proves a message that has no SSR marker still renders: the acceptance gate for streaming.
        if (params.has('growth')) {
            window.__stBoot = Object.assign({}, stats);
            appendMessage('Seraphina', 'FIXTURE_FOUR appended at runtime, no marker existed for it.');
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

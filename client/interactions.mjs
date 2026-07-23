// Interaction gate: real Chrome input (CDP) against the served client, so a silently-dead handler
// (the ziex currentTarget/jsz traps) fails a check instead of shipping. Rows: 'must' = fatal,
// 'pending' = known-red plan item (printed; a pending PASS asks for promotion to must).
// Usage: node interactions.mjs --base http://127.0.0.1:PORT [--timeout MS]

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

function parseArgs(argv) {
    // Watchdog must exceed the worst-case sum of row waits, or a fully broken build dies at the
    // watchdog before the per-row diagnostics print. Raised with the P3-B rows, which navigate.
    const out = { base: null, timeout: 600000 };
    for (let i = 0; i < argv.length; i += 2) {
        const k = argv[i], v = argv[i + 1];
        if (k === '--base') out.base = v;
        else if (k === '--timeout') out.timeout = Number(v);
        else throw new Error(`unknown arg: ${k}`);
    }
    if (!out.base) throw new Error('required: --base URL');
    return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Poll a condition rather than sleeping a guessed interval: a refresh crosses the network, and a
// fixed wait is either a flake or dead time.
const waitUntil = async (fn, timeoutMs) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await fn()) return true;
        await sleep(100);
    }
    return false;
};

// A SECOND connection of the same user, held open from the driver. The origin skip is only half
// proved by this tab staying quiet; the other half is that the change did reach somebody else.
const openSecondStream = async (base, clientId) => {
    const controller = new AbortController();
    const res = await fetch(`${base}/api/events?clientId=${encodeURIComponent(clientId)}`, { signal: controller.signal });
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    const state = { frames: [], close: () => controller.abort() };
    (async () => {
        try {
            for (;;) {
                const { done, value } = await reader.read();
                if (done) return;
                state.frames.push(decoder.decode(value, { stream: true }));
            }
        } catch { /* aborted by close() */ }
    })();
    return state;
};

/* W6 */
// WCAG contrast for the W6 rows, injected into a page eval. The colour is PAINTED to resolve it:
// this theme is authored in oklch and color-mix, and Chrome keeps both verbatim in computed style
// ("oklch(0.54 0.018 72)"), so scraping the numbers out of the string reads L/C/H as if they were
// RGB and lands every pair at ~1:1. A 1x1 canvas gives the sRGB bytes the display actually gets.
const contrastFn = `
    const rgb = (c) => { const cv = document.createElement('canvas'); cv.width = cv.height = 1;
        const x = cv.getContext('2d', { willReadFrequently: true });
        x.fillStyle = c; x.fillRect(0, 0, 1, 1);
        const d = x.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2]]; };
    const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4); });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
    const contrast = (a, b) => { const l1 = lum(a), l2 = lum(b);
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); };
`;

class CDP {
    constructor(ws) {
        this.ws = ws;
        this.id = 0;
        this.pending = new Map();
        this.onEvent = null;
        ws.addEventListener('message', (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.id === undefined) {
                if (this.onEvent) this.onEvent(msg);
                return;
            }
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
            else p.resolve(msg.result);
        });
        const failAll = (reason) => {
            for (const [, p] of this.pending) p.reject(new Error(reason));
            this.pending.clear();
        };
        ws.addEventListener('close', () => failAll('cdp socket closed'));
        ws.addEventListener('error', () => failAll('cdp socket error'));
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id;
        const frame = { id, method, params };
        if (sessionId) frame.sessionId = sessionId;
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject, method });
            this.ws.send(JSON.stringify(frame));
        });
    }
}

function launchChrome(profile) {
    const child = spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox',
        // Headless answers `(hover: hover) and (pointer: fine)` FALSE, so every hover rule is INERT and
        // a row asserting one passes without the rule applying. mobile-audit.mjs omits this on purpose.
        '--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4',
        '--window-size=1400,1000',
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
    // Without this, a missing chrome binary is an async unhandled 'error' that skips cleanup.
    child.on('error', (err) => { child.spawnError = err; });
    return child;
}

async function readDebugPort(profile, child, deadline) {
    const portFile = join(profile, 'DevToolsActivePort');
    while (Date.now() < deadline) {
        if (child.spawnError) throw new Error(`chrome failed to spawn: ${child.spawnError.message}`);
        if (child.exitCode !== null) throw new Error(`chrome exited early (code ${child.exitCode})`);
        if (existsSync(portFile)) {
            const line = readFileSync(portFile, 'utf8').split('\n')[0].trim();
            if (line) return line;
        }
        await sleep(50);
    }
    throw new Error('chrome never wrote DevToolsActivePort');
}

async function openWs(url) {
    return await new Promise((resolve, reject) => {
        const ws = new WebSocket(url);
        ws.addEventListener('open', () => resolve(ws), { once: true });
        ws.addEventListener('error', () => reject(new Error('cdp websocket error')), { once: true });
    });
}

// Driver context bound to one attached page session.
class Page {
    constructor(cdp, sessionId, consoleLines, navState) {
        this.cdp = cdp;
        this.sessionId = sessionId;
        this.consoleLines = consoleLines;
        // Shared with the console handler so a captured line can name the page it came from.
        this.navState = navState || { url: 'about:blank' };
    }
    async eval(expr) {
        const r = await this.cdp.send('Runtime.evaluate',
            { expression: expr, returnByValue: true }, this.sessionId);
        if (r.exceptionDetails) throw new Error(`eval threw: ${r.exceptionDetails.text} in ${expr}`);
        return r.result ? r.result.value : undefined;
    }
    async waitFor(expr, ms = 5000, poll = 100) {
        const guarded = `(function(){try{return !!(${expr})}catch(_){return false}})()`;
        const deadline = Date.now() + ms;
        for (;;) {
            if (await this.eval(guarded)) return true;
            if (Date.now() >= deadline) return false;
            await sleep(poll);
        }
    }
    async navigate(url) {
        this.consoleLines.length = 0;
        this.navState.url = url;
        await this.cdp.send('Page.navigate', { url }, this.sessionId);
    }
    // Center of the element's VISIBLE portion: a full-height handle's raw center sits far below the
    // viewport, and a click there hits nothing.
    async center(selector) {
        const box = await this.eval(`(function(){
            const el = document.querySelector(${JSON.stringify(selector)});
            if (!el) return null;
            el.scrollIntoView({ block: 'center' });
            const r = el.getBoundingClientRect();
            const x0 = Math.max(r.left, 0), x1 = Math.min(r.right, window.innerWidth);
            const y0 = Math.max(r.top, 0), y1 = Math.min(r.bottom, window.innerHeight);
            if (x1 <= x0 || y1 <= y0) return { x: -1, y: -1 };
            return { x: (x0 + x1) / 2, y: (y0 + y1) / 2 };
        })()`);
        if (!box) throw new Error(`no element: ${selector}`);
        if (box.x < 0) throw new Error(`element not visible in viewport: ${selector}`);
        return box;
    }
    // Real mouse click: Chrome synthesizes the pointer events and the bubble path the ziex body
    // delegate depends on, which a synthetic el.click() would shortcut.
    async click(selector) {
        const { x, y } = await this.center(selector);
        const base = { x, y, button: 'left', clickCount: 1, pointerType: 'mouse' };
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base }, this.sessionId);
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base }, this.sessionId);
    }
    async drag(selector, dx) {
        const { x, y } = await this.center(selector);
        const b = { button: 'left', clickCount: 1, pointerType: 'mouse' };
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, ...b }, this.sessionId);
        const steps = 8;
        for (let i = 1; i <= steps; i++) {
            await this.cdp.send('Input.dispatchMouseEvent',
                { type: 'mouseMoved', x: x + (dx * i) / steps, y, ...b }, this.sessionId);
            await sleep(20);
        }
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x + dx, y, ...b }, this.sessionId);
    }
    async focus(selector) {
        await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`);
    }
    async insertText(text) {
        await this.cdp.send('Input.insertText', { text }, this.sessionId);
    }
    sawConsole(needle) {
        return this.consoleLines.some((l) => l.includes(needle));
    }
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    const profile = mkdtempSync(join(tmpdir(), 'st-interact-'));
    const child = launchChrome(profile);
    let ws = null;
    let cleaned = false;
    const cleanup = () => {
        if (cleaned) return;
        cleaned = true;
        try { if (ws) ws.close(); } catch (_) { /* already closed */ }
        try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* already gone */ }
        try { rmSync(profile, { recursive: true, force: true }); } catch (_) { /* best effort */ }
    };
    const watchdog = setTimeout(() => {
        process.stderr.write(`interactions.mjs: HARD TIMEOUT after ${args.timeout}ms, forcing exit\n`);
        cleanup();
        process.exit(2);
    }, args.timeout);
    // External termination (ctrl-c, a wrapper's kill) must still reap chrome + the temp profile.
    for (const sig of ['SIGINT', 'SIGTERM']) {
        process.on(sig, () => { cleanup(); process.exit(130); });
    }

    let mustRows = 0;
    let mustFails = 0;

    // A dead server is the failure that looks like a slow one: every later row waits on a socket
    // nobody will answer, and the run reads as still-going until the watchdog finally fires. Name it
    // instead, with the row it died after, so the next reader is not left guessing.
    let lastRowSeen = '(before the first row)';
    let serverMisses = 0;
    const heartbeat = setInterval(async () => {
        try {
            const res = await fetch(`${args.base}/dev/state`, { signal: AbortSignal.timeout(4000) });
            if (!res.ok) throw new Error(`status ${res.status}`);
            serverMisses = 0;
        } catch (err) {
            serverMisses += 1;
            if (serverMisses < 3) return;
            process.stderr.write(`interactions.mjs: the mock server stopped answering (${err.message}); `
                + `last row was ${lastRowSeen}. The suite outliving its server is the usual cause.\n`);
            clearInterval(heartbeat);
            cleanup();
            process.exit(3);
        }
    }, 5000);
    heartbeat.unref();
    let pendingRows = 0;
    let pendingPasses = 0;
    const row = (kind, ok, label, detail) => {
        lastRowSeen = label;
        let tag;
        if (kind === 'must') {
            mustRows += 1;
            tag = ok ? 'ok      ' : 'FAIL    ';
            if (!ok) mustFails += 1;
        } else {
            pendingRows += 1;
            tag = ok ? 'PENDPASS' : 'pending ';
            if (ok) pendingPasses += 1;
        }
        console.log(`  ${tag}${label.padEnd(58)} ${detail ?? ''}`);
    };

    try {
        const port = await readDebugPort(profile, child, Date.now() + 15000);
        const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
        ws = await openWs(ver.webSocketDebuggerUrl);
        const cdp = new CDP(ws);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Runtime.enable', {}, sessionId);

        // The [zx:dom] channel (the ziex door and the glue). ANOMALIES are emitted whatever the flag
        // says (console.error); TRACES only while __zx_debug is on (console.debug). Both logs are
        // run-wide and are never cleared, unlike consoleLines: C-DBG-8 is a tripwire over the WHOLE
        // run, and the rows that need one load's worth take a window by index. navState stamps each
        // entry with the page that was loaded, so a future anomaly names the load that produced it.
        const navState = { url: 'about:blank' };
        const zxAnomalies = [];
        const zxTraces = [];
        // Uncaught exceptions arrive on their own CDP channel, not as console output, so every row
        // that reads consoleAPICalled is blind to them. The crash this whole channel exists to catch
        // arrived exactly that way: a NotFoundError off a promise, which reaches no console.error and
        // carries no prefix. Watching only what the door chooses to say makes the door the sole
        // witness to its own failure.
        const pageExceptions = [];
        const ZX_PREFIX = '[zx:dom]';
        // The renderer's own channel. Watched because an anomaly channel with no listener is a diary
        // entry, not an announcement: the drain's pass-cap anomaly went here and NOTHING read it, so a
        // capped drain could drop a component's update and pass every row in this file.
        const ZX_RENDER_PREFIX = '[zx:render]';
        // This driver's own sensor self-test lines (C-DBG-1, C-DBG-2), never the product's. Every
        // product row below excludes them by this marker.
        const ZX_PROBE = 'ST-SENSOR-PROBE';
        const consoleLines = [];
        cdp.onEvent = (msg) => {
            // A native dialog BLOCKS the renderer, so every later CDP call waits forever and the run
            // reads as slow rather than stuck. Dismiss it and name the row that opened it: a row that
            // forgot to stub confirm/prompt should fail loudly, never hang the suite.
            if (msg.method === 'Page.javascriptDialogOpening' && msg.sessionId === sessionId) {
                process.stderr.write(`interactions.mjs: a native ${msg.params.type} dialog opened after `
                    + `${lastRowSeen} (${JSON.stringify(msg.params.message)}); dismissing it. `
                    + `Stub window.confirm/prompt before the click that opens it.\n`);
                cdp.send('Page.handleJavaScriptDialog', { accept: true }, sessionId).catch(() => {});
                return;
            }
            if (msg.method === 'Runtime.consoleAPICalled' && msg.sessionId === sessionId) {
                const line = (msg.params.args || [])
                    .map((a) => (a.value !== undefined ? String(a.value) : (a.description || '')))
                    .join(' ');
                consoleLines.push(line);
                // Sorted by CDP type, not by the emitter's intent: anything carrying the prefix that
                // is NOT an error is treated as a trace, so a trace mistakenly sent to console.log or
                // console.warn still trips the leak row instead of slipping past a debug-only filter.
                if (line.includes(ZX_PREFIX) || line.includes(ZX_RENDER_PREFIX)) {
                    const entry = { type: msg.params.type, text: line, url: navState.url };
                    // ...EXCEPT a line that calls itself an ANOMALY, which is one whatever level it
                    // came out at: the drain's pass-cap anomaly is emitted at log level, so type alone
                    // would file the loudest thing the renderer can say as a leaked trace.
                    const isAnomaly = msg.params.type === 'error' || line.includes('ANOMALY');
                    (isAnomaly ? zxAnomalies : zxTraces).push(entry);
                }
            }
            // Both flavours land here: a synchronous throw nobody caught, and a promise that rejected
            // with no handler ("Uncaught (in promise)"). The description carries the stack, so the row
            // can name the site rather than only the message.
            if (msg.method === 'Runtime.exceptionThrown' && msg.sessionId === sessionId) {
                const d = msg.params.exceptionDetails || {};
                const ex = d.exception || {};
                const text = [d.text, ex.description || ex.value].filter((s) => s !== undefined && s !== '').join(' ');
                pageExceptions.push({ text, url: navState.url });
            }
        };
        const page = new Page(cdp, sessionId, consoleLines, navState);
        const hydrated = "document.querySelector('#chat-root.hydrated')";
        // Boot shows the home landing now, not an auto-opened chat, so flows needing an open chat resume
        // first. Retry the click: resume-last needs the character store, which races the recent-list load.
        const openRecentChat = async () => {
            await page.waitFor(`${hydrated} && document.querySelector('#home-resume')`, 15000);
            const deadline = Date.now() + 15000;
            while (Date.now() < deadline) {
                await page.click('#home-resume');
                if (await page.waitFor("document.querySelectorAll('#chat .mes').length>=3", 2000)) return;
            }
            throw new Error('openRecentChat: no chat opened after resume-last');
        };

        // ---- Session A: demo fixtures + settings drawer + resize handles ----
        console.log('== session A: demo mode (?demo=1) ==');
        await page.navigate(`${args.base}/?demo=1`);
        row('must', await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=12`, 15000),
            'A1 boot: hydrated with 12 fixtures');

        // A1b exists because 338a06bb4 shipped a glue call to a wasm export nobody added, and every
        // gate stayed green: that call only throws at runtime, on a path one real upload reaches.
        // Call sites come from SOURCE (dist is minified, which renames the `wasm` local); the
        // denominator is the built module's OWN export table, because a source-side grep lies here:
        // __st_reader_stream_begin is a `pub export fn` in reader.zig, not in bridge.zig's comptime block.
        // Every glue file, not just custom.js: today it is the only one, so naming it would make this
        // denominator right by luck and silently blind to the second.
        const glueDir = join(dirname(fileURLToPath(import.meta.url)), 'glue');
        const glueSrc = readdirSync(glueDir).filter((f) => f.endsWith('.js'))
            .map((f) => readFileSync(join(glueDir, f), 'utf8')).join('\n');
        const calledExports = [...new Set([...glueSrc.matchAll(/wasm\.(__st_[a-zA-Z0-9_]+)/g)].map((m) => m[1]))].sort();
        await page.eval(`window.__wasm_exports = null; (async function(){
            try {
                const r = await fetch('/client/assets/_/main.wasm');
                const m = await WebAssembly.compile(await r.arrayBuffer());
                window.__wasm_exports = WebAssembly.Module.exports(m).map(function(e){return e.name;}).join(',');
            } catch (e) { window.__wasm_exports = 'FETCH-FAILED:' + e.message; }
        })();`);
        await page.waitFor('window.__wasm_exports !== null', 8000);
        const wasmExports = String(await page.eval('window.__wasm_exports'));
        const exportSet = new Set(wasmExports.split(','));
        const missingExports = calledExports.filter((n) => !exportSet.has(n));
        row('must', calledExports.length > 0 && !wasmExports.startsWith('FETCH-FAILED') && missingExports.length === 0,
            'A1b every wasm export the glue calls exists in the built module',
            `checked=${calledExports.length} missing=${missingExports.length ? missingExports.join(',') : 'none'}`);

        await page.click('#d-settings');
        row('must', await page.waitFor("document.querySelector('.settings-body')"),
            'A2 drawer opens the settings panel (plain zx handler)');

        await page.click('.seg-btn[data-reading-set="size"][data-reading-val="s"]');
        row('must', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-size')==='s'", 2500),
            'A3 reading Small sets data-reading-size on #chat-root');

        await page.click('.settings-tab[data-reading-val="appearance"]');
        row('must', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-tab')==='appearance'", 2500),
            'A4 settings tab switches to Appearance');

        // The motion buttons sit on the appearance tab, display:none until the tab handler sets
        // data-reading-tab, so A5a/A5b also prove A4 reached the DOM: a dead tab handler makes the
        // click itself unreachable (the element is not visible in the viewport) and both rows fail.
        let motionClicked = false;
        try {
            await page.click('[data-motion-set="on"]');
            motionClicked = true;
        } catch (_) { /* unreachable if the appearance panel never showed */ }
        row('must', motionClicked
            && await page.waitFor("document.getElementById('shell').classList.contains('motion-on')", 2500),
            'A5a motion On reaches the shell class (zx handler -> ui.selectMotion)');
        row('must', motionClicked
            && await page.waitFor("document.querySelector('[data-motion-set=\\'on\\']').getAttribute('aria-checked')==='true'", 2500),
            'A5b motion On updates the segmented highlight + aria-checked');

        const h0 = await page.eval("document.getElementById('send_textarea').clientHeight");
        await page.focus('#send_textarea');
        await page.insertText('one\ntwo\nthree\nfour');
        row('must', await page.waitFor(`document.getElementById('send_textarea').clientHeight > ${h0}`, 2500),
            'A6 composer auto-grows on input');

        // Close the settings drawer before the resize drag: the appearance tab's custom-CSS textarea
        // (C-COMP) overlays the chat area and would otherwise intercept the drag on the reading-width handle.
        await page.click('#d-settings');
        await page.waitFor("!document.querySelector('.settings-body')", 2500);
        await page.drag('.chat-resize', 80);
        row('must', await page.waitFor("document.getElementById('chat-root').style.getPropertyValue('--reading-measure') !== ''", 2500),
            'A7 reading-width handle drags (8198ddf22 regression row)');

        await page.click('#d-characters');
        row('must', await page.waitFor("document.querySelector('#panel-view.panel-right')"),
            'A8 characters dock opens on the right');
        const pw0 = await page.eval("document.querySelector('#panel-view.panel-right').getBoundingClientRect().width");
        await page.drag('#panel-view .panel-resize', -60);
        row('must', await page.waitFor(`Math.abs(document.querySelector('#panel-view.panel-right').getBoundingClientRect().width - ${pw0}) > 20`, 2500),
            'A9 side-panel handle drags the dock width (glue gesture -> Zig state)');

        // ---- Session B: mock backend, real boot path ----
        console.log('== session B: mock backend (no demo) ==');
        await page.navigate(`${args.base}/`);
        row('must', await page.waitFor(`${hydrated} && document.querySelector('#chat-home:not(.hidden)') && document.querySelectorAll('#chat .mes').length===0`, 15000)
            && !page.sawConsole('opened chat:'),
            'B1 boot shows the home landing, no chat auto-opened');

        await page.click('#d-characters');
        row('must', await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 60", 5000),
            'B2 characters dock lists the 60 mock characters');
        // S2 Zig-path proof: char_api.zig is the line's ONLY emitter (JS twin deleted, grep-gated).
        // Chosen over a 500-char injection row; B5/B6 already exercise scale + paging on this path.
        row('must', page.sawConsole('loaded 60 characters'),
            'B2b Zig data layer loaded the list ([st:chars] loaded 60 characters)');

        consoleLines.length = 0;
        await page.click('.char-item[data-char-select="5"] .char-name');
        const sawOpen5 = await (async () => {
            const deadline = Date.now() + 5000;
            while (Date.now() < deadline) {
                if (page.sawConsole('opened chat: Char 05')) return true;
                await sleep(100);
            }
            return false;
        })();
        row('must', sawOpen5, 'B3 row-child click opens the chat (9d12349a3 regression row)');

        await page.click('.char-fav-star[data-char-index="6"]');
        row('must', await page.waitFor("document.querySelector('.char-fav-star[data-char-index=\\'6\\']') && document.querySelector('.char-fav-star[data-char-index=\\'6\\']').textContent.trim()==='\\u2605'", 6000),
            'B4 fav star toggles and survives the refetch');

        // C-CHAR: page size is dropdown.zx now, not a native <select>, so this drives the real
        // gesture (open the listbox, click the option) instead of dispatching a synthetic change.
        // Row count, not the label: at page_size=0 the label already reads "1..60 of 60", so a label
        // predicate passes with a dead handler (critic finding).
        await page.click('[data-dd-toggle="char-pagesize"]');
        await page.waitFor("document.querySelector('#dd-list-char-pagesize')", 2500);
        await page.click('#dd-list-char-pagesize [data-dd-value="20"]');
        row('must', await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 20", 4000),
            'B5 page size dropdown paginates (delegated dropdown dispatch)');
        const label0 = await page.eval("document.querySelector('.char-page-label').textContent");
        await page.click('.char-pager [data-page="next"]');
        row('must', await page.waitFor(`document.querySelector('.char-page-label').textContent !== ${JSON.stringify(label0)}`, 2500),
            'B6 pagination next advances the page');

        await page.focus('.char-search');
        await page.insertText('rita');
        const filtered = await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 1", 4000);
        const kept = await page.eval("document.activeElement === document.querySelector('.char-search')");
        row('must', filtered && kept, 'B7 search filters and the input keeps focus', `filtered=${filtered} focus=${kept}`);

        // Keyboard parity on the still-filtered single row: focus + Enter opens the chat.
        consoleLines.length = 0;
        await page.eval("document.querySelector('#chat-root .char-item').focus()");
        await page.cdp.send('Input.dispatchKeyEvent',
            { type: 'rawKeyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 }, page.sessionId);
        await page.cdp.send('Input.dispatchKeyEvent',
            { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 }, page.sessionId);
        const sawKeyOpen = await (async () => {
            const deadline = Date.now() + 5000;
            while (Date.now() < deadline) {
                if (page.sawConsole('opened chat: Rita Recent')) return true;
                await sleep(100);
            }
            return false;
        })();
        row('must', sawKeyOpen, 'B8a Enter on a focused character row opens the chat');

        // ===== C-CHAR rows (character management 1c + a11y 1b) =====
        // The list is still filtered to "rita" here, so clear the search before asserting on order.
        await page.eval("(function(){const s=document.querySelector('.char-search'); s.value=''; s.dispatchEvent(new Event('input',{bubbles:true}));})()");
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 20", 4000);

        // Rita Recent carries the newest date_last_chat in the fixture, so the default sort puts her
        // first. A default of name_asc would head the list with "Char 00 Moon".
        row('must', await page.waitFor("document.querySelector('#chat-root .char-item .char-name').textContent.trim() === 'Rita Recent'", 3000)
            && await page.eval("document.querySelector('#dd-btn-char-sort span').textContent.trim()") === 'Recent',
            'C1 character list defaults to the most-recent sort');

        // The subtitle is metadata, not the card blurb: recency + chat volume, and the description
        // (which every fixture row carries) must be gone from the row entirely.
        const meta = await page.eval("document.querySelector('#chat-root .char-item .char-meta').textContent.replace(/\\s+/g,' ').trim()");
        const noDesc = await page.eval("!document.querySelector('#chat-root .char-item').textContent.includes('Mock character')");
        row('must', /ago|just now|\d{4}-\d{2}-\d{2}|No chats yet/.test(meta) && /KB|MB|B$|B\b/.test(meta) && noDesc,
            'C4 row subtitle is last-chat recency + chat volume, not the description', `meta=${JSON.stringify(meta)} noDesc=${noDesc}`);

        // The avatar filename holds spaces; the src must be percent-encoded (character_list.zx:67 bug).
        await page.click('[data-dd-toggle="char-pagesize"]');
        await page.click('#dd-list-char-pagesize [data-dd-value="all"]');
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 60", 4000);
        const spacedSrc = await page.eval("(document.querySelector('#chat-root .char-item[data-char-select=\"12\"] .char-avatar')||{getAttribute:()=>null}).getAttribute('src')");
        row('must', spacedSrc === '../thumbnail?type=avatar&file=Char%2012%20Spaced.png',
            'C5 avatar src percent-encodes a spaced filename', `src=${spacedSrc}`);

        // Sort pick through the styled dropdown, then the persistence contract: localStorage now, the
        // account blob through reading_prefs' one debounced saver.
        await page.click('[data-dd-toggle="char-sort"]');
        await page.waitFor("document.querySelector('#dd-list-char-sort')", 2500);
        await page.click('#dd-list-char-sort [data-dd-value="name_asc"]');
        const azFirst = await page.waitFor("document.querySelector('#chat-root .char-item .char-name').textContent.trim() === 'Char 00 Moon'", 3000);
        const azStored = await page.eval("localStorage.getItem('st-char-sort')");
        row('must', azFirst && azStored === 'name_asc',
            'C2 sort dropdown reorders the list and stores the pick', `stored=${azStored}`);

        // Keyboard parity (WD35-WD40): the sort dropdown opens and commits from the keyboard alone.
        await page.focus('#dd-btn-char-sort');
        for (const key of ['ArrowDown', 'ArrowDown', 'Enter']) {
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code: key, windowsVirtualKeyCode: key === 'Enter' ? 13 : 40 }, page.sessionId);
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key, windowsVirtualKeyCode: key === 'Enter' ? 13 : 40 }, page.sessionId);
            await sleep(120);
        }
        const kbSort = await page.eval("localStorage.getItem('st-char-sort')");
        row('must', kbSort !== null && kbSort !== 'name_asc',
            'C3 sort dropdown is operable by keyboard alone', `stored=${kbSort}`);

        // Escape aimed at an open dropdown closes the MENU only. ui.onPageKey dismisses the panel on
        // Escape and rides the same delegated keydown, so the menu's own Escape must consume it or
        // the dock goes with it. The click-path twin of this is ui.onPageClick's detached-target guard.
        await page.click('[data-dd-toggle="char-sort"]');
        await page.waitFor("document.querySelector('#dd-list-char-sort')", 2500);
        for (const type of ['rawKeyDown', 'keyUp']) {
            await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
        }
        const menuClosed = await page.waitFor("!document.querySelector('#dd-list-char-sort')", 2500);
        const panelAlive = await page.eval("!!document.querySelector('#panel-view') && !!document.querySelector('.char-toolbar')");
        row('must', menuClosed && panelAlive,
            'C9 Escape closes the dropdown without dismissing the panel', `menuClosed=${menuClosed} panelAlive=${panelAlive}`);

        // C-UI: C9 cannot tell WHICH guard saved the dock, because this toolbar stops the key itself;
        // its own line masks the component's. The half it cannot reach, that the dock survives a
        // consumer which never stops the key, is pinned on the demo island instead (C12), the one
        // root that discards onKey's result. C13 below is the other twin: the row that catches a
        // guard which fixes C9 by BREAKING the feature. With no menu open the panel MUST still close
        // on Escape, so ui.onPageKey standing down unconditionally, or nav.isOpenAny() stuck true,
        // passes C9 and C12 and still leaves the dock undismissable.
        const panelBeforeEsc = await page.eval("!!document.querySelector('#panel-view')");
        for (const type of ['rawKeyDown', 'keyUp']) {
            await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
        }
        const panelDismissed = await page.waitFor("!document.querySelector('#panel-view')", 2500);
        row('must', panelBeforeEsc && panelDismissed,
            'C13 Escape with no menu open still dismisses the panel', `wasOpen=${panelBeforeEsc} dismissed=${panelDismissed}`);
        await page.click('#d-characters');
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 60", 5000);

        // The pick survives a reload: the list opens on the stored sort, not the .recent default.
        await page.eval("localStorage.setItem('st-char-sort','name_desc')");
        await page.navigate(`${args.base}/`);
        await page.waitFor(hydrated, 15000);
        await page.click('#d-characters');
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 60", 5000);
        row('must', await page.waitFor("document.querySelector('#chat-root .char-item .char-name').textContent.trim() === 'Rita Recent' || document.querySelector('#chat-root .char-item .char-name').textContent.trim().startsWith('Char 59')", 3000)
            && await page.eval("document.querySelector('#dd-btn-char-sort span').textContent.trim()") === 'Z-A',
            'C6 a stored sort is applied on the next load');

        // Row-hover actions: every one is a real focusable button with its own accessible name, and
        // duplicate (the one with no native dialog in front of it) fires from the keyboard.
        const actNames = await page.eval("JSON.stringify(Array.from(document.querySelectorAll('#chat-root .char-item .char-row-act')).slice(0,4).map(b=>[b.tagName,b.getAttribute('aria-label')]))");
        row('must', /BUTTON/.test(actNames) && /Rename /.test(actNames) && /Delete /.test(actNames),
            'C7 row actions are named buttons carrying their character', `names=${actNames}`);

        await page.focus("#chat-root .char-item .char-row-act[data-char-action='duplicate']");
        const actFocused = await page.eval("document.activeElement.getAttribute('data-char-action')");
        // keyDown + text, not rawKeyDown: a native button's Enter-to-click is a DEFAULT ACTION, which
        // Chrome only runs for a key event carrying its text ('\r'). rawKeyDown suppresses it.
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', text: '\r', unmodifiedText: '\r', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 }, page.sessionId);
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 }, page.sessionId);
        const dup = await (async () => {
            const deadline = Date.now() + 5000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                if (st.duplicated_avatar) return st.duplicated_avatar;
                await sleep(150);
            }
            return null;
        })();
        row('must', actFocused === 'duplicate' && typeof dup === 'string' && dup.endsWith('.png'),
            'C8 Enter on a focused row action reaches char_api (duplicate)', `focused=${actFocused} dup=${dup}`);

        // Mirrors C-BG-5: pins the panel against the dismiss defect from the CLICK side (a row action
        // that ever rebuilt its own node would detach the target and read as an outside click).
        // The focus twin of the reveal. Its hover twin is C11 below, reachable since the gate started
        // declaring a fine, hover-capable pointer.
        await page.focus("#chat-root .char-item:nth-of-type(2) .char-row-act[data-char-action='duplicate']");
        await sleep(200);
        const revealed = await page.eval("(function(){const c=document.querySelectorAll('#chat-root .char-item')[1].querySelector('.char-row-actions');const s=getComputedStyle(c);return JSON.stringify({op:s.opacity, pe:s.pointerEvents})})()");
        await page.click("#chat-root .char-item:nth-of-type(2) .char-row-act[data-char-action='duplicate']");
        await sleep(400);
        const panelAliveClick = await page.eval("!!document.querySelector('#panel-view') && !!document.querySelector('.char-toolbar') && document.querySelectorAll('#chat-root .char-item').length > 0");
        row('must', JSON.parse(revealed).op === '1' && JSON.parse(revealed).pe === 'auto' && panelAliveClick,
            'C10 a revealed row action is clickable and the click keeps the panel open', `reveal=${revealed} panelAlive=${panelAliveClick}`);

        // The POINTER half, unreachable until the gate declared a hover-capable pointer. Asserts hidden
        // FIRST, so a rule that revealed unconditionally could not pass this.
        await page.eval("document.activeElement && document.activeElement.blur()");
        await sleep(200);
        const clusterSel = "document.querySelectorAll('#chat-root .char-item')[2].querySelector('.char-row-actions')";
        const hiddenBefore = await page.eval(`getComputedStyle(${clusterSel}).opacity === '0'`);
        const box = await page.eval(`(function(){const r=document.querySelectorAll('#chat-root .char-item')[2].getBoundingClientRect();return JSON.stringify({x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)})})()`);
        const { x, y } = JSON.parse(box);
        await page.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, buttons: 0 }, page.sessionId);
        const hoverRevealed = await page.waitFor(`getComputedStyle(${clusterSel}).opacity === '1'`, 3000);
        row('must', hiddenBefore && hoverRevealed,
            'C11 hovering a row reveals its actions (the pointer twin of C10)',
            `hiddenBefore=${hiddenBefore} revealed=${hoverRevealed}`);

        await page.click('#d-persona');
        row('must', await page.waitFor("document.querySelectorAll('#persona-list .char-item').length >= 2", 5000),
            'B8 persona dock lists the mock personas');
        await page.click('#persona-list .char-item[data-persona-index="1"] .char-name');
        row('must', await page.waitFor("document.querySelector('#persona-list .char-item[data-persona-index=\\'1\\']').classList.contains('is-selected')", 2500),
            'B9 persona row-child click selects the persona');

        await page.eval("localStorage.setItem('st-reading-size','s')");
        await page.navigate(`${args.base}/?demo=1`);
        await page.waitFor(hydrated, 15000);
        row('must', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-size')==='s'", 2500),
            'B10 persisted reading prefs re-apply at boot');

        // --- send-loop ---
        // Fresh boot loads the mock textgen connection and opens Rita Recent; the mock reply SSE runs
        // 24 tokens ("lantern" first, "FIN" only on completion) so a stop can land mid-stream.
        console.log('== send loop (mock textgen backend) ==');
        const idle = "!document.querySelector('#chat .mes[aria-busy=\\'true\\']')";

        // One send, proven to be THIS send: clear the recorded generate first, and key the wait on the
        // message COUNT, since a predicate looking for "FIN" matches the PREVIOUS send's and returns
        // before this one lands. Hoisted; two blocks held identical copies.
        const sendProbe = async (text) => {
            await (await fetch(`${args.base}/dev/clear-generate`)).json();
            const before = await page.eval("document.querySelectorAll('#chat .mes').length");
            await page.focus('#send_textarea');
            await page.insertText(text);
            await page.click('#composer button[aria-label="Send"]');
            const grew = await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${before} + 2 && ${idle}`, 15000);
            if (!grew) throw new Error(`sendProbe: no reply after "${text}"`);
        };
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        row('must', await page.waitFor("document.getElementById('d-connections') && document.getElementById('d-connections').dataset.connState === 'connected'", 8000),
            'SL-status shows the configured backend connected');

        const beforeSend = await page.eval("document.querySelectorAll('#chat .mes').length");
        await page.focus('#send_textarea');
        await page.insertText('SEND GATE PROBE');
        await page.click('#composer button[aria-label="Send"]');
        row('must', await page.waitFor("document.body.textContent.includes('SEND GATE PROBE')", 4000),
            'SL-user turn appears in the log on send');
        row('must', await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${beforeSend} + 2 && document.body.textContent.includes('lantern')`, 8000),
            'SL-assistant reply streams into a new message');
        // Let the first reply finish so the stream is idle before the next send.
        await page.waitFor(`document.body.textContent.includes('FIN') && ${idle}`, 8000);

        // SL-scroll: a send jumps to the bottom and pins the reply to follow, even from scrolled up.
        // Scroll to the top, send, and the sealed view must sit at the bottom (streamPinned forced).
        const scrollable = await page.eval("(function(){var c=document.getElementById('chat');return (c.scrollHeight - c.clientHeight) > 120;})()");
        await page.eval("document.getElementById('chat').scrollTop = 0");
        await sendProbe('SCROLL FOLLOW PROBE');
        const followedToBottom = await page.waitFor("(function(){var c=document.getElementById('chat');return (c.scrollHeight - c.scrollTop - c.clientHeight) < 80;})()", 3000);
        row('must', scrollable && followedToBottom, 'SL-send jumps to the bottom and the reply follows', `scrollable=${scrollable} atBottom=${followedToBottom}`);

        // SL-chip: scroll up mid-stream -> "New message" chip; scroll back to bottom -> hidden (reader.zig).
        // Own-send stream force-pins, so hold scrollTop=0 across ticks (sustained scroll) to beat the pinned tick.
        await page.focus('#send_textarea');
        await page.insertText('CHIP PROBE');
        await page.click('#composer button[aria-label="Send"]');
        await page.waitFor("(function(){var m=document.querySelectorAll('#chat .mes');return m.length && m[m.length-1].textContent.includes('lantern')})()", 8000);
        let chipShown = false;
        for (let i = 0; i < 14 && !chipShown; i++) {
            await page.eval("document.getElementById('chat').scrollTop = 0");
            chipShown = await page.eval("!!document.querySelector('.chat-newmsg-chip.is-visible')");
            await sleep(60);
        }
        const chipExists = await page.eval("!!document.querySelector('.chat-newmsg-chip')");
        await page.eval("(function(){var c=document.getElementById('chat');c.scrollTop = c.scrollHeight;})()");
        const chipHidBack = await page.waitFor("!document.querySelector('.chat-newmsg-chip.is-visible')", 3000);
        row('must', chipShown && chipHidBack, 'SL-chip shows scrolled-up mid-stream, hides back at the bottom', `exists=${chipExists} shown=${chipShown} hidBack=${chipHidBack}`);
        await page.waitFor(`document.body.textContent.includes('FIN') && ${idle}`, 8000);

        // STOP: send, wait for a few tokens, stop, assert the reply sealed PARTIAL (no FIN) and idle.
        await page.focus('#send_textarea');
        await page.insertText('STOP PROBE');
        await page.click('#composer button[aria-label="Send"]');
        await page.waitFor("(function(){var m=document.querySelectorAll('#chat .mes');return m.length && m[m.length-1].textContent.includes('w2')})()", 8000);
        await page.click('#composer button[aria-label="Stop"]');
        const stopped = await page.waitFor(`${idle} && (function(){var m=document.querySelectorAll('#chat .mes');var t=m[m.length-1].textContent;return t.includes('w2') && !t.includes('FIN')})()`, 5000);
        row('must', stopped, 'SL-stop seals the reply partial (no FIN) and returns to idle');

        // ENTER: Shift+Enter must NOT send (returns to insert a newline); a bare Enter sends.
        const beforeEnter = await page.eval("document.querySelectorAll('#chat .mes').length");
        await page.focus('#send_textarea');
        await page.insertText('ENTER PROBE');
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 8 }, page.sessionId);
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 8 }, page.sessionId);
        await sleep(500);
        const afterShift = await page.eval("document.querySelectorAll('#chat .mes').length");
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 0 }, page.sessionId);
        await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, modifiers: 0 }, page.sessionId);
        const enterSent = await page.waitFor(`document.body.textContent.includes('ENTER PROBE') && document.querySelectorAll('#chat .mes').length >= ${beforeEnter} + 2`, 8000);
        row('must', enterSent && afterShift === beforeEnter,
            'SL-Enter sends; Shift+Enter does not', `shift+enter=${afterShift} enter=${beforeEnter}->${enterSent}`);

        /* w3-reason BEGIN reasoning-block rows (3f) */
        console.log('== reasoning blocks (w3-reason) ==');
        // The mock reply streams "<th|ink>mull the tides|</th|ink>|lantern ..." so these rows prove
        // the mid-tag boundary split end to end, not just in the native unit tests.
        // The elements always exist (stable-diff shape); PRESENCE = wrapper not .mes_reasoning-empty,
        // OPEN = body not .mes_reasoning-closed.
        const lastReason = "#chat .chat-live .mes:last-child .mes_reasoning:not(.mes_reasoning-empty)";
        const lastReasonToggle = `${lastReason} .mes_reasoning_toggle`;
        const lastReasonOpenBody = `${lastReason} .mes_reasoning_body:not(.mes_reasoning-closed)`;
        const t1 = await page.waitFor(`document.querySelector('${lastReason}')`, 6000);
        const t2 = await page.eval(`!document.querySelector('${lastReasonOpenBody}')`);
        const t3 = await page.eval("!document.body.textContent.includes('mull the tides')");
        const r1ok = t1 && t2 && t3;
        row('must', r1ok, 'R1 streamed reply renders a collapsed reasoning block, body split clean', `shown=${t1} collapsed=${t2} noleak=${t3}`);
        if (r1ok) {
            await page.click(lastReasonToggle);
            row('must', await page.waitFor(`document.querySelector('${lastReasonOpenBody}') && document.querySelector('${lastReasonOpenBody}').textContent.includes('mull the tides') && document.querySelector('${lastReasonToggle}').getAttribute('aria-expanded')==='true'`, 3000),
                'R2 toggle expands the block and shows the split-out thinking');
            await page.click(lastReasonToggle);
            row('must', await page.waitFor(`!document.querySelector('${lastReasonOpenBody}') && document.querySelector('${lastReasonToggle}').getAttribute('aria-expanded')==='false'`, 3000),
                'R3 second toggle collapses the block again');
        } else {
            row('must', false, 'R2 toggle expands the block and shows the split-out thinking', 'skipped: R1 failed');
            row('must', false, 'R3 second toggle collapses the block again', 'skipped: R1 failed');
        }

        // Fresh load: the fixture's newest assistant HISTORY turn carries extra.reasoning.
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        row('must', await page.waitFor("document.querySelector('#chat .chat-history .mes .mes_reasoning:not(.mes_reasoning-empty)')", 6000),
            'R4 chat-load lifts extra.reasoning into a collapsed block');

        // Inline editor (replaces the old prompt): open it on the reasoning message, confirm it shows
        // the RAW markdown with live highlight, edit it, and save via the tick. The block must survive.
        // The trigger is opacity-0 until hover/focus, so a coordinate click flakes; fire its click
        // directly (the delegate resolves off event.target either way).
        const reasonTrigger = "#chat .mes:has(.mes_reasoning:not(.mes_reasoning-empty)) .msg-menu-trigger";
        let menuOpen = false;
        for (let attempt = 0; attempt < 3 && !menuOpen; attempt += 1) {
            await page.eval(`(function(){var m=document.querySelector('${reasonTrigger}'); if(m) m.click();})()`);
            menuOpen = await page.waitFor("document.querySelector('#msg-menu')", 3000);
        }
        let editorUp = false, rawShown = false, highlighted = false, roundTrip = false, r5ok = false;
        if (menuOpen) {
            // The popped menu can sit partly off-viewport (fixed + max-height), which makes a CDP
            // coordinate click miss; a real bubbling click event via el.click() reaches the delegate.
            await page.eval("(function(){var e=document.querySelector('#msg-menu [data-msg-action=\"edit\"]'); if(e) e.click();})()");
            editorUp = await page.waitFor("document.querySelector('.mes_edit_field') && document.querySelector('.mes_edit_field').getAttribute('contenteditable') === 'true'", 4000);
            // The field carries the raw source and the highlight has run (a .md-line per line).
            rawShown = await page.eval("(function(){var f=document.querySelector('.mes_edit_field'); return !!f && f.textContent.length > 0 && !!f.querySelector('.md-line');})()");
            // Type markdown with markers; the markers MUST stay in the text (round-trip) while it styles.
            await page.eval("(function(){var f=document.querySelector('.mes_edit_field'); if(!f) return; f.textContent='Edited **body**, reasoning kept.'; f.dispatchEvent(new Event('input',{bubbles:true}));})()");
            highlighted = await page.eval("!!document.querySelector('.mes_edit_field .md-bold')");
            roundTrip = await page.eval("(document.querySelector('.mes_edit_field')||{}).textContent === 'Edited **body**, reasoning kept.'");
            // Bubbling el.click(), not a CDP coordinate click: the inline save button can sit
            // off-viewport in a scrolled chat where a coordinate click misses (like the Edit/cancel above).
            await page.eval("(function(){var e=document.querySelector('.mes_edit_save'); if(e) e.click();})()");
            r5ok = await page.waitFor("(function(){var w=document.querySelector('#chat .mes .mes_reasoning:not(.mes_reasoning-empty)'); if(!w) return false; var mes=w.closest('.mes'); return mes.textContent.includes('Edited body, reasoning kept.')})()", 8000);
        }
        row('must', editorUp, 'R5a clicking Edit opens the inline live-markdown editor', `menu=${menuOpen} editor=${editorUp}`);
        row('must', rawShown, 'R5b the editor shows the raw markdown source with live highlight', `raw=${rawShown}`);
        row('must', highlighted && roundTrip, 'R5c highlight styles content while the markers stay in the saved text', `bold=${highlighted} roundtrip=${roundTrip}`);
        row('must', r5ok, 'R5 edit/save round-trip keeps the reasoning block on the edited message', `edited=${r5ok}`);

        // R5-cancel: reopen the editor, type, then discard with the cross. The box closes and the typed
        // text never reaches the message (cancel is pure client, no mutation).
        let cancelOk = false;
        let cancelMenu = false;
        for (let attempt = 0; attempt < 3 && !cancelMenu; attempt += 1) {
            await page.eval(`(function(){var m=document.querySelector('${reasonTrigger}'); if(m) m.click();})()`);
            cancelMenu = await page.waitFor("document.querySelector('#msg-menu')", 3000);
        }
        if (cancelMenu) {
            await page.eval("(function(){var e=document.querySelector('#msg-menu [data-msg-action=\"edit\"]'); if(e) e.click();})()");
            if (await page.waitFor("document.querySelector('.mes_edit_field')", 4000)) {
                await page.eval("(function(){var f=document.querySelector('.mes_edit_field'); if(f){ f.textContent='DISCARD-THIS-GATE'; f.dispatchEvent(new Event('input',{bubbles:true})); }})()");
                await page.eval("(function(){var e=document.querySelector('.mes_edit_cancel'); if(e) e.click();})()");
                cancelOk = await page.waitFor("!document.querySelector('.mes_edit_field') && !document.body.textContent.includes('DISCARD-THIS-GATE')", 4000);
            }
        }
        row('must', cancelOk, 'R5-cancel discards the edit and restores the body (no mutation)', `cancelled=${cancelOk}`);

        // --- tags (w3-reason 3d): manager create/assign persists via the settings blob; chips
        // filter on the card tags the 3d data fix made live. Rita Recent = char41.png.
        console.log('== tags (w3-reason 3d) ==');
        await page.click('#d-characters');
        await page.waitFor("document.querySelector('.char-toolbar')", 4000);
        await page.click('.char-toolbar button[aria-label="Manage tags"]');
        await page.waitFor("document.querySelector('.tag-manager')", 3000);
        await page.focus('#tag-create-name');
        await page.insertText('gatetag');
        await page.click('.tag-manager [data-tag-create]');
        row('must', await page.waitFor("Array.from(document.querySelectorAll('.tag-row-name')).some(function(n){return n.textContent==='gatetag'})", 3000),
            'T1 tag create adds a manager row');
        await page.click('.tag-manager [data-tag-assign="t-gatetag"]');
        row('must', await page.waitFor("(function(){var b=document.querySelector('.tag-manager [data-tag-assign=\\'t-gatetag\\']');return !!b && b.getAttribute('aria-pressed')==='true'})()", 3000),
            'T2 assign toggles pressed for the open character');
        let tagSaved = false;
        for (let i = 0; i < 20 && !tagSaved; i += 1) {
            await sleep(500);
            const st = await (await fetch(`${args.base}/dev/state`)).json();
            const ps = st.persona_settings || {};
            tagSaved = Array.isArray(ps.tags) && ps.tags.some((t) => t.name === 'gatetag')
                && ps.tag_map && Array.isArray(ps.tag_map['char41.png']) && ps.tag_map['char41.png'].includes('t-gatetag');
        }
        row('must', tagSaved, 'T3 tags + tag_map land in the settings blob via the one saver');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.click('#d-characters');
        await page.waitFor("document.querySelector('.char-toolbar')", 4000);
        await page.click('.char-toolbar button[aria-label="Manage tags"]');
        row('must', await page.waitFor("(function(){var b=document.querySelector('.tag-manager [data-tag-assign=\\'t-gatetag\\']');return !!b && b.getAttribute('aria-pressed')==='true'})()", 6000),
            'T4 created tag and assignment survive a reload (mined from the blob)');
        const chipRowsBefore = await page.eval("document.querySelectorAll('#chat-root .char-item').length");
        await page.click('.char-tags [data-tag="night"]');
        row('must', await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 6", 3000),
            'T5 filter chip narrows the list to the tagged cards', `before=${chipRowsBefore}`);
        await page.click('.char-tags [data-tag="night"]');
        await page.waitFor(`document.querySelectorAll('#chat-root .char-item').length === ${chipRowsBefore}`, 3000);
        /* w3-reason END reasoning + tag rows */

        // PERSIST: send, let the reply seal (user append on send + assistant append on seal), then
        // reload and prove both turns survive (the mock /get echoes the appended messages). Wait for
        // the ENTER-probe stream to seal first: Send is hidden while a reply streams (C-COMP toggle).
        await page.waitFor(`${idle}`, 8000);
        const beforePersist = await page.eval("document.querySelectorAll('#chat .mes').length");
        await page.focus('#send_textarea');
        await page.insertText('PERSIST PROBE');
        await page.click('#composer button[aria-label="Send"]');
        await page.waitFor(`${idle} && document.querySelectorAll('#chat .mes').length >= ${beforePersist} + 2`, 8000);
        let appends = { appended: [] };
        for (let i = 0; i < 40; i++) {
            appends = await (await fetch(`${args.base}/dev/state`)).json();
            const u = (appends.appended || []).some(m => m.is_user && m.mes === 'PERSIST PROBE');
            const a = (appends.appended || []).some(m => !m.is_user && m.mes.includes('lantern'));
            if (u && a) break;
            await sleep(150);
        }
        const gotUser = (appends.appended || []).some(m => m.is_user && m.mes === 'PERSIST PROBE');
        const gotAsst = (appends.appended || []).some(m => !m.is_user && m.mes.includes('lantern'));
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        const survived = await page.waitFor("document.body.textContent.includes('PERSIST PROBE')", 6000);
        row('must', gotUser && gotAsst && survived,
            'SL-send persists across a reload (user + assistant appended)', `user=${gotUser} asst=${gotAsst} reload=${survived}`);

        // ===== w3-grp: group send rotation (T0) =====
        // Real glue end to end: door export -> group_send -> per-member launches -> SSE -> group
        // appends; the mock's group window feeds member N the replies of members before it.
        console.log('== group send rotation (w3-grp, T0) ==');
        await page.waitFor(`${idle}`, 8000);
        const grpMembers = [
            { avatar: 'char01.png', name: 'Char 01 Vex' },
            { avatar: 'char02.png', name: 'Char 02 Vex' },
            { avatar: 'char03.png', name: 'Char 03 Moon' },
        ];
        const grpState0 = await (await fetch(`${args.base}/dev/state`)).json();
        const grpBase = (grpState0.group_appended || []).length;
        const grpDef = JSON.stringify({ chat_id: 'grp-gate', strategy: 1, members: grpMembers, text: 'GROUP ROTATION PROBE' });
        const beforeGrp = await page.eval("document.querySelectorAll('#chat .mes').length");
        const grpBegan = await page.eval(`window.__st_group_send(${JSON.stringify(grpDef)})`);
        row('must', grpBegan === 1, 'GRP-rotation begins via the door export', `ret=${grpBegan}`);
        const grpDone = await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${beforeGrp} + 4 && ${idle}`, 30000);
        row('must', grpDone, 'GRP-user turn + three member replies land in the log');

        // T0 exact sequence: the group file got user + Vex01 + Vex02 + Moon03 in order, correct
        // is_user flags, nothing dropped, nothing interleaved, and the solo append list untouched.
        let grpState = {};
        for (let i = 0; i < 60; i++) {
            grpState = await (await fetch(`${args.base}/dev/state`)).json();
            if ((grpState.group_appended || []).length >= grpBase + 4) break;
            await sleep(150);
        }
        const ga = (grpState.group_appended || []).slice(grpBase);
        const gaShape = ga.map(m => ({ n: m.name, u: m.is_user }));
        const grpExact = ga.length === 4
            && ga[0].is_user === true && ga[0].mes === 'GROUP ROTATION PROBE'
            && ga[1].is_user === false && ga[1].name === 'Char 01 Vex' && ga[1].mes.includes('FIN')
            && ga[2].is_user === false && ga[2].name === 'Char 02 Vex' && ga[2].mes.includes('FIN')
            && ga[3].is_user === false && ga[3].name === 'Char 03 Moon' && ga[3].mes.includes('FIN');
        const soloUntouched = (grpState.appended || []).every(m => m.mes !== 'GROUP ROTATION PROBE');
        row('must', grpExact && soloUntouched,
            'GRP-T0 exact persisted sequence: user + 3 replies in order, correct attribution, solo file untouched',
            JSON.stringify(gaShape));

        // Display attribution: the last three rows carry each member's own name and avatar.
        const grpDom = JSON.parse(await page.eval(
            "JSON.stringify([...document.querySelectorAll('#chat .mes')].slice(-3).map(e => ({ n: e.querySelector('.mes_name').textContent, a: (e.querySelector('.mes_avatar') || { src: '' }).src })))"));
        const grpDomOk = grpDom.length === 3
            && grpDom[0].n === 'Char 01 Vex' && grpDom[0].a.includes('char01')
            && grpDom[1].n === 'Char 02 Vex' && grpDom[1].a.includes('char02')
            && grpDom[2].n === 'Char 03 Moon' && grpDom[2].a.includes('char03');
        row('must', grpDomOk, 'GRP-each reply renders under its own member name + avatar', JSON.stringify(grpDom));

        // Invariant 2 + sequencing: the LAST generate (member 3) fetched the group window, so its
        // prompt must carry the user probe AND an earlier member's streamed reply.
        const grpPrompt = grpState.last_generate_prompt || '';
        row('must', grpPrompt.includes('GROUP ROTATION PROBE') && grpPrompt.includes('lantern'),
            'GRP-member 3 prompt spans the group window (user turn + earlier member replies)');

        // STOP: begin another rotation, stop mid-member-1; the partial seals with attribution, the
        // queue clears (append count settles at exactly user + 1 partial, no FIN, no member 2).
        await page.waitFor(`${idle}`, 8000);
        const grpStopBase = grpBase + 4;
        const grpDef2 = JSON.stringify({ chat_id: 'grp-gate', strategy: 1, members: grpMembers, text: 'GROUP STOP PROBE' });
        await page.eval(`window.__st_group_send(${JSON.stringify(grpDef2)})`);
        await page.waitFor("(function(){var m=document.querySelectorAll('#chat .mes');return m.length && m[m.length-1].textContent.includes('w2')})()", 8000);
        await page.click('#composer button[aria-label="Stop"]');
        const grpStopped = await page.waitFor(`${idle}`, 8000);
        await sleep(2000);
        const grpState2 = await (await fetch(`${args.base}/dev/state`)).json();
        const ga2 = (grpState2.group_appended || []).slice(grpStopBase);
        const grpStopExact = ga2.length === 2
            && ga2[0].is_user === true && ga2[0].mes === 'GROUP STOP PROBE'
            && ga2[1].is_user === false && ga2[1].name === 'Char 01 Vex' && !ga2[1].mes.includes('FIN');
        row('must', grpStopped && grpStopExact,
            'GRP-stop seals the current member partial and clears the queue (no member 2 launch)',
            JSON.stringify(ga2.map(m => ({ n: m.name, u: m.is_user, fin: String(m.mes).includes('FIN') }))));
        // ===== end w3-grp =====

        // --- connection ---
        // /dev/state is the mock's node-side readback of what the client persisted and last generated with.
        console.log('== connection setup (server-persisted) ==');
        const connUrl = 'http://127.0.0.1:9099';
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.click('#d-connections');
        await page.waitFor("document.getElementById('llama-url')", 4000);
        await page.eval("document.getElementById('llama-url').value=''");
        await page.focus('#llama-url');
        await page.insertText(connUrl);
        await page.click('.conn-connect');
        row('must', await page.waitFor("document.getElementById('conn-status').textContent.includes('Connected')", 6000),
            'CONN-connect probes and shows Connected + model');
        const persisted = await (await fetch(`${args.base}/dev/state`)).json();
        row('must', !!(persisted.recorded_connection && persisted.recorded_connection.api_server === connUrl && persisted.recorded_connection.api_type === 'llamacpp'),
            'CONN-persisted via set-connection merge', JSON.stringify(persisted.recorded_connection));
        // Close the drawer (click the composer, outside the panel), then send.
        await page.click('#send_textarea');
        await page.waitFor("!document.querySelector('#panel-view')", 3000);
        await page.focus('#send_textarea');
        await page.insertText('CONN SEND');
        await page.click('#composer button[aria-label="Send"]');
        // Poll for the generate to land: persisted history already shows "lantern", so a DOM check
        // would pass before this send's request reaches the mock.
        let used = { last_generate_server: null };
        for (let i = 0; i < 40; i++) {
            used = await (await fetch(`${args.base}/dev/state`)).json();
            if (used.last_generate_server === connUrl) break;
            await sleep(150);
        }
        row('must', used.last_generate_server === connUrl,
            'CONN-send uses the persisted server in the generate body', used.last_generate_server);
        // A1: the card's own system_prompt overrides the global, its {{original}} expands to the global
        // content, and it reaches the prompt. The system prompt went out EMPTY on every send pre-fix.
        const genPrompt = used.last_generate_prompt || '';
        row('must', genPrompt.includes('CARD SAYS') && genPrompt.includes('SYSPROMPT PROBE'),
            'A1 card system_prompt overrides global and {{original}} expands',
            `len=${genPrompt.length} deepPersona=${genPrompt.includes('curious and warm')} card=${genPrompt.includes('CARD SAYS')} global=${genPrompt.includes('SYSPROMPT PROBE')}`);
        // Jailbreak (post_history_instructions): a user turn after the history, macros resolved.
        row('must', genPrompt.includes('JB PROBE reply as ') && !genPrompt.includes('JB PROBE reply as {{char}}'),
            'A1 jailbreak reaches the prompt with macros resolved',
            `jb=${genPrompt.includes('JB PROBE reply as ')} unresolved=${genPrompt.includes('reply as {{char}}')}`);
        // Character depth note (data.extensions.depth_prompt) injected at its depth.
        row('must', genPrompt.includes('keep the lamp burning'),
            'A1 character depth note reaches the prompt', `note=${genPrompt.includes('keep the lamp burning')}`);

        // Deterministic form of the CONN-* flake: force a settings re-render while a URL is half-typed
        // and assert it survives. Reverting connection.urlFieldValue to activeServerUrl reddens this.
        console.log('== connection url sticky ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.click('#d-connections');
        await page.waitFor("document.getElementById('llama-url')", 4000);
        await page.eval("document.getElementById('llama-url').value=''");
        await page.focus('#llama-url');
        const stickyUrl = 'http://127.0.0.1:9077';
        await page.insertText(stickyUrl);
        await fetch(`${args.base}/dev/emit-event?type=settings-changed&data=${encodeURIComponent(JSON.stringify({ source: 'sticky' }))}`);
        await sleep(1400);
        const stickyAfter = await page.eval("document.getElementById('llama-url').value");
        row('must', stickyAfter === stickyUrl,
            'CONN-URL-STICKY a live settings event does not overwrite a URL being typed', `url=${stickyAfter}`);

        // --- append-409 ---
        // A "409:" message makes the mock append 409; asserted via observable state (mock counters +
        // store reset), not console lines, which are fragile after many prior sends.
        console.log('== append 409 resync ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        // Wait for the connection to load, else the send is a no-op (conn null) and never appends.
        await page.waitFor("document.getElementById('d-connections') && document.getElementById('d-connections').dataset.connState === 'connected'", 8000);
        const st0 = await (await fetch(`${args.base}/dev/state`)).json();
        await page.focus('#send_textarea');
        await page.insertText('409: force a resync');
        await page.click('#composer button[aria-label="Send"]');
        // Resync is observable: the mock returned a 409 (append_409_count up), the reader re-fetched the
        // tail (get_count up), and the un-persisted "409:" turn was dropped from the store.
        const resynced = await (async () => {
            const deadline = Date.now() + 12000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                const dropped = !(await page.eval("document.body.textContent.includes('409: force a resync')"));
                if (st.append_409_count > st0.append_409_count && st.get_count > st0.get_count && dropped) return true;
                await sleep(150);
            }
            return false;
        })();
        row('must', resynced, 'SL-append 409 re-syncs the reader to the tail', `resync=${resynced}`);

        // A history-prefetch 409 (external write above the window) must PRESERVE a scrolled-up reader's
        // place, not tail-jump. Arm the mock to 409 the next prepend GET, scroll up to fire it, then assert.
        console.log('== prefetch 409 preserves scroll ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor("document.getElementById('d-connections') && document.getElementById('d-connections').dataset.connState === 'connected'", 8000);
        const pf0 = await (await fetch(`${args.base}/dev/state`)).json();
        await fetch(`${args.base}/dev/arm-get-409`);
        // Scroll to the top (fires the armed prepend GET) and capture the top-most on-screen anchor's
        // abs index (mirrors readerAnchorMes), so the assertion proves THAT specific row survives.
        const capturedIdx = await page.eval(`(function(){
            var c = document.getElementById('chat');
            c.scrollTop = 0;
            var mes = c.querySelectorAll('.mes[data-abs-index]');
            var top = c.getBoundingClientRect().top;
            for (var i = 0; i < mes.length; i++) { if (mes[i].getBoundingClientRect().bottom > top + 1) return parseInt(mes[i].getAttribute('data-abs-index'), 10); }
            return mes.length ? parseInt(mes[mes.length - 1].getAttribute('data-abs-index'), 10) : -1;
        })()`);
        // Preserved shows as: armed 409 fired (get_409_count up), resync reload landed (get_count +2), and
        // the reader settled scrolled up (not top, not bottom) with the CAPTURED anchor row still present.
        const preserved = await (async () => {
            const notBottom = "(function(){var c=document.getElementById('chat');return c.scrollTop + c.clientHeight < c.scrollHeight - 80;})()";
            const notTop = "document.getElementById('chat').scrollTop > 200";
            const anchorSurvived = `!!document.querySelector('#chat .mes[data-abs-index="${capturedIdx}"]')`;
            const deadline = Date.now() + 12000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                if (st.get_409_count === pf0.get_409_count) {
                    // The prepend has not fired yet (reader tail still settling); nudge the scroll again.
                    await page.eval("document.getElementById('chat').scrollTop = 0");
                    await sleep(150);
                    continue;
                }
                if (st.get_count > pf0.get_count + 1 &&
                    await page.eval(notBottom) && await page.eval(notTop) && await page.eval(anchorSurvived)) return true;
                await sleep(150);
            }
            return false;
        })();
        row('must', capturedIdx >= 0 && preserved, "SL-prefetch 409 preserves a scrolled-up reader's position",
            `anchor=${capturedIdx} preserved=${preserved}`);

        // ================= J1: generation window (invariant 2) + connection prefill =================
        // PREFILL: a fresh boot re-mines the mock settings blob (server 5001); the connections panel
        // input must show that configured server, not the placeholder default.
        console.log('== J1 connection prefill ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.click('#d-connections');
        await page.waitFor("document.getElementById('llama-url')", 4000);
        const prefill = await page.eval("document.getElementById('llama-url').value");
        row('must', prefill === 'http://127.0.0.1:5001',
            'J1 connections panel prefills the configured server url', prefill);

        // INVARIANT 2: the mock chat is 300 messages, the reader shows only the tail (TAIL_LIMIT=50),
        // so "History message 150" is below the display floor. The prompt must contain it (fetched from
        // the spine) while the display must not: the prompt window is not bounded by what is on screen.
        console.log('== J1 invariant 2: prompt window exceeds the display window ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor("document.getElementById('d-connections') && document.getElementById('d-connections').dataset.connState === 'connected'", 8000);
        const displayHas150 = await page.eval("document.body.textContent.includes('History message 150')");
        await page.focus('#send_textarea');
        await page.insertText('INV2 PROBE');
        await page.click('#composer button[aria-label="Send"]');
        let gen = { last_generate_prompt: null };
        for (let i = 0; i < 40; i++) {
            gen = await (await fetch(`${args.base}/dev/state`)).json();
            if (gen.last_generate_prompt && gen.last_generate_prompt.includes('INV2 PROBE')) break;
            await sleep(150);
        }
        const promptText = gen.last_generate_prompt || '';
        const promptHas150 = promptText.includes('History message 150');
        const promptHasProbe = promptText.includes('INV2 PROBE');
        row('must', promptHas150 && promptHasProbe && displayHas150 === false,
            'J1 prompt window spans history beyond the display tail',
            `promptHas150=${promptHas150} displayHas150=${displayHas150} probe=${promptHasProbe}`);

        // ===== UNDO C4 (append-only) =====
        // Dangerous property: index 1 and its twin at 3 both read "gutters"; restoring 1 changes only 1.
        console.log('== undo: per-message version history + snapshot overlay ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();

        // Open the undo fixture chat by search (kept oldest so it never auto-opens).
        await page.click('#d-characters');
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 60", 5000);
        await page.focus('.char-search');
        await page.insertText('Char 00');
        await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 1", 4000);
        consoleLines.length = 0;
        await page.click('#chat-root .char-item .char-name');
        const undoOpened = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                if (page.sawConsole('opened chat: Char 00 Moon')
                    && await page.eval("document.querySelectorAll('#chat .mes_text').length === 4")) return true;
                await sleep(100);
            }
            return false;
        })();
        row('must', undoOpened, 'UNDO-1 undo fixture chat opens with its four messages');

        // The two identical twins start identical.
        const twinsBefore = await page.eval(
            "(function(){const t=document.querySelectorAll('#chat .mes_text');"
            + "return t[1].textContent.includes('gutters') && t[3].textContent.includes('gutters');})()");
        row('must', twinsBefore, 'UNDO-2 message 1 and its twin at 3 both read "gutters" before restore');

        // Close the character dock so the message controls are unobstructed, then open message 1's
        // action menu and pick Earlier versions (the history control now lives inside that menu).
        await page.click('#d-characters');
        await page.click('[data-msg-menu="1"]');
        await page.waitFor("document.querySelector('#msg-menu [data-undo-history=\\'1\\']')", 4000);
        await page.click("#msg-menu [data-undo-history='1']");
        const popover = await page.waitFor(
            "document.querySelector('#undo-surface [data-undo-restore][data-undo-kind=\\'version\\']')", 6000);
        row('must', popover, 'UNDO-3 the message menu Earlier-versions action opens the version popover');

        const stU0 = await (await fetch(`${args.base}/dev/state`)).json();
        await page.click("#undo-surface [data-undo-restore][data-undo-kind='version']");
        // The restore mutates only index 1; the reader resyncs and the DOM reflects it. Index 3 (the
        // identical twin) must be unchanged: this is the dangerous-property assertion.
        const restored = await (async () => {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
                const ok = await page.eval(
                    "(function(){const t=document.querySelectorAll('#chat .mes_text');"
                    + "return t.length===4 && t[1].textContent.includes('flares') && t[3].textContent.includes('gutters');})()");
                if (ok) return true;
                await sleep(150);
            }
            return false;
        })();
        const stU1 = await (await fetch(`${args.base}/dev/state`)).json();
        row('must', restored, 'UNDO-4 restoring message 1 changes only its text ("flares"), twin at 3 unchanged');
        row('must', stU1.get_count > stU0.get_count, 'UNDO-5 the reader resynced after the restore', `get_count ${stU0.get_count}->${stU1.get_count}`);

        // The whole-chat snapshot overlay, surfaced from the composer snapshots button (relabelled
        // from "Options" to match what it opens; C-COMP).
        await page.click('#composer button[aria-label="Chat snapshots"]');
        const snapListed = await page.waitFor(
            "document.querySelector('#undo-surface [data-undo-restore][data-undo-kind=\\'snapshot\\']')", 6000);
        row('must', snapListed, 'UNDO-6 composer Options opens the snapshot overlay with a save point');

        const stU2 = await (await fetch(`${args.base}/dev/state`)).json();
        await page.click("#undo-surface [data-undo-restore][data-undo-kind='snapshot']");
        // "Resyncs the reader" must mean the READER came back, not that the server was asked: the
        // resync empties the store before refilling it, so a request-count row returns mid-gap.
        const snapRestored = await (async () => {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
                const closed = await page.eval("document.querySelector('#undo-surface') === null");
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                const readerBack = await page.eval(
                    "document.querySelectorAll('#chat .mes').length === 4 && !!document.querySelector('[data-msg-menu=\"0\"]')");
                if (closed && st.get_count > stU2.get_count && readerBack) return true;
                await sleep(150);
            }
            return false;
        })();
        row('must', snapRestored, 'UNDO-7 restoring a snapshot closes the overlay and resyncs the reader');

        // ===== C-MSG message action menu (append-only) =====
        console.log('== message actions: hover menu, copy, relocated history ==');
        const pressEscape = async () => {
            const k = { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 };
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...k }, page.sessionId);
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...k }, page.sessionId);
        };
        // Close via Escape on a focused trigger (both inside #chat, so the region keydown delegate
        // fires): clicking a background element is a moving target the fixed popup can cover.
        const closeMenu = async () => {
            if (await page.eval("!!document.querySelector('#msg-menu')")) {
                await page.focus('#chat .mes .msg-menu-trigger');
                await pressEscape();
                await page.waitFor("!document.querySelector('#msg-menu')", 3000);
            }
        };
        // Open deterministically: ensure closed first (a trigger click TOGGLES, so an already-open menu
        // would close on click), then click and confirm the popped list rendered.
        const openMenu = async (abs) => {
            await closeMenu();
            // Retry: a click on an opacity-0 trigger can miss, or toggle a residual menu shut. Ensure
            // closed and re-click until the popped list renders.
            for (let attempt = 0; attempt < 3; attempt++) {
                await page.click(`[data-msg-menu="${abs}"]`);
                if (await page.waitFor("document.querySelector('#msg-menu [role=\\'menuitem\\']')", 2500)) return true;
                await closeMenu();
            }
            return false;
        };
        // A mutation re-syncs the reader (one fresh /get, so get_count advances), and only then has the
        // client adopted the new full token. The NEXT mutation must wait for that or it 409s on a stale one.
        const waitResync = async (before) => {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
                const s = await (await fetch(`${args.base}/dev/state`)).json();
                if (s.get_count > before) return true;
                await sleep(100);
            }
            return false;
        };
        // Highest-abs base-file message (abs<300) in the loaded window, scrolled into view so its
        // content-visibility:auto trigger actually paints (an off-screen trigger is not, so a click misses).
        const pickBaseAbs = async () => {
            const abs = await page.eval(
                "(function(){const a=[...document.querySelectorAll('#chat .mes[data-abs-index]')]"
                + ".map(e=>parseInt(e.getAttribute('data-abs-index'),10)).filter(x=>x<300);"
                + "return a.length?Math.max(...a):-1;})()");
            if (abs >= 0) {
                await page.eval(`document.querySelector('[data-abs-index="${abs}"]').scrollIntoView({block:'center'})`);
                await sleep(400);
            }
            return abs;
        };

        // The trigger is chrome OUTSIDE the sanitized body (invariant 6) and hidden by default.
        const triggerChrome = await page.eval(
            "(function(){const t=[...document.querySelectorAll('#chat .mes .msg-menu-trigger')];"
            + "return t.length>=4 && t.every(el=>el.closest('.mes_text')===null)"
            + " && getComputedStyle(t[0]).opacity==='0';})()");
        row('must', triggerChrome, 'C-MSG trigger is hidden chrome outside the message body');

        // The trigger reveals when the message takes focus (the keyboard affordance; pointer hover
        // uses the same CSS reveal, gated to hover-capable pointers). waitFor polls past the 120ms fade.
        const hiddenByDefault = await page.eval(
            "getComputedStyle(document.querySelector('#chat .mes .msg-menu-trigger')).opacity==='0'");
        await page.focus('[data-msg-menu="0"]');
        const focusRevealed = await page.waitFor(
            "getComputedStyle(document.querySelector('[data-msg-menu=\\'0\\']')).opacity==='1'", 3000);
        row('must', hiddenByDefault && focusRevealed, 'C-MSG trigger hidden by default, revealed on message focus',
            `hidden=${hiddenByDefault} revealed=${focusRevealed}`);

        // C-UI: the POINTER half of that same reveal (.mes:hover .msg-menu-trigger), which no row
        // reached while the gate answered (hover: hover) false and the rule sat inert. Blur first and
        // assert hidden BEFORE the mouse arrives, so a rule that revealed unconditionally cannot pass.
        await page.eval("document.activeElement && document.activeElement.blur()");
        await sleep(200);
        const msgTrigSel = "document.querySelectorAll('#chat .mes')[0].querySelector('.msg-menu-trigger')";
        const msgHiddenBefore = await page.eval(`getComputedStyle(${msgTrigSel}).opacity === '0'`);
        const msgBox = await page.eval("(function(){const r=document.querySelectorAll('#chat .mes')[0].getBoundingClientRect();return JSON.stringify({x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)})})()");
        const msgPt = JSON.parse(msgBox);
        await page.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: msgPt.x, y: msgPt.y, buttons: 0 }, page.sessionId);
        const msgHoverRevealed = await page.waitFor(`getComputedStyle(${msgTrigSel}).opacity === '1'`, 3000);
        row('must', msgHiddenBefore && msgHoverRevealed,
            'C14 hovering a message reveals its menu trigger (the pointer twin of the focus reveal)',
            `hiddenBefore=${msgHiddenBefore} revealed=${msgHoverRevealed}`);
        await page.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 0, y: 0, buttons: 0 }, page.sessionId);

        // Click the trigger: the popped list renders at the region root (escaping the .mes paint
        // containment that would clip it), sized, inside the reader region, and horizontally in view.
        const menuOpened = await openMenu(0);
        const menuUnclipped = menuOpened && await page.eval(
            "(function(){const m=document.querySelector('#msg-menu');if(!m)return false;"
            + "const r=m.getBoundingClientRect();"
            + "return m.closest('.mes')===null && !!m.closest('#chat') && r.width>0 && r.height>0"
            + " && r.left>=0 && r.right<=window.innerWidth;})()");
        row('must', menuUnclipped, 'C-MSG menu opens at the region root, unclipped and in view');

        // Narrow viewport keeps the trigger shown at the top-right (touch has no hover).
        await closeMenu();
        const wideWidth = await page.eval('window.innerWidth');
        await page.cdp.send('Emulation.setDeviceMetricsOverride',
            { width: 600, height: 900, deviceScaleFactor: 1, mobile: false }, page.sessionId);
        const narrowShown = await page.waitFor(
            "(function(){const t=document.querySelector('#chat .mes .msg-menu-trigger');if(!t)return false;"
            + "const o=getComputedStyle(t).opacity;const mr=t.closest('.mes').getBoundingClientRect();"
            + "const r=t.getBoundingClientRect();return o!=='0' && r.right<=mr.right+2 && r.top<=mr.top+40;})()", 3000);
        await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
        // clearDeviceMetricsOverride RETURNS before the page has relaid out, and every later row
        // inherits the half-restored layout. That was the C-MSG copy flake, ~1 run in 3 for four
        // reporters: the copy row read the item's rect at 600px, the page snapped back to 1400 before
        // the mouse event dispatched, and the click landed where the menu no longer was
        // (clickLanded=0, copied=NEVER-CALLED, menu still open). Wait for the width to really return.
        const vpRestored = await page.waitFor(`window.innerWidth === ${wideWidth}`, 5000);
        row('must', narrowShown, 'C-MSG narrow viewport keeps the trigger inside the top-right');
        row('must', vpRestored, 'C-MSG the viewport override is fully restored before later rows run',
            `wide=${wideWidth} now=${await page.eval('window.innerWidth')}`);

        // Copy writes the message's own text to the clipboard (no endpoint, no history write).
        await page.eval("(function(){window.__copied=null;const s=(t)=>{window.__copied=t;return Promise.resolve();};"
            + "try{navigator.clipboard.writeText=s;}catch(e){Object.defineProperty(navigator,'clipboard',{value:{writeText:s},configurable:true});}})()");
        const msg0text = await page.eval("document.querySelectorAll('#chat .mes_text')[0].textContent.trim()");
        const copyMenuOpen = await openMenu(0);
        // clickLanded is what caught the flake above: it read 0, which ruled out every copyMessage
        // guard in one run. Keep it, so a recurrence still names its own half.
        await page.eval(`window.__clickHits = 0;
            (function(){ const el = document.querySelector("#msg-menu [data-msg-action='copy']");
              if (el) el.addEventListener('click', function(){ window.__clickHits++; }, true); })();`);
        if (copyMenuOpen) await page.click("#msg-menu [data-msg-action='copy']");
        const clickHits = await page.eval('window.__clickHits');
        const copied = await (async () => {
            const deadline = Date.now() + 3000;
            while (Date.now() < deadline) {
                const c = await page.eval("window.__copied");
                if (c != null) return c;
                await sleep(100);
            }
            return null;
        })();
        const copyOk = copyMenuOpen && copied != null && copied.trim().length > 0 && msg0text.length > 0
            && (copied.includes(msg0text.slice(0, 10)) || msg0text.includes(copied.trim().slice(0, 10)));
        // null (writeText never ran) and "" (it ran with empty text) are different failures; the old
        // report printed both as copied="", which is why this row read as a mystery when it flaked.
        row('must', copyOk, 'C-MSG copy writes the message text to the clipboard',
            `menuOpen=${copyMenuOpen} clickLanded=${clickHits} copied=${copied === null ? 'NEVER-CALLED' : JSON.stringify(copied.slice(0, 24))} msg0=${JSON.stringify(msg0text.slice(0, 16))}`);

        // The relocated history control: Earlier versions opens the version UI (undo.openVersionsFor).
        const verMenuOpen = await openMenu(1);
        if (verMenuOpen) await page.click("#msg-menu [data-undo-history='1']");
        const versionsOpened = verMenuOpen && await page.waitFor("document.querySelector('#undo-surface')", 6000);
        row('must', versionsOpened, 'C-MSG Earlier versions opens the version UI via undo.openVersionsFor');

        // ===== C-MSG-T0 mutation dangerous property (edit/delete while window_offset>0) =====
        // Rita is a 300-msg file shown as a ~50-msg tail: a store-relative index would hit + corrupt an above-window message.
        console.log('== message mutations (T0): edit/delete never touch above-window history ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=40`, 15000);
        await page.waitFor("document.querySelector('#chat .mes[data-abs-index]')", 6000);
        const mst0 = await (await fetch(`${args.base}/dev/state`)).json();
        const firstAbs = await pickBaseAbs();
        row('must', mst0.reader_total === 300 && firstAbs >= 200 && firstAbs < 300,
            'C-MSG-T0 reader opens windowed (tail of a 300-message file, window_offset>0)',
            `firstAbs=${firstAbs} readerTotal=${mst0.reader_total}`);

        // EDIT the topmost visible message via the inline editor. The edit must land at firstAbs
        // (server-probed by the exact absolute index) and leave index 0 untouched. A store-relative
        // index would miss firstAbs entirely.
        const editMenuOpen = await openMenu(firstAbs);
        const getBeforeEdit = (await (await fetch(`${args.base}/dev/state`)).json()).get_count;
        let editorOpened = false;
        if (editMenuOpen) {
            await page.eval("(function(){var e=document.querySelector('#msg-menu [data-msg-action=\"edit\"]'); if(e) e.click();})()");
            editorOpened = await page.waitFor("document.querySelector('.mes_edit_field')", 4000);
            if (editorOpened) {
                await page.eval("(function(){var f=document.querySelector('.mes_edit_field'); f.textContent='EDITED-BY-GATE-T0'; f.dispatchEvent(new Event('input',{bubbles:true}));})()");
                // el.click() (not a coordinate click): the save button sits off-viewport in the windowed
                // 300-msg reader, where a CDP coordinate click misses and the edit never lands.
                await page.eval("(function(){var e=document.querySelector('.mes_edit_save'); if(e) e.click();})()");
            }
        }
        const editLanded = editorOpened && await (async () => {
            const deadline = Date.now() + 12000;
            while (Date.now() < deadline) {
                const r = await (await fetch(`${args.base}/dev/reader-at?i=${firstAbs}`)).json();
                if (r.mes === 'EDITED-BY-GATE-T0') return true;
                await sleep(150);
            }
            return false;
        })();
        // Let the reader adopt the post-edit full token before the delete presents one.
        await waitResync(getBeforeEdit);
        const mst1 = await (await fetch(`${args.base}/dev/state`)).json();
        row('must', editLanded && mst1.reader_total === 300 && mst1.reader_above_probe === mst0.reader_above_probe,
            'C-MSG-T0 edit hits the absolute index; above-window history untouched',
            `landed=${editLanded} editor=${editorOpened} menu=${editMenuOpen} ft=${mst0.full_token}->${mst1.full_token} readerTotal=${mst1.reader_total}`);

        // DELETE the topmost visible message. reader base drops by one; index 0 must stay put.
        await page.eval("window.confirm = () => true;");
        const delAbs = await pickBaseAbs();
        const delMenuOpen = await openMenu(delAbs);
        if (delMenuOpen) await page.eval("(function(){var e=document.querySelector('#msg-menu [data-msg-action=\"delete\"]'); if(e) e.click();})()");
        const mst2 = delMenuOpen ? await (async () => {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                if (st.reader_total === 299) return st;
                await sleep(150);
            }
            return null;
        })() : null;
        row('must', mst2 != null && mst2.reader_above_probe === mst0.reader_above_probe,
            'C-MSG-T0 delete hits the absolute index; above-window history untouched',
            mst2 ? `readerTotal=${mst2.reader_total} aboveIntact=${mst2.reader_above_probe === mst0.reader_above_probe}` : 'reader base never dropped to 299');

        // ===== C-HOME (append-only): recent-chats home landing (list-first) =====
        console.log('== home: recent-chats landing ==');
        await page.navigate(`${args.base}/`);
        // Boot shows the landing (no auto-open) with the recent list: three character chats plus the
        // group chat (w3-grp: group rows list and open; the v1 filter is gone). The group row's name
        // falls back to the file stem ("Party") while the roster holds no such group.
        row('must', await page.waitFor(
            `${hydrated} && document.querySelector('#chat-home:not(.hidden)') && document.querySelectorAll('#chat-home .home-thread').length === 4`, 15000),
            'HOME-1 boot shows the home landing with all four recent chats (group row included)');
        const grpRowName = await page.eval(
            "(function(){var rows=document.querySelectorAll('#chat-home .home-thread');var last=rows[rows.length-1];return last?last.textContent:'';})()");
        row('must', grpRowName.includes('Party'),
            'HOME-6 the group recent row renders with a name, not blank (w3-grp)',
            `text=${JSON.stringify(grpRowName.slice(0, 60))}`);

        // The fixture's chats are 5 minutes, 3 hours and 4 days old, so "recently" is the NaN fallback
        // rather than a date, and a list whose parse fails for every row still looks populated.
        const whenTexts = await page.eval(
            "JSON.stringify(Array.from(document.querySelectorAll('#chat-home .home-thread time')).map(function(t){return t.textContent.trim();}))");
        const whens = JSON.parse(whenTexts);
        const datesReal = whens.length === 4 && whens.every((w) => /^(just now|\d+[mhd] ago|\d{4}-\d{2}-\d{2})$/.test(w));
        row('must', datesReal, 'HOME-5 a recent row dates the chat instead of falling back to "recently"',
            `when=${whenTexts}`);

        // A recent row opens that character's chat (loadCharacterChat) and the landing hides behind the log.
        consoleLines.length = 0;
        await page.click('#chat-home .home-thread');
        const homeOpened = await (async () => {
            const deadline = Date.now() + 6000;
            while (Date.now() < deadline) {
                if (page.sawConsole('opened chat: Rita Recent')
                    && await page.eval("!!document.querySelector('#chat-home.hidden')")) return true;
                await sleep(100);
            }
            return false;
        })();
        row('must', homeOpened, 'HOME-2 a recent row opens the chat and the landing hides');

        // Empty state: arm the mock to return [], reload, and prove the invite renders (not a spinner).
        await fetch(`${args.base}/dev/arm-recent-empty`);
        await page.navigate(`${args.base}/`);
        row('must', await page.waitFor(
            `${hydrated} && document.querySelector('#chat-home:not(.hidden)')`
            + ` && document.querySelectorAll('#chat-home .home-thread').length === 0`
            + ` && document.querySelector('#chat-home').textContent.includes('No conversations yet')`
            + ` && !document.querySelector('#chat-home [aria-busy=\\'true\\']')`, 15000),
            'HOME-3 empty recent list renders the invite, not a spinner-forever');

        // The explicit resume action opens the most recent chat even with an empty recent list.
        consoleLines.length = 0;
        await page.click('#home-resume');
        const resumed = await (async () => {
            const deadline = Date.now() + 6000;
            while (Date.now() < deadline) {
                if (page.sawConsole('resume last') && page.sawConsole('opened chat: Rita Recent')) return true;
                await sleep(100);
            }
            return false;
        })();
        row('must', resumed, 'HOME-4 the resume-last action opens the most recent chat');

        // ===== C-DROP (append-only) =====
        // The styled dropdown proven in isolation via its dev harness (?dropdemo=1 mounts a fixed island
        // whose region root delegates to dropdown.onClick/onKey). Asserts the onchange callback fired
        // (the readout changed) and the fixed panel is not clipped by the viewport.
        console.log('== dropdown: styled listbox component (dev harness) ==');
        await page.navigate(`${args.base}/?dropdemo=1`);
        await page.waitFor(`${hydrated} && document.getElementById('dropdown-demo')`, 15000);
        row('must', (await page.eval("document.getElementById('dd-demo-value').textContent")) === 'chatml',
            'C-DROP-1 demo island hydrates with the initial value');

        await page.click('#dd-btn-demo');
        const ddOpen = await page.waitFor(
            "document.querySelector('#dd-list-demo[role=\\'listbox\\']') && document.getElementById('dd-btn-demo').getAttribute('aria-expanded')==='true'", 4000);
        row('must', ddOpen, 'C-DROP-2 clicking the button opens the listbox (delegated onClick)');


        const ddClip = await page.eval(`(function(){
            var el = document.getElementById('dd-list-demo');
            if (!el) return null;
            var r = el.getBoundingClientRect();
            return { inView: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight, w: r.width, h: r.height };
        })()`);
        row('must', !!ddClip && ddClip.inView && ddClip.w > 0 && ddClip.h > 0,
            'C-DROP-3 the fixed panel is fully in the viewport (not clipped)', JSON.stringify(ddClip));

        // Keyboard: focus the button (open() already did), Down twice to the third option, Enter to pick.
        await page.eval("document.getElementById('dd-btn-demo').focus()");
        const press = async (key, code, vk) => {
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code, windowsVirtualKeyCode: vk }, page.sessionId);
            await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: vk }, page.sessionId);
        };
        await press('ArrowDown', 'ArrowDown', 40);
        await press('ArrowDown', 'ArrowDown', 40);
        await press('Enter', 'Enter', 13);
        const ddPicked = await page.waitFor("document.getElementById('dd-demo-value').textContent === 'mistral'", 4000);
        const ddClosed = await page.eval("document.getElementById('dd-list-demo') === null");
        const ddRefocus = await page.eval("document.activeElement === document.getElementById('dd-btn-demo')");
        row('must', ddPicked && ddClosed && ddRefocus,
            'C-DROP-4 keyboard select fires onchange, closes the menu, refocuses the button',
            `picked=${ddPicked} closed=${ddClosed} refocus=${ddRefocus}`);

        // C-UI: the demo root is the ONE consumer that discards onKey's result (`_ = dropdown.onKey`),
        // the exact shape that shipped the dock-eating bug, so it is the only place the component's
        // OWN stop is observable: every real panel stops the key itself and masks it (C9 cannot see
        // this). ziex delegates at <body>, so a key the dropdown stopped never reaches document.
        // Delete the stopPropagation in dropdown.onKey and this goes red while C9 stays green.
        await page.eval("window.__stEscAtDoc = 0; if (!window.__stEscProbe) { window.__stEscProbe = 1; document.addEventListener('keydown', function (e) { if (e.key === 'Escape') window.__stEscAtDoc++; }); }");
        await page.click('#dd-btn-demo');
        await page.waitFor("document.querySelector('#dd-list-demo')", 4000);
        await press('Escape', 'Escape', 27);
        const demoEscClosed = await page.waitFor("!document.querySelector('#dd-list-demo')", 2500);
        const escAtDoc = await page.eval('window.__stEscAtDoc');
        row('must', demoEscClosed && escAtDoc === 0,
            'C12 the dropdown stops the Escape it consumed, so a consumer that never stops it is safe',
            `menuClosed=${demoEscClosed} escapesReachingDocument=${escAtDoc}`);

        // The control: a key the dropdown does NOT consume still reaches the page, so C12 above is
        // measuring the stop and not a probe that never fires.
        await press('Escape', 'Escape', 27);
        const escAtDocClosed = await page.eval('window.__stEscAtDoc');
        row('must', escAtDocClosed === 1,
            'C15 an Escape with no menu open is left alone and reaches the page',
            `escapesReachingDocument=${escAtDocClosed}`);

        // ==================== C-COMP: composer polish + appearance ====================
        // Demo mode carries .mes_text bodies and the settings drawer, so the pad/width/invariant-6
        // rows run here; the toggle needs a real stream, so it navigates to the mock backend after.
        console.log('== C-COMP: composer polish + appearance (2d) ==');
        await page.navigate(`${args.base}/?demo=1`);
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=12`, 15000);

        // Bottom-pad: max(0.75rem, env(...)) resolves to 12px on desktop where the old env(..,0.75rem)
        // fallback resolved to 0 (the env var is defined as 0, so the fallback never applied).
        const padBottom = await page.eval("parseFloat(getComputedStyle(document.getElementById('composer')).paddingBottom)");
        row('must', padBottom >= 11.5, 'C-COMP composer bottom-pad nonzero on desktop', `${padBottom}px`);

        // Width: the composer inner tracks .chat-inner's reading column. At a bound measure both
        // border-boxes equal the measure, so their rendered widths match within a pixel.
        let widthOk = true;
        const widthDetail = [];
        for (const w of [400, 600, 800]) {
            await page.eval(`document.getElementById('chat-root').style.setProperty('--reading-measure','${w}px')`);
            await sleep(60);
            const m = await page.eval(`(function(){
                const c = document.querySelector('#composer > div').getBoundingClientRect().width;
                const i = document.querySelector('.chat-inner').getBoundingClientRect().width;
                return { c, i };
            })()`);
            if (!(Math.abs(m.c - m.i) < 1.5 && Math.abs(m.c - w) < 1.5)) widthOk = false;
            widthDetail.push(`${w}:c${m.c.toFixed(0)}/i${m.i.toFixed(0)}`);
        }
        await page.eval("document.getElementById('chat-root').style.removeProperty('--reading-measure')");
        row('must', widthOk, 'C-COMP composer tracks .chat-inner at 3 widths', widthDetail.join(' '));

        // Invariant 6: a custom rule targeting a chrome id AND the message body. The @scope wrap makes
        // .mes_text (the scope limit) unmatchable, so only the chrome outline lands. outline does not
        // inherit, so this is a clean subject-match test, not an inheritance artefact.
        await page.click('#d-settings');
        await page.waitFor("document.querySelector('.settings-body')", 5000);
        await page.click('.settings-tab[data-reading-val="appearance"]');
        await page.waitFor("document.getElementById('custom-css')", 3000);
        await page.focus('#custom-css');
        await page.insertText('#composer{outline:3px solid rgb(1,2,3)} .mes_text{outline:3px solid rgb(4,5,6)}');
        await sleep(250);
        const inv = await page.eval(`(function(){
            const comp = getComputedStyle(document.getElementById('composer')).outlineColor;
            const mt = document.querySelector('.mes_text');
            return { comp, body: mt ? getComputedStyle(mt).outlineColor : 'none', hasMt: !!mt };
        })()`);
        row('must', inv.hasMt && inv.comp === 'rgb(1, 2, 3)' && inv.body !== 'rgb(4, 5, 6)',
            'C-COMP invariant 6: custom CSS styles chrome, never the message body',
            `chrome=${inv.comp} body=${inv.body}`);
        // Clear the box through real input so its localStorage copy does not re-inject on the next nav.
        await page.eval("(function(){var t=document.getElementById('custom-css'); if(t){t.value=''; t.dispatchEvent(new Event('input',{bubbles:true}));}})()");
        await sleep(150);

        // Send/Stop toggle across a live generation: idle shows send, a streaming .mes (aria-busy)
        // flips the :has() rule to show stop. The mock textgen backend lives at base /; the home
        // landing no longer auto-opens (C-HOME), so open a recent chat before sending.
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        await page.waitFor("document.getElementById('d-connections') && document.getElementById('d-connections').dataset.connState === 'connected'", 8000);
        await page.waitFor(`${idle}`, 5000);
        const disp = (sel) => page.eval(`getComputedStyle(document.querySelector(${JSON.stringify(sel)})).display`);
        const idleSend = await disp('#composer .composer-send');
        const idleStop = await disp('#composer .composer-stop');
        await page.focus('#send_textarea');
        await page.insertText('TOGGLE PROBE');
        await page.click('#composer button[aria-label="Send"]');
        // Read the toggle atomically WHILE a .mes is aria-busy: the mock stream can seal between two
        // separate reads, so poll a single tick that requires streaming AND send-hidden AND stop-shown.
        const streamToggled = await page.waitFor(`(function(){
            if (!document.querySelector('#chat .mes[aria-busy=\\'true\\']')) return false;
            const send = getComputedStyle(document.querySelector('#composer .composer-send')).display;
            const stop = getComputedStyle(document.querySelector('#composer .composer-stop')).display;
            return send === 'none' && stop !== 'none';
        })()`, 8000);
        row('must',
            streamToggled && idleStop === 'none' && idleSend !== 'none',
            'C-COMP send/stop toggles on generation state',
            `idle send=${idleSend}/stop=${idleStop} streamToggled=${streamToggled}`);
        // Let the reply seal so teardown is clean.
        await page.waitFor("!document.querySelector('#chat .mes[aria-busy=\\'true\\']')", 8000);

        // ===== C-PERS (append-only): persona auto-select + remember-last + CRUD =====
        // The mock settings blob is mutable (settings/save round-trips), so a persist shows on the
        // next get. The "a b.png" persona proves the avatar-url encode fix; prompt/confirm are
        // monkeypatched so the CRUD dialogs are deterministic under headless Chrome. The home landing
        // no longer auto-opens (C-HOME), so open a recent chat after each nav to boot the session.
        console.log('== persona: auto-select, remember-last, CRUD ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        await page.click('#d-persona');
        await page.waitFor("document.querySelectorAll('#persona-list .char-item').length >= 3", 5000);

        const encoded = await page.eval(
            "Array.from(document.querySelectorAll('#persona-list img')).some(function(i){return (i.getAttribute('src')||'').indexOf('a%20b.png')>=0;})");
        const rawSpace = await page.eval(
            "Array.from(document.querySelectorAll('#persona-list img')).some(function(i){return (i.getAttribute('src')||'').indexOf('a b.png')>=0;})");
        row('must', encoded && !rawSpace, 'C-PERS-1 persona avatar url percent-encodes a spaced filename', `enc=${encoded} raw=${rawSpace}`);

        // Remember-last (non-vacuous): select persona 1 (differs from the boot auto-select), the
        // selection persists as user_avatar, and a reload auto-selects it again.
        await page.click('#persona-list .char-item[data-persona-index="1"] .char-name');
        await page.waitFor("document.querySelector('#persona-list .char-item[data-persona-index=\\'1\\']').classList.contains('is-selected')", 3000);
        const persistedSel = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                if (st.persona_settings && st.persona_settings.user_avatar === 'p2.png') return true;
                await sleep(150);
            }
            return false;
        })();
        await page.navigate(`${args.base}/`);
        await openRecentChat();
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        await page.click('#d-persona');
        await page.waitFor("document.querySelectorAll('#persona-list .char-item').length >= 3", 5000);
        const remembered = await page.waitFor("document.querySelector('#persona-list .char-item[data-persona-index=\\'1\\']').classList.contains('is-selected')", 3000);
        row('must', persistedSel && remembered, 'C-PERS-2 selection persists (user_avatar) and survives a reload', `persisted=${persistedSel} remembered=${remembered}`);

        // Set default: with persona 1 selected, set-default writes power_user.default_persona.
        await page.waitFor("document.querySelector('[data-persona-action=\\'set-default\\']')", 3000);
        await page.click('[data-persona-action="set-default"]');
        const defaultOk = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                const pu = st.persona_settings && st.persona_settings.power_user;
                if (pu && pu.default_persona === 'p2.png') return true;
                await sleep(150);
            }
            return false;
        })();
        row('must', defaultOk, 'C-PERS-3 set-default persists power_user.default_persona', `default=${defaultOk}`);

        // CRUD mutates the store for instant UI, then the change round-trips through reading_prefs's
        // one debounced saver (3s). Each row asserts BOTH the immediate DOM and the server state.
        const pollPersonas = async (pred) => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                const p = st.persona_settings && st.persona_settings.power_user && st.persona_settings.power_user.personas;
                if (p && pred(p)) return true;
                await sleep(150);
            }
            return false;
        };

        // Add: a monkeypatched prompt names the persona; the row appears at once and the save carries it.
        const before = await page.eval("document.querySelectorAll('#persona-list .char-item').length");
        await page.eval("window.prompt = function(){ return 'Zephyr'; }; window.confirm = function(){ return true; };");
        await page.click('[data-persona-action="add"]');
        const addedRow = await page.waitFor(
            `document.querySelectorAll('#persona-list .char-item').length === ${before} + 1 && document.querySelector('#persona-list .char-item[data-persona-index="${before}"] .char-name').textContent.trim() === 'Zephyr'`, 6000);
        const addedSaved = await pollPersonas((p) => Object.values(p).indexOf('Zephyr') >= 0);
        row('must', addedRow && addedSaved, 'C-PERS-4 add persona appends a row and round-trips to the server', `row=${addedRow} saved=${addedSaved}`);

        // Rename: select the new persona, rename it; the row updates and the save round-trips.
        await page.click(`#persona-list .char-item[data-persona-index="${before}"] .char-name`);
        await page.waitFor(`document.querySelector('#persona-list .char-item[data-persona-index="${before}"]').classList.contains('is-selected')`, 3000);
        await page.eval("window.prompt = function(){ return 'Zephyr II'; };");
        await page.waitFor("document.querySelector('[data-persona-action=\\'rename\\']')", 3000);
        await page.click('[data-persona-action="rename"]');
        const renamedRow = await page.waitFor(
            `document.querySelector('#persona-list .char-item[data-persona-index="${before}"] .char-name').textContent.trim() === 'Zephyr II'`, 6000);
        const renamedSaved = await pollPersonas((p) => Object.values(p).indexOf('Zephyr II') >= 0 && Object.values(p).indexOf('Zephyr') < 0);
        row('must', renamedRow && renamedSaved, 'C-PERS-5 rename updates the name and round-trips', `row=${renamedRow} saved=${renamedSaved}`);

        // Delete: select it, confirm; the row disappears and the removal round-trips (back to pre-add count).
        await page.click(`#persona-list .char-item[data-persona-index="${before}"] .char-name`);
        await page.waitFor(`document.querySelector('#persona-list .char-item[data-persona-index="${before}"]').classList.contains('is-selected')`, 3000);
        await page.waitFor("document.querySelector('[data-persona-action=\\'delete\\']')", 3000);
        await page.click('[data-persona-action="delete"]');
        const deletedRow = await page.waitFor(`document.querySelectorAll('#persona-list .char-item').length === ${before}`, 6000);
        const deletedSaved = await pollPersonas((p) => Object.keys(p).length === before && Object.values(p).indexOf('Zephyr II') < 0);
        row('must', deletedRow && deletedSaved, 'C-PERS-6 delete removes the persona and round-trips', `row=${deletedRow} saved=${deletedSaved}`);

        // ===== C-BG (append-only): backgrounds gallery, apply, persist, file actions =====
        // The mock gallery is mutable, so a delete/rename shows on the next /all: that is what makes
        // the two server-authoritative rows non-vacuous.
        console.log('== backgrounds: gallery, apply, persist, delete/rename ==');
        await page.navigate(`${args.base}/`);
        await page.waitFor(hydrated, 15000);
        await page.click('#d-backgrounds');

        // C-BG2 raised the fixture from 4 to 7: three of them carry shapes the old typed parse died on.
        const listed = await page.waitFor("document.querySelectorAll('#bg-gallery .bg-tile-wrap').length === 7", 8000);
        row('must', listed, 'C-BG-1 the gallery lists every background the server serves', `tiles=${await page.eval("document.querySelectorAll('#bg-gallery .bg-tile-wrap').length")}`);

        // The Wave-1 bug class: a space in a filename must reach the thumbnail url percent-encoded.
        const thumbEnc = await page.eval(
            "Array.from(document.querySelectorAll('#bg-gallery img')).some(function(i){return (i.getAttribute('src')||'').indexOf('file=a%20b.jpg')>=0;})");
        const thumbRaw = await page.eval(
            "Array.from(document.querySelectorAll('#bg-gallery img')).some(function(i){return (i.getAttribute('src')||'').indexOf('file=a b.jpg')>=0;})");
        row('must', thumbEnc && !thumbRaw, 'C-BG-2 the tile thumbnail url percent-encodes a spaced filename', `enc=${thumbEnc} raw=${thumbRaw}`);

        const gifBadge = await page.eval(
            "!!document.querySelector('#bg-gallery [data-bg-file=\\'loop.webp\\']') && Array.from(document.querySelectorAll('#bg-gallery .bg-tile-wrap')).some(function(w){return w.querySelector('[data-bg-file=\\'loop.webp\\']') && /GIF/.test(w.textContent);})");
        row('must', gifBadge, 'C-BG-3 the animated background is badged as animated', `badge=${gifBadge}`);

        // C-UI: the POINTER half of the tile-actions reveal (.bg-tile-wrap:hover .bg-tile-actions),
        // inert under the gate until it started declaring a fine, hover-capable pointer. Hidden is
        // asserted BEFORE the mouse arrives, so an unconditionally-revealed cluster cannot pass.
        await page.eval("document.activeElement && document.activeElement.blur()");
        await sleep(200);
        const tileActSel = "document.querySelectorAll('#bg-gallery .bg-tile-wrap')[0].querySelector('.bg-tile-actions')";
        const tileHiddenBefore = await page.eval(`getComputedStyle(${tileActSel}).opacity === '0'`);
        const tileBox = await page.eval("(function(){const r=document.querySelectorAll('#bg-gallery .bg-tile-wrap')[0].getBoundingClientRect();return JSON.stringify({x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)})})()");
        const tilePt = JSON.parse(tileBox);
        await page.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: tilePt.x, y: tilePt.y, buttons: 0 }, page.sessionId);
        const tileHoverRevealed = await page.waitFor(`getComputedStyle(${tileActSel}).opacity === '1'`, 3000);
        row('must', tileHiddenBefore && tileHoverRevealed,
            'C-BG-13 hovering a tile reveals its file actions (the pointer twin of the focus reveal)',
            `hiddenBefore=${tileHiddenBefore} revealed=${tileHoverRevealed}`);
        await page.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 0, y: 0, buttons: 0 }, page.sessionId);

        // Applying: the url rides a custom property on :root, encoded, and data-background gates the
        // layer on. Asserting the property (not pixels) keeps this off the browser's image decoder.
        await page.click("#bg-gallery [data-bg-file='a b.jpg']");
        const applied = await page.waitFor(
            "document.documentElement.getAttribute('data-background') === 'on' && document.documentElement.style.getPropertyValue('--chat-bg-image').indexOf('a%20b.jpg') >= 0", 4000);
        const pressed = await page.eval("document.querySelector('#bg-gallery [data-bg-file=\\'a b.jpg\\']').getAttribute('aria-pressed') === 'true'");
        row('must', applied && pressed, 'C-BG-4 selecting a background applies it and marks the tile pressed', `applied=${applied} pressed=${pressed}`);

        // C-CONN's panel-dismiss defect: a control that rerenders its own node away on click leaves
        // ui.onPageClick walking a detached target and dismissing the panel. A tile reselect only
        // patches aria-pressed in place, so the node survives and this needs no isConnected guard.
        const panelOpen = await page.eval("!!document.querySelector('#panel-view') && !!document.querySelector('#bg-gallery')");
        row('must', panelOpen, 'C-BG-5 selecting a background does not dismiss the panel', `open=${panelOpen}`);

        const stored = await page.eval("localStorage.getItem('st-background')");
        row('must', stored === 'a b.jpg', 'C-BG-6 the choice persists to localStorage unencoded', `stored=${stored}`);

        // The rule itself, not just the property: the layer must exist, sit behind the content, and
        // carry the scrim over the photo. A property nothing paints would pass every row above.
        const layer = await page.eval(
            "JSON.stringify((function(){var s=getComputedStyle(document.body,'::before');" +
            "return {c:s.content,z:s.zIndex,p:s.position,img:s.backgroundImage};})())");
        const l = JSON.parse(layer);
        const layerOk = l.c !== 'none' && l.z === '-1' && l.p === 'fixed'
            && l.img.indexOf('a%20b.jpg') >= 0 && l.img.indexOf('gradient') >= 0;
        row('must', layerOk, 'C-BG-7 the layer paints behind the content with its scrim', `z=${l.z} pos=${l.p} scrim=${l.img.indexOf('gradient') >= 0}`);

        // None clears it: the property goes back to none and the layer's gate attribute is dropped,
        // so an unset background costs no scrim over the chrome.
        await page.click("#bg-gallery [data-bg-none]");
        const cleared = await page.waitFor(
            "!document.documentElement.hasAttribute('data-background') && !localStorage.getItem('st-background')", 4000);
        row('must', cleared, 'C-BG-8 None clears the background and drops the layer', `cleared=${cleared}`);

        // Server-authoritative delete: the tile goes only because the server took it, proven by the
        // gallery re-serving one fewer on a fresh load.
        await page.eval('window.confirm = function(){ return true; };');
        await page.click("#bg-gallery [data-bg-delete='study.png']");
        const tileGone = await page.waitFor("!document.querySelector('#bg-gallery [data-bg-file=\\'study.png\\']')", 6000);
        const serverGone = await (async () => {
            const res = await fetch(`${args.base}/api/backgrounds/all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
            const j = await res.json();
            return !j.images.some((i) => i.filename === 'study.png');
        })();
        row('must', tileGone && serverGone, 'C-BG-9 delete removes the background on the server, not just the tile', `tile=${tileGone} server=${serverGone}`);

        await page.eval("window.prompt = function(){ return 'dusk harbour.jpg'; };");
        await page.click("#bg-gallery [data-bg-rename='dusk harbor.jpg']");
        const renamedTile = await page.waitFor("!!document.querySelector('#bg-gallery [data-bg-file=\\'dusk harbour.jpg\\']')", 6000);
        const renamedServer = await (async () => {
            const res = await fetch(`${args.base}/api/backgrounds/all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
            const j = await res.json();
            return j.images.some((i) => i.filename === 'dusk harbour.jpg') && !j.images.some((i) => i.filename === 'dusk harbor.jpg');
        })();
        row('must', renamedTile && renamedServer, 'C-BG-10 rename retitles the background and round-trips', `tile=${renamedTile} server=${renamedServer}`);

        // The blob check runs BEFORE the reload: the saver debounces 3s, and a navigate would discard
        // the pending timer and read as a save that never fired.
        await page.click("#bg-gallery [data-bg-file='loop.webp']");
        await page.waitFor("localStorage.getItem('st-background') === 'loop.webp'", 3000);

        const blobSaved = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const res = await fetch(`${args.base}/api/settings/get`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
                const j = await res.json();
                try {
                    if (JSON.parse(j.settings).clientBackground?.image === 'loop.webp') return true;
                } catch (_) { /* blob not written yet */ }
                await sleep(250);
            }
            return false;
        })();
        row('must', blobSaved, 'C-BG-11 the chosen background rides the account settings blob', `saved=${blobSaved}`);

        await page.navigate(`${args.base}/`);
        await page.waitFor(hydrated, 15000);
        const bootApplied = await page.waitFor(
            "document.documentElement.getAttribute('data-background') === 'on' && document.documentElement.style.getPropertyValue('--chat-bg-image').indexOf('loop.webp') >= 0", 5000);
        row('must', bootApplied, 'C-BG-12 a chosen background is applied again at boot', `applied=${bootApplied}`);

        // ===== C-BG2 (append-only): the odd isAnimated shapes, the second mutation, the upload seam =====
        console.log('== C-BG2 backgrounds: tolerant badge, concurrent mutation, upload ==');
        await page.click('#d-backgrounds');
        const bgAll = async () => {
            const res = await fetch(`${args.base}/api/backgrounds/all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
            return (await res.json()).images.map((i) => i.filename);
        };

        // Two of these carry isAnimated as a string and as null. Typed `bool`, ONE of them failed the
        // whole array parse and the gallery came up EMPTY: the count is what proves it costs no rows.
        const oddListed = await page.waitFor("document.querySelectorAll('#bg-gallery .bg-tile-wrap').length === 6", 8000);
        const oddTiles = await page.eval(
            "!!document.querySelector('#bg-gallery [data-bg-file=\\'odd str.jpg\\']') && !!document.querySelector('#bg-gallery [data-bg-file=\\'odd null.jpg\\']')");
        row('must', oddListed && oddTiles, 'C-BG2-1 a background with an odd isAnimated shape costs no tile, not the gallery', `six=${oddListed} tiles=${oddTiles}`);

        // The badge is the ONLY thing the odd shape may cost. "true" as a string is not a claim: a
        // truthiness read would badge it, and would badge a literal "false" just the same.
        const badged = (f) => `Array.from(document.querySelectorAll('#bg-gallery .bg-tile-wrap')).some(function(w){return w.querySelector("[data-bg-file='${f}']") && /GIF/.test(w.textContent);})`;
        const oddStrBadge = await page.eval(badged('odd str.jpg'));
        const oddNullBadge = await page.eval(badged('odd null.jpg'));
        const realBadge = await page.eval(badged('loop.webp'));
        row('must', !oddStrBadge && !oddNullBadge && realBadge, 'C-BG2-2 only a real bool badges a background as animated', `str=${oddStrBadge} null=${oddNullBadge} real=${realBadge}`);

        // A single shared pending slot dropped this on the floor: no dialog, no error, no delete. The
        // first delete is held open server-side, so the second click lands squarely in the in-flight
        // window the dialog was wrongly read as closing.
        await page.eval('window.confirm = function(){ return true; };');
        await page.click("#bg-gallery [data-bg-delete='slow delete.png']");
        await page.click("#bg-gallery [data-bg-delete='odd null.jpg']");
        const bothGone = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const names = await bgAll();
                if (!names.includes('slow delete.png') && !names.includes('odd null.jpg')) return true;
                await sleep(250);
            }
            return false;
        })();
        const secondServed = !(await bgAll()).includes('odd null.jpg');
        row('must', bothGone && secondServed, 'C-BG2-3 a second mutation while one is in flight is not swallowed', `both=${bothGone} second=${secondServed}`);

        // The upload control. The POST is Zig-owned now (net.zig raw multipart via the door op); what
        // is pinned here is our half: the control, its file typing and its accessible name.
        const uploadCtl = await page.eval(
            "(function(){var i=document.getElementById('bg-upload-input');return !!i && i.type==='file' && !!i.getAttribute('aria-label') && !!i.getAttribute('name');})()");
        row('must', uploadCtl, 'C-BG2-4 the upload control is present, named and typed for files', `ctl=${uploadCtl}`);

        const seam = await (async () => {
            await page.eval('window.__read_file_called = false; window.__st_read_file = function(){ window.__read_file_called = true; };');
            // bubbles: true is load-bearing. ziex delegates from a root, so a non-bubbling change
            // event never reaches the handler and the row reads as a dead seam.
            await page.eval("document.getElementById('bg-upload-input').dispatchEvent(new Event('change', { bubbles: true }))");
            return await page.waitFor('window.__read_file_called === true', 4000);
        })();
        const sending = await page.waitFor("/Uploading/.test(document.querySelector('.bg-upload-row').textContent)", 4000);
        row('must', seam && sending, 'C-BG2-5 picking a file calls the File->bytes glue and shows the wait', `seam=${seam} sending=${sending}`);

        // C-BG2-5 STUBS __st_read_file, so it pins the seam (uploadPick reached the File->bytes glue)
        // and nothing past it. Navigate fresh (the reload destroys the stub) and drive the REAL path
        // with a real picked file, so the Zig multipart build + raw POST run end to end.
        await page.navigate(`${args.base}/`);
        await page.waitFor(hydrated, 15000);
        await page.click('#d-backgrounds');
        await page.waitFor("document.getElementById('bg-upload-input')", 8000);
        const bgPngPath = join(mkdtempSync(join(tmpdir(), 'st-bg-')), 'picked bg.png');
        const bgPngBytes = Buffer.from(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            'base64');
        const bgExpectSha = createHash('sha256').update(bgPngBytes).digest('hex');
        writeFileSync(bgPngPath, bgPngBytes);
        const bgDoc = await page.cdp.send('DOM.getDocument', { depth: 1 }, page.sessionId);
        const bgNodeId = (await page.cdp.send('DOM.querySelector',
            { nodeId: bgDoc.root.nodeId, selector: '#bg-upload-input' }, page.sessionId)).nodeId;
        await page.cdp.send('DOM.setFileInputFiles', { files: [bgPngPath], nodeId: bgNodeId }, page.sessionId);
        const bgPost = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const st = (await (await fetch(`${args.base}/dev/state`)).json()).bg_upload;
                if (st) return st;
                await sleep(150);
            }
            return null;
        })();
        // The wait must LIFT. Reading for the absence of 'Uploading' is what the missing export
        // failed and what a future glue edit that drops the callback will fail again.
        const bgWaitLifted = await page.waitFor(
            "!/Uploading/.test(document.querySelector('.bg-upload-row').textContent)", 8000);
        const bgLanded = await page.eval(
            "Array.from(document.querySelectorAll('#bg-gallery .bg-tile-wrap')).some(function(t){return /picked bg\\.png/.test(t.textContent);})");
        row('must', !!bgPost && bgPost.field_avatar === true && bgWaitLifted && bgLanded,
            'C-BG2-6 a real upload posts under the field multer reads, lifts the wait, and shows the file',
            `post=${bgPost ? JSON.stringify(bgPost) : 'NEVER-ARRIVED'} waitLifted=${bgWaitLifted} tile=${bgLanded}`);
        // The dangerous-property check: the RAW file part the Zig multipart carried must be the PNG
        // byte-for-byte (a UTF-8 round trip in the door would have corrupted it). The mock parses the
        // file bytes out of the multipart body and hashes them.
        row('must', !!bgPost && bgPost.file_sha256 === bgExpectSha && bgPost.file_len === bgPngBytes.length,
            'C-BG2-7 the uploaded PNG round-trips byte-identical through the raw multipart POST',
            `sha=${bgPost && bgPost.file_sha256} expect=${bgExpectSha} len=${bgPost && bgPost.file_len}/${bgPngBytes.length}`);
        // C-BG2-8: a non-ASCII filename (emoji + accent) must reach the server's part header intact;
        // appendQuoted passes those bytes raw and the raw door op does not decode the body.
        const bgUniName = 'café🎨 bg.png';
        const bgUniPath = join(mkdtempSync(join(tmpdir(), 'st-bg2-')), bgUniName);
        writeFileSync(bgUniPath, bgPngBytes);
        const bgUniNodeId = (await page.cdp.send('DOM.querySelector',
            { nodeId: bgDoc.root.nodeId, selector: '#bg-upload-input' }, page.sessionId)).nodeId;
        await page.cdp.send('DOM.setFileInputFiles', { files: [bgUniPath], nodeId: bgUniNodeId }, page.sessionId);
        const bgUniPost = await (async () => {
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const st = (await (await fetch(`${args.base}/dev/state`)).json()).bg_upload;
                if (st && st.filename === bgUniName) return st;
                await sleep(150);
            }
            return null;
        })();
        row('must', !!bgUniPost && bgUniPost.filename === bgUniName && bgUniPost.file_sha256 === bgExpectSha,
            'C-BG2-8 a non-ASCII filename reaches the part header intact and the bytes still match',
            `name=${bgUniPost && JSON.stringify(bgUniPost.filename)} expect=${JSON.stringify(bgUniName)} bytesMatch=${!!bgUniPost && bgUniPost.file_sha256 === bgExpectSha}`);
        /* C-CONN */
        // The connection panel's type selector and its write-only API-key field. The key never
        // round-trips: the field renders empty and only a masked tail reaches the DOM.
        console.log('== C-CONN connection panel ==');
        const openConnections = async () => {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-connections');
            await page.waitFor("document.getElementById('dd-btn-conn-type')", 4000);
        };
        const ddFace = () => page.eval("document.querySelector('#dd-btn-conn-type span').textContent");

        // Reflect the MINED type: seed a configured type the client does not default to, so a pass
        // cannot come from the default.
        await (await fetch(`${args.base}/dev/conn-type?t=tabby`)).json();
        await openConnections();
        row('must', (await ddFace()) === 'TabbyAPI',
            'C-CONN-1 selector reflects the mined type from the settings blob', await ddFace());

        // A SECOND panel's Escape, because the guard must hold for every panel rather than for the one
        // whose author remembered to consume the key. C9 is the character-list twin of this row.
        await page.click('[data-dd-toggle="conn-type"]');
        await page.waitFor("document.getElementById('dd-list-conn-type')", 2500);
        for (const type of ['rawKeyDown', 'keyUp']) {
            await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
        }
        const connMenuClosed = await page.waitFor("!document.getElementById('dd-list-conn-type')", 2500);
        const connPanelAlive = await page.eval("!!document.querySelector('#panel-view') && !!document.getElementById('dd-btn-conn-type')");
        row('must', connMenuClosed && connPanelAlive,
            'C-CONN-11 Escape closes the type dropdown without dismissing the connections panel',
            `menuClosed=${connMenuClosed} panelAlive=${connPanelAlive}`);

        // tabby is seeded with a key, so presence shows without a write, masked to a 3-char tail.
        const keyState = await page.waitFor("document.getElementById('conn-key-state').textContent.includes('Key set')", 4000)
            && await page.eval("document.getElementById('conn-key-state').textContent");
        row('must', typeof keyState === 'string' && keyState.includes('*******001'),
            'C-CONN-2 a stored key shows as a masked tail only', String(keyState));
        row('must', !(await page.eval("document.body.textContent.includes('dummy-tabby-key')")),
            'C-CONN-3 the stored key plaintext never reaches the DOM');
        row('must', (await page.eval("document.getElementById('conn-api-key').value")) === '',
            'C-CONN-4 the key field renders empty (write-only, no round-trip)');

        // Write a key: the field clears, presence re-reads, and the mock records it under the
        // selected type's secret key.
        await page.focus('#conn-api-key');
        await page.insertText('dummy-written-key-9zz');
        await page.click('.conn-key-save');
        const savedMsg = await page.waitFor("document.getElementById('conn-key-status').textContent.includes('Key saved')", 6000);
        const clearedField = await page.eval("document.getElementById('conn-api-key').value");
        const secretsAfterWrite = (await (await fetch(`${args.base}/dev/state`)).json()).secrets;
        const tabbyEntries = (secretsAfterWrite && secretsAfterWrite.api_key_tabby) || [];
        const activeEntry = tabbyEntries.find((e) => e.active);
        row('must', savedMsg && clearedField === '' && !!activeEntry && activeEntry.value === 'dummy-written-key-9zz',
            'C-CONN-5 save writes the key under api_key_tabby and clears the field',
            `saved=${savedMsg} field="${clearedField}" active=${activeEntry && activeEntry.id}`);

        // Switching to a type with no key field: ollama takes no key in SECRET_KEYS.
        await page.click('#dd-btn-conn-type');
        await page.waitFor("document.getElementById('dd-list-conn-type')", 3000);
        await page.click("#dd-list-conn-type [data-dd-value='ollama']");
        const ollamaFace = await page.waitFor("document.querySelector('#dd-btn-conn-type span').textContent === 'Ollama'", 3000);
        const keyGone = await page.waitFor("!document.getElementById('conn-api-key')", 3000);
        row('must', ollamaFace && keyGone,
            'C-CONN-6 a type that takes no key hides the key field', `face=${ollamaFace} hidden=${keyGone}`);

        // Connect persists the SELECTED type, not the hardcoded llamacpp the panel used to send.
        await page.eval("document.getElementById('llama-url').value=''");
        await page.focus('#llama-url');
        await page.insertText('http://127.0.0.1:9098');
        await page.click('.conn-connect');
        const connOk = await page.waitFor("document.getElementById('conn-status').textContent.includes('Connected')", 6000);
        const recorded = (await (await fetch(`${args.base}/dev/state`)).json()).recorded_connection;
        row('must', connOk && !!recorded && recorded.api_type === 'ollama',
            'C-CONN-7 connect persists the selected type', JSON.stringify(recorded));

        // Remove drops only the ACTIVE key; secrets.js reactivates the next one, so the panel must
        // fall back to reporting the seeded key rather than claiming the type has none.
        await (await fetch(`${args.base}/dev/conn-type?t=tabby`)).json();
        await openConnections();
        await page.waitFor("document.getElementById('conn-key-state').textContent.includes('Key set')", 4000);
        await page.click('.conn-key-clear');
        const rotated = await page.waitFor("document.getElementById('conn-key-state').textContent.includes('*******001')", 6000);
        const afterOne = (await (await fetch(`${args.base}/dev/state`)).json()).secrets;
        const leftAfterOne = (afterOne && afterOne.api_key_tabby) || [];
        row('must', rotated && leftAfterOne.length === tabbyEntries.length - 1 && leftAfterOne[0].active,
            'C-CONN-8 remove deletes the active key and reports the one that takes over',
            `rotated=${rotated} left=${leftAfterOne.length}`);

        // Removing the last one empties the key: the panel states it plainly (no bare spinner).
        await page.click('.conn-key-clear');
        const emptied = await page.waitFor("document.getElementById('conn-key-state').textContent.includes('No key set')", 6000);
        const afterAll = (await (await fetch(`${args.base}/dev/state`)).json()).secrets;
        row('must', emptied && !(afterAll && afterAll.api_key_tabby),
            'C-CONN-9 removing the last key empties the store and shows the empty state',
            `emptied=${emptied} key=${JSON.stringify(afterAll && afterAll.api_key_tabby)}`);

        // DANGEROUS PROPERTY (T0): with allowKeysExposure=true the server returns the key in the
        // CLEAR, so the client's own re-mask is the only thing between a live key and the DOM. The
        // masked-server path above cannot leak and therefore cannot test this. Drive the raw path.
        const rawKey = 'dummy-exposed-key-7xy';
        await (await fetch(`${args.base}/dev/arm-keys-exposed`)).json();
        await (await fetch(`${args.base}/dev/conn-type?t=tabby`)).json();
        await openConnections();
        await page.focus('#conn-api-key');
        await page.insertText(rawKey);
        await page.click('.conn-key-save');
        await page.waitFor("document.getElementById('conn-key-status').textContent.includes('Key saved')", 6000);
        // The re-read after the write is the one the server answers in the clear.
        const maskedShown = await page.waitFor("document.getElementById('conn-key-state').textContent.includes('*******7xy')", 6000);
        const servedRaw = ((await (await fetch(`${args.base}/dev/state`)).json()).secrets.api_key_tabby || [])
            .some((e) => e.active && e.value === rawKey);
        const leaked = await page.eval(
            `document.body.textContent.includes('${rawKey}')` +
            ` || document.documentElement.outerHTML.includes('${rawKey}')` +
            ` || document.getElementById('conn-api-key').value.includes('${rawKey}')`);
        row('must', servedRaw && maskedShown && !leaked,
            'C-CONN-10 allowKeysExposure=true: the raw key the server returns never reaches the DOM',
            `servedRaw=${servedRaw} masked=${maskedShown} leaked=${leaked}`);
        /* C-CARD */
        {
            console.log('== card editor: full-card fetch + save round-trip (3e) ==');
            await page.click('#d-card_editor');
            // The form only mounts once the deep card lands, so its presence IS the fetch assertion.
            const cardLoaded = await page.waitFor(
                "!!document.querySelector('#card-description') && document.querySelector('#card-description').value.indexOf('lighthouse keeper') >= 0", 8000);
            const deepFields = await page.eval(
                "(function(){var g=function(id){var e=document.getElementById(id);return e?e.value:null;};return JSON.stringify({pers:g('card-personality'),ver:g('card-character_version'),tags:g('card-tags'),depth:g('card-depth_prompt_depth')});})()");
            const deep = JSON.parse(deepFields || '{}');
            // The shallow /characters/all form carries none of these; only the deep /get fetch can fill them.
            const deepOk = deep.pers === 'curious and warm' && deep.ver === '1.2' && deep.tags === 'keeper, coastal' && deep.depth === '4';
            row('must', cardLoaded && deepOk, 'C-CARD-1 opening the panel fetches the FULL card into the form', `loaded=${cardLoaded} ${deepFields}`);

            await page.eval("(function(){var t=document.getElementById('card-description'); t.value='a keeper who reads the weather and the tide'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.click('#card-save');
            const pollCard = async (pred) => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const st = await (await fetch(`${args.base}/dev/state`)).json();
                    if (st.card_edit && pred(st.card_edit)) return st.card_edit;
                    await sleep(150);
                }
                return null;
            };
            const saved = await pollCard((c) => c.description === 'a keeper who reads the weather and the tide');
            row('must', !!saved, 'C-CARD-2 an edit saves through /characters/edit', `saved=${!!saved}`);

            // THE CONTRACT TRAPS. charaFormatData _.sets every field it knows unconditionally, so a key
            // the body omits is written back as its default: the card silently loses it. fav is worse -
            // the server compares `data.fav == 'true'`, so a JSON boolean reads as false and clears it.
            const card = saved || {};
            const favOk = card.fav === 'true';
            const bookOk = typeof card.json_data === 'string' && card.json_data.indexOf('character_book') >= 0;
            const talkOk = card.talkativeness === 0.7;
            const greetOk = Array.isArray(card.alternate_greetings) && card.alternate_greetings.length === 2;
            const metaOk = !!card.avatar_url && card.chat === `${card.avatar_url} - 2026-01-01` && card.create_date === '2026-01-01T00:00:00.000Z';
            const depthOk = card.depth_prompt_depth === 4 && card.depth_prompt_role === 'system';
            row('must', favOk && bookOk && talkOk && greetOk && metaOk && depthOk,
                'C-CARD-3 the save echoes every field charaFormatData would default away',
                `fav=${card.fav} book=${bookOk} talk=${card.talkativeness} greets=${greetOk} meta=${metaOk} depth=${card.depth_prompt_depth}/${card.depth_prompt_role}`);

            // A full page load, not a Revert click: this gate TYPED into the textarea, which sets its
            // dirty-value flag, so the browser keeps showing that text whatever the VDOM patches into
            // the text child. Only a fresh mount proves the text came back from the server.
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
            await page.click('#d-card_editor');
            const persisted = await page.waitFor(
                "!!document.querySelector('#card-description') && document.querySelector('#card-description').value === 'a keeper who reads the weather and the tide'", 8000);
            row('must', persisted, 'C-CARD-4 the saved text comes back on a fresh load', `persisted=${persisted}`);

            // The one enumerated field rides the shared dropdown, delegated from the panel root (ZX11).
            await page.click('#dd-btn-depth_prompt_role');
            const menuOpen = await page.waitFor("!!document.querySelector('[role=\"listbox\"]')", 3000);
            await page.click('[role="option"][data-dd-value="user"]');
            const rolePicked = await page.waitFor(
                "document.querySelector('#dd-btn-depth_prompt_role').textContent.indexOf('User') >= 0", 3000);
            // Non-vacuous: this click also proves the panel SURVIVES it. The menu closing re-renders
            // synchronously and orphans the clicked option, which the page-click dismiss used to read
            // as a click outside the panel and close the whole drawer (fixed in ui.onPageClick).
            const panelAlive = await page.eval("!!document.querySelector('#card-editor')");
            row('must', menuOpen && rolePicked && panelAlive, 'C-CARD-5 the note-role dropdown opens and stores the pick', `open=${menuOpen} picked=${rolePicked} panelAlive=${panelAlive}`);

            // Escape rides the same delegated keydown to ui.onPageKey, which closes the active panel
            // without reading the target: a handler that does not CONSUME the key it handled loses the
            // whole drawer to a menu dismiss. Non-vacuous only if it asserts the panel survived.
            const escape = async () => {
                const k = { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, modifiers: 0 };
                await page.cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', ...k }, page.sessionId);
                await page.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...k }, page.sessionId);
            };
            await page.click('#dd-btn-depth_prompt_role');
            await page.waitFor("!!document.querySelector('[role=\"listbox\"]')", 3000);
            await escape();
            const escClosedMenu = await page.waitFor("!document.querySelector('[role=\"listbox\"]')", 3000);
            const escKeptPanel = await page.eval("!!document.querySelector('#card-editor')");
            row('must', escClosedMenu && escKeptPanel, 'C-CARD-6 Escape closes the menu and the panel survives it', `menuClosed=${escClosedMenu} panelAlive=${escKeptPanel}`);

            // The same Escape with no menu open still dismisses the panel: consuming the key must not
            // cost the drawer its own Escape.
            await escape();
            const escClosedPanel = await page.waitFor("!document.querySelector('#card-editor')", 3000);
            row('must', escClosedPanel, 'C-CARD-7 Escape with no menu open still closes the panel', `closed=${escClosedPanel}`);

            // C-CARD2: the greetings the save was already echoing are now editable. Structural, so
            // it drives the buttons rather than the buffers: a removal shifts row 1 up into a node
            // the user typed in, and a textarea the user has typed in ignores its text child ever
            // after, so the panel has to write the survivor's text into it explicitly.
            await page.click('#d-card_editor');
            await page.waitFor("!!document.querySelector('#card-greeting-0')", 8000);
            const greetLoaded = await page.eval(
                "(function(){var g=function(i){var e=document.getElementById('card-greeting-'+i);return e?e.value:null;};" +
                "return JSON.stringify({n:document.querySelectorAll('[data-card-greeting]').length,a:g(0),b:g(1)});})()");
            const gl = JSON.parse(greetLoaded || '{}');
            row('must', gl.n === 2 && gl.a === 'The fog is in.' && gl.b === 'Mind the step.',
                'C-CARD-8 the card\'s alternate greetings load into their own editors', greetLoaded);

            // ISOLATION IS THE WHOLE ROW: Revert re-reads the card, so the footer is empty and the
            // edit below is the ONLY thing that happens before the read. The inputs deliberately do
            // not re-render (that would cost the caret), so nothing renders here at all: a notice
            // computed only at render time reads "". An earlier draft typed after a button click and
            // passed on that click's render, proving nothing.
            await page.click('#card-revert');
            await page.waitFor("!!document.getElementById('card-editor-notice')" +
                " && document.getElementById('card-editor-notice').textContent === ''" +
                " && !!document.getElementById('card-personality')", 8000);
            const noticeBefore = await page.eval("document.getElementById('card-editor-notice').textContent");
            await page.eval("(function(){var t=document.getElementById('card-personality'); t.value='changed by the gate'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            const noticeAfterEdit = await page.waitFor(
                "document.getElementById('card-editor-notice').textContent.indexOf('Unsaved changes') >= 0", 3000);
            row('must', noticeBefore === '' && noticeAfterEdit,
                'C-CARD-10 an edit says so in the footer with no render to carry it',
                `before="${noticeBefore}" after="${await page.eval("document.getElementById('card-editor-notice').textContent")}"`);

            await page.click('#card-greeting-add');
            await page.waitFor("!!document.querySelector('#card-greeting-2')", 3000);
            await page.focus('#card-greeting-2');
            await page.insertText('The lamp is out.');
            // Remove row 0: row 1 and row 2 shift up into nodes that already hold typed-in text.
            await page.click('[data-card-greeting-remove="0"]');
            const shifted = await page.waitFor(
                "document.querySelectorAll('[data-card-greeting]').length === 2" +
                " && document.getElementById('card-greeting-0').value === 'Mind the step.'" +
                " && document.getElementById('card-greeting-1').value === 'The lamp is out.'", 3000);
            row('must', shifted, 'C-CARD-9 adding, typing and removing a greeting leaves every row showing its own text',
                `shifted=${shifted} ${await page.eval("(function(){var v=[];document.querySelectorAll('[data-card-greeting]').forEach(function(e){v.push(e.value);});return JSON.stringify(v);})()")}`);

            await page.click('#card-save');
            const savedGreets = await pollCard((c) => Array.isArray(c.alternate_greetings) && c.alternate_greetings.length === 2);
            const greetBody = savedGreets && savedGreets.alternate_greetings;
            row('must', !!savedGreets && greetBody[0] === 'Mind the step.' && greetBody[1] === 'The lamp is out.',
                'C-CARD-11 the edited greetings are what the save sends', JSON.stringify(greetBody));

            // THE EDIT ABOVE IS THE TRAP, so it has to stay above: reflectNotice writes the footer with
            // no render, and writing it through textContent REPLACED the text node ziex holds by vnode
            // id, so every later render patched a detached node and the save reported into thin air.
            // A row that saves a pristine form proves nothing here (C-CARD-15 passed throughout for
            // exactly that reason: it never edits first).
            const aliveAfterSave = await page.eval("!!document.querySelector('#card-editor-notice')");
            const noticeSaved = aliveAfterSave && await page.waitFor(
                "document.getElementById('card-editor-notice').textContent.indexOf('Saved') >= 0", 4000);
            row('must', !!noticeSaved, 'C-CARD-14 a save keeps the character selected and says it saved',
                `formAlive=${aliveAfterSave} selection=${await page.eval("!document.querySelector('#card-editor p')||document.querySelector('#card-editor p').textContent")}`);

            // THE REFUSAL PATH, and the one that costs the user most: the same detached-node defect
            // silenced every notice, and a save that is REFUSED in silence reads as a save that worked.
            // Clearing the name is the only refusal reachable without the server playing along, and it
            // runs through an edit, so it re-enters the trap C-CARD-14 guards from the other side.
            const nameBefore = await page.eval("document.getElementById('card-name').value");
            await page.eval("(function(){var t=document.getElementById('card-name'); t.value=''; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.click('#card-save');
            const refusal = await page.waitFor(
                "document.getElementById('card-editor-notice').textContent.indexOf('needs a name') >= 0", 4000);
            // The guard refuses BEFORE the request, so the server must still hold the last good name.
            // The body names it ch_name, which is the key the server 400s on (characters.js:1197).
            await sleep(400);
            const serverName = (await (await fetch(`${args.base}/dev/state`)).json()).card_edit.ch_name;
            row('must', refusal && serverName === nameBefore && nameBefore.length > 0,
                'C-CARD-16 a save refused for a missing name says so instead of failing silently',
                `notice="${await page.eval("document.getElementById('card-editor-notice').textContent")}" serverName=${JSON.stringify(serverName)} nameBefore=${JSON.stringify(nameBefore)}`);

            // Every row above is served a card shaped the way we BELIEVE the server shapes them, so
            // they prove our reading of the contract and nothing else. The server coerces none of a
            // card's fields (characters.js:426-430); typed, one odd field failed the WHOLE parse.
            await (await fetch(`${args.base}/dev/arm-hostile-card`)).json();
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
            await page.click('#d-card_editor');
            // The form mounting at all IS the assertion: the error screen has no fields.
            const hostileMounted = await page.waitFor("!!document.querySelector('#card-creator')", 8000);
            const hostileFields = await page.eval(
                "(function(){var g=function(id){var e=document.getElementById(id);return e?e.value:null;};" +
                "return JSON.stringify({name:g('card-name'),desc:g('card-description'),pers:g('card-personality')," +
                "scen:g('card-scenario'),first:g('card-first_mes'),creator:g('card-creator'),ver:g('card-character_version')," +
                "tags:g('card-tags'),depth:g('card-depth_prompt_depth'),world:g('card-world')," +
                "role:(document.querySelector('#dd-btn-depth_prompt_role')||{}).textContent," +
                "greets:document.querySelectorAll('[data-card-greeting]').length," +
                "g0:g('card-greeting-0'),err:!!document.querySelector('#card-editor [role=alert]')});})()");
            const h = JSON.parse(hostileFields || '{}');
            // Each unreadable shape costs its OWN field and nothing else.
            const hostileCosts = h.name === '' && h.desc === '' && h.pers === '' && h.scen === '' && h.first === '' && h.world === '';
            // The readable fields beside them are untouched, which is the whole point of the row.
            const hostileKeeps = h.creator === 'someone' && h.tags === 'solo, mystery' && h.depth === '3';
            // A role of 5 matches no option: it falls back to the server's own default rather than
            // rendering a dropdown with a blank face.
            const hostileRole = (h.role || '').indexOf('System') >= 0;
            // Three greetings in, three out: the two unreadable ones are empty rows the user can see.
            const hostileGreets = h.greets === 3 && h.g0 === 'real one';
            row('must', hostileMounted && !h.err && hostileCosts && hostileKeeps && hostileRole && hostileGreets,
                'C-CARD-12 a card another tool wrote still opens, and each odd field costs only itself',
                `mounted=${hostileMounted} ${hostileFields}`);

            // The image replace, driven through the real <input type=file> with a real file: a
            // FormData cannot cross the wasm boundary, so the POST hops to a JS helper, and the
            // helper is the only thing that knows the field must be named 'avatar'.
            const pngPath = join(mkdtempSync(join(tmpdir(), 'st-card-')), 'new-face.png');
            writeFileSync(pngPath, Buffer.from(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
                'base64'));
            // Edit BEFORE the pick, deliberately. An edit is what used to detach the footer's text
            // node, so an upload onto a pristine form reported fine while the same upload after a
            // keystroke reported into a node no user could see. This row passed throughout the defect
            // for exactly that reason; now it enters the trap the way a user does.
            await page.focus('#card-personality');
            await page.insertText('!');
            const doc = await page.cdp.send('DOM.getDocument', { depth: 1 }, page.sessionId);
            const nodeId = (await page.cdp.send('DOM.querySelector',
                { nodeId: doc.root.nodeId, selector: '#card-avatar-input' }, page.sessionId)).nodeId;
            await page.cdp.send('DOM.setFileInputFiles', { files: [pngPath], nodeId }, page.sessionId);
            const post = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const st = (await (await fetch(`${args.base}/dev/state`)).json()).avatar_post;
                    if (st) return st;
                    await sleep(150);
                }
                return null;
            })();
            // The field name IS the contract: multer is .single('avatar'), so a body naming the file
            // anything else 400s, which a user only ever sees as an image that did not change.
            row('must', !!post && post.field_avatar === true && post.avatar_url === 'char41.png' && post.bytes > 100,
                'C-CARD-13 picking an image posts it to edit-avatar under the field multer reads',
                `post=${JSON.stringify(post)}`);

            const avatarNotice = await page.waitFor(
                "!!document.getElementById('card-editor-notice') && document.getElementById('card-editor-notice').textContent.indexOf('New image saved') >= 0", 4000);
            row('must', avatarNotice, 'C-CARD-15 the panel reports the new image in its own footer',
                `notice=${avatarNotice}`);
        }

        // --- C-CFG: the config panels (2a samplers, 2b templates, 2c author's note) ---
        console.log('== config panels ==');
        {
            // The drawer button toggles, so a second click closes it. There is no #topdrawer id to
            // reach the chrome's own close button by.
            const closeTopDrawer = async () => {
                await page.click('#d-formatting');
                await page.waitFor("!document.getElementById('instruct-input_sequence')", 3000);
            };
            const openChat = async () => {
                await page.navigate(`${args.base}/`);
                await openRecentChat();
            };

            // 2a SAMPLERS. The panel must open on the LIVE value from the settings blob (temp 0.8),
            // not on the spec default (1.0), or it would silently rewrite the user's sampler on the
            // first save.
            await openChat();
            await page.click('#d-ai_config');
            await page.waitFor("document.getElementById('sampler-temp')", 4000);
            const tempAtOpen = await page.eval("document.getElementById('sampler-temp').value");
            row('must', tempAtOpen === '0.80',
                'C-CFG-1 samplers open on the mined blob value, not the spec default', `temp=${tempAtOpen}`);

            // The slider and the box are two controls over one value: moving one must move the other,
            // or the panel lies about what it will send.
            await page.eval("(function(){const r=document.getElementById('sampler-range-temp');r.value='1.5';r.dispatchEvent(new Event('input',{bubbles:true}));})()");
            const twinSynced = await page.waitFor("document.getElementById('sampler-temp').value === '1.50'", 2500);
            row('must', twinSynced, 'C-CFG-2 moving the slider moves its number box',
                `num=${await page.eval("document.getElementById('sampler-temp').value")}`);

            // The clamp is the guard between a typed value and the request body. 99 is past temp's max.
            await page.eval("(function(){const n=document.getElementById('sampler-temp');n.value='99';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            const clamped = await page.waitFor("document.getElementById('sampler-range-temp').value === '4'", 2500);
            row('must', clamped, 'C-CFG-3 an out-of-range typed sampler clamps to the spec max',
                `range=${await page.eval("document.getElementById('sampler-range-temp').value")}`);

            // The sampler must reach the REQUEST, which is the only thing that proves the panel is
            // wired to send rather than to localStorage alone. Send, then read the recorded body.
            await page.eval("(function(){const n=document.getElementById('sampler-temp');n.value='0.35';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(200);
            await page.click('#panel-view .icon[data-icon="close"]');
            await sleep(200);
            await sendProbe('does the sampler ride the request');
            const genBody = await (await fetch(`${args.base}/dev/state`)).json();
            // Cleared before the send, so a body here can only be the one this row caused.
            row('must', !!genBody.last_generate_body, 'C-CFG-4a the probe send actually reached the backend',
                `recorded=${!!genBody.last_generate_body}`);
            const sentTemp = genBody.last_generate_body && JSON.parse(genBody.last_generate_body).temperature;
            row('must', sentTemp === 0.35,
                'C-CFG-4 a panel sampler reaches the generate request body', `temperature=${sentTemp}`);

            // The stop sequence: the tear that let the model run past its own end-of-turn.
            const sentStop = genBody.last_generate_body && JSON.parse(genBody.last_generate_body).stop;
            // The classic-parity array leads with the \nName: stops (names_as_stop_strings), so assert
            // the ChatML end-of-turn stop is PRESENT, not at index 0.
            row('must', Array.isArray(sentStop) && sentStop.some(s => s.includes('<|im_end|>')),
                'C-CFG-5 the instruct stop sequence reaches the request', `stop=${JSON.stringify(sentStop)}`);

            // The prompt must carry the ChatML wrappers AND no literal handlebars. Both tears at once:
            // a story string rendered by the flat resolver alone would ship "{{#if description}}".
            const prompt = genBody.last_generate_prompt || '';
            row('must', prompt.includes('<|im_start|>user') && prompt.includes('<|im_start|>system'),
                'C-CFG-6 the prompt wraps turns in the blob template sequences',
                `hasUser=${prompt.includes('<|im_start|>user')} hasSystem=${prompt.includes('<|im_start|>system')}`);
            row('must', !prompt.includes('{{#if') && !prompt.includes('{{trim}}'),
                'C-CFG-7 the story string renders rather than shipping literal handlebars',
                `leaked=${prompt.includes('{{#if') || prompt.includes('{{trim}}')}`);

            // 2c the note from the chat header must reach the prompt. The fixture note is in_chat.
            row('must', prompt.includes('The tide is coming in.'),
                'C-CFG-8 the chat header author\'s note reaches the prompt', `present=${prompt.includes('The tide is coming in.')}`);

            // 2b FORMATTING panel. The instruct fields open on the blob, hostile shapes and all: the
            // fixture writes enabled as the STRING "true" and first_output_sequence as null.
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('instruct-input_sequence')", 4000);
            const inputSeq = await page.eval("document.getElementById('instruct-input_sequence').value");
            const enabledBox = await page.eval("document.getElementById('instruct-enabled').checked");
            row('must', inputSeq === '<|im_start|>user' && enabledBox === true,
                'C-CFG-9 the instruct editor opens on the blob template despite hostile field shapes',
                `input_sequence=${inputSeq} enabled=${enabledBox}`);

            // The note editor opens on the chat's own note, including the depth the fixture stores as
            // the STRING "2" (the tolerant number parse).
            const notePrompt = await page.eval("document.getElementById('an-prompt').value");
            const noteDepth = await page.eval("document.getElementById('an-depth').value");
            row('must', notePrompt === 'The tide is coming in.' && noteDepth === '2',
                'C-CFG-10 the note editor opens on the chat header note, string depth included',
                `prompt=${JSON.stringify(notePrompt)} depth=${noteDepth}`);

            // Editing an instruct field must reshape the NEXT prompt with no reload.
            await page.eval("(function(){const n=document.getElementById('instruct-output_sequence');n.value='<|assistant|>';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(200);
            await closeTopDrawer();
            await sleep(300);
            await sendProbe('does the edited template reshape the prompt');
            const afterEdit = await (await fetch(`${args.base}/dev/state`)).json();
            row('must', (afterEdit.last_generate_prompt || '').includes('<|assistant|>'),
                'C-CFG-11 an edited instruct sequence reshapes the very next prompt',
                `present=${(afterEdit.last_generate_prompt || '').includes('<|assistant|>')}`);

            // 2c the note SAVE round-trip: what the client sends must be the classic client's keys,
            // and it must gate on the FULL token (a tail token would let two edits both pass).
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('an-prompt')", 4000);
            await page.eval("(function(){const n=document.getElementById('an-prompt');n.value='The lamp is out.';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.eval("(function(){const n=document.getElementById('an-interval');n.value='3';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(150);
            await page.click('.an-save');
            const savedOk = await page.waitFor("document.getElementById('an-status').textContent === 'Note saved'", 4000);
            const sent = await (await fetch(`${args.base}/dev/note-save`)).json();
            row('must', savedOk && sent.note_prompt === 'The lamp is out.' && sent.note_interval === 3,
                'C-CFG-12 saving the note posts the classic metadata keys', `sent=${JSON.stringify({p: sent.note_prompt, i: sent.note_interval})}`);
            row('must', typeof sent.change_token === 'string' && sent.change_token.startsWith('full-'),
                'C-CFG-13 the note save gates on the FULL change token, not the tail token',
                `token=${sent.change_token}`);

            const stored = await (await fetch(`${args.base}/dev/chat-metadata`)).json();
            row('must', stored.note_prompt === 'The lamp is out.' && stored.integrity === 'mock-integrity',
                'C-CFG-14 the note write keeps the chat metadata the client does not model',
                `integrity=${stored.integrity}`);

            // A concurrent writer moved the file. The user must be told, not silently dropped.
            await (await fetch(`${args.base}/dev/arm-metadata-409`)).json();
            await page.eval("(function(){const n=document.getElementById('an-prompt');n.value='A racing edit.';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(150);
            await page.click('.an-save');
            const staleTold = await page.waitFor("document.getElementById('an-status').textContent.includes('Chat changed elsewhere')", 4000);
            row('must', staleTold, 'C-CFG-15 a stale note save says so rather than dropping the edit',
                `status=${await page.eval("document.getElementById('an-status').textContent")}`);

            // And the adopted token makes the RETRY land, so the user is not stuck in a 409 loop.
            await page.click('.an-save');
            const retryOk = await page.waitFor("document.getElementById('an-status').textContent === 'Note saved'", 4000);
            row('must', retryOk, 'C-CFG-16 saving again after a 409 lands on the refreshed token', `status=${await page.eval("document.getElementById('an-status').textContent")}`);

            // The Escape guard, this panel's copy. A dropdown Escape must not take the whole drawer.
            await page.click('[data-dd-toggle="an-position"]');
            await page.waitFor("document.getElementById('dd-list-an-position')", 2500);
            for (const type of ['rawKeyDown', 'keyUp']) {
                await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
            }
            const cfgMenuClosed = await page.waitFor("!document.getElementById('dd-list-an-position')", 2500);
            const cfgPanelAlive = await page.eval("!!document.getElementById('an-prompt')");
            row('must', cfgMenuClosed && cfgPanelAlive,
                'C-CFG-17 Escape closes the note dropdown without dismissing the formatting panel',
                `menuClosed=${cfgMenuClosed} panelAlive=${cfgPanelAlive}`);

            // The C-CARD-7 shape: Escape with NO menu open must still close the panel, so a guard that
            // fixes C-CFG-17 by swallowing every Escape cannot pass both.
            for (const type of ['rawKeyDown', 'keyUp']) {
                await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
            }
            const cfgEscClosed = await page.waitFor("!document.getElementById('an-prompt')", 3000);
            row('must', cfgEscClosed, 'C-CFG-18 Escape with no menu open still closes the formatting panel',
                `closed=${cfgEscClosed}`);
        }

        // The panel shipped WORKING and HALF-PERSISTED: every live path was proven (a sampler reaches
        // the request body, an edited template reshapes the next prompt) while the merge into the
        // settings blob was never wired into the one saver. config_state keeps TWO channels, so the
        // edit still survived a reload out of localStorage and looked fine; what never happened was
        // the DURABLE write, so another browser, another device and the classic ST client all saw the
        // old value forever. Assert the BLOB, not the reload: a reload row passes on localStorage
        // alone and proves nothing about the channel that was missing (it did: this row's first
        // draft stayed green with the merge line deleted).
        {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-ai_config');
            await page.waitFor("document.getElementById('sampler-temp')", 4000);
            await page.eval("(function(){const r=document.getElementById('sampler-range-temp');r.value='1.25';r.dispatchEvent(new Event('input',{bubbles:true}));})()");
            // The saver is debounced, so poll the server's own copy rather than sleep.
            const blobTemp = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const s = JSON.parse(r.settings || '{}');
                    const t = s.textgenerationwebui_settings && s.textgenerationwebui_settings.temp;
                    if (t === 1.25) return t;
                    await sleep(200);
                }
                return null;
            })();
            row('must', blobTemp === 1.25,
                'C-CFG-19 an edited sampler reaches the settings blob, not just this browser',
                `blobTemp=${blobTemp === null ? 'NEVER-ARRIVED' : blobTemp}`);
        }

        // --- C-PRE-TPL: the instruct/context preset pickers (wave 3b) ---
        // Hand-typing ChatML into six fields and getting one subtly wrong makes a model answer badly
        // in a way a user cannot diagnose. These rows prove the pick reaches the PROMPT, not the panel.
        console.log('== template presets ==');
        {
            const pick = async (dd, value) => {
                await page.click(`[data-dd-toggle="${dd}"]`);
                await page.waitFor(`document.getElementById('dd-list-${dd}')`, 3000);
                await page.click(`#dd-list-${dd} [data-dd-value="${value}"]`);
                await page.waitFor(`!document.getElementById('dd-list-${dd}')`, 3000);
                await sleep(150);
            };
            const optionsOf = async (dd) => {
                await page.click(`[data-dd-toggle="${dd}"]`);
                await page.waitFor(`document.getElementById('dd-list-${dd}')`, 3000);
                // The library is fetched lazily on the panel's first render, so an open menu is NOT
                // proof it has arrived: reading straight away races the fetch and reports [] for a
                // list that was merely late. Bounded, so a genuinely empty list still fails the row
                // rather than hanging it.
                await page.waitFor(`document.querySelectorAll('#dd-list-${dd} [role=option]').length > 0`, 6000);
                const labels = await page.eval(
                    `JSON.stringify(Array.from(document.querySelectorAll('#dd-list-${dd} [role=option]')).map(o => o.textContent))`);
                await page.click(`[data-dd-toggle="${dd}"]`);
                await page.waitFor(`!document.getElementById('dd-list-${dd}')`, 3000);
                return JSON.parse(labels);
            };
            const promptNow = async () => (await (await fetch(`${args.base}/dev/state`)).json()).last_generate_prompt || '';

            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('instruct-input_sequence')", 4000);
            await page.waitFor("!!document.querySelector('#dd-btn-fmt-instruct-preset')", 4000);

            // TOLERANCE. The fixture library carries a hostile preset, a non-object element and a
            // nameless one. A typed parse of the array would fail on ONE of them and empty the WHOLE
            // list, which is the exact shape that shipped three times here. The two unnameable
            // entries cost themselves; the three nameable ones must all still list.
            const instructOpts = await optionsOf('fmt-instruct-preset');
            row('must', instructOpts.length === 3 && instructOpts.includes('ChatML') && instructOpts.includes('Alpaca') && instructOpts.includes('Hostile'),
                'C-PRE-TPL-1 the instruct list renders every nameable preset despite a hostile, a non-object and a nameless one',
                `options=${JSON.stringify(instructOpts)}`);

            const contextOpts = await optionsOf('fmt-context-preset');
            row('must', contextOpts.length === 2 && contextOpts.includes('ChatML') && contextOpts.includes('Unmigrated'),
                'C-PRE-TPL-2 the context list renders its presets', `options=${JSON.stringify(contextOpts)}`);

            // The panel must open on the LIVE template's name, or it would claim the user is on a
            // preset they are not and a save would overwrite the wrong file.
            const faceAtOpen = await page.eval("document.querySelector('#dd-btn-fmt-instruct-preset span').textContent");
            row('must', faceAtOpen === 'ChatML', 'C-PRE-TPL-3 the picker opens on the live template name, not on the first option',
                `face=${faceAtOpen}`);

            // THE ROW THAT MATTERS: the pick must reshape the PROMPT, not the panel's own display.
            await pick('fmt-instruct-preset', 'Alpaca');
            // Null-safe: a regression that drops `enabled` collapses the whole sequence editor, and a
            // throwing read here would abort the block and take every row below it with it.
            const seqAfterPick = await page.eval("(document.getElementById('instruct-input_sequence')||{}).value || 'FIELDS-GONE'");
            await page.click('#d-formatting');
            await page.waitFor("!document.getElementById('instruct-input_sequence')", 3000);
            await sendProbe('does the picked preset reshape the prompt');
            const alpacaPrompt = await promptNow();
            row('must', alpacaPrompt.includes('### Instruction:') && alpacaPrompt.includes('### Response:') && !alpacaPrompt.includes('<|im_start|>user'),
                'C-PRE-TPL-4 picking an instruct preset reshapes the very next prompt',
                `hasAlpaca=${alpacaPrompt.includes('### Instruction:')} chatmlGone=${!alpacaPrompt.includes('<|im_start|>user')} field=${seqAfterPick}`);

            // The stop sequence rides the same preset and is what stops the model running past its
            // own end-of-turn, so it must move with the pick too.
            const genBody = await (await fetch(`${args.base}/dev/state`)).json();
            const stop = genBody.last_generate_body && JSON.parse(genBody.last_generate_body).stop;
            // Same as C-CFG-5: the name-stops lead the array, so assert the Alpaca stop is present.
            row('must', Array.isArray(stop) && stop.some(s => s.includes('### Instruction:')),
                'C-PRE-TPL-5 the picked preset\'s stop sequence reaches the request', `stop=${JSON.stringify(stop)}`);

            // HOSTILE. Its two good fields must apply, its five bad ones must cost only themselves,
            // and `enabled` (which NO shipped instruct preset carries: it is a user toggle, not a
            // template property) must survive the pick. A wholesale replace reads the struct default
            // and silently switches instruct wrapping OFF, so the user picks a template and gets LESS
            // templating: the prompt would fall back to bare "Name: mes" lines.
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('instruct-input_sequence')", 4000);
            await pick('fmt-instruct-preset', 'Hostile');
            const stillEnabled = await page.eval("document.getElementById('instruct-enabled').checked");
            const hostileOpts = await optionsOf('fmt-instruct-preset');
            await page.click('#d-formatting');
            await page.waitFor("!document.getElementById('instruct-input_sequence')", 3000);
            await sendProbe('does the hostile preset still apply its good fields');
            const hostilePrompt = await promptNow();
            row('must', hostilePrompt.includes('<|hostile_user|>') && hostilePrompt.includes('<|hostile_bot|>'),
                'C-PRE-TPL-6 a hostile preset still applies the fields that ARE readable',
                `user=${hostilePrompt.includes('<|hostile_user|>')} bot=${hostilePrompt.includes('<|hostile_bot|>')}`);
            // The prompt must END on the preset's own output sequence, because that is the reply
            // prime. It is the one observable that isolates `enabled`: with instruct off,
            // continuationPrefix primes with a bare "<char>:" no matter what the sequences say.
            // NOT the checkbox (its `checked` DOM property survives a VDOM patch that drops the
            // attribute, so it reads true either way: asserting on it proves nothing), and NOT a
            // hardcoded name regex (this chat's character is not named what a guess would guess).
            // Both of those were the first draft, and both stayed green with the fix broken.
            const primed = hostilePrompt.trimEnd().endsWith('<|hostile_bot|>');
            row('must', primed,
                'C-PRE-TPL-7 a preset carrying no `enabled` key leaves instruct wrapping ON',
                `primedWithSequence=${primed} tail=${JSON.stringify(hostilePrompt.trimEnd().slice(-24))} checkbox=${stillEnabled}`);
            row('must', hostileOpts.length === 3,
                'C-PRE-TPL-8 a hostile preset costs its own bad fields and not the list',
                `options=${JSON.stringify(hostileOpts)}`);
            // `wrap` arrived as the junk string "yes". It defaults TRUE, so it must STAY true: read as
            // false it would unwrap every turn, and the separator newline after the prefix is the
            // observable that says which happened.
            row('must', hostilePrompt.includes('<|hostile_user|>\n'),
                'C-PRE-TPL-9 an unreadable bool string keeps its default rather than flipping the prompt shape',
                `wrapped=${hostilePrompt.includes('<|hostile_user|>\n')}`);

            // THE ANCHOR MIGRATION, and it is the one that fails SILENTLY. "Unmigrated" is what a
            // hand-written or older preset looks like: a story string with no anchors and no
            // story_string_position. Picking it must run the same one-time migration the classic
            // client runs on a picked preset (power-user.js:2032), or the author's note renders
            // NOWHERE and nothing on screen says why. The note is put at the anchorAfter slot first,
            // so it can only arrive through a slot the migration inserted.
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('an-prompt')", 4000);
            await pick('an-position', '0');
            await page.eval("(function(){const n=document.getElementById('an-prompt');n.value='The lighthouse is unmanned.';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(150);
            await pick('fmt-context-preset', 'Unmigrated');
            await page.click('#d-formatting');
            await page.waitFor("!document.getElementById('an-prompt')", 3000);
            await sendProbe('does the note survive an unmigrated context preset');
            const notePrompt = await promptNow();
            row('must', notePrompt.includes('The lighthouse is unmanned.'),
                'C-PRE-TPL-10 an author\'s note still reaches the prompt after picking a context preset that predates the anchors',
                `notePresent=${notePrompt.includes('The lighthouse is unmanned.')}`);
            // The preset really did take effect (its own story string is in play) and the migration
            // did not leave the anchor handlebars sitting literal in the prompt.
            row('must', !notePrompt.includes('{{anchorAfter}}') && !notePrompt.includes('{{#if'),
                'C-PRE-TPL-11 the migrated story string renders rather than shipping literal handlebars',
                `leaked=${notePrompt.includes('{{anchorAfter}}') || notePrompt.includes('{{#if')}`);

            // THE SAVE CONTRACT. The field names ARE the contract: the route 400s without `preset` or
            // `name`, and apiId is what picks the directory it writes to (presets.js:29-32).
            await page.click('#d-formatting');
            await page.waitFor("document.getElementById('context-preset-name')", 4000);
            await page.eval("(function(){const n=document.getElementById('context-preset-name');n.value='Lighthouse';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(150);
            await page.click('#context-preset-name ~ button');
            const savedOk = await page.waitFor("document.getElementById('context-preset-name-status').textContent === 'Preset saved'", 5000);
            const sent = (await (await fetch(`${args.base}/dev/state`)).json()).preset_save;
            row('must', savedOk && !!sent && sent.apiId === 'context' && sent.name === 'Lighthouse',
                'C-PRE-TPL-12 saving a preset posts the name and the apiId the route switches on',
                `sent=${JSON.stringify({ name: sent && sent.name, apiId: sent && sent.apiId })}`);
            row('must', !!sent && !!sent.preset && typeof sent.preset.story_string === 'string' && sent.preset.story_string.length > 0 && sent.preset.name === 'Lighthouse',
                'C-PRE-TPL-13 the saved preset body carries the live template, not an empty object',
                `story_len=${sent && sent.preset && sent.preset.story_string && sent.preset.story_string.length} name=${sent && sent.preset && sent.preset.name}`);

            // A saved preset must be pickable NOW. The library is re-read after a save, so the name
            // appears without a reload; without that the user saves a preset and cannot see it.
            const grownOpts = await (async () => {
                for (let i = 0; i < 20; i++) {
                    const o = await optionsOf('fmt-context-preset');
                    if (o.includes('Lighthouse')) return o;
                    await sleep(200);
                }
                return await optionsOf('fmt-context-preset');
            })();
            row('must', grownOpts.includes('Lighthouse'),
                'C-PRE-TPL-14 a just-saved preset is pickable without a reload',
                `options=${JSON.stringify(grownOpts)}`);

            // THE DURABLE WRITE. A pick rides reading_prefs' ONE debounced saver, and nothing above
            // proves it: every row up to here reads the LIVE templates or the prompt, all of which
            // are served from memory. Deleting the scheduleSave() call left all fifteen green, which
            // is the half-persisted panel this project already shipped once: the pick works all
            // session, survives a reload out of localStorage, and another browser, another device and
            // the classic client see the old template forever.
            //
            // Assert the BLOB THE SERVER HOLDS, never a reloaded panel: a reload row passes on
            // localStorage alone and proves nothing about the channel that would be missing.
            // #d-formatting TOGGLES, so a blind click here CLOSES the drawer the save rows left open.
            // Ask, then open only if it is shut.
            const ensureFormattingOpen = async () => {
                if (await page.eval("!!document.querySelector('#dd-btn-fmt-instruct-preset')")) return;
                await page.click('#d-formatting');
                await page.waitFor("!!document.querySelector('#dd-btn-fmt-instruct-preset')", 4000);
            };
            await ensureFormattingOpen();
            await pick('fmt-instruct-preset', 'Alpaca');
            const blobSeq = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const s = JSON.parse(r.settings || '{}');
                    const pu = s.power_user || {};
                    const seq = pu.instruct && pu.instruct.input_sequence;
                    if (seq === '### Instruction:') return seq;
                    await sleep(200);
                }
                const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                const s = JSON.parse(r.settings || '{}');
                return (s.power_user && s.power_user.instruct && s.power_user.instruct.input_sequence) || 'NEVER-ARRIVED';
            })();
            row('must', blobSeq === '### Instruction:',
                'C-PRE-TPL-16 a picked instruct preset reaches the settings blob, not just this browser',
                `blobInputSequence=${JSON.stringify(blobSeq)}`);

            // The context half rides the same saver and is a separate merge, so a pick that persisted
            // instruct alone would still lose the story string.
            // The predicate must be something ONLY the picked "Unmigrated" preset can produce, and
            // that rules out the anchors on their own: the fixture's OWN ChatML context already
            // carries {{anchorAfter}}, so an anchors-only assertion passes on the untouched default
            // blob and proves nothing. It did: this row's first draft stayed green with the
            // scheduleSave() deleted. `{{#if personality}}` is unique to Unmigrated and `{{#if
            // system}}` is unique to the fixture default, so together they say WHICH story string
            // landed; the anchors then say it was migrated on the way.
            const landed = (str) => typeof str === 'string'
                && str.includes('{{#if personality}}') && !str.includes('{{#if system}}')
                && str.includes('{{anchorBefore}}') && str.includes('{{anchorAfter}}');
            const blobStory = await (async () => {
                const deadline = Date.now() + 8000;
                let last = 'NEVER-ARRIVED';
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const s = JSON.parse(r.settings || '{}');
                    const ctx = (s.power_user || {}).context;
                    if (ctx && typeof ctx.story_string === 'string') last = ctx.story_string;
                    if (landed(last)) return last;
                    await sleep(200);
                }
                return last;
            })();
            row('must', landed(blobStory),
                'C-PRE-TPL-17 the picked context preset lands in the blob with its anchors already migrated',
                `blobStory=${JSON.stringify(blobStory.slice(0, 72))}`);

            // WHAT A SAVE KEEPS. Instruct is on Alpaca from C-PRE-TPL-16, so this is the round trip a
            // user performs: pick a shipped preset, name it, save it. The save must carry the fields
            // this client does not model back out of the file it picked.
            //
            // ONLY A BROWSER CAN PROVE THIS ONE. saveBody's rules are proven natively 6 ways over, but
            // the BASE it preserves from is chosen by template_presets.baseFor, which imports zx and
            // therefore has NO native test at all: stub it to null and all 426 native tests stay green
            // while every save silently deletes the same 7 fields again. This row is the only thing
            // standing on that wire. It reads the body THE SERVER RECEIVED (/dev/state.preset_save),
            // never the panel.
            await ensureFormattingOpen();
            await page.eval("(function(){const n=document.getElementById('instruct-preset-name');n.value='My Alpaca';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await sleep(150);
            await page.click('#instruct-preset-name ~ button');
            const savedInstruct = await page.waitFor("document.getElementById('instruct-preset-name-status').textContent === 'Preset saved'", 5000);
            const sentI = (await (await fetch(`${args.base}/dev/state`)).json()).preset_save;
            const iPreset = (sentI && sentI.preset) || {};
            // The two the shipped files really carry a non-default value for: sequences_as_stop_strings
            // is true in 37 of 38, and the alignment message is prose in 5. A dropped key reads back as
            // undefined, and the classic client's apply loop then keeps its LIVE value rather than the
            // file's, which is how a save silently reverts them.
            const keptStops = iPreset.sequences_as_stop_strings === true;
            const keptAlign = typeof iPreset.user_alignment_message === 'string' && iPreset.user_alignment_message.startsWith("Let's get started");
            // Presence, not truth, for the five whose shipped value IS the type default: the key going
            // missing is the defect, and `=== ''` would pass just as well on a key that was never sent.
            const keptKeys = ['activation_regex', 'skip_examples', 'first_input_sequence', 'last_input_sequence', 'last_system_sequence']
                .filter((k) => iPreset[k] === undefined);
            row('must', savedInstruct && sentI && sentI.apiId === 'instruct' && keptStops && keptAlign && keptKeys.length === 0,
                'C-PRE-TPL-18 saving a picked preset keeps the fields this client does not model',
                `stops=${iPreset.sequences_as_stop_strings} align=${JSON.stringify(String(iPreset.user_alignment_message).slice(0, 24))} dropped=${JSON.stringify(keptKeys)}`);
            // The name is the one place the panel MUST beat the base: same key, both halves carry it.
            row('must', iPreset.name === 'My Alpaca' && sentI.name === 'My Alpaca',
                'C-PRE-TPL-19 the typed name overwrites the base preset\'s own name in both places',
                `presetName=${JSON.stringify(iPreset.name)} envelopeName=${JSON.stringify(sentI && sentI.name)}`);
            // `enabled` is instruct mode itself. The classic client strips it from every preset it
            // writes; one riding a shared file switches instruct OFF for whoever picks it.
            row('must', iPreset.enabled === undefined && iPreset.preset === undefined,
                'C-PRE-TPL-20 a saved preset carries neither instruct mode itself nor a name for the file',
                `enabled=${iPreset.enabled} preset=${iPreset.preset}`);

            // The C-CFG-17 shape, this picker's copy: Escape must close the MENU and leave the panel.
            await ensureFormattingOpen();
            await page.click('[data-dd-toggle="fmt-instruct-preset"]');
            await page.waitFor("document.getElementById('dd-list-fmt-instruct-preset')", 2500);
            for (const type of ['rawKeyDown', 'keyUp']) {
                await page.cdp.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, page.sessionId);
            }
            const menuClosed = await page.waitFor("!document.getElementById('dd-list-fmt-instruct-preset')", 2500);
            const panelAlive = await page.eval("!!document.getElementById('instruct-input_sequence')");
            row('must', menuClosed && panelAlive,
                'C-PRE-TPL-15 Escape closes the preset menu without dismissing the formatting panel',
                `menuClosed=${menuClosed} panelAlive=${panelAlive}`);
        }

        // --- C-PRE-TPL-FAIL: the load-failure state, its retry, and the loop it must not do ---
        // THIS BLOCK IS WHY THE BUG SHIPPED: there was no load-failure row here at all, so the panel
        // painted "Reading the preset library..." forever at anyone whose settings fetch failed, with
        // no error and no retry, and every existing row stayed green because they all load fine.
        // The panel reads the SAME endpoint boot reads, so the failure is armed AFTER boot: a standing
        // failure would break the app rather than the picker.
        {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await (await fetch(`${args.base}/dev/arm-settings-fail`)).json();
            await page.click('#d-formatting');
            const hintNow = () => page.eval(
                "(document.getElementById('instruct-preset-name-hint')||{}).textContent || ''");
            const failShown = await page.waitFor(
                "!!document.querySelector('.tpl-preset-retry') && (document.getElementById('instruct-preset-name-hint')||{}).textContent.indexOf('did not load') >= 0", 6000);
            const failHint = await hintNow();
            row('must', failShown,
                'C-PRE-TPL-21 a preset library that fails to load says so and offers a retry',
                `retryShown=${failShown} hint=${JSON.stringify(failHint.slice(0, 40))}`);
            // The defect itself, named: the panel must not still be claiming it is reading.
            row('must', failShown && failHint.indexOf('Reading the preset library') < 0,
                'C-PRE-TPL-22 a failed load stops claiming it is still reading the library',
                `hint=${JSON.stringify(failHint.slice(0, 40))}`);

            // THE LOOP. ensureLoaded fires from the panel's RENDER, so a failure that returned to
            // .idle would fetch, fail, rerender and hammer the failing server forever. Count the
            // server's own settings reads across a second of failure state: a loop is an unbounded
            // climb. config_state's twin read 423 here before its latch.
            const c0 = (await (await fetch(`${args.base}/dev/state`)).json()).settings_get_count;
            await sleep(1000);
            const c1 = (await (await fetch(`${args.base}/dev/state`)).json()).settings_get_count;
            row('must', c1 - c0 <= 1,
                'C-PRE-TPL-23 a failed preset load retries on the user, not in a loop',
                `settingsReadsWhileFailed=${c1 - c0}`);

            // The retry must actually recover, in the same panel, with no reload. Assert the fixture's
            // own preset NAMES are back rather than a count: an earlier row in this run saved
            // "My Alpaca", and the server serves it too, so a count would pin this row to that one.
            await (await fetch(`${args.base}/dev/disarm-settings-fail`)).json();
            await page.click('.tpl-preset-retry');
            const recovered = await page.waitFor(
                "!document.querySelector('.tpl-preset-retry')", 6000);
            await page.click('[data-dd-toggle="fmt-instruct-preset"]');
            await page.waitFor("document.querySelectorAll('#dd-list-fmt-instruct-preset [role=option]').length > 0", 6000);
            const backOpts = JSON.parse(await page.eval(
                "JSON.stringify(Array.from(document.querySelectorAll('#dd-list-fmt-instruct-preset [role=option]')).map(o => o.textContent))"));
            const allBack = recovered && ['ChatML', 'Alpaca', 'Hostile'].every((n) => backOpts.includes(n));
            row('must', allBack,
                'C-PRE-TPL-24 the retry loads the library without a reload',
                `retryGone=${recovered} options=${JSON.stringify(backOpts)}`);

            // SAVE-AS MUST NOT COME PRE-LOADED WITH A SHIPPED PRESET'S NAME. The field used to prefill
            // the live template's name, so the panel's loudest control sat ONE CLICK from replacing
            // ChatML: the server takes that write with no exists-check and no confirmation
            // (presets.js:57 writeFileAtomic). Nothing has been typed in this block, and the picker is
            // on ChatML, so this is exactly that click.
            await page.click('[data-dd-toggle="fmt-instruct-preset"]');
            const nameValue = await page.eval("document.getElementById('instruct-preset-name').value");
            const savesBefore = (await (await fetch(`${args.base}/dev/state`)).json()).preset_save;
            await page.click('#instruct-preset-name ~ button');
            await sleep(400);
            const savesAfter = (await (await fetch(`${args.base}/dev/state`)).json()).preset_save;
            const statusText = await page.eval(
                "(document.getElementById('instruct-preset-name-status')||{}).textContent || ''");
            // The property, not the preset name I assumed: NO WRITE REACHED THE SERVER. Keying on
            // `name === 'ChatML'` looked right and was blind, because the picker is on Alpaca by here;
            // the restored prefill saved "Alpaca" and a ChatML-shaped check would have waved it past.
            const wrote = JSON.stringify(savesBefore) !== JSON.stringify(savesAfter);
            row('must', nameValue === '' && !wrote && statusText.indexOf('Name the preset') >= 0,
                'C-PRE-TPL-25 save-as starts empty, so one click cannot overwrite the shipped preset the picker is on',
                `value=${JSON.stringify(nameValue)} status=${JSON.stringify(statusText)} wroteToServer=${wrote} lastSave=${JSON.stringify(savesAfter && savesAfter.name)}`);

            // The 44px touch target at phone width, MEASURED. A class-name grep would pass on a token
            // tailwind never generated (ZX14: its extractor silently drops classes), so the only honest
            // check is the rendered height.
            const wideW = await page.eval('window.innerWidth');
            await page.cdp.send('Emulation.setDeviceMetricsOverride',
                { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, page.sessionId);
            await page.waitFor('window.innerWidth === 390', 3000);
            const tap = JSON.parse(await page.eval(
                "(function(){const b=document.querySelector('#instruct-preset-name ~ button');"
                + "if(!b)return JSON.stringify({err:'no save button'});"
                + "return JSON.stringify({h:Math.round(b.getBoundingClientRect().height)});})()"));
            await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
            // The override returns before the relayout, so a later row would inherit a half-restored
            // page (the W6-10 lesson).
            const tapRestored = await page.waitFor(`window.innerWidth === ${wideW}`, 5000);
            row('must', tap.h >= 44 && tapRestored,
                'C-PRE-TPL-26 the preset save button clears the 44px touch target at 390px',
                `saveHeight=${tap.h}px restored=${tapRestored} wide=${wideW}`);
        }

        // --- C-PRE-SAM: the sampler preset picker (list, pick, wire, save, persist) ---
        // The presets arrive as PARALLEL ARRAYS of (name, RAW FILE TEXT) in the /api/settings/get
        // ENVELOPE, beside `settings` rather than inside it. They are user-writable files that the
        // server only validates as parseable JSON, so the fixture serves deliberately hostile ones
        // and these rows are what prove one bad file cannot empty the list.
        console.log('== sampler presets ==');
        {
            const openPresets = async () => {
                await page.navigate(`${args.base}/`);
                await openRecentChat();
                await page.click('#d-ai_config');
                await page.waitFor("document.getElementById('dd-btn-sampler-preset')", 4000);
            };
            // The options exist only while the menu is open, and the list is fetched lazily on the
            // panel's first render, so the wait is for an OPTION to appear rather than for the
            // button (which is present from the first paint and would make the wait return at once:
            // the first draft of this waited on a `li, #dd-btn-...` selector, the button half
            // matched instantly, and the two rows below read the face before the fetch had landed).
            const openMenu = async () => {
                await page.click('#dd-btn-sampler-preset');
                await page.waitFor("document.querySelectorAll('#dd-list-sampler-preset li').length > 0", 5000);
            };
            const pick = async (name) => {
                await openMenu();
                await page.click(`#dd-list-sampler-preset li[data-dd-value="${name}"]`);
                await page.waitFor(`document.querySelector('#dd-btn-sampler-preset span').textContent === ${JSON.stringify(name)}`, 3000);
                // The pick writes through the debounced saver; give the DOM sync a beat.
                await sleep(150);
            };
            const sampler = async (id) => page.eval(`document.getElementById('sampler-${id}').value`);

            // The backend the user is on BEFORE any preset is picked. Captured rather than hardcoded:
            // the C-CONN rows earlier in this run legitimately change the type, and the invariant is
            // that a PICK does not move it, not that it holds some particular value.
            const readConn = async () => {
                const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                const tg = (JSON.parse(r.settings || '{}')).textgenerationwebui_settings || {};
                return JSON.stringify({ type: tg.type, server_urls: tg.server_urls });
            };
            const connBefore = await readConn();

            await openPresets();
            await openMenu();

            // The face must show the name the BLOB carries under the classic client's own key
            // (textgenerationwebui_settings.preset), not a placeholder. Read once the list has
            // arrived: the face resolves the name against the options, so before the fetch lands it
            // legitimately reads "Select..." and asserting it earlier would be asserting the race.
            const faceAtOpen = await page.eval("document.querySelector('#dd-btn-sampler-preset span').textContent");
            row('must', faceAtOpen === 'Big O',
                'C-PRE-SAM-1 the picker opens on the preset the settings blob names', `face=${faceAtOpen}`);

            // THE TOLERANCE ROW FOR THE LIST. The fixture serves 6 entries: 4 usable, one whose body
            // is valid JSON but not an object ("Broken": 42), one whose NAME is the number 41. The
            // two unusable ones must cost THEMSELVES and nothing else. A typed parse of this array
            // would have rendered ZERO options, which is the bug that emptied the character list.
            const labels = JSON.parse(await page.eval(
                "JSON.stringify(Array.from(document.querySelectorAll('#dd-list-sampler-preset li')).map(x => x.textContent))"));
            const listOk = labels.length === 4
                && ['Deterministic', 'Big O', 'Classic Saved', 'Hostile Shapes'].every((n) => labels.includes(n))
                && !labels.includes('Broken') && !labels.includes('41');
            row('must', listOk,
                'C-PRE-SAM-2 an unreadable preset costs that preset and never the list',
                `options=${JSON.stringify(labels)}`);
            await page.click('#dd-btn-sampler-preset');
            await sleep(100);

            // Picking must move the panel, AND move the two budget dials the preset spells
            // genamt/max_length rather than amount_gen/max_context. Reading them under the blob
            // spelling would silently ignore both, and every preset the classic client saves has them.
            await pick('Classic Saved');
            const cs = { temp: await sampler('temp'), top_k: await sampler('top_k'), max_tokens: await sampler('max_tokens'), max_context: await sampler('max_context') };
            row('must', cs.temp === '0.66' && cs.top_k === '20' && cs.max_tokens === '384' && cs.max_context === '32768',
                'C-PRE-SAM-3 picking a preset applies its samplers, dials included, under the preset spelling',
                `temp=${cs.temp} top_k=${cs.top_k} amount_gen=${cs.max_tokens} max_context=${cs.max_context}`);

            // Big O carries no dials at all, which is the shape of every SHIPPED preset. Absent must
            // KEEP: a snap-to-default here would silently reset the user's prompt window to 512/8192
            // every time they picked one.
            await pick('Big O');
            const bo = { temp: await sampler('temp'), top_p: await sampler('top_p'), max_tokens: await sampler('max_tokens'), max_context: await sampler('max_context') };
            row('must', bo.temp === '0.87' && bo.top_p === '0.99' && bo.max_tokens === '384' && bo.max_context === '32768',
                'C-PRE-SAM-4 a preset that carries no dials leaves them where it found them',
                `temp=${bo.temp} top_p=${bo.top_p} amount_gen=${bo.max_tokens} max_context=${bo.max_context}`);

            // THE HOSTILE-FIELD ROW. Every field of "Hostile Shapes" is a different wrong shape:
            // temp is the quoted "0.55" (a hand-edit, still a number, so it MUST apply), top_p null,
            // top_k an object, min_p a bool, rep_pen a non-numeric string, genamt an array,
            // max_length a word. Only temp may move; every other sampler must still hold Big O's
            // value, which is what proves a bad FIELD costs that field alone.
            await pick('Hostile Shapes');
            const h = {
                temp: await sampler('temp'), top_p: await sampler('top_p'), top_k: await sampler('top_k'),
                min_p: await sampler('min_p'), rep_pen: await sampler('rep_pen'),
                max_tokens: await sampler('max_tokens'), max_context: await sampler('max_context'),
            };
            const hostileOk = h.temp === '0.55' && h.top_p === '0.99' && h.top_k === '100'
                && h.min_p === '0.05' && h.rep_pen === '1.05' && h.max_tokens === '384' && h.max_context === '32768';
            row('must', hostileOk,
                'C-PRE-SAM-5 a hostile field costs that field and the preset applies the rest',
                `temp=${h.temp} top_p=${h.top_p} top_k=${h.top_k} min_p=${h.min_p} rep_pen=${h.rep_pen} amount_gen=${h.max_tokens} max_context=${h.max_context}`);

            // THE USER MUST BE TOLD WHAT IT DROPPED. Two of the six fixture entries are unusable, and
            // a file the user can see on disk that never appears in the picker, with the reason only
            // in a console they will never open, is the silent failure this parse exists to avoid.
            const notice = await page.eval(
                "document.getElementById('preset-unreadable') ? document.getElementById('preset-unreadable').textContent : ''");
            row('must', notice.indexOf('2 preset files could not be read') >= 0,
                'C-PRE-SAM-14 the panel says how many preset files it could not read',
                `notice=${JSON.stringify(notice)}`);

            // AND IT MUST BE SAID OUT LOUD. The notice arrives with a fetch, long after the panel
            // renders, so a reader who is not looking at it is told by the live region or not at
            // all. Read the ATTRIBUTES that make it announce rather than the text C-PRE-SAM-14
            // already owns: a row that only found the element passed with no announcement at all.
            const live = await page.eval(`(function(){
                const n=document.getElementById('preset-unreadable');
                if(!n)return JSON.stringify({err:'no #preset-unreadable'});
                const f=document.getElementById('preset-save-name');
                return JSON.stringify({role:n.getAttribute('role'),live:n.getAttribute('aria-live'),
                    describedBy:f?f.getAttribute('aria-describedby'):null,
                    saysSomething:n.textContent.trim().length>0});})()`);
            const lv = JSON.parse(live);
            row('must', lv.role === 'status' && lv.live === 'polite' && lv.saysSomething
                && (lv.describedBy || '').split(/\s+/).includes('preset-unreadable'),
                'C-PRE-SAM-19 the unreadable-files notice announces itself rather than waiting to be found',
                `role=${lv.role} ariaLive=${lv.live} describedBy=${JSON.stringify(lv.describedBy)} hasText=${lv.saysSomething}`);

            // THE CONNECTION MUST SURVIVE A PICK. "Classic Saved" carries `type` and `server_urls`
            // pointing at a backend that is not the user's. A picker that applied a preset by
            // overwriting the textgen section would swap the user's backend out from under them the
            // moment they picked it, and the only symptom would be that generation stopped working.
            // Wait for the picked samplers to land in the blob first, so this reads a blob the picks
            // have definitely been written to rather than one they had not reached yet.
            await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const tg = (JSON.parse(r.settings || '{}')).textgenerationwebui_settings || {};
                    if (tg.temp === 0.55) return;
                    await sleep(200);
                }
            })();
            const connAfter = await readConn();
            const c = JSON.parse(connAfter);
            // Three things, because "unchanged" ALONE is blind: an earlier panel open in this run
            // also triggers the save path, so a clobber can land before this block's baseline and
            // then compare equal to itself. Assert the connection is still THERE, that it is not the
            // preset's own backend, and only then that the picks did not move it.
            const connIntact = !!c.type && !!c.server_urls && Object.keys(c.server_urls).length > 0;
            const notThePresets = c.type !== 'koboldcpp' && !(c.server_urls && c.server_urls.koboldcpp);
            row('must', connIntact && notThePresets && connAfter === connBefore,
                'C-PRE-SAM-15 picking a preset never touches the backend connection',
                `intact=${connIntact} notPresets=${notThePresets} unchanged=${connAfter === connBefore} after=${connAfter}`);

            // THE WIRE ROW. The panel's displayed value proves nothing about what send carries. Clear
            // the recorded generate first and key the wait on the message COUNT: a previous send's
            // FIN already sits in the log, so a naive predicate would match instantly, skip the send
            // and read a body this row never caused (the sendProbe discipline from C-CFG).
            await page.click('#panel-view .icon[data-icon="close"]');
            await sleep(200);
            await (await fetch(`${args.base}/dev/clear-generate`)).json();
            const before = await page.eval("document.querySelectorAll('#chat .mes').length");
            await page.focus('#send_textarea');
            await page.insertText('does the picked preset ride the request');
            await page.click('#composer button[aria-label="Send"]');
            const grew = await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${before} + 2 && ${idle}`, 15000);
            if (!grew) throw new Error('C-PRE-SAM: no reply after the preset send');
            const gen = await (await fetch(`${args.base}/dev/state`)).json();
            row('must', !!gen.last_generate_body, 'C-PRE-SAM-6a the probe send actually reached the backend',
                `recorded=${!!gen.last_generate_body}`);
            const sent = gen.last_generate_body && JSON.parse(gen.last_generate_body);
            // 0.55 is the quoted temp from the hostile preset: it reached the wire through the panel,
            // the clamp and the connection, which is the whole chain this half was built for.
            row('must', sent && sent.temperature === 0.55 && sent.max_tokens === 384,
                'C-PRE-SAM-6 a picked preset reaches the generate request body',
                `temperature=${sent && sent.temperature} max_tokens=${sent && sent.max_tokens}`);

            // THE SAVE ROW. The field names ARE the contract: /api/presets/save 400s without `name`
            // or `preset`, and routes the file by `apiId`. Assert the POST the client actually made.
            await page.click('#d-ai_config');
            await page.waitFor("document.getElementById('preset-save-name')", 4000);
            await page.focus('#preset-save-name');
            await page.insertText('My Saved Preset');
            await page.click('.preset-save');
            const saveBody = await (async () => {
                const deadline = Date.now() + 6000;
                while (Date.now() < deadline) {
                    const st = (await (await fetch(`${args.base}/dev/state`)).json()).preset_save;
                    if (st) return st;
                    await sleep(150);
                }
                return null;
            })();
            const saveOk = !!saveBody && saveBody.name === 'My Saved Preset'
                && saveBody.apiId === 'textgenerationwebui'
                && !!saveBody.preset && Object.keys(saveBody.preset).length > 0;
            row('must', saveOk,
                'C-PRE-SAM-7 saving posts the real contract: name, apiId and a preset body',
                `name=${saveBody && saveBody.name} apiId=${saveBody && saveBody.apiId} keys=${saveBody && saveBody.preset ? Object.keys(saveBody.preset).length : 0}`);

            // The saved file must carry the samplers the panel holds AND the ~4 keys the panel does
            // not model, or a save silently strips them. It came from the hostile preset's base, so
            // the base's own extra keys are what must survive.
            const savedPreset = saveBody && saveBody.preset;
            row('must', savedPreset && savedPreset.temp === 0.55 && savedPreset.genamt === 384
                && savedPreset.max_length === 32768,
                'C-PRE-SAM-8 the saved preset carries the live samplers under the preset spelling',
                `temp=${savedPreset && savedPreset.temp} genamt=${savedPreset && savedPreset.genamt} max_length=${savedPreset && savedPreset.max_length}`);

            // A preset must not name itself: the base it was built from carried `preset`, and a file
            // that names itself fights the blob's own selected-preset key on the next load. The name
            // rides the envelope, which is where the server reads it from.
            row('must', savedPreset && savedPreset.preset === undefined,
                'C-PRE-SAM-16 a saved preset never names itself',
                `presetKeyInFile=${savedPreset && savedPreset.preset}`);

            // THE PERSISTENCE ROW, and it asserts the BLOB rather than a reload. config_state writes
            // two channels: localStorage survives a reload on its own, so a reload row stays green
            // while the DURABLE write is broken and every other browser and the classic client see
            // the old value forever. The saver is debounced, so poll the server's own copy.
            const blobPreset = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const s = JSON.parse(r.settings || '{}');
                    const p = s.textgenerationwebui_settings && s.textgenerationwebui_settings.preset;
                    if (p === 'My Saved Preset') return p;
                    await sleep(200);
                }
                return null;
            })();
            row('must', blobPreset === 'My Saved Preset',
                'C-PRE-SAM-9 the picked preset reaches the settings blob, not just this browser',
                `blobPreset=${blobPreset === null ? 'NEVER-ARRIVED' : blobPreset}`);

            // And the samplers it applied must be in the blob too, under the BLOB spelling this time
            // (amount_gen, not genamt): the preset file and the blob disagree on the name, and the
            // panel is the thing that has to get both right.
            const blobSamplers = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                    const s = JSON.parse(r.settings || '{}');
                    const tg = s.textgenerationwebui_settings || {};
                    if (tg.temp === 0.55 && s.amount_gen === 384) return { temp: tg.temp, amount_gen: s.amount_gen, max_context: s.max_context };
                    await sleep(200);
                }
                return null;
            })();
            row('must', blobSamplers && blobSamplers.temp === 0.55 && blobSamplers.amount_gen === 384 && blobSamplers.max_context === 32768,
                'C-PRE-SAM-10 the samplers a preset applied reach the blob under the blob spelling',
                `blob=${JSON.stringify(blobSamplers)}`);

            // THE REJECTED SAVE. The server sanitizes the filename and 400s when the result is empty
            // (presets.js:44), so a name the CLIENT accepts can still be refused: "con" is a reserved
            // Windows device name and sanitize-filename reduces it to "". Nothing in the UI hints at
            // that, which is exactly why the failure has to be handled rather than assumed away.
            const typeName = async (n) => page.eval(
                `document.getElementById('preset-save-name').value = ${JSON.stringify(n)}`);
            const faceOf = async () => page.eval("document.querySelector('#dd-btn-sampler-preset span').textContent");
            const blobPresetNow = async () => {
                const r = await (await fetch(`${args.base}/api/settings/get`, { method: 'POST' })).json();
                const s = JSON.parse(r.settings || '{}');
                return (s.textgenerationwebui_settings || {}).preset;
            };

            const faceBeforeReject = await faceOf();
            await typeName('con');
            await page.click('.preset-save');
            const saidNo = await page.waitFor(
                "document.getElementById('preset-status').textContent.indexOf('not saved') >= 0", 5000);
            await sleep(600);
            const faceAfterReject = await faceOf();
            const blobAfterReject = await blobPresetNow();
            // The selection must not move to a file the server refused to write, and the blob must
            // not record it either: an optimistic commit here would leave the picker, and every
            // other client, naming a preset that does not exist.
            row('must', saidNo && faceAfterReject === faceBeforeReject && blobAfterReject !== 'con'
                && faceBeforeReject === 'My Saved Preset',
                'C-PRE-SAM-17 a save the server rejects keeps the old selection and says so',
                `saidNo=${saidNo} face=${faceAfterReject} blobPreset=${blobAfterReject}`);

            // THE SANITIZED SAVE. "../x" is accepted by the client and WRITTEN AS "..x": the server
            // strips the slash and returns the name it used. The picker must adopt the SERVER's name,
            // because that is the file that now exists; adopting the typed one would name a ghost.
            await typeName('../x');
            await page.click('.preset-save');
            const adopted = await page.waitFor(
                "document.querySelector('#dd-btn-sampler-preset span').textContent === '..x'", 6000);
            const blobAdopted = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    if (await blobPresetNow() === '..x') return '..x';
                    await sleep(200);
                }
                return await blobPresetNow();
            })();
            row('must', adopted && blobAdopted === '..x',
                'C-PRE-SAM-18 the picker adopts the name the server actually wrote',
                `face=${await faceOf()} blobPreset=${blobAdopted}`);

            // THE DEAD BUTTON. An empty name is refused in memory and, until this row, the refusal
            // was never painted: the click did NOTHING a user could see, and the only cue that the
            // app had noticed at all was a status line still reporting the previous save. Assert the
            // rendered TEXT moves to the refusal's own words; the line is never that by any other
            // route, and asserting merely that the element exists passes on the dead build.
            const statusOf = async () => page.eval("document.getElementById('preset-status').textContent");
            const staleStatus = await statusOf();
            await typeName('');
            await page.click('.preset-save');
            const refused = await page.waitFor(
                "document.getElementById('preset-status').textContent === 'Name the preset first.'", 4000);
            const afterEmpty = await statusOf();
            row('must', refused && afterEmpty !== staleStatus,
                'C-PRE-SAM-20 saving with no name says so on screen instead of doing nothing',
                `before=${JSON.stringify(staleStatus)} after=${JSON.stringify(afterEmpty)} changed=${afterEmpty !== staleStatus}`);

            // THE IN-FLIGHT LINE. It is set before the request and overwritten by the reply, so on a
            // build that only paints at the reply it is a string that never reaches a screen. The
            // mock answers instantly, which would make the pending state unobservable however
            // broken it was, so hold the save open and watch for the line through a real paint.
            await (await fetch(`${args.base}/dev/arm-preset-save-delay`)).json();
            await typeName('Slow Save');
            await page.click('.preset-save');
            const sawSaving = await page.waitFor(
                "document.getElementById('preset-status').textContent === 'Saving...'", 4000);
            const savingText = await statusOf();
            await (await fetch(`${args.base}/dev/disarm-preset-save-delay`)).json();
            // And it must be TRANSIENT: a "Saving..." that never clears is its own defect.
            const settled = await page.waitFor(
                "document.getElementById('preset-status').textContent === 'Preset saved'", 6000);
            row('must', sawSaving && settled,
                'C-PRE-SAM-21 a save in flight says so, and stops saying so when it lands',
                `sawSaving=${sawSaving} textWhileInFlight=${JSON.stringify(savingText)} settledToSaved=${settled}`);

            // THE ONE COMMITTING WRITE ON THE PANEL. Save wore the same outline as its own Reset:
            // same weight, so nothing said which button was the point. Measured through a PAINTED
            // canvas: the theme is oklch and Chrome hands the string back verbatim, so a computed
            // colour compared as RGB reads ~1:1 for every pair. The accent is read from the token
            // itself rather than a hardcoded rgb, so a retheme moves the row with the theme.
            const look = await page.eval(`(function(){${contrastFn}
                const b=document.querySelector('.preset-save'), r=document.querySelector('.cfg-reset');
                if(!b||!r)return JSON.stringify({err:'no .preset-save / .cfg-reset'});
                const probe=document.createElement('div');
                probe.style.cssText='background:var(--color-accent);color:var(--color-on-accent)';
                document.body.appendChild(probe);
                const p=getComputedStyle(probe), accent=p.backgroundColor, on=p.color;
                probe.remove();
                const s=getComputedStyle(b), rs=getComputedStyle(r), key=(c)=>rgb(c).join(',');
                return JSON.stringify({
                    fillIsAccent:key(s.backgroundColor)===key(accent),
                    textIsOnAccent:key(s.color)===key(on),
                    outweighsReset:key(s.backgroundColor)!==key(rs.backgroundColor),
                    textOnFill:Math.round(contrast(s.color,s.backgroundColor)*100)/100,
                    fill:s.backgroundColor,resetFill:rs.backgroundColor});})()`);
            const lk = JSON.parse(look);
            row('must', lk.fillIsAccent && lk.textIsOnAccent && lk.outweighsReset && lk.textOnFill >= 4.5,
                'C-PRE-SAM-22 the Save control is the panel\'s filled accent, not a twin of its Reset',
                `filledWithAccentToken=${lk.fillIsAccent} onAccentText=${lk.textIsOnAccent} differsFromReset=${lk.outweighsReset} textOnFill=${lk.textOnFill}:1 fill=${lk.fill} reset=${lk.resetFill}`);
        }

        // --- C-PRE-SAM-FAIL: the picker's load-failure state, its retry, and the loop it must not do ---
        // The panel reads the SAME endpoint boot reads, so the failure is armed one-shot AFTER boot:
        // a standing failure would break the app rather than the picker.
        {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await (await fetch(`${args.base}/dev/arm-settings-fail`)).json();
            await page.click('#d-ai_config');
            const failShown = await page.waitFor(
                "!!document.querySelector('.preset-retry') && document.getElementById('preset-status').textContent.indexOf('did not load') >= 0", 5000);
            row('must', failShown,
                'C-PRE-SAM-11 a preset list that fails to load says so and offers a retry',
                `retryShown=${failShown}`);

            // REGRESSION. The first draft of failPresetLoad re-armed the fetch and then rerendered,
            // and the panel's render is what fires the fetch: it refetched, failed, rerendered and
            // hammered the failing server forever. Count the server's own settings reads across a
            // second of failure state; a loop shows up here as an unbounded climb.
            const c0 = (await (await fetch(`${args.base}/dev/state`)).json()).settings_get_count;
            await sleep(1000);
            const c1 = (await (await fetch(`${args.base}/dev/state`)).json()).settings_get_count;
            row('must', c1 - c0 <= 1,
                'C-PRE-SAM-12 a failed preset load retries on the user, not in a loop',
                `settingsReadsWhileFailed=${c1 - c0}`);

            // THE LIVE REGION MUST PRE-DATE THE NEWS. A region inserted already holding its text
            // announces nothing: the reader had no region to be told about a change to. This is the
            // panel with NOTHING to report (the list never loaded), so the notice must be here and
            // empty, waiting. The C-PRE-SAM-19 attributes are asserted on the SILENT case too,
            // because that is the render that has to already be right when the count lands.
            const quiet = await page.eval(`(function(){
                const n=document.getElementById('preset-unreadable');
                if(!n)return JSON.stringify({present:false});
                return JSON.stringify({present:true,text:n.textContent,
                    role:n.getAttribute('role'),live:n.getAttribute('aria-live'),
                    hidden:getComputedStyle(n).display==='none'});})()`);
            const q = JSON.parse(quiet);
            row('must', q.present && q.text === '' && q.role === 'status' && q.live === 'polite' && q.hidden,
                'C-PRE-SAM-23 the notice\'s live region is already there, silent, before it has news',
                `present=${q.present} text=${JSON.stringify(q.text)} role=${q.role} ariaLive=${q.live} hiddenWhileEmpty=${q.hidden}`);

            // EVERY BUTTON ON THIS PANEL AT PHONE WIDTH. Measured, not asserted as a class: the
            // convention is a class string, but what a thumb hits is a rendered box. Driven here
            // rather than in the block above because Retry only exists in the failure state, and it
            // is the same 30px control as the other two. Restored below before any later row runs.
            const wideW = await page.eval('window.innerWidth');
            await page.cdp.send('Emulation.setDeviceMetricsOverride',
                { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, page.sessionId);
            await page.waitFor('window.innerWidth === 390', 3000);
            const taps = await page.eval(`(function(){
                const h=function(s){const e=document.querySelector(s);
                    return e?Math.round(e.getBoundingClientRect().height*10)/10:-1;};
                return JSON.stringify({save:h('.preset-save'),reset:h('.cfg-reset'),retry:h('.preset-retry')});})()`);
            const tp = JSON.parse(taps);
            await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
            const tapsRestored = await page.waitFor(`window.innerWidth === ${wideW}`, 5000);
            row('must', tp.save >= 44 && tp.reset >= 44 && tp.retry >= 44,
                'C-PRE-SAM-24 every control on the panel is thumb-sized at 390px',
                `save=${tp.save}px reset=${tp.reset}px retry=${tp.retry}px`);
            row('must', tapsRestored,
                'C-PRE-SAM-25 the 390px override is fully restored before later rows run',
                `wide=${wideW} now=${await page.eval('window.innerWidth')}`);

            // The retry must actually recover: the same panel, no reload. Assert the four fixture
            // presets are BACK rather than a count: an earlier row in this run saved a preset, and
            // the server serves it too, so a count would pin this row to that row having happened.
            await (await fetch(`${args.base}/dev/disarm-settings-fail`)).json();
            await page.click('.preset-retry');
            await page.click('#dd-btn-sampler-preset');
            const recovered = await page.waitFor(
                "document.querySelectorAll('#dd-list-sampler-preset li').length > 0", 5000);
            const back = JSON.parse(await page.eval(
                "JSON.stringify(Array.from(document.querySelectorAll('#dd-list-sampler-preset li')).map(x => x.textContent))"));
            const allBack = recovered
                && ['Deterministic', 'Big O', 'Classic Saved', 'Hostile Shapes'].every((n) => back.includes(n))
                && !back.includes('Broken');
            row('must', allBack,
                'C-PRE-SAM-13 the retry loads the presets without a reload',
                `options=${JSON.stringify(back)}`);
        }


        // --- C-CFG-SEL: a refetch must not deselect the character (char_api.rebuildCharacterStore) ---
        // clear() nulls selected_index and nothing put it back, so EVERY fetchCharacters silently
        // deselected the character app-wide: a card save, an import, a duplicate and an avatar replace
        // all refetch, and the chat reads the same selected(). No prior row caught it because they all
        // navigated and reselected right after a save, restoring the selection by accident before
        // anything looked. This row looks WITHOUT reselecting.
        {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-card_editor');
            const cardLoaded = await page.waitFor("document.getElementById('card-name')", 5000);

            // Duplicate refetches /characters/all, which is the rebuild path, with no navigation and
            // no reselect after it.
            await page.click('#d-characters');
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 5000);
            const selBefore = await page.eval("(function(){const r=document.querySelector('#chat-root .char-item.is-selected');return r?r.querySelector('.char-name').textContent:null})()");
            await page.focus("#chat-root .char-item.is-selected .char-row-act[data-char-action='duplicate']");
            await page.click("#chat-root .char-item.is-selected .char-row-act[data-char-action='duplicate']");
            // Wait on the SERVER seeing the duplicate, so the refetch it triggers has actually been
            // issued before the selection is read back.
            const dupSeen = await (async () => {
                const deadline = Date.now() + 4000;
                while (Date.now() < deadline) {
                    const s = await (await fetch(`${args.base}/dev/state`)).json();
                    if (s.duplicated_avatar) return true;
                    await sleep(100);
                }
                return false;
            })();
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 4000);
            await sleep(400);
            const selAfter = await page.eval("(function(){const r=document.querySelector('#chat-root .char-item.is-selected');return r?r.querySelector('.char-name').textContent:null})()");
            row('must', cardLoaded && dupSeen && selBefore != null && selAfter === selBefore,
                'C-CFG-SEL-1 a refetch keeps the same character selected',
                `dupSeen=${dupSeen} before=${JSON.stringify(selBefore)} after=${JSON.stringify(selAfter)}`);

            // The blast radius: the card editor reads the same selected(), so a deselect empties it.
            await page.click('#d-card_editor');
            const cardStillOpen = await page.waitFor("document.getElementById('card-name')", 4000);
            row('must', cardStillOpen,
                'C-CFG-SEL-2 the card editor still has its character after a refetch',
                `cardOpen=${cardStillOpen}`);
        }

        /* W6 */
        // Ten design findings against the panels. Three files had drifted in their own worktree
        // (character/persona actions + lists), and the rest were single-panel defects. Every row here
        // re-establishes its own state, so the block is position-independent.
        console.log('== W6 panel design fixes ==');
        {
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-characters');
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 5000);

            // A search that matches nothing is NOT the same nothing as a list that never loaded, and
            // both used to render "Connect to the SillyTavern backend": with 60 characters in the
            // store, a typo was answered by an instruction to connect a backend already connected.
            await page.focus('.char-search');
            await page.insertText('zzzzznotacharacter');
            const noRows = await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 0", 4000);
            const emptyCopy = await page.eval("(function(){const e=document.querySelector('#chat-root .panel-empty');return e?e.textContent.trim():'';})()");
            const namesTheTerm = emptyCopy.includes('zzzzznotacharacter');
            const noConnectLie = !/connect to the sillytavern backend/i.test(emptyCopy);
            const offersOut = await page.eval("!!document.getElementById('char-clear-filters')");
            row('must', noRows && namesTheTerm && noConnectLie && offersOut,
                'W6-1 a search matching nothing names the term and offers a way out, never "connect a backend"',
                `rowsGone=${noRows} namesTerm=${namesTheTerm} noConnectCopy=${noConnectLie} clearControl=${offersOut} copy=${JSON.stringify(emptyCopy)}`);

            await page.click('#char-clear-filters');
            const rowsBack = await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 4000);
            const boxCleared = await page.eval("document.querySelector('.char-search').value === ''");
            row('must', rowsBack && boxCleared,
                'W6-2 clearing from that empty state empties the search box and brings the list back',
                `rows=${rowsBack} searchBoxCleared=${boxCleared}`);

            // The action buttons reached for --color-border (the STRUCTURAL edge, for a panel
            // divider) where every other panel uses --color-control-border, and inherited the body
            // serif where all other chrome is mono. Measured from the rendered page, not asserted as
            // a class string: a class-string row passes on a token resolving to anything at all.
            const btnStyle = await page.eval(`(function(){${contrastFn}
                const b=document.querySelector('.char-act-btn');
                if(!b)return JSON.stringify({err:'no .char-act-btn'});
                const s=getComputedStyle(b);
                const ta=document.getElementById('send_textarea');
                return JSON.stringify({
                    ratio:Math.round(contrast(s.borderTopColor,s.backgroundColor)*100)/100,
                    font:s.fontFamily,
                    matchesHouseControl: ta ? s.borderTopColor === getComputedStyle(ta).borderTopColor : false,
                });})()`);
            const bs = JSON.parse(btnStyle);
            const monoChrome = /JetBrains Mono/i.test(bs.font || '');
            row('must', bs.ratio >= 3 && monoChrome && bs.matchesHouseControl,
                'W6-3 the character action buttons wear the interactive edge (>=3:1) and the chrome face',
                `borderVsFill=${bs.ratio}:1 mono=${monoChrome} sameEdgeAsComposerInput=${bs.matchesHouseControl} font=${JSON.stringify(bs.font)}`);

            // Chrome's own file button INHERITS the mono font off the input and paints a strong edge
            // of its own, so "is it mono" and "has contrast" BOTH pass on the unstyled default. What
            // separates our button from the browser's is the app's own tokens. The input stays real
            // and focusable on purpose: two of these are driven by setFileInputFiles (C-CARD-13,
            // C-BG2-6) and one by .click() while detached.
            const picker = await page.eval(`(function(){${contrastFn}
                const i=document.getElementById('char-import-input');
                if(!i)return JSON.stringify({err:'no #char-import-input'});
                const s=getComputedStyle(i,'::file-selector-button');
                const house=getComputedStyle(document.querySelector('.char-act-btn'));
                i.focus();
                return JSON.stringify({
                    housefill:s.backgroundColor === house.backgroundColor,
                    houseEdge:s.borderTopColor === house.borderTopColor,
                    edge:Math.round(contrast(s.borderTopColor,s.backgroundColor)*100)/100,
                    mono:/JetBrains Mono/i.test(s.fontFamily),
                    focusable:document.activeElement===i,
                    stillAFileInput:i.type==='file' && typeof i.files==='object',
                });})()`);
            const pk = JSON.parse(picker);
            row('must', pk.housefill && pk.houseEdge && pk.edge >= 3 && pk.mono && pk.focusable && pk.stillAFileInput,
                'W6-4 the file picker wears the house button, not Chrome\'s, and stays a real focusable file input',
                `sameFillAsHouseBtn=${pk.housefill} sameEdgeAsHouseBtn=${pk.houseEdge} buttonEdge=${pk.edge}:1 mono=${pk.mono} focusable=${pk.focusable} realFileInput=${pk.stillAFileInput}`);

            // Selection rode a class alone, which paints the amber wash and tells a screen reader
            // nothing. aria-selected has to track the same condition the class does, on every row.
            const ariaOf = (listSel) => page.eval(`(function(){const l=document.querySelector('${listSel}');
                if(!l)return JSON.stringify({list:'MISSING',roles:[],agree:false,selected:-1});
                const rows=[...l.querySelectorAll('.char-item')];
                return JSON.stringify({list:l.getAttribute('role'),
                roles:[...new Set(rows.map(function(r){return r.getAttribute('role');}))],
                agree:rows.length>0 && rows.every(function(r){return r.getAttribute('aria-selected') === String(r.classList.contains('is-selected'));}),
                selected:rows.filter(function(r){return r.getAttribute('aria-selected')==='true';}).length});})()`);
            const ca = JSON.parse(await ariaOf('#chat-root .char-list[aria-label="Characters"]'));
            row('must', ca.list === 'listbox' && ca.roles.length === 1 && ca.roles[0] === 'option' && ca.agree,
                'W6-5 every character row publishes its selection state in ARIA, not just in a class',
                `list=${ca.list} rowRoles=${JSON.stringify(ca.roles)} ariaMatchesClass=${ca.agree}`);

            await page.click('#d-persona');
            await page.waitFor("document.querySelectorAll('#persona-list .char-item').length >= 2", 5000);
            await page.click('#persona-list .char-item[data-persona-index="1"] .char-name');
            await page.waitFor("document.querySelector('#persona-list .char-item[data-persona-index=\\'1\\']').classList.contains('is-selected')", 2500);
            const pa = JSON.parse(await ariaOf('#persona-list'));
            row('must', pa.list === 'listbox' && pa.roles.length === 1 && pa.roles[0] === 'option' && pa.agree && pa.selected === 1,
                'W6-6 the selected persona says so in ARIA, not just in a class',
                `list=${pa.list} rowRoles=${JSON.stringify(pa.roles)} ariaMatchesClass=${pa.agree} selectedCount=${pa.selected}`);

            // The readout moved to the topbar in P1-C, so this drives the same property against the
            // new surface: a real Connect must leave the connections button reporting the backend it
            // just probed, in its state attribute AND by name. A row that only checked the attribute
            // was still there would stay green with the dot frozen while the backend was down.
            const statusBefore = await page.eval("document.getElementById('d-connections').dataset.connState");
            // #d-connections TOGGLES and five rows click it, so a blind click CLOSES a drawer a prior
            // row left open. Ask, then open only if it is shut.
            if (!await page.eval("!!document.querySelector('.conn-connect')")) {
                await page.click('#d-connections');
                if (!await page.waitFor("document.querySelector('.conn-connect')", 8000)) {
                    throw new Error('W6-7: the connections drawer never opened');
                }
            }
            // page.click dispatches at COORDINATES, and the drawer opens on a transition, so a click
            // measured mid-animation lands on empty space. Wait for the button to stop moving.
            await (async () => {
                let last = null;
                for (let i = 0; i < 80; i++) {
                    const at = await page.eval(
                        "(()=>{const e=document.querySelector('.conn-connect');if(!e)return '';const b=e.getBoundingClientRect();return b.top+','+b.left+','+b.width;})()");
                    if (at && at === last) return;
                    last = at;
                    await sleep(50);
                }
                throw new Error('W6-7: the connect button never settled');
            })();
            // Wait on the persist's OWN signal, not a clock: a flat 6s budget read RED on an untouched
            // baseline 2 runs in 4 under load. COUNT, not value: connect is clicked 3x, payloads repeat.
            const connBefore = (await (await fetch(`${args.base}/dev/state`)).json()).set_connection_count;
            await page.click('.conn-connect');
            const landed = await (async () => {
                const deadline = Date.now() + 15000;
                while (Date.now() < deadline) {
                    const st = await (await fetch(`${args.base}/dev/state`)).json();
                    if (st.set_connection_count > connBefore) return true;
                    await sleep(100);
                }
                return false;
            })();
            const statusMoved = landed && await page.waitFor(
                "document.getElementById('d-connections').dataset.connState === 'connected'", 6000);
            const after = await page.eval(`(function(){
                const b = document.getElementById('d-connections');
                const m = b.querySelector('.conn-model');
                return { state: b.dataset.connState, label: b.getAttribute('aria-label'),
                         model: m ? m.textContent.trim() : null };
            })()`);
            // The model name is the mock's own ("mock-model", devserve.py:1434), so this cannot pass
            // off a hardcoded string or a stale boot value as a probe result.
            row('must', statusMoved && after.state === 'connected' && after.model === 'mock-model'
                && after.label === 'API Connections, Connected: mock-model',
                'W6-7 the backend readout tracks the backend it is reporting on',
                `landed=${landed} before=${JSON.stringify(statusBefore)} ${JSON.stringify(after)}`);

            // The readout used to live in the composer as #send-status, in flow above the controls,
            // and at 390px it sat on the conversation. P1-C deleted it, so the row that measured how
            // much of the chat it covered has nothing left to measure and the honest replacement is
            // the stronger claim: NO connection readout survives anywhere in the composer. The
            // wordmark check rides the same 390px override.
            await page.click('#d-connections');
            const wideW = await page.eval('window.innerWidth');
            await page.cdp.send('Emulation.setDeviceMetricsOverride',
                { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, page.sessionId);
            await page.waitFor('window.innerWidth === 390', 3000);
            // Scoped to the composer and named by the vocabulary the old readout used, so a readout
            // reintroduced under any id or tag is caught, not just one called #send-status again.
            const phone = await page.eval(`(function(){
                const words = ['Connected', 'Backend', 'No backend', 'unlock at silly'];
                const comp = document.getElementById('composer');
                const bearers = [...comp.querySelectorAll('*')].filter(function (el) {
                    if (el.children.length > 0) return false;
                    const t = (el.textContent || '').trim();
                    return t.length > 0 && words.some(function (w) { return t.includes(w); });
                }).map(function (el) { return (el.id || el.tagName.toLowerCase()) + ':' + el.textContent.trim().slice(0, 40); });
                const h1 = document.querySelector('#topbar h1');
                const dot = document.querySelector('#d-connections .conn-dot');
                return JSON.stringify({ legacy: !!document.getElementById('send-status'),
                    bearers: bearers,
                    dotVisible: !!dot && dot.getBoundingClientRect().width > 0,
                    markClipped: h1.scrollWidth > h1.clientWidth + 1,
                    markW: h1.clientWidth, markFull: h1.scrollWidth });
            })()`);
            const ph = JSON.parse(phone);
            await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
            // Same restore discipline the C-MSG rows learned the hard way: the override returns before
            // the relayout, and a later row would inherit the half-restored page.
            const phoneRestored = await page.waitFor(`window.innerWidth === ${wideW}`, 5000);
            row('must', ph.legacy === false && ph.bearers.length === 0 && ph.dotVisible,
                'W6-8 no connection readout survives in the composer, and the dot shows at 390px',
                `legacy=${ph.legacy} bearers=${JSON.stringify(ph.bearers)} dotVisible=${ph.dotVisible}`);
            row('must', ph.markClipped === false,
                'W6-9 the wordmark renders whole at 390px (the nav is what gives way, not the brand)',
                `clipped=${ph.markClipped} rendered=${ph.markW}px full=${ph.markFull}px`);
            row('must', phoneRestored,
                'W6-10 the 390px override is fully restored before later rows run',
                `wide=${wideW} now=${await page.eval('window.innerWidth')}`);
        }

        /* C-SWAP */
        // THE ROUTE IS THIS BLOCK'S VALUE, NOT THE ASSERTION. C-DBG-8 has watched every load of this
        // run for a [zx:dom] anomaly since it was written, and it stayed green over a live crash the
        // operator hit twice: no row ever drove the sequence below. The operator swaps STRAIGHT from
        // the characters panel into the card editor. C-CFG-SEL-2 looks like it does the same and does
        // not: it opens the card editor at 2988 FIRST, so the editor is warm by 3017 and its
        // ensureLoaded() (card_editor_body.zx:31) fetches nothing during the diff. A cold mount does,
        // which re-enters render for a component whose diff is in flight.
        // Measured at 7e180f05b, 3 loads per cell: this route 3/3 anomalies + orphanCount 9; the warm
        // route 3/3 clean; drawer-closed-first 3/3 clean. With patch 13, 12/12 cells clean, orphans 0.
        console.log('== C-SWAP the straight swap into a cold card editor ==');
        {
            // Cold is half the trigger, so the route navigates every time: a page that already opened
            // the card editor takes the warm path, where every assertion below is vacuous.
            const swapRoute = async (clickSelect) => {
                await page.navigate(`${args.base}/`);
                await openRecentChat();
                await page.click('#d-characters');
                const listed = await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 8000);
                if (clickSelect) {
                    await page.click('#chat-root .char-item .char-name');
                    await page.waitFor("!!document.querySelector('#chat-root .char-item.is-selected')", 8000);
                }
                const selected = await page.eval("!!document.querySelector('#chat-root .char-item.is-selected')");
                const cold = await page.eval("!document.querySelector('#card-name')");
                const from = zxAnomalies.length;
                // Straight in, drawer still open. Closing it first is the route that never drifts.
                await page.click('#d-card_editor');
                // The form mounting is the swap's own completion signal (W6-7: never a wall clock).
                const mounted = await page.waitFor("!!document.querySelector('#card-name')", 8000);
                // An anomaly has no completion signal to wait on, so one bounded settle gives a late
                // one the same room C-DBG-6 gives an absent trace.
                await sleep(1000);
                return {
                    drove: listed && selected && cold && mounted,
                    listed, selected, cold, mounted,
                    anomalies: zxAnomalies.slice(from).filter((e) => !e.text.includes(ZX_PROBE)),
                    shellAlive: await page.eval("document.getElementById('shell') !== null"),
                    // -1, never a skip: an audit that is gone cannot prove zero orphans.
                    orphans: await page.eval(
                        "(typeof globalThis.__zx_audit === 'function') ? globalThis.__zx_audit().orphanCount : -1"),
                };
            };
            const say = (r) => `drove=${r.drove} (listed=${r.listed} selected=${r.selected}`
                + ` coldBefore=${r.cold} mounted=${r.mounted}) anomalies=${r.anomalies.length}`
                + ` shellAlive=${r.shellAlive} orphanCount=${r.orphans}`
                + (r.anomalies.length ? ` first=${JSON.stringify(r.anomalies[0].text.slice(0, 150))}` : '');

            // Three assertions in one row on purpose, because they are blind in different places. The
            // audit reads its registry against the DOM; the door REFUSING a garbage patch (f245755e6)
            // leaves #shell alive and can leave that registry coherent, so either alone can go green
            // one patch from the crash. #shell is the blast radius: the refused patch named parent and
            // child BOTH #0, and id 0 is Shell's root. The drove= terms are IN the conjunction: a swap
            // that silently fails to drive reports no anomaly, a live #shell and no orphan, and that
            // is this row's green (F12).
            const fresh = await swapRoute(true);
            row('must', fresh.drove && fresh.anomalies.length === 0 && fresh.shellAlive && fresh.orphans === 0,
                'C-SWAP-1 picking a character then opening its card from the panel drifts nothing',
                say(fresh));

            // The same swap with a SETTLED selection (resume-last, no click in the list): red 3/3 at
            // 7e180f05b as well, so the click is not the trigger and this is a second real entry, the
            // user who resumes a chat, opens the panel to browse, then opens the card.
            const settled = await swapRoute(false);
            row('must', settled.drove && settled.anomalies.length === 0 && settled.shellAlive && settled.orphans === 0,
                'C-SWAP-2 the same swap with a settled selection drifts nothing either',
                say(settled));
        }

        // ===== w3-chatmgr (append-only): chat management panel (3a). Keep ABOVE C-DBG. =====
        // Server-side truth for every mutation row comes from /dev/mgr-state (the fixture store the
        // mock routes actually touched), never from the panel's own rendering alone: a list that
        // repaints correctly over the wrong file is exactly the failure these rows exist to catch.
        console.log('== w3-chatmgr: chat management ==');
        {
            const mgrState = async () => await (await fetch(`${args.base}/dev/mgr-state`)).json();
            const mgrRowsQ = "document.querySelectorAll('#panel-view .chatmgr-row').length";
            const mgrNamesArr = "Array.from(document.querySelectorAll('#panel-view .chatmgr-row .font-serif')).map(function(n){return n.textContent.trim();})";
            const mgrNames = `JSON.stringify(${mgrNamesArr})`;
            const openMgr = async () => {
                if (!(await page.eval("!!document.querySelector('#panel-view .chatmgr')"))) {
                    await page.click('#d-chat_manager');
                }
                await page.waitFor("document.querySelector('#panel-view .chatmgr')", 5000);
            };
            const rowActByName = async (name, act) => {
                const clicked = await page.eval(`(function(){
                    var act = ${JSON.stringify(act)};
                    var rows = document.querySelectorAll('#panel-view .chatmgr-row');
                    for (var i = 0; i < rows.length; i++) {
                        if (rows[i].querySelector('.font-serif').textContent.trim() === ${JSON.stringify(name)}) {
                            if (act === 'open') { rows[i].click(); return true; }
                            var btn = rows[i].querySelector('[data-chat-act="' + act + '"]');
                            if (btn) { btn.click(); return true; }
                        }
                    }
                    return false;
                })()`);
                if (!clicked) throw new Error(`chatmgr: no row/button ${name}/${act}`);
            };

            // Land on char07's default chat: fresh load, characters dock, search, click the row.
            await page.navigate(`${args.base}/`);
            await page.waitFor(`${hydrated} && document.querySelector('#chat-home')`, 15000);
            await page.click('#d-characters');
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length > 0", 8000);
            await page.eval("(function(){const s=document.querySelector('.char-search'); s.value='Char 07'; s.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 1", 5000);
            await page.click('#chat-root .char-item');
            await page.waitFor("document.querySelectorAll('#chat .mes').length === 3 && document.body.textContent.includes('Default thread tail marker')", 8000);

            // CM-1: the manager lists the character's chats with count, size and date per row.
            await openMgr();
            const listed = await page.waitFor(`${mgrRowsQ} === 3`, 6000);
            const names = JSON.parse(await page.eval(mgrNames));
            const metaOk = await page.eval(
                "document.querySelector('#panel-view .chatmgr-row') && document.querySelector('#panel-view .chatmgr-row').textContent.includes('messages')");
            row('must', listed && names.includes('old adventure') && names.includes('keep me') && metaOk,
                'CM-1 the manager lists all three of the character\'s chats with metadata',
                `names=${JSON.stringify(names)}`);

            // CM-2: switching to an older chat renders that chat and closes the drawer.
            await rowActByName('old adventure', 'open');
            const switched = await page.waitFor(
                "document.querySelectorAll('#chat .mes').length === 2 && document.body.textContent.includes('peppermint dragon') && !document.querySelector('#panel-view')", 8000);
            row('must', switched, 'CM-2 switching to an older chat renders it and closes the drawer');

            // CM-3 (the wrong-file hazard): a send AFTER the switch persists into the SWITCHED file.
            // char_api re-derives the file per send, so without the override this lands in the default.
            await page.focus('#send_textarea');
            await page.insertText('AFTER SWITCH PROBE');
            await page.click('#composer button[aria-label="Send"]');
            await page.waitFor("document.body.textContent.includes('FIN') && !document.querySelector('#chat .mes[aria-busy=\\'true\\']')", 15000);
            const afterSend = await (async () => {
                const deadline = Date.now() + 6000;
                while (Date.now() < deadline) {
                    const st = await mgrState();
                    if ((st.files['old adventure'] || []).length >= 4) return st;
                    await sleep(150);
                }
                return await mgrState();
            })();
            row('must',
                (afterSend.files['old adventure'] || []).some((m) => m.includes('AFTER SWITCH PROBE'))
                && (afterSend.files['Char 07 Vex - 2026-07-14'] || []).length === 3,
                'CM-3 a send after switching persists into the switched file, never the card default',
                `switched=${(afterSend.files['old adventure'] || []).length} default=${(afterSend.files['Char 07 Vex - 2026-07-14'] || []).length}`);

            // CM-4: search narrows server-side; clearing restores the full list.
            await openMgr();
            await page.eval("(function(){const s=document.getElementById('chat-mgr-search'); s.value='peppermint'; s.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const narrowed = await page.waitFor(`${mgrRowsQ} === 1`, 6000);
            const narrowedName = JSON.parse(await page.eval(mgrNames));
            await page.eval("(function(){const s=document.getElementById('chat-mgr-search'); s.value=''; s.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const restored = await page.waitFor(`${mgrRowsQ} === 3`, 6000);
            row('must', narrowed && narrowedName[0] === 'old adventure' && restored,
                'CM-4 search narrows to the matching chat and clearing restores the list',
                `narrowed=${JSON.stringify(narrowedName)}`);

            // CM-5: rename round-trips. The renamed chat is OPEN, so the reader must follow the new
            // name; the store must hold the same bytes under the new key and nothing under the old.
            await page.eval("window.prompt = function(){ return 'renamed quest'; };");
            await rowActByName('old adventure', 'rename');
            const renamedListed = await page.waitFor(`(${mgrNamesArr}).includes('renamed quest') && !(${mgrNamesArr}).includes('old adventure')`, 8000);
            const stRename = await mgrState();
            const renamedIntact = (stRename.files['renamed quest'] || []).length >= 4
                && !('old adventure' in stRename.files)
                && stRename.files['renamed quest'][1].includes('candy caves');
            const readerFollowed = await page.waitFor("document.body.textContent.includes('peppermint dragon')", 6000);
            row('must', renamedListed && renamedIntact && readerFollowed,
                'CM-5 rename round-trips: new name listed, bytes intact, open reader follows',
                `files=${JSON.stringify(Object.keys(stRename.files))}`);

            // CM-6: duplicate creates a byte-equal sibling and leaves the original alone.
            await openMgr();
            await rowActByName('keep me', 'duplicate');
            const dupListed = await page.waitFor(`(${mgrNamesArr}).includes('keep me copy')`, 8000);
            const stDup = await mgrState();
            const dupEqual = JSON.stringify(stDup.files['keep me copy']) === JSON.stringify(stDup.files['keep me'])
                && (stDup.files['keep me'] || []).length === 2;
            row('must', dupListed && dupEqual,
                'CM-6 duplicate creates a byte-equal copy and the original is untouched');

            // CM-7: branch at message 1 creates a one-message prefix copy and opens it.
            await page.eval("window.prompt = function(){ return '1'; };");
            await rowActByName('keep me', 'branch');
            const branchOpened = await page.waitFor(
                "document.querySelectorAll('#chat .mes').length === 1 && document.body.textContent.includes('Sibling canary line one') && !document.querySelector('#panel-view')", 8000);
            const stBranch = await mgrState();
            const branchRight = (stBranch.files['keep me branch 1'] || []).length === 1
                && (stBranch.files['keep me'] || []).length === 2;
            row('must', branchOpened && branchRight,
                'CM-7 branch at message 1 creates the prefix copy and the reader opens it');

            // CM-8 (T1 dangerous property): delete removes EXACTLY the target; the sibling canary
            // keeps its two lines byte-for-byte.
            await page.eval("window.confirm = function(){ return true; };");
            await openMgr();
            await rowActByName('keep me copy', 'delete');
            const delGone = await page.waitFor(`!(${mgrNamesArr}).includes('keep me copy')`, 8000);
            const stDel = await mgrState();
            const canaryIntact = JSON.stringify(stDel.files['keep me'])
                === JSON.stringify(['Sibling canary line one.', 'Sibling canary line two.']);
            row('must', delGone && !('keep me copy' in stDel.files) && canaryIntact,
                'CM-8 delete removes exactly the target and the sibling chat is byte-intact',
                `files=${JSON.stringify(Object.keys(stDel.files))}`);

            // CM-9: deleting the OPEN chat (the branch) falls back to the card's default chat.
            await rowActByName('keep me branch 1', 'delete');
            const fellBack = await page.waitFor(
                "document.querySelectorAll('#chat .mes').length === 3 && document.body.textContent.includes('Default thread tail marker')", 8000);
            const stDel2 = await mgrState();
            row('must', fellBack && !('keep me branch 1' in stDel2.files),
                'CM-9 deleting the open chat falls back to the default chat');

            // CM-10: export fetches the file and hands a non-empty blob to a download click.
            await openMgr();
            await page.eval("window.__dlCount = 0; window.__dlSize = -1; (function(){ var orig = URL.createObjectURL.bind(URL); URL.createObjectURL = function(b){ window.__dlCount++; window.__dlSize = b.size; return orig(b); }; })();");
            await rowActByName('keep me', 'export');
            const dlHit = await page.waitFor('window.__dlCount === 1 && window.__dlSize > 0', 8000);
            const stExp = await mgrState();
            row('must', dlHit && stExp.exported === 'keep me',
                'CM-10 export downloads the requested chat as a non-empty jsonl blob',
                `size=${await page.eval('window.__dlSize')}`);

            // CM-11: import round-trips a stock jsonl: header line + two turns in, a listed chat with
            // the same two message bodies out. Drives the REAL file input (DataTransfer + change).
            const importedOk = await page.eval(`(function(){
                var header = JSON.stringify({ user_name: 'You', character_name: 'Char 07 Vex', create_date: '2026-01-01', chat_metadata: {} });
                var m1 = JSON.stringify({ name: 'You', is_user: true, send_date: 1, mes: 'imported line alpha', extra: {} });
                var m2 = JSON.stringify({ name: 'Char 07 Vex', is_user: false, send_date: 2, mes: 'imported line beta', extra: {} });
                var file = new File([header + '\\n' + m1 + '\\n' + m2], 'stock export.jsonl', { type: '' });
                var input = document.getElementById('chat-import-input');
                if (!input) return false;
                var dt = new DataTransfer();
                dt.items.add(file);
                input.files = dt.files;
                input.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            })()`);
            const importListed = await page.waitFor(`(${mgrNamesArr}).some(function(n){return n.indexOf('imported') !== -1;})`, 10000);
            const stImp = await mgrState();
            const impKey = Object.keys(stImp.files).find((k) => k.includes('imported'));
            const impRound = impKey
                && JSON.stringify(stImp.files[impKey]) === JSON.stringify(['imported line alpha', 'imported line beta']);
            row('must', importedOk && importListed && !!impRound,
                'CM-11 import round-trips a stock jsonl into a new listed chat',
                `key=${impKey || 'none'}`);
        }
        // ===== end w3-chatmgr section =====
        // ===== w3-grp (append-only): groups roster, membership, dangerous property =====
        // T0: the whole create/edit/delete cycle runs between two /dev/grp-t0 snapshots; the last
        // row asserts no chat write fired and the solo-chat fingerprint held byte-identical.
        console.log('== w3-grp: groups roster, membership, T0 ==');
        {
            const grpT0 = async () => (await fetch(`${args.base}/dev/grp-t0`)).json();
            const grpAll = async () => (await fetch(`${args.base}/api/groups/all`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
            })).json();
            // Server-truth wait: persistEdit is fire-and-forget, so a reload straight after a click
            // can cancel the in-flight POST and turn a real pass flaky. The gate polls the mock
            // until the edit landed, then reloads.
            const grpSettled = async (pred, ms = 5000) => {
                const deadline = Date.now() + ms;
                while (Date.now() < deadline) {
                    try { if (pred(await grpAll())) return true; } catch (_) { /* poll again */ }
                    await sleep(120);
                }
                return false;
            };
            const t0Before = await grpT0();

            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.click('#d-groups');
            const emptyState = await page.waitFor(
                "!!document.querySelector('.group-panel') && /No groups yet/.test(document.querySelector('.group-panel').textContent)", 8000);
            row('must', emptyState, 'W3-GRP-1 the groups panel opens on its empty state', `empty=${emptyState}`);

            // Create: prompt stubbed, the first two characters picked as members, one POST on commit.
            await page.eval("window.prompt = function(){ return 'Gate Party'; }; window.confirm = function(){ return true; };");
            await page.click("[data-group-action='new']");
            const editorUp = await page.waitFor("!!document.querySelector('.group-editor')", 5000);
            await page.click('.group-candidate-row [data-member-add]');
            await page.waitFor("document.querySelectorAll('.group-member-row').length === 1", 4000);
            await page.click('.group-candidate-row [data-member-add]');
            const twoMembers = await page.waitFor("document.querySelectorAll('.group-member-row').length === 2", 4000);
            await page.click("[data-group-action='create']");
            const promoted = await page.waitFor("!!document.querySelector('[data-group-action=\\'delete\\']')", 6000);
            const t0Created = await grpT0();
            row('must', editorUp && twoMembers && promoted && t0Created.groups === t0Before.groups + 1,
                'W3-GRP-2 create builds a group from two existing characters and adopts the minted id',
                `editor=${editorUp} members2=${twoMembers} promoted=${promoted} serverGroups=${t0Created.groups}`);

            // The roster row wears its first member's avatar, percent-encoded through thumbUrl.
            await page.click("[data-group-action='back']");
            const rosterRow = await page.waitFor("document.querySelectorAll('#group-list [data-group-index]').length === 1", 5000);
            const rowAvatar = await page.eval(
                "(function(){var i=document.querySelector('#group-list img');return i?(i.getAttribute('src')||''):'';})()");
            row('must', rosterRow && rowAvatar.indexOf('thumbnail?type=avatar&file=char00.png') >= 0,
                'W3-GRP-3 the roster row renders with its first member\'s avatar',
                `row=${rosterRow} src=${JSON.stringify(rowAvatar)}`);

            // Membership edits: mute the second member, move it up, then prove BOTH survive a reload
            // (the store is a mirror; the truth must be in the group file the server holds).
            await page.click("[data-group-edit='0']");
            await page.click(".group-member-row [data-member-mute='char01.png']");
            const muteMarked = await page.waitFor(
                "(function(){var b=document.querySelector('.group-member-row [data-member-mute=\\'char01.png\\']');return !!b && b.getAttribute('aria-pressed')==='true';})()", 4000);
            await page.click(".group-member-row [data-member-up='1']");
            const editsLanded = await grpSettled((gs) => gs.length === 1
                && Array.isArray(gs[0].disabled_members) && gs[0].disabled_members.indexOf('char01.png') >= 0
                && Array.isArray(gs[0].members) && gs[0].members[0] === 'char01.png');
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.click('#d-groups');
            await page.waitFor("document.querySelectorAll('#group-list [data-group-index]').length === 1", 8000);
            await page.click("[data-group-edit='0']");
            const orderKept = await page.waitFor(
                "(function(){var i=document.querySelector('.group-member-row img');return !!i && (i.getAttribute('src')||'').indexOf('char01.png')>=0;})()", 5000);
            const muteKept = await page.eval(
                "(function(){var b=document.querySelector('.group-member-row [data-member-mute=\\'char01.png\\']');return !!b && b.getAttribute('aria-pressed')==='true';})()");
            row('must', muteMarked && editsLanded && orderKept && muteKept,
                'W3-GRP-4 mute and member order persist to the server and survive a reload',
                `muted=${muteMarked} landed=${editsLanded} orderKept=${orderKept} muteKept=${muteKept}`);

            // Delete: server-authoritative, back to the empty roster.
            await page.eval('window.confirm = function(){ return true; };');
            await page.click("[data-group-action='delete']");
            const emptyAgain = await page.waitFor(
                "!!document.querySelector('.group-panel') && /No groups yet/.test(document.querySelector('.group-panel').textContent)", 6000);
            const t0After = await grpT0();
            row('must', emptyAgain && t0After.groups === t0Before.groups,
                'W3-GRP-5 delete removes the group and returns the roster to empty',
                `empty=${emptyAgain} serverGroups=${t0After.groups}`);

            // THE dangerous-property row (T0): the whole cycle above fired no chat-file write and
            // left the solo-chat state byte-identical.
            row('must', t0After.chat_writes === t0Before.chat_writes && t0After.fingerprint === t0Before.fingerprint,
                'W3-GRP-T0 group create/edit/delete never touches a chat file',
                `writesBefore=${t0Before.chat_writes} writesAfter=${t0After.chat_writes} fpHeld=${t0After.fingerprint === t0Before.fingerprint}`);
        }

        // ===== W3-WI (append-only): world-info store + entry editor (3b-A, no engine) =====
        // The mock books are mutable and survive reloads within the run, so persistence rows are
        // real server round-trips. The T0 row deep-diffs the WHOLE stored book after one editor
        // edit: an editor that drops any of the ~40 stock fields, or the unknown futureField, or a
        // sibling entry, fails it (the whole-file /edit is exactly where a clobber would happen).
        console.log('== W3-WI world info: books, scopes, entries, T0 round-trip ==');
        {
            const wiState = async () => (await fetch(`${args.base}/dev/state`)).json();
            const wiDiff = (a, b, p) => {
                if (a === b) return [];
                if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object' || typeof a !== typeof b) {
                    return JSON.stringify(a) === JSON.stringify(b) ? [] : [p || '(root)'];
                }
                let out = [];
                for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
                    out = out.concat(wiDiff(a[k], b[k], p ? `${p}.${k}` : k));
                }
                return out;
            };
            const wiOrig = JSON.parse(JSON.stringify((await wiState()).wi_books['gate-lore']));
            // An earlier section saved a card, and the mock then serves that save verbatim (no
            // embedded book). Reset so the deep card carries its character_book again.
            await fetch(`${args.base}/dev/wi-reset-card`);

            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.waitFor(hydrated, 15000);
            // The deep card is cached per avatar and earlier sections loaded it while their saved
            // (bookless) card was live, so pick a never-deep-loaded character and wait on the mock's
            // own request counter: the fresh /characters/get is what carries the embedded book in.
            const wiGetsBefore = (await wiState()).card_get_count;
            await page.click('#d-characters');
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 14", 8000);
            await page.eval("document.querySelectorAll('#chat-root .char-item .char-name')[13].click()");
            const wiDeepFetched = await (async () => {
                const deadline = Date.now() + 10000;
                while (Date.now() < deadline) {
                    if ((await wiState()).card_get_count > wiGetsBefore) return true;
                    await sleep(250);
                }
                return false;
            })();
            row('must', wiDeepFetched, 'W3WI-0 selecting a fresh character deep-fetches its card', `fetched=${wiDeepFetched}`);
            await page.click('#d-world_info');

            const wiRows = await page.waitFor("document.querySelectorAll('.wi-books ul li').length === 2", 8000);
            row('must', wiRows, 'W3WI-1 the book list renders every server book with its display name',
                `rows=${await page.eval("document.querySelectorAll('.wi-books ul li').length")} names=${await page.eval("JSON.stringify(Array.from(document.querySelectorAll('.wi-books .wi-row')).map(function(b){return b.textContent.trim();}))")}`);

            const wiChatLine = await page.eval("(document.querySelector('.wi-books')||{textContent:''}).textContent.indexOf('gate-lore') >= 0");
            row('must', wiChatLine, 'W3WI-2 the chat-linked book name surfaces from the chat metadata', `seen=${wiChatLine}`);

            // The embedded v2 card book: surfaces, converts, and is view-only.
            const wiCharBtn = await page.waitFor("!!document.querySelector('[data-wi-charbook]')", 8000);
            await page.click('[data-wi-charbook]');
            const charEntry = await page.waitFor("document.querySelectorAll('.wi-entries ul li').length === 1 && document.querySelector('.wi-entries').textContent.indexOf('lighthouse') >= 0", 8000);
            const roMarked = await page.eval("document.querySelector('.wi-entries').textContent.indexOf('read only') >= 0 && !document.querySelector('[data-wi-newentry]')");
            row('must', wiCharBtn && charEntry && roMarked,
                "W3WI-3 the card's embedded book surfaces converted from the v2 shape, view-only",
                `btn=${wiCharBtn} entry=${charEntry} readonly=${roMarked}`);
            await page.click('[data-wi-back]');

            // T0: edit ONE field of the fully-loaded stock book, let the debounced save land, then
            // deep-diff the stored file against the pre-edit copy.
            await page.waitFor("document.querySelectorAll('.wi-books ul li').length === 2", 5000);
            await page.click("[data-wi-open='gate-lore']");
            await page.waitFor("document.querySelectorAll('.wi-entries ul li').length === 2", 8000);
            await page.click("[data-wi-entry='0']");
            await page.waitFor("!!document.querySelector('#wi-content')", 5000);
            await page.eval("(function(){var t=document.querySelector('#wi-content'); t.value='Dragons hoard gold.'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            const wiSaved = await page.waitFor("document.querySelector('.wi-save-status').textContent === 'Saved'", 10000);
            const wiAfter = (await wiState()).wi_books['gate-lore'];
            const diff = wiDiff(wiOrig, wiAfter, '');
            const onlyContent = diff.length === 1 && diff[0] === 'entries.0.content'
                && wiAfter.entries['0'].content === 'Dragons hoard gold.'
                && JSON.stringify(wiAfter.entries['0'].futureField) === JSON.stringify({ nested: [1, 2, 3] });
            row('must', wiSaved && onlyContent,
                'W3WI-4 T0: the whole-book save changes ONLY the edited field; all stock fields, the unknown futureField and the sibling entry survive',
                `saved=${wiSaved} diff=${JSON.stringify(diff)}`);

            // Create: the new entry carries the full stock template server-side and survives a reload.
            await page.click('[data-wi-toentries]');
            await page.waitFor("document.querySelectorAll('.wi-entries ul li').length === 2", 5000);
            await page.click('[data-wi-newentry]');
            await page.waitFor("!!document.querySelector('#wi-comment')", 5000);
            await page.eval("(function(){var t=document.querySelector('#wi-comment'); t.value='GATE NEW'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.waitFor("document.querySelector('.wi-save-status').textContent === 'Saved'", 10000);
            const created = (await wiState()).wi_books['gate-lore'].entries['4'];
            const tmplOk = !!created && created.comment === 'GATE NEW' && created.groupWeight === 100
                && created.triggers && Object.keys(created).length >= 40;
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.click('#d-world_info');
            await page.waitFor("document.querySelectorAll('.wi-books ul li').length === 2", 8000);
            await page.click("[data-wi-open='gate-lore']");
            const survived = await page.waitFor("document.querySelectorAll('.wi-entries ul li').length === 3 && document.querySelector('.wi-entries').textContent.indexOf('GATE NEW') >= 0", 8000);
            row('must', tmplOk && survived,
                'W3WI-5 a created entry carries the full stock template and persists across a reload',
                `template=${tmplOk} keys=${created ? Object.keys(created).length : 0} reloaded=${survived}`);

            // Delete: confirm-gated, persists, and the sibling entries stay.
            await page.eval('window.confirm = function(){ return true; };');
            await page.click("[data-wi-entry='4']");
            await page.waitFor("!!document.querySelector('[data-wi-delentry]')", 5000);
            await page.click('[data-wi-delentry]');
            await page.waitFor("document.querySelectorAll('.wi-entries ul li').length === 2", 8000);
            await page.waitFor("document.querySelector('.wi-save-status').textContent === 'Saved'", 10000);
            const afterDel = (await wiState()).wi_books['gate-lore'].entries;
            const delOk = !afterDel['4'] && !!afterDel['0'] && !!afterDel['3'];
            row('must', delOk, 'W3WI-6 deleting an entry removes only that entry, server-side too',
                `keys=${JSON.stringify(Object.keys(afterDel))}`);

            // Scope + budget knobs persist through the ONE settings saver into the classic keys.
            await page.click('[data-wi-back]');
            await page.waitFor("!!document.querySelector('#wi-budget')", 5000);
            await page.eval("(function(){var t=document.querySelector('#wi-budget'); t.value='40'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.eval("(function(){var c=document.querySelector('[data-wi-global=\\'beta-lore\\']'); c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const wiPersisted = await (async () => {
                const deadline = Date.now() + 12000;
                while (Date.now() < deadline) {
                    const ws = (await wiState()).settings_world_info;
                    if (ws && ws.world_info_budget === 40 && ws.world_info
                        && (ws.world_info.globalSelect || []).indexOf('beta-lore') >= 0) return true;
                    await sleep(300);
                }
                return false;
            })();
            row('must', wiPersisted,
                'W3WI-7 the budget knob and a global-select toggle persist under the classic world_info_settings keys',
                `persisted=${wiPersisted}`);

            // Chat link, request shape only (merged-tree server accepts world_info since 9bc8ee713).
            // Row 5's reload left no chat open and the chatlink needs a live chat identity: resume one first.
            await page.eval("document.getElementById('d-world_info').click()");
            await openRecentChat();
            await page.eval("document.getElementById('d-world_info').click()");
            await page.waitFor("!!document.querySelector(\"[data-wi-open='beta-lore']\")", 8000);
            await page.click("[data-wi-open='beta-lore']");
            await page.waitFor("!!document.querySelector('[data-wi-chatlink]')", 8000);
            await page.click('[data-wi-chatlink]');
            const wiLinkBody = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const b = await (await fetch(`${args.base}/dev/note-save`)).json();
                    if (b && b.world_info === 'beta-lore') return b;
                    await sleep(250);
                }
                return null;
            })();
            const wiLinkShape = !!wiLinkBody && typeof wiLinkBody.avatar_url === 'string' && wiLinkBody.avatar_url.length > 0
                && typeof wiLinkBody.file_name === 'string' && wiLinkBody.file_name.length > 0
                && typeof wiLinkBody.change_token === 'string';
            const wiLinkReflected = await page.waitFor("document.querySelector('[data-wi-chatlink]').getAttribute('aria-pressed') === 'true'", 5000);
            row('must', wiLinkShape && wiLinkReflected,
                'W3WI-8 linking a book to the open chat POSTs the metadata descriptor shape (avatar_url + file_name + change_token + world_info) and the toggle reflects it',
                `shape=${wiLinkShape} body=${JSON.stringify(wiLinkBody || {}).slice(0, 140)} reflected=${wiLinkReflected}`);
        }

        // w3-chatref BEGIN group chat open + composer routing (3c-C). Keep ABOVE C-DBG.
        // The mock's single group_appended list feeds /group/get, so the rotation turns the earlier
        // w3-grp block persisted ARE the history a fresh group open must render.
        console.log('== w3-chatref: group chat open, composer rotation, solo return ==');
        {
            const refState = async () => (await fetch(`${args.base}/dev/state`)).json();
            const refGrpBase = ((await refState()).group_appended || []).length;

            // A UI-created group (members char00 "Char 00 Moon" + char01 "Char 01 Vex").
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.eval("window.prompt = function(){ return 'Ref Party'; }; window.confirm = function(){ return true; };");
            await page.click('#d-groups');
            await page.waitFor("!!document.querySelector('.group-panel')", 8000);
            await page.click("[data-group-action='new']");
            await page.waitFor("!!document.querySelector('.group-editor')", 5000);
            await page.click('.group-candidate-row [data-member-add]');
            await page.waitFor("document.querySelectorAll('.group-member-row').length === 1", 4000);
            await page.click('.group-candidate-row [data-member-add]');
            await page.waitFor("document.querySelectorAll('.group-member-row').length === 2", 4000);
            await page.click("[data-group-action='create']");
            await page.waitFor("!!document.querySelector('[data-group-action=\\'delete\\']')", 6000);
            await page.click("[data-group-action='back']");
            await page.waitFor("document.querySelectorAll('#group-list [data-group-index]').length >= 1", 5000);

            // (a) Opening the group from the roster renders the group file's history, each row
            // attributed to its own speaker by NAME (char02/char03 are not even members here).
            await page.click("#group-list [data-group-index='0']");
            const refOpened = await page.waitFor(
                `document.querySelectorAll('#chat .mes').length === ${refGrpBase} && document.getElementById('chat').textContent.includes('GROUP ROTATION PROBE') && ${idle}`, 10000);
            const refAttrib = JSON.parse(await page.eval(
                "JSON.stringify([...document.querySelectorAll('#chat .mes')].slice(1, 4).map(e => ({ n: e.querySelector('.mes_name').textContent, a: (e.querySelector('.mes_avatar') || { src: '' }).src })))"));
            const refAttribOk = refAttrib.length === 3
                && refAttrib[0].n === 'Char 01 Vex' && refAttrib[0].a.includes('char01')
                && refAttrib[1].n === 'Char 02 Vex' && refAttrib[1].a.includes('char02')
                && refAttrib[2].n === 'Char 03 Moon' && refAttrib[2].a.includes('char03');
            row('must', refOpened && refAttribOk,
                'CHATREF-1 opening a group from the roster renders its chat history with per-member attribution',
                `opened=${refOpened} rows=${JSON.stringify(refAttrib)}`);

            // (b) A composer send in the open group runs the rotation (both mentioned members, in
            // mention order) and persists into the group file, never the solo one.
            const stPre = await refState();
            const refSoloBase = (stPre.appended || []).length;
            const refGrpPre = (stPre.group_appended || []).length;
            const beforeRefSend = await page.eval("document.querySelectorAll('#chat .mes').length");
            await page.focus('#send_textarea');
            await page.insertText('Moon and Vex muster at the CHATREF beacon');
            await page.click('#composer button[aria-label="Send"]');
            const refSent = await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${beforeRefSend} + 3 && ${idle}`, 30000);
            let stPost = {};
            for (let i = 0; i < 60; i++) {
                stPost = await refState();
                if ((stPost.group_appended || []).length >= refGrpPre + 3) break;
                await sleep(150);
            }
            const refTurns = (stPost.group_appended || []).slice(refGrpPre);
            const refSeq = refTurns.length === 3
                && refTurns[0].is_user === true && refTurns[0].mes === 'Moon and Vex muster at the CHATREF beacon'
                && refTurns[1].is_user === false && refTurns[1].name === 'Char 00 Moon' && refTurns[1].mes.includes('FIN')
                && refTurns[2].is_user === false && refTurns[2].name === 'Char 01 Vex' && refTurns[2].mes.includes('FIN');
            const refSoloHeld = (stPost.appended || []).length === refSoloBase;
            row('must', refSent && refSeq && refSoloHeld,
                'CHATREF-2 a composer send in an open group rotates the mentioned members and persists only into the group file',
                `sent=${refSent} turns=${JSON.stringify(refTurns.map(m => ({ n: m.name, u: m.is_user, fin: String(m.mes).includes('FIN') })))} soloHeld=${refSoloHeld}`);

            // (c) Switching back to a solo character loads the solo chat; a follow-up send lands in
            // the solo file while the group file holds still (no group state leak).
            await page.click('#d-characters');
            await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 14", 8000);
            await page.eval("document.querySelectorAll('#chat-root .char-item .char-name')[5].click()");
            const refSoloLoaded = await page.waitFor(
                `document.querySelectorAll('#chat .mes').length >= 50 && !document.getElementById('chat').textContent.includes('GROUP ROTATION PROBE') && ${idle}`, 10000);
            const stPre2 = await refState();
            const refGrp2 = (stPre2.group_appended || []).length;
            await sendProbe('CHATREF SOLO PROBE');
            const stPost2 = await refState();
            const refSoloLanded = (stPost2.appended || []).some(m => m.mes === 'CHATREF SOLO PROBE');
            const refGrpHeld = (stPost2.group_appended || []).length === refGrp2;
            row('must', refSoloLoaded && refSoloLanded && refGrpHeld,
                'CHATREF-3 switching back to a solo character loads the solo chat and its sends stay solo (no group leak)',
                `soloLoaded=${refSoloLoaded} soloLanded=${refSoloLanded} grpHeld=${refGrpHeld}`);
        }
        // w3-chatref END
        // w3-wi-engine BEGIN (append-only): activation engine rows (3b-B). Books are seeded
        // deterministic (probability 100 / constant); rows read the RECORDED payload, not the UI.
        console.log('== w3-wi-engine: activation, budget cap, unlink, import ==');
        {
            const engState = async () => (await fetch(`${args.base}/dev/state`)).json();
            const engPost = (path, obj) => fetch(`${args.base}${path}`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj),
            });
            const engEntry = (uid, over) => Object.assign({
                uid, key: [], keysecondary: [], comment: '', content: '', constant: false,
                selective: false, selectiveLogic: 0, order: 100, position: 0, disable: false,
                probability: 100, useProbability: true, depth: 4,
            }, over);

            // E1: only the entry whose key appears in the typed message reaches the payload.
            await engPost('/api/worldinfo/edit', {
                name: 'engine-lore', data: {
                    name: 'Engine Lore', entries: {
                        0: engEntry(0, { key: ['gatekey'], content: 'WI-ENGINE-ALPHA' }),
                        1: engEntry(1, { key: ['zebraword'], content: 'WI-ENGINE-NEVER' }),
                    },
                },
            });
            await engPost('/api/chats/metadata', { world_info: 'engine-lore' });
            // Earlier preset rows leave a context template without wi slots active (stock DROPS wi
            // then); pin a slotted one so these rows do not depend on run order.
            const engEnv = await (await engPost('/api/settings/get', {})).json();
            const engSettings = JSON.parse(engEnv.settings);
            engSettings.power_user.context = {
                name: 'WI Slotted',
                story_string: '{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}{{trim}}',
                chat_start: '',
                example_separator: '',
                story_string_position: 0,
            };
            await engPost('/api/settings/save', engSettings);
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await sendProbe('I found the GATEKEY in the sand');
            const engS1 = await engState();
            const engP1 = engS1.last_generate_prompt || '';
            row('must', engP1.includes('WI-ENGINE-ALPHA') && !engP1.includes('WI-ENGINE-NEVER'),
                'W3WI-E1 a linked book\'s matching entry lands in the generation payload and a non-matching entry does not',
                `alpha=${engP1.includes('WI-ENGINE-ALPHA')} never=${engP1.includes('WI-ENGINE-NEVER')} gets=${JSON.stringify(engS1.wi_get_log)} slot=${JSON.stringify((engS1.settings_context || {}).story_string || '').includes('wiBefore')} plen=${engP1.length}`);

            // E2 (T0): entries sized 0.6x the MEASURED 1% cap (earlier rows may leave any
            // max_context), so either fits alone and the lower-order one is what the cap sheds.
            const engBody1 = JSON.parse(engS1.last_generate_body || '{}');
            const engCap = Math.floor((Number(engBody1.truncation_length || 8192) - Number(engBody1.max_new_tokens || 64)) * 7 / 2 / 100);
            const engFill = (tag, n) => tag + 'x'.repeat(Math.max(1, n - tag.length));
            await engPost('/api/worldinfo/edit', {
                name: 'engine-budget', data: {
                    name: 'Engine Budget', entries: {
                        0: engEntry(0, { constant: true, order: 900, content: engFill('WI-BUDGET-KEEP ', Math.floor(engCap * 0.6)) }),
                        1: engEntry(1, { constant: true, order: 50, content: engFill('WI-BUDGET-DROP ', Math.floor(engCap * 0.6)) }),
                    },
                },
            });
            // Drive the PANEL knobs (the deterministic path: a harness-written blob races the
            // client's own debounced settings save): budget 1%, engine-budget globally selected.
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector('#wi-budget')", 8000);
            await page.eval("(function(){var t=document.querySelector('#wi-budget'); t.value='1'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.eval("(function(){var c=document.querySelector('[data-wi-global=\\'engine-budget\\']'); c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const engBudgetLoaded = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    if (((await engState()).wi_get_log || []).includes('engine-budget')) return true;
                    await sleep(250);
                }
                return false;
            })();
            await page.click('#send_textarea');
            await sendProbe('a plain probe line');
            const engP2 = (await engState()).last_generate_prompt || '';
            row('must', engBudgetLoaded && engP2.includes('WI-BUDGET-KEEP') && !engP2.includes('WI-BUDGET-DROP'),
                'W3WI-E2 the budget cap drops the lowest-priority entry when exceeded',
                `bookLoaded=${engBudgetLoaded} keep=${engP2.includes('WI-BUDGET-KEEP')} drop=${engP2.includes('WI-BUDGET-DROP')} cap=${engCap}`);

            // E3: unlink writes world_info:"" through the server allowlist and the next payload
            // carries nothing from the unlinked book (the global engine-budget book stays live).
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector(\"[data-wi-open='engine-lore']\")", 8000);
            await page.click("[data-wi-open='engine-lore']");
            await page.waitFor("!!document.querySelector('[data-wi-chatlink]')", 8000);
            const engLinked = await page.eval("document.querySelector('[data-wi-chatlink]').getAttribute('aria-pressed')");
            await page.click('[data-wi-chatlink]');
            const engUnlinkBody = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const b = await (await fetch(`${args.base}/dev/note-save`)).json();
                    if (b && b.world_info === '') return b;
                    await sleep(250);
                }
                return null;
            })();
            // boolAttr renders false as aria-pressed="" (not "false"), so test for not-'true'.
            const engUnlinkToggle = await page.waitFor("document.querySelector('[data-wi-chatlink]').getAttribute('aria-pressed') !== 'true'", 5000);
            await page.click('#send_textarea');
            await sendProbe('the GATEKEY once more');
            const engP3 = (await engState()).last_generate_prompt || '';
            row('must', engLinked === 'true' && !!engUnlinkBody && engUnlinkToggle && !engP3.includes('WI-ENGINE-ALPHA'),
                'W3WI-E3 unlink round-trips world_info:"" and the next payload carries no content from the unlinked book',
                `wasLinked=${engLinked} bodyEmptyStr=${!!engUnlinkBody} toggle=${engUnlinkToggle} alphaGone=${!engP3.includes('WI-ENGINE-ALPHA')}`);

            // E4: a stock ST world book FILE imports through the real input and round-trips into
            // the list (server-side entries intact, display name from inside the file).
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector('[data-wi-back]')", 5000);
            await page.click('[data-wi-back]');
            await page.waitFor("!!document.querySelector('#wi-import-input')", 8000);
            const engImportFired = await page.eval(`(function(){
                var book = JSON.stringify({ name: 'Imported Realm', entries: { '0': { uid: 0, key: ['relic'], content: 'the relic hums', order: 100, position: 0 } } });
                var file = new File([book], 'stock realm.json', { type: 'application/json' });
                var input = document.getElementById('wi-import-input');
                if (!input) return 'no-input';
                var dt = new DataTransfer();
                dt.items.add(file);
                input.files = dt.files;
                input.dispatchEvent(new Event('change', { bubbles: true }));
                return 'ok';
            })()`);
            const engImported = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const b = (await engState()).wi_books['stock realm'];
                    if (b) return b;
                    await sleep(250);
                }
                return null;
            })();
            const engImportListed = await page.waitFor("(document.querySelector('.wi-books')||{textContent:''}).textContent.indexOf('Imported Realm') >= 0", 8000);
            row('must', engImportFired === 'ok' && !!engImported && engImported.entries['0'].content === 'the relic hums' && engImportListed,
                'W3WI-E4 a stock world book file imports through the panel and round-trips into the list',
                `fired=${engImportFired} stored=${!!engImported} listed=${engImportListed}`);
        }
        // w3-wi-engine END

        // wi-polish BEGIN (append-only): the recursion toggle (task#16 item 1). Rides the WI Slotted
        // template + probe mechanics the w3-wi-engine block pinned; keep BELOW it, ABOVE C-DBG.
        console.log('== wi-polish: recursion toggle persists and gates the engine ==');
        {
            const wpState = async () => (await fetch(`${args.base}/dev/state`)).json();
            const wpPost = (path, obj) => fetch(`${args.base}${path}`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj),
            });
            const wpEntry = (uid, over) => Object.assign({
                uid, key: [], keysecondary: [], comment: '', content: '', constant: false,
                selective: false, selectiveLogic: 0, order: 100, position: 0, disable: false,
                probability: 100, useProbability: true, depth: 4,
            }, over);

            // A chain book: the second entry's key appears ONLY inside the first entry's content, so
            // it can activate through recursion alone.
            await wpPost('/api/worldinfo/edit', {
                name: 'recurse-lore', data: {
                    name: 'Recurse Lore', entries: {
                        0: wpEntry(0, { key: ['recursegate'], content: 'WI-RECURSE-FIRST holds the embercode' }),
                        1: wpEntry(1, { key: ['embercode'], content: 'WI-RECURSE-SECOND' }),
                    },
                },
            });
            await wpPost('/api/chats/metadata', { world_info: 'recurse-lore' });

            // R1: the panel toggle persists under the classic world_info_recursive key and survives
            // a reload back into a checked box.
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector('#wi-recursive')", 8000);
            await page.eval("(function(){var t=document.querySelector('#wi-budget'); t.value='40'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.eval("(function(){var c=document.querySelector('#wi-recursive'); c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const wpOnPersisted = await (async () => {
                const deadline = Date.now() + 12000;
                while (Date.now() < deadline) {
                    const ws = (await wpState()).settings_world_info;
                    if (ws && ws.world_info_recursive === true) return true;
                    await sleep(300);
                }
                return false;
            })();
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector('#wi-recursive')", 8000);
            const wpReloadedChecked = await page.eval("document.querySelector('#wi-recursive').checked === true");
            row('must', wpOnPersisted && wpReloadedChecked === true,
                'WIPOL-R1 the recursion toggle persists under world_info_recursive and reloads checked',
                `persisted=${wpOnPersisted} reloaded=${wpReloadedChecked}`);

            // R2: with recursion ON a recursion-only entry reaches the payload. The drawer closes
            // first so resume-last is clickable.
            await page.click('#d-world_info');
            await openRecentChat();
            await sendProbe('the RECURSEGATE stands open');
            const wpP1 = (await wpState()).last_generate_prompt || '';
            row('must', wpP1.includes('WI-RECURSE-FIRST') && wpP1.includes('WI-RECURSE-SECOND'),
                'WIPOL-R2 recursion on: an entry keyed only by activated lore content joins the payload',
                `first=${wpP1.includes('WI-RECURSE-FIRST')} second=${wpP1.includes('WI-RECURSE-SECOND')}`);

            // R3: toggled OFF the chained entry stays out while the keyed one still lands.
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector('#wi-recursive')", 8000);
            await page.eval("(function(){var c=document.querySelector('#wi-recursive'); c.checked=false; c.dispatchEvent(new Event('change',{bubbles:true}));})()");
            const wpOffPersisted = await (async () => {
                const deadline = Date.now() + 12000;
                while (Date.now() < deadline) {
                    const ws = (await wpState()).settings_world_info;
                    if (ws && ws.world_info_recursive === false) return true;
                    await sleep(300);
                }
                return false;
            })();
            await page.click('#send_textarea');
            await sendProbe('the RECURSEGATE once more');
            const wpP2 = (await wpState()).last_generate_prompt || '';
            row('must', wpOffPersisted && wpP2.includes('WI-RECURSE-FIRST') && !wpP2.includes('WI-RECURSE-SECOND'),
                'WIPOL-R3 recursion off: the chained entry stays out of the payload',
                `persisted=${wpOffPersisted} first=${wpP2.includes('WI-RECURSE-FIRST')} second=${wpP2.includes('WI-RECURSE-SECOND')}`);

            // ---- group AN/WI headers (task#16 item 2): the group chat's note + linked book live in
            // the group chat file's header; the same panels edit them; the solo header holds still.
            const wpSoloSnap = JSON.stringify((await wpState()).chat_meta);
            const wpOpenGroup = async () => {
                await page.navigate(`${args.base}/`);
                await page.waitFor(hydrated, 15000);
                await page.click('#d-groups');
                await page.waitFor("!!document.querySelector(\"#group-list [data-group-index='0']\")", 8000);
                await page.click("#group-list [data-group-index='0']");
                await page.waitFor(`document.getElementById('chat').textContent.includes('GROUP ROTATION PROBE') && ${idle}`, 10000);
            };

            // G1: the note panel is live in a group chat and its save carries group_id, not a solo ref.
            await wpOpenGroup();
            await page.click('#d-formatting');
            const wpNoteLive = await page.waitFor("!!document.getElementById('an-prompt')", 8000);
            await page.eval("(function(){const n=document.getElementById('an-prompt');n.value='GROUP NOTE HOLDS';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await page.click('.an-save');
            const wpNoteBody = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const b = await (await fetch(`${args.base}/dev/note-save`)).json();
                    if (b && b.note_prompt === 'GROUP NOTE HOLDS') return b;
                    await sleep(250);
                }
                return null;
            })();
            const wpNoteShape = !!wpNoteBody && typeof wpNoteBody.group_id === 'string' && wpNoteBody.group_id.length > 0
                && wpNoteBody.avatar_url === undefined && wpNoteBody.file_name === undefined;
            const wpGroupMeta1 = (await wpState()).group_meta || {};
            row('must', wpNoteLive && wpNoteShape && wpGroupMeta1.note_prompt === 'GROUP NOTE HOLDS',
                'WIPOL-G1 a group chat note edits through the same panel and saves by group_id into the group header',
                `live=${wpNoteLive} shape=${wpNoteShape} body=${JSON.stringify(wpNoteBody || {}).slice(0, 120)} stored=${wpGroupMeta1.note_prompt}`);

            // G2: the group note survives a full reload of the group chat (loaded from the header).
            await wpOpenGroup();
            await page.click('#d-formatting');
            await page.waitFor("!!document.getElementById('an-prompt')", 8000);
            const wpNoteReloaded = await page.eval("document.getElementById('an-prompt').value");
            row('must', wpNoteReloaded === 'GROUP NOTE HOLDS',
                'WIPOL-G2 the group note reloads from the group header on reopen',
                `value=${JSON.stringify(wpNoteReloaded)}`);

            // G3: linking a book to the OPEN GROUP writes world_info by group_id, the engine's chat
            // scope activates it in the group rotation payload, and the solo header never moved.
            await page.click('#d-formatting');
            await page.click('#d-world_info');
            await page.waitFor("!!document.querySelector(\"[data-wi-open='engine-lore']\")", 8000);
            await page.click("[data-wi-open='engine-lore']");
            await page.waitFor("!!document.querySelector('[data-wi-chatlink]')", 8000);
            await page.click('[data-wi-chatlink]');
            const wpLinkBody = await (async () => {
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                    const b = await (await fetch(`${args.base}/dev/note-save`)).json();
                    if (b && b.world_info === 'engine-lore') return b;
                    await sleep(250);
                }
                return null;
            })();
            const wpLinkShape = !!wpLinkBody && typeof wpLinkBody.group_id === 'string' && wpLinkBody.group_id.length > 0
                && wpLinkBody.avatar_url === undefined;
            await page.click('#d-world_info');
            await page.click('#send_textarea');
            await (await fetch(`${args.base}/dev/clear-generate`)).json();
            const wpGrpMsgs = await page.eval("document.querySelectorAll('#chat .mes').length");
            await page.focus('#send_textarea');
            await page.insertText('Moon, the GATEKEY glows');
            await page.click('#composer button[aria-label="Send"]');
            await page.waitFor(`document.querySelectorAll('#chat .mes').length >= ${wpGrpMsgs} + 2 && ${idle}`, 30000);
            const wpSt = await wpState();
            const wpGrpPrompt = wpSt.last_generate_prompt || '';
            const wpSoloHeld = JSON.stringify(wpSt.chat_meta) === wpSoloSnap;
            row('must', wpLinkShape && (wpSt.group_meta || {}).world_info === 'engine-lore' && wpGrpPrompt.includes('WI-ENGINE-ALPHA') && wpSoloHeld,
                'WIPOL-G3 a group-linked book saves by group_id, activates in the group rotation payload, and the solo header holds still',
                `shape=${wpLinkShape} stored=${(wpSt.group_meta || {}).world_info} alpha=${wpGrpPrompt.includes('WI-ENGINE-ALPHA')} soloHeld=${wpSoloHeld}`);
        }
        // wi-polish END

        /* C-CONN-DOT: the connection readout after P1-C moved it out of the composer. */
        // The dot is the fast channel and the words are the real one. Colour alone is unreadable to a
        // screen reader and to a red-green reader, so every state row asserts the aria-label TEXT as
        // well as the attribute, and the colours are only checked for being distinct from each other.
        console.log('== C-CONN-DOT the connection readout ==');
        {
            const connState = async () => page.eval(`(function(){
                const b = document.getElementById('d-connections');
                if (!b) return null;
                const dot = b.querySelector('.conn-dot');
                const model = b.querySelector('.conn-model');
                return { state: b.dataset.connState, label: b.getAttribute('aria-label'),
                         dot: dot ? getComputedStyle(dot).backgroundColor : null,
                         dotW: dot ? Math.round(dot.getBoundingClientRect().width) : 0,
                         model: model ? model.textContent.trim() : null };
            })()`);
            const reloadWith = async (mode) => {
                await fetch(`${args.base}/dev/status-mode?m=${mode}`);
                await page.navigate(`${args.base}/?demo=1`);
                await page.waitFor(hydrated, 15000);
                await page.waitFor(`document.getElementById('d-connections').dataset.connState !== 'configured'`, 10000);
                return connState();
            };

            const ok = await reloadWith('ok');
            row('must', !!ok && ok.state === 'connected' && ok.label === 'API Connections, Connected: mock-model'
                && ok.model === 'mock-model' && ok.dotW > 0,
                'C-CONN-DOT-1 a reachable backend shows connected, names the model, and says so in words',
                JSON.stringify(ok));

            const asleep = await reloadWith('asleep');
            row('must', asleep.state === 'asleep' && asleep.label === 'API Connections, Backend asleep - unlock at silly',
                'C-CONN-DOT-2 a 502 at the edge reads as asleep, in the attribute and in the name',
                JSON.stringify(asleep));

            // P1-D end to end on a real outcome site: the boot probe's asleep branch must reach the
            // notification system, not just the dot. Each reloadWith navigates, so the history is
            // empty on arrival and this toast can only have come from THIS load's probe.
            const asleepToast = await page.eval(`(function(){
                const t = [...document.querySelectorAll('#notifications div[data-level]')]
                    .map(function (e) { return { level: e.getAttribute('data-level'), text: e.textContent }; });
                const badge = document.querySelector('#d-notifications .notif-badge');
                return { toasts: t, badge: badge ? badge.textContent : null };
            })()`);
            row('must', asleepToast.toasts.length === 1 && asleepToast.toasts[0].level === 'warning'
                && asleepToast.toasts[0].text === 'Backend asleep - unlock at silly' && asleepToast.badge === '1',
                'C-CONN-DOT-8 an asleep backend also raises a notification, and the bell counts it',
                JSON.stringify(asleepToast));

            const offline = await reloadWith('offline');
            row('must', offline.state === 'offline' && offline.label === 'API Connections, Backend offline - unlock at silly',
                'C-CONN-DOT-3 an online:false probe reads as offline, not as connected',
                JSON.stringify(offline));

            const errored = await reloadWith('error');
            row('must', errored.state === 'err' && errored.label === 'API Connections, Backend error 500',
                'C-CONN-DOT-4 a 500 carries its status code into the readout',
                JSON.stringify(errored));

            // Distinctness, not specific colours: the words are what carry meaning, so this only has
            // to prove the dot is not painting one colour for four different states.
            const shades = [ok.dot, asleep.dot, errored.dot];
            row('must', new Set(shades).size === 3 && shades.every((c) => c && c !== 'rgba(0, 0, 0, 0)'),
                'C-CONN-DOT-5 connected, asleep and error paint three different dots',
                JSON.stringify(shades));

            await fetch(`${args.base}/dev/status-mode?m=ok`);
            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(hydrated, 15000);
            // The relocation itself. Scoped to #composer and keyed on the readout's own vocabulary, so
            // a status line reintroduced under any id is caught, not only one called #send-status.
            const composerClean = await page.eval(`(function(){
                const words = ['Connected', 'Backend', 'No backend', 'unlock at silly'];
                const comp = document.getElementById('composer');
                const bearers = [...comp.querySelectorAll('*')].filter(function (el) {
                    if (el.children.length > 0) return false;
                    const t = (el.textContent || '').trim();
                    return t.length > 0 && words.some(function (w) { return t.includes(w); });
                }).map(function (el) { return (el.id || el.tagName.toLowerCase()) + ':' + el.textContent.trim().slice(0, 40); });
                return { legacy: !!document.getElementById('send-status'), bearers: bearers,
                         inShell: !!document.querySelector('#shell .conn-dot') };
            })()`);
            row('must', composerClean.legacy === false && composerClean.bearers.length === 0
                && composerClean.inShell,
                'C-CONN-DOT-6 the composer carries no connection readout, and the topbar does',
                JSON.stringify(composerClean));

            // The panel's standing line is the full readout the topbar only abbreviates.
            await page.click('#d-connections');
            await page.waitFor("document.querySelector('#conn-standing')", 6000);
            const standing = await page.eval(`(function(){
                const el = document.getElementById('conn-standing');
                return { state: el.dataset.connState,
                         text: document.getElementById('conn-standing-text').textContent.trim(),
                         progressEmpty: (document.getElementById('conn-status').textContent || '').trim() === '' };
            })()`);
            await page.click('#d-connections');
            row('must', standing.state === 'connected' && standing.text === 'Connected: mock-model'
                && standing.progressEmpty,
                'C-CONN-DOT-7 the panel shows the standing line, with Connect progress still its own',
                JSON.stringify(standing));
        }
        /* C-CONN-DOT END */

        /* C-SSE: the live server channel (P3-MOCK + P3-A). */
        // Every server event is NAMED, and onmessage receives only unnamed ones, so a glue that bound
        // onmessage alone would connect, hold the socket, and deliver nothing: a dead server with a
        // healthy-looking connection. C-SSE-3 is the row for exactly that, and it is the reason the
        // counts below are per-TYPE rather than a single total.
        console.log('== C-SSE the live server channel ==');
        {
            const sse = async () => page.eval(`(function(){
                const s = window.__st_events_stat;
                return { total: s(0), lastId: s(1), connId: s(2), hellos: s(3), replayed: s(4), unknown: s(5),
                         readyState: window.__st_events_state ? window.__st_events_state() : -2 };
            })()`);
            const emit = async (type, note) =>
                (await (await fetch(`${args.base}/dev/emit-event?type=${type}&note=${encodeURIComponent(note)}`)).json()).id;
            const devState = async () => (await (await fetch(`${args.base}/dev/state`)).json());

            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(hydrated, 15000);
            await page.waitFor("window.__st_events_state && window.__st_events_state() === 1", 8000);

            const opened = await page.eval("window.__st_events_state()");
            const st0 = await devState();
            row('must', opened === 1 && st0.events_open >= 1,
                'C-SSE-1 the client holds a live stream open against the server',
                `readyState=${opened} serverSideOpen=${st0.events_open}`);

            // Six named events, one at a time, all of which must CROSS into Zig.
            const before = await page.eval('window.__st_events_stat(0)');
            const kinds = ['settings-changed', 'background-changed', 'preset-changed',
                'worldinfo-changed', 'chat-changed', 'backend-status'];
            const ids = [];
            for (const k of kinds) ids.push(await emit(k, 'c-sse'));
            await sleep(1200);
            const afterEmit = await sse();
            row('must', afterEmit.total - before === kinds.length && afterEmit.lastId === ids[ids.length - 1],
                'C-SSE-2 every named event crosses into Zig, not just the first',
                `crossed=${afterEmit.total - before} of ${kinds.length} lastId=${afterEmit.lastId} wanted=${ids[ids.length - 1]}`);

            // THE NAMED-EVENT TRAP. onmessage sees only UNNAMED events, so if the glue bound nothing
            // else this count would be zero while the connection looked perfectly healthy.
            row('must', afterEmit.unknown === 0 && afterEmit.hellos >= 1 && afterEmit.total >= kinds.length + 1,
                'C-SSE-3 named events arrive through their own listeners, not through onmessage',
                `unknown=${afterEmit.unknown} hellos=${afterEmit.hellos} total=${afterEmit.total}`);

            // The id has to survive the crossing or a router can never dedupe a replay.
            row('must', afterEmit.lastId === ids[ids.length - 1] && afterEmit.lastId > 0,
                'C-SSE-4 the event id crosses with the payload, so a replay is identifiable',
                `lastId=${afterEmit.lastId} serverLastId=${ids[ids.length - 1]}`);

            // Drop the stream server-side, then let the BROWSER retry on its own.
            const connBefore = afterEmit.connId;
            await fetch(`${args.base}/dev/drop-events`);
            const reconnected = await page.waitFor(
                `window.__st_events_stat(2) > ${connBefore}`, 10000);
            const afterDrop = await sse();
            row('must', reconnected && afterDrop.connId > connBefore && afterDrop.hellos >= 2,
                'C-SSE-5 the browser reconnects by itself after the stream is dropped',
                `connBefore=${connBefore} connAfter=${afterDrop.connId} hellos=${afterDrop.hellos}`);

            // RESUME. Events emitted while the client was away must arrive on the reconnect, which
            // can only happen if Last-Event-ID went out with the retry.
            const beforeResume = afterDrop.total;
            await fetch(`${args.base}/dev/drop-events?ms=2000`);
            // Emitting with zero streams open is the whole row: emit while the client is back and the
            // events arrive live, which proves nothing about a resume.
            let awayOpen = -1;
            for (let i = 0; i < 40 && awayOpen !== 0; i += 1) {
                awayOpen = (await devState()).events_open;
                if (awayOpen !== 0) await sleep(50);
            }
            const missedA = await emit('settings-changed', 'missed-1');
            const missedB = await emit('background-changed', 'missed-2');
            const resumed = await page.waitFor(
                `window.__st_events_stat(1) >= ${missedB}`, 15000);
            const afterResume = await sse();
            row('must', awayOpen === 0 && resumed && afterResume.lastId >= missedB && afterResume.total > beforeResume,
                'C-SSE-6 events missed while disconnected are replayed on the reconnect',
                `openWhenEmitted=${awayOpen} missed=[${missedA},${missedB}] lastId=${afterResume.lastId} total=${beforeResume}->${afterResume.total}`);

            // The beacon, posted by Zig through net.zig so it carries the csrf token.
            const beaconRet = await page.eval('window.__st_events_visibility(false)');
            await sleep(800);
            const stAfter = await devState();
            const recorded = (stAfter.events_visibility || []).slice(-1)[0];
            row('must', beaconRet === 1 && !!recorded && recorded.visible === false
                && recorded.id === afterResume.connId,
                'C-SSE-7 the visibility beacon posts and the server records the right connection',
                `ret=${beaconRet} recorded=${JSON.stringify(recorded)} connId=${afterResume.connId}`);
        }
        /* C-SSE END */

        /* C-LIVE: routing, idempotency, origin skip and the hot path (P3-B). */
        // The routes are measured SERVER-SIDE, by which endpoint got refetched. A refresh that fired
        // and a refresh that did not look identical in the DOM when the data has not changed, so the
        // only honest instrument is the request the client did or did not make.
        console.log('== C-LIVE the event router ==');
        {
            const sse = async () => page.eval(`(function(){
                const s = window.__st_events_stat;
                return { total: s(0), lastId: s(1), connId: s(2), hellos: s(3), replayed: s(4),
                         unknown: s(5), applied: s(6), readyState: window.__st_events_state() };
            })()`);
            const devState = async () => (await (await fetch(`${args.base}/dev/state`)).json());
            const hits = async (p) => ((await devState()).api_hits || {})[p] || 0;
            const emit = async (type, payload) => (await (await fetch(
                `${args.base}/dev/emit-event?type=${type}&data=${encodeURIComponent(JSON.stringify(payload))}`)).json()).id;

            await fetch(`${args.base}/dev/status-mode?m=ok`);
            await fetch(`${args.base}/dev/add-background?name=${encodeURIComponent('live origin.jpg')}`);
            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(hydrated, 15000);
            await page.waitFor("window.__st_events_state && window.__st_events_state() === 1", 8000);
            await page.waitFor('window.__st_events_stat(3) >= 1', 8000);

            // ROUTING. One event type at a time, each asserted against ITS OWN endpoint.
            const routes = [
                ['background-changed', '/api/backgrounds/all', { action: 'delete', name: 'x.jpg' }],
                ['settings-changed', '/api/settings/get', { source: 'settings-save' }],
                ['character-changed', '/api/characters/all', { action: 'edit', avatar: 'x.png' }],
                ['worldinfo-changed', '/api/worldinfo/list', { action: 'edit', name: 'lore' }],
            ];
            const routed = [];
            for (const [type, endpoint, payload] of routes) {
                const before = await hits(endpoint);
                await emit(type, payload);
                const landed = await waitUntil(async () => (await hits(endpoint)) > before, 6000);
                routed.push(`${type}->${endpoint}:${landed ? 'refetched' : 'NOTHING'}`);
            }
            row('must', routed.every((r) => r.endsWith('refetched')),
                'C-LIVE-1 each event type refetches its own subsystem and nothing stands in for it',
                routed.join(' '));

            // IDEMPOTENCY. A resume replays what this client already applied, so the SAME ids arrive
            // twice; the second sighting must change nothing.
            const beforeReplay = await hits('/api/backgrounds/all');
            const statBefore = await sse();
            await fetch(`${args.base}/dev/replay-from?id=0`);
            await sleep(1200);
            const afterReplay = await hits('/api/backgrounds/all');
            const statAfter = await sse();
            row('must', afterReplay === beforeReplay && statAfter.replayed > statBefore.replayed,
                'C-LIVE-2 a replayed batch is recognised and refreshes nothing a second time',
                `bgAll=${beforeReplay}->${afterReplay} replayed=${statBefore.replayed}->${statAfter.replayed} total=${statBefore.total}->${statAfter.total}`);

            // ORIGIN SKIP, end to end. The tab's own write must not come back to it, or every write
            // costs a refetch of the thing just written.
            // The delete goes through the CLIENT's own request path, so the header under test is the
            // one net.zig attaches. A hand-written fetch here would prove only that the mock skips.
            const other = await openSecondStream(args.base, 'c-other-tab');
            await page.click('#d-backgrounds');
            const galleryUp = await page.waitFor("!!document.querySelector('#bg-gallery')", 8000);
            const tilePresent = galleryUp && await page.waitFor(
                `!!document.querySelector("#bg-gallery [data-bg-delete='live origin.jpg']")`, 8000);
            const tiles = await page.eval(
                "Array.from(document.querySelectorAll('#bg-gallery [data-bg-file]')).map(function(e){return e.getAttribute('data-bg-file');}).join('|')");
            const ownedBefore = await sse();
            const tabClientId = await page.eval('window.__st_client_id()');
            // Delete confirms through a NATIVE dialog, which blocks the renderer and hangs every
            // later CDP call until it is dismissed. Stub it before the click, as the C-BG rows do.
            // Delete confirms through a NATIVE dialog, which blocks the renderer and hangs every
            // later CDP call until it is dismissed. Stub it before the click, as the C-BG rows do.
            await page.eval('window.confirm = function(){ return true; };');
            if (tilePresent) await page.click("#bg-gallery [data-bg-delete='live origin.jpg']");
            const deleted = tilePresent && await page.waitFor(
                `!document.querySelector("#bg-gallery [data-bg-file='live origin.jpg']")`, 8000);
            await sleep(1200);
            const ownedAfter = await sse();
            const otherSaw = other.frames.join('').split('event: background-changed').length - 1;
            row('must', tilePresent && deleted && ownedAfter.total === ownedBefore.total && otherSaw >= 1,
                'C-LIVE-3 a write made here is not echoed back here, and another tab still gets it',
                `thisTab=${ownedBefore.total}->${ownedAfter.total} otherTabSaw=${otherSaw} clientId=${tabClientId.slice(0, 8)} gallery=${galleryUp} tiles=[${tiles}]`);
            other.close();
            await page.click('#d-backgrounds');

            // HOT PATH. The turns ride the event, so the open chat gains EXACTLY the ones sent.
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await page.waitFor("window.__st_events_state && window.__st_events_state() === 1", 8000);
            await page.waitFor('window.__st_events_stat(3) >= 1', 8000);
            const mesCount = async () => page.eval("document.querySelectorAll('#chat .mes').length");
            const beforeAppend = await mesCount();
            await emit('chat-appended', { card: null, file: null, group_id: null, change_token: 't',
                messages: [{ name: 'Seraphina', mes: 'a turn from another device', is_user: false }] });
            const appendedOne = await waitUntil(async () => (await mesCount()) !== beforeAppend, 6000);
            await sleep(600);
            const afterAppend = await mesCount();
            row('must', appendedOne && afterAppend === beforeAppend + 1,
                'C-LIVE-4 a turn added elsewhere appends exactly one message, not zero and not two',
                `mes=${beforeAppend}->${afterAppend}`);

            // The same event for a DIFFERENT chat must not land in this one.
            const beforeForeign = await mesCount();
            const chatHitsBefore = await hits('/api/chats/get');
            await emit('chat-appended', { card: 'SomeoneElse', file: 'another chat', group_id: null,
                messages: [{ name: 'SomeoneElse', mes: 'not for this chat', is_user: false }] });
            await sleep(1200);
            row('must', (await mesCount()) === beforeForeign && (await hits('/api/chats/get')) === chatHitsBefore,
                'C-LIVE-5 a turn belonging to another chat neither lands here nor triggers a reload',
                `mes=${beforeForeign}->${await mesCount()}`);

            // SCOPING. The draft is the property the region work exists for.
            await page.focus('#send_textarea');
            await page.insertText('a draft nobody should take');
            await emit('settings-changed', { source: 'settings-save' });
            await sleep(1500);
            const draft = await page.eval("document.getElementById('send_textarea').value");
            const caret = await page.eval("document.getElementById('send_textarea').selectionStart");
            row('must', draft === 'a draft nobody should take' && caret === draft.length,
                'C-LIVE-6 an incoming event leaves the composer draft and caret alone',
                `draft=${JSON.stringify(draft)} caret=${caret}`);
            await page.eval("document.getElementById('send_textarea').value = ''");
        }
        /* C-LIVE END */

        /* C-RETIRE: the poll stands down under a live stream and takes over when it drops (P3-B). */
        console.log('== C-RETIRE the poll handover ==');
        {
            const probes = async () => (await (await fetch(`${args.base}/dev/state`)).json()).status_probe_count;
            await fetch(`${args.base}/dev/status-mode?m=ok`);
            await page.navigate(`${args.base}/?demo=1&pollms=400`);
            await page.waitFor(hydrated, 15000);
            await page.waitFor("window.__st_events_state && window.__st_events_state() === 1", 8000);
            await page.waitFor('window.__st_events_stat(3) >= 1', 8000);

            // Up: the poll must be standing down, so a 400ms cadence still probes nothing.
            const upBefore = await probes();
            await sleep(2500);
            const upAfter = await probes();
            const armedUnderStream = await page.eval('window.__st_conn_poll_armed()');
            row('must', upAfter === upBefore && armedUnderStream === 0,
                'C-RETIRE-1 a live stream leaves the poll standing down, probing nothing',
                `probes=+${upAfter - upBefore} over 2.5s at 400ms armed=${armedUnderStream}`);

            // Down: the browser reports the drop, and the poll has to take the status back.
            await fetch(`${args.base}/dev/drop-events?ms=6000`);
            const armedAfterDrop = await waitUntil(async () => (await page.eval('window.__st_conn_poll_armed()')) === 1, 8000);
            const downBefore = await probes();
            await sleep(2500);
            const downAfter = await probes();
            row('must', armedAfterDrop && downAfter > downBefore,
                'C-RETIRE-2 a dropped stream hands the status back to the poll',
                `armed=${armedAfterDrop} probes=+${downAfter - downBefore} over 2.5s at 400ms`);

            // And back: the reconnect's hello stands it down again, so both cannot run at once.
            const backUp = await waitUntil(async () => (await page.eval('window.__st_events_state()')) === 1, 12000);
            const settledArmed = await waitUntil(async () => (await page.eval('window.__st_conn_poll_armed()')) === 0, 8000);
            const reBefore = await probes();
            await sleep(2000);
            row('must', backUp && settledArmed && (await probes()) === reBefore,
                'C-RETIRE-3 the reconnect stands the poll down again, so the two never both run',
                `readyState=${await page.eval('window.__st_events_state()')} armed=${await page.eval('window.__st_conn_poll_armed()')} probes=+${(await probes()) - reBefore}`);
        }
        /* C-RETIRE END */

        /* C-POLL: the standalone backend-status poll (P1-E). */
        // Counted server-side, never inferred from the dot: a poll that stopped and a backend that
        // stopped changing look identical from the DOM. ?pollms shortens the shipped 20s cadence.
        console.log('== C-POLL the standalone status poll ==');
        {
            const probes = async () => (await (await fetch(`${args.base}/dev/state`)).json()).status_probe_count;
            const armed = async () => page.eval('window.__st_conn_poll(true)');
            await fetch(`${args.base}/dev/status-mode?m=ok`);
            await page.navigate(`${args.base}/?demo=1&pollms=400`);
            await page.waitFor(hydrated, 15000);
            await page.waitFor("document.getElementById('d-connections').dataset.connState === 'connected'", 10000);
            // The poll is the FALLBACK for a stream that is down (P3-B), so these rows close the live
            // channel first. Left open, its hello stands the poll down and every row below measures
            // the retirement instead of the fallback it is here to test.
            await page.eval('window.__st_events_close()');

            // The dot must follow the backend with NOBODY reloading. Nothing below navigates.
            await fetch(`${args.base}/dev/status-mode?m=asleep`);
            const flipped = await page.waitFor(
                "document.getElementById('d-connections').dataset.connState === 'asleep'", 10000);
            const flippedLabel = await page.eval("document.getElementById('d-connections').getAttribute('aria-label')");
            row('must', flipped && flippedLabel === 'API Connections, Backend asleep - unlock at silly',
                'C-POLL-1 the poll flips the dot when the backend changes, with no reload',
                `flipped=${flipped} label=${JSON.stringify(flippedLabel)}`);

            await fetch(`${args.base}/dev/status-mode?m=ok`);
            const back = await page.waitFor(
                "document.getElementById('d-connections').dataset.connState === 'connected'", 10000);
            row('must', back, 'C-POLL-2 the poll recovers the dot when the backend comes back', `recovered=${back}`);

            // A hidden tab probes NOTHING. document.hidden is overridden rather than stubbed out of
            // the code path: the Zig still reads the real property, this only sets what it reads.
            await page.eval("Object.defineProperty(document, 'hidden', { configurable: true, get: function(){ return true; } });");
            const hiddenFrom = await probes();
            await sleep(2500);
            const hiddenAdded = (await probes()) - hiddenFrom;
            // Then reveal it again: a zero that survives un-hiding would mean the poll had simply died.
            await page.eval("Object.defineProperty(document, 'hidden', { configurable: true, get: function(){ return false; } });");
            const shownFrom = await probes();
            await sleep(2500);
            const shownAdded = (await probes()) - shownFrom;
            row('must', hiddenAdded === 0 && shownAdded >= 3,
                'C-POLL-3 a hidden tab probes nothing, and probing resumes when it is shown',
                `hidden=+${hiddenAdded} shown=+${shownAdded} over 2.5s at 400ms`);

            // Arming twice must not double the rate. The sweep timer taught us that a loop which
            // re-arms itself will happily run twice with nothing in the DOM to show for it.
            const armAgain = await armed();
            const armAgain2 = await armed();
            const doubleFrom = await probes();
            await sleep(2500);
            const doubleAdded = (await probes()) - doubleFrom;
            row('must', armAgain === 1 && armAgain2 === 1 && doubleAdded >= 3 && doubleAdded <= 9,
                'C-POLL-4 arming an already-armed poll starts no second timer',
                `armed=${armAgain},${armAgain2} probes=+${doubleAdded} over 2.5s at 400ms (one timer ~6)`);

            // And it must actually STOP. A poll that cannot be stood down cannot become a fallback.
            const stopped = await page.eval('window.__st_conn_poll(false)');
            await sleep(700);
            const stopFrom = await probes();
            await sleep(2500);
            const stopAdded = (await probes()) - stopFrom;
            row('must', stopped === 0 && stopAdded === 0,
                'C-POLL-5 stopping the poll leaves no timer still probing',
                `armedAfterStop=${stopped} probes=+${stopAdded} over 2.5s`);

            const rearmed = await armed();
            const reFrom = await probes();
            await sleep(2500);
            const reAdded = (await probes()) - reFrom;
            row('must', rearmed === 1 && reAdded >= 3,
                'C-POLL-6 a stopped poll can be armed again, so the fallback is re-enterable',
                `armed=${rearmed} probes=+${reAdded}`);
            await page.eval('window.__st_conn_poll(false)');
        }
        /* C-POLL END */

        /* C-PUSH: one row per notification push site (P1-D2). */
        // A push site with no row is a branch nobody has run. Each row here drives the REAL path that
        // reaches its push and asserts the level and the exact text, so a site cannot be proven by a
        // neighbour's toast. Where two sites share wording (the three asleep pushes, the two offline
        // ones) the driver is what tells them apart, which is why each starts from a known-silent
        // load: a healthy boot pushes nothing, so any toast present after it came from the action.
        console.log('== C-PUSH every notification push site ==');
        {
            const toastsNow = async () => page.eval(
                `[...document.querySelectorAll('#notifications div[data-level]')].map(function(e){`
                + `return { level: e.getAttribute('data-level'), text: e.textContent }; })`);
            const only = (list, level, text) => list.length === 1 && list[0].level === level && list[0].text === text;
            const settled = async (ms = 4000) => {
                await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length > 0", ms);
                await sleep(250);
                return toastsNow();
            };
            // A load whose probe answers `mode`. Returns once the readout has left its pre-probe state,
            // so the boot push (if the mode has one) has already landed.
            const bootWith = async (mode) => {
                await fetch(`${args.base}/dev/status-mode?m=${mode}`);
                await page.navigate(`${args.base}/?demo=1`);
                await page.waitFor(hydrated, 15000);
                await page.waitFor("document.getElementById('d-connections').dataset.connState !== 'configured'", 10000);
                await sleep(200);
                return toastsNow();
            };
            const openConnections = async () => {
                if (!await page.eval("!!document.querySelector('.conn-connect')")) {
                    await page.click('#d-connections');
                    await page.waitFor("document.querySelector('.conn-connect')", 8000);
                }
                // The drawer opens on a transition and page.click dispatches at coordinates, so a
                // click measured mid-animation lands on empty space.
                let last = null;
                for (let i = 0; i < 80; i++) {
                    const at = await page.eval("(function(){const e=document.querySelector('.conn-connect');"
                        + "if(!e)return '';const b=e.getBoundingClientRect();return b.top+','+b.left+','+b.width;})()");
                    if (at && at === last) return;
                    last = at;
                    await sleep(50);
                }
                throw new Error('C-PUSH: the connect button never settled');
            };
            // Connect from a healthy boot, so the only toast that can be up is this attempt's.
            const connectWith = async (mode, arm) => {
                await bootWith('ok');
                await fetch(`${args.base}/dev/status-mode?m=${mode}`);
                if (arm) await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent(arm)}&code=500`);
                await openConnections();
                await page.click('.conn-connect');
                return settled();
            };

            const bootOffline = await bootWith('offline');
            row('must', only(bootOffline, 'warning', 'Backend offline - unlock at silly'),
                'C-PUSH-1 boot probe offline raises exactly its own warning',
                JSON.stringify(bootOffline));

            const bootErr = await bootWith('error');
            row('must', only(bootErr, 'err', 'Backend error 500'),
                'C-PUSH-2 boot probe error carries its status code into the toast',
                JSON.stringify(bootErr));

            const bootOk = await bootWith('ok');
            row('must', bootOk.length === 0,
                'C-PUSH-3 a healthy boot pushes NOTHING, so every row below starts silent',
                JSON.stringify(bootOk));

            const probeAsleep = await connectWith('asleep', null);
            row('must', only(probeAsleep, 'warning', 'Backend asleep - unlock at silly'),
                'C-PUSH-4 interactive Connect against a 502 raises the asleep warning',
                JSON.stringify(probeAsleep));

            const probeFailed = await connectWith('error', null);
            row('must', only(probeFailed, 'err', 'Connect failed: 500'),
                'C-PUSH-5 interactive Connect against a 500 says connect failed, with the code',
                JSON.stringify(probeFailed));

            const probeOffline = await connectWith('offline', null);
            row('must', only(probeOffline, 'warning', 'Backend offline - unlock at silly'),
                'C-PUSH-6 interactive Connect against online:false raises the offline warning',
                JSON.stringify(probeOffline));

            const saveFailed = await connectWith('ok', '/api/settings/set-connection');
            row('must', only(saveFailed, 'err', 'Connection save failed: 500'),
                'C-PUSH-7 a probe that succeeds but a persist that fails says the SAVE failed',
                JSON.stringify(saveFailed));

            const connected = await connectWith('ok', null);
            row('must', only(connected, 'success', 'Connected: mock-model'),
                'C-PUSH-8 a Connect that lands names the model it connected to',
                JSON.stringify(connected));

            // The key lifecycle. Save then remove, each in both outcomes, from a silent boot.
            const keyAction = async (arm, act) => {
                await bootWith('ok');
                await openConnections();
                if (arm) await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent(arm)}&code=500`);
                if (act === 'save') {
                    await page.focus('#conn-api-key');
                    await page.insertText('sk-push-probe');
                    await page.click('.conn-key-save');
                } else {
                    await page.click('.conn-key-clear');
                }
                return settled();
            };

            const keySaved = await keyAction(null, 'save');
            row('must', only(keySaved, 'success', 'API key saved'),
                'C-PUSH-9 saving an API key confirms it', JSON.stringify(keySaved));

            const keySaveFailed = await keyAction('/api/secrets/write', 'save');
            row('must', only(keySaveFailed, 'err', 'API key save failed: 500'),
                'C-PUSH-10 a rejected key write says so, with the code', JSON.stringify(keySaveFailed));

            const keyRemoved = await keyAction(null, 'remove');
            row('must', only(keyRemoved, 'success', 'API key removed'),
                'C-PUSH-11 removing a stored key confirms it', JSON.stringify(keyRemoved));

            const keyRemoveFailed = await keyAction('/api/secrets/delete', 'remove');
            row('must', only(keyRemoveFailed, 'err', 'API key removal failed: 500'),
                'C-PUSH-12 a rejected key delete says so, with the code', JSON.stringify(keyRemoveFailed));

            // The character list. Its failure is the one a user experiences as an empty app, so the
            // toast is the only thing that says why. Armed, then a load, then a clean load to recover.
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/characters/all')}&code=500`);
            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(hydrated, 15000);
            const charsFailed = await settled(8000);
            row('must', charsFailed.some((t) => t.level === 'err' && t.text === 'Character list failed to load: 500'),
                'C-PUSH-13 a failed character list says so rather than showing an empty app',
                JSON.stringify(charsFailed));

            // A file picked into a real input, so the Zig multipart + raw POST run end to end. Shared
            // by the background and the two avatar sites below.
            const pickFile = async (inputId, name) => {
                const dir = mkdtempSync(join(tmpdir(), 'st-push-'));
                const path = join(dir, name);
                writeFileSync(path, Buffer.from(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
                    'base64'));
                const doc = await page.cdp.send('DOM.getDocument', { depth: 1 }, page.sessionId);
                const nodeId = (await page.cdp.send('DOM.querySelector',
                    { nodeId: doc.root.nodeId, selector: '#' + inputId }, page.sessionId)).nodeId;
                await page.cdp.send('DOM.setFileInputFiles', { files: [path], nodeId }, page.sessionId);
            };
            // Delete goes through window.confirm and rename through window.prompt (backgrounds.zig
            // :272, :304). Each navigate here restores the NATIVE dialogs, and a native modal blocks
            // the page: an unstubbed confirm hangs every later CDP eval, which is what a 420s
            // watchdog timeout after the upload rows turned out to be.
            const openBackgrounds = async () => {
                await page.navigate(`${args.base}/?demo=1`);
                await page.waitFor(hydrated, 15000);
                await page.eval("window.confirm = function(){ return true; };"
                    + "window.prompt = function(){ return 'push renamed.png'; };");
                await page.click('#d-backgrounds');
                await page.waitFor("document.getElementById('bg-upload-input')", 8000);
                await sleep(300);
            };

            await openBackgrounds();
            await pickFile('bg-upload-input', 'push probe.png');
            const bgUploaded = await settled(8000);
            row('must', bgUploaded.some((t) => t.level === 'success' && t.text === 'Background uploaded'),
                'C-PUSH-14 a background upload that lands confirms it', JSON.stringify(bgUploaded));

            await openBackgrounds();
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/backgrounds/upload')}&code=500`);
            await pickFile('bg-upload-input', 'push fail.png');
            const bgUpFailed = await settled(8000);
            row('must', bgUpFailed.some((t) => t.level === 'err' && t.text === 'Background upload failed: 500'),
                'C-PUSH-15 a rejected background upload says so, with the code', JSON.stringify(bgUpFailed));

            await openBackgrounds();
            const delTarget = await page.eval("(document.querySelector('#bg-gallery [data-bg-delete]')||{}).dataset ? document.querySelector('#bg-gallery [data-bg-delete]').getAttribute('data-bg-delete') : ''");
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/backgrounds/delete')}&code=500`);
            await page.click(`#bg-gallery [data-bg-delete='${delTarget}']`);
            const bgDelFailed = await settled(8000);
            row('must', bgDelFailed.some((t) => t.level === 'err' && t.text === 'Background delete failed: 500'),
                'C-PUSH-16 a rejected background delete says so, with the code',
                `target=${JSON.stringify(delTarget)} ${JSON.stringify(bgDelFailed)}`);

            await openBackgrounds();
            const renTarget = await page.eval("document.querySelector('#bg-gallery [data-bg-rename]').getAttribute('data-bg-rename')");
            await page.eval("window.prompt = function(){ return 'push renamed.png'; };");
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/backgrounds/rename')}&code=500`);
            await page.click(`#bg-gallery [data-bg-rename='${renTarget}']`);
            const bgRenFailed = await settled(8000);
            row('must', bgRenFailed.some((t) => t.level === 'err' && t.text === 'Background rename failed: 500'),
                'C-PUSH-17 a rejected background rename says so, with the code',
                `target=${JSON.stringify(renTarget)} ${JSON.stringify(bgRenFailed)}`);

            // The card editor. Opening it fetches the deep card, so the form's presence is the signal
            // that the panel is ready to save from.
            // The editor only has a card to show once one is selected, which resuming a chat does. A
            // bare navigate leaves it empty, and the form never mounts.
            const openCardEditor = async () => {
                await page.navigate(`${args.base}/`);
                await openRecentChat();
                await page.click('#d-card_editor');
                if (!await page.waitFor("!!document.querySelector('#card-description')", 10000)) {
                    throw new Error('C-PUSH: the card editor form never mounted');
                }
                await sleep(200);
            };

            await openCardEditor();
            await page.eval("(function(){var t=document.getElementById('card-description');"
                + "t.value='push probe edit'; t.dispatchEvent(new Event('input',{bubbles:true}));})()");
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/characters/edit')}&code=500`);
            await page.click('#card-save');
            const cardSaveFailed = await settled(8000);
            row('must', cardSaveFailed.some((t) => t.level === 'err' && t.text === 'Character save failed: 500'),
                'C-PUSH-18 a rejected card save says so, with the code', JSON.stringify(cardSaveFailed));

            await openCardEditor();
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/characters/edit-avatar')}&code=500`);
            await pickFile('card-avatar-input', 'card push.png');
            const cardAvatarFailed = await settled(8000);
            row('must', cardAvatarFailed.some((t) => t.level === 'err' && t.text === 'Avatar upload failed: 500'),
                'C-PUSH-19 a rejected card avatar upload says so, with the code', JSON.stringify(cardAvatarFailed));

            const openPersona = async () => {
                await page.navigate(`${args.base}/?demo=1`);
                await page.waitFor(hydrated, 15000);
                await page.click('#d-persona');
                if (!await page.waitFor("document.getElementById('persona-avatar-input')", 10000)) {
                    throw new Error('C-PUSH: the persona panel never mounted its avatar input');
                }
                await sleep(200);
            };

            await openPersona();
            await pickFile('persona-avatar-input', 'persona push.png');
            const personaOk = await settled(8000);
            row('must', personaOk.some((t) => t.level === 'success' && t.text === 'Persona avatar updated'),
                'C-PUSH-20 a persona avatar that uploads confirms it', JSON.stringify(personaOk));

            await openPersona();
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/avatars/upload')}&code=500`);
            await pickFile('persona-avatar-input', 'persona fail.png');
            const personaFailed = await settled(8000);
            row('must', personaFailed.some((t) => t.level === 'err' && t.text === 'Persona avatar upload failed: 500'),
                'C-PUSH-21 a rejected persona avatar upload says so, with the code', JSON.stringify(personaFailed));

            // The stream's own unreachable path, which is NOT the boot probe: stream_drive hands a
            // 502 at the seal to connection.onStreamUnreachable, and only a real send reaches it.
            // Not bootWith: that loads ?demo=1, which seeds a chat and has no #home-resume to click.
            await fetch(`${args.base}/dev/status-mode?m=ok`);
            await page.navigate(`${args.base}/`);
            await openRecentChat();
            await fetch(`${args.base}/dev/fail-next?path=${encodeURIComponent('/api/backends/text-completions/generate')}&code=502`);
            await page.focus('#send_textarea');
            await page.insertText('push probe send');
            await page.click('#composer button[aria-label="Send"]');
            const streamAsleep = await settled(15000);
            row('must', streamAsleep.some((t) => t.level === 'warning' && t.text === 'Backend asleep - unlock at silly'),
                'C-PUSH-22 a send whose stream 502s at the edge raises the asleep warning',
                JSON.stringify(streamAsleep));

            await fetch(`${args.base}/dev/clear-fail-next`);
            await fetch(`${args.base}/dev/status-mode?m=ok`);
        }
        /* C-PUSH END */

        /* C-NOTIF: the toast overlay (P1-PROBE + P1-A). Keep ABOVE C-DBG, which reads the whole run. */
        // Two claims, and the second is the one the region exists for. First: a toast fades on its own,
        // driven by one Zig setInterval and nothing else, so these rows never touch the page between
        // the push and the fade. Second: that whole lifecycle leaves the composer alone. The composer
        // holds unsaved typing, so a toast that re-rendered it would take the draft, the caret, and the
        // auto-grown height with it, and nothing in the product would report the loss.
        //
        // Isolation is measured with a MutationObserver, not a render counter: the -Dinstrument
        // counters in instrument.zig have no reader left (render-harness.sh drives a ?rendercount=
        // probe that lived in the deleted glue/main.js).
        console.log('== C-NOTIF the toast overlay ==');
        {
            // The timer spy, installed before the document exists so it wraps the globals ahead of the
            // wasm door. No app code used zx.client.setInterval before this chunk, so neither the
            // repeat nor the CLEAR path has ever run in this product: a sweep that never stops is a
            // 250ms wakeup for the life of the page, and nothing else here would notice it.
            const spy = await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
                source: `(function(){
                    window.__timerLog = { set: [], clear: [] };
                    const rawSet = window.setInterval.bind(window);
                    const rawClear = window.clearInterval.bind(window);
                    window.setInterval = function (fn, ms) {
                        const id = rawSet(fn, ms);
                        window.__timerLog.set.push({ id: id, ms: ms });
                        return id;
                    };
                    window.clearInterval = function (id) {
                        window.__timerLog.clear.push(id);
                        return rawClear(id);
                    };
                })();`,
            }, sessionId);

            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=12`, 15000);

            // Deltas, not totals: an unrelated 250ms interval registered at boot would otherwise be
            // counted as the sweep and make the leak row pass while the sweep leaked.
            const sweepTimers = async () => page.eval(`(function(){
                const l = window.__timerLog || { set: [], clear: [] };
                const s = l.set.filter(function (e) { return e.ms === 250; });
                return { ids: s.map(function (e) { return e.id; }), cleared: l.clear.slice() };
            })()`);
            const timersAtBoot = await sweepTimers();

            const overlay = await page.eval(`(function(){
                const el = document.getElementById('notifications');
                if (!el) return null;
                const cs = getComputedStyle(el);
                return { kids: el.children.length, pos: cs.position, pe: cs.pointerEvents, live: el.getAttribute('aria-live') };
            })()`);
            row('must', !!overlay && overlay.kids === 0 && overlay.pos === 'fixed'
                && overlay.pe === 'none' && overlay.live === 'polite',
                'C-NOTIF-1 the overlay mounts empty, fixed, and never eats a click',
                JSON.stringify(overlay));

            // Typed BEFORE the toast, and asserted afterwards against this exact string. A row that
            // only compared before to after would pass on two empty reads, which is what a composer
            // rebuilt on the first push would give it (gate-rows-that-can-fail F3).
            const draft = 'draft that must survive a toast';
            await page.focus('#send_textarea');
            await page.insertText(draft);
            const before = await page.eval(`(function(){
                const t = document.getElementById('send_textarea');
                t.setSelectionRange(6, 6);
                t.__notifMark = 'COMPOSER-NODE';
                const chat = document.getElementById('chat');
                if (chat) chat.__notifMark = 'CHAT-NODE';
                return { value: t.value, caret: t.selectionStart, height: t.style.height };
            })()`);

            // The isolation instrument. A MutationObserver rather than the door's [zx:dom] traces:
            // those need __st_debug(true), and C-DBG-3 reads the whole run so far as a flag-off window,
            // so turning it on above that row would break it. It also attributes better. A childList
            // record names the PARENT, so a node the renderer REMOVED is still scored to the region it
            // was removed from, which is exactly the composer damage a trace-id lookup could not see.
            // #chat-root itself is bucketed apart and not scored as a stray: it is the grid the regions
            // sit in, not a region, and reveal.zig plus reading_prefs.zig write classes and custom
            // properties on it to their own schedule. A real full-page re-render would light up the
            // composer, chat and shell counts, so excusing the root alone cannot hide one. Every
            // non-toast record is described, so a red names what moved instead of asking for a rerun.
            await page.eval(`(function(){
                window.__notifMuts = { toast: 0, composer: 0, chat: 0, shell: 0, root: 0, other: 0, what: [] };
                const bucket = function (node) {
                    const el = node && node.nodeType === 3 ? node.parentElement : node;
                    if (!el || !el.closest) return 'other';
                    if (el.closest('#notifications')) return 'toast';
                    if (el.closest('#composer')) return 'composer';
                    if (el.closest('#chat')) return 'chat';
                    if (el.closest('#shell')) return 'shell';
                    if (el.id === 'chat-root') return 'root';
                    return 'other';
                };
                window.__notifObs = new MutationObserver(function (recs) {
                    for (const r of recs) {
                        const b = bucket(r.target);
                        window.__notifMuts[b] += 1;
                        if (b !== 'toast' && window.__notifMuts.what.length < 6) {
                            const t = r.target;
                            const name = t.nodeType === 3 ? '#text' : ((t.id ? '#' + t.id : '') || t.nodeName.toLowerCase());
                            window.__notifMuts.what.push(b + ':' + r.type + ':' + name + (r.attributeName ? '[' + r.attributeName + ']' : ''));
                        }
                    }
                });
                window.__notifObs.observe(document.getElementById('chat-root'),
                    { subtree: true, childList: true, attributes: true, characterData: true });
            })()`);

            const ttl = 1200;
            await page.eval(`window.__st_notify('err', 'probe toast alpha', ${ttl})`);
            const shown = await page.waitFor("document.querySelector('#notifications div[data-level]')", 4000);
            const toastAt = Date.now();
            const toast = await page.eval(`(function(){
                const el = document.querySelector('#notifications div[data-level]');
                if (!el) return null;
                const r = el.getBoundingClientRect();
                return { text: el.textContent, level: el.getAttribute('data-level'),
                         onScreen: r.width > 0 && r.height > 0 && r.top < window.innerHeight };
            })()`);
            row('must', shown && !!toast && toast.text === 'probe toast alpha'
                && toast.level === 'err' && toast.onScreen,
                'C-NOTIF-2 a pushed notification paints as a toast carrying its own text and level',
                JSON.stringify(toast));

            // Nothing below touches the page: the only thing that can clear this toast is the sweep
            // interval inside the wasm. No app code called zx.client.setInterval before this chunk, so
            // this row is also the first proof that the ziex interval reaches Zig at all.
            const faded = await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 0", 6000);
            const fadeMs = Date.now() - toastAt;
            row('must', faded && fadeMs >= 900 && fadeMs <= 5000,
                'C-NOTIF-3 the toast fades on the sweep timer alone, near its own ttl',
                `faded=${faded} after=${fadeMs}ms ttl=${ttl}ms`);

            const after = await page.eval(`(function(){
                const t = document.getElementById('send_textarea');
                const chat = document.getElementById('chat');
                return { value: t.value, caret: t.selectionStart, height: t.style.height,
                         sameNode: t.__notifMark === 'COMPOSER-NODE',
                         chatSame: !!chat && chat.__notifMark === 'CHAT-NODE',
                         focused: document.activeElement === t };
            })()`);
            row('must', after.value === draft && after.caret === before.caret
                && after.sameNode && after.chatSame && after.height === before.height,
                'C-NOTIF-4 the composer keeps its draft, caret, height and node across the toast',
                `value=${JSON.stringify(after.value)} caret=${after.caret} node=${after.sameNode} chat=${after.chatSame} h=${after.height}`);

            await page.eval('window.__notifObs.takeRecords()');
            const where = await page.eval('window.__notifMuts');
            // Shell is EXPECTED to move now: the bell's unread badge is computed from the same list,
            // so a push that left the topbar alone would be the bug. What must not move is the state
            // the user owns, which lives in the composer and the chat log. C-NOTIF-11 asserts the
            // shell side positively, so the shell count dropping to zero cannot pass unnoticed here.
            const strayed = where.composer + where.chat + where.other;
            // toast > 0 is the instrument's own liveness proof: an observer that never fired reads
            // exactly like perfect isolation (gate-rows-that-can-fail F17).
            row('must', where.toast > 0 && strayed === 0,
                'C-NOTIF-5 the toast lifecycle left the composer and the chat log untouched',
                JSON.stringify(where));

            const kept = await page.eval(`(function(){
                const el = document.getElementById('notifications');
                return { kids: el ? el.children.length : -1 };
            })()`);
            row('must', kept.kids === 0,
                'C-NOTIF-6 the faded toast leaves no empty node behind in the overlay',
                JSON.stringify(kept));

            await page.eval('window.__notifObs.disconnect()');

            // One interval for the whole toast, and it must be GONE afterwards. A sweep that never
            // clears is a 250ms wakeup for the life of the page that no other row here would see.
            const t1 = await sweepTimers();
            const firstSweep = t1.ids.filter((id) => !timersAtBoot.ids.includes(id));
            const firstCleared = firstSweep.length === 1 && t1.cleared.includes(firstSweep[0]);
            row('must', firstSweep.length === 1 && firstCleared,
                'C-NOTIF-7 one 250ms sweep serves the toast and is cleared when the last one fades',
                `registered=${firstSweep.length} id=${firstSweep[0]} cleared=${firstCleared} clears=${JSON.stringify(t1.cleared)}`);

            // Two ttls at once. The long toast needs ttl/250 = 8 sweeps, so a timer that fired once,
            // or a fixed few times, cannot retire it. The short one going FIRST also proves the
            // per-toast decrement is per-toast: a store that aged them together would drop both at once.
            const shortTtl = 600;
            const longTtl = 2000;
            await page.eval(`window.__st_notify('info', 'probe toast short', ${shortTtl});`
                + `window.__st_notify('warning', 'probe toast long', ${longTtl});`);
            const pairAt = Date.now();
            const bothUp = await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 2", 3000);
            const shortGone = await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 1", 5000);
            const shortAt = Date.now() - pairAt;
            const survivor = await page.eval("(document.querySelector('#notifications div[data-level]')||{}).textContent");
            const longGone = await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 0", 6000);
            const longAt = Date.now() - pairAt;
            row('must', bothUp && shortGone && longGone && survivor === 'probe toast long'
                && shortAt >= 450 && longAt >= 1800 && longAt > shortAt + 600,
                'C-NOTIF-8 the sweep keeps firing: the 600ms toast goes, the 2000ms one stays, then goes',
                `short=${shortAt}ms long=${longAt}ms survivor=${JSON.stringify(survivor)} sweeps>=${Math.floor(longAt / 250)}`);

            // The restart. C-NOTIF-7 proved the timer stops; a stop with no restart would mean the
            // FIRST toast of the page fades and every later one hangs on screen forever.
            const t2 = await sweepTimers();
            const secondSweep = t2.ids.filter((id) => !t1.ids.includes(id));
            const secondCleared = secondSweep.length === 1 && t2.cleared.includes(secondSweep[0]);
            row('must', secondSweep.length === 1 && secondCleared,
                'C-NOTIF-9 a push after the sweep stopped starts a fresh interval, also cleared',
                `registered=${secondSweep.length} id=${secondSweep[0]} cleared=${secondCleared} totalSweeps=${t2.ids.length}`);

            await cdp.send('Page.removeScriptToEvaluateOnNewDocument', { identifier: spy.identifier }, sessionId);

            // Three pushes have happened above and none were read, so the badge is the count of them.
            // Asserting the NUMBER, not merely that a badge exists: a badge stuck at 1 looks correct.
            const bell = await page.eval(`(function(){
                const b = document.getElementById('d-notifications');
                if (!b) return null;
                const badge = b.querySelector('.notif-badge');
                return { icon: b.getAttribute('data-icon'), label: b.getAttribute('aria-label'),
                         badge: badge ? badge.textContent : null,
                         badgeHidden: badge ? badge.getAttribute('aria-hidden') : null };
            })()`);
            row('must', !!bell && bell.icon === 'bell' && bell.badge === '3'
                && bell.label === 'Notifications, 3 unread' && bell.badgeHidden === 'true',
                'C-NOTIF-10 the bell carries the unread count in its badge and in its name',
                JSON.stringify(bell));

            await page.click('#d-notifications');
            const listed = await page.waitFor("document.querySelectorAll('#notif-list li').length === 3", 4000);
            const drawer = await page.eval(`(function(){
                const li = [...document.querySelectorAll('#notif-list li')];
                return { rows: li.map(function (e) {
                             return { text: e.querySelector('.notif-text').textContent,
                                      age: e.querySelector('.notif-age').textContent,
                                      level: e.getAttribute('data-level') };
                         }),
                         empty: !!document.querySelector('.panel-empty') };
            })()`);
            const r = drawer.rows;
            row('must', listed && r.length === 3
                && r[0].text === 'probe toast long' && r[2].text === 'probe toast alpha'
                && r[0].level === 'warning' && r[2].level === 'err'
                && r.every((e) => e.age.length > 0) && !drawer.empty,
                'C-NOTIF-11 the drawer lists the history newest first, with each level and age',
                JSON.stringify(r));

            // Opening the drawer is the read receipt, so the badge must be gone WHILE the list is up.
            const afterOpen = await page.eval(`(function(){
                const b = document.getElementById('d-notifications');
                return { badge: !!b.querySelector('.notif-badge'), label: b.getAttribute('aria-label') };
            })()`);
            row('must', afterOpen.badge === false && afterOpen.label === 'Notifications',
                'C-NOTIF-12 opening the drawer marks the list read and clears the badge',
                JSON.stringify(afterOpen));

            await page.click('#notif-clear');
            const cleared = await page.waitFor("document.querySelector('#panel-view .panel-empty') && !document.querySelector('#notif-list')", 4000);
            const emptyText = await page.eval("(document.querySelector('#panel-view .panel-empty')||{}).textContent || ''");
            row('must', cleared && emptyText.length > 40 && /reload/i.test(emptyText),
                'C-NOTIF-13 Clear empties the list and leaves a real empty state, not a blank panel',
                `cleared=${cleared} copy=${JSON.stringify(emptyText.slice(0, 60))}`);

            // Four levels at once, to prove the ramp DISCRIMINATES. Four identical borders would pass
            // any "is it coloured" row, so the assertion is on the count of DISTINCT colours, plus a
            // measured contrast floor against the toast ground (WD4 non-text 3:1).
            await page.eval(`window.__st_notify('info','ramp info',9000);window.__st_notify('success','ramp success',9000);`
                + `window.__st_notify('warning','ramp warning',9000);window.__st_notify('err','ramp error',9000);`);
            await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 4", 4000);
            const ramp = await page.eval(`(function(){
                ${contrastFn}
                const el = [...document.querySelectorAll('#notifications div[data-level]')];
                const edges = el.map(function (e) { return getComputedStyle(e).borderLeftColor; });
                const ground = getComputedStyle(el[0]).backgroundColor;
                return { levels: el.map(function (e) { return e.getAttribute('data-level'); }),
                         edges: edges, distinct: new Set(edges).size,
                         width: getComputedStyle(el[0]).borderLeftWidth,
                         minContrast: Math.round(Math.min.apply(null, edges.map(function (c) { return contrast(c, ground); })) * 100) / 100 };
            })()`);
            row('must', ramp.distinct === 4 && ramp.width === '4px' && ramp.minContrast >= 3,
                'C-NOTIF-14 the four status levels paint four distinct edges, each clearing 3:1 on the toast ground',
                `distinct=${ramp.distinct} width=${ramp.width} minContrast=${ramp.minContrast} ${JSON.stringify(ramp.edges)}`);

            // A toast already on screen must not replay its entrance when the NEXT one arrives. The
            // list renders unkeyed, so this asks whether the vdom patches position 0 in place or
            // rebuilds it: a rebuilt node restarts its 180ms fade from opacity 0, which reads as the
            // whole stack flickering every time a notification lands. Marked node, then one push.
            await page.eval("document.querySelector('#notifications div[data-level]').__toastMark = 'FIRST';");
            await sleep(400);
            await page.eval("window.__st_notify('info','stack probe',9000)");
            await page.waitFor("document.querySelectorAll('#notifications div[data-level]').length === 5", 4000);
            const stack = await page.eval(`(function(){
                const el = document.querySelector('#notifications div[data-level]');
                return { sameNode: el.__toastMark === 'FIRST', opacity: Number(getComputedStyle(el).opacity),
                         text: el.textContent };
            })()`);
            row('must', stack.sameNode && stack.opacity > 0.9 && stack.text === 'ramp info',
                'C-NOTIF-18 an arriving toast does not rebuild or reflash the ones already up',
                JSON.stringify(stack));

            // THE MOBILE ROW. #chat-root sets overflow-x:clip below 768px and the overlay is a fixed
            // child of it, so "is it in the DOM" proves nothing here: the question is whether the
            // clip ate it. elementFromPoint answers that, because a clipped node is not hit-testable.
            const wideW = await page.eval('window.innerWidth');
            await page.cdp.send('Emulation.setDeviceMetricsOverride',
                { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, page.sessionId);
            await page.waitFor('window.innerWidth === 390', 3000);
            // Sampled before AND after a settle window, because a single immediate read cannot tell
            // "the clip ate it" from "caught it mid-entrance", and those want opposite fixes. The
            // pre-sample is a diagnostic only: it read 0 while the row above still ran the 180ms
            // fade, which is why the assertion is on the settled sample.
            const phoneAtSwitch = await page.eval("Number(getComputedStyle(document.querySelector('#notifications div[data-level]')).opacity)");
            await sleep(600);
            const phone = await page.eval(`(function(){
                const el = document.querySelector('#notifications div[data-level]');
                if (!el) return { seen: false };
                const r = el.getBoundingClientRect();
                const cx = Math.round(r.left + r.width / 2), cy = Math.round(r.top + r.height / 2);
                const hit = document.elementFromPoint(cx, cy);
                const cs = getComputedStyle(el);
                return { seen: true, w: Math.round(r.width), h: Math.round(r.height),
                         left: Math.round(r.left), right: Math.round(r.right),
                         top: Math.round(r.top), bottom: Math.round(r.bottom),
                         inViewport: r.left >= 0 && r.top >= 0 && r.right <= 390 && r.bottom <= 844,
                         hitsSelf: !!hit && (hit === el || el.contains(hit)),
                         opacity: Number(cs.opacity), vis: cs.visibility, disp: cs.display };
            })()`);
            await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
            const restored = await page.waitFor(`window.innerWidth === ${wideW}`, 5000);
            row('must', phone.seen && phone.w > 0 && phone.h > 0 && phone.inViewport && phone.hitsSelf
                && phone.opacity > 0.9 && phone.vis === 'visible' && phone.disp !== 'none',
                'C-NOTIF-15 a toast is on screen and hit-testable at 390px, not eaten by the clip',
                `${JSON.stringify(phone)} opacityAtSwitch=${phoneAtSwitch}`);
            row('must', restored,
                'C-NOTIF-16 the 390px override is fully restored before later rows run',
                `wide=${wideW} now=${await page.eval('window.innerWidth')}`);

            // Reduced motion must make the toast GENTLER, never absent: a fade that never runs leaves
            // opacity at 0, and every DOM row still passes over an invisible toast (WD25).
            //
            // The in-app motion setting deliberately OVERRIDES the OS preference (the
            // :root:has(#shell.motion-on) rule), and row A5a set it to On earlier in this run, so the
            // OS path is only reachable with the stored pref cleared, which is what a first-time
            // visitor with reduce set actually has. Clearing it needs a reload to be read.
            await page.cdp.send('Emulation.setEmulatedMedia',
                { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] }, page.sessionId);
            await page.eval("localStorage.removeItem('st-motion')");
            await page.navigate(`${args.base}/?demo=1`);
            await page.waitFor(hydrated, 15000);
            await page.eval("window.__st_notify('info','reduced motion toast',9000)");
            const rmShown = await page.waitFor("document.querySelector('#notifications div[data-level]')", 4000);
            await sleep(400);
            const rm = await page.eval(`(function(){
                const el = document.querySelector('#notifications div[data-level]');
                if (!el) return { move: getComputedStyle(document.documentElement).getPropertyValue('--move').trim() };
                const cs = getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return { move: getComputedStyle(document.documentElement).getPropertyValue('--move').trim(),
                         opacity: Number(cs.opacity), anim: cs.animationName,
                         w: Math.round(r.width), h: Math.round(r.height) };
            })()`);
            await page.cdp.send('Emulation.setEmulatedMedia', { features: [] }, page.sessionId);
            await page.eval("localStorage.setItem('st-motion','on')");
            row('must', rmShown && rm.move === '0' && rm.opacity > 0.9 && rm.anim === 'toast-in'
                && rm.w > 0 && rm.h > 0,
                'C-NOTIF-17 under reduced motion the toast still lands and settles fully opaque',
                JSON.stringify(rm));

        }
        /* C-NOTIF END */

        /* C-DBG */
        // The [zx:dom] channel. A live crash (removeChild NotFoundError) came out of the door with the
        // framework's tree and the real DOM already drifted apart, and no reproduction was ever found,
        // so the framework says what it is doing and these rows hold that saying honest.
        // KEEP THIS BLOCK LAST: C-DBG-8 reads the anomalies of the WHOLE run, and a block appended
        // after it would go unwatched.
        console.log('== C-DBG the [zx:dom] debug channel ==');
        {
            // A log grows only from the socket callback, so awaiting a sleep is what lets it arrive.
            const grewBy = async (log, from, ms = 3000) => {
                const deadline = Date.now() + ms;
                while (Date.now() < deadline) {
                    if (log.length > from) return true;
                    await sleep(50);
                }
                return false;
            };
            const product = (log, from = 0) => log.slice(from).filter((e) => !e.text.includes(ZX_PROBE));
            // The glue announces the flag twice at console.info (custom.js:44 the __st_debug ack,
            // custom.js:68 the flag-on banner). Neither names an op, a vnode or a tag, so neither is
            // a trace, and counting them as one makes "tracing happens" true whenever the switch is
            // merely acknowledged, with every real trace dead. The per-op traces are the debug ones.
            const traced = (log, from = 0) => product(log, from).filter((e) => e.type === 'debug');
            // console.log and console.warn are declared by neither the door nor the glue. A prefixed
            // line arriving on one is a sink nobody chose and a console filter on debug would miss.
            const strayed = (log, from = 0) => product(log, from).filter((e) => e.type !== 'debug' && e.type !== 'info');

            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await page.eval("localStorage.removeItem('zx:debug')");

            // The sensors go first. Every row under them claims console output was ABSENT, and an
            // absence row proves nothing until the capture that would have seen it is shown working:
            // a cut pipe, a renamed CDP type, a swallowed prefix all read as a clean run. The probes
            // are emitted from the page and carry ST-SENSOR-PROBE, so no product row counts them.
            const errFrom = zxAnomalies.length;
            await page.eval(`console.error('${ZX_PREFIX} ${ZX_PROBE} removeChild vnode=7 tag=div')`);
            const errSeen = await grewBy(zxAnomalies, errFrom);
            const errProbes = zxAnomalies.slice(errFrom).filter((e) => e.text.includes(ZX_PROBE));
            row('must', errSeen && errProbes.length === 1 && errProbes[0].type === 'error',
                'C-DBG-1 the anomaly sensor sees a [zx:dom] console.error',
                `seen=${errSeen} type=${errProbes[0] ? errProbes[0].type : 'none'} text=${JSON.stringify(errProbes[0] ? errProbes[0].text : '')}`);

            const dbgFrom = zxTraces.length;
            await page.eval(`console.debug('${ZX_PREFIX} ${ZX_PROBE} patch vnode=7 tag=div')`);
            const dbgSeen = await grewBy(zxTraces, dbgFrom);
            const dbgProbes = zxTraces.slice(dbgFrom).filter((e) => e.text.includes(ZX_PROBE));
            row('must', dbgSeen && dbgProbes.length === 1 && dbgProbes[0].type === 'debug',
                'C-DBG-2 the trace sensor sees a [zx:dom] console.debug',
                `seen=${dbgSeen} type=${dbgProbes[0] ? dbgProbes[0].type : 'none'} text=${JSON.stringify(dbgProbes[0] ? dbgProbes[0].text : '')}`);

            // Position is the window here: every load of this run so far ran with the flag off, and
            // the rows that turn it on are all below. So this reads the whole run, not one page.
            const leaked = product(zxTraces);
            row('must', leaked.length === 0,
                'C-DBG-3 debug output does not leak into a default load (whole run, flag off)',
                `traces=${leaked.length}${leaked.length ? ` first=${JSON.stringify(leaked[0].text)} type=${leaked[0].type} at=${leaked[0].url}` : ''}`);

            // C-DBG-4 to C-DBG-7 are pending: nothing emits a trace until the door and the glue land,
            // so they are RED by construction today and their PENDPASS is the promotion signal.
            const onFrom = zxTraces.length;
            await page.navigate(`${args.base}/?zxdebug=1`);
            await page.waitFor(hydrated, 15000);
            // Wait for the trace rather than sample the instant hydration reports done: the door's
            // console line is not part of the hydrated signal, so a sample here is a wall clock, and
            // a wall clock read on a box running five members is a different test than on a quiet one.
            await grewBy(zxTraces, onFrom, 5000);
            const onTraces = traced(zxTraces, onFrom);
            const onStrays = strayed(zxTraces, onFrom);
            const onStored = await page.eval("localStorage.getItem('zx:debug')");
            row('must', onTraces.length > 0 && onStrays.length === 0 && onStored !== null,
                'C-DBG-4 ?zxdebug=1 traces the render and remembers the choice',
                `traces=${onTraces.length} types=${JSON.stringify([...new Set(product(zxTraces, onFrom).map((e) => e.type))])} strays=${onStrays.length} stored=${JSON.stringify(onStored)}`);

            const backFrom = zxTraces.length;
            await page.navigate(`${args.base}/`);
            await page.waitFor(hydrated, 15000);
            await grewBy(zxTraces, backFrom, 5000);
            const backTraces = traced(zxTraces, backFrom);
            row('must', backTraces.length > 0,
                'C-DBG-5 a plain reload still traces, so the choice outlived the query string',
                `traces=${backTraces.length} stored=${JSON.stringify(await page.eval("localStorage.getItem('zx:debug')"))}`);

            const offFrom = zxTraces.length;
            await page.navigate(`${args.base}/?zxdebug=0`);
            await page.waitFor(hydrated, 15000);
            // An absence has no completion signal to wait on, so this one settle is unavoidable: it
            // gives a trace that WOULD have come the same room the rows above wait 5000ms for.
            await sleep(1000);
            const offTraces = product(zxTraces, offFrom);
            const offStored = await page.eval("localStorage.getItem('zx:debug')");
            // The tracedBefore term is the point of the row. "No traces and no key" is TRUE on a build
            // where tracing was never possible and the key never existed, so without it the row is
            // satisfied by the default and proves nothing stopped.
            row('must', backTraces.length > 0 && offTraces.length === 0 && offStored === null,
                'C-DBG-6 ?zxdebug=0 stops the tracing it was actually doing, and forgets it',
                `tracedBefore=${backTraces.length} tracesAfter=${offTraces.length} stored=${JSON.stringify(offStored)}`);

            const liveFrom = zxTraces.length;
            const hasSwitch = await page.eval("typeof window.__st_debug === 'function'");
            if (hasSwitch) await page.eval('window.__st_debug(true)');
            // A trace needs the door to patch something. Boot is the only other churn and it is over,
            // so the panel open is what gives the switch something to say, with no reload.
            const drawer = await page.waitFor("document.getElementById('d-characters')", 5000);
            if (drawer) {
                await page.click('#d-characters');
                await page.waitFor("document.querySelector('#chat-root .char-item, #chat-root .panel-empty')", 5000);
                await grewBy(zxTraces, liveFrom, 5000);
            }
            // Counts the per-op traces only. __st_debug ALWAYS prints its own acknowledgement, so a
            // row counting every prefixed line would be satisfied by the switch reporting itself,
            // which is the one thing it does whether or not it turned anything on.
            const liveTraces = traced(zxTraces, liveFrom);
            const liveAck = product(zxTraces, liveFrom).some((e) => e.type === 'info');
            row('must', hasSwitch && drawer && liveTraces.length > 0,
                'C-DBG-7 __st_debug(true) starts tracing mid-session, with no reload',
                `switch=${hasSwitch} panelOpened=${drawer} traces=${liveTraces.length} ack=${liveAck}`);

            // Last row of the gate on purpose. Every load any row above has driven, flag on or off,
            // has been watched for an anomaly, so the drift names itself the moment it returns and
            // nobody has to reproduce it first.
            const anomalies = product(zxAnomalies);
            row('must', anomalies.length === 0,
                'C-DBG-8 no [zx:dom] or [zx:render] anomaly in the whole run',
                anomalies.length === 0
                    ? 'clean'
                    : `${anomalies.length} anomalies, first at ${anomalies[0].url}: ${JSON.stringify(anomalies[0].text)}`);
            for (const a of anomalies) console.log(`          anomaly at ${a.url}: ${a.text}`);

            // Both flavours, because they are not one mechanism: a throw out of an event handler and
            // a rejected promise nobody awaited reach the page by different paths, and the crash we
            // are hunting took the second. A sensor proven on one would leave the other unwatched.
            const exFrom = pageExceptions.length;
            await page.eval(`setTimeout(function(){ throw new Error('${ZX_PROBE} sync: removeChild on a node that moved'); }, 0)`);
            await page.eval(`Promise.reject(new Error('${ZX_PROBE} async: NotFoundError off a promise'))`);
            await grewBy(pageExceptions, exFrom + 1, 5000);
            const exProbes = pageExceptions.slice(exFrom).filter((e) => e.text.includes(ZX_PROBE));
            const sawSync = exProbes.some((e) => e.text.includes('sync:'));
            const sawAsync = exProbes.some((e) => e.text.includes('async:'));
            row('must', sawSync && sawAsync,
                'C-DBG-9 the exception sensor sees an uncaught throw and a rejected promise',
                `sync=${sawSync} async=${sawAsync} captured=${exProbes.length}`);

            // Strictly broader than every prefix row above, and the only one that would have caught
            // the crash this channel was built for: an exception reaches no console.error, so the
            // door cannot be the witness to a failure that stops it from speaking.
            const uncaught = pageExceptions.filter((e) => !e.text.includes(ZX_PROBE));
            row('must', uncaught.length === 0,
                'C-DBG-10 no uncaught exception in the whole run',
                uncaught.length === 0
                    ? 'clean'
                    : `${uncaught.length} uncaught, first at ${uncaught[0].url}: ${JSON.stringify(uncaught[0].text.slice(0, 160))}`);
            for (const e of uncaught) console.log(`          uncaught at ${e.url}: ${e.text.split('\n')[0]}`);
        }

    } finally {
        clearTimeout(watchdog);
        cleanup();
    }

    console.log('');
    if (pendingPasses > 0) {
        console.log(`interactions: ${pendingPasses} pending row(s) now PASS - promote them to must`);
    }
    // The count comes from the counter row() keeps, not from grepping this output back. A bare
    // "all must rows passed" says the same thing when every row passed and when a crash before the
    // first row meant none ran, and those are opposite facts.
    const pend = pendingRows > 0 ? ` (+${pendingRows} pending, not counted)` : '';
    console.log(`interactions: ${mustRows - mustFails} of ${mustRows} must rows passed, ${mustFails} failed${pend}`);
    process.exit(mustFails === 0 ? 0 : 1);
}

main().catch((err) => {
    process.stderr.write(`interactions.mjs: ${err.message}\n`);
    process.exit(2);
});

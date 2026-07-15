// Interaction gate: real Chrome input (CDP) against the served client, so a silently-dead handler
// (the ziex currentTarget/jsz traps) fails a check instead of shipping. Rows: 'must' = fatal,
// 'pending' = known-red plan item (printed; a pending PASS asks for promotion to must).
// Usage: node interactions.mjs --base http://127.0.0.1:PORT [--timeout MS]

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function parseArgs(argv) {
    // Watchdog must exceed the worst-case sum of row waits (~140s all-red), or a fully broken build
    // dies at the watchdog before the per-row diagnostics print.
    const out = { base: null, timeout: 240000 };
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
    constructor(cdp, sessionId, consoleLines) {
        this.cdp = cdp;
        this.sessionId = sessionId;
        this.consoleLines = consoleLines;
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

    let mustFails = 0;
    let pendingPasses = 0;
    const row = (kind, ok, label, detail) => {
        let tag;
        if (kind === 'must') {
            tag = ok ? 'ok      ' : 'FAIL    ';
            if (!ok) mustFails += 1;
        } else {
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

        const consoleLines = [];
        cdp.onEvent = (msg) => {
            if (msg.method === 'Runtime.consoleAPICalled' && msg.sessionId === sessionId) {
                const line = (msg.params.args || [])
                    .map((a) => (a.value !== undefined ? String(a.value) : (a.description || '')))
                    .join(' ');
                consoleLines.push(line);
            }
        };
        const page = new Page(cdp, sessionId, consoleLines);
        const hydrated = "document.querySelector('#chat-root.hydrated')";

        // ---- Session A: demo fixtures + settings drawer + resize handles ----
        console.log('== session A: demo mode (?demo=1) ==');
        await page.navigate(`${args.base}/?demo=1`);
        row('must', await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=12`, 15000),
            'A1 boot: hydrated with 12 fixtures');

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
        row('must', await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000)
            && page.sawConsole('opened chat: Rita Recent'),
            'B1 boot auto-opens the most recent chat (Rita Recent)');

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

        await page.eval("(function(){const s=document.querySelector('.char-pagesize'); s.value='20'; s.dispatchEvent(new Event('change',{bubbles:true}));})()");
        // Row count, not the label: at page_size=0 the label already reads "1..60 of 60", so a label
        // predicate passes with a dead handler (critic finding).
        row('must', await page.waitFor("document.querySelectorAll('#chat-root .char-item').length === 20", 4000),
            'B5 page size select paginates (working target-based handler)');
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
        await page.navigate(`${args.base}/`);
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        row('must', await page.waitFor("document.getElementById('send-status') && document.getElementById('send-status').textContent.includes('Connected')", 8000),
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

        // PERSIST: send, let the reply seal (user append on send + assistant append on seal), then
        // reload and prove both turns survive (the mock /get echoes the appended messages).
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
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        const survived = await page.waitFor("document.body.textContent.includes('PERSIST PROBE')", 6000);
        row('must', gotUser && gotAsst && survived,
            'SL-send persists across a reload (user + assistant appended)', `user=${gotUser} asst=${gotAsst} reload=${survived}`);

        // --- connection ---
        // /dev/state is the mock's node-side readback of what the client persisted and last generated with.
        console.log('== connection setup (server-persisted) ==');
        const connUrl = 'http://127.0.0.1:9099';
        await page.navigate(`${args.base}/`);
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
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

        // --- append-409 ---
        // A "409:" message makes the mock append 409; asserted via observable state (mock counters +
        // store reset), not console lines, which are fragile after many prior sends.
        console.log('== append 409 resync ==');
        await page.navigate(`${args.base}/`);
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        // Wait for the connection to load, else the send is a no-op (conn null) and never appends.
        await page.waitFor("document.getElementById('send-status') && document.getElementById('send-status').textContent.includes('Connected')", 8000);
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
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        await page.waitFor("document.getElementById('send-status') && document.getElementById('send-status').textContent.includes('Connected')", 8000);
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
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
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
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);
        await page.waitFor("document.getElementById('send-status') && document.getElementById('send-status').textContent.includes('Connected')", 8000);
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
        await page.waitFor(`${hydrated} && document.querySelectorAll('#chat .mes').length>=3`, 15000);

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

        // Close the character dock so the message controls are unobstructed, then open message 1 history.
        await page.click('#d-characters');
        await page.click('[data-undo-history="1"]');
        const popover = await page.waitFor(
            "document.querySelector('#undo-surface [data-undo-restore][data-undo-kind=\\'version\\']')", 6000);
        row('must', popover, 'UNDO-3 the per-message history control opens the version popover');

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

        // The whole-chat snapshot overlay, surfaced from the composer Options button.
        await page.click('#composer button[aria-label="Options"]');
        const snapListed = await page.waitFor(
            "document.querySelector('#undo-surface [data-undo-restore][data-undo-kind=\\'snapshot\\']')", 6000);
        row('must', snapListed, 'UNDO-6 composer Options opens the snapshot overlay with a save point');

        const stU2 = await (await fetch(`${args.base}/dev/state`)).json();
        await page.click("#undo-surface [data-undo-restore][data-undo-kind='snapshot']");
        const snapRestored = await (async () => {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
                const closed = await page.eval("document.querySelector('#undo-surface') === null");
                const st = await (await fetch(`${args.base}/dev/state`)).json();
                if (closed && st.get_count > stU2.get_count) return true;
                await sleep(150);
            }
            return false;
        })();
        row('must', snapRestored, 'UNDO-7 restoring a snapshot closes the overlay and resyncs the reader');
    } finally {
        clearTimeout(watchdog);
        cleanup();
    }

    console.log('');
    if (pendingPasses > 0) {
        console.log(`interactions: ${pendingPasses} pending row(s) now PASS - promote them to must`);
    }
    console.log(mustFails === 0
        ? 'interactions: all must rows passed'
        : `interactions: ${mustFails} must row(s) FAILED`);
    process.exit(mustFails === 0 ? 0 : 1);
}

main().catch((err) => {
    process.stderr.write(`interactions.mjs: ${err.message}\n`);
    process.exit(2);
});

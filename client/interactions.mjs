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
        await openRecentChat();
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

        // --- append-409 ---
        // A "409:" message makes the mock append 409; asserted via observable state (mock counters +
        // store reset), not console lines, which are fragile after many prior sends.
        console.log('== append 409 resync ==');
        await page.navigate(`${args.base}/`);
        await openRecentChat();
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
        await openRecentChat();
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
        await page.cdp.send('Emulation.setDeviceMetricsOverride',
            { width: 600, height: 900, deviceScaleFactor: 1, mobile: false }, page.sessionId);
        const narrowShown = await page.waitFor(
            "(function(){const t=document.querySelector('#chat .mes .msg-menu-trigger');if(!t)return false;"
            + "const o=getComputedStyle(t).opacity;const mr=t.closest('.mes').getBoundingClientRect();"
            + "const r=t.getBoundingClientRect();return o!=='0' && r.right<=mr.right+2 && r.top<=mr.top+40;})()", 3000);
        await page.cdp.send('Emulation.clearDeviceMetricsOverride', {}, page.sessionId);
        row('must', narrowShown, 'C-MSG narrow viewport keeps the trigger inside the top-right');

        // Copy writes the message's own text to the clipboard (no endpoint, no history write).
        await page.eval("(function(){window.__copied=null;const s=(t)=>{window.__copied=t;return Promise.resolve();};"
            + "try{navigator.clipboard.writeText=s;}catch(e){Object.defineProperty(navigator,'clipboard',{value:{writeText:s},configurable:true});}})()");
        const msg0text = await page.eval("document.querySelectorAll('#chat .mes_text')[0].textContent.trim()");
        const copyMenuOpen = await openMenu(0);
        if (copyMenuOpen) await page.click("#msg-menu [data-msg-action='copy']");
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
        row('must', copyOk, 'C-MSG copy writes the message text to the clipboard', `copied=${JSON.stringify((copied || '').slice(0, 24))} msg0=${JSON.stringify(msg0text.slice(0, 16))}`);

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

        // EDIT the topmost visible message. The edit must land at firstAbs (server-probed by the exact
        // absolute index) and leave index 0 untouched. A store-relative index would miss firstAbs entirely.
        await page.eval("window.prompt = function(){ return 'EDITED-BY-GATE-T0'; };");
        const stubOk = await page.eval("window.prompt() === 'EDITED-BY-GATE-T0'");
        const editMenuOpen = await openMenu(firstAbs);
        const getBeforeEdit = (await (await fetch(`${args.base}/dev/state`)).json()).get_count;
        if (editMenuOpen) await page.click("#msg-menu [data-msg-action='edit']");
        const editLanded = editMenuOpen && await (async () => {
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
            `landed=${editLanded} stub=${stubOk} menu=${editMenuOpen} ft=${mst0.full_token}->${mst1.full_token} readerTotal=${mst1.reader_total}`);

        // DELETE the topmost visible message. reader base drops by one; index 0 must stay put.
        await page.eval("window.confirm = () => true;");
        const delAbs = await pickBaseAbs();
        const delMenuOpen = await openMenu(delAbs);
        if (delMenuOpen) await page.click("#msg-menu [data-msg-action='delete']");
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
        // Boot shows the landing (no auto-open) with the recent list: three character chats, the group
        // chat filtered out of v1.
        row('must', await page.waitFor(
            `${hydrated} && document.querySelector('#chat-home:not(.hidden)') && document.querySelectorAll('#chat-home .home-thread').length === 3`, 15000),
            'HOME-1 boot shows the home landing with three recent character chats (group filtered)');

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
        await page.waitFor("document.getElementById('send-status') && document.getElementById('send-status').textContent.includes('Connected')", 8000);
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

        const listed = await page.waitFor("document.querySelectorAll('#bg-gallery .bg-tile-wrap').length === 4", 8000);
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

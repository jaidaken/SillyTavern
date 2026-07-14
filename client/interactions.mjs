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
        row('pending', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-size')==='s'", 2500),
            'A3 [B1] reading Small sets data-reading-size on #chat-root');

        await page.click('.settings-tab[data-reading-val="appearance"]');
        row('pending', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-tab')==='appearance'", 2500),
            'A4 [B2] settings tab switches to Appearance');

        // The motion buttons sit on the appearance tab, display:none until the (dead) tab handler
        // sets data-reading-tab: motion is UNREACHABLE by real input at HEAD. Both rows gate on B2.
        let motionClicked = false;
        try {
            await page.click('[data-motion-set="on"]');
            motionClicked = true;
        } catch (_) { /* hidden while B2 is red */ }
        row('pending', motionClicked
            && await page.waitFor("document.getElementById('shell').classList.contains('motion-on')", 2500),
            'A5a [B2] motion On reaches the shell class (JS delegate path)');
        row('pending', motionClicked
            && await page.waitFor("document.querySelector('[data-motion-set=\\'on\\']').getAttribute('aria-checked')==='true'", 2500),
            'A5b [B2+B3] motion On updates the segmented highlight (zx state path)');

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
        row('pending', await page.waitFor(`Math.abs(document.querySelector('#panel-view.panel-right').getBoundingClientRect().width - ${pw0}) > 20`, 2500),
            'A9 [B7] side-panel handle drags the dock width');

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
        row('pending', await page.waitFor("document.getElementById('chat-root').getAttribute('data-reading-size')==='s'", 2500),
            'B10 [B6] persisted reading prefs re-apply at boot');
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

// Interaction gate: real Chrome input (CDP) against the served client, so a silently-dead handler
// (the ziex currentTarget/jsz traps) fails a check instead of shipping. Rows: 'must' = fatal,
// 'pending' = known-red plan item (printed; a pending PASS asks for promotion to must).
// Usage: node interactions.mjs --base http://127.0.0.1:PORT [--timeout MS]

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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

        // A1b exists because 338a06bb4 shipped a glue call to a wasm export nobody added, and every
        // gate stayed green: that call only throws at runtime, on a path one real upload reaches.
        // Call sites come from SOURCE (dist is minified, which renames the `wasm` local); the
        // denominator is the built module's OWN export table, because a source-side grep lies here:
        // __st_set_panel_width is a `pub export fn` in ui.zig, not in bridge.zig's comptime block.
        const glueSrc = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'glue', 'custom.js'), 'utf8');
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
        // null (writeText never ran) and "" (it ran with empty text) are different failures; the old
        // report printed both as copied="", which is why this row read as a mystery when it flaked.
        row('must', copyOk, 'C-MSG copy writes the message text to the clipboard',
            `menuOpen=${copyMenuOpen} copied=${copied === null ? 'NEVER-CALLED' : JSON.stringify(copied.slice(0, 24))} msg0=${JSON.stringify(msg0text.slice(0, 16))}`);

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

        // The fixture's chats are 5 minutes, 3 hours and 4 days old, so "recently" is the NaN fallback
        // rather than a date, and a list whose parse fails for every row still looks populated.
        const whenTexts = await page.eval(
            "JSON.stringify(Array.from(document.querySelectorAll('#chat-home .home-thread time')).map(function(t){return t.textContent.trim();}))");
        const whens = JSON.parse(whenTexts);
        const datesReal = whens.length === 3 && whens.every((w) => /^(just now|\d+[mhd] ago|\d{4}-\d{2}-\d{2})$/.test(w));
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

        // The upload control. The POST itself rides a FormData helper in custom.js that this member
        // does not own, so what is pinned here is our half: the control, and the call into the seam.
        const uploadCtl = await page.eval(
            "(function(){var i=document.getElementById('bg-upload-input');return !!i && i.type==='file' && !!i.getAttribute('aria-label') && !!i.getAttribute('name');})()");
        row('must', uploadCtl, 'C-BG2-4 the upload control is present, named and typed for files', `ctl=${uploadCtl}`);

        const seam = await (async () => {
            await page.eval('window.__bg_upload_called = false; window.__st_bg_upload = function(){ window.__bg_upload_called = true; };');
            // bubbles: true is load-bearing. ziex delegates from a root, so a non-bubbling change
            // event never reaches the handler and the row reads as a dead seam.
            await page.eval("document.getElementById('bg-upload-input').dispatchEvent(new Event('change', { bubbles: true }))");
            return await page.waitFor('window.__bg_upload_called === true', 4000);
        })();
        const sending = await page.waitFor("/Uploading/.test(document.querySelector('.bg-upload-row').textContent)", 4000);
        row('must', seam && sending, 'C-BG2-5 picking a file calls the upload glue and shows the wait', `seam=${seam} sending=${sending}`);

        // C-BG2-5 STUBS __st_bg_upload, so it pins the seam and nothing past it: that is how
        // 338a06bb4 shipped the glue without its bridge export and stayed green. Navigate fresh (the
        // reload destroys the stub) and drive the REAL helper, because the failure lived past the
        // seam and uploadPick's catch is blind to it (__st_bg_upload exists; its callee throws).
        await page.navigate(`${args.base}/`);
        await page.waitFor(hydrated, 15000);
        await page.click('#d-backgrounds');
        await page.waitFor("document.getElementById('bg-upload-input')", 8000);
        const bgPngPath = join(mkdtempSync(join(tmpdir(), 'st-bg-')), 'picked bg.png');
        writeFileSync(bgPngPath, Buffer.from(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            'base64'));
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

            // KNOWN RED, and the defect is NOT in the card editor: onSaveDone refreshes the character
            // list, and char_api.rebuildCharacterStore calls char_store.clear(), which nulls
            // selected_index (character_store.zig:85). Nothing restores it, so a save DESELECTS the
            // character app-wide: the editor falls back to "Pick a character" and its own "Saved to
            // the card." dies with the form. Fixing it means editing char_api.zig, which this member
            // does not own. Promote this to must once the rebuild re-selects by avatar.
            const aliveAfterSave = await page.eval("!!document.querySelector('#card-editor-notice')");
            const noticeSaved = aliveAfterSave && await page.waitFor(
                "document.getElementById('card-editor-notice').textContent.indexOf('Saved') >= 0", 4000);
            row('pending', !!noticeSaved, 'C-CARD-14 a save keeps the character selected and says it saved',
                `formAlive=${aliveAfterSave} selection=${await page.eval("!document.querySelector('#card-editor p')||document.querySelector('#card-editor p').textContent")}`);

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

            // Same deselect as C-CARD-14: the upload's own list refresh drops the selection, so the
            // panel that would report the new image is gone by the time it lands.
            const avatarNotice = await page.eval(
                "!!document.getElementById('card-editor-notice') && document.getElementById('card-editor-notice').textContent.indexOf('New image saved') >= 0");
            row('pending', avatarNotice, 'C-CARD-15 the panel reports the new image in its own footer',
                `notice=${avatarNotice}`);
        }

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

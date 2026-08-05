// EXHAUSTIVE DIFFERENTIAL prompt-parity oracle. Runs BOTH prompt builders (old public/ frontend and
// new wasm client) on ONE shared fixture and byte-diffs the assembled prompts. This is the only
// method that is actually exhaustive: hand-audit converges on nothing, a byte-diff cannot miss.
//
// Wiring (all loopback, all spawned+torn-down here):
//   parity-fake-backend.py  :FAKE   answers /v1/models (frontends go "connected") + records the
//                                    forwarded prompt at /v1/completions -> GET /captured
//   node server.js          :OLD    the REAL old ST server on a scratch data dir; serves public/ AND
//                                    is the backend both frontends read their card/settings/history from
//   devserve.py (proxy)     :NEW    serves the new client's dist/, proxies /api -> :OLD
// Both frontends read identical real data from :OLD and POST their assembled prompt through :OLD to
// :FAKE, which records it. No mock, no alignment problem: one fixture, two builders.
//
// Usage: node parity-diff.mjs [--data DIR] [--repo DIR] [--probe old|new] [--keep] [--only ID]

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, mkdirSync, readdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32 } from 'node:zlib';

// Old server + presets run from the main worktree (only it has root node_modules); public/ + server.js
// are identical at the shared HEAD. NEW_DIST alone comes from THIS worktree - the client build under test.
const CLIENT = dirname(fileURLToPath(import.meta.url));
const REPO = dirname(CLIENT);
const NEW_DIST = join(CLIENT, 'dist');
// Worker-offset at main() start: worker w -> base + w*10, disjoint ports + data dir per worker so N
// rigs run in parallel as separate processes. worker 0 keeps the historical 8123/8124/8125.
let PORTS = { OLD: 8123, NEW: 8124, FAKE: 8125 };
const NIX = ['develop', REPO, '-c', 'bash', '-lc'];

// --formats: rotate instruct+context preset per seed (seed i -> INSTRUCT_PRESETS[i % N] + same-named
// context if it exists) to MEASURE the non-ChatML gap. ROTATE_FORMATS set in runFuzz.
const INSTRUCT_DIR = join(REPO, 'default', 'content', 'presets', 'instruct');
const CONTEXT_DIR = join(REPO, 'default', 'content', 'presets', 'context');
const INSTRUCT_PRESETS = readdirSync(INSTRUCT_DIR).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort();
let ROTATE_FORMATS = false;
function loadPreset(dir, name) { const p = join(dir, `${name}.json`); return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null; }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
    const out = {
        data: null, repo: REPO, probe: null, keep: false, only: null, timed: false, chunk4: false,
        fuzz: false, worker: 0, seed: 1, count: 24, handcards: false,
        trim: false, ctx: 1024, amt: 256, sends: 16, pad: null,
        measurepick: false, mesraw: false, formats: false,
    };
    for (let i = 0; i < argv.length; i += 2) {
        const k = argv[i], v = argv[i + 1];
        if (k === '--data') out.data = v;
        else if (k === '--repo') out.repo = v;
        else if (k === '--probe') out.probe = v;
        else if (k === '--only') out.only = v;
        else if (k === '--worker') out.worker = Number(v);
        else if (k === '--seed') out.seed = Number(v);
        else if (k === '--count') out.count = Number(v);
        else if (k === '--ctx') out.ctx = Number(v);
        else if (k === '--amt') out.amt = Number(v);
        else if (k === '--sends') out.sends = Number(v);
        else if (k === '--pad') out.pad = Number(v);
        else if (k === '--keep') { out.keep = true; i -= 1; }
        else if (k === '--timed') { out.timed = true; i -= 1; }
        else if (k === '--chunk4') { out.chunk4 = true; i -= 1; }
        else if (k === '--fuzz') { out.fuzz = true; i -= 1; }
        else if (k === '--trim') { out.trim = true; i -= 1; }
        else if (k === '--handcards') { out.handcards = true; i -= 1; }
        else if (k === '--measurepick') { out.measurepick = true; i -= 1; }
        else if (k === '--mesraw') { out.mesraw = true; i -= 1; }
        else if (k === '--formats') { out.formats = true; i -= 1; }
        else if (k === '--selfcheck') { out.selfcheck = true; i -= 1; }
        else if (k === '--describe') { out.describe = true; i -= 1; }
        else if (k === '--audit') { out.audit = true; i -= 1; }
        else if (k === '--update-golden') { out.updateGolden = true; i -= 1; }
        else if (k === '--macros') { out.macros = true; i -= 1; }
        else throw new Error(`unknown arg: ${k}`);
    }
    if (!out.data) out.data = join(tmpdir(), 'parity-data');
    if (Number.isNaN(out.worker) || Number.isNaN(out.seed) || Number.isNaN(out.count)) throw new Error('worker/seed/count must be numbers');
    return out;
}

// ---- CDP primitives (same model as interactions.mjs / render.mjs) --------------------------------
class CDP {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.pending = new Map(); this.onEvent = null;
        ws.addEventListener('message', (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.id === undefined) { if (this.onEvent) this.onEvent(msg); return; }
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
            else p.resolve(msg.result);
        });
        const failAll = (reason) => { for (const [, p] of this.pending) p.reject(new Error(reason)); this.pending.clear(); };
        ws.addEventListener('close', () => failAll('cdp socket closed'));
        ws.addEventListener('error', () => failAll('cdp socket error'));
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id;
        const frame = { id, method, params };
        if (sessionId) frame.sessionId = sessionId;
        return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject, method }); this.ws.send(JSON.stringify(frame)); });
    }
}

class Page {
    constructor(cdp, sessionId, consoleLines) { this.cdp = cdp; this.sessionId = sessionId; this.consoleLines = consoleLines; }
    async eval(expr) {
        const r = await this.cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, this.sessionId);
        if (r.exceptionDetails) throw new Error(`eval threw: ${r.exceptionDetails.text}`);
        return r.result ? r.result.value : undefined;
    }
    async waitFor(expr, ms = 8000, poll = 100) {
        const guarded = `(function(){try{return !!(${expr})}catch(_){return false}})()`;
        const deadline = Date.now() + ms;
        for (;;) { if (await this.eval(guarded)) return true; if (Date.now() >= deadline) return false; await sleep(poll); }
    }
    async navigate(url) { this.consoleLines.length = 0; await this.cdp.send('Page.navigate', { url }, this.sessionId); }
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
        if (box.x < 0) throw new Error(`not visible: ${selector}`);
        return box;
    }
    async click(selector) {
        const { x, y } = await this.center(selector);
        const base = { x, y, button: 'left', clickCount: 1, pointerType: 'mouse' };
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base }, this.sessionId);
        await this.cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base }, this.sessionId);
    }
    async focus(selector) { await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`); }
    async insertText(text) { await this.cdp.send('Input.insertText', { text }, this.sessionId); }
    // Synthetic .click(): fine for an element with a DIRECT handler (old ST #send_but), no viewport
    // visibility needed. NOT for the new client's ziex body-delegate, which needs real mouse events.
    async jsClick(selector) { await this.eval(`document.querySelector(${JSON.stringify(selector)}).click()`); }
}

function launchChrome(profile) {
    const child = spawn('google-chrome-stable', [
        // old --headless + --ozone-platform=headless: no Wayland surface on the operator's niri desktop.
        '--headless', '--ozone-platform=headless', '--disable-gpu', '--no-sandbox', '--window-size=1400,1600',
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
    child.on('error', (err) => { child.spawnError = err; });
    return child;
}
async function readDebugPort(profile, child, deadline) {
    const portFile = join(profile, 'DevToolsActivePort');
    while (Date.now() < deadline) {
        if (child.spawnError) throw new Error(`chrome spawn: ${child.spawnError.message}`);
        if (child.exitCode !== null) throw new Error(`chrome exited early ${child.exitCode}`);
        if (existsSync(portFile)) { const l = readFileSync(portFile, 'utf8').split('\n')[0].trim(); if (l) return l; }
        await sleep(50);
    }
    throw new Error('chrome never wrote DevToolsActivePort');
}
async function openWs(url) {
    return await new Promise((resolve, reject) => {
        const ws = new WebSocket(url);
        ws.addEventListener('open', () => resolve(ws), { once: true });
        ws.addEventListener('error', () => reject(new Error('cdp ws error')), { once: true });
    });
}

// ---- service orchestration -----------------------------------------------------------------------
const children = [];
// Dependency lifetime: a backstop for a SIGKILLed harness, not a budget, so it must outlast the run. At
// its old 1200s the services died ~20 min in and every later seed failed "old: never connected".
const DEP_TTL = Number(process.env.PARITY_DEP_TTL || 21600);
function spawnSvc(name, shellCmd) {
    // detached -> nix leads its own group so teardown's `kill -child.pid` reaps the tree; NO setsid
    // (it would orphan into a new group). `timeout` backstops a SIGKILL of this harness before teardown.
    const child = spawn('nix', [...NIX, `timeout ${DEP_TTL} ${shellCmd}`], { cwd: REPO, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.svcName = name; child.out = '';
    child.stdout.on('data', (d) => { child.out += d; });
    child.stderr.on('data', (d) => { child.out += d; });
    children.push(child);
    return child;
}
async function waitHttp(url, ms, expectOk = true) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
        try {
            const r = await fetch(url);
            if (!expectOk || r.ok) return true;
        } catch (_) { /* not up yet */ }
        await sleep(400);
    }
    return false;
}
function teardown() {
    for (const c of children) { try { if (c.pid) process.kill(-c.pid, 'SIGKILL'); } catch (_) { /* gone */ } }
}

/// Which of the three services stopped answering. A dead dependency otherwise surfaces as a drive error
/// blaming the wrong process, which is how a 20-minute service cap read as 18 parity failures.
async function deadServices() {
    const probes = [['fake-backend', `http://127.0.0.1:${PORTS.FAKE}/captured`], ['old-st', `http://127.0.0.1:${PORTS.OLD}/`], ['devserve', `http://127.0.0.1:${PORTS.NEW}/`]];
    const down = [];
    for (const [name, url] of probes) {
        try {
            const c = new AbortController();
            const t = setTimeout(() => c.abort(), 4000);
            await fetch(url, { signal: c.signal });
            clearTimeout(t);
        } catch (_) { down.push(name); }
    }
    return down;
}

async function fakeCaptured() { return await (await fetch(`http://127.0.0.1:${PORTS.FAKE}/captured`)).json(); }
async function fakeClear() { await fetch(`http://127.0.0.1:${PORTS.FAKE}/clear`); }
function svcLogTail(name, n = 1400) { const c = children.find((x) => x.svcName === name); return c ? c.out.slice(-n) : '(no svc)'; }

// Both frontends persist their send into the shared chat file. Wipe it before EACH drive so old and
// new start from IDENTICAL (greeting-only) history; otherwise the second drive reads the first's turns.
let argsData = null;
// fileKey = the card FILE stem (default_Seraphina), which is how ST names the chat dir + backups -
// NOT the display name. Reset by the file key or the wipe silently misses and history accumulates.
async function resetChat(fileKey) {
    const { rmSync, readdirSync, existsSync } = await import('node:fs');
    const user = join(argsData, 'default-user');
    let removed = 0;
    for (const dir of ['chats', 'group chats']) {
        const p = join(user, dir, fileKey);
        if (existsSync(p)) { rmSync(p, { recursive: true, force: true }); removed++; }
    }
    const backups = join(user, 'backups');
    const key = fileKey.toLowerCase();
    if (existsSync(backups)) {
        for (const f of readdirSync(backups)) {
            if (f.toLowerCase().includes(key)) { try { rmSync(join(backups, f), { force: true }); } catch (_) { /* */ } }
        }
    }
    const still = existsSync(join(user, 'chats', fileKey));
    process.stderr.write(`[reset] ${fileKey}: removed ${removed} dir(s), ${still ? 'STILL EXISTS' : 'gone'}\n`);
}

// ---- boot the whole rig --------------------------------------------------------------------------
async function bootRig(args) {
    const cfg = join(args.data, 'parity-config.yaml');
    mkdirSync(args.data, { recursive: true });
    // config: loopback, debug logs, no browser launch, whitelist loopback
    const yaml = [
        `dataRoot: ./data`, `listen: false`, `port: ${PORTS.OLD}`, `whitelistMode: true`,
        `whitelist:`, `  - 127.0.0.1`, `  - ::1`, `browserLaunch:`, `  enabled: false`,
        `logging:`, `  minLogLevel: 0`, `securityOverride: true`, `basicAuthMode: false`,
        `enableUserAccounts: false`, `skipContentCheck: true`,
    ].join('\n');
    const { writeFileSync } = await import('node:fs');
    writeFileSync(cfg, yaml);

    // Cold-boot bootstrap: the run config's skipContentCheck also skips the content SEED, so bootstrap
    // boots content-check-ENABLED + waits for the seeded FILES (HTTP 200 races the seed), then kills.
    const seededCard = join(args.data, 'default-user', 'characters', 'default_Seraphina.png');
    if (!existsSync(join(args.data, 'default-user', 'settings.json')) || !existsSync(seededCard)) {
        process.stderr.write('[rig] phase-A: cold-boot bootstrap (content seed: settings.json + card + worlds)\n');
        const bootCfg = join(args.data, 'parity-bootstrap.yaml');
        writeFileSync(bootCfg, yaml.split('\n').filter((l) => !l.includes('skipContentCheck')).join('\n'));
        const a = spawnSvc('phaseA', `node server.js --port ${PORTS.OLD} --dataRoot '${args.data}' --configPath '${bootCfg}'`);
        const bootDeadline = Date.now() + 120000;
        let seeded = false;
        while (Date.now() < bootDeadline) {
            if (existsSync(join(args.data, 'default-user', 'settings.json')) && existsSync(seededCard)) { seeded = true; break; }
            if (a.exitCode !== null) break;
            await sleep(500);
        }
        try { process.kill(-a.pid, 'SIGKILL'); } catch (_) { /* */ }
        children.splice(children.indexOf(a), 1);
        await sleep(1000);
        if (!seeded) { process.stderr.write(a.out.slice(-2000)); throw new Error('phase-A bootstrap never seeded settings.json + card'); }
    }

    // seed the fixture (idempotent)
    process.stderr.write('[rig] seeding fixture\n');
    await new Promise((res, rej) => {
        const s = spawn('nix', [...NIX, `python3 client/parity-seed.py --data '${args.data}' --repo '${args.repo}' --fake-url http://127.0.0.1:${PORTS.FAKE}`], { cwd: REPO, stdio: ['ignore', 'inherit', 'inherit'] });
        s.on('exit', (c) => (c === 0 ? res() : rej(new Error(`seed exit ${c}`))));
    });

    // battery variant cards (distinct names) from the stock card
    process.stderr.write('[rig] generating battery variant cards\n');
    await new Promise((res, rej) => {
        const c = spawn('nix', [...NIX, `python3 client/parity-cards.py --base '${join(args.data, 'default-user', 'characters', 'default_Seraphina.png')}' --out-dir '${join(args.data, 'default-user', 'characters')}'`], { cwd: REPO, stdio: ['ignore', 'inherit', 'inherit'] });
        c.on('exit', (code) => (code === 0 ? res() : rej(new Error(`parity-cards exit ${code}`))));
    });

    // Phase B + fake + devserve
    process.stderr.write('[rig] booting fake backend\n');
    spawnSvc('fake', `python3 client/parity-fake-backend.py --port ${PORTS.FAKE}`);
    if (!await waitHttp(`http://127.0.0.1:${PORTS.FAKE}/v1/models`, 10000)) throw new Error('fake never listened');

    process.stderr.write('[rig] booting old ST server\n');
    const srv = spawnSvc('old', `node server.js --port ${PORTS.OLD} --dataRoot '${args.data}' --configPath '${cfg}'`);
    if (!await waitHttp(`http://127.0.0.1:${PORTS.OLD}/`, 90000)) { process.stderr.write(srv.out.slice(-2000)); throw new Error('old server never listened'); }

    process.stderr.write('[rig] booting devserve proxy (new client)\n');
    spawnSvc('new', `python3 client/devserve.py --port ${PORTS.NEW} --dist '${NEW_DIST}' --backend http://127.0.0.1:${PORTS.OLD}`);
    if (!await waitHttp(`http://127.0.0.1:${PORTS.NEW}/`, 15000)) throw new Error('devserve never listened');
    process.stderr.write('[rig] all services up\n');
}

// ---- one chrome, a page per drive ----------------------------------------------------------------
async function newPage() {
    const profile = mkdtempSync(join(tmpdir(), 'parity-chrome-'));
    const child = launchChrome(profile);
    const port = await readDebugPort(profile, child, Date.now() + 15000);
    const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const ws = await openWs(ver.webSocketDebuggerUrl);
    const cdp = new CDP(ws);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Runtime.enable', {}, sessionId);
    const consoleLines = [];
    cdp.onEvent = (m) => {
        if (m.method === 'Runtime.consoleAPICalled' && (m.sessionId === sessionId || m.params?.sessionId === sessionId)) {
            consoleLines.push((m.params.args || []).map((a) => a.value ?? a.description ?? '').join(' '));
        }
    };
    const page = new Page(cdp, sessionId, consoleLines);
    return { page, child, profile };
}

// ---- probe: dump enough to nail selectors --------------------------------------------------------
async function probe(which) {
    const url = which === 'new' ? `http://127.0.0.1:${PORTS.NEW}/?showtabs=1` : `http://127.0.0.1:${PORTS.OLD}/`;
    const { page, child } = await newPage();
    await page.navigate(url);
    await sleep(6000);
    if (which === 'new') {
        try { await openCastCharacters(page); } catch (e) { process.stdout.write(`cast open err: ${e.message}\n`); }
        const drawerInfo = await page.eval(`JSON.stringify({
            castDock: !!document.querySelector('#panel-view.panel-right'),
            charItems: document.querySelectorAll('#chat-root .char-item').length,
            charNames: [...document.querySelectorAll('#chat-root .char-item .char-name')].map(n=>n.textContent.trim()).slice(0,6),
            homeResume: !!document.querySelector('#home-resume'),
            chatRootHead: (document.querySelector('#chat-root')||{}).textContent ? document.querySelector('#chat-root').textContent.slice(0,180).replace(/\\s+/g,' ') : null,
        })`);
        process.stdout.write(`\n=== PROBE new drawer ===\n${drawerInfo}\n`);
    }
    const info = await page.eval(`(function(){
        const q = (s) => !!document.querySelector(s);
        return JSON.stringify({
            title: document.title,
            sendTextarea: q('#send_textarea'),
            sendBut: q('#send_but'),
            composerSend: q('#composer button[aria-label="Send"]'),
            statusText: (document.querySelector('.online_status_text')||{}).textContent||null,
            sendStatus: (document.querySelector('#send-status')||{}).textContent||null,
            charItems: document.querySelectorAll('.character_select, #chat-root .char-item').length,
            firstRun: q('#user-settings-block .welcomePanel') || q('.welcome') || document.body.textContent.includes('Welcome to SillyTavern'),
            bodyHead: document.body.textContent.slice(0,200).replace(/\\s+/g,' '),
        });
    })()`);
    process.stdout.write(`\n=== PROBE ${which} (${url}) ===\n${info}\n`);
    process.stdout.write(`console(${page.consoleLines.length}): ${page.consoleLines.slice(0, 15).join(' | ')}\n`);
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ }
}

// ---- drive one send on each frontend, capture the assembled prompt from the fake ----------------
const MSG = 'Tell me what you see.';

async function captureFor(needle, ms = 12000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
        const cap = await fakeCaptured();
        const hit = cap.find((c) => typeof c.prompt === 'string' && c.prompt.includes(needle));
        if (hit) return hit;
        await sleep(250);
    }
    return null;
}

// Grab ANY captured prompt after a fakeClear: used only when the needle (current message) is legitimately
// absent because the overhead block alone exceeds budget and the builder trimmed even the current turn.
async function captureAny(ms = 5000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
        const cap = await fakeCaptured();
        const hit = cap.find((c) => typeof c.prompt === 'string');
        if (hit) return hit;
        await sleep(200);
    }
    return null;
}

async function driveOld(display) {
    const { page, child } = await newPage();
    try {
        await page.navigate(`http://127.0.0.1:${PORTS.OLD}/`);
        const connected = await page.waitFor(
            "document.querySelector('.online_status_text') && document.querySelector('.online_status_text').textContent.trim().length>0 && !/no.?connection|not connected/i.test(document.querySelector('.online_status_text').textContent)", 60000);
        if (!connected) throw new Error('old: never connected');
        const opened = await page.eval(`(function(){
            const items=[...document.querySelectorAll('.character_select')];
            const el=items.find(e=>{const n=e.querySelector('.ch_name');return n&&n.textContent.trim()===${JSON.stringify(display)};});
            if(!el) return false; el.click(); return true;
        })()`);
        if (!opened) throw new Error(`old: ${display} not in list`);
        if (!await page.waitFor("document.querySelectorAll('#chat .mes').length >= 1", 15000)) throw new Error('old: chat/greeting never loaded');
        // ONE send only: a re-send would persist a second user turn and pollute the prompt history.
        await sleep(500);
        await fakeClear();
        await page.focus('#send_textarea');
        await page.insertText(MSG);
        await page.jsClick('#send_but');
        const hit = await captureFor(MSG, 15000);
        if (!hit) {
            const diag = await page.eval("JSON.stringify({ta:document.querySelector('#send_textarea').value,mes:document.querySelectorAll('#chat .mes').length,status:(document.querySelector('.online_status_text')||{}).textContent,toast:(document.querySelector('.toast')||{}).textContent||null})");
            const cap = await fakeCaptured();
            throw new Error(`old: no prompt captured. diag=${diag}\nFAKE-CAPTURED(${cap.length})\nOLD-SERVER-LOG(tail):\n${svcLogTail('old', 2600)}`);
        }
        return hit;
    } finally { try { process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ } }
}

// The UI rework deleted the topbar, so #d-characters is gone; the Cast dock opens from an edge tab that
// ?showtabs=1 pins. Mirrors interactions.mjs openPanel: the click retries because the dock arrives on a slide.
const CAST_SECTION = '#panel-view.panel-right nav button[data-section="characters"]';
async function openCastCharacters(page) {
    if (!await page.waitFor("document.querySelector('#chat-root.hydrated')", 20000)) throw new Error('new: never hydrated');
    if (!await page.eval("!!document.querySelector('#panel-view.panel-right')")) {
        await page.click('#tab-cast');
        if (!await page.waitFor("document.querySelector('#panel-view.panel-right')", 8000)) throw new Error('new: cast dock never opened');
    }
    await page.waitFor("(function(){var e=document.querySelector('#panel-view.panel-right');return e && e.getBoundingClientRect().right < innerWidth + 1;})()", 4000);
    for (let attempt = 1; ; attempt++) {
        await page.click(CAST_SECTION);
        if (await page.waitFor(`document.querySelector('${CAST_SECTION}[aria-current="true"]')`, 4000)) break;
        if (attempt === 3) throw new Error('new: characters never became the current section');
    }
}

async function driveNew(display) {
    const { page, child } = await newPage();
    try {
        await page.navigate(`http://127.0.0.1:${PORTS.NEW}/?showtabs=1`);
        await openCastCharacters(page);
        if (!await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 1", 12000)) throw new Error('new: no char list');
        await page.focus('.char-search');
        await page.insertText(display);
        if (!await page.waitFor(`[...document.querySelectorAll('#chat-root .char-item .char-name')].some(n=>n.textContent.trim()===${JSON.stringify(display)})`, 5000)) throw new Error(`new: ${display} not filtered`);
        await page.eval(`(function(){
            const names=[...document.querySelectorAll('#chat-root .char-item .char-name')];
            const n=names.find(x=>x.textContent.trim()===${JSON.stringify(display)}); if(n) n.click();
        })()`);
        // Do NOT require a greeting message: whether the new client reconstructs first_mes on a fresh
        // (reset) chat is one of the diffs we are measuring, not a drive precondition. Sending works empty.
        if (!await page.waitFor("document.querySelector('#send_textarea') && document.querySelector('#composer button[aria-label=\"Send\"]')", 15000)) throw new Error('new: composer never ready');
        await page.waitFor("document.querySelector('#send-status') && /connected/i.test(document.querySelector('#send-status').textContent)", 15000);
        await sleep(500);
        await fakeClear();
        await page.focus('#send_textarea');
        await page.insertText(MSG);
        await page.click('#composer button[aria-label="Send"]');
        const hit = await captureFor(MSG, 15000);
        if (!hit) throw new Error(`new: no prompt captured. console: ${page.consoleLines.slice(-6).join(' | ')}`);
        return hit;
    } finally { try { process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ } }
}

// Normalize the random-macro card line: droll/seedrandom entropy means Dice/Coin differ every run.
function maskImpure(s) {
    return s.replace(/Dice: -?\d+\. Coin: [^.]*\./g, 'Dice: <N>. Coin: <W>.');
}

// line-level diff report (old vs new)
function diffReport(oldP, newP) {
    const a = oldP.split('\n'), b = newP.split('\n');
    if (oldP === newP) return { equal: true, bytes: oldP.length, text: '' };
    // longest-common-subsequence line diff (small inputs)
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
        dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const out = [];
    let i = 0, j = 0;
    while (i < n && j < m) {
        if (a[i] === b[j]) { out.push(`  ${a[i]}`); i++; j++; }
        else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push(`- ${a[i]}`); i++; }
        else { out.push(`+ ${b[j]}`); j++; }
    }
    while (i < n) out.push(`- ${a[i++]}`);
    while (j < m) out.push(`+ ${b[j++]}`);
    return { equal: false, bytes: { old: oldP.length, new: newP.length }, text: out.join('\n') };
}

// display = the card name shown in the list; fileKey = the card FILE stem (== chat dir name).
const BATTERY = [
    { display: 'Seraphina', fileKey: 'default_Seraphina', label: 'plain card, ChatML, sysprompt on (baseline)' },
    { display: 'ParityMacro', fileKey: 'ParityMacro', label: 'card-field macros: {{//comment}} {{roll}} {{random}} {{pick}} {{user}} {{char}}' },
    { display: 'ParitySysOverride', fileKey: 'ParitySysOverride', label: 'per-card system_prompt override + {{original}}' },
    { display: 'ParityJailbreak', fileKey: 'ParityJailbreak', label: 'post_history_instructions jailbreak + {{original}}' },
    { display: 'ParityDepth', fileKey: 'ParityDepth', label: 'character depth_prompt note (data.extensions.depth_prompt)' },
    { display: 'ParityGreeting', fileKey: 'ParityGreeting', label: 'greeting macros: {{user}} {{//comment}} {{persona}}' },
    { display: 'ParityCardFields', fileKey: 'ParityCardFields', label: 'card-field env macros: charPrompt/charInstruction/mesExamples/charDepthPrompt/greeting/charVersion + aliases' },
];

async function runBattery(args) {
    const { writeFileSync } = await import('node:fs');
    const results = [];
    for (const item of BATTERY) {
        if (args.only && item.display !== args.only) continue;
        process.stdout.write(`\n===== ${item.display}: ${item.label} =====\n`);
        let oldHit, newHit, error = null;
        try {
            await resetChat(item.fileKey);
            oldHit = await driveOld(item.display);
            await resetChat(item.fileKey);
            newHit = await driveNew(item.display);
        } catch (e) { error = e.message; }
        if (error) { process.stdout.write(`DRIVE ERROR: ${error}\n`); results.push({ item, error }); continue; }
        writeFileSync(join(args.data, `p-${item.display}-old.txt`), oldHit.prompt);
        writeFileSync(join(args.data, `p-${item.display}-new.txt`), newHit.prompt);
        // {{roll}}/{{random}} are genuinely random both sides; mask Dice+Coin. {{pick}} is deterministic
        // (cyrb53+seedrandom off the chat id) so it stays unmasked, byte-compared as the parity proof.
        const rep = diffReport(maskImpure(oldHit.prompt), maskImpure(newHit.prompt));
        if (rep.equal) { process.stdout.write(`RESULT: BYTE-IDENTICAL (${rep.bytes} bytes)\n`); results.push({ item, equal: true }); }
        else {
            process.stdout.write(`RESULT: DIVERGENT (old ${rep.bytes.old} bytes, new ${rep.bytes.new} bytes)\n--- old (public/)   +++ new (wasm)\n${rep.text}\n`);
            results.push({ item, equal: false });
        }
    }
    process.stdout.write(`\n===== SUMMARY =====\n`);
    for (const r of results) {
        const tag = r.error ? '[ERROR]' : r.equal ? '[MATCH]' : '[DIFF] ';
        process.stdout.write(`${tag} ${r.item.display}: ${r.item.label}${r.error ? ' - ' + r.error : ''}\n`);
    }
    process.stdout.write(`\n(per-item prompts at ${args.data}/p-<name>-{old,new}.txt)\n`);
}

// ---- multi-send timed-effect battery: sticky only manifests across sends, so drive N without reset -
const TIMED_WORLD = 'Eldoria';
const STICKY_KEY = 'zephyrion';
const STICKY_MARK = 'ZZ_STICKY_MARK_ZZ';
const TIMED_MSGS = [
    `the ${STICKY_KEY} glows over the glade tonight`, // send 1: keyword hit -> sticky window opens
    'tell me more about that please',                  // send 2: no keyword -> sticky must hold it
    'and what happened in the end',                    // send 3: no keyword -> sticky still holds
];

// Add a sticky entry to the scratch world (scanDepth 1: the keyword matches only while NEWEST, so by
// send 2 it is out of scan range and ONLY sticky can keep the entry active). Returns a restore fn.
async function seedTimed(data) {
    const { readFileSync, writeFileSync, existsSync, copyFileSync, rmSync } = await import('node:fs');
    const wf = join(data, 'default-user', 'worlds', `${TIMED_WORLD}.json`);
    if (!existsSync(wf)) throw new Error(`timed battery needs the ${TIMED_WORLD} world at ${wf}`);
    const bak = `${wf}.paritybak`;
    copyFileSync(wf, bak);
    const world = JSON.parse(readFileSync(wf, 'utf8'));
    world.entries['9100'] = {
        uid: 9100, key: [STICKY_KEY], keysecondary: [], comment: 'parity-sticky', content: STICKY_MARK,
        constant: false, selective: false, order: 100, position: 0, disable: false, addMemo: false,
        group: '', groupOverride: false, groupWeight: 100, sticky: 5, cooldown: 0, delay: 0,
        probability: 100, useProbability: false, depth: 4, role: 0, vectorized: false,
        excludeRecursion: false, preventRecursion: false, delayUntilRecursion: 0, scanDepth: 1,
        caseSensitive: false, matchWholeWords: false, useGroupScoring: false, automationId: '',
    };
    writeFileSync(wf, JSON.stringify(world, null, 4));
    return () => { copyFileSync(bak, wf); rmSync(bak); };
}

async function openFrontend(page, which, display) {
    if (which === 'old') {
        await page.navigate(`http://127.0.0.1:${PORTS.OLD}/`);
        if (!await page.waitFor("document.querySelector('.online_status_text') && document.querySelector('.online_status_text').textContent.trim().length>0 && !/no.?connection|not connected/i.test(document.querySelector('.online_status_text').textContent)", 60000)) throw new Error('old: never connected');
        const opened = await page.eval(`(function(){const items=[...document.querySelectorAll('.character_select')];const el=items.find(e=>{const n=e.querySelector('.ch_name');return n&&n.textContent.trim()===${JSON.stringify(display)};});if(!el) return false; el.click(); return true;})()`);
        if (!opened) throw new Error(`old: ${display} not in list`);
        if (!await page.waitFor("document.querySelectorAll('#chat .mes').length >= 1", 15000)) throw new Error('old: chat/greeting never loaded');
    } else {
        await page.navigate(`http://127.0.0.1:${PORTS.NEW}/?showtabs=1`);
        await openCastCharacters(page);
        if (!await page.waitFor("document.querySelectorAll('#chat-root .char-item').length >= 1", 12000)) throw new Error('new: no char list');
        await page.focus('.char-search');
        await page.insertText(display);
        if (!await page.waitFor(`[...document.querySelectorAll('#chat-root .char-item .char-name')].some(n=>n.textContent.trim()===${JSON.stringify(display)})`, 5000)) throw new Error(`new: ${display} not filtered`);
        await page.eval(`(function(){const names=[...document.querySelectorAll('#chat-root .char-item .char-name')];const n=names.find(x=>x.textContent.trim()===${JSON.stringify(display)}); if(n) n.click();})()`);
        if (!await page.waitFor("document.querySelector('#send_textarea') && document.querySelector('#composer button[aria-label=\"Send\"]')", 15000)) throw new Error('new: composer never ready');
        await page.waitFor("document.querySelector('#send-status') && /connected/i.test(document.querySelector('#send-status').textContent)", 15000);
    }
}

// Persisted MESSAGE lines (header excluded: only turns carry is_user). The new client re-fetches its
// window from the SERVER each send, so history is only right once the prior turns are on disk.
function chatMessageCount(fileKey) {
    const dir = join(argsData, 'default-user', 'chats', fileKey);
    if (!existsSync(dir)) return 0;
    let total = 0;
    for (const f of readdirSync(dir)) {
        if (!f.endsWith('.jsonl')) continue;
        const lines = readFileSync(join(dir, f), 'utf8').split('\n');
        for (const ln of lines) if (ln.includes('"is_user"')) total++;
    }
    return total;
}

// The new client only appends to an EXISTING chat file, so an audit that never runs the old frontend
// has to lay the header down itself. Same shape the old drive would have left behind.
function seedChatFile(fileKey, charName, userName, chatName, note) {
    const dir = join(argsData, 'default-user', 'chats', fileKey);
    mkdirSync(dir, { recursive: true });
    const existing = readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
    // The card's own `chat` field names the file the client opens; anything else and the client opens
    // a chat whose file is not there, then every append 404s.
    const file = chatName ? `${chatName}.jsonl` : (existing.length ? existing[0] : `${charName} - audit.jsonl`);
    // A real chat carries the author's note in its own metadata (the old frontend seeds it from the
    // default when it creates the chat), so a bare header would make the note look dropped.
    const metadata = note && note.default ? {
        note_prompt: note.default,
        note_interval: note.defaultInterval,
        note_position: note.defaultPosition,
        note_depth: note.defaultDepth,
        note_role: note.defaultRole,
    } : {};
    const header = {
        user_name: userName,
        character_name: charName,
        create_date: '2026-01-01@00h00m00s',
        chat_metadata: metadata,
    };
    writeFileSync(join(dir, file), JSON.stringify(header) + '\n');
}

// The new client only /appends to an EXISTING chat file (never creates one). The old drive creates it;
// this strips it to a clean header so the new drive reuses the SAME chat from the identical start.
function resetChatToHeader(fileKey) {
    const dir = join(argsData, 'default-user', 'chats', fileKey);
    if (!existsSync(dir)) throw new Error(`no chat file to reuse for the new drive at ${dir} (did the old drive persist?)`);
    for (const f of readdirSync(dir)) {
        if (!f.endsWith('.jsonl')) continue;
        const p = join(dir, f);
        const first = readFileSync(p, 'utf8').split('\n')[0];
        let header;
        try { header = JSON.parse(first); } catch { continue; }
        if (header.chat_metadata && typeof header.chat_metadata === 'object') delete header.chat_metadata.timedWorldInfo;
        writeFileSync(p, JSON.stringify(header) + '\n');
    }
}

// N sends on one frontend, no reset between; between sends it waits for both turns to persist (msg
// count += 2) so the next send's window fetch and in-memory timed state see the prior send.
async function driveMulti(which, display, messages, fileKey, tolerant = false) {
    const { page, child } = await newPage();
    const prompts = [];
    try {
        await openFrontend(page, which, display);
        await sleep(500);
        const sendSel = which === 'old' ? '#send_but' : '#composer button[aria-label="Send"]';
        for (const msg of messages) {
            const beforeMsgs = chatMessageCount(fileKey);
            await fakeClear();
            await page.focus('#send_textarea');
            await page.insertText(msg);
            if (which === 'old') await page.jsClick(sendSel); else await page.click(sendSel);
            let hit = await captureFor(msg, 15000);
            // Tolerant: needle absent = over-budget regime (current turn trimmed); capture what WAS sent so
            // story-only prompts still byte-diff. Give up only if no prompt was sent at all.
            if (!hit && tolerant) { hit = await captureAny(5000); if (hit) process.stderr.write(`[driveMulti ${which}] send ${prompts.length + 1}: needle absent (over-budget), captured story-only prompt\n`); }
            if (!hit) {
                const diag = await page.eval("JSON.stringify({ta:(document.querySelector('#send_textarea')||{}).value,mes:document.querySelectorAll('#chat .mes, #chat-root .mes').length,status:(document.querySelector('.online_status_text')||{}).textContent,sendStatus:(document.querySelector('#send-status')||{}).textContent,toast:(document.querySelector('.toast')||{}).textContent||null})").catch((e) => `diag-eval-failed: ${e.message}`);
                const logTail = which === 'old' ? `\nOLD-SERVER-LOG(tail):\n${svcLogTail('old', 2600)}` : '';
                const emsg = `${which}: no prompt for "${msg}". diag=${diag} console: ${page.consoleLines.slice(-8).join(' | ')}${logTail}`;
                if (tolerant) { process.stderr.write(`[driveMulti ${which}] STOPPING at send ${prompts.length + 1}: ${emsg}\n`); break; }
                throw new Error(emsg);
            }
            prompts.push(hit); // full {prompt, stop} hit; callers read .prompt / .stop
            const target = beforeMsgs + 2;
            const deadline = Date.now() + 60000;
            while (chatMessageCount(fileKey) < target && Date.now() < deadline) await sleep(300);
            if (chatMessageCount(fileKey) < target) {
                const emsg = `${which}: "${msg}" never persisted (msgs=${chatMessageCount(fileKey)}/${target})`;
                if (tolerant) { process.stderr.write(`[driveMulti ${which}] STOPPING at send ${prompts.length}: ${emsg}\n`); break; }
                throw new Error(emsg);
            }
            await sleep(400);
        }
        return prompts;
    } finally { try { process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ } }
}

async function runTimedBattery(args) {
    const { writeFileSync } = await import('node:fs');
    const restore = await seedTimed(args.data);
    try {
        process.stdout.write(`\n===== TIMED (sticky) multi-send: Seraphina + ${TIMED_WORLD} sticky entry =====\n`);
        await resetChat('default_Seraphina');
        const oldP = await driveMulti('old', 'Seraphina', TIMED_MSGS, 'default_Seraphina');
        // Keep the file old created (new can't make one) but strip it back to a clean header.
        resetChatToHeader('default_Seraphina');
        const newP = await driveMulti('new', 'Seraphina', TIMED_MSGS, 'default_Seraphina');
        let allEqual = true;
        for (let k = 0; k < TIMED_MSGS.length; k++) {
            writeFileSync(join(args.data, `p-timed${k + 1}-old.txt`), oldP[k]?.prompt ?? '');
            writeFileSync(join(args.data, `p-timed${k + 1}-new.txt`), newP[k]?.prompt ?? '');
            const rep = diffReport(oldP[k]?.prompt ?? '', newP[k]?.prompt ?? '');
            if (rep.equal) process.stdout.write(`  send ${k + 1}: BYTE-IDENTICAL (${rep.bytes} bytes)\n`);
            else { allEqual = false; process.stdout.write(`  send ${k + 1}: DIVERGENT (old ${rep.bytes.old}, new ${rep.bytes.new})\n--- old (public/)   +++ new (wasm)\n${rep.text}\n`); }
        }
        // Non-vacuous only if the reference (old) kept the mark on send 2, whose message has no
        // keyword: that proves the sticky window held. A byte-identical new then held it too.
        const held = (oldP[1]?.prompt ?? '').includes(STICKY_MARK);
        process.stdout.write(`  oracle validity (old kept sticky mark on send 2 sans keyword): ${held}\n`);
        process.stdout.write(`\n===== TIMED RESULT: ${allEqual ? 'ALL SENDS BYTE-IDENTICAL' : 'DIVERGENCE'}${held ? '' : ' (WARNING: sticky not exercised, oracle vacuous)'} =====\n`);
    } finally { restore(); }
}

// ---- chunk-4 battery: one entry per feature (decorator force/suppress, characterFilter in/out,
// matchScenario scan) seeded into Eldoria, then a Seraphina send byte-diffed old vs new. ----------
// Extension-stripped, as stock getCharaFilename returns and characterFilter.names stores.
const SERAPHINA_AVATAR = 'default_Seraphina';
function chunk4Entries() {
    const base = (uid, extra) => Object.assign({
        uid, key: [], keysecondary: [], comment: `a4-${uid}`, content: '', constant: false, selective: false,
        order: 100 - uid % 100, position: 0, disable: false, addMemo: false, group: '', groupOverride: false,
        groupWeight: 100, sticky: 0, cooldown: 0, delay: 0, probability: 100, useProbability: false, depth: 4,
        role: 0, vectorized: false, excludeRecursion: false, preventRecursion: false, delayUntilRecursion: 0,
        scanDepth: null, caseSensitive: false, matchWholeWords: false, useGroupScoring: false, automationId: '',
        characterFilter: null, triggers: [], matchPersonaDescription: false, matchCharacterDescription: false,
        matchCharacterPersonality: false, matchCharacterDepthPrompt: false, matchScenario: false, matchCreatorNotes: false,
    }, extra);
    return {
        9200: base(9200, { key: ['zzznomatchword'], content: '@@activate\nDECOR_MARK_A4' }),
        9201: base(9201, { constant: true, content: '@@dont_activate\nDONT_MARK_A4' }),
        9202: base(9202, { constant: true, content: 'CHARIN_MARK_A4', characterFilter: { isExclude: false, names: [SERAPHINA_AVATAR], tags: [] } }),
        9203: base(9203, { constant: true, content: 'CHAROUT_MARK_A4', characterFilter: { isExclude: false, names: ['nobody-else'], tags: [] } }),
        9204: base(9204, { key: ['beasts'], content: 'SCAN_MARK_A4', matchScenario: true }),
    };
}

async function seedChunk4(data) {
    const { copyFileSync, rmSync } = await import('node:fs');
    const wf = join(data, 'default-user', 'worlds', `${TIMED_WORLD}.json`);
    if (!existsSync(wf)) throw new Error(`chunk-4 battery needs the ${TIMED_WORLD} world at ${wf}`);
    const bak = `${wf}.chunk4bak`;
    copyFileSync(wf, bak);
    const world = JSON.parse(readFileSync(wf, 'utf8'));
    Object.assign(world.entries, chunk4Entries());
    writeFileSync(wf, JSON.stringify(world, null, 4));
    return () => { copyFileSync(bak, wf); rmSync(bak); };
}

async function runChunk4Battery(args) {
    const { writeFileSync: wf } = await import('node:fs');
    const restore = await seedChunk4(args.data);
    try {
        process.stdout.write(`\n===== CHUNK-4 (characterFilter, decorators, extended scan): Seraphina =====\n`);
        await resetChat('default_Seraphina');
        const oldHit = await driveOld('Seraphina');
        await resetChat('default_Seraphina');
        const newHit = await driveNew('Seraphina');
        wf(join(args.data, 'p-chunk4-old.txt'), oldHit.prompt);
        wf(join(args.data, 'p-chunk4-new.txt'), newHit.prompt);
        const rep = diffReport(oldHit.prompt, newHit.prompt);
        // Oracle validity: the fixture is only meaningful if the expected marks actually landed in old.
        const present = ['DECOR_MARK_A4', 'CHARIN_MARK_A4', 'SCAN_MARK_A4'].filter((m) => oldHit.prompt.includes(m));
        const absent = ['DONT_MARK_A4', 'CHAROUT_MARK_A4'].filter((m) => !oldHit.prompt.includes(m));
        process.stdout.write(`  oracle validity (old): forced/matched present ${present.length}/3, suppressed absent ${absent.length}/2\n`);
        if (rep.equal) process.stdout.write(`  RESULT: BYTE-IDENTICAL (${rep.bytes} bytes)\n`);
        else process.stdout.write(`  RESULT: DIVERGENT (old ${rep.bytes.old}, new ${rep.bytes.new})\n--- old (public/)   +++ new (wasm)\n${rep.text}\n`);
    } finally { restore(); }
}

// FUZZER: seeded-PRNG generator -> one randomized state applied to BOTH frontends -> byte-diff of
// prompt + stop array (impure masked), each divergence logged with its seed and grouped by feature.

// mulberry32: tiny deterministic PRNG. Same seed -> same state -> reproducible divergence.
function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
        a |= 0; a = (a + 0x6D2B79F5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

// ---- PNG chara-chunk card writer (JS port of parity-cards.py: no per-seed python spawn) -----------
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
function readPngChunks(buf) {
    if (!buf.subarray(0, 8).equals(PNG_SIG)) throw new Error('not a PNG');
    const chunks = [];
    let i = 8;
    while (i < buf.length) {
        const len = buf.readUInt32BE(i);
        const type = buf.subarray(i + 4, i + 8).toString('latin1');
        const data = buf.subarray(i + 8, i + 8 + len);
        chunks.push({ type, data });
        i += 8 + len + 4;
    }
    return chunks;
}
function writePng(chunks) {
    const parts = [PNG_SIG];
    for (const { type, data } of chunks) {
        const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
        const typeBuf = Buffer.from(type, 'latin1');
        const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])) >>> 0, 0);
        parts.push(len, typeBuf, data, crc);
    }
    return Buffer.concat(parts);
}
function charaChunkKeyword(chunk) {
    if (chunk.type !== 'tEXt') return null;
    const z = chunk.data.indexOf(0);
    return chunk.data.subarray(0, z).toString('latin1').toLowerCase();
}
function loadCardJson(basePng) {
    for (const c of readPngChunks(basePng)) {
        const kw = charaChunkKeyword(c);
        if (kw === 'chara' || kw === 'ccv3') {
            const z = c.data.indexOf(0);
            return JSON.parse(Buffer.from(c.data.subarray(z + 1).toString('latin1'), 'base64').toString('utf8'));
        }
    }
    throw new Error('no chara chunk in base card');
}
function makeCardPng(basePng, cardObj) {
    const kept = readPngChunks(basePng).filter((c) => { const kw = charaChunkKeyword(c); return kw !== 'chara' && kw !== 'ccv3'; });
    const b64 = Buffer.from(JSON.stringify(cardObj), 'utf8').toString('base64');
    const chara = { type: 'tEXt', data: Buffer.concat([Buffer.from('chara', 'latin1'), Buffer.from([0]), Buffer.from(b64, 'latin1')]) };
    kept.splice(kept.length - 1, 0, chara); // before IEND
    return writePng(kept);
}

// Retries per seed before a drive failure is scored. 18 of 74 seeds failed as "old: never connected"
// during one loaded run, none of them real.
const DRIVE_ATTEMPTS = 3;
// Every macro the old frontend registers, by tier. The probe block below puts them in a card field so
// the audit's unresolved-macro check names the ones we do not implement, one line per macro.
const MACRO_PROBE_TIERS = {
    chat: ['lastMessage', 'lastMessageId', 'lastUserMessage', 'lastCharMessage', 'firstIncludedMessageId', 'firstDisplayedMessageId', 'lastSwipeId', 'currentSwipeId', 'allChatRange'],
    core: ['trim', 'input', 'maxPrompt', 'maxContext', 'maxResponse', 'banned::x', 'if::a::b::c', 'else::d'],
    env: ['group', 'groupNotMuted', 'notChar', 'model', 'isMobile'],
    instruct: ['systemPrompt'],
    state: ['lastGenerationType', 'hasExtension::none'],
    time: ['time', 'date', 'weekday', 'isotime', 'isodate', 'datetimeformat::MM-DD', 'idleDuration', 'timeDiff::now::now'],
    variable: ['getvar::v', 'hasvar::v', 'getglobalvar::g', 'hasglobalvar::g'],
};

/// Set by --macros. Off by default so the differential run stays comparable: several of these resolve
/// to a clock or to chat state and would differ between two drives seconds apart.
let MACRO_PROBE = false;

/// One line per macro, each tagged so an unresolved one is identifiable by name in the finding.
function macroProbeBlock() {
    const lines = [];
    for (const [tier, names] of Object.entries(MACRO_PROBE_TIERS)) {
        for (const name of names) lines.push(`M[${tier}:${name.split('::')[0]}]={{${name}}}`);
    }
    return lines.join('\n');
}

const FUZZ_CARD = 'ParityFuzz';
const FUZZ_WORLD = 'ParityFuzz';

// Impure-macro wrappers the generator embeds so their resolved-different values mask to equal. {{pick}}
// stays UNwrapped: it is deterministic off the (shared) chat id, so it is a parity signal, not noise.
function maskFuzz(s) {
    return maskImpure(s)
        .replace(/\[\[roll:[^\]]*\]\]/g, '[[roll:<N>]]')
        .replace(/\[\[rnd:[^\]]*\]\]/g, '[[rnd:<W>]]');
}

// ---- generator: seed -> a coherent randomized state across every in-scope axis --------------------
function genState(seed, basePng, baseSettings) {
    const rng = mulberry32(seed);
    const pick = (arr) => arr[Math.floor(rng() * arr.length)];
    const chance = (p) => rng() < p;
    const rint = (lo, hi) => lo + Math.floor(rng() * (hi - lo + 1));
    // Axes added after the first baseline draw from a SECOND stream: taking them from `rng` would shift
    // every later draw and silently re-roll every existing scenario, so a seed would stop being comparable.
    const rng2 = mulberry32(seed ^ 0x9e3779b9);
    const pick2 = (arr) => arr[Math.floor(rng2() * arr.length)];
    const chance2 = (p) => rng2() < p;
    const rint2 = (lo, hi) => lo + Math.floor(rng2() * (hi - lo + 1));
    const markers = {};
    const axes = [];
    const mark = (feat) => { const t = `Z${feat.toUpperCase().replace(/[^A-Z]/g, '')}_${seed}Z`; markers[t] = feat; if (!axes.includes(feat)) axes.push(feat); return t; };
    // deterministic format coverage: seed maps to one shipped instruct preset (rotation on --formats).
    const format = ROTATE_FORMATS ? INSTRUCT_PRESETS[seed % INSTRUCT_PRESETS.length] : null;
    if (format) axes.push(`fmt:${format}`);
    // Impure + pure macro salad, appended to a field to exercise macro parity inside fields. {{pick}}
    // leads so only static text precedes it: stock seeds pick on the match offset AFTER earlier macros
    // expand, so a pick placed after {{roll}}/{{random}} inherits their impure length and is itself impure.
    // Deterministic tail exercises the pure/legacy macros (angle tags, space, noop, reverse). They
    // resolve identically both sides, so they stay UNwrapped and byte-compared as a parity signal.
    const detMacros = ` <USER>|<BOT>|<CHAR> sp[{{space::3}}] {{noop}}nn rv[{{reverse::Lana}}]`;
    const macroSalad = () => chance(0.5) ? ` {{pick::one,two,three}} {{user}}/{{char}} [[roll:{{roll:d20}}]] [[rnd:{{random::alpha,beta,gamma}}]] {{//c}}${detMacros}` : '';

    // --- card (all fields) ---
    const card = loadCardJson(basePng);
    card.name = FUZZ_CARD;
    card.data = card.data || {};
    card.data.name = FUZZ_CARD;
    card.data.description = `${mark('card-description')} a warded glade of beasts and old magic.${macroSalad()}`;
    card.data.personality = `${mark('card-personality')} calm, watchful, precise`;
    card.data.scenario = `${mark('card-scenario')} dusk over the glade`;
    card.data.first_mes = `${mark('card-greeting')} Hello {{user}}, I am {{char}}.${macroSalad()}`; // never empty (old needs a greeting)
    card.data.creator_notes = `${mark('card-creatornotes')} fuzz notes`;
    // The macro probe rides the DESCRIPTION: every shipped context template has a {{description}} slot,
    // so the block reaches the prompt whichever template the seed picked.
    if (MACRO_PROBE) { card.data.description += `\n${macroProbeBlock()}`; axes.push('macro-probe'); }
    card.data.mes_example = chance(0.5) ? `<START>\n{{user}}: ${mark('card-example')} hi\n{{char}}: hello there\n` : '';
    if (chance(0.5)) card.data.system_prompt = `${mark('card-system')} CARD SYS {{original}}`; else card.data.system_prompt = '';
    if (chance(0.5)) card.data.post_history_instructions = `${mark('card-jailbreak')} JB {{original}}`; else card.data.post_history_instructions = '';
    card.data.extensions = card.data.extensions || {};
    if (chance(0.5)) card.data.extensions.depth_prompt = { prompt: `${mark('card-depthprompt')} lamp flickers`, depth: rint(0, 4), role: pick(['system', 'user', 'assistant']) };
    else delete card.data.extensions.depth_prompt;
    delete card.data.character_book; delete card.character_book; // WI comes via a linked world below

    // --- world info (linked world; every audited field per entry) ---
    let world = null;
    if (chance(0.6)) {
        const wiMark = mark('world-info');
        const entries = {};
        const n = rint(1, 3);
        for (let k = 0; k < n; k++) {
            const uid = 9300 + k;
            const keyed = chance(0.5);
            entries[uid] = {
                uid, key: keyed ? [pick(['glade', 'beasts', 'magic'])] : [], keysecondary: chance(0.3) ? ['dusk'] : [],
                comment: `fz-${uid}`, content: `${wiMark}-${uid} lore entry ${uid}`, constant: !keyed,
                selective: chance(0.3), selectiveLogic: pick([0, 1, 2, 3]), order: rint(1, 200), position: pick([0, 1, 2, 3, 4]),
                disable: false, addMemo: false, group: '', groupOverride: false, groupWeight: 100, sticky: 0, cooldown: 0, delay: 0,
                probability: 100, useProbability: false, depth: rint(0, 4), role: pick([0, 1, 2]), vectorized: false,
                excludeRecursion: chance(0.2), preventRecursion: chance(0.2), delayUntilRecursion: 0, scanDepth: chance(0.3) ? rint(1, 4) : null,
                caseSensitive: false, matchWholeWords: chance(0.3), useGroupScoring: false, automationId: '',
                characterFilter: null, triggers: [], matchPersonaDescription: false, matchCharacterDescription: false,
                matchCharacterPersonality: false, matchCharacterDepthPrompt: false, matchScenario: false, matchCreatorNotes: false,
            };
        }
        world = { entries, name: FUZZ_WORLD };
        card.data.extensions.world = FUZZ_WORLD;
    } else {
        delete card.data.extensions.world;
    }

    // --- settings patch (persona, author note, templates, power-user, sysprompt) ---
    const applySettings = (s) => {
        const pu = s.power_user = s.power_user || {};
        const avatar = s.user_avatar;

        // persona: text + position + depth + role
        const personaPos = pick([0, 1, 2, 3, 4, 9]); // IN_PROMPT AFTER_CHAR TOP_AN BOTTOM_AN AT_DEPTH NONE
        const personaText = personaPos === 9 ? '' : `${mark('persona')} the traveller, weary${macroSalad()}`;
        const personaDepth = rint(1, 4), personaRole = pick([0, 1, 2]);
        pu.personas = pu.personas || {}; pu.personas[avatar] = baseSettings.username || 'Tester';
        pu.persona_descriptions = pu.persona_descriptions || {};
        // The persona-bound lorebook is stock's FOURTH world-info source (getPersonaLore). It was pinned
        // empty here, so that source was never exercised on either side.
        const personaBook = (personaPos !== 9 && chance2(0.3)) ? FUZZ_WORLD : '';
        pu.persona_descriptions[avatar] = { description: personaText, position: personaPos, depth: personaDepth, role: personaRole, lorebook: personaBook };
        pu.persona_description = personaText;
        pu.persona_description_position = personaPos;
        pu.persona_description_depth = personaDepth;
        pu.persona_description_role = personaRole;
        pu.persona_description_lorebook = personaBook;
        if (personaBook) axes.push('persona-lorebook');

        if (process.env.DUMP_SEED && seed === Number(process.env.DUMP_SEED)) {
            console.error('DUMP persona:', JSON.stringify({ pos: personaPos, depth: personaDepth, role: personaRole }));
        }
        // author's note (global default; a fresh chat inherits it)
        s.extension_settings = s.extension_settings || {};
        if (chance(0.5)) {
            const anText = `${mark('authors-note')} the wind rises${macroSalad()}`;
            s.extension_settings.note = { default: anText, defaultInterval: 1, defaultPosition: pick([0, 1]), defaultDepth: rint(1, 4), defaultRole: pick([0, 1, 2]), allowWIScan: false, chara: [] };
            if (process.env.DUMP_SEED && seed === Number(process.env.DUMP_SEED)) console.error('DUMP note:', JSON.stringify(s.extension_settings.note));
        } else {
            s.extension_settings.note = { default: '', defaultInterval: 1, defaultPosition: 0, defaultDepth: 4, defaultRole: 0, allowWIScan: false, chara: [] };
        }

        // --formats: swap in the seed's shipped instruct+context preset AS-SHIPPED (own wrap/sequences),
        // so a divergence attributes to that format. Else mutate ChatML's knobs for structure coverage.
        if (format) {
            const inst = loadPreset(INSTRUCT_DIR, format); if (inst) { inst.enabled = true; pu.instruct = inst; }
            const ctx = loadPreset(CONTEXT_DIR, format); if (ctx) pu.context = ctx;
        } else {
            if (pu.instruct) { pu.instruct.wrap = chance(0.5); pu.instruct.names_behavior = pick(['none', 'force', 'always']); axes.push('instruct-template'); }
            if (pu.context) { pu.context.example_separator = pick(['***', '<START>', '---']); pu.context.chat_start = pick(['', '***']); axes.push('context-template'); }
            // parity-seed.py forces instruct ON for every run, so the whole non-instruct path was untested:
            // always_force_name2 and the classic `Name:` cue only exist there. Never disabled under --formats.
            if (pu.instruct && chance2(0.25)) {
                pu.instruct.enabled = false;
                pu.always_force_name2 = chance2(0.5);
                axes.push('instruct-off');
            }
        }

        // power-user prompt-reaching settings (some drive the stop array)
        pu.collapse_newlines = chance(0.5);
        if (process.env.DUMP_SEED && seed === Number(process.env.DUMP_SEED)) console.error('DUMP collapse_newlines:', pu.collapse_newlines);
        pu.trim_sentences = chance(0.5);
        pu.custom_stopping_strings = JSON.stringify([`ZSTOP_${seed}A`, `ZSTOP_${seed}B`]);
        pu.custom_stopping_strings_macro = chance(0.5);
        pu.names_as_stop_strings = chance(0.5);
        axes.push('power-user');

        // Prompt-affecting settings the generator never varied before (measured 2026-08-04: 48 of 61
        // prompt-path power_user keys unvaried). Each of these changes prompt bytes in stock.
        pu.pin_examples = chance2(0.35);
        pu.strip_examples = !pu.pin_examples && chance2(0.2);
        pu.token_padding = pick2([0, 64, 256]);
        pu.disable_group_trimming = chance2(0.5);
        if (chance2(0.35)) {
            pu.user_prompt_bias = `${mark('prompt-bias')} bias tail`;
            pu.show_user_prompt_bias = true;
        } else { pu.user_prompt_bias = ''; }
        if (pu.pin_examples || pu.strip_examples) axes.push('example-mode');
        if (pu.token_padding !== 64) axes.push('token-padding');

        // WI globals were never set, so recursion never ran (stock default off) and the caps were dead.
        // Both frontends read `world_info_settings ?? root` and the seed HAS it: a root write is ignored.
        const ws = s.world_info_settings = s.world_info_settings || {};
        ws.world_info_recursive = chance2(0.5);
        ws.world_info_max_recursion_steps = ws.world_info_recursive ? pick2([0, 1, 2, 3]) : 0;
        ws.world_info_budget_cap = pick2([0, 0, 50, 200]);
        ws.world_info_budget = pick2([25, 50, 100]);
        ws.world_info_depth = rint2(1, 4);
        if (ws.world_info_recursive) axes.push('wi-recursive');
        if (ws.world_info_budget_cap) axes.push('wi-budget-cap');

        // sysprompt stays enabled with a marked content (global system slot)
        pu.sysprompt = { enabled: true, name: 'Parity', content: `${mark('global-sysprompt')} Stay in character.` };
        pu.prefer_character_prompt = true; pu.prefer_character_jailbreak = true;
    };

    // --- chat history (a minority cross the trim boundary via multi-send) ---
    const histLen = chance(0.25) ? rint(2, 4) : 0;
    const messages = [];
    for (let k = 0; k < histLen; k++) messages.push(`turn ${k}: more about the glade and its beasts and magic`);
    messages.push('Tell me what you see in the glade with beasts and magic.'); // final (carries WI scan words)
    if (histLen) axes.push('chat-history');

    if (process.env.DUMP_SEED && seed === Number(process.env.DUMP_SEED)) {
        console.error('DUMP fmt:', format);
        console.error('DUMP depth_prompt:', JSON.stringify(card.data?.extensions?.depth_prompt));
        console.error('DUMP world:', JSON.stringify(Object.values(world?.entries || {}).map((e) => ({ uid: e.uid, role: e.role, position: e.position, depth: e.depth }))));
    }
    return { seed, card, world, applySettings, messages, markers, axes, format };
}

function applyFuzzState(state, baseSettings, basePng) {
    const chars = join(argsData, 'default-user', 'characters');
    writeFileSync(join(chars, `${FUZZ_CARD}.png`), makeCardPng(basePng, state.card));
    const wf = join(argsData, 'default-user', 'worlds', `${FUZZ_WORLD}.json`);
    if (state.world) writeFileSync(wf, JSON.stringify(state.world, null, 4));
    else if (existsSync(wf)) rmSync(wf, { force: true });
    const s = JSON.parse(JSON.stringify(baseSettings));
    state.applySettings(s);
    writeFileSync(join(argsData, 'default-user', 'settings.json'), JSON.stringify(s, null, 4));
    // Handed back, never recomputed: applySettings DRAWS from the scenario's PRNG, so calling it a
    // second time to "see" the settings produces a different scenario than the one on disk.
    return s;
}

// Attribute a divergence to feature buckets: a marker token inside a +/- hunk -> that feature; a stop
// mismatch -> stop-strings; hunks present but no marker matched -> structure/order/format.
function classifyDiff(diffText, stopEqual, markers) {
    const buckets = new Set();
    const hunks = (diffText || '').split('\n').filter((l) => l.startsWith('+ ') || l.startsWith('- ')).join('\n');
    for (const [token, feat] of Object.entries(markers)) if (hunks.includes(token)) buckets.add(feat);
    if (!stopEqual) buckets.add('stop-strings');
    if (hunks.length && buckets.size === (stopEqual ? 0 : 1)) buckets.add('structure/order/format');
    return [...buckets];
}

// ---- the audit: judge OUR prompt on its own terms ------------------------------------------------
//
// The differential fuzz above asks "is this byte-identical to the old frontend". That answers whether
// we match, never whether we are RIGHT, and it turns every deliberate improvement red. The audit asks
// the question the operator actually cares about: is anything MISSING, and is anything MANGLED. The
// old frontend stays a defect detector (--fuzz); it stops being the definition of correct.

/// The marker tokens whose feature must appear exactly once when it appears at all. A repeat means a
/// block was emitted twice, which costs context and confuses the model.
const SINGLETON_FEATURES = new Set([
    'card-description', 'card-personality', 'card-scenario', 'card-creatornotes',
    'card-system', 'card-jailbreak', 'card-depthprompt', 'persona', 'authors-note', 'global-sysprompt',
]);

/// Which marker features the settings say MUST be in the prompt. Derived from the scenario, never from
/// the other frontend: a field that rides the story string is only expected when the chosen context
/// template actually has a slot for it, so a template without {{personality}} is not a missing field.
function expectedFeatures(state, s) {
    const pu = s.power_user || {};
    const story = String(pu.context?.story_string || '');
    const card = state.card.data || {};
    const has = (v) => typeof v === 'string' && v.length > 0;
    const want = new Set();

    if (has(card.description) && story.includes('{{description}}')) want.add('card-description');
    if (has(card.personality) && story.includes('{{personality}}')) want.add('card-personality');
    if (has(card.scenario) && story.includes('{{scenario}}')) want.add('card-scenario');
    // The greeting is the chat's first message, so it rides the history rather than the story string.
    if (has(card.first_mes)) want.add('card-greeting');
    if (has(card.mes_example) && !pu.strip_examples) want.add('card-example');
    if (has(card.system_prompt) && pu.prefer_character_prompt !== false) want.add('card-system');
    if (has(card.post_history_instructions) && pu.prefer_character_jailbreak !== false) want.add('card-jailbreak');
    if (has(card.extensions?.depth_prompt?.prompt)) want.add('card-depthprompt');
    // The card's own system prompt carries {{original}}, which pulls the global one in behind it, so
    // the global marker is expected either way once sysprompt is on.
    if (pu.sysprompt?.enabled) want.add('global-sysprompt');

    const persona = pu.persona_description ?? '';
    const pos = pu.persona_description_position;
    // IN_PROMPT (0) rides the story string's {{persona}} slot; every other position injects on its own.
    if (has(persona) && pos !== 9 && (pos !== 0 || story.includes('{{persona}}'))) want.add('persona');

    if (has(s.extension_settings?.note?.default || '')) want.add('authors-note');
    if (has(pu.user_prompt_bias)) want.add('prompt-bias');

    // World info only when an entry needs no keyword match AND no absolute cap can starve it. A cap is
    // the one setting that legitimately drops lore, and re-deriving which entry survives would just be
    // the prompt builder written twice.
    const entries = Object.values(state.world?.entries || {});
    const capped = Number(s.world_info_settings?.world_info_budget_cap || 0) > 0;
    if (!capped && entries.some((e) => e.constant)) want.add('world-info');
    return want;
}

/// Everything wrong with one prompt, as findings. Empty = the prompt carries every field the scenario
/// asked for, in one piece, with nothing left unrendered.
function auditPrompt(prompt, state, s) {
    const findings = [];
    const seed = String(state.seed);
    const featureOf = state.markers;
    const add = (check, detail) => findings.push({ check, detail });

    if (!prompt || !prompt.trim()) {
        add('empty-prompt', 'the assembled prompt is empty');
        return findings;
    }

    // MISSING: a field the settings put in the prompt that did not arrive.
    const want = expectedFeatures(state, s);
    const present = new Set();
    for (const [token, feat] of Object.entries(featureOf)) if (prompt.includes(token)) present.add(feat);
    for (const feat of want) if (!present.has(feat)) add('missing-field', feat);

    // MANGLED: a marker that starts and does not finish. A trim, a bad slice or an off-by-one shows up
    // here first; this is the exact shape of the trim_sentences fault the differential run found.
    // trim_sentences deliberately cuts a reply at its last sentence end, and the markers carry '_',
    // which stock counts as one. With it on, a cut marker is the setting working.
    if (!s.power_user?.trim_sentences) {
        for (const m of prompt.matchAll(/Z[A-Z]+_/g)) {
            const tail = prompt.slice(m.index, m.index + m[0].length + seed.length + 1);
            if (!tail.endsWith(`${seed}Z`)) add('truncated-marker', `${m[0]}... at offset ${m.index}`);
        }
    }

    // UNRENDERED: macro syntax that reached the model. A macro we do not implement lands here verbatim,
    // which is worse than useless: the model reads the braces as content.
    for (const m of prompt.matchAll(/\{\{[^}\n]{0,60}\}\}/g)) add('unresolved-macro', m[0]);
    for (const tag of ['<USER>', '<BOT>', '<CHAR>']) if (prompt.includes(tag)) add('unresolved-macro', tag);

    // DUPLICATED: one block emitted twice spends context on nothing.
    // A card system prompt or jailbreak containing {{original}} pulls the global one in behind it, so
    // both markers legitimately appear twice. Only a THIRD copy is a duplicated block.
    const nests = /\{\{original\}\}/.test(String(state.card.data?.system_prompt || '') + String(state.card.data?.post_history_instructions || ''));
    for (const [token, feat] of Object.entries(featureOf)) {
        if (!SINGLETON_FEATURES.has(feat)) continue;
        const allowed = (nests && (feat === 'card-system' || feat === 'global-sysprompt' || feat === 'card-jailbreak')) ? 2 : 1;
        const n = prompt.split(token).length - 1;
        if (n > allowed) add('duplicate-block', `${feat} appears ${n} times`);
    }

    // BARE LABEL: a speaker cue with no line behind it, the shape of the nameless-label fault.
    for (const line of prompt.split('\n')) {
        if (/^\s*:\s*$/.test(line)) add('bare-label', 'a line is nothing but a colon');
    }

    // DROPPED TURN: every message the user actually sent has to be in the window.
    for (const msg of state.messages) if (!prompt.includes(msg)) add('missing-turn', msg.slice(0, 40));

    return findings;
}

// Prints the scenario a seed generates without booting anything. A divergent seed is read here first:
// which world entries exist with which fields, and which settings the patch wrote. Needs only a data
// dir a prior run left behind (the card png + the base settings.json).
function describeSeeds(args) {
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const baseSettings = JSON.parse(readFileSync(join(argsData, 'default-user', 'settings.json'), 'utf8'));
    for (let i = 0; i < args.count; i++) {
        const seed = args.worker * 1000000 + args.seed + i;
        const state = genState(seed, basePng, baseSettings);
        const s = JSON.parse(JSON.stringify(baseSettings));
        state.applySettings(s);
        process.stdout.write(`\n===== seed ${seed} axes:[${state.axes.join(',')}] fmt:${state.format} hist:${state.messages.length - 1} =====\n`);
        process.stdout.write(`world: ${JSON.stringify(Object.values(state.world?.entries || {}), null, 1)}\n`);
        process.stdout.write(`world_info_settings: ${JSON.stringify(s.world_info_settings, null, 1)}\n`);
        process.stdout.write(`power_user: ${JSON.stringify(s.power_user, null, 1)}\n`);
        process.stdout.write(`depth_prompt: ${JSON.stringify(state.card.data?.extensions?.depth_prompt)}\n`);
    }
}

/// Proves every audit check can FAIL. A checker that has never rejected anything is indistinguishable
/// from one that cannot, so each check is fed a prompt broken in exactly its way and must name it.
function auditSelfCheck() {
    const seed = 99000001;
    const mk = (feat) => `Z${feat.toUpperCase().replace(/[^A-Z]/g, '')}_${seed}Z`;
    const markers = {
        [mk('card-description')]: 'card-description',
        [mk('persona')]: 'persona',
        [mk('authors-note')]: 'authors-note',
        [mk('card-greeting')]: 'card-greeting',
    };
    const state = {
        seed,
        markers,
        messages: ['tell me about the glade'],
        card: { data: { description: 'a glade', first_mes: 'hello' } },
        world: null,
    };
    const settings = {
        power_user: {
            context: { story_string: '{{description}}\n{{persona}}' },
            sysprompt: { enabled: false },
            persona_description: 'the traveller',
            persona_description_position: 0,
            trim_sentences: false,
        },
        extension_settings: { note: { default: 'the wind rises' } },
    };
    const whole = [
        mk('card-description'),
        mk('persona'),
        mk('authors-note'),
        mk('card-greeting'),
        'tell me about the glade',
    ].join('\n');

    const cases = [
        ['empty-prompt', ''],
        ['missing-field', whole.replace(mk('persona'), '')],
        ['truncated-marker', whole.replace(mk('persona'), 'ZPERSONA_')],
        ['unresolved-macro', `${whole}\n{{time}}`],
        ['unresolved-macro', `${whole}\n<USER> stands there`],
        ['duplicate-block', `${whole}\n${mk('card-description')}`],
        ['bare-label', `${whole}\n:`],
        ['missing-turn', whole.replace('tell me about the glade', 'something else entirely')],
    ];

    let passed = 0;
    process.stdout.write('\n########## AUDIT SELF-CHECK ##########\n');
    for (const [check, prompt] of cases) {
        const found = auditPrompt(prompt, state, settings).map((f) => f.check);
        const ok = found.includes(check);
        process.stdout.write(`  ${ok ? 'PASS' : 'FAIL'}  ${check} is caught${ok ? '' : ` (got [${found.join(', ')}])`}\n`);
        if (ok) passed += 1;
    }
    // And the clean prompt must be reported clean, or every run above is a false alarm.
    const cleanFindings = auditPrompt(whole, state, settings);
    const cleanOk = cleanFindings.length === 0;
    process.stdout.write(`  ${cleanOk ? 'PASS' : 'FAIL'}  a correct prompt raises nothing${cleanOk ? '' : ` (got ${JSON.stringify(cleanFindings)})`}\n`);
    if (cleanOk) passed += 1;

    const total = cases.length + 1;
    process.stdout.write(`\nAUDIT SELF-CHECK: ${passed}/${total} passed\n`);
    if (passed !== total) process.exitCode = 2;
}

/// Where an approved prompt lives. Committed beside the harness so a change to the assembled prompt
/// shows up as a diff someone signed off on, not as drift nobody noticed.
const GOLDEN_DIR = new URL('./parity-golden/', import.meta.url).pathname;

async function runAudit(args) {
    const startedAt = Date.now();
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const settingsPath = join(argsData, 'default-user', 'settings.json');
    const baseSettings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    ROTATE_FORMATS = args.formats;
    MACRO_PROBE = Boolean(args.macros);
    if (args.updateGolden && !existsSync(GOLDEN_DIR)) mkdirSync(GOLDEN_DIR, { recursive: true });

    process.stdout.write(`\n########## AUDIT: worker ${args.worker}, seeds ${args.seed}..${args.seed + args.count - 1} ##########\n`);
    process.stdout.write('judging OUR prompt: every field the settings asked for, in one piece, nothing left unrendered.\n');
    const results = [];
    const byCheck = {};
    try {
        for (let i = 0; i < args.count; i++) {
            const seed = args.worker * 1000000 + args.seed + i;
            const state = genState(seed, basePng, baseSettings);
            let applied = null;
            let hit, error = null;
            for (let attempt = 1; attempt <= DRIVE_ATTEMPTS; attempt++) {
                error = null;
                try {
                    applied = applyFuzzState(state, baseSettings, basePng);
                    await resetChat(FUZZ_CARD);
                    seedChatFile(FUZZ_CARD, FUZZ_CARD, baseSettings.username || 'Tester', state.card.chat, applied.extension_settings?.note);
                    const p = await driveMulti('new', FUZZ_CARD, state.messages, FUZZ_CARD);
                    hit = p[p.length - 1];
                    break;
                } catch (e) {
                    error = e.message;
                    const down = await deadServices();
                    if (down.length) { error = `${e.message} [SERVICE DOWN: ${down.join(', ')}]`; break; }
                }
            }
            if (error) { process.stdout.write(`  seed ${seed}: DRIVE ERROR: ${error}\n`); results.push({ seed, error }); continue; }

            const findings = auditPrompt(hit.prompt, state, applied);
            const goldenPath = join(GOLDEN_DIR, `${seed}.txt`);
            let drift = null;
            if (args.updateGolden) {
                writeFileSync(goldenPath, hit.prompt);
            } else if (existsSync(goldenPath)) {
                // Masked, like the differential: {{roll}} and {{random}} are genuinely random per send,
                // so a raw compare would report every run as drift and the check would mean nothing.
                const approved = readFileSync(goldenPath, 'utf8');
                const a = maskFuzz(approved);
                const b = maskFuzz(hit.prompt);
                if (a !== b) drift = diffReport(a, b);
            }
            for (const f of findings) {
                const b = byCheck[f.check] = byCheck[f.check] || { seeds: new Set(), details: new Set() };
                b.seeds.add(seed);
                b.details.add(f.detail);
            }
            if (!findings.length && !drift) { process.stdout.write(`  seed ${seed}: CLEAN (${hit.prompt.length} bytes)\n`); results.push({ seed, clean: true }); continue; }
            process.stdout.write(`  seed ${seed}: ${findings.length} finding(s) axes:[${state.axes.join(',')}]\n`);
            for (const f of findings.slice(0, 12)) process.stdout.write(`      ${f.check}: ${f.detail}\n`);
            if (findings.length > 12) process.stdout.write(`      ... ${findings.length - 12} more\n`);
            if (drift) {
                process.stdout.write(`      unapproved-change: the prompt differs from the approved snapshot\n--- approved   +++ now\n${drift.text}\n`);
                const b = byCheck['unapproved-change'] = byCheck['unapproved-change'] || { seeds: new Set(), details: new Set() };
                b.seeds.add(seed);
                b.details.add('the prompt differs from the approved snapshot');
            }
            writeFileSync(join(args.data, `au-${seed}.txt`), hit.prompt);
            results.push({ seed, clean: false, findings: findings.length, drift: Boolean(drift) });
        }
    } finally {
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4));
        for (const p of [join(argsData, 'default-user', 'characters', `${FUZZ_CARD}.png`), join(argsData, 'default-user', 'worlds', `${FUZZ_WORLD}.json`)]) if (existsSync(p)) rmSync(p, { force: true });
    }

    const clean = results.filter((r) => r.clean).length;
    const errs = results.filter((r) => r.error).length;
    const dirty = results.filter((r) => r.clean === false).length;
    process.stdout.write(`\n########## AUDIT SUMMARY (worker ${args.worker}) ##########\n`);
    process.stdout.write(`seeds ${results.length}: ${clean} CLEAN, ${dirty} WITH FINDINGS, ${errs} ERROR\n`);
    // Distinct details, not a seed tally: 30 seeds all missing the same macro is ONE thing to fix, and
    // the per-seed lines above truncate. This is the list to work from.
    for (const [check, b] of Object.entries(byCheck).sort((a, b2) => b2[1].seeds.size - a[1].seeds.size)) {
        const seeds = [...b.seeds];
        process.stdout.write(`  ${check}: ${b.details.size} distinct in ${seeds.length} seed(s)  [${seeds.slice(0, 4).join(', ')}${seeds.length > 4 ? ', ...' : ''}]\n`);
        for (const d of [...b.details].sort()) process.stdout.write(`      ${d}\n`);
    }
    if (args.updateGolden) process.stdout.write(`\napproved snapshots written to ${GOLDEN_DIR}\n`);
    process.stdout.write(`\n(per-seed prompts at ${args.data}/au-<seed>.txt)\n`);
    await reportIntegrity(args.count, results.length, startedAt);
}

async function runFuzz(args) {
    const startedAt = Date.now();
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const settingsPath = join(argsData, 'default-user', 'settings.json');
    const baseSettings = JSON.parse(readFileSync(settingsPath, 'utf8'));

    ROTATE_FORMATS = args.formats;
    if (ROTATE_FORMATS) process.stdout.write(`\n########## FORMAT ROTATION: ${INSTRUCT_PRESETS.length} instruct presets (run --count ${INSTRUCT_PRESETS.length}+ for full coverage) ##########\n`);

    // re-confirm the existing hand-cards still MATCH after these changes (regression guard).
    if (args.handcards) {
        process.stdout.write('\n########## HAND-CARD RE-CONFIRM (baseline battery) ##########\n');
        await runBattery({ ...args, only: null });
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4)); // battery leaves settings; restore before fuzz
    }

    process.stdout.write(`\n########## FUZZ: worker ${args.worker}, seeds ${args.seed}..${args.seed + args.count - 1} ##########\n`);
    const results = [];
    const byFeature = {};
    try {
        for (let i = 0; i < args.count; i++) {
            const seed = args.worker * 1000000 + args.seed + i;
            const state = genState(seed, basePng, baseSettings);
            process.stdout.write(`\n----- seed ${seed} axes:[${state.axes.join(',')}] hist:${state.messages.length - 1} -----\n`);
            let oldHit, newHit, error = null;
            // Scoring the first drive failure as ERROR reports machine load as a result and loses the seed;
            // a genuinely broken drive still fails every attempt.
            for (let attempt = 1; attempt <= DRIVE_ATTEMPTS; attempt++) {
                error = null;
                try {
                    applyFuzzState(state, baseSettings, basePng);
                    await resetChat(FUZZ_CARD);
                    const oldP = await driveMulti('old', FUZZ_CARD, state.messages, FUZZ_CARD);
                    resetChatToHeader(FUZZ_CARD);
                    const newP = await driveMulti('new', FUZZ_CARD, state.messages, FUZZ_CARD);
                    oldHit = oldP[oldP.length - 1]; newHit = newP[newP.length - 1];
                    break;
                } catch (e) {
                    error = e.message;
                    // Name a dead dependency instead of letting it masquerade as a parity failure: a dead
                    // fake backend reports as "old: never connected", which points at the wrong process.
                    const down = await deadServices();
                    if (down.length) { error = `${e.message} [SERVICE DOWN: ${down.join(', ')}]`; break; }
                    if (attempt < DRIVE_ATTEMPTS) process.stdout.write(`  seed ${seed}: drive attempt ${attempt}/${DRIVE_ATTEMPTS} failed (${e.message}), retrying\n`);
                }
            }
            if (error) { process.stdout.write(`  seed ${seed}: DRIVE ERROR: ${error}\n`); results.push({ seed, error }); continue; }
            writeFileSync(join(args.data, `fz-${seed}-old.txt`), oldHit.prompt);
            writeFileSync(join(args.data, `fz-${seed}-new.txt`), newHit.prompt);
            const stopEqual = JSON.stringify(oldHit.stop ?? null) === JSON.stringify(newHit.stop ?? null);
            const rep = diffReport(maskFuzz(oldHit.prompt), maskFuzz(newHit.prompt));
            if (rep.equal && stopEqual) { process.stdout.write(`  seed ${seed}: MATCH (${rep.bytes} bytes)\n`); results.push({ seed, equal: true }); continue; }
            const feats = classifyDiff(rep.text, stopEqual, state.markers);
            for (const f of feats) (byFeature[f] = byFeature[f] || []).push(seed);
            // Axes reprinted here, not just in the header: the header prints before applySettings runs, so
            // every axis chosen there (power-user, instruct-off, wi-*, prompt-bias) is missing from it.
            process.stdout.write(`  seed ${seed}: DIVERGENT feats:[${feats.join(',')}] axes:[${state.axes.join(',')}] stopEqual:${stopEqual}\n`);
            if (!rep.equal) process.stdout.write(`--- old (public/)   +++ new (wasm)\n${rep.text}\n`);
            if (!stopEqual) process.stdout.write(`  STOP old=${JSON.stringify(oldHit.stop)}\n  STOP new=${JSON.stringify(newHit.stop)}\n`);
            results.push({ seed, equal: false, feats, stopEqual });
        }
    } finally {
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4)); // restore clean settings
        for (const p of [join(argsData, 'default-user', 'characters', `${FUZZ_CARD}.png`), join(argsData, 'default-user', 'worlds', `${FUZZ_WORLD}.json`)]) if (existsSync(p)) rmSync(p, { force: true });
    }

    const matches = results.filter((r) => r.equal).length;
    const errs = results.filter((r) => r.error).length;
    const divs = results.filter((r) => r.equal === false).length;
    process.stdout.write(`\n########## FUZZ SUMMARY (worker ${args.worker}) ##########\n`);
    process.stdout.write(`seeds ${results.length}: ${matches} MATCH, ${divs} DIVERGENT, ${errs} ERROR\n`);
    process.stdout.write('divergence classes (feature -> seed count [sample seeds]):\n');
    for (const [feat, seeds] of Object.entries(byFeature).sort((a, b) => b[1].length - a[1].length)) {
        process.stdout.write(`  ${feat}: ${seeds.length}  [${seeds.slice(0, 6).join(', ')}${seeds.length > 6 ? ', ...' : ''}]\n`);
    }
    if (ROTATE_FORMATS) {
        const byFmt = {};
        for (const r of results) { const f = INSTRUCT_PRESETS[r.seed % INSTRUCT_PRESETS.length]; const b = byFmt[f] = byFmt[f] || { m: 0, d: 0, e: 0 }; if (r.error) b.e++; else if (r.equal) b.m++; else b.d++; }
        process.stdout.write('\nper-format matrix (format -> MATCH/DIV/ERR):\n');
        for (const f of INSTRUCT_PRESETS) { const b = byFmt[f]; if (b) process.stdout.write(`  ${b.d ? 'DIV ' : b.e ? 'ERR ' : 'ok  '} ${f}: ${b.m}M ${b.d}D ${b.e}E\n`); }
    }
    if (errs) process.stdout.write(`errors: ${results.filter((r) => r.error).map((r) => `${r.seed}(${r.error.slice(0, 60)})`).join('; ')}\n`);
    process.stdout.write(`\n(per-seed prompts at ${args.data}/fz-<seed>-{old,new}.txt; reproduce one with --fuzz --seed <N> --count 1)\n`);
    await reportIntegrity(args.count, results.length, startedAt);
}

/// Says whether the numbers above can be believed. A run whose services were killed mid-way still prints
/// a tidy summary, so this sets a non-zero exit code to stop a killed run reading as a pass.
async function reportIntegrity(requested, scored, startedAt) {
    const elapsed = Math.round((Date.now() - startedAt) / 1000);
    const down = await deadServices();
    const faults = [];
    if (scored < requested) faults.push(`TRUNCATED: scored ${scored} of ${requested} seeds`);
    if (down.length) faults.push(`SERVICE DOWN at end: ${down.join(', ')}`);
    // The services die exactly at DEP_TTL, so a run that outlives it was scoring against corpses.
    if (elapsed >= DEP_TTL) faults.push(`OUTLIVED the ${DEP_TTL}s service lifetime (ran ${elapsed}s); raise PARITY_DEP_TTL`);
    process.stdout.write('\n########## RUN INTEGRITY ##########\n');
    process.stdout.write(`elapsed ${elapsed}s of ${DEP_TTL}s service lifetime; seeds scored ${scored}/${requested}; services ${down.length ? `DOWN(${down.join(',')})` : 'all up'}\n`);
    if (faults.length === 0) {
        process.stdout.write('VERDICT: COMPLETE (every seed scored, services alive, inside the service lifetime)\n');
        return true;
    }
    for (const f of faults) process.stdout.write(`  ${f}\n`);
    process.stdout.write('VERDICT: NOT TRUSTWORTHY (the counts above are partial; do not cite them)\n');
    process.exitCode = 2;
    return false;
}

// ---- TRIM boundary battery: ONE deterministic scenario that FORCES token-budget trimming. A big
// card story block (description/personality/scenario) eats most of a small max_context, then a long
// multi-send history exceeds what remains so the builder MUST drop oldest turns. This exercises the
// history-trim boundary the below-boundary hand-cards never reach: it is exactly where a mismatch in
// overhead token accounting (client counts wrapped_story+examples+chat_start as one encode with NO
// token_padding; old getMessagesTokenCount concatenates a different set + power_user.token_padding)
// shifts which oldest turn survives. NO macros in card/messages, so no impure masking: raw byte-diff.
const TRIM_CARD = 'ParityTrim';

function bigText(tag, n) {
    let s = tag;
    for (let i = 0; i < n; i++) s += ` the warded glade holds beasts and old magic beneath the ${i} dusk sky`;
    return s;
}

function trimCard(basePng) {
    const card = loadCardJson(basePng);
    card.name = TRIM_CARD;
    card.data = card.data || {};
    card.data.name = TRIM_CARD;
    card.data.description = bigText('DESC', 14);
    card.data.personality = bigText('PERS', 5);
    card.data.scenario = bigText('SCEN', 5);
    card.data.first_mes = 'GREET00 Hello traveller, I am the watchful keeper of this glade.';
    card.data.mes_example = '';
    card.data.creator_notes = '';
    card.data.system_prompt = '';
    card.data.post_history_instructions = '';
    card.data.extensions = card.data.extensions || {};
    delete card.data.extensions.depth_prompt;
    delete card.data.extensions.world;
    delete card.data.character_book; delete card.character_book;
    return card;
}

async function runTrimBattery(args) {
    const { writeFileSync } = await import('node:fs');
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const settingsPath = join(argsData, 'default-user', 'settings.json');
    const baseSettings = JSON.parse(readFileSync(settingsPath, 'utf8'));

    // Tight budget = max_context - amount_gen. Written to both keys BOTH builders mine (settings.max_context
    // + settings.amount_gen); the big story block below then forces oldest-first history trimming.
    const s = JSON.parse(JSON.stringify(baseSettings));
    s.max_context = args.ctx;
    s.amount_gen = args.amt;
    // Diagnostic: --pad 0 sets power_user.token_padding to isolate whether the reserve is the sole cause
    // of the boundary shift (a byte-identical result at pad 0 also proves both used the same real tokenizer).
    if (args.pad !== null) { s.power_user = s.power_user || {}; s.power_user.token_padding = args.pad; }
    writeFileSync(settingsPath, JSON.stringify(s, null, 4));
    writeFileSync(join(argsData, 'default-user', 'characters', `${TRIM_CARD}.png`), makeCardPng(basePng, trimCard(basePng)));

    const msgs = [];
    for (let i = 0; i < args.sends; i++) msgs.push(`TURN${String(i).padStart(2, '0')} tell me more about the glade and the beasts and the old magic that lingers among these ancient trees`);

    try {
        process.stdout.write(`\n===== TRIM boundary: ${TRIM_CARD}, max_context=${s.max_context} amount_gen=${s.amount_gen} (budget=${s.max_context - s.amount_gen} tok), ${msgs.length} sends =====\n`);
        await resetChat(TRIM_CARD);
        const oldP = await driveMulti('old', TRIM_CARD, msgs, TRIM_CARD, true);
        resetChatToHeader(TRIM_CARD);
        const newP = await driveMulti('new', TRIM_CARD, msgs, TRIM_CARD, true);
        const common = Math.min(oldP.length, newP.length);
        if (common < msgs.length) process.stdout.write(`  NOTE: comparing ${common} completed sends (old ${oldP.length}, new ${newP.length} of ${msgs.length})\n`);
        let allEqual = true, firstDiff = -1;
        for (let k = 0; k < common; k++) {
            writeFileSync(join(args.data, `p-trim${String(k + 1).padStart(2, '0')}-old.txt`), oldP[k]?.prompt ?? '');
            writeFileSync(join(args.data, `p-trim${String(k + 1).padStart(2, '0')}-new.txt`), newP[k]?.prompt ?? '');
            const rep = diffReport(oldP[k]?.prompt ?? '', newP[k]?.prompt ?? '');
            if (rep.equal) { process.stdout.write(`  send ${k + 1}: BYTE-IDENTICAL (${rep.bytes} bytes)\n`); }
            else {
                allEqual = false; if (firstDiff < 0) firstDiff = k + 1;
                process.stdout.write(`  send ${k + 1}: DIVERGENT (old ${rep.bytes.old}, new ${rep.bytes.new})\n--- old (public/)   +++ new (wasm)\n${rep.text}\n`);
            }
        }
        // Oracle validity: the reference (old) must actually have trimmed on the deepest COMPARED send -
        // oldest turns gone, newest kept - else the budget was not tight enough and the diff proves nothing.
        const deepest = Math.max(common - 1, 0);
        const finalOld = oldP[deepest]?.prompt ?? '';
        const survivors = [];
        for (let i = 0; i < deepest; i++) if (finalOld.includes(`TURN${String(i).padStart(2, '0')}`)) survivors.push(i);
        const droppedOldest = !finalOld.includes('TURN00') && !finalOld.includes('GREET00');
        const keptNewest = finalOld.includes(`TURN${String(deepest).padStart(2, '0')}`);
        process.stdout.write(`  oracle validity (old send ${deepest + 1}): trimmed oldest=${droppedOldest}, kept newest=${keptNewest}, surviving TURNs=[${survivors.join(',')}]\n`);
        process.stdout.write(`\n===== TRIM RESULT: ${allEqual ? 'ALL SENDS BYTE-IDENTICAL' : `DIVERGENCE (first at send ${firstDiff})`}${(droppedOldest && keptNewest) ? '' : ' (WARNING: no real trim on old - oracle vacuous, lower --ctx or raise --sends)'} =====\n`);
    } finally {
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4));
        const cp = join(argsData, 'default-user', 'characters', `${TRIM_CARD}.png`);
        if (existsSync(cp)) rmSync(cp, { force: true });
    }
}

// ---- measure stock's ACTUAL {{pick}} inputs (non-invasive: wraps String.prototype.charCodeAt in the
// browser so every getStringHash(str) reveals `str`; NO edits to the reference tree) -----------------
const PICK_HOOK = `(function(){
  if (window.__ccHooked) return 'already';
  window.__ccHooked = true;
  window.__hashLog = [];
  const seen = new Set();
  const orig = String.prototype.charCodeAt;
  String.prototype.charCodeAt = function(i){
    if (i === 0) {
      const len = this.length;
      if (len >= 8) {
        const c0 = orig.call(this, 0);
        if (c0 >= 48 && c0 <= 57 && len < 80) {
          const s = this.toString();
          if (/^\\d{6,}-\\d{6,}-\\d+/.test(s)) { if(!seen.has('s'+s)){ seen.add('s'+s); window.__hashLog.push('SEED\\t'+s); } }
        } else if (len > 20) {
          const s = this.toString();
          if (s.indexOf('{{pick') !== -1) { const k='r'+len+s.slice(0,50); if(!seen.has(k)){ seen.add(k); window.__hashLog.push('RAW\\t'+len+'\\t'+JSON.stringify(s)); } }
        }
      }
    }
    return orig.call(this, i);
  };
  return 'hooked';
})()`;

async function driveOldWithHook(display) {
    const { page, child } = await newPage();
    try {
        await page.navigate(`http://127.0.0.1:${PORTS.OLD}/`);
        const connected = await page.waitFor(
            "document.querySelector('.online_status_text') && document.querySelector('.online_status_text').textContent.trim().length>0 && !/no.?connection|not connected/i.test(document.querySelector('.online_status_text').textContent)", 60000);
        if (!connected) throw new Error('old: never connected');
        const opened = await page.eval(`(function(){
            const items=[...document.querySelectorAll('.character_select')];
            const el=items.find(e=>{const n=e.querySelector('.ch_name');return n&&n.textContent.trim()===${JSON.stringify(display)};});
            if(!el) return false; el.click(); return true;
        })()`);
        if (!opened) throw new Error(`old: ${display} not in list`);
        if (!await page.waitFor("document.querySelectorAll('#chat .mes').length >= 1", 15000)) throw new Error('old: chat/greeting never loaded');
        await sleep(500);
        const hookState = await page.eval(PICK_HOOK);
        process.stdout.write(`[measure] hook install: ${hookState}\n`);
        await fakeClear();
        await page.focus('#send_textarea');
        await page.insertText(MSG);
        await page.jsClick('#send_but');
        const hit = await captureFor(MSG, 15000);
        if (!hit) throw new Error('old: no prompt captured under hook');
        const logJson = await page.eval("JSON.stringify(window.__hashLog||[])");
        return { hit, log: JSON.parse(logJson) };
    } finally { try { process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ } }
}

async function runMeasurePick(args) {
    const { readFileSync, writeFileSync, existsSync, rmSync } = await import('node:fs');
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const settingsPath = join(argsData, 'default-user', 'settings.json');
    const baseSettings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    const seed = args.worker * 1000000 + args.seed;
    const state = genState(seed, basePng, baseSettings);
    process.stdout.write(`\n########## MEASURE PICK: seed ${seed} axes:[${state.axes.join(',')}] ##########\n`);
    try {
        applyFuzzState(state, baseSettings, basePng);
        await resetChat(FUZZ_CARD);
        const { hit, log } = await driveOldWithHook(FUZZ_CARD);
        writeFileSync(join(args.data, `mp-${seed}-old.txt`), hit.prompt);
        process.stdout.write(`\n=== captured getStringHash inputs during the real generation ===\n`);
        for (const line of log) process.stdout.write(line + '\n');
        process.stdout.write(`\n=== chat id (for chatIdHash) = "Seraphina - 2023-5-12 @21h 32m 29s 224ms" ===\n`);
        process.stdout.write(`(old prompt saved at ${args.data}/mp-${seed}-old.txt)\n`);
    } finally {
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4));
        for (const p of [join(argsData, 'default-user', 'characters', `${FUZZ_CARD}.png`), join(argsData, 'default-user', 'worlds', `${FUZZ_WORLD}.json`)]) if (existsSync(p)) rmSync(p, { force: true });
    }
}

// ---- mesExamplesRaw story-template battery: forces a CUSTOM story_string carrying {{mesExamplesRaw}}
// (+ {{mesExamples}} as a control) on a card with base example dialogue AND world-info example-position
// entries (EMTop=5, EMBottom=6, which the fuzzer never generates). Stock resolves the STORY-TEMPLATE
// {{mesExamplesRaw}} as mesExamplesRawArray.join('') = the parsed <START> blocks (WI em_top + card +
// em_bottom) UN-instruct-formatted; the card-field/greeting macro keeps the raw trimmed field. This
// exercises the divergence the shipped 34 presets never reach. Markers bracket each value so the exact
// resolved bytes are extractable from the sent prompt. -------------------------------------------------
const MESRAW_CARD = 'ParityMesRaw';
const MESRAW_WORLD = 'ParityMesRaw';
const MESRAW_STORY = 'MRAWBEG[{{mesExamplesRaw}}]MRAWMID[{{mesExamples}}]MRAWEND\n{{#if description}}{{description}}\n{{/if}}{{trim}}';

function mesRawEntry(uid, position, comment, content) {
    return {
        uid, key: [], keysecondary: [], comment, content, constant: true, selective: false,
        selectiveLogic: 0, order: 100, position, disable: false, addMemo: false, group: '',
        groupOverride: false, groupWeight: 100, sticky: 0, cooldown: 0, delay: 0, probability: 100,
        useProbability: false, depth: 4, role: 0, vectorized: false, excludeRecursion: false,
        preventRecursion: false, delayUntilRecursion: 0, scanDepth: null, caseSensitive: false,
        matchWholeWords: false, useGroupScoring: false, automationId: '', characterFilter: null,
        triggers: [], matchPersonaDescription: false, matchCharacterDescription: false,
        matchCharacterPersonality: false, matchCharacterDepthPrompt: false, matchScenario: false,
        matchCreatorNotes: false,
    };
}

function mesRawCard(basePng) {
    const card = loadCardJson(basePng);
    card.name = MESRAW_CARD;
    card.data = card.data || {};
    card.data.name = MESRAW_CARD;
    card.data.description = 'DESCMARK a warded glade.';
    card.data.personality = '';
    card.data.scenario = '';
    card.data.first_mes = 'Greetings, traveler.';
    card.data.mes_example = '<START>\n{{user}}: greetings\n{{char}}: well met, traveler\n<START>\n{{user}}: a question\n{{char}}: an answer';
    card.data.creator_notes = '';
    card.data.system_prompt = '';
    card.data.post_history_instructions = '';
    card.data.alternate_greetings = [];
    card.data.extensions = card.data.extensions || {};
    delete card.data.extensions.depth_prompt;
    card.data.extensions.world = MESRAW_WORLD;
    delete card.data.character_book; delete card.character_book;
    return card;
}

function extractMesRaw(prompt) {
    const m = prompt.match(/MRAWBEG\[([\s\S]*?)\]MRAWMID\[([\s\S]*?)\]MRAWEND/);
    if (!m) return null;
    return { raw: m[1], fmt: m[2] };
}

async function runMesRawBattery(args) {
    const basePng = readFileSync(join(argsData, 'default-user', 'characters', 'default_Seraphina.png'));
    const settingsPath = join(argsData, 'default-user', 'settings.json');
    const baseSettings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    const chars = join(argsData, 'default-user', 'characters');
    const worldsDir = join(argsData, 'default-user', 'worlds');
    if (!existsSync(worldsDir)) mkdirSync(worldsDir, { recursive: true });
    const cardPath = join(chars, `${MESRAW_CARD}.png`);
    const worldPath = join(worldsDir, `${MESRAW_WORLD}.json`);

    const s = JSON.parse(JSON.stringify(baseSettings));
    s.power_user = s.power_user || {};
    s.power_user.context = s.power_user.context || {};
    s.power_user.context.story_string = MESRAW_STORY;

    try {
        writeFileSync(cardPath, makeCardPng(basePng, mesRawCard(basePng)));
        const world = { entries: {
            9400: mesRawEntry(9400, 5, 'em-top', '{{user}}: from the top\n{{char}}: a top reply'),
            9401: mesRawEntry(9401, 6, 'em-bottom', '{{user}}: from the bottom\n{{char}}: a bottom reply'),
        }, name: MESRAW_WORLD };
        writeFileSync(worldPath, JSON.stringify(world, null, 4));
        writeFileSync(settingsPath, JSON.stringify(s, null, 4));

        process.stdout.write(`\n===== MESRAW story-template: ${MESRAW_CARD} + WI em_top/em_bottom, story_string carries {{mesExamplesRaw}} + {{mesExamples}} =====\n`);
        await resetChat(MESRAW_CARD);
        const oldHit = await driveOld(MESRAW_CARD);
        resetChatToHeader(MESRAW_CARD);
        const newHit = await driveNew(MESRAW_CARD);
        writeFileSync(join(args.data, 'p-mesraw-old.txt'), oldHit.prompt);
        writeFileSync(join(args.data, 'p-mesraw-new.txt'), newHit.prompt);

        const rep = diffReport(oldHit.prompt, newHit.prompt);
        const oldEx = extractMesRaw(oldHit.prompt);
        const newEx = extractMesRaw(newHit.prompt);
        process.stdout.write(`\n--- extracted story-template values ---\n`);
        process.stdout.write(`stock {{mesExamplesRaw}} = ${JSON.stringify(oldEx?.raw)}\n`);
        process.stdout.write(`client {{mesExamplesRaw}} = ${JSON.stringify(newEx?.raw)}\n`);
        process.stdout.write(`  mesExamplesRaw MATCH: ${oldEx && newEx && oldEx.raw === newEx.raw}\n`);
        process.stdout.write(`stock {{mesExamples}} = ${JSON.stringify(oldEx?.fmt)}\n`);
        process.stdout.write(`client {{mesExamples}} = ${JSON.stringify(newEx?.fmt)}\n`);
        process.stdout.write(`  mesExamples MATCH: ${oldEx && newEx && oldEx.fmt === newEx.fmt}\n`);
        if (rep.equal) process.stdout.write(`\n===== MESRAW RESULT: WHOLE-PROMPT BYTE-IDENTICAL (${rep.bytes} bytes) =====\n`);
        else process.stdout.write(`\n===== MESRAW RESULT: DIVERGENT (old ${rep.bytes.old}, new ${rep.bytes.new}) =====\n--- old (public/)   +++ new (wasm)\n${rep.text}\n`);
    } finally {
        writeFileSync(settingsPath, JSON.stringify(baseSettings, null, 4));
        for (const p of [cardPath, worldPath]) if (existsSync(p)) rmSync(p, { force: true });
    }
}

/// Proves the integrity checks FIRE, rather than trusting that they would: kills a real service and
/// asserts the probe names it, then asserts a short run and an outlived lifetime are both refused.
async function runSelfCheck(args) {
    const checks = [];
    const assert = (name, pass, detail) => { checks.push({ name, pass, detail }); process.stdout.write(`  ${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}\n`); };
    process.stdout.write('\n########## HARNESS SELF-CHECK ##########\n');

    await bootRig(args);
    const upAtBoot = await deadServices();
    assert('all three services answer after boot', upAtBoot.length === 0, upAtBoot.length ? `down: ${upAtBoot.join(',')}` : '');

    // Kill ONE service and confirm the probe names that one and not another.
    const fake = children.find((c) => c.svcName === 'fake');
    if (fake) { try { process.kill(-fake.pid, 'SIGKILL'); } catch (_) { /* gone */ } }
    await sleep(1500);
    const afterKill = await deadServices();
    assert('a killed service is detected', afterKill.length > 0, `down: ${afterKill.join(',') || 'NONE (probe blind)'}`);
    assert('the probe names the service that died', afterKill.includes('fake-backend'), `named: ${afterKill.join(',') || 'none'}`);

    // The verdict must refuse a run that scored fewer seeds than asked for, and must set a failing exit.
    const priorExit = process.exitCode;
    process.exitCode = 0;
    const verdict = await reportIntegrity(10, 4, Date.now() - 1000);
    assert('a short run is called NOT TRUSTWORTHY', verdict === false);
    assert('an untrustworthy run sets a failing exit code', process.exitCode === 2, `exitCode=${process.exitCode}`);
    process.exitCode = priorExit;

    // Outliving the service lifetime must be caught even when every seed was scored.
    process.exitCode = 0;
    const outlived = await reportIntegrity(1, 1, Date.now() - (DEP_TTL + 5) * 1000);
    assert('outliving the service lifetime is caught', outlived === false);
    process.exitCode = priorExit;

    const failed = checks.filter((c) => !c.pass);
    process.stdout.write(`\nSELF-CHECK: ${checks.length - failed.length}/${checks.length} passed\n`);
    if (failed.length) { process.stdout.write('the integrity checks CANNOT be trusted; fix them before citing any sweep\n'); process.exitCode = 3; }
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.worker) {
        const off = args.worker * 10;
        PORTS = { OLD: PORTS.OLD + off, NEW: PORTS.NEW + off, FAKE: PORTS.FAKE + off };
        args.data = `${args.data}-w${args.worker}`;
    }
    argsData = args.data;
    process.on('SIGINT', () => { teardown(); process.exit(130); });
    try {
        if (args.selfcheck && args.audit) { auditSelfCheck(); return; }
        if (args.selfcheck) { await runSelfCheck(args); return; }
        if (args.describe) { describeSeeds(args); return; }
        await bootRig(args);
        if (args.probe) { await probe(args.probe); return; }
        if (args.timed) { await runTimedBattery(args); return; }
        if (args.chunk4) { await runChunk4Battery(args); return; }
        if (args.trim) { await runTrimBattery(args); return; }
        if (args.measurepick) { await runMeasurePick(args); return; }
        if (args.mesraw) { await runMesRawBattery(args); return; }
        if (args.audit) { await runAudit(args); return; }
        if (args.fuzz) { await runFuzz(args); return; }
        await runBattery(args);
    } finally {
        if (!args.keep) teardown();
    }
}

main().catch((e) => { process.stderr.write(`parity-diff: ${e.stack || e.message}\n`); teardown(); process.exit(1); });

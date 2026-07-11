// Deterministic headless render capture for verify.sh: drive Chrome over CDP, POLL a caller-supplied
// completion predicate against the live DOM, dump HTML only once it holds. Replaces `chrome
// --dump-dom --virtual-time-budget=N`, which snapshots a pre-hydration DOM under load (checks read 0).
// Zero npm deps: Node global WebSocket + fetch (stable 22+; project pins >=26).
// Usage: node render.mjs --url URL --wait 'JS-EXPR' [--timeout MS] [--poll MS]
// Timeout still dumps the partial DOM (caller sees the real state) and exits 1, so a broken build FAILS.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function parseArgs(argv) {
    const out = { url: null, wait: null, timeout: 30000, poll: 100 };
    for (let i = 0; i < argv.length; i += 2) {
        const k = argv[i], v = argv[i + 1];
        if (k === '--url') out.url = v;
        else if (k === '--wait') out.wait = v;
        else if (k === '--timeout') out.timeout = Number(v);
        else if (k === '--poll') out.poll = Number(v);
        else { throw new Error(`unknown arg: ${k}`); }
    }
    if (!out.url || !out.wait) throw new Error('required: --url URL --wait JS-EXPR');
    return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One CDP session over the browser WebSocket, flatten mode: command replies correlate by id, target
// events carry a sessionId. A single map of pending id -> {resolve,reject} drives request/response.
class CDP {
    constructor(ws) {
        this.ws = ws;
        this.id = 0;
        this.pending = new Map();
        ws.addEventListener('message', (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.id === undefined) return; // an event, not a command reply
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
            else p.resolve(msg.result);
        });
        // A dropped socket or crashed target mid-poll must settle every in-flight send, or the awaiting
        // caller hangs forever and cleanup never runs.
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
    // remote-debugging-port=0 -> Chrome picks a free port and writes it to DevToolsActivePort. Own
    // process group (detached) so cleanup can group-kill the browser and its renderers together.
    const child = spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox',
        // Tall window so every fixture message is inside the viewport: the app uses content-visibility
        // to skip rendering off-screen messages, and a short window would leave the last (streamed) one
        // off-screen and unrendered, so its content would be absent from the dump.
        '--window-size=1400,9000',
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
    return child;
}

async function readDebugPort(profile, child, deadline) {
    const portFile = join(profile, 'DevToolsActivePort');
    while (Date.now() < deadline) {
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

async function main() {
    const args = parseArgs(process.argv.slice(2));
    const profile = mkdtempSync(join(tmpdir(), 'st-render-'));
    const child = launchChrome(profile);
    let ws = null;
    let timedOut = false;
    let cleaned = false;
    // Predicate is wrapped so a throw (element not present yet) reads as not-ready, never an error.
    const guarded = `(function(){try{return !!(${args.wait})}catch(_){return false}})()`;

    const cleanup = () => {
        if (cleaned) return;
        cleaned = true;
        try { if (ws) ws.close(); } catch (_) { /* already closed */ }
        try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* already gone */ }
        try { rmSync(profile, { recursive: true, force: true }); } catch (_) { /* best effort */ }
    };
    // Absolute backstop: even a hang the poll deadline cannot see (a send that never settles with no
    // socket close) must force a cleaned exit, so chrome and the temp profile never leak.
    const watchdog = setTimeout(() => {
        process.stderr.write(`render.mjs: HARD TIMEOUT after ${args.timeout + 5000}ms, forcing exit\n`);
        cleanup();
        process.exit(1);
    }, args.timeout + 5000);

    try {
        const startDeadline = Date.now() + Math.min(args.timeout, 15000);
        const port = await readDebugPort(profile, child, startDeadline);
        const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
        ws = await openWs(ver.webSocketDebuggerUrl);
        const cdp = new CDP(ws);

        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Runtime.enable', {}, sessionId);
        await cdp.send('Page.navigate', { url: args.url }, sessionId);

        const deadline = Date.now() + args.timeout;
        for (;;) {
            const r = await cdp.send('Runtime.evaluate',
                { expression: guarded, returnByValue: true }, sessionId);
            if (r.result && r.result.value === true) break;
            if (Date.now() >= deadline) { timedOut = true; break; }
            await sleep(args.poll);
        }

        const dom = await cdp.send('Runtime.evaluate',
            { expression: 'document.documentElement.outerHTML', returnByValue: true }, sessionId);
        process.stdout.write(dom.result && dom.result.value ? dom.result.value : '');
        if (timedOut) {
            process.stderr.write(`render.mjs: TIMEOUT after ${args.timeout}ms waiting for: ${args.wait}\n`);
        }
    } finally {
        clearTimeout(watchdog);
        cleanup();
    }
    process.exit(timedOut ? 1 : 0);
}

main().catch((err) => {
    process.stderr.write(`render.mjs: ${err.message}\n`);
    process.exit(2);
});

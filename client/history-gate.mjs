// Reader history-paging gate: drives the REAL reader pump against the mock 300-message chat, emits
// one JSON line (open-at-bottom, node survival, anchor drift) for verify.sh. Usage: node history-gate.mjs URL
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const URL = process.argv[2] || 'http://127.0.0.1:8942/';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class CDP {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.pending = new Map();
        ws.addEventListener('message', (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.id === undefined) return;
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
            else p.resolve(msg.result);
        });
        const failAll = (r) => { for (const [, p] of this.pending) p.reject(new Error(r)); this.pending.clear(); };
        ws.addEventListener('close', () => failAll('cdp closed'));
        ws.addEventListener('error', () => failAll('cdp error'));
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id; const frame = { id, method, params };
        if (sessionId) frame.sessionId = sessionId;
        return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject, method }); this.ws.send(JSON.stringify(frame)); });
    }
}

function launchChrome(profile) {
    return spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox', '--window-size=900,1200',
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
}
async function readPort(profile, child, deadline) {
    const f = join(profile, 'DevToolsActivePort');
    while (Date.now() < deadline) {
        if (child.exitCode !== null) throw new Error('chrome exited early');
        if (existsSync(f)) { const l = readFileSync(f, 'utf8').split('\n')[0].trim(); if (l) return l; }
        await sleep(50);
    }
    throw new Error('no DevToolsActivePort');
}
function openWs(url) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(url);
        ws.addEventListener('open', () => resolve(ws), { once: true });
        ws.addEventListener('error', () => reject(new Error('ws error')), { once: true });
    });
}

async function main() {
    const profile = mkdtempSync(join(tmpdir(), 'st-histgate-'));
    const child = launchChrome(profile);
    let ws = null;
    const cleanup = () => {
        try { if (ws) ws.close(); } catch (_) { /* */ }
        try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); } catch (_) { /* */ }
        try { rmSync(profile, { recursive: true, force: true }); } catch (_) { /* */ }
    };
    try {
        const port = await readPort(profile, child, Date.now() + 15000);
        const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
        ws = await openWs(ver.webSocketDebuggerUrl);
        const cdp = new CDP(ws);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Runtime.enable', {}, sessionId);
        await cdp.send('Page.navigate', { url: URL }, sessionId);

        const evalRaw = async (expr) => {
            const r = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, sessionId);
            if (r.exceptionDetails) throw new Error('eval: ' + (r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text));
            return r.result.value;
        };
        const waitFor = async (expr, ms = 20000) => {
            const dl = Date.now() + ms;
            for (;;) {
                if (await evalRaw(`(function(){try{return !!(${expr})}catch(_){return false}})()`)) return true;
                if (Date.now() > dl) throw new Error('timeout: ' + expr);
                await sleep(100);
            }
        };

        // Boot + auto-open of the mock 300-message chat.
        await waitFor('document.querySelector("#chat-root.hydrated") && window.__st_reader_scroll_bottom');
        await waitFor('document.querySelectorAll("#chat .mes").length >= 50');
        await sleep(400);

        const openAtBottom = await evalRaw(`(function(){
            var c=document.getElementById("chat");
            return (c.scrollHeight - c.scrollTop - c.clientHeight) < 80;
        })()`);

        // Tag every existing message, scroll to the top, and capture the on-screen anchor BEFORE the
        // async prepend resolves.
        const pre = await evalRaw(`(function(){
            var c=document.getElementById("chat");
            var mes=c.querySelectorAll(".mes");
            mes.forEach(function(e,i){ e.setAttribute("data-hg", String(i)); });
            c.scrollTop = 0;
            var top=c.getBoundingClientRect().top, anchor=null;
            for (var i=0;i<mes.length;i++){ if(mes[i].getBoundingClientRect().bottom > top+1){anchor=mes[i];break;} }
            if(!anchor) anchor = mes[mes.length-1];
            anchor.setAttribute("data-hg-anchor","1");
            window.__hgAnchorTop = anchor.getBoundingClientRect().top;
            window.__hgTagged = mes.length;
            return { tagged: mes.length, anchorTop: window.__hgAnchorTop };
        })()`);

        // Wait for a prepend to land and its correction to settle.
        await waitFor(`document.querySelectorAll("#chat .mes").length > ${pre.tagged} && !document.getElementById("chat-root").hasAttribute("data-reader-state")`, 15000);
        await sleep(400);

        const post = await evalRaw(`(function(){
            var c=document.getElementById("chat");
            var anchor=c.querySelector(".mes[data-hg-anchor]");
            return {
                survived: c.querySelectorAll(".mes[data-hg]").length,
                tagged: window.__hgTagged,
                finalCount: c.querySelectorAll(".mes").length,
                anchorPresent: !!anchor,
                anchorDrift: anchor ? Math.abs(anchor.getBoundingClientRect().top - window.__hgAnchorTop) : 999,
            };
        })()`);

        console.log(JSON.stringify({ openAtBottom, pre, post }));
    } finally {
        cleanup();
    }
}
main().catch((e) => { process.stderr.write('history-gate.mjs: ' + e.message + '\n'); process.exit(2); });

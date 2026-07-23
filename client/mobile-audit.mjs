// Headless mobile-layout audit for verify.sh: drive Chrome over CDP under a 390x844 phone emulation,
// open every top-bar panel, and assert the mobile invariants that a desktop render cannot see. A JSON
// report goes to stdout; the process exits 1 when any invariant is violated (so verify.sh fails).
// Zero npm deps: Node global WebSocket + fetch (stable 22+; project pins >=26). Sibling of render.mjs.
// Usage: node mobile-audit.mjs --url URL [--mode mobile|desktop] [--timeout MS]
// mobile (default): sweep every panel for the sliver regression + tap size + reachability + overflow
// scroll, plus 0 console errors. desktop: the console-error + horizontal-overflow guard only.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function parseArgs(argv) {
    const out = { url: null, mode: 'mobile', timeout: 45000, poll: 120 };
    for (let i = 0; i < argv.length; i += 2) {
        const k = argv[i], v = argv[i + 1];
        if (k === '--url') out.url = v;
        else if (k === '--mode') out.mode = v;
        else if (k === '--timeout') out.timeout = Number(v);
        else if (k === '--poll') out.poll = Number(v);
        else throw new Error(`unknown arg: ${k}`);
    }
    if (!out.url) throw new Error('required: --url URL');
    if (out.mode !== 'mobile' && out.mode !== 'desktop') throw new Error('--mode must be mobile or desktop');
    return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MOBILE = { width: 390, height: 844 };
const DESKTOP = { width: 1400, height: 900 };
// The top-level launchers, which are now the two edge tabs: the 13-button top bar they replaced is
// gone. Ids match the button element ids edgetabs.zx emits. The remaining panels have no launcher
// until the information-architecture move homes them, and gain rows when they do.
const PANEL_IDS = ['tab-setup', 'tab-cast'];
const TAP_MIN = 44;   // iOS minimum touch target, px
const WIDTH_MIN = 80; // an open mobile panel must fill at least this % of the viewport width
// verify.sh serves the static dist through devserve.py, which has no SillyTavern Express backend, so a
// request to a dynamic backend route (an avatar thumbnail, an api call) 404s BY DESIGN of the gate,
// not because anything is broken. A 404 whose path starts with one of these is exempt from the
// console-error check; any OTHER failed request (a missing dist asset: a font, css, wasm) still fails.
const BACKEND_ROUTES = ['/thumbnail', '/api/', '/characters', '/backgrounds', '/avatars', '/user', '/User', '/csrf'];

class CDP {
    constructor(ws) {
        this.ws = ws;
        this.id = 0;
        this.pending = new Map();
        ws.addEventListener('message', (ev) => {
            const m = JSON.parse(ev.data);
            if (m.id === undefined) return;
            const p = this.pending.get(m.id);
            if (!p) return;
            this.pending.delete(m.id);
            if (m.error) p.reject(new Error(`${p.method}: ${m.error.message}`));
            else p.resolve(m.result);
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

function launchChrome(profile) {
    return spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox',
        '--window-size=1400,9000',
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
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
    const vp = args.mode === 'mobile' ? MOBILE : DESKTOP;
    const profile = mkdtempSync(join(tmpdir(), 'st-mobile-'));
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
        process.stderr.write(`mobile-audit.mjs: HARD TIMEOUT after ${args.timeout + 5000}ms\n`);
        cleanup();
        process.exit(1);
    }, args.timeout + 5000);

    const report = { mode: args.mode, url: args.url, viewport: vp, violations: [], panels: [] };
    const fail = (id, detail) => report.violations.push({ id, detail });
    const consoleErrors = [];

    try {
        const startDeadline = Date.now() + Math.min(args.timeout, 15000);
        const port = await readDebugPort(profile, child, startDeadline);
        const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
        ws = await openWs(ver.webSocketDebuggerUrl);
        const cdp = new CDP(ws);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        const S = sessionId;
        await cdp.send('Page.enable', {}, S);
        await cdp.send('Runtime.enable', {}, S);
        await cdp.send('Log.enable', {}, S);
        await cdp.send('Network.enable', {}, S);
        const netErrors = [];
        // A JS exception or a console.error is always a real code error (the BigInt-boundary class of
        // crash lands here). A failed request carries its URL only on requestWillBeSent, so that url is
        // held per requestId and looked up on loadingFailed: without it an aborted request has an error
        // string where its url should be and cannot be told from a real missing dist asset. An abort of
        // a backend route (a thumbnail cancelled when the audit re-navigates) is then exempt like a 404.
        const reqUrl = new Map();
        ws.addEventListener('message', (ev) => {
            const m = JSON.parse(ev.data);
            if (m.method === 'Runtime.exceptionThrown') consoleErrors.push('exception: ' + (m.params?.exceptionDetails?.exception?.description || m.params?.exceptionDetails?.text || 'unknown'));
            else if (m.method === 'Runtime.consoleAPICalled' && m.params?.type === 'error') consoleErrors.push('console.error: ' + (m.params.args || []).map((a) => a.value ?? a.description ?? '').join(' '));
            else if (m.method === 'Log.entryAdded' && m.params?.entry?.level === 'error' && !/failed to load resource/i.test(m.params.entry.text || '')) consoleErrors.push('log: ' + m.params.entry.text);
            else if (m.method === 'Network.requestWillBeSent') reqUrl.set(m.params.requestId, m.params.request?.url || '');
            else if (m.method === 'Network.responseReceived' && m.params?.response?.status >= 400) netErrors.push({ status: m.params.response.status, url: m.params.response.url });
            else if (m.method === 'Network.loadingFailed' && m.params?.type !== 'Ping') netErrors.push({ status: m.params?.errorText || 'failed', url: reqUrl.get(m.params.requestId) || '' });
        });
        await cdp.send('Emulation.setDeviceMetricsOverride', { width: vp.width, height: vp.height, deviceScaleFactor: args.mode === 'mobile' ? 2 : 1, mobile: args.mode === 'mobile' }, S);
        if (args.mode === 'mobile') await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 }, S);

        const evalJS = async (expr) => {
            const r = await cdp.send('Runtime.evaluate', { expression: `(function(){try{return JSON.stringify(${expr})}catch(e){return JSON.stringify({__err:String(e)})}})()`, returnByValue: true }, S);
            return JSON.parse(r.result.value);
        };
        const navigate = async (url) => {
            await cdp.send('Page.navigate', { url }, S);
            const dl = Date.now() + Math.min(args.timeout, 25000);
            while (Date.now() < dl) {
                const ok = await evalJS(`!!(document.querySelector('#chat-root.hydrated') && document.querySelectorAll('#chat .mes').length>=12)`);
                if (ok === true) break;
                await sleep(args.poll);
            }
            await sleep(250);
        };

        await navigate(args.url);

        // No horizontal body overflow (a stray full-width child breaks a phone layout silently).
        const overflow = await evalJS(`({sw:document.documentElement.scrollWidth,cw:document.documentElement.clientWidth})`);
        report.overflowX = overflow.sw > overflow.cw + 1;
        if (report.overflowX) fail('no-horizontal-overflow', `scrollWidth ${overflow.sw} > clientWidth ${overflow.cw}`);

        if (args.mode === 'mobile') {
            // The launchers: on a coarse pointer the edge tabs never hide (there is no hover to reveal
            // them with), so each must be present, visible, a >=44px tap target, and fully on screen.
            const bar = await evalJS(`(()=>{const ids=${JSON.stringify(PANEL_IDS)};const btns=ids.map(id=>document.getElementById(id)).filter(Boolean);return{count:btns.length,buttons:btns.map(b=>{const r=b.getBoundingClientRect();const st=getComputedStyle(b);return{id:b.id,w:Math.round(r.width),h:Math.round(r.height),left:Math.round(r.left),right:Math.round(r.right),top:Math.round(r.top),opacity:Number(st.opacity),pointerEvents:st.pointerEvents};})};})()`);
            report.topbar = bar;
            if (bar.count !== PANEL_IDS.length) fail('topbar-count', `${bar.count} launchers, want ${PANEL_IDS.length}`);
            for (const b of bar.buttons || []) {
                if (b.w < TAP_MIN || b.h < TAP_MIN) fail('topbar-tap', `${b.id} is ${b.w}x${b.h}, want >=${TAP_MIN}`);
                if (b.left < -1 || b.right > vp.width + 1 || b.top < -1) fail('topbar-reachable', `${b.id} at [${b.left},${b.top},${b.right}] outside the viewport`);
                // Hidden behind a hover that a touch device cannot perform would leave no way in at all.
                if (b.opacity < 1 || b.pointerEvents === 'none') fail('topbar-tap', `${b.id} is not reachable on touch (opacity ${b.opacity}, pointer-events ${b.pointerEvents})`);
            }

            // Each panel: open it, measure, close it (the drawer button toggles). Reload only if a panel
            // fails to appear, so the common path stays fast.
            for (const pid of PANEL_IDS) {
                const opened = await evalJS(`(()=>{const b=document.getElementById('${pid}');if(!b)return false;b.click();return true;})()`);
                if (opened !== true) { await navigate(args.url); await evalJS(`(()=>{const b=document.getElementById('${pid}');b&&b.click();return true;})()`); }
                await sleep(320);
                const pr = await evalJS(`(()=>{const pv=document.querySelector('#panel-view');if(!pv)return{id:'${pid}',open:false};const r=pv.getBoundingClientRect();const scroller=[...pv.querySelectorAll('*')].find(el=>{const o=getComputedStyle(el).overflowY;return o==='auto'||o==='scroll';})||pv;const sc=getComputedStyle(scroller);const controls=[...pv.querySelectorAll('button,a[href],input,select,textarea,[tabindex]')].filter(el=>{const cr=el.getBoundingClientRect();const st=getComputedStyle(el);return st.display!=='none'&&st.visibility!=='hidden'&&(cr.width>0||cr.height>0);});const clipped=controls.filter(el=>{const cr=el.getBoundingClientRect();return cr.left<r.left-1||cr.right>r.right+1;}).length;return{id:'${pid}',open:true,wpct:Math.round(r.width/innerWidth*100),hpct:Math.round(r.height/innerHeight*100),left:Math.round(r.left),right:Math.round(r.right),top:Math.round(r.top),bottom:Math.round(r.bottom),overflowY:sc.overflowY,scrollableWhenOverflow:scroller.scrollHeight<=scroller.clientHeight+1||scroller.scrollHeight>scroller.clientHeight,controlCount:controls.length,clippedControls:clipped};})()`);
                report.panels.push(pr);
                if (!pr.open) { fail(`panel-open`, `${pid} did not open`); }
                else {
                    if (pr.wpct < WIDTH_MIN) fail('panel-width', `${pid} is ${pr.wpct}% wide, want >=${WIDTH_MIN}%`);
                    if (pr.left < -1 || pr.right > vp.width + 1 || pr.top < -1) fail('panel-inviewport', `${pid} rect [${pr.left},${pr.top},${pr.right},${pr.bottom}] clipped off-screen`);
                    if (pr.overflowY !== 'auto' && pr.overflowY !== 'scroll') fail('panel-scroll', `${pid} scroller overflow-y is ${pr.overflowY}, want auto/scroll`);
                    if (pr.clippedControls > 0) fail('panel-reachable', `${pid} has ${pr.clippedControls} control(s) clipped past the panel edge`);
                }
                // Close: the same drawer button toggles it shut. Verify closed before the next panel.
                await evalJS(`(()=>{const b=document.getElementById('${pid}');b&&b.click();return true;})()`);
                await sleep(200);
                const stillOpen = await evalJS(`!!document.querySelector('#panel-view')`);
                if (stillOpen === true) await navigate(args.url);
            }
        }

        report.consoleErrors = consoleErrors;
        if (consoleErrors.length > 0) fail('console-errors', `${consoleErrors.length}: ${consoleErrors.slice(0, 5).join(' | ')}`);
        const isBackend = (url) => { try { return BACKEND_ROUTES.some((r) => new URL(url).pathname.startsWith(r)); } catch (_) { return false; } };
        // ERR_ABORTED is a request the audit cancelled by re-navigating, never a missing file (a missing
        // dist asset returns a 404 response, caught above). It is harness noise regardless of the route.
        const isAbort = (e) => e.status === 'net::ERR_ABORTED';
        report.harnessBackend404 = netErrors.filter((e) => isBackend(e.url) || isAbort(e));
        report.missingAssets = netErrors.filter((e) => !isBackend(e.url) && !isAbort(e));
        if (report.missingAssets.length > 0) fail('missing-asset', report.missingAssets.slice(0, 5).map((e) => `${e.status} ${e.url}`).join(' | '));
    } catch (err) {
        fail('audit-error', err.message);
    } finally {
        clearTimeout(watchdog);
    }

    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
    cleanup();
    process.exit(report.violations.length > 0 ? 1 : 0);
}

main().catch((err) => {
    process.stderr.write(`mobile-audit.mjs: ${err.message}\n`);
    process.exit(2);
});

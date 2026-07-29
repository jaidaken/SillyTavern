// One-off debug probe: sample the edge tab + panel x during a CLOSE slide to prove whether the tab
// eases out with the panel or jumps after it. Standalone (own devserve + chrome + CDP). Not a gate.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const PORT = process.env.PORT || '8977';
const BASE = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const srv = spawn('python3', ['devserve.py', '--port', PORT, '--dist', 'dist', '--dev'],
    { stdio: 'ignore', detached: true });

const profile = mkdtempSync(join(tmpdir(), 'probe-'));
const chrome = spawn('google-chrome-stable', [
    '--headless', '--disable-gpu', '--no-sandbox',
    '--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4',
    '--window-size=1400,1000', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
], { detached: true, stdio: 'ignore' });

function cleanup() {
    try { process.kill(-srv.pid); } catch {}
    try { process.kill(-chrome.pid); } catch {}
}

async function main() {
    // wait for devserve
    for (let i = 0; i < 100; i++) {
        try { const r = await fetch(BASE + '/'); if (r.ok) break; } catch {}
        await sleep(100);
    }
    // read chrome debug port
    const portFile = join(profile, 'DevToolsActivePort');
    let wsPort;
    for (let i = 0; i < 100; i++) {
        if (existsSync(portFile)) { wsPort = readFileSync(portFile, 'utf8').split('\n')[0].trim(); break; }
        await sleep(50);
    }
    const listRes = await fetch(`http://127.0.0.1:${wsPort}/json/version`);
    const wsUrl = (await listRes.json()).webSocketDebuggerUrl;

    const ws = await new Promise((res, rej) => {
        const w = new WebSocket(wsUrl);
        w.addEventListener('open', () => res(w), { once: true });
        w.addEventListener('error', () => rej(new Error('ws err')), { once: true });
    });
    let id = 0; const pending = new Map();
    ws.addEventListener('message', (e) => {
        const m = JSON.parse(e.data);
        if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    });
    const send = (method, params, sessionId) => new Promise((res) => {
        const mid = ++id; pending.set(mid, res);
        ws.send(JSON.stringify({ id: mid, method, params, sessionId }));
    });

    const { result: { targetInfos } } = await send('Target.getTargets');
    let pageTarget = targetInfos.find((t) => t.type === 'page');
    const { result: { sessionId } } = await send('Target.attachToTarget', { targetId: pageTarget.targetId, flatten: true });
    await send('Page.enable', {}, sessionId);
    await send('Runtime.enable', {}, sessionId);

    const evalIn = async (expr) => {
        const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true }, sessionId);
        if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.text);
        return r.result?.result?.value;
    };

    await send('Page.navigate', { url: `${BASE}/?showtabs=1` }, sessionId);
    // wait hydrated
    for (let i = 0; i < 150; i++) {
        if (await evalIn(`!!document.querySelector('#chat-root.hydrated')`)) break;
        await sleep(100);
    }
    await sleep(400);

    const clickSel = async (sel) => {
        const box = await evalIn(`(function(){const e=document.querySelector('${sel}');const r=e.getBoundingClientRect();return {x:(r.left+r.right)/2,y:(r.top+r.bottom)/2};})()`);
        const b = { x: box.x, y: box.y, button: 'left', clickCount: 1, pointerType: 'mouse' };
        await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...b }, sessionId);
        await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...b }, sessionId);
    };
    const clickTab = () => clickSel('#tab-cast'); // RIGHT dock (Cast)

    // Right side: sample the Cast tab AND the notify bell (the element Jamie saw jump). rightEdge = the
    // element's distance from the viewport's right edge; both should ease together, no snap at commit.
    const probe = `(function(){
        const W = window.innerWidth;
        const re = (el) => el ? +(W - el.getBoundingClientRect().right).toFixed(1) : null;
        const tab=document.querySelector('#tab-cast');
        const bell=document.querySelector('#notify-bell');
        const panel=document.querySelector('.panel-right');
        const cs=getComputedStyle(document.documentElement);
        return {
            tabRight: re(tab),
            bellRight: re(bell),
            panelRight: re(panel),
            anim: cs.getPropertyValue('--dock-anim-right').trim(),
            dockW: cs.getPropertyValue('--dock-w-right').trim(),
        };
    })()`;

    // OPEN
    await clickTab();
    console.log('--- OPEN slide ---');
    for (let i = 0; i < 18; i++) { console.log(i*16, JSON.stringify(await evalIn(probe))); await sleep(16); }
    await sleep(300);
    console.log('OPEN settled:', JSON.stringify(await evalIn(probe)));

    // CLOSE
    await clickTab();
    console.log('--- CLOSE slide ---');
    for (let i = 0; i < 20; i++) { console.log(i*16, JSON.stringify(await evalIn(probe))); await sleep(16); }
    await sleep(300);
    console.log('CLOSE settled:', JSON.stringify(await evalIn(probe)));

    ws.close();
}

main().then(() => { cleanup(); process.exit(0); }).catch((e) => { console.error('PROBE ERR', e); cleanup(); process.exit(1); });

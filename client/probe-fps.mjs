// Measure the slide's real frame cadence: a page-side rAF loop records performance.now() + the tab's
// live translateX every frame during a CLOSE. Frame-to-frame deltas ~16.7ms = 60fps; ragged/33ms =
// dropped frames. Tells apart a Zig-loop bottleneck (ragged here) from GPU compositing (clean here,
// jank only on a real GPU browser). Standalone. Not a gate.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const PORT = process.env.PORT || '8978';
const BASE = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const srv = spawn('python3', ['devserve.py', '--port', PORT, '--dist', 'dist', '--dev'],
    { stdio: 'ignore', detached: true });
const profile = mkdtempSync(join(tmpdir(), 'probefps-'));
// NOTE: --disable-gpu means headless cannot show the compositing win; this probe only measures the
// JS/rAF cadence, i.e. whether the Zig loop itself keeps a steady frame budget.
const chrome = spawn('google-chrome-stable', [
    '--headless', '--disable-gpu', '--no-sandbox',
    '--window-size=1400,1000', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
], { detached: true, stdio: 'ignore' });

function cleanup() { try { process.kill(-srv.pid); } catch {} try { process.kill(-chrome.pid); } catch {} }

async function main() {
    for (let i = 0; i < 100; i++) { try { const r = await fetch(BASE + '/'); if (r.ok) break; } catch {} await sleep(100); }
    const portFile = join(profile, 'DevToolsActivePort');
    let wsPort;
    for (let i = 0; i < 100; i++) { if (existsSync(portFile)) { wsPort = readFileSync(portFile, 'utf8').split('\n')[0].trim(); break; } await sleep(50); }
    const wsUrl = (await (await fetch(`http://127.0.0.1:${wsPort}/json/version`)).json()).webSocketDebuggerUrl;
    const ws = await new Promise((res, rej) => { const w = new WebSocket(wsUrl); w.addEventListener('open', () => res(w), { once: true }); w.addEventListener('error', () => rej(new Error('ws')), { once: true }); });
    let id = 0; const pending = new Map();
    ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
    const send = (method, params, sessionId) => new Promise((res) => { const mid = ++id; pending.set(mid, res); ws.send(JSON.stringify({ id: mid, method, params, sessionId })); });

    const { result: { targetInfos } } = await send('Target.getTargets');
    const { result: { sessionId } } = await send('Target.attachToTarget', { targetId: targetInfos.find((t) => t.type === 'page').targetId, flatten: true });
    await send('Page.enable', {}, sessionId); await send('Runtime.enable', {}, sessionId);
    const evalIn = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }, sessionId); if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.text); return r.result?.result?.value; };

    await send('Page.navigate', { url: `${BASE}/?showtabs=1` }, sessionId);
    for (let i = 0; i < 150; i++) { if (await evalIn(`!!document.querySelector('#chat-root.hydrated')`)) break; await sleep(100); }
    await sleep(400);

    const clickTab = async () => {
        const box = await evalIn(`(function(){const e=document.querySelector('#tab-setup');const r=e.getBoundingClientRect();return {x:(r.left+r.right)/2,y:(r.top+r.bottom)/2};})()`);
        const b = { x: box.x, y: box.y, button: 'left', clickCount: 1, pointerType: 'mouse' };
        await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...b }, sessionId);
        await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...b }, sessionId);
    };

    await clickTab(); // open
    await sleep(400);

    // Start a page-side rAF recorder, THEN trigger close, so we capture the close frames.
    await evalIn(`(function(){
        window.__frames = [];
        const tab = document.querySelector('#tab-setup');
        function tx(){ const m = new DOMMatrixReadOnly(getComputedStyle(tab).transform); return m.m41; }
        let last = performance.now();
        function loop(t){
            window.__frames.push({ t: +(t).toFixed(2), dt: +(t-last).toFixed(2), tx: +tx().toFixed(1) });
            last = t;
            if (window.__frames.length < 90) requestAnimationFrame(loop);
        }
        requestAnimationFrame(loop);
    })()`);
    await sleep(30);
    await clickTab(); // close
    await sleep(1500);

    const frames = await evalIn(`window.__frames`);
    // Only the frames where tx is actually moving = the slide window.
    const moving = frames.filter((f, i) => i > 0 && Math.abs(f.tx - frames[i-1].tx) > 0.05);
    const dts = moving.map((f) => f.dt);
    const stats = (arr) => { const s = [...arr].sort((a,b)=>a-b); const mean = arr.reduce((a,b)=>a+b,0)/arr.length; return { n: arr.length, min: s[0], p50: s[(s.length/2)|0], p95: s[Math.min(s.length-1,(s.length*0.95)|0)], max: s[s.length-1], mean: +mean.toFixed(2) }; };
    console.log('SLIDE frame count:', moving.length);
    console.log('frame dt stats (ms):', JSON.stringify(stats(dts)));
    console.log('dropped frames (dt>20ms):', dts.filter((d)=>d>20).length, 'of', dts.length);
    console.log('--- per-frame (dt, translateX) during slide ---');
    for (const f of moving) console.log(`dt=${f.dt}ms tx=${f.tx}`);

    ws.close();
}
main().then(() => { cleanup(); process.exit(0); }).catch((e) => { console.error('ERR', e); cleanup(); process.exit(1); });

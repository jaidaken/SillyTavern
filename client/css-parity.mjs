// Computed-style parity oracle for the utility-to-semantic CSS conversion.
//
// Moving a class attribute from utility tokens to a semantic name is supposed to change the STYLESHEET
// and nothing a browser renders. Nothing in the build can prove that: the class gate proves every class
// resolves to some rule, not that the rules still compute to the same values, and a screenshot compares
// pixels through anti-aliasing noise. So this walks the live DOM in a set of app states and records the
// FULL computed style of every element against a structural path, which a class rename cannot move.
// Capture before a conversion, capture after, diff: any property whose computed value moved is a
// regression, named with its element and both values.
//
// Usage: node css-parity.mjs --out FILE [--port N]
//        node css-parity.mjs --compare BEFORE AFTER [--max N]
//        node css-parity.mjs --selfcheck [--port N]      (capture twice, diff; must be 0)

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
    const i = args.indexOf(name);
    return i === -1 ? fallback : args[i + 1];
};
const has = (name) => args.includes(name);

const PORT = flag('--port', process.env.PORT || '8971');
const BASE = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A path a class rename cannot move: tag plus position among its siblings, root downward. Ids are used
// where present because they survive a sibling count changing, which a conversion should never do but a
// merge might.
const PATH_FN = `(function pathOf(el){
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
        if (n.id) { parts.unshift('#' + n.id); break; }
        let i = 1;
        for (let s = n.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === n.tagName) i++;
        parts.unshift(n.tagName.toLowerCase() + ':' + i);
    }
    return parts.join('>');
})`;

// Chrome returns "" for a computed style's cssText, so the declarations are enumerated by index. The
// property list is read once off the first element: it is the same for every element in a document.
const CAPTURE = `(function(){
    const pathOf = ${PATH_FN};
    const first = getComputedStyle(document.body);
    const props = [];
    for (let i = 0; i < first.length; i++) props.push(first.item(i));
    if (props.length < 100) throw new Error('computed style enumerated only ' + props.length + ' properties');
    const out = {};
    for (const el of document.body.querySelectorAll('*')) {
        if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE' || el.tagName === 'LINK') continue;
        const cs = getComputedStyle(el);
        const parts = [];
        for (const p of props) parts.push(p + ': ' + cs.getPropertyValue(p));
        out[pathOf(el)] = parts.join('; ');
    }
    out['body'] = props.map((p) => p + ': ' + first.getPropertyValue(p)).join('; ');
    return out;
})()`;

// The states worth capturing: every surface whose markup carries utility classes. Each is a click path
// from a freshly loaded page, so one state's leftovers cannot leak into the next.
const STATES = [
    { name: 'base', clicks: [] },
    { name: 'dock-left', clicks: ['#tab-setup'] },
    { name: 'dock-right', clicks: ['#tab-cast'] },
    { name: 'sysmenu', clicks: ['#sys-gear'] },
    { name: 'notify', clicks: ['#notify-bell'] },
];

async function connect() {
    const srv = spawn('python3', ['devserve.py', '--port', PORT, '--dist', 'dist', '--dev'],
        { stdio: 'ignore', detached: true });
    const profile = mkdtempSync(join(tmpdir(), 'cssparity-'));
    const chrome = spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox',
        '--window-size=1400,1000', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });

    const cleanup = () => {
        try { process.kill(-srv.pid); } catch { /* already gone */ }
        try { process.kill(-chrome.pid); } catch { /* already gone */ }
        try { rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
    };

    for (let i = 0; i < 150; i++) {
        try { const r = await fetch(BASE + '/'); if (r.ok) break; } catch { /* not up yet */ }
        await sleep(100);
    }
    const portFile = join(profile, 'DevToolsActivePort');
    let wsPort;
    for (let i = 0; i < 150; i++) {
        if (existsSync(portFile)) { wsPort = readFileSync(portFile, 'utf8').split('\n')[0].trim(); break; }
        await sleep(50);
    }
    if (!wsPort) { cleanup(); throw new Error('chrome never published a debug port'); }
    const wsUrl = (await (await fetch(`http://127.0.0.1:${wsPort}/json/version`)).json()).webSocketDebuggerUrl;
    const ws = await new Promise((res, rej) => {
        const w = new WebSocket(wsUrl);
        w.addEventListener('open', () => res(w), { once: true });
        w.addEventListener('error', () => rej(new Error('devtools websocket refused')), { once: true });
    });
    let id = 0;
    const pending = new Map();
    ws.addEventListener('message', (e) => {
        const m = JSON.parse(e.data);
        if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    });
    const send = (method, params, sessionId) => new Promise((res) => {
        const mid = ++id;
        pending.set(mid, res);
        ws.send(JSON.stringify({ id: mid, method, params, sessionId }));
    });
    const { result: { targetInfos } } = await send('Target.getTargets');
    const page = targetInfos.find((t) => t.type === 'page');
    const { result: { sessionId } } = await send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
    await send('Page.enable', {}, sessionId);
    await send('Runtime.enable', {}, sessionId);

    const evalIn = async (expr) => {
        const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true }, sessionId);
        if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.text);
        return r.result?.result?.value;
    };
    const click = async (sel) => {
        const box = await evalIn(`(function(){const e=document.querySelector(${JSON.stringify(sel)});`
            + `if(!e)return null;const r=e.getBoundingClientRect();return {x:(r.left+r.right)/2,y:(r.top+r.bottom)/2};})()`);
        if (!box) return false;
        const b = { x: box.x, y: box.y, button: 'left', clickCount: 1, pointerType: 'mouse' };
        await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...b }, sessionId);
        await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...b }, sessionId);
        return true;
    };
    return { evalIn, click, send, sessionId, ws, cleanup };
}

async function settle(conn) {
    for (let i = 0; i < 60; i++) {
        const quiet = await conn.evalIn(`!document.querySelector('#chat-root.revealing')`
            + ` && document.getAnimations().every(function(a){return a.playState !== 'running';})`);
        if (quiet) { await sleep(120); return; }
        await sleep(100);
    }
    throw new Error('animations never settled');
}

async function capture(conn) {
    const shot = {};
    for (const state of STATES) {
        await conn.send('Page.navigate', { url: `${BASE}/?demo=1&showtabs=1` }, conn.sessionId);
        let ready = false;
        for (let i = 0; i < 200; i++) {
            if (await conn.evalIn(`!!document.querySelector('#chat-root.hydrated')`)) { ready = true; break; }
            await sleep(100);
        }
        if (!ready) throw new Error(`state ${state.name}: page never hydrated`);
        // Motion off before anything opens, so no capture lands mid-slide and the values are the
        // resting ones a reader actually sees.
        await conn.evalIn(`(function(){const s=document.getElementById('shell');`
            + `if(s){s.classList.remove('motion-on');s.classList.add('motion-off');}})()`);
        // The staggered load reveal runs animation-delay out to 1.3s, and an opacity sampled part way
        // through it differs between two otherwise identical runs. Wait it out by state, not by clock.
        await settle(conn);
        for (const sel of state.clicks) {
            if (!await conn.click(sel)) throw new Error(`state ${state.name}: ${sel} not present`);
            await settle(conn);
        }
        const snap = await conn.evalIn(CAPTURE);
        // A capture that came back empty compares equal to any other empty capture, which reads as a
        // clean run while proving nothing. Refuse it here rather than let it pass as a green diff.
        const thin = Object.values(snap).filter((v) => v.length < 100).length;
        if (thin) throw new Error(`state ${state.name}: ${thin} elements captured no computed style`);
        shot[state.name] = snap;
    }
    return shot;
}

function compare(before, after, max) {
    let elementsChecked = 0;
    let propsDiffering = 0;
    let onlyBefore = 0;
    let onlyAfter = 0;
    const lines = [];
    for (const state of Object.keys(before)) {
        const a = before[state];
        const b = after[state] || {};
        for (const path of Object.keys(a)) {
            if (!(path in b)) { onlyBefore++; continue; }
            elementsChecked++;
            if (a[path] === b[path]) continue;
            const pa = Object.fromEntries(a[path].split('; ').filter(Boolean).map((d) => {
                const i = d.indexOf(': ');
                return [d.slice(0, i), d.slice(i + 2)];
            }));
            const pb = Object.fromEntries(b[path].split('; ').filter(Boolean).map((d) => {
                const i = d.indexOf(': ');
                return [d.slice(0, i), d.slice(i + 2)];
            }));
            for (const k of new Set([...Object.keys(pa), ...Object.keys(pb)])) {
                if (pa[k] === pb[k]) continue;
                propsDiffering++;
                if (lines.length < max) lines.push(`  ${state} ${path}\n      ${k}: ${pa[k]} -> ${pb[k]}`);
            }
        }
        for (const path of Object.keys(b)) if (!(path in a)) onlyAfter++;
    }
    return { elementsChecked, propsDiffering, onlyBefore, onlyAfter, lines };
}

async function main() {
    if (has('--compare')) {
        const i = args.indexOf('--compare');
        const before = JSON.parse(readFileSync(args[i + 1], 'utf8'));
        const after = JSON.parse(readFileSync(args[i + 2], 'utf8'));
        const r = compare(before, after, Number(flag('--max', '40')));
        console.log(`css-parity: ${r.elementsChecked} elements compared across ${Object.keys(before).length} states`);
        console.log(`  properties differing: ${r.propsDiffering}`);
        console.log(`  elements only in before: ${r.onlyBefore}   only in after: ${r.onlyAfter}`);
        for (const ln of r.lines) console.log(ln);
        const clean = r.propsDiffering === 0 && r.onlyBefore === 0 && r.onlyAfter === 0;
        console.log(clean ? 'css-parity: PASS (nothing a browser renders moved)' : 'css-parity: FAIL');
        process.exit(clean ? 0 : 1);
    }

    const conn = await connect();
    try {
        if (has('--selfcheck')) {
            const first = await capture(conn);
            const second = await capture(conn);
            const r = compare(first, second, 20);
            console.log(`css-parity selfcheck: ${r.elementsChecked} elements, ${r.propsDiffering} unstable properties`);
            for (const ln of r.lines) console.log(ln);
            conn.ws.close();
            conn.cleanup();
            process.exit(r.propsDiffering === 0 && r.onlyBefore === 0 && r.onlyAfter === 0 ? 0 : 1);
        }
        const shot = await capture(conn);
        const out = flag('--out');
        writeFileSync(out, JSON.stringify(shot));
        const n = Object.values(shot).reduce((s, st) => s + Object.keys(st).length, 0);
        console.log(`css-parity: captured ${n} elements across ${Object.keys(shot).length} states -> ${out}`);
        conn.ws.close();
        conn.cleanup();
        process.exit(0);
    } catch (e) {
        conn.ws.close();
        conn.cleanup();
        throw e;
    }
}

main().catch((e) => { console.error('css-parity ERR', e); process.exit(1); });

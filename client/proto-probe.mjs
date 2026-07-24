// PROTOTYPE probe, disposable. Answers the one thing a screenshot cannot: does the edge-tab reveal
// zone eat clicks? Drives real Chrome over CDP and hit-tests the flank with document.elementFromPoint,
// the same test the browser runs when a click lands. Usage: node proto-probe.mjs --base http://host:port

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const base = (() => {
    const i = process.argv.indexOf('--base');
    if (i < 0) throw new Error('required: --base URL');
    return process.argv[i + 1];
})();

const W = 1440, H = 900;

function launchChrome(profile) {
    // Headless reports a coarse pointer by default, which flips the tabs to their always-visible touch
    // rule and hides the very behaviour under probe. These blink settings make it a fine pointer.
    const child = spawn('google-chrome-stable', [
        '--headless', '--disable-gpu', '--no-sandbox',
        '--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4',
        `--window-size=${W},${H}`,
        `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
    ], { detached: true, stdio: 'ignore' });
    child.on('error', (err) => { child.spawnError = err; });
    return child;
}

class Cdp {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.pending = new Map();
        ws.addEventListener('message', (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.id && this.pending.has(msg.id)) {
                const { resolve, reject } = this.pending.get(msg.id);
                this.pending.delete(msg.id);
                if (msg.error) reject(new Error(JSON.stringify(msg.error)));
                else resolve(msg.result);
            }
        });
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id;
        const frame = { id, method, params };
        if (sessionId) frame.sessionId = sessionId;
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            this.ws.send(JSON.stringify(frame));
        });
    }
}

const profile = mkdtempSync(join(tmpdir(), 'p2-probe-'));
const child = launchChrome(profile);
let failures = 0;
const check = (name, ok, detail) => {
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`);
    if (!ok) failures++;
};

try {
    const portFile = join(profile, 'DevToolsActivePort');
    const deadline = Date.now() + 20000;
    let port = null;
    while (Date.now() < deadline && !port) {
        if (existsSync(portFile)) port = readFileSync(portFile, 'utf8').split('\n')[0].trim();
        else await sleep(50);
    }
    if (!port) throw new Error('chrome never wrote DevToolsActivePort');
    const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const ws = await new Promise((resolve, reject) => {
        const sock = new WebSocket(ver.webSocketDebuggerUrl);
        sock.addEventListener('open', () => resolve(sock), { once: true });
        sock.addEventListener('error', () => reject(new Error('cdp ws error')), { once: true });
    });
    const cdp = new Cdp(ws);
    const targets = await cdp.send('Target.getTargets');
    const page = targets.targetInfos.find((t) => t.type === 'page');
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Emulation.setDeviceMetricsOverride',
        { width: W, height: H, deviceScaleFactor: 1, mobile: false }, sessionId);

    const evaluate = async (expression) => {
        const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
        if (r.exceptionDetails) throw new Error(`eval threw: ${r.exceptionDetails.text}`);
        return r.result ? r.result.value : undefined;
    };
    const waitFor = async (expr, ms = 15000) => {
        const stop = Date.now() + ms;
        for (;;) {
            if (await evaluate(`(function(){try{return !!(${expr})}catch(_){return false}})()`)) return true;
            if (Date.now() >= stop) return false;
            await sleep(100);
        }
    };
    // Settle past the tab's own 200ms opacity transition, not just the rAF coalesce plus re-render:
    // sampling earlier reads a mid-fade 0.96 and calls a working reveal a failure.
    const move = async (x, y) => {
        await cdp.send('Input.dispatchMouseEvent',
            { type: 'mouseMoved', x, y, buttons: 0, pointerType: 'mouse' }, sessionId);
        await sleep(450);
    };
    const clickAt = async (x, y) => {
        for (const type of ['mousePressed', 'mouseReleased']) {
            await cdp.send('Input.dispatchMouseEvent',
                {
                    type, x, y, button: 'left', clickCount: 1,
                    buttons: type === 'mousePressed' ? 1 : 0, pointerType: 'mouse',
                }, sessionId);
        }
        await sleep(250);
    };
    const opacity = (id) => evaluate(`(function(){const e=document.getElementById(${JSON.stringify(id)});return e?getComputedStyle(e).opacity:'missing'})()`);
    const hitAt = (x, y) => evaluate(`(function(){const e=document.elementFromPoint(${x},${y});return e?(e.id||e.className||e.tagName):'none'})()`);

    await cdp.send('Page.navigate', { url: `${base}/?demo` }, sessionId);
    const up = await waitFor(`document.querySelector('#tab-setup') && document.querySelector('#chat')`);
    check('page hydrated, both tabs present', up);

    // 1. Pointer parked in the middle: neither flank entered, so both tabs are faded out.
    await move(720, 450);
    const hiddenL = await opacity('tab-setup');
    const hiddenR = await opacity('tab-cast');
    check('tabs hidden with the pointer centred', hiddenL === '0' && hiddenR === '0', `left=${hiddenL} right=${hiddenR}`);

    // 2. The hidden tab's own square hit-tests through to the page underneath.
    const tabBox = await evaluate(`(function(){const r=document.getElementById('tab-setup').getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}})()`);
    const overTab = await hitAt(tabBox.x, tabBox.y);
    check('hidden tab does not hit-test', !String(overTab).includes('tab-setup'), `elementFromPoint=${overTab} at ${tabBox.x},${tabBox.y}`);

    // 3. A real click on that square does not toggle the panel (the old hover zone swallowed it).
    await clickAt(tabBox.x, tabBox.y);
    const openedByGhost = await evaluate(`!!document.querySelector('#panel-view')`);
    check('click on the hidden tab square opens nothing', !openedByGhost);
    await move(720, 450);

    // 4. Sweep the whole left flank: no point in it may resolve to a tab or a full-band overlay.
    const grid = [];
    for (const x of [10, 80, 160, 240, 320, 395]) for (const y of [70, 200, 400, 600, 780]) grid.push([x, y]);
    const hits = [];
    for (const [x, y] of grid) hits.push(`${x},${y}=${await hitAt(x, y)}`);
    const eaten = hits.filter((h) => h.includes('tab-setup') || h.includes('tab-cast'));
    check('no tab element anywhere in the left flank grid', eaten.length === 0, eaten.join(' | ') || `${grid.length} points clear`);
    console.log('     flank hit sample:', hits.slice(0, 6).join('  '));

    // 5. The reveal fires far from the tab, and fades again when the pointer leaves the flank.
    await move(380, 620);
    const shownL = await opacity('tab-setup');
    const stillHiddenR = await opacity('tab-cast');
    check('left tab reveals from deep inside the flank (380,620)', shownL === '1', `opacity=${shownL}`);
    check('right tab stays hidden meanwhile', stillHiddenR === '0', `opacity=${stillHiddenR}`);
    await move(720, 450);
    const fadedL = await opacity('tab-setup');
    check('left tab fades when the pointer leaves the flank', fadedL === '0', `opacity=${fadedL}`);

    // 6. Mirror side.
    await move(W - 380, 620);
    const shownR = await opacity('tab-cast');
    check('right tab reveals from deep inside the right flank', shownR === '1', `opacity=${shownR}`);

    // 7. Above the top bar and below the composer the flank is dead, per the locked spec.
    await move(200, 20);
    const topDead = await opacity('tab-setup');
    check('top bar band does not reveal', topDead === '0', `opacity=${topDead}`);
    await move(200, H - 20);
    const bottomDead = await opacity('tab-setup');
    check('composer band does not reveal', bottomDead === '0', `opacity=${bottomDead}`);

    // 8. Revealed, the tab is a real button again.
    await move(300, 400);
    await clickAt(tabBox.x, tabBox.y);
    const opened = await evaluate(`!!document.querySelector('#panel-view')`);
    check('revealed tab opens its panel on click', opened);

    // 9. The resize drag: the tab must track the panel edge at pointer rate, not jump on release.
    await waitFor(`document.querySelector('#panel-view.panel-left .panel-resize')`);
    const sep = await evaluate(`(function(){const r=document.querySelector('#panel-view.panel-left .panel-resize').getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}})()`);
    const edges = () => evaluate(`(function(){
        const p = document.querySelector('#panel-view.panel-left').getBoundingClientRect();
        const t = document.getElementById('tab-setup').getBoundingClientRect();
        return {panelRight: p.right, tabLeft: t.left};
    })()`);
    // A shell re-render would show up as DOM mutations; a correct drag writes one custom property on
    // <html>, which is outside this subtree, so the count must stay at zero.
    await evaluate(`(function(){
        window.__probeMutations = 0;
        window.__probeObs = new MutationObserver((recs) => { window.__probeMutations += recs.length; });
        window.__probeObs.observe(document.getElementById('shell'), { subtree: true, childList: true, attributes: true, characterData: true });
    })()`);

    const before = await edges();
    await cdp.send('Input.dispatchMouseEvent',
        { type: 'mousePressed', x: sep.x, y: sep.y, button: 'left', clickCount: 1, buttons: 1, pointerType: 'mouse' }, sessionId);
    // Zero the counter after the press: pointerdown legitimately adds the is-dragging class. What is
    // being measured is the per-move cost, which must be no DOM work inside the shell at all.
    await sleep(80);
    await evaluate(`window.__probeMutations = 0`);
    const samples = [];
    for (const dx of [40, 90, 140]) {
        await cdp.send('Input.dispatchMouseEvent',
            { type: 'mouseMoved', x: sep.x + dx, y: sep.y, button: 'left', buttons: 1, pointerType: 'mouse' }, sessionId);
        await sleep(80);
        samples.push({ dx, ...(await edges()) });
    }
    const tracked = samples.every((s) => Math.abs(s.tabLeft - s.panelRight) <= 1);
    const moved = Math.abs(samples[samples.length - 1].panelRight - before.panelRight) > 20;
    check('tab tracks the panel edge at every point during the drag', tracked && moved,
        samples.map((s) => `+${s.dx}: panel ${Math.round(s.panelRight)} tab ${Math.round(s.tabLeft)}`).join(' | '));

    const midDragMutations = await evaluate(`window.__probeMutations`);
    check('no shell DOM work per pointer move (3 moves)', midDragMutations === 0, `mutations=${midDragMutations}`);

    await cdp.send('Input.dispatchMouseEvent',
        { type: 'mouseReleased', x: sep.x + 140, y: sep.y, button: 'left', clickCount: 1, buttons: 0, pointerType: 'mouse' }, sessionId);
    await sleep(250);
    const after = await edges();
    const last = samples[samples.length - 1];
    const jump = Math.max(Math.abs(after.panelRight - last.panelRight), Math.abs(after.tabLeft - last.tabLeft));
    check('nothing jumps when the drag is released', jump <= 1, `jump=${jump.toFixed(2)}px`);
    check('tab still sits on the panel edge after release', Math.abs(after.tabLeft - after.panelRight) <= 1,
        `panel ${Math.round(after.panelRight)} tab ${Math.round(after.tabLeft)}`);
    await evaluate(`window.__probeObs.disconnect()`);

    // Close the panel so its resized width does not skew the flank geometry for the checks below.
    await evaluate(`(function(){const b=document.getElementById('tab-setup');b&&b.click();})()`);
    await sleep(250);

    // 10. The band's bottom edge tracks the composer as it grows. A multi-line message makes the
    // textarea taller, lifting the composer's top; the excluded composer band must follow it live, or
    // a point that is now over the composer would still reveal off a stale cached bound.
    const composerTop = () => evaluate(`document.getElementById('composer').getBoundingClientRect().top`);
    const grownTop = await evaluate(`(function(){
        const ta = document.getElementById('send_textarea');
        ta.value = Array.from({length: 8}, (_, i) => 'line ' + (i + 1)).join('\\n');
        ta.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
    })()`);
    await sleep(200);
    const cTop = await composerTop();
    const baseTop = 829; // the single-line composer top measured earlier this run
    check('the composer grew, lifting its top edge', cTop < baseTop - 20, `composer top ${Math.round(cTop)} (was ~${baseTop})`);
    // A point now sitting OVER the grown composer must not reveal: the band bottom followed it up.
    await move(200, Math.round(cTop) + 15);
    const overGrownComposer = await opacity('tab-setup');
    check('a point over the grown composer does not reveal (band bottom tracked it)', overGrownComposer === '0', `opacity=${overGrownComposer} at y=${Math.round(cTop) + 15}`);
    // Just above the grown composer still reveals: the band ends exactly at the live composer top.
    await move(200, Math.round(cTop) - 25);
    const aboveGrownComposer = await opacity('tab-setup');
    check('just above the grown composer still reveals', aboveGrownComposer === '1', `opacity=${aboveGrownComposer} at y=${Math.round(cTop) - 25}`);
    await move(720, 450);
    await evaluate(`(function(){const ta=document.getElementById('send_textarea');ta.value='';ta.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await sleep(150);

    // 11. Coarse pointer / touch: there is no hover to reveal a tab with, so both tabs must be
    // standing, visible, and tappable WITHOUT any pointer movement, and a tap must open the panel.
    await cdp.send('Emulation.setEmulatedMedia',
        { features: [{ name: 'pointer', value: 'coarse' }, { name: 'hover', value: 'none' }] }, sessionId);
    await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 }, sessionId);
    await cdp.send('Page.navigate', { url: `${base}/?demo` }, sessionId);
    await waitFor(`document.querySelector('#tab-setup') && document.querySelector('#chat')`);
    await sleep(300);
    const coarse = await evaluate(`(function(){
        return ['tab-setup','tab-cast'].map(function(id){
            const e = document.getElementById(id);
            const r = e.getBoundingClientRect();
            const st = getComputedStyle(e);
            return {id: id, opacity: Number(st.opacity), pe: st.pointerEvents, w: Math.round(r.width), h: Math.round(r.height)};
        });
    })()`);
    const bothStanding = coarse.every((c) => c.opacity === 1 && c.pe !== 'none');
    check('coarse pointer: both tabs stand visible with no hover', bothStanding, coarse.map((c) => `${c.id} op${c.opacity} pe:${c.pe}`).join(' | '));
    const bigEnough = coarse.every((c) => c.w >= 44 && c.h >= 44);
    check('coarse pointer: both tabs meet the 44px tap target', bigEnough, coarse.map((c) => `${c.id} ${c.w}x${c.h}`).join(' | '));
    await clickAt(coarse[0].w / 2 + 2, await evaluate(`document.getElementById('tab-setup').getBoundingClientRect().top + 20`));
    const coarseOpened = await evaluate(`!!document.querySelector('#panel-view')`);
    check('coarse pointer: a tap opens the panel', coarseOpened);
    await cdp.send('Emulation.setEmulatedMedia', { features: [] }, sessionId);
    await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: false }, sessionId);

    const zone = await evaluate(`(function(){
        const t = document.getElementById('topbar').getBoundingClientRect();
        const c = document.getElementById('composer').getBoundingClientRect();
        const w = window.innerWidth;
        const flank = Math.min(Math.max(w * 0.28, 200), w * 0.45);
        return {w: w, h: window.innerHeight, top: t.bottom, bottom: c.top, flank: flank};
    })()`);
    console.log(`     viewport ${zone.w}x${zone.h} | band y ${zone.top}..${zone.bottom} | flank ${zone.flank}px each side`);
} finally {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch { /* already gone */ } }
    rmSync(profile, { recursive: true, force: true });
}

console.log(failures === 0 ? 'PROBE GREEN' : `PROBE RED (${failures} failing)`);
process.exit(failures === 0 ? 0 : 1);

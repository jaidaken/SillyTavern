// Mutation harness for the ziex door's DOM-glue guards (D2 in patch-door.sh). Forces each guard's
// condition true in a real DOM and asserts the verbatim console text: a guard nobody can force red
// is decoration (notes/gate-rows-that-can-fail.md). Slices the glue + helpers out of the PATCHED
// door verbatim, so it tests shipped bytes or fails to slice.
//
// DOES NOT PROVE: it drives the glue directly with synthetic ids, so it never proves the zig side
// calls these ops in these sequences. Green = the guards work, NOT that the app is drift-free.
//
// Usage: node door-guard-probe.mjs [patched-unminified-door]
//   default: zig-out/static/vendor/ziex/wasm/index.js, patched into a temp copy via ./patch-door.sh
// Exit 0 = every guard fired as expected. Exit 1 = a guard did not fire, or fired wrong.

import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function patchedDoorText(argPath) {
    if (argPath) return readFileSync(argPath, 'utf8');
    const src = resolve(HERE, 'zig-out/static/vendor/ziex/wasm/index.js');
    if (!existsSync(src)) {
        throw new Error(`door not found at ${src} (run ./build.sh first, or pass a path)`);
    }
    // Patch a COPY: the probe must never mutate a build artifact.
    const tmp = join(mkdtempSync(join(tmpdir(), 'zx-door-')), 'index.js');
    copyFileSync(src, tmp);
    execFileSync(resolve(HERE, 'patch-door.sh'), [tmp], { stdio: 'pipe' });
    return readFileSync(tmp, 'utf8');
}

function sliceOut(src, startMarker, endMarker, label) {
    const a = src.indexOf(startMarker);
    if (a < 0) throw new Error(`probe: start marker not found for ${label}; door changed, update this probe`);
    const b = src.indexOf(endMarker, a);
    if (b < 0) throw new Error(`probe: end marker not found for ${label}; door changed, update this probe`);
    return src.slice(a, b + endMarker.length);
}

function buildPage(door) {
    const glue = sliceOut(door, '        _ce: (id, vnodeId) => {', '        _getLocationHref:', 'glue');
    const glueBody = glue.slice(0, glue.lastIndexOf('        _getLocationHref:'));
    const helpers = sliceOut(door, 'var domNodes = new Map;',
        'function zxTrace(msg) {\n  console.debug("[zx:dom] " + msg);\n}', 'helpers');

    return `<!doctype html><meta charset="utf-8"><body><div id="root"></div><pre id="out"></pre>
<script>
var LOG = [];
console.error = function (m) { LOG.push(['error', String(m)]); };
console.debug = function (m) { LOG.push(['debug', String(m)]); };

var TAG_NAMES = ['div', 'span', 'p', 'ul', 'li', 'svg'];
var SVG_TAG_START_INDEX = 5;
var STRINGS = new Map();
function readString(ptr, len) { return STRINGS.get(ptr) ?? ('str@' + ptr); }
function storeValueGetRef(v) { return 0; }

/* ---- VERBATIM from the patched door ---- */
${helpers}

var __zx = {
${glueBody}
};
/* ---- end verbatim ---- */

var root = document.getElementById('root');
var R = [];
function reset() { domNodes.clear(); LOG = []; root.innerHTML = ''; globalThis.__zx_debug = undefined; }
function errs() { return LOG.filter(function (e) { return e[0] === 'error'; }).map(function (e) { return e[1]; }); }
function dbgs() { return LOG.filter(function (e) { return e[0] === 'debug'; }).map(function (e) { return e[1]; }); }
function check(name, pass, lines, state) { R.push({ name: name, pass: !!pass, lines: lines || [], state: state || '' }); }

// G1 _srh prunes tracked children and traces the count
(function () {
  reset();
  globalThis.__zx_debug = true;
  __zx._ce(0, 1n); root.appendChild(domNodes.get(1n));
  __zx._ce(1, 2n); __zx._ac(1n, 2n);
  __zx._ct(0, 0, 3n); __zx._ac(2n, 3n);
  var before = domNodes.size;
  STRINGS.set(90, '<b>new</b>');
  __zx._srh(1n, 90, 10);
  var traced = dbgs().some(function (l) { return l.indexOf('pruned 2 tracked node(s)') >= 0; });
  check('G1 _srh prunes destroyed children', traced && domNodes.size === 1 && before === 3,
    dbgs().filter(function (l) { return l.indexOf('_srh') >= 0; }),
    'domNodes ' + before + ' -> ' + domNodes.size + ' (children #2,#3 pruned, #1 kept)');
})();

// G1b without the prune the ids would leak
(function () {
  reset();
  __zx._ce(0, 10n); root.appendChild(domNodes.get(10n));
  __zx._ce(1, 11n); __zx._ac(10n, 11n);
  var had = domNodes.has(11n);
  STRINGS.set(91, 'x');
  __zx._srh(10n, 91, 1);
  check('G1b _srh leaves no stale id', had === true && domNodes.has(11n) === false, [],
    'child #11 tracked before=' + had + ' after=' + domNodes.has(11n));
})();

// G2 _rc tree drift: anomaly + recover, never throw (the operator's crash)
(function () {
  reset();
  __zx._ce(0, 20n); __zx._ce(0, 21n);
  root.appendChild(domNodes.get(20n)); root.appendChild(domNodes.get(21n));
  __zx._ce(1, 22n); __zx._ac(21n, 22n);
  var threw = null;
  try { __zx._rc(20n, 22n); } catch (e) { threw = e.name + ': ' + e.message; }
  var named = errs().some(function (l) { return l.indexOf('_rc TREE DRIFT') >= 0; });
  check('G2 _rc drift recovers without throwing',
    named && threw === null && !domNodes.get(21n).firstChild && !domNodes.has(22n),
    errs(), 'threw=' + threw + ' | detached=' + !domNodes.get(21n).firstChild + ' | untracked=' + !domNodes.has(22n));
})();

// G2b _rc normal path stays silent
(function () {
  reset();
  __zx._ce(0, 30n); root.appendChild(domNodes.get(30n));
  __zx._ce(1, 31n); __zx._ac(30n, 31n);
  __zx._rc(30n, 31n);
  check('G2b _rc normal path emits no anomaly',
    errs().length === 0 && domNodes.get(30n).childNodes.length === 0 && !domNodes.has(31n),
    errs(), 'anomalies=' + errs().length + ' removed=true untracked=true');
})();

// G3 every missing-node lookup names the id that missed
(function () {
  reset();
  __zx._ce(0, 40n); root.appendChild(domNodes.get(40n));
  STRINGS.set(92, 'html');
  var seen = [];
  __zx._ac(999n, 40n); __zx._ac(40n, 998n); __zx._rc(997n, 996n);
  __zx._ib(995n, 40n, 40n); __zx._rpc(40n, 994n, 993n);
  __zx._snv(992n, 0, 0); __zx._srh(991n, 92, 4);
  seen = errs();
  var ids = ['#999', '#998', '#997', '#995', '#994', '#992', '#991'];
  var all = ids.every(function (id) { return seen.some(function (l) { return l.indexOf(id) >= 0; }); });
  check('G3 missing-node anomalies name the id (6 ops)', all && seen.length === 7, seen,
    'anomalies=' + seen.length + '/7');
})();

// G4 _ib missing ref: anomaly, recovered as append, no throw
(function () {
  reset();
  __zx._ce(0, 50n); root.appendChild(domNodes.get(50n));
  __zx._ce(1, 51n); __zx._ac(50n, 51n);
  __zx._ce(1, 52n);
  var threw = null;
  try { __zx._ib(50n, 52n, 989n); } catch (e) { threw = e.name; }
  var named = errs().some(function (l) { return l.indexOf('_ib missing ref #989') >= 0 && l.indexOf('RECOVERED') >= 0; });
  check('G4 _ib missing ref recovers as append',
    named && threw === null && domNodes.get(50n).lastChild === domNodes.get(52n),
    errs(), 'threw=' + threw + ' | appended to claimed parent=' + (domNodes.get(50n).lastChild === domNodes.get(52n)));
})();

// G5a _ib foreign ref: anomaly + recover to claimed parent, no throw
(function () {
  reset();
  __zx._ce(0, 60n); __zx._ce(0, 61n);
  root.appendChild(domNodes.get(60n)); root.appendChild(domNodes.get(61n));
  __zx._ce(1, 62n); __zx._ac(61n, 62n);
  __zx._ce(1, 63n);
  var threw = null;
  try { __zx._ib(60n, 63n, 62n); } catch (e) { threw = e.name; }
  var landed = domNodes.get(63n).parentNode === domNodes.get(60n);
  var named = errs().some(function (l) { return l.indexOf('_ib ref') >= 0 && l.indexOf('RECOVERED') >= 0; });
  check('G5a _ib foreign ref recovers without throwing', named && threw === null && landed,
    errs(), 'threw=' + threw + ' | child under claimed parent=' + landed);
})();

// G5b _rpc foreign oldChild: anomaly + detach old, append new, no throw
(function () {
  reset();
  __zx._ce(0, 70n); __zx._ce(0, 71n);
  root.appendChild(domNodes.get(70n)); root.appendChild(domNodes.get(71n));
  __zx._ce(1, 72n); __zx._ac(71n, 72n);
  var oldNode = domNodes.get(72n);
  __zx._ce(1, 73n);
  var threw = null;
  try { __zx._rpc(70n, 73n, 72n); } catch (e) { threw = e.name; }
  var newLanded = domNodes.get(73n).parentNode === domNodes.get(70n);
  var oldGone = oldNode.parentNode === null;
  var named = errs().some(function (l) { return l.indexOf('_rpc oldChild') >= 0 && l.indexOf('RECOVERED') >= 0; });
  check('G5b _rpc foreign oldChild recovers without throwing',
    named && threw === null && newLanded && oldGone && !domNodes.has(72n),
    errs(), 'threw=' + threw + ' | new under claimed parent=' + newLanded + ' | old detached=' + oldGone + ' | old untracked=' + !domNodes.has(72n));
})();

// G5c _rpc normal path stays silent
(function () {
  reset();
  __zx._ce(0, 74n); root.appendChild(domNodes.get(74n));
  __zx._ce(1, 75n); __zx._ac(74n, 75n);
  __zx._ce(1, 76n);
  __zx._rpc(74n, 76n, 75n);
  check('G5c _rpc normal path emits no anomaly',
    errs().length === 0 && domNodes.get(76n).parentNode === domNodes.get(74n) && !domNodes.has(75n),
    errs(), 'anomalies=' + errs().length);
})();

// G6 re-creating a live id orphans the previous node
(function () {
  reset();
  __zx._ce(0, 80n); __zx._ce(1, 80n);
  var a = errs().slice();
  LOG = [];
  __zx._ct(0, 0, 81n); __zx._ct(0, 0, 81n);
  var b = errs();
  check('G6 _ce/_ct re-create of a live id is named', a.length === 1 && b.length === 1, a.concat(b));
})();

// G7 one trace line per op under __zx_debug
(function () {
  reset();
  globalThis.__zx_debug = true;
  STRINGS.set(1, 'hello'); STRINGS.set(2, 'cls'); STRINGS.set(3, 'box');
  STRINGS.set(4, 'value'); STRINGS.set(5, 'v1'); STRINGS.set(6, '<i>raw</i>'); STRINGS.set(7, 'bye');
  __zx._ce(0, 100n); root.appendChild(domNodes.get(100n));
  __zx._ct(1, 5, 101n); __zx._ac(100n, 101n);
  __zx._sa(100n, 2, 3, 3, 3); __zx._sp(100n, 4, 5, 5, 2); __zx._ra(100n, 2, 3);
  __zx._snv(101n, 7, 3);
  __zx._ce(1, 102n); __zx._ib(100n, 102n, 101n);
  __zx._ce(1, 103n); __zx._rpc(100n, 103n, 102n);
  __zx._rc(100n, 103n);
  __zx._ce(2, 104n); __zx._ac(100n, 104n); __zx._srh(104n, 6, 10);
  var ops = ['_ce', '_ct', '_ac', '_sa', '_sp', '_ra', '_snv', '_ib', '_rpc', '_rc', '_srh'];
  var lines = dbgs();
  var covered = ops.every(function (op) {
    return lines.some(function (l) { return l.indexOf('[zx:dom] ' + op + ' ') >= 0; });
  });
  check('G7 every DOM op traces under __zx_debug (11 ops)', covered && errs().length === 0, lines,
    'ops covered=' + covered + ' anomalies=' + errs().length);
})();

// G7b production default is silent
(function () {
  reset();
  __zx._ce(0, 110n); root.appendChild(domNodes.get(110n));
  __zx._ct(1, 5, 111n); __zx._ac(110n, 111n);
  __zx._sa(110n, 2, 3, 3, 3); __zx._rc(110n, 111n);
  check('G7b no traces when __zx_debug is unset', dbgs().length === 0 && errs().length === 0, [],
    'debug lines=' + dbgs().length + ' error lines=' + errs().length);
})();

document.getElementById('out').textContent = JSON.stringify(R);
var d = document.createElement('div'); d.id = 'done'; document.body.appendChild(d);
</script></body>`;
}

// --- drive the page in headless chrome over CDP (mirrors render.mjs) ---
const profile = mkdtempSync(join(tmpdir(), 'zx-probe-'));
const pagePath = join(profile, 'probe.html');
writeFileSync(pagePath, buildPage(patchedDoorText(process.argv[2])));

const chrome = spawn('google-chrome-stable', [
    '--headless', '--disable-gpu', '--no-sandbox',
    `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
], { detached: true, stdio: 'ignore' });

const cleanup = () => {
    try { if (chrome.pid) process.kill(-chrome.pid, 'SIGKILL'); } catch (_) { /* already gone */ }
    try { rmSync(profile, { recursive: true, force: true }); } catch (_) { /* best effort */ }
};
process.on('exit', cleanup);
const watchdog = setTimeout(() => {
    process.stderr.write('door-guard-probe: HARD TIMEOUT\n');
    cleanup();
    process.exit(2);
}, 40000);

const portFile = join(profile, 'DevToolsActivePort');
let port = '';
for (let i = 0; i < 300 && !port; i++) {
    if (chrome.exitCode !== null) throw new Error(`chrome exited early (${chrome.exitCode})`);
    if (existsSync(portFile)) port = readFileSync(portFile, 'utf8').split('\n')[0].trim();
    if (!port) await sleep(50);
}
const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const ws = await new Promise((res, rej) => {
    const s = new WebSocket(webSocketDebuggerUrl);
    s.addEventListener('open', () => res(s), { once: true });
    s.addEventListener('error', () => rej(new Error('cdp websocket error')), { once: true });
});
let msgId = 0;
const pending = new Map();
ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== undefined && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
const send = (method, params = {}, sessionId) => new Promise((res) => {
    const i = ++msgId;
    pending.set(i, res);
    ws.send(JSON.stringify(sessionId ? { id: i, method, params, sessionId } : { id: i, method, params }));
});

const t = (await send('Target.createTarget', { url: 'about:blank' })).result;
const sid = (await send('Target.attachToTarget', { targetId: t.targetId, flatten: true })).result.sessionId;
await send('Runtime.enable', {}, sid);
await send('Page.enable', {}, sid);
await send('Page.navigate', { url: 'file://' + pagePath }, sid);

let out = null;
for (let i = 0; i < 200 && out === null; i++) {
    const r = await send('Runtime.evaluate', {
        expression: 'document.getElementById("done") ? document.getElementById("out").textContent : null',
        returnByValue: true,
    }, sid);
    const v = r.result?.result?.value;
    if (v) out = v;
    else await sleep(50);
}
clearTimeout(watchdog);
if (!out) { console.error('door-guard-probe: page never signalled done'); cleanup(); process.exit(2); }

const results = JSON.parse(out);
let failed = 0;
for (const r of results) {
    console.log(`${r.pass ? 'PASS' : 'FAIL'}  ${r.name}`);
    for (const l of r.lines) console.log(`        ${l}`);
    if (r.state) console.log(`        [state] ${r.state}`);
    if (!r.pass) failed++;
}
console.log(`\ndoor-guard-probe: ${results.length - failed}/${results.length} guards fired as expected`);
cleanup();
process.exit(failed ? 1 : 0);

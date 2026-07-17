#!/usr/bin/env node
// Mutation gate: a re-runnable proof that named gate rows can still go RED.
//
// A row is worth nothing until you have seen it red (notes/gate-rows-that-can-fail.md). Every proof
// this project has ever made lived in a chat message, so a month later nobody can re-run it, the row
// is green, and GREEN IS INDISTINGUISHABLE FROM HOLLOW. This runner is those proofs as bytes.
//
// Per entry: run the command UNMUTATED (baseline, memoized), prove the expected red is ABSENT there
// (attribution: a red the baseline already showed proves nothing), mutate a THROWAWAY COPY, re-run,
// prove the mutation SURVIVED TO THE MOMENT OF MEASUREMENT (the witness: build.sh resets .ziex before
// the suite runs, which once erased a mutation and printed a green that read as proof), then assert
// the named row went red. Anchors must be unique or the run aborts: a blind sed that matches twice or
// never mutates the wrong line or nothing, and the run after it is a meaningless green.
//
// THE LIVE TREE IS NEVER MUTATED. A runner that edited verify.sh in place and died mid-run would
// leave the operator's gate broken, looking exactly like a real regression.
//
// DOES NOT PROVE: that any row not listed here can fail (8 rows of the 285 the gate runs); that a row
// asserts the RIGHT thing (it can go red for a reason no entry names); that the product is correct.
//
// Usage:
//   node mutation-gate.mjs                   # the registry. exit 0 = every mutation produced its red
//   node mutation-gate.mjs --only M1,M3
//   node mutation-gate.mjs --list
//   node mutation-gate.mjs --prove-can-fail  # the runner rejects a hollow entry and a dead anchor
//
// Run it inside the devshell (node is not on PATH otherwise):
//   nix develop /home/jaidaken/projects/SillyTavern -c bash -lc 'node mutation-gate.mjs'

import { spawnSync, spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');

// Ports are per-member state, not a constant: two gates on one port drive each other's dist and
// report on their own (notes/gate-rows-that-can-fail.md, the stale-server signature). Overridable so
// a concurrent member can run this without colliding.
const PORT = process.env.PORT || '8990';
const IPORT = process.env.IPORT || '8996';

// ---------------------------------------------------------------------------------------------
// THE COMMANDS. Memoized: entries M1 and M2 share one verify.sh baseline, M4/M6/M7/M8 share one
// interaction baseline. A baseline per entry would cost four extra full gate runs and prove nothing
// extra, since the tree each entry copies is byte-identical.
// ---------------------------------------------------------------------------------------------
const COMMANDS = {
    verify: { cmd: `PORT=${PORT} IPORT=${IPORT} ./verify.sh`, timeoutMs: 600000 },
    build: { cmd: './build.sh', timeoutMs: 1200000 },
    interactions: { cmd: `IPORT=${IPORT} ./verify-interactions.sh`, timeoutMs: 600000 },
    doorprobe: { cmd: 'node door-guard-probe.mjs', timeoutMs: 120000 },
};

// ---------------------------------------------------------------------------------------------
// THE REGISTRY
//
// entry = {
//   id, title,
//   command:   key into COMMANDS
//   edits:     [{ file, find, replace, count }]  count = how many times `find` MUST appear
//   hold:      { port }                          bind a port for the length of the command
//   witness:   { file, must } | { port }         re-read AFTER the command: did the mutation survive?
//   present:   [{ name, re }]  MUST appear mutated, MUST NOT appear in the baseline (the red)
//   absent:    [{ name, re }]  MUST NOT appear mutated, MUST appear in the baseline (what stopped)
//   unchanged: [{ name, re }]  MUST appear in BOTH (the blindness this entry is documenting)
// }
//
// Every regex is checked against BOTH runs, so no regex can be satisfied by accident: `present` that
// was already there is a broken entry, `absent` that was never there is a broken entry.
// ---------------------------------------------------------------------------------------------
const REGISTRY = [
    {
        id: 'M1',
        title: 'a deleted verify.sh row is invisible except in the count',
        command: 'verify',
        edits: [{
            file: 'verify.sh',
            find: 'check   "main.wasm present" "$([ -f "$WASM" ] && echo yes || echo no)" "yes"',
            replace: ': # MUTATED by mutation-gate.mjs M1: the row is gone',
            count: 1,
        }],
        witness: { file: 'verify.sh', must: 'MUTATED by mutation-gate.mjs M1' },
        // The DENOMINATOR is the only thing that notices, which is the whole reason verify.sh carries
        // one. Deliberately keyed on the total and NOT on "0 failed": this gate has known load-
        // sensitive rows, and an entry that needs a perfectly green box to make its point is an entry
        // that goes red for reasons it is not about. The claim is 58 -> 57, and that holds either way.
        present: [{ name: 'the total drops by the deleted row', re: /verify\.sh: \d+ of 57 rows passed/ }],
        absent: [
            { name: 'the honest total', re: /verify\.sh: \d+ of 58 rows passed/ },
            { name: 'the row itself', re: /ok +main\.wasm present/ },
        ],
        unchanged: [],
        // NOT asserted here: "the verdict does not move" (rc unchanged), which is the punchline of the
        // entry. It was asserted, and it went red under load: an unrelated flaky row (C-PRE-SAM-3, no
        // element for the Big O preset) failed in the mutated run only, so rc moved 0 -> 1 for a reason
        // that had nothing to do with deleting a row. A claim that needs a quiet box is a claim that
        // lies red on this one, and this programme runs members in parallel BY DESIGN. Observed on a
        // green box instead, and left as prose rather than a row that would eventually revert a real
        // fix: baseline rc=0 -> mutated rc=0, "verify.sh: 57 of 57 rows passed, 0 failed".
    },
    {
        id: 'M2',
        title: 'a verify.sh python stage that dies before its first row is counted, not skipped',
        command: 'verify',
        edits: [{
            file: 'verify.sh',
            // The streaming + render-cache stage. Its five rows are printed by python and only an
            // exit code reaches bash, so a stage that dies early would otherwise cost the denominator
            // nothing and read as one failure out of a total that already excluded what never ran.
            find: 'import json, re, sys\nh = open(sys.argv[1], encoding="utf-8", errors="replace").read()\nm = re.search(r\'<pre id="probe-metrics"[^>]*>(.*?)</pre>\', h, re.S)',
            replace: 'import json, re, sys\nsys.exit(9)  # MUTATED by mutation-gate.mjs M2: the stage dies before row one\nh = open(sys.argv[1], encoding="utf-8", errors="replace").read()\nm = re.search(r\'<pre id="probe-metrics"[^>]*>(.*?)</pre>\', h, re.S)',
            count: 1,
        }],
        witness: { file: 'verify.sh', must: 'MUTATED by mutation-gate.mjs M2' },
        present: [
            { name: 'the dead stage names itself and its exit code', re: /FAIL +streaming and render-cache stage +stage reported no rows \(rc=9\)/ },
            // 58 - the 5 rows it owed + the 1 row tally() charges for the silence = 54. A stage that
            // died before row one costs the denominator exactly what it failed to run, which is the
            // difference between "one failure" and "five rows nobody ever measured".
            { name: 'the total loses the five rows it never ran', re: /verify\.sh: \d+ of 54 rows passed/ },
        ],
        absent: [
            { name: 'the honest total', re: /verify\.sh: \d+ of 58 rows passed/ },
            { name: 'a row the dead stage owed', re: /ok +all tokens delivered/ },
        ],
        unchanged: [],
    },
    {
        id: 'M3',
        title: 'patch 12 regression test, mutated IN THE PATCH so it survives setup-ziex',
        command: 'build',
        // The mutation MUST live in the patch, not in .ziex: build.sh runs setup-ziex.sh first, which
        // does `git reset --hard` + `git clean -fd` on .ziex. A mutation written into .ziex is erased
        // BEFORE the suite that was supposed to fail on it ever runs, and build.sh then prints EXIT 0.
        // That exact green was once mistaken for proof. The witness below is what makes it impossible.
        edits: [{
            file: 'patches/12-placement-move-order-and-raw-html-misuse.patch',
            // A `+` line: changing its CONTENT leaves the hunk's line counts intact, so `git apply`
            // still applies cleanly and the mutation reaches the compiler rather than the patch parser.
            find: '+    try testing.expect(moves > 0);',
            replace: '+    try testing.expect(moves > 999999); // MUTATED by mutation-gate.mjs M3',
            count: 1,
        }],
        // Read back out of .ziex, on the far side of setup-ziex.sh's reset. If this string is here,
        // the mutation was in the tree the compiler read. This is the most valuable line in the file.
        witness: { file: '.ziex/test/core/vdom.zig', must: 'MUTATED by mutation-gate.mjs M3' },
        // Keys on the FAILURE, not the test name. The name alone was the first signal here and the
        // runner rejected the entry for it: the zig runner prints every test's name whether it passed
        // or failed, so the baseline already carried it and the "red" was satisfied by a green run.
        // That is F2 from the gate doc (a predicate satisfied by the default) inside this very file.
        present: [{ name: 'the ziex suite names the failing test', re: /"reversing keyed rows leaves the vtree in the DOM's order" - TestUnexpectedResult/ }],
        absent: [{ name: 'the build completes', re: /build\.sh: done \(opt=/ }],
        unchanged: [{ name: 'setup-ziex reapplied the patch it was mutated in', re: /setup-ziex: applied 12-placement-move-order-and-raw-html-misuse\.patch/ }],
    },
    {
        id: 'M4',
        title: 'the interaction gate refuses a port it does not own, before a single browser row',
        command: 'interactions',
        // Not a file edit. The mutation is the environment: a stranger already on the port. The old
        // failure this row exists for is silent, because a readiness curl proves that A server
        // answers, never that it is OURS, so every row then drives someone else's dist.
        hold: { port: Number(IPORT) },
        // The squatter must still hold the socket at the moment of measurement. A squatter that died
        // early would make the gate's refusal a mystery rather than a proof, and this entry would be
        // claiming a red it did not cause.
        witness: { port: Number(IPORT) },
        present: [{ name: 'the refusal names the port', re: new RegExp(`port ${IPORT} already answers before we started`) }],
        // The refusal must land BEFORE the browser runs, not as a late failure among the rows.
        absent: [
            { name: 'the first browser row', re: /A1 boot: hydrated with 12 fixtures/ },
            { name: 'the interaction summary', re: /interactions: \d+ of \d+ must rows passed/ },
        ],
        unchanged: [],
    },
    {
        id: 'M6',
        title: 'an unhandled rejection fails C-DBG-10 while every console row stays green',
        command: 'interactions',
        // dist/glue/custom.js is the built, minified product the gate actually serves and drives, so
        // this mutates the thing under test rather than a source file the gate never reads.
        edits: [{
            file: 'dist/glue/custom.js',
            find: '(function(){"use strict";',
            // The crash this whole channel was built for arrived exactly this way: a NotFoundError off
            // a promise. It reaches no console.error and carries no prefix, so the door cannot be the
            // witness to a failure that stops it from speaking.
            replace: '(function(){"use strict";Promise.reject(new DOMException("Failed to execute \'removeChild\' on \'Node\': The node to be removed is not a child of this node. MUTATED-M6",\'NotFoundError\'));',
            count: 1,
        }],
        witness: { file: 'dist/glue/custom.js', must: 'MUTATED-M6' },
        present: [{ name: 'C-DBG-10 sees the uncaught rejection', re: /FAIL +C-DBG-10 no uncaught exception in the whole run/ }],
        absent: [{ name: 'C-DBG-10 clean', re: /ok +C-DBG-10 no uncaught exception in the whole run +clean/ }],
        // THE POINT OF THIS ENTRY. C-DBG-8 watches console.error and is structurally blind to an
        // exception, so it sails through the exact crash the channel exists to catch. That blindness
        // is why C-DBG-10 exists, and this is the row that proves the blindness is real rather than
        // asserted. M8 proves C-DBG-8 is not merely green forever.
        unchanged: [{ name: 'C-DBG-8 stays green through the crash', re: /ok +C-DBG-8 no \[zx:dom\] anomaly in the whole run +clean/ }],
    },
    {
        id: 'M7',
        title: 'a stray [zx:dom] trace on a default load fails C-DBG-3',
        command: 'interactions',
        edits: [{
            file: 'dist/glue/custom.js',
            find: '(function(){"use strict";',
            // console.debug, so it lands in zxTraces. The driver sorts by CDP type, not by the
            // emitter's intent, and carries no ST-SENSOR-PROBE marker, so no sensor row counts it.
            replace: '(function(){"use strict";console.debug("[zx:dom] MUTATED-M7 patch vnode=1 tag=div");',
            count: 1,
        }],
        witness: { file: 'dist/glue/custom.js', must: 'MUTATED-M7' },
        present: [{ name: 'C-DBG-3 sees debug output leak into a default load', re: /FAIL +C-DBG-3 debug output does not leak into a default load/ }],
        absent: [{ name: 'C-DBG-3 clean', re: /ok +C-DBG-3 debug output does not leak into a default load/ }],
        unchanged: [],
    },
    {
        id: 'M8',
        title: 'a [zx:dom] anomaly fails C-DBG-8, so M6 is measuring blindness and not a dead row',
        command: 'interactions',
        // NOT one of the seven. M6 asserts C-DBG-8 stays GREEN through an uncaught exception, and that
        // assertion is worthless if C-DBG-8 is a row that can never go red at all: a permanently green
        // row satisfies M6's `unchanged` exactly as well as a working one does. That is the disease
        // wearing the cure's clothes. This entry is what makes M6 mean anything.
        edits: [{
            file: 'dist/glue/custom.js',
            find: '(function(){"use strict";',
            replace: '(function(){"use strict";console.error("[zx:dom] MUTATED-M8 _rc TREE DRIFT vnode=1 tag=div");',
            count: 1,
        }],
        witness: { file: 'dist/glue/custom.js', must: 'MUTATED-M8' },
        present: [{ name: 'C-DBG-8 sees the anomaly', re: /FAIL +C-DBG-8 no \[zx:dom\] anomaly in the whole run/ }],
        absent: [{ name: 'C-DBG-8 clean', re: /ok +C-DBG-8 no \[zx:dom\] anomaly in the whole run +clean/ }],
        unchanged: [],
    },
];

// The two entries below never run against the registry. They are the runner's OWN can-fail proof,
// and they live here rather than in a chat message for the same reason the registry does: a proof
// that cannot be re-run is a proof that expires. `--prove-can-fail` asserts the runner REJECTS both.
const CAN_FAIL_PROOFS = [
    {
        id: 'P1',
        title: 'an entry whose red is already red without the mutation must FAIL, not pass',
        expect: 'not-attributable',
        entry: {
            id: 'P1',
            title: 'points at a guard that passes in the baseline and mutates something unrelated',
            command: 'doorprobe',
            edits: [{ file: 'README.md', find: '#', replace: '#', count: 1 }],
            witness: { file: 'README.md', must: '#' },
            // Already true in the baseline. The mutation cannot have caused it, so the runner must
            // refuse it rather than score a green row as a kill.
            present: [{ name: 'a guard that was always passing', re: /PASS +G1 _srh prunes destroyed children/ }],
            absent: [],
            unchanged: [],
        },
    },
    {
        id: 'P2',
        title: 'an anchor that no longer exists must ABORT the run, never skip quietly',
        expect: 'anchor-error',
        entry: {
            id: 'P2',
            title: 'the file legitimately changed shape and the anchor is gone',
            command: 'doorprobe',
            edits: [{
                file: 'verify.sh',
                find: 'check "main.wasm present" THIS ANCHOR HAS BEEN CORRUPTED',
                replace: ': # never reached',
                count: 1,
            }],
            witness: { file: 'verify.sh', must: 'never reached' },
            present: [{ name: 'unreachable', re: /never reached/ }],
            absent: [],
            unchanged: [],
        },
    },
];

// ---------------------------------------------------------------------------------------------
// MACHINERY
// ---------------------------------------------------------------------------------------------

class AnchorError extends Error {}

const copies = new Set();
const cleanupAll = () => {
    for (const d of copies) {
        try { rmSync(d, { recursive: true, force: true }); } catch (_) { /* best effort */ }
    }
    copies.clear();
};
process.on('exit', cleanupAll);
for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => { cleanupAll(); process.exit(130); });
}

// A copy, never the live tree. --reflink=auto on btrfs makes this metadata-only: the whole repo costs
// about 300ms and almost no space, which is what lets every entry get a pristine tree instead of a
// restore step that has to be trusted. A restore step is trust; a fresh copy is arithmetic.
//
// The REPO, not just client/: check-api-routes.mjs resolves the repo root as client/.. and reads the
// express router out of <root>/src, so a client-only copy failed that row in every single run and the
// baseline was never green. The client is not self-contained and the copy must not pretend it is.
function copyTree() {
    const dir = mkdtempSync(join(tmpdir(), 'mut-gate-'));
    copies.add(dir);
    const dest = join(dir, 'repo');
    execFileSync('cp', ['-a', '--reflink=auto', REPO, dest], { stdio: 'pipe' });
    return join(dest, 'client');
}

function dropTree(dest) {
    const dir = dirname(dirname(dest));
    try { rmSync(dir, { recursive: true, force: true }); } catch (_) { /* best effort */ }
    copies.delete(dir);
}

// The anchor discipline. A `find` that appears twice mutates both and the entry is then a claim about
// a line nobody chose; a `find` that appears zero times mutates nothing and the run that follows is a
// meaningless green. Both abort, naming the file, the count, and what to do.
function applyEdits(dest, edits, id) {
    for (const e of edits) {
        const p = join(dest, e.file);
        if (!existsSync(p)) {
            throw new AnchorError(`${id}: ${e.file} does not exist. The tree changed shape; update this entry.`);
        }
        const src = readFileSync(p, 'utf8');
        const want = e.count ?? 1;
        const got = src.split(e.find).length - 1;
        if (got !== want) {
            throw new AnchorError(
                `${id}: anchor in ${e.file} appears ${got} time(s), entry requires exactly ${want}.\n` +
                `  anchor: ${JSON.stringify(e.find.length > 120 ? e.find.slice(0, 120) + '...' : e.find)}\n` +
                (got === 0
                    ? '  The file legitimately changed and this mutation now edits NOTHING. An entry that\n' +
                      '  silently skips reports green while testing nothing, so this run stops here.\n' +
                      '  FIX: re-read the file, pick a new anchor, and re-prove the row goes red.'
                    : '  A non-unique anchor mutates every copy at once, so the entry is a claim about a line\n' +
                      '  nobody picked. FIX: lengthen the anchor until it is unique, or set count.'),
            );
        }
        writeFileSync(p, src.split(e.find).join(e.replace));
    }
}

// The environment mutation for M4: a stranger already on the port. It must be a SEPARATE PROCESS.
// An in-process server cannot answer while spawnSync blocks this event loop, so the gate's readiness
// curl times out instead of getting a reply, the refusal never fires, and the gate dies of EADDRINUSE
// four seconds later looking like an unrelated bug. That cost a run here. The squatter must also
// ANSWER, not merely hold the socket: the pre-check is a curl, and a bare TCP accept that never
// replies is not the thing this row exists to catch.
async function answers(port) {
    try {
        const r = await fetch(`http://127.0.0.1:${port}/`, { signal: AbortSignal.timeout(2000) });
        await r.text();
        return true;
    } catch (_) {
        return false;
    }
}

async function holdPort(port) {
    const code = `require('http').createServer((q, r) => r.end('mutation-gate squatter'))` +
        `.listen(${port}, '127.0.0.1');`;
    const child = spawn(process.execPath, ['-e', code], { stdio: 'ignore' });
    for (let i = 0; i < 100; i++) {
        if (await answers(port)) return child;
        if (child.exitCode !== null) break;
        await new Promise((r) => setTimeout(r, 100));
    }
    try { child.kill('SIGKILL'); } catch (_) { /* already gone */ }
    throw new Error(`mutation-gate: could not squat port ${port} (already held? pass a free IPORT)`);
}

function runCommand(dest, key) {
    const { cmd, timeoutMs } = COMMANDS[key];
    const started = Date.now();
    // No pipe. `cmd | tail` reports TAIL's exit status, so a failed run reads as success; the whole
    // point of this runner is to not make that mistake while checking for it.
    const r = spawnSync('bash', ['-c', cmd], {
        cwd: dest,
        encoding: 'utf8',
        timeout: timeoutMs,
        maxBuffer: 64 * 1024 * 1024,
        env: { ...process.env, PORT, IPORT },
    });
    return {
        rc: r.status,
        signal: r.signal,
        out: `${r.stdout || ''}${r.stderr || ''}`,
        ms: Date.now() - started,
    };
}

const baselines = new Map();
function baselineFor(key) {
    if (baselines.has(key)) return baselines.get(key);
    process.stdout.write(`  [baseline] ${key}: ${COMMANDS[key].cmd} ... `);
    const dest = copyTree();
    let r;
    try {
        r = runCommand(dest, key);
    } finally {
        dropTree(dest);
    }
    process.stdout.write(`rc=${r.rc} ${(r.ms / 1000).toFixed(0)}s\n`);
    // Every baseline here is a gate that is supposed to be green, so a red one is load or a real
    // regression and the reader needs to know which tree these verdicts describe. Not fatal:
    // attribution is per-SIGNAL, so an unrelated flaky row cannot make an entry lie. But it is said
    // out loud, because this gate has known load-sensitive rows and this box runs members in parallel
    // by design (notes/gate-rows-that-can-fail.md, OPEN). Observed live: the same interaction
    // baseline gave rc=1 under a concurrent build and rc=0 on a quiet box minutes later.
    if (r.rc !== 0) {
        console.log(`  [!] the ${key} baseline is NOT GREEN (rc=${r.rc}) before any mutation. Every verdict`);
        console.log('      below still holds per-signal, but re-run on a quiet box before believing a red.');
        // The gate doc's standing OPEN item is that the load-sensitive rows are PLURAL and their names
        // were never captured: a member saw "4 must row(s) FAILED", could not name them, and the
        // question is still open. Every baseline here is a free sample of exactly that, so name them.
        const failed = r.out.split('\n').filter((l) => /^\s*FAIL/.test(l));
        for (const l of failed.slice(0, 12)) console.log(`      [baseline-red] ${l.trim()}`);
        if (failed.length > 12) console.log(`      [baseline-red] ... and ${failed.length - 12} more`);
    }
    baselines.set(key, r);
    return r;
}

const hits = (out, sigs) => sigs.filter((s) => s.re.test(out));
const misses = (out, sigs) => sigs.filter((s) => !s.re.test(out));

// ---------------------------------------------------------------------------------------------
// ONE ENTRY
// ---------------------------------------------------------------------------------------------
async function runEntry(entry) {
    const fails = [];
    const notes = [];
    const base = baselineFor(entry.command);

    // ATTRIBUTION, before spending a run. A red that the baseline already shows was not caused by
    // this mutation, and an `absent` signal the baseline never had is an entry describing a row that
    // does not exist. Both are broken entries, and neither needs the mutated run to prove it.
    const preRed = hits(base.out, entry.present ?? []);
    if (preRed.length) {
        for (const s of preRed) {
            fails.push(`NOT ATTRIBUTABLE: "${s.name}" is ALREADY present in the unmutated baseline. ` +
                'The row was red before the mutation, so this entry proves nothing about it.');
        }
    }
    const preGone = misses(base.out, entry.absent ?? []);
    for (const s of preGone) {
        fails.push(`BROKEN ENTRY: "${s.name}" is not in the unmutated baseline, so the mutation cannot remove it.`);
    }
    const preUnchanged = misses(base.out, entry.unchanged ?? []);
    for (const s of preUnchanged) {
        fails.push(`BROKEN ENTRY: "${s.name}" is not in the unmutated baseline, so "unchanged" is meaningless.`);
    }
    // Rejected before the mutation ran, so the mutated output does not exist and the baseline is the
    // only evidence there is. Print it: the reader is deciding whether the ROW rotted or the ENTRY did.
    if (fails.length) return { entry, ok: false, fails, notes, base, showBase: true };

    // The mutated run.
    const dest = copyTree();
    let srv = null;
    let r;
    try {
        if (entry.edits) applyEdits(dest, entry.edits, entry.id);
        if (entry.hold) srv = await holdPort(entry.hold.port);
        r = runCommand(dest, entry.command);

        // THE WITNESS. Everything below is a claim about a run that measured the mutation, and that
        // claim is false if the mutation was gone by then. setup-ziex.sh erases .ziex edits before
        // the suite runs; a squatter can die before the gate looks. Check, do not assume.
        if (entry.witness?.file) {
            const wp = join(dest, entry.witness.file);
            const alive = existsSync(wp) && readFileSync(wp, 'utf8').includes(entry.witness.must);
            if (!alive) {
                fails.push(`MUTATION DID NOT SURVIVE: ${entry.witness.file} does not contain ` +
                    `${JSON.stringify(entry.witness.must)} after the command ran. The command reset it, ` +
                    'rebuilt it, or never read it, so this run measured the UNMUTATED tree and its result ' +
                    'is meaningless whichever way it went.');
            } else {
                notes.push(`witness: ${entry.witness.file} still carries the mutation after the run`);
            }
        }
        if (entry.witness?.port) {
            // ANSWERS, not `listening`. A handle's listening flag reads true while the process cannot
            // reply at all, which is the stale-observable shape the gate doc names: it survives the
            // thing going wrong without going false, so it reads as PASS either way.
            const alive = srv && srv.exitCode === null && await answers(entry.witness.port);
            if (!alive) {
                fails.push(`MUTATION DID NOT SURVIVE: the squatter on port ${entry.witness.port} was not ` +
                    'answering when the command finished, so the refusal below was not caused by us.');
            } else {
                notes.push(`witness: the squatter still answered on port ${entry.witness.port} after the run`);
            }
        }
    } finally {
        if (srv) { try { srv.kill('SIGKILL'); } catch (_) { /* already gone */ } }
        dropTree(dest);
    }

    if (r.signal) fails.push(`the command was killed by ${r.signal} (timeout?), so no verdict is possible`);

    for (const s of misses(r.out, entry.present ?? [])) {
        fails.push(`NO RED: expected "${s.name}" ${s.re} in the mutated run, and it is not there. ` +
            'The mutation landed and the row did not notice: this row may be hollow.');
    }
    for (const s of hits(r.out, entry.absent ?? [])) {
        fails.push(`STILL THERE: "${s.name}" ${s.re} survived the mutation.`);
    }
    for (const s of misses(r.out, entry.unchanged ?? [])) {
        fails.push(`COLLATERAL: "${s.name}" was expected to stay put and did not. The mutation hit more ` +
            'than the row it aimed at, so the attribution in this entry is wrong.');
    }
    for (const s of hits(r.out, entry.present ?? [])) notes.push(`RED as expected: ${s.name}`);
    for (const s of hits(r.out, entry.unchanged ?? [])) notes.push(`unchanged as expected: ${s.name}`);

    return { entry, ok: fails.length === 0, fails, notes, base, mutated: r };
}

// Verbatim evidence beats a claim about it: print the lines the regexes matched, not a summary of them.
function evidence(out, sigs) {
    const lines = out.split('\n');
    const seen = [];
    for (const s of sigs) {
        const l = lines.find((x) => s.re.test(x));
        if (l) seen.push(l.trim());
    }
    return seen;
}

// ---------------------------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------------------------
const argv = process.argv.slice(2);
const only = (argv.find((a) => a.startsWith('--only=')) || '').split('=')[1]
    || (argv.includes('--only') ? argv[argv.indexOf('--only') + 1] : '');

if (argv.includes('--list')) {
    for (const e of REGISTRY) console.log(`${e.id.padEnd(4)} [${e.command.padEnd(12)}] ${e.title}`);
    process.exit(0);
}

// Anchor rot is checkable in milliseconds and this runner learned that the expensive way: a mistyped
// anchor (one space where the file has three) was found only after a 128s baseline had already run.
// Cheap enough to put in front of the real run, so a rotted registry says so before it costs anything.
if (argv.includes('--check-anchors')) {
    let bad = 0;
    for (const e of REGISTRY) {
        for (const ed of e.edits ?? []) {
            const p = join(HERE, ed.file);
            const got = existsSync(p) ? readFileSync(p, 'utf8').split(ed.find).length - 1 : -1;
            const want = ed.count ?? 1;
            const ok = got === want;
            if (!ok) bad += 1;
            console.log(`${ok ? 'ok  ' : 'ROT '} ${e.id} ${ed.file}: anchor found ${got}x, want ${want}x`);
        }
        if (!e.edits) console.log(`ok   ${e.id} (no file edits: ${e.hold ? `holds port ${e.hold.port}` : 'none'})`);
    }
    console.log(`\nmutation-gate: ${bad === 0 ? 'every anchor still matches the tree' : `${bad} ROTTED anchor(s), fix before trusting a run`}`);
    process.exit(bad ? 2 : 0);
}

if (argv.includes('--prove-can-fail')) {
    // The runner's own can-fail proof. A mutation runner that cannot fail is the joke this whole file
    // exists to stop, so the proof is a mode rather than a paragraph somebody wrote once.
    console.log('mutation-gate --prove-can-fail: the runner must REJECT both of these.\n');
    let bad = 0;
    for (const p of CAN_FAIL_PROOFS) {
        console.log(`${p.id} ${p.title}`);
        let verdict = 'accepted (WRONG)';
        try {
            const res = await runEntry(p.entry);
            if (res.ok) {
                verdict = 'accepted (WRONG)';
            } else if (res.fails.some((f) => f.startsWith('NOT ATTRIBUTABLE'))) {
                verdict = 'not-attributable';
            } else {
                verdict = `rejected: ${res.fails[0]}`;
            }
        } catch (e) {
            verdict = e instanceof AnchorError ? 'anchor-error' : `threw: ${e.message}`;
            if (e instanceof AnchorError) console.log(`   ${String(e.message).split('\n').join('\n   ')}`);
        }
        const ok = verdict === p.expect;
        if (!ok) bad += 1;
        console.log(`   want=${p.expect} got=${verdict}  -> ${ok ? 'PASS' : 'FAIL'}\n`);
    }
    console.log(`mutation-gate: ${CAN_FAIL_PROOFS.length - bad} of ${CAN_FAIL_PROOFS.length} can-fail proofs held`);
    process.exit(bad ? 1 : 0);
}

const picked = only ? REGISTRY.filter((e) => only.split(',').includes(e.id)) : REGISTRY;
if (!picked.length) {
    console.error(`mutation-gate: --only ${only} matched no entry. Known: ${REGISTRY.map((e) => e.id).join(',')}`);
    process.exit(2);
}

console.log(`mutation-gate: ${picked.length} mutation(s), ports PORT=${PORT} IPORT=${IPORT}`);
console.log('every run works on a throwaway copy; the live tree is never mutated.\n');

const t0 = Date.now();
const results = [];
for (const e of picked) {
    console.log(`${e.id} ${e.title}`);
    try {
        const res = await runEntry(e);
        results.push(res);
        for (const n of res.notes) console.log(`   ${n}`);
        if (res.mutated) {
            for (const l of evidence(res.mutated.out, [...(e.present ?? []), ...(e.unchanged ?? [])])) {
                console.log(`   | ${l}`);
            }
            console.log(`   baseline rc=${res.base.rc} -> mutated rc=${res.mutated.rc} (${(res.mutated.ms / 1000).toFixed(0)}s)`);
        }
        for (const f of res.fails) console.log(`   ${f}`);
        // A failing entry without its output is a claim the reader cannot check, and the reader is
        // usually deciding whether the ROW rotted or the ENTRY did. Print the bytes, not a summary.
        if (!res.ok && res.mutated) {
            console.log(`   ---- last 20 lines of the mutated run (rc=${res.mutated.rc}) ----`);
            for (const l of res.mutated.out.trimEnd().split('\n').slice(-20)) console.log(`   | ${l}`);
            console.log('   ----');
        }
        if (!res.ok && res.showBase) {
            console.log(`   ---- last 20 lines of the UNMUTATED baseline (rc=${res.base.rc}) ----`);
            for (const l of res.base.out.trimEnd().split('\n').slice(-20)) console.log(`   | ${l}`);
            console.log('   ----');
        }
        console.log(`   ${res.ok ? 'PASS: the mutation produced its expected red' : 'FAIL'}\n`);
    } catch (err) {
        // An AnchorError is not a failed entry, it is a registry that no longer describes the tree.
        // Reporting it as one red among many would let a rotted registry keep printing a score.
        if (err instanceof AnchorError) {
            console.error(`\nmutation-gate: STOPPING. The registry no longer matches the tree.\n${err.message}`);
            process.exit(2);
        }
        throw err;
    }
}

const passed = results.filter((r) => r.ok).length;
console.log(`mutation-gate: ${passed} of ${results.length} mutations produced their expected red ` +
    `(${((Date.now() - t0) / 1000).toFixed(0)}s)`);
process.exit(passed === results.length ? 0 : 1);

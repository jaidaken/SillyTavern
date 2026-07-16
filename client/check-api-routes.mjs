// Every /api/ path the client calls must exist on the real server.
//
// This is A1b one layer up. A1b checks the glue's wasm calls against the built module's export table
// because 338a06bb4 shipped a call to an export nobody added. The same shape bit the server side:
// the client POSTed /api/chats/metadata, the DEVSERVE MOCK invented that route, the gate went green,
// and the real express server had no such route, so the note save 404'd for every user. A mock that
// invents a route tests itself; only the server's own router can answer whether a route exists.
//
// Denominator discipline (this file has no browser and no mock to hide behind):
//   - client paths come from the .zig sources, every one of them, not a hand-kept list.
//   - server routes come from the mount table in server-startup.js joined to each endpoint file's
//     own router.<method> registrations. A hand-kept list here would rot into a lie.
//   - a path that a NESTED router (router.use inside an endpoint file) could own is reported
//     UNRESOLVED, never MISSING. Failing on what it cannot see is how a checker starts lying.
//
// Usage: node check-api-routes.mjs [--root <repo root>]

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const rootIdx = args.indexOf('--root');
const ROOT = rootIdx >= 0 ? resolve(args[rootIdx + 1]) : resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CLIENT = join(ROOT, 'client', 'app', 'pages');
const SRC = join(ROOT, 'src');

function read(p) {
    return existsSync(p) ? readFileSync(p, 'utf8') : null;
}

// ---- what the client calls ---------------------------------------------------------------------

function clientPaths() {
    const out = new Map();
    const walk = (dir) => {
        for (const e of readdirSync(dir, { withFileTypes: true })) {
            const p = join(dir, e.name);
            if (e.isDirectory()) { walk(p); continue; }
            if (!/\.(zig|zx)$/.test(e.name)) continue;
            const src = readFileSync(p, 'utf8');
            for (const m of src.matchAll(/"(\/api\/[a-zA-Z0-9/_.-]+)"/g)) {
                if (!out.has(m[1])) out.set(m[1], []);
                out.get(m[1]).push(e.name);
            }
        }
    };
    walk(CLIENT);
    return out;
}

// ---- what the server actually serves -----------------------------------------------------------

// `import { router as chatsRouter } from './endpoints/chats.js'` + `app.use('/api/chats', chatsRouter)`
function mountTable() {
    const startup = read(join(SRC, 'server-startup.js'));
    const main = read(join(SRC, 'server-main.js'));
    if (!startup) throw new Error('server-startup.js not found: cannot build a route denominator');
    const text = startup + '\n' + (main || '');

    const varToFile = new Map();
    for (const m of text.matchAll(/import\s*\{\s*router\s+as\s+(\w+)\s*\}\s*from\s*'([^']+)'/g)) {
        varToFile.set(m[1], m[2]);
    }
    const mounts = [];
    for (const m of text.matchAll(/app\.use\(\s*'(\/api\/[^']*)'\s*,\s*(\w+)\s*\)/g)) {
        const file = varToFile.get(m[2]);
        if (file) mounts.push({ prefix: m[1], file });
    }
    // Longest prefix first: /api/backends/text-completions must win over any shorter neighbour.
    mounts.sort((a, b) => b.prefix.length - a.prefix.length);
    return mounts;
}

function routerFileText(rel) {
    const p = join(SRC, rel.replace(/^\.\//, ''));
    return read(p);
}

function routesIn(text) {
    const direct = new Set();
    for (const m of text.matchAll(/router\.(get|post|put|patch|delete)\(\s*'([^']*)'/g)) {
        direct.add(m[2] === '' ? '/' : m[2]);
    }
    const nested = new Set();
    for (const m of text.matchAll(/router\.use\(\s*'([^']+)'/g)) nested.add(m[1]);
    return { direct, nested };
}

// ---- the check ---------------------------------------------------------------------------------

const mounts = mountTable();
if (mounts.length === 0) throw new Error('no /api mounts parsed: the checker would pass everything');

const paths = clientPaths();
if (paths.size === 0) throw new Error('no client /api paths found: the checker would pass vacuously');

const missing = [];
const unresolved = [];
let ok = 0;

for (const [p, files] of [...paths].sort()) {
    const mount = mounts.find((m) => p === m.prefix || p.startsWith(m.prefix + '/'));
    if (!mount) { unresolved.push(`${p}  (no mount matches; called from ${files.join(', ')})`); continue; }
    const text = routerFileText(mount.file);
    if (text === null) { unresolved.push(`${p}  (router file ${mount.file} unreadable)`); continue; }
    const rest = p.slice(mount.prefix.length) || '/';
    const { direct, nested } = routesIn(text);
    if (direct.has(rest)) { ok++; continue; }
    const firstSeg = '/' + rest.split('/').filter(Boolean)[0];
    if (nested.has(firstSeg)) { unresolved.push(`${p}  (may live in the nested router ${firstSeg} of ${mount.file})`); continue; }
    missing.push(`${p}  -> ${mount.file} has no route '${rest}'   (called from ${files.join(', ')})`);
}

console.log(`api-routes: ${ok} verified, ${missing.length} missing, ${unresolved.length} unresolved (of ${paths.size} client paths)`);
for (const u of unresolved) console.log(`  unresolved  ${u}`);
for (const m of missing) console.log(`  MISSING     ${m}`);

if (missing.length > 0) {
    console.log('\nA path the client calls does not exist on the server. The devserve mock can invent it');
    console.log('and every gate will still pass; the user gets a 404. Add the route or fix the path.');
    process.exit(1);
}
process.exit(0);

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import url from 'node:url';

const rootDirectory = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const baselinePath = path.join(rootDirectory, 'typecheck-baseline.json');
const tscBinary = path.join(rootDirectory, 'node_modules', '.bin', 'tsc');
// Line and column are omitted from the key: they churn on unrelated edits and would force baseline churn.
const errorPattern = /^(?<file>[^(]+)\((?<line>\d+),(?<column>\d+)\): error (?<code>TS\d+): (?<message>.*)$/;
const shouldWriteBaseline = process.argv.includes('--write');

function runTypeScript() {
    const result = spawnSync(tscBinary, ['--noEmit', '--pretty', 'false', '--project', 'jsconfig.json'], {
        cwd: rootDirectory,
        encoding: 'utf8',
        maxBuffer: 256 * 1024 * 1024,
    });

    if (result.error) {
        console.error('Failed to run tsc:', result.error.message);
        process.exit(2);
    }

    return `${result.stdout ?? ''}${result.stderr ?? ''}`;
}

function parseDiagnostics(output) {
    const counts = new Map();

    for (const line of output.split('\n')) {
        const match = errorPattern.exec(line.trim());
        if (!match) {
            continue;
        }

        const { file, code, message } = match.groups;
        const key = JSON.stringify({ file: file.split(path.sep).join('/'), code, message });
        counts.set(key, (counts.get(key) ?? 0) + 1);
    }

    return counts;
}

function readBaseline() {
    if (!fs.existsSync(baselinePath)) {
        console.error(`Missing baseline at ${baselinePath}. Regenerate it with: npm run typecheck:baseline`);
        process.exit(2);
    }

    const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
    return new Map(baseline.errors.map(entry => [JSON.stringify({ file: entry.file, code: entry.code, message: entry.message }), entry.count]));
}

function writeBaseline(counts) {
    const errors = [...counts.entries()]
        .map(([key, count]) => ({ ...JSON.parse(key), count }))
        .sort((a, b) => a.file.localeCompare(b.file) || a.code.localeCompare(b.code) || a.message.localeCompare(b.message));
    const total = errors.reduce((sum, entry) => sum + entry.count, 0);
    const typescriptVersion = JSON.parse(fs.readFileSync(path.join(rootDirectory, 'node_modules', 'typescript', 'package.json'), 'utf8')).version;

    fs.writeFileSync(baselinePath, `${JSON.stringify({ typescriptVersion, total, errors }, null, 4)}\n`);
    console.info(`Wrote ${total} baselined errors to ${path.basename(baselinePath)} (typescript ${typescriptVersion}).`);
}

const counts = parseDiagnostics(runTypeScript());

if (shouldWriteBaseline) {
    writeBaseline(counts);
    process.exit(0);
}

const baseline = readBaseline();
const introduced = [];
let resolved = 0;

for (const [key, count] of counts) {
    const allowed = baseline.get(key) ?? 0;
    if (count > allowed) {
        introduced.push({ ...JSON.parse(key), count: count - allowed });
    }
}

for (const [key, allowed] of baseline) {
    resolved += Math.max(0, allowed - (counts.get(key) ?? 0));
}

const total = [...counts.values()].reduce((sum, count) => sum + count, 0);

if (introduced.length > 0) {
    console.error(`Typecheck gate failed: ${introduced.reduce((sum, entry) => sum + entry.count, 0)} new error(s) not in the baseline.\n`);
    for (const entry of introduced) {
        console.error(`  ${entry.file}: ${entry.code}: ${entry.message}${entry.count > 1 ? ` (x${entry.count})` : ''}`);
    }
    console.error('\nFix them, or if they are intentional, refresh the baseline with: npm run typecheck:baseline');
    process.exit(1);
}

console.info(`Typecheck gate passed: ${total} baselined error(s), 0 new.`);

if (resolved > 0) {
    console.info(`${resolved} baselined error(s) are now fixed. Shrink the baseline with: npm run typecheck:baseline`);
}

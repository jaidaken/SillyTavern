import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import yaml from 'yaml';

import { characterCardV2, E2E_CHARACTER_NAME } from './fixtures.js';
import { MockServer } from './mock-server.js';
import { SillyTavernClient } from './st-client.js';
import { allocatePort, DEFAULT_HANDLE, SERVER_ROOT } from './st-server.js';

const PORT = Number(process.env.ST_E2E_PORT ?? 8000);
const READY_PORT = Number(process.env.ST_E2E_READY_PORT ?? PORT + 1);
const FORCE_KILL_DELAY_MS = 10000;
const READY_TIMEOUT_MS = 120000;
const READY_POLL_INTERVAL_MS = 100;

// User accounts stay off so the frontend loads without a login round trip.
const E2E_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: false,
});

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-e2e-'));
const dataRoot = path.join(tempDir, 'data');
const configPath = path.join(tempDir, 'config.yaml');
fs.writeFileSync(configPath, yaml.stringify(E2E_CONFIG), 'utf8');

const baseUrl = `http://127.0.0.1:${PORT}`;
const upstream = new MockServer({ host: '127.0.0.1', port: await allocatePort() });
await upstream.start();
const upstreamUrl = `http://127.0.0.1:${upstream.port}/v1`;

const child = spawn(process.execPath, [
    path.join(SERVER_ROOT, 'server.js'),
    '--configPath', configPath,
    '--dataRoot', dataRoot,
    '--port', String(PORT),
], { cwd: SERVER_ROOT, stdio: 'inherit' });

let cleanedUp = false;

/**
 * Removes the throwaway data root and stops the mock upstream once, on any exit path.
 * @returns {void}
 */
function cleanUp() {
    if (cleanedUp) {
        return;
    }
    cleanedUp = true;
    upstream.stop().catch(() => {});
    fs.rmSync(tempDir, { recursive: true, force: true });
}

/**
 * Polls an unauthenticated route until the server binds its port.
 * @returns {Promise<void>}
 */
async function waitUntilReady() {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    while (Date.now() < deadline) {
        try {
            const response = await fetch(`${baseUrl}/csrf-token`);
            await response.arrayBuffer();
            if (response.ok) {
                return;
            }
        } catch {
            // Connection is refused until the server finishes startup and binds.
        }
        await new Promise(resolve => setTimeout(resolve, READY_POLL_INTERVAL_MS));
    }
    throw new Error(`Server did not become ready within ${READY_TIMEOUT_MS} ms.`);
}

/**
 * Points the seeded settings at the mock upstream and streams from it.
 * @returns {void}
 */
function seedSettings() {
    const settingsPath = path.join(dataRoot, DEFAULT_HANDLE, 'settings.json');
    const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));

    settings.firstRun = false;
    settings.main_api = 'openai';
    settings.oai_settings.chat_completion_source = 'custom';
    settings.oai_settings.custom_url = upstreamUrl;
    settings.oai_settings.custom_model = 'mock-model';
    settings.oai_settings.stream_openai = true;

    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 4), 'utf8');
}

/**
 * Imports the character the streaming test sends a message to.
 * @returns {Promise<void>}
 */
async function seedCharacter() {
    const client = new SillyTavernClient(baseUrl);
    await client.fetchCsrfToken();

    const card = characterCardV2(E2E_CHARACTER_NAME, { first_mes: 'Greeting line.' });
    const form = new FormData();
    form.append('file_type', 'json');
    form.append('avatar', new Blob([JSON.stringify(card)], { type: 'application/json' }), `${E2E_CHARACTER_NAME}.json`);

    const imported = await client.postForm('/api/characters/import', form);
    if (imported.status !== 200) {
        throw new Error(`Character seed failed: ${imported.status} ${await imported.text()}`);
    }
}

child.on('exit', (code) => {
    cleanUp();
    process.exit(code ?? 1);
});

// server.js does not always exit on SIGTERM, and a survivor keeps the port bound for the next run.
for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
        child.kill(signal);
        setTimeout(() => child.kill('SIGKILL'), FORCE_KILL_DELAY_MS).unref();
    });
}

process.on('exit', cleanUp);

await waitUntilReady();
seedSettings();
await seedCharacter();

// Playwright waits on this port, so it never navigates before the seeded settings and character exist.
const readySignal = http.createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ready');
});
readySignal.listen(READY_PORT, '127.0.0.1');

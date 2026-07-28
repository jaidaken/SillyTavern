import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import yaml from 'yaml';
import { spawn } from 'node:child_process';

import { SillyTavernServer, DEFAULT_HANDLE, allocatePort, SERVER_ROOT } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { SseStream } from '../util/sse-stream.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 60000;

const SMOKE_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: true,
});

/**
 * A completions backend the test drives one token at a time, so a disconnect can land at an exact
 * frame instead of at whatever a timer happened to reach.
 */
class ScriptedUpstream {
    constructor() {
        this.host = '127.0.0.1';
        this.port = 0;
        this.server = null;
        /** @type {import('http').ServerResponse|null} */
        this.live = null;
        this.aborted = false;
        this.requests = 0;
        this.sent = [];
    }

    get baseUrl() {
        return `http://${this.host}:${this.port}`;
    }

    async start() {
        this.port = await allocatePort();
        this.server = http.createServer((req, res) => {
            this.requests += 1;
            res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
            this.live = res;
            req.on('aborted', () => { this.aborted = true; });
            res.on('close', () => { if (!res.writableEnded) this.aborted = true; });
        });
        await new Promise((resolve, reject) => {
            this.server.on('error', reject);
            this.server.listen(this.port, this.host, resolve);
        });
    }

    /**
     * @param {number} count How many tokens to emit.
     * @returns {string[]} The token texts emitted.
     */
    emit(count) {
        const emitted = [];
        for (let i = 0; i < count; i++) {
            const text = `tok${this.sent.length} `;
            this.sent.push(text);
            emitted.push(text);
            this.live?.write(`data: ${JSON.stringify({ choices: [{ text }] })}\n\n`);
        }
        return emitted;
    }

    finish() {
        this.live?.write('data: [DONE]\n\n');
        this.live?.end();
    }

    async stop() {
        this.live?.destroy();
        await new Promise(resolve => this.server?.close(resolve));
    }
}

/**
 * @param {Record<string, string>} extraEnv Environment overrides for the child.
 * @returns {Promise<{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}>}
 */
async function startServer(extraEnv = {}) {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-generation-'));
    const dataRoot = path.join(tempDir, 'data');
    const configPath = path.join(tempDir, 'config.yaml');
    const logPath = path.join(tempDir, 'server.log');
    fs.writeFileSync(configPath, yaml.stringify(SMOKE_CONFIG), 'utf8');
    const port = await allocatePort();

    const logFd = fs.openSync(logPath, 'a');
    const child = spawn(process.execPath, [
        path.join(SERVER_ROOT, 'server.js'),
        '--configPath', configPath,
        '--dataRoot', dataRoot,
        '--port', String(port),
    ], { cwd: SERVER_ROOT, stdio: ['ignore', logFd, logFd], env: { ...process.env, ...extraEnv } });
    fs.closeSync(logFd);

    let exitCode = null;
    child.once('exit', code => { exitCode = code ?? -1; });

    const baseUrl = `http://127.0.0.1:${port}`;
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
        if (exitCode !== null) {
            throw new Error(`Server exited with ${exitCode} before ready.\n${fs.readFileSync(logPath, 'utf8').split('\n').slice(-40).join('\n')}`);
        }
        try {
            const response = await fetch(`${baseUrl}/csrf-token`);
            await response.arrayBuffer();
            if (response.ok) {
                break;
            }
        } catch {
            // Connection is refused until the server binds its port.
        }
        await new Promise(resolve => setTimeout(resolve, 100));
    }

    return {
        baseUrl,
        userDirectory: (handle = DEFAULT_HANDLE) => path.join(dataRoot, handle),
        stop: async () => {
            if (child && exitCode === null) {
                const exited = new Promise(resolve => child.once('exit', resolve));
                child.kill('SIGTERM');
                const killTimer = setTimeout(() => child.kill('SIGKILL'), 15000);
                await exited;
                clearTimeout(killTimer);
            }
            fs.rmSync(tempDir, { recursive: true, force: true });
        },
    };
}

const CARD = 'Seraphina';
const CHAT_FILE = 'generation-chat';

/**
 * @param {{userDirectory: (handle?: string) => string}} server The running server.
 * @returns {string} The absolute chat file path.
 */
function chatPath(server) {
    return path.join(server.userDirectory(), 'chats', CARD, `${CHAT_FILE}.jsonl`);
}

/**
 * @param {{userDirectory: (handle?: string) => string}} server The running server.
 * @returns {void}
 */
function seedChat(server) {
    const filePath = chatPath(server);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const lines = [
        JSON.stringify({ user_name: 'You', character_name: CARD, chat_metadata: {} }),
        JSON.stringify({ name: 'You', is_user: true, is_system: false, mes: 'hello', send_date: 1700000000000, extra: {} }),
    ];
    fs.writeFileSync(filePath, lines.join('\n'), 'utf8');
}

/**
 * @param {string} filePath A jsonl chat file.
 * @returns {object[]} Parsed non-empty lines (header first, then messages).
 */
function readChatLines(filePath) {
    return fs.readFileSync(filePath, 'utf8').split('\n').filter(line => line.length > 0).map(line => JSON.parse(line));
}

/**
 * @param {{baseUrl: string}} server The running server.
 * @param {string} handle User handle.
 * @returns {Promise<SillyTavernClient>} A logged-in client.
 */
async function loggedInClient(server, handle = DEFAULT_HANDLE) {
    const client = new SillyTavernClient(server.baseUrl);
    await client.fetchCsrfToken();
    await client.login(handle);
    await client.fetchCsrfToken();
    return client;
}

/**
 * @param {SillyTavernClient} client A logged-in client.
 * @param {string} upstreamUrl The scripted backend base url.
 * @returns {Promise<{status: number, body: any}>} The start response.
 */
async function startGeneration(client, upstreamUrl) {
    const response = await client.postJson('/api/generation/start', {
        chat: { avatar_url: `${CARD}.png`, file_name: CHAT_FILE, character_name: CARD },
        generate: { api_type: 'generic', api_server: upstreamUrl, model: 'mock', prompt: 'hi', max_tokens: 64 },
    });
    return { status: response.status, body: await response.json() };
}

/**
 * @param {{baseUrl: string}} server The running server.
 * @param {SillyTavernClient} client A logged-in client.
 * @param {string} generationId The generation to watch.
 * @param {number} since The resume cursor.
 * @returns {Promise<SseStream>} An open viewer.
 */
function openViewer(server, client, generationId, since) {
    return SseStream.open(server.baseUrl, `/api/generation/${generationId}/stream?since=${since}`, {
        cookieHeader: client.cookieHeader,
        csrfToken: client.csrfToken,
    });
}

/**
 * Text carried by a viewer's frames, in arrival order. The token payloads are the only thing a
 * client ever turns into message text, so this is what "byte-identical" has to mean.
 * @param {SseStream} viewer An open or closed viewer.
 * @returns {string} The concatenated token text.
 */
function textOf(viewer) {
    let text = '';
    for (const frame of viewer.frames) {
        if (frame.data === '[DONE]') {
            continue;
        }
        try {
            text += JSON.parse(frame.data)?.choices?.[0]?.text ?? '';
        } catch {
            // A control payload carries no token text.
        }
    }
    return text;
}

/**
 * @param {() => boolean} predicate Condition to wait for.
 * @param {string} label What the wait is for, used in the timeout message.
 * @returns {Promise<void>}
 */
async function until(predicate, label) {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
        if (predicate()) {
            return;
        }
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error(`Timed out waiting for ${label}`);
}

describe('server-owned generation', () => {
    /** @type {Awaited<ReturnType<typeof startServer>>} */
    let server;

    beforeAll(async () => {
        server = await startServer();
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    });

    test('a completed generation appends exactly one assistant turn', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);
        const before = readChatLines(chatPath(server));

        const started = await startGeneration(client, upstream.baseUrl);
        expect(started.status).toBe(200);
        expect(typeof started.body.generation_id).toBe('string');

        const viewer = await openViewer(server, client, started.body.generation_id, 0);
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(5);
        await viewer.waitForFrameCount(5);
        upstream.finish();
        await viewer.waitForEnd();

        const expectedText = upstream.sent.join('');
        await until(() => readChatLines(chatPath(server)).length === before.length + 1, 'the assistant turn to land');

        const after = readChatLines(chatPath(server));
        expect(after.length).toBe(before.length + 1);
        const appended = after[after.length - 1];
        expect(appended.is_user).toBe(false);
        expect(appended.name).toBe(CARD);
        expect(appended.mes).toBe(expectedText);
        expect(textOf(viewer)).toBe(expectedText);

        // The double-append guard: nothing else may land after the writer is done, and every earlier
        // line must be byte-identical to what was there before the generation ran.
        expect(after.slice(0, before.length).map(line => JSON.stringify(line)))
            .toEqual(before.map(line => JSON.stringify(line)));
        expect(after.filter(line => line.mes === expectedText).length).toBe(1);

        await viewer.close();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a mid-generation disconnect and re-attach yields byte-identical text', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const started = await startGeneration(client, upstream.baseUrl);
        const id = started.body.generation_id;

        const first = await openViewer(server, client, id, 0);
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(4);
        await first.waitForFrameCount(4);
        const cursor = Number(first.frames[first.frames.length - 1].id);
        const firstText = textOf(first);
        await first.close();

        // The generation must survive the viewer leaving: tokens emitted while nobody watches are
        // exactly the ones a resumed viewer would otherwise lose.
        upstream.emit(3);
        expect(upstream.aborted).toBe(false);

        const second = await openViewer(server, client, id, cursor);
        upstream.emit(2);
        upstream.finish();
        await second.waitForEnd();

        const resumedText = firstText + textOf(second);
        expect(resumedText).toBe(upstream.sent.join(''));
        // No frame is served twice: the resumed viewer starts strictly past the cursor.
        expect(Number(second.frames[0].id)).toBe(cursor + 1);

        await until(() => readChatLines(chatPath(server)).length === 3, 'the assistant turn to land');
        const appended = readChatLines(chatPath(server))[2];
        expect(appended.mes).toBe(upstream.sent.join(''));

        await second.close();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a reload onto an active generation resumes rather than truncating', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const started = await startGeneration(client, upstream.baseUrl);
        const id = started.body.generation_id;

        const before = await openViewer(server, client, id, 0);
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(6);
        await before.waitForFrameCount(6);
        await before.close();

        // A reload is a brand new session for the same user: it finds the generation through /active
        // and replays the whole log, so nothing that streamed before the reload is lost.
        const reloaded = await loggedInClient(server);
        const activeResponse = await reloaded.get(`/api/generation/active?avatar_url=${encodeURIComponent(`${CARD}.png`)}&file_name=${encodeURIComponent(CHAT_FILE)}`);
        const active = await activeResponse.json();
        expect(active.active).toBe(true);
        expect(active.generation_id).toBe(id);

        const viewer = await openViewer(server, reloaded, active.generation_id, 0);
        upstream.emit(4);
        upstream.finish();
        await viewer.waitForEnd();

        const wholeText = upstream.sent.join('');
        expect(textOf(viewer)).toBe(wholeText);

        await until(() => readChatLines(chatPath(server)).length === 3, 'the assistant turn to land');
        const appended = readChatLines(chatPath(server))[2];
        // The truncation guard: the file holds every token, including the six that streamed before
        // the reload, not just what arrived after it.
        expect(appended.mes).toBe(wholeText);
        expect(appended.mes.startsWith('tok0 ')).toBe(true);
        expect(appended.mes.endsWith('tok9 ')).toBe(true);

        await viewer.close();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('stop ends the generation and persists what arrived', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const started = await startGeneration(client, upstream.baseUrl);
        const id = started.body.generation_id;

        const viewer = await openViewer(server, client, id, 0);
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(3);
        await viewer.waitForFrameCount(3);

        const stopped = await client.postJson(`/api/generation/${id}/stop`, {});
        expect(stopped.status).toBe(200);
        expect((await stopped.json()).status).toBe('stopped');

        await viewer.waitForEnd();
        await until(() => upstream.aborted, 'the upstream to be aborted');

        const activeResponse = await client.get(`/api/generation/active?avatar_url=${encodeURIComponent(`${CARD}.png`)}&file_name=${encodeURIComponent(CHAT_FILE)}`);
        expect((await activeResponse.json()).active).toBe(false);

        await until(() => readChatLines(chatPath(server)).length === 3, 'the partial turn to land');
        expect(readChatLines(chatPath(server))[2].mes).toBe(upstream.sent.join(''));

        await viewer.close();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a client disconnect does not abort the upstream', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const started = await startGeneration(client, upstream.baseUrl);
        const viewer = await openViewer(server, client, started.body.generation_id, 0);
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(2);
        await viewer.waitForFrameCount(2);
        await viewer.close();

        upstream.emit(2);
        expect(upstream.aborted).toBe(false);
        upstream.finish();

        await until(() => readChatLines(chatPath(server)).length === 3, 'the assistant turn to land');
        expect(readChatLines(chatPath(server))[2].mes).toBe(upstream.sent.join(''));

        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a resume past what the log can serve reports a resync instead of a hole', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const started = await startGeneration(client, upstream.baseUrl);
        const id = started.body.generation_id;
        await until(() => upstream.live !== null, 'the upstream request');
        upstream.emit(2);

        const viewer = await openViewer(server, client, id, 99);
        await viewer.waitForEnd();
        expect(viewer.frames.map(frame => frame.event)).toContain('resync');
        expect(textOf(viewer)).toBe('');

        upstream.finish();
        await viewer.close();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a start for a chat that is already generating is refused', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);

        const first = await startGeneration(client, upstream.baseUrl);
        expect(first.status).toBe(200);
        await until(() => upstream.live !== null, 'the upstream request');

        const second = await startGeneration(client, upstream.baseUrl);
        expect(second.status).toBe(409);
        expect(second.body.generation_id).toBe(first.body.generation_id);
        expect(upstream.requests).toBe(1);

        upstream.finish();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);

    test('a start whose chat target escapes the user root is refused', async () => {
        const client = await loggedInClient(server);
        const response = await client.postJson('/api/generation/start', {
            chat: { avatar_url: '../../../etc/passwd.png', file_name: '../../escape', character_name: 'x' },
            generate: { api_type: 'generic', api_server: 'http://127.0.0.1:1', prompt: 'hi' },
        });
        expect(response.status).toBe(400);
        expect((await response.json()).error).toBe('bad_chat_target');
    }, CASE_TIMEOUT_MS);

    test('a generation stream is not reachable without a session', async () => {
        seedChat(server);
        const upstream = new ScriptedUpstream();
        await upstream.start();
        const client = await loggedInClient(server);
        const started = await startGeneration(client, upstream.baseUrl);

        const anonymous = await fetch(`${server.baseUrl}/api/generation/${started.body.generation_id}/stream?since=0`);
        await anonymous.arrayBuffer();
        expect(anonymous.status).not.toBe(200);

        upstream.finish();
        await upstream.stop();
    }, CASE_TIMEOUT_MS);
});

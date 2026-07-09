import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { MockServer } from './util/mock-server.js';
import { SillyTavernServer, DEFAULT_HANDLE, SERVER_ROOT, allocatePort } from './util/st-server.js';
import { SillyTavernClient } from './util/st-client.js';
import { characterCardV2, chatMessages } from './util/fixtures.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const SECRET_KEY = 'api_key_openai';
const SECRET_VALUE = 'sk-smoke-ABCDEFGHIJ-xyz';
const MASKED_SECRET_VALUE = '*******xyz';

describe('SillyTavern server smoke suite', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {MockServer} */
    let upstream;
    /** @type {SillyTavernClient} */
    let client;
    /** @type {string} */
    let upstreamUrl;
    /** @type {{ version: string }} */
    let packageJson;

    beforeAll(async () => {
        packageJson = JSON.parse(fs.readFileSync(path.join(SERVER_ROOT, 'package.json'), 'utf8'));

        const upstreamPort = await allocatePort();
        upstream = new MockServer({ port: upstreamPort, host: '127.0.0.1' });
        await upstream.start();
        upstreamUrl = `http://127.0.0.1:${upstreamPort}/v1/chat/completions`;

        server = new SillyTavernServer();
        await server.start();

        client = new SillyTavernClient(server.baseUrl);
        await client.fetchCsrfToken();
        const login = await client.login(DEFAULT_HANDLE);
        if (login.status !== 200) {
            throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
        }
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await upstream?.stop();
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    test('unauthenticated_request_to_private_route_is_rejected', async () => {
        const anonymous = new SillyTavernClient(server.baseUrl);

        const response = await anonymous.get('/version');

        expect(response.status).toBe(403);
        expect(anonymous.cookieNames).toEqual([]);
    }, CASE_TIMEOUT_MS);

    test('login_with_valid_handle_sets_session_cookie_and_authorizes_private_route', async () => {
        const fresh = new SillyTavernClient(server.baseUrl);
        const token = await fresh.fetchCsrfToken();
        expect(token).toHaveLength(64);

        const login = await fresh.login(DEFAULT_HANDLE);

        expect(login.status).toBe(200);
        expect(await login.json()).toEqual({ handle: DEFAULT_HANDLE });
        expect(fresh.cookieNames.some(name => name.startsWith('session-'))).toBe(true);

        const authorized = await fresh.get('/version');
        expect(authorized.status).toBe(200);
        expect((await authorized.json()).pkgVersion).toBe(packageJson.version);
    }, CASE_TIMEOUT_MS);

    test('login_with_unknown_handle_is_rejected_with_generic_error', async () => {
        const fresh = new SillyTavernClient(server.baseUrl);
        await fresh.fetchCsrfToken();

        const login = await fresh.login('no-such-user');

        expect(login.status).toBe(403);
        expect(await login.json()).toEqual({ error: 'Incorrect credentials' });
    }, CASE_TIMEOUT_MS);

    test('character_import_persists_card_to_disk_and_appears_in_character_list', async () => {
        const card = characterCardV2('SmokeChar', { description: 'desc-marker-42', first_mes: 'greeting-marker-7' });
        const form = new FormData();
        form.append('file_type', 'json');
        form.append('avatar', new Blob([JSON.stringify(card)], { type: 'application/json' }), 'SmokeChar.json');

        const imported = await client.postForm('/api/characters/import', form);

        expect(imported.status).toBe(200);
        expect(await imported.json()).toEqual({ file_name: 'SmokeChar' });

        const avatarPath = path.join(server.userDirectory(), 'characters', 'SmokeChar.png');
        expect(fs.existsSync(avatarPath)).toBe(true);
        expect(fs.readFileSync(avatarPath).subarray(0, 8)).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));

        const listed = await client.postJson('/api/characters/all', {});
        expect(listed.status).toBe(200);
        const entry = (await listed.json()).find(character => character.name === 'SmokeChar');
        expect(entry).toBeDefined();
        expect(entry.description).toBe('desc-marker-42');

        const fetched = await client.postJson('/api/characters/get', { avatar_url: 'SmokeChar.png' });
        expect(fetched.status).toBe(200);
        expect((await fetched.json()).first_mes).toBe('greeting-marker-7');
    }, CASE_TIMEOUT_MS);

    test('chat_save_then_get_round_trips_messages_byte_for_byte', async () => {
        const avatarUrl = 'ChatSmokeChar.png';
        const fileName = 'smoke-chat';
        const messages = chatMessages('ChatSmokeChar');

        const bootstrap = await client.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: '' });
        expect(bootstrap.status).toBe(200);

        const saved = await client.postJson('/api/chats/save', {
            avatar_url: avatarUrl,
            file_name: fileName,
            chat: messages,
            force: true,
        });
        expect(saved.status).toBe(200);
        expect(await saved.json()).toEqual({ ok: true });

        const reloaded = await client.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: fileName });
        expect(reloaded.status).toBe(200);
        expect(await reloaded.json()).toEqual(messages);

        const chatPath = path.join(server.userDirectory(), 'chats', 'ChatSmokeChar', `${fileName}.jsonl`);
        expect(fs.readFileSync(chatPath, 'utf8')).toBe(messages.map(message => JSON.stringify(message)).join('\n'));
    }, CASE_TIMEOUT_MS);

    test('cors_proxy_forwards_request_body_and_returns_upstream_response', async () => {
        const response = await client.postThroughProxy(upstreamUrl, {
            model: 'gpt-4o',
            max_tokens: 7,
            messages: [{ role: 'user', content: 'Hello, proxy!' }],
        });

        expect(response.status).toBe(200);
        expect(await response.json()).toEqual({
            choices: [{
                finish_reason: 'stop',
                index: 0,
                message: {
                    role: 'assistant',
                    reasoning_content: 'gpt-4o\n1\n7',
                    content: 'Hello, proxy!',
                },
            }],
            created: 0,
            model: 'gpt-4o',
        });
    }, CASE_TIMEOUT_MS);

    test('cors_proxy_rejects_a_circular_request_to_its_own_origin', async () => {
        const response = await client.postThroughProxy(`${server.baseUrl}/version`, {});

        expect(response.status).toBe(400);
        expect(await response.text()).toBe('Circular requests are not allowed');
    }, CASE_TIMEOUT_MS);

    test('unhandled_route_error_is_returned_as_json_by_the_error_middleware', async () => {
        const response = await client.postRaw('/api/ping', '{not valid json', 'application/json');

        expect(response.status).toBe(400);
        expect(response.headers.get('content-type')).toMatch(/^application\/json/);
        expect(await response.json()).toEqual({ error: true, message: 'Bad Request' });
    }, CASE_TIMEOUT_MS);

    test('secret_write_then_read_returns_masked_value_and_persists_plaintext', async () => {
        const written = await client.postJson('/api/secrets/write', {
            key: SECRET_KEY,
            value: SECRET_VALUE,
            label: 'smoke',
        });
        expect(written.status).toBe(200);
        const { id } = await written.json();
        expect(id).toEqual(expect.any(String));

        const state = await client.postJson('/api/secrets/read', {});
        expect(state.status).toBe(200);
        const body = await state.json();

        expect(body[SECRET_KEY]).toEqual([{ id, value: MASKED_SECRET_VALUE, label: 'smoke', active: true }]);
        expect(JSON.stringify(body)).not.toContain(SECRET_VALUE);

        const secretsPath = path.join(server.userDirectory(), 'secrets.json');
        const onDisk = JSON.parse(fs.readFileSync(secretsPath, 'utf8'));
        expect(onDisk[SECRET_KEY]).toEqual([{ id, value: SECRET_VALUE, label: 'smoke', active: true }]);
    }, CASE_TIMEOUT_MS);

    test('frontend_lib_bundle_compiles_and_is_served', async () => {
        const response = await client.get('/lib.js');

        expect(response.status).toBe(200);
        expect(response.headers.get('content-type')).toMatch(/javascript/);
        const body = await response.text();
        expect(body.length).toBeGreaterThan(10000);
    }, CASE_TIMEOUT_MS);
});

import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

/**
 * @param {SillyTavernServer} server The running server.
 * @returns {string} The absolute path to the default user's settings.json.
 */
function settingsPath(server) {
    return path.join(server.userDirectory(), 'settings.json');
}

/**
 * @param {SillyTavernServer} server The running server.
 * @param {object} settings The settings object to seed.
 */
function writeSettings(server, settings) {
    fs.writeFileSync(settingsPath(server), JSON.stringify(settings, null, 4), 'utf8');
}

/**
 * @param {SillyTavernServer} server The running server.
 * @returns {object} The parsed settings.json.
 */
function readSettings(server) {
    return JSON.parse(fs.readFileSync(settingsPath(server), 'utf8'));
}

/**
 * @param {SillyTavernServer} server The running server.
 * @returns {Promise<SillyTavernClient>} A logged-in client.
 */
async function loggedInClient(server) {
    const client = new SillyTavernClient(server.baseUrl);
    await client.fetchCsrfToken();
    const login = await client.login(DEFAULT_HANDLE);
    if (login.status !== 200) {
        throw new Error(`Client failed to log in: ${login.status} ${await login.text()}`);
    }
    return client;
}

describe('settings set-connection merge', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let client;

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start();
        client = await loggedInClient(server);
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    test('set_connection_merges_the_fields_and_preserves_every_unrelated_key', async () => {
        writeSettings(server, {
            main_api: 'openai',
            unrelated_top: 'keep-me',
            power_user: { blur_strength: 7, nested: 'keep-me-too' },
            textgenerationwebui_settings: {
                existing_sub: 'preserve',
                temp: 0.9,
                server_urls: { ooba: 'http://old-ooba:5000' },
            },
        });

        const response = await client.postJson('/api/settings/set-connection', {
            api_type: 'llamacpp', api_server: 'http://127.0.0.1:8080',
        });
        expect(response.status).toBe(200);
        expect(await response.json()).toEqual({ ok: true, connection: { api_type: 'llamacpp', api_server: 'http://127.0.0.1:8080' } });

        const settings = readSettings(server);
        expect(settings.main_api).toBe('textgenerationwebui');
        expect(settings.textgenerationwebui_settings.type).toBe('llamacpp');
        expect(settings.textgenerationwebui_settings.server_urls.llamacpp).toBe('http://127.0.0.1:8080');

        expect(settings.unrelated_top).toBe('keep-me');
        expect(settings.power_user).toEqual({ blur_strength: 7, nested: 'keep-me-too' });
        expect(settings.textgenerationwebui_settings.existing_sub).toBe('preserve');
        expect(settings.textgenerationwebui_settings.temp).toBe(0.9);
        expect(settings.textgenerationwebui_settings.server_urls.ooba).toBe('http://old-ooba:5000');
    }, CASE_TIMEOUT_MS);

    test('set_connection_creates_the_nested_objects_when_absent', async () => {
        writeSettings(server, { main_api: 'kobold', some_flag: true });

        const response = await client.postJson('/api/settings/set-connection', {
            api_type: 'llamacpp', api_server: 'http://localhost:8081',
        });
        expect(response.status).toBe(200);

        const settings = readSettings(server);
        expect(settings.main_api).toBe('textgenerationwebui');
        expect(settings.textgenerationwebui_settings.type).toBe('llamacpp');
        expect(settings.textgenerationwebui_settings.server_urls.llamacpp).toBe('http://localhost:8081');
        expect(settings.some_flag).toBe(true);
    }, CASE_TIMEOUT_MS);

    test('set_connection_keys_server_urls_by_a_general_api_type', async () => {
        writeSettings(server, { main_api: 'openai', textgenerationwebui_settings: { server_urls: { llamacpp: 'http://keep' } } });

        const response = await client.postJson('/api/settings/set-connection', {
            api_type: 'tabby', api_server: 'http://tabby:5000',
        });
        expect(response.status).toBe(200);

        const settings = readSettings(server);
        expect(settings.textgenerationwebui_settings.type).toBe('tabby');
        expect(settings.textgenerationwebui_settings.server_urls.tabby).toBe('http://tabby:5000');
        expect(settings.textgenerationwebui_settings.server_urls.llamacpp).toBe('http://keep');
    }, CASE_TIMEOUT_MS);

    test('set_connection_is_visible_through_settings_get', async () => {
        writeSettings(server, { main_api: 'openai' });

        const setResponse = await client.postJson('/api/settings/set-connection', {
            api_type: 'llamacpp', api_server: 'http://127.0.0.1:9090',
        });
        expect(setResponse.status).toBe(200);

        const getResponse = await client.postJson('/api/settings/get', {});
        expect(getResponse.status).toBe(200);
        const parsed = JSON.parse((await getResponse.json()).settings);
        expect(parsed.main_api).toBe('textgenerationwebui');
        expect(parsed.textgenerationwebui_settings.server_urls.llamacpp).toBe('http://127.0.0.1:9090');
    }, CASE_TIMEOUT_MS);

    test('set_connection_rejects_a_missing_api_server_without_touching_settings', async () => {
        writeSettings(server, { main_api: 'openai', keep: 'this' });
        const before = fs.readFileSync(settingsPath(server), 'utf8');

        const response = await client.postJson('/api/settings/set-connection', { api_type: 'llamacpp' });
        expect(response.status).toBe(400);

        expect(fs.readFileSync(settingsPath(server), 'utf8')).toBe(before);
    }, CASE_TIMEOUT_MS);

    test('set_connection_rejects_an_empty_api_type', async () => {
        writeSettings(server, { main_api: 'openai' });
        const response = await client.postJson('/api/settings/set-connection', { api_type: '', api_server: 'http://x' });
        expect(response.status).toBe(400);
    }, CASE_TIMEOUT_MS);

    test('set_connection_rejects_a_non_string_api_server', async () => {
        writeSettings(server, { main_api: 'openai' });
        const response = await client.postJson('/api/settings/set-connection', { api_type: 'llamacpp', api_server: 1234 });
        expect(response.status).toBe(400);
    }, CASE_TIMEOUT_MS);

    test('set_connection_rejects_a_prototype_polluting_api_type', async () => {
        writeSettings(server, { main_api: 'openai' });
        const response = await client.postJson('/api/settings/set-connection', { api_type: '__proto__', api_server: 'http://x' });
        expect(response.status).toBe(400);
    }, CASE_TIMEOUT_MS);
});

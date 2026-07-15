import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

describe('character list cache invalidation', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let client;

    beforeAll(async () => {
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
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    /**
     * Fetches the character list and returns the entry for one avatar, if present.
     * @param {string} avatar Avatar filename
     * @returns {Promise<object|undefined>} The matching list entry, or undefined
     */
    async function findEntry(avatar) {
        const response = await client.postJson('/api/characters/all', {});
        expect(response.status).toBe(200);
        return (await response.json()).find(character => character.avatar === avatar);
    }

    test('character_all_reflects_a_freshly_created_character', async () => {
        // Warm the cache before the character exists, so a stale empty list would be caught.
        expect(await findEntry('CacheCreate.png')).toBeUndefined();

        const create = await client.postJson('/api/characters/create', {
            file_name: 'CacheCreate',
            ch_name: 'CacheCreate',
            description: 'create-marker',
        });
        expect(create.status).toBe(200);

        const entry = await findEntry('CacheCreate.png');
        expect(entry).toBeDefined();
        expect(entry.description).toBe('create-marker');
    }, CASE_TIMEOUT_MS);

    test('character_all_serves_the_edited_description_not_a_cached_copy', async () => {
        const create = await client.postJson('/api/characters/create', {
            file_name: 'CacheEdit',
            ch_name: 'CacheEdit',
            description: 'before-edit',
        });
        expect(create.status).toBe(200);

        // Warm the cache with the pre-edit value.
        expect((await findEntry('CacheEdit.png')).description).toBe('before-edit');

        const edit = await client.postJson('/api/characters/edit', {
            avatar_url: 'CacheEdit.png',
            ch_name: 'CacheEdit',
            description: 'after-edit',
            create_date: new Date().toISOString(),
        });
        expect(edit.status).toBe(200);

        const entry = await findEntry('CacheEdit.png');
        expect(entry).toBeDefined();
        expect(entry.description).toBe('after-edit');
    }, CASE_TIMEOUT_MS);

    test('character_all_drops_a_deleted_character_from_a_warm_cache', async () => {
        const create = await client.postJson('/api/characters/create', {
            file_name: 'CacheDelete',
            ch_name: 'CacheDelete',
        });
        expect(create.status).toBe(200);

        // Warm the cache: the character is present before deletion.
        expect(await findEntry('CacheDelete.png')).toBeDefined();

        const del = await client.postJson('/api/characters/delete', { avatar_url: 'CacheDelete.png' });
        expect(del.status).toBe(200);

        expect(await findEntry('CacheDelete.png')).toBeUndefined();
    }, CASE_TIMEOUT_MS);

    test('character_all_recomputes_chat_size_when_a_new_chat_file_appears', async () => {
        const create = await client.postJson('/api/characters/create', {
            file_name: 'CacheChat',
            ch_name: 'CacheChat',
        });
        expect(create.status).toBe(200);

        // Warm the cache while the chat directory is still empty.
        expect((await findEntry('CacheChat.png')).chat_size).toBe(0);

        const save = await client.postJson('/api/chats/save', {
            avatar_url: 'CacheChat.png',
            file_name: 'cache-chat-file',
            chat: [{ name: 'CacheChat', is_user: false, mes: 'hello from the cache test', send_date: Date.now() }],
            force: true,
        });
        expect(save.status).toBe(200);

        // The new chat file moves the chat-directory mtime, so the probe rebuilds the entry.
        const entry = await findEntry('CacheChat.png');
        expect(entry).toBeDefined();
        expect(entry.chat_size).toBeGreaterThan(0);
    }, CASE_TIMEOUT_MS);
});

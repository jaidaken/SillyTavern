import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

/**
 * @param {string} characterName Character name for the header.
 * @returns {object} A chat metadata header line.
 */
function chatHeader(characterName) {
    return { user_name: 'You', character_name: characterName, chat_metadata: { integrity: 'meta-cache-test' } };
}

/**
 * @param {number} count Number of messages.
 * @returns {object[]} Ordered messages whose mes text encodes its index.
 */
function buildMessages(count) {
    const messages = [];
    for (let i = 0; i < count; i++) {
        messages.push({
            name: i % 2 === 0 ? 'You' : 'Bot',
            is_user: i % 2 === 0,
            mes: `message ${i}`,
            send_date: 1700000000000 + i,
            extra: {},
        });
    }
    return messages;
}

/**
 * @param {SillyTavernServer} server The running server.
 * @param {string} card The character card name without extension.
 * @param {string} fileName The chat file name without extension.
 * @returns {string} The absolute solo chat file path.
 */
function soloChatPath(server, card, fileName) {
    return path.join(server.userDirectory(), 'chats', card, `${fileName}.jsonl`);
}

/**
 * Writes a header plus messages as jsonl, creating parent directories.
 * @param {string} filePath Target file path.
 * @param {object} header Header line object.
 * @param {object[]} messages Message objects.
 */
function writeChatFile(filePath, header, messages) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const lines = [JSON.stringify(header), ...messages.map(m => JSON.stringify(m))];
    fs.writeFileSync(filePath, lines.join('\n'), 'utf8');
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
        throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
    }
    return client;
}

/**
 * @param {SillyTavernClient} client A logged-in client.
 * @param {string} avatarUrl The character avatar file name.
 * @param {string} [query] Optional content search query.
 * @returns {Promise<object[]>} The /search result rows.
 */
async function search(client, avatarUrl, query) {
    const response = await client.postJson('/api/chats/search', { avatar_url: avatarUrl, query });
    expect(response.status).toBe(200);
    return response.json();
}

describe('chat-metadata cache', () => {
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

    test('search_after_a_save_reflects_the_new_count_with_no_stale_value', async () => {
        const card = 'CardSave';
        fs.mkdirSync(path.dirname(soloChatPath(server, card, 'chatSave')), { recursive: true });

        const first = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatSave', force: true, chat: [chatHeader(card), ...buildMessages(3)],
        });
        expect(first.status).toBe(200);

        let rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].message_count).toBe(3);
        expect(rows[0].preview_message).toBe('message 2');

        const second = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatSave', force: true, chat: [chatHeader(card), ...buildMessages(5)],
        });
        expect(second.status).toBe(200);

        rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].message_count).toBe(5);
        expect(rows[0].preview_message).toBe('message 4');
    }, CASE_TIMEOUT_MS);

    test('out_of_band_edit_is_caught_by_the_mtime_size_probe', async () => {
        const card = 'CardOob';
        const filePath = soloChatPath(server, card, 'chatOob');

        writeChatFile(filePath, chatHeader(card), buildMessages(4));
        let rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].message_count).toBe(4);
        expect(rows[0].preview_message).toBe('message 3');

        // A direct write the server never saw: the count and size change, so the probe must miss the cached entry.
        writeChatFile(filePath, chatHeader(card), buildMessages(7));
        rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].message_count).toBe(7);
        expect(rows[0].preview_message).toBe('message 6');
    }, CASE_TIMEOUT_MS);

    test('delete_busts_the_entry_so_a_recreated_file_reads_fresh', async () => {
        const card = 'CardBust';
        const filePath = soloChatPath(server, card, 'chatBust');
        // A fixed mtime plus equal byte size makes the recreated file indistinguishable to the mtime probe,
        // so only an explicit delete-bust can keep the second read from returning the stale ALPHA preview.
        const fixedTime = new Date(1700000100000);

        const alpha = buildMessages(3);
        alpha[2].mes = 'ALPHA';
        writeChatFile(filePath, chatHeader(card), alpha);
        fs.utimesSync(filePath, fixedTime, fixedTime);

        let rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].preview_message).toBe('ALPHA');

        const deleted = await client.postJson('/api/chats/delete', { avatar_url: `${card}.png`, chatfile: 'chatBust.jsonl' });
        expect(deleted.status).toBe(200);

        const omega = buildMessages(3);
        omega[2].mes = 'OMEGA';
        writeChatFile(filePath, chatHeader(card), omega);
        fs.utimesSync(filePath, fixedTime, fixedTime);
        expect(fs.statSync(filePath).mtimeMs).toBe(fixedTime.getTime());

        rows = await search(client, `${card}.png`);
        expect(rows).toHaveLength(1);
        expect(rows[0].message_count).toBe(3);
        expect(rows[0].preview_message).toBe('OMEGA');
    }, CASE_TIMEOUT_MS);

    test('query_search_still_matches_message_content_through_a_cached_file', async () => {
        const card = 'CardQuery';
        const filePath = soloChatPath(server, card, 'chatQuery');
        const messages = buildMessages(3);
        messages[1].mes = 'the zephyrword hides here';
        writeChatFile(filePath, chatHeader(card), messages);

        // Prime the cache via a no-query listing first; the content match must still stream, not short-circuit.
        const listed = await search(client, `${card}.png`);
        expect(listed).toHaveLength(1);

        const hit = await search(client, `${card}.png`, 'zephyrword');
        expect(hit).toHaveLength(1);
        expect(hit[0].message_count).toBe(3);

        const miss = await search(client, `${card}.png`, 'absentxyztoken');
        expect(miss).toHaveLength(0);
    }, CASE_TIMEOUT_MS);

    test('recent_reflects_an_in_place_save_update', async () => {
        const card = 'CardRecent';
        const charactersDir = path.join(server.userDirectory(), 'characters');
        fs.mkdirSync(charactersDir, { recursive: true });
        fs.writeFileSync(path.join(charactersDir, `${card}.png`), Buffer.from([0]));
        fs.mkdirSync(path.dirname(soloChatPath(server, card, 'chatRecent')), { recursive: true });

        const first = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatRecent', force: true, chat: [chatHeader(card), ...buildMessages(3)],
        });
        expect(first.status).toBe(200);

        const findRow = (rows) => rows.find(row => row.file_id === 'chatRecent');

        let recent = await client.postJson('/api/chats/recent', {});
        expect(recent.status).toBe(200);
        let row = findRow(await recent.json());
        expect(row).toBeDefined();
        expect(row.chat_items).toBe(3);
        expect(row.mes).toBe('message 2');

        const second = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatRecent', force: true, chat: [chatHeader(card), ...buildMessages(6)],
        });
        expect(second.status).toBe(200);

        recent = await client.postJson('/api/chats/recent', {});
        expect(recent.status).toBe(200);
        row = findRow(await recent.json());
        expect(row).toBeDefined();
        expect(row.chat_items).toBe(6);
        expect(row.mes).toBe('message 5');
    }, CASE_TIMEOUT_MS);
});

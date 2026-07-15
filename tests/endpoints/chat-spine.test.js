import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import yaml from 'yaml';

import { SillyTavernServer, DEFAULT_HANDLE, allocatePort, SERVER_ROOT } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const CFID_ENV = 'SILLYTAVERN_CHAT_CFID_ENABLED';

// Jest sandboxes process.env, so a runtime mutation never reaches child_process.spawn.
// The flag-on server is booted here with an explicit env so the child actually sees the flag.
const SMOKE_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: true,
    enableCorsProxy: true,
});

/**
 * Boots server.js against a throwaway data root with an explicit environment.
 * @param {Record<string, string>} extraEnv Environment overrides for the child.
 * @returns {Promise<{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}>}
 */
async function startServerWithEnv(extraEnv) {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-cfid-'));
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

/**
 * @param {string} characterName Character name for the header.
 * @returns {object} A chat metadata header line.
 */
function chatHeader(characterName) {
    return { user_name: 'You', character_name: characterName, chat_metadata: { integrity: 'spine-test' } };
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
 * @returns {string} The absolute chat file path.
 */
function soloChatPath(server, card, fileName) {
    return path.join(server.userDirectory(), 'chats', card, `${fileName}.jsonl`);
}

/**
 * @param {SillyTavernServer} server The running server.
 * @param {string} id The group chat id.
 * @returns {string} The absolute group chat file path.
 */
function groupChatPath(server, id) {
    return path.join(server.userDirectory(), 'group chats', `${id}.jsonl`);
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
 * @param {string} filePath A jsonl chat file.
 * @returns {object[]} Parsed non-empty lines (header first, then messages).
 */
function readChatLines(filePath) {
    return fs.readFileSync(filePath, 'utf8').split('\n').filter(line => line.length > 0).map(line => JSON.parse(line));
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

describe('chat spine paged reads (cf_id flag off)', () => {
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

    test('non_paged_get_returns_the_full_array_unchanged', async () => {
        writeChatFile(soloChatPath(server, 'CardFull', 'chatFull'), chatHeader('CardFull'), buildMessages(5));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardFull.png', file_name: 'chatFull' });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(Array.isArray(body)).toBe(true);
        expect(body).toHaveLength(6);
        expect(body[0].user_name).toBe('You');
        expect(body[5].mes).toBe('message 4');
    }, CASE_TIMEOUT_MS);

    test('paged_tail_returns_the_last_limit_messages', async () => {
        writeChatFile(soloChatPath(server, 'CardTail', 'chatTail'), chatHeader('CardTail'), buildMessages(200));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardTail.png', file_name: 'chatTail', paged: true, limit: 50 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(50);
        expect(body.messages[0].mes).toBe('message 150');
        expect(body.messages[49].mes).toBe('message 199');
        expect(body.has_more_before).toBe(true);
        expect(body.has_more_after).toBe(false);
        expect(body.total_items).toBe(200);
    }, CASE_TIMEOUT_MS);

    test('paged_before_index_returns_the_older_slice', async () => {
        writeChatFile(soloChatPath(server, 'CardBefore', 'chatBefore'), chatHeader('CardBefore'), buildMessages(200));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardBefore.png', file_name: 'chatBefore', paged: true, limit: 50, before_index: 150 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(50);
        expect(body.messages[0].mes).toBe('message 100');
        expect(body.messages[49].mes).toBe('message 149');
        expect(body.has_more_before).toBe(true);
        expect(body.has_more_after).toBe(true);
    }, CASE_TIMEOUT_MS);

    test('paged_first_page_reports_no_more_before', async () => {
        writeChatFile(soloChatPath(server, 'CardFirst', 'chatFirst'), chatHeader('CardFirst'), buildMessages(200));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardFirst.png', file_name: 'chatFirst', paged: true, limit: 50, before_index: 30 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(30);
        expect(body.messages[0].mes).toBe('message 0');
        expect(body.messages[29].mes).toBe('message 29');
        expect(body.has_more_before).toBe(false);
        expect(body.has_more_after).toBe(true);
    }, CASE_TIMEOUT_MS);

    test('paged_around_index_centres_on_the_anchor', async () => {
        writeChatFile(soloChatPath(server, 'CardAround', 'chatAround'), chatHeader('CardAround'), buildMessages(200));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardAround.png', file_name: 'chatAround', paged: true, limit: 20, around_index: 100 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(21);
        expect(body.anchor_index).toBe(100);
        const anchorPosition = body.messages.findIndex(message => message.mes === 'message 100');
        expect(anchorPosition).toBe(10);
        expect(body.messages[0].mes).toBe('message 90');
        expect(body.messages[20].mes).toBe('message 110');
    }, CASE_TIMEOUT_MS);

    test('paged_absent_chat_returns_empty_page_not_error', async () => {
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardMissing.png', file_name: 'nope', paged: true, limit: 50 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(0);
        expect(body.total_items).toBe(0);
        expect(body.anchor_found).toBe(false);
        expect(body.has_more_before).toBe(false);
    }, CASE_TIMEOUT_MS);

    test('paged_limit_is_caller_owned_with_no_hidden_cap', async () => {
        writeChatFile(soloChatPath(server, 'CardNoCap', 'chatNoCap'), chatHeader('CardNoCap'), buildMessages(500));
        const response = await client.postJson('/api/chats/get', { avatar_url: 'CardNoCap.png', file_name: 'chatNoCap', paged: true, limit: 100000 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(500);
        expect(body.has_more_before).toBe(false);
        expect(body.has_more_after).toBe(false);
    }, CASE_TIMEOUT_MS);

    test('offset_scroll_up_yields_every_message_once_with_no_dupes_or_drops', async () => {
        const total = 137;
        writeChatFile(soloChatPath(server, 'CardScroll', 'chatScroll'), chatHeader('CardScroll'), buildMessages(total));

        let response = await client.postJson('/api/chats/get', { avatar_url: 'CardScroll.png', file_name: 'chatScroll', paged: true, limit: 40 });
        let body = await response.json();
        let collected = body.messages.slice();
        let token = body.change_token;

        while (body.has_more_before) {
            const oldestIndex = Number(collected[0].mes.split(' ')[1]);
            response = await client.postJson('/api/chats/get', {
                avatar_url: 'CardScroll.png', file_name: 'chatScroll', paged: true, limit: 40, before_index: oldestIndex, change_token: token,
            });
            expect(response.status).toBe(200);
            body = await response.json();
            collected = body.messages.concat(collected);
            token = body.change_token;
        }

        expect(collected).toHaveLength(total);
        for (let i = 0; i < total; i++) {
            expect(collected[i].mes).toBe(`message ${i}`);
        }
    }, CASE_TIMEOUT_MS);

    test('append_between_pages_does_not_return_409', async () => {
        const filePath = soloChatPath(server, 'CardAppend', 'chatAppend');
        writeChatFile(filePath, chatHeader('CardAppend'), buildMessages(100));

        const tail = await (await client.postJson('/api/chats/get', { avatar_url: 'CardAppend.png', file_name: 'chatAppend', paged: true, limit: 40 })).json();
        const token = tail.change_token;
        const oldestIndex = Number(tail.messages[0].mes.split(' ')[1]);

        const messages = buildMessages(100);
        messages.push({ name: 'You', is_user: true, mes: 'appended tail', send_date: 1700000000999, extra: {} });
        writeChatFile(filePath, chatHeader('CardAppend'), messages);

        const response = await client.postJson('/api/chats/get', {
            avatar_url: 'CardAppend.png', file_name: 'chatAppend', paged: true, limit: 40, before_index: oldestIndex, change_token: token,
        });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages[0].mes).toBe('message 20');
        expect(body.messages[body.messages.length - 1].mes).toBe('message 59');
    }, CASE_TIMEOUT_MS);

    test('edit_above_anchor_returns_409_and_the_client_can_resync', async () => {
        const filePath = soloChatPath(server, 'CardEdit', 'chatEdit');
        writeChatFile(filePath, chatHeader('CardEdit'), buildMessages(100));

        const tail = await (await client.postJson('/api/chats/get', { avatar_url: 'CardEdit.png', file_name: 'chatEdit', paged: true, limit: 40 })).json();
        const token = tail.change_token;
        const oldestIndex = Number(tail.messages[0].mes.split(' ')[1]);

        const messages = buildMessages(100);
        messages[10].mes = 'edited above the anchor';
        writeChatFile(filePath, chatHeader('CardEdit'), messages);

        const stale = await client.postJson('/api/chats/get', {
            avatar_url: 'CardEdit.png', file_name: 'chatEdit', paged: true, limit: 40, before_index: oldestIndex, change_token: token,
        });
        expect(stale.status).toBe(409);
        const staleBody = await stale.json();
        expect(staleBody.error).toBe('stale');
        expect(typeof staleBody.change_token).toBe('string');

        const resync = await client.postJson('/api/chats/get', { avatar_url: 'CardEdit.png', file_name: 'chatEdit', paged: true, limit: 40 });
        expect(resync.status).toBe(200);
        const resyncBody = await resync.json();
        expect(resyncBody.messages).toHaveLength(40);
    }, CASE_TIMEOUT_MS);

    test('delete_above_anchor_returns_409_and_the_client_can_resync', async () => {
        const filePath = soloChatPath(server, 'CardDelete', 'chatDelete');
        writeChatFile(filePath, chatHeader('CardDelete'), buildMessages(100));

        const tail = await (await client.postJson('/api/chats/get', { avatar_url: 'CardDelete.png', file_name: 'chatDelete', paged: true, limit: 40 })).json();
        const token = tail.change_token;
        const oldestIndex = Number(tail.messages[0].mes.split(' ')[1]);

        const messages = buildMessages(100);
        messages.splice(10, 1);
        writeChatFile(filePath, chatHeader('CardDelete'), messages);

        const stale = await client.postJson('/api/chats/get', {
            avatar_url: 'CardDelete.png', file_name: 'chatDelete', paged: true, limit: 40, before_index: oldestIndex, change_token: token,
        });
        expect(stale.status).toBe(409);
        const staleBody = await stale.json();
        expect(staleBody.error).toBe('stale');
        expect(typeof staleBody.change_token).toBe('string');
        expect(staleBody.change_token).not.toBe(token);

        const resync = await client.postJson('/api/chats/get', { avatar_url: 'CardDelete.png', file_name: 'chatDelete', paged: true, limit: 40 });
        expect(resync.status).toBe(200);
        expect((await resync.json()).messages).toHaveLength(40);
    }, CASE_TIMEOUT_MS);

    test('group_get_rides_the_same_paged_path', async () => {
        writeChatFile(groupChatPath(server, 'spine-group-a'), chatHeader('GroupA'), buildMessages(120));
        const response = await client.postJson('/api/chats/group/get', { id: 'spine-group-a', paged: true, limit: 30, before_index: 60 });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.messages).toHaveLength(30);
        expect(body.messages[0].mes).toBe('message 30');
        expect(body.messages[29].mes).toBe('message 59');
        expect(body.total_items).toBe(120);
    }, CASE_TIMEOUT_MS);

    test('group_get_non_paged_still_returns_the_full_array', async () => {
        writeChatFile(groupChatPath(server, 'spine-group-b'), chatHeader('GroupB'), buildMessages(4));
        const response = await client.postJson('/api/chats/group/get', { id: 'spine-group-b' });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(Array.isArray(body)).toBe(true);
        expect(body).toHaveLength(5);
        expect(body[4].mes).toBe('message 3');
    }, CASE_TIMEOUT_MS);

    test('save_does_not_mint_cf_id_when_the_flag_is_off', async () => {
        const card = 'CardFlagOff';
        fs.mkdirSync(path.dirname(soloChatPath(server, card, 'chatFlagOff')), { recursive: true });
        const response = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatFlagOff', force: true, chat: [chatHeader(card), ...buildMessages(3)],
        });
        expect(response.status).toBe(200);
        const lines = readChatLines(soloChatPath(server, card, 'chatFlagOff'));
        for (const message of lines.slice(1)) {
            expect(message.cf_id).toBeUndefined();
        }
    }, CASE_TIMEOUT_MS);
});

describe('chat spine cf_id minting (flag on)', () => {
    /** @type {{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}} */
    let server;
    /** @type {SillyTavernClient} */
    let client;

    beforeAll(async () => {
        server = await startServerWithEnv({ [CFID_ENV]: 'true' });
        client = await loggedInClient(server);
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    test('save_mints_a_top_level_ulid_cf_id_never_inside_extra', async () => {
        const card = 'CardMint';
        fs.mkdirSync(path.dirname(soloChatPath(server, card, 'chatMint')), { recursive: true });
        const messages = buildMessages(3).map(message => ({ ...message, extra: { note: 'keep' } }));
        const response = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatMint', force: true, chat: [chatHeader(card), ...messages],
        });
        expect(response.status).toBe(200);

        const lines = readChatLines(soloChatPath(server, card, 'chatMint'));
        expect(lines[0].cf_id).toBeUndefined();
        for (const message of lines.slice(1)) {
            expect(typeof message.cf_id).toBe('string');
            expect(message.cf_id).toHaveLength(26);
            expect(message.extra.cf_id).toBeUndefined();
            expect(message.extra.note).toBe('keep');
        }
    }, CASE_TIMEOUT_MS);

    test('cf_id_survives_an_edit_and_resave', async () => {
        const card = 'CardPreserve';
        const filePath = soloChatPath(server, card, 'chatPreserve');
        fs.mkdirSync(path.dirname(filePath), { recursive: true });

        const first = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatPreserve', force: true, chat: [chatHeader(card), ...buildMessages(3)],
        });
        expect(first.status).toBe(200);
        const originalIds = readChatLines(filePath).slice(1).map(message => message.cf_id);
        expect(originalIds.every(id => typeof id === 'string' && id.length === 26)).toBe(true);

        const saved = readChatLines(filePath);
        saved[2].mes = 'edited body but same message';
        const second = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatPreserve', force: true, chat: saved,
        });
        expect(second.status).toBe(200);

        const afterIds = readChatLines(filePath).slice(1).map(message => message.cf_id);
        expect(afterIds).toEqual(originalIds);
        expect(readChatLines(filePath)[2].mes).toBe('edited body but same message');
    }, CASE_TIMEOUT_MS);

    test('a_new_message_without_a_cf_id_is_backfilled_on_the_next_save', async () => {
        const card = 'CardBackfill';
        const filePath = soloChatPath(server, card, 'chatBackfill');
        fs.mkdirSync(path.dirname(filePath), { recursive: true });

        await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatBackfill', force: true, chat: [chatHeader(card), ...buildMessages(3)],
        });
        const withIds = readChatLines(filePath);
        const existingIds = withIds.slice(1).map(message => message.cf_id);

        withIds.push({ name: 'Bot', is_user: false, mes: 'a stock reply with no id', send_date: 1700000009999, extra: {} });
        const response = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatBackfill', force: true, chat: withIds,
        });
        expect(response.status).toBe(200);

        const finalMessages = readChatLines(filePath).slice(1);
        expect(finalMessages).toHaveLength(4);
        expect(finalMessages.slice(0, 3).map(message => message.cf_id)).toEqual(existingIds);
        expect(typeof finalMessages[3].cf_id).toBe('string');
        expect(finalMessages[3].cf_id).toHaveLength(26);
        expect(finalMessages[3].mes).toBe('a stock reply with no id');
    }, CASE_TIMEOUT_MS);

    test('paged_read_anchors_by_cf_id_and_reports_an_unknown_id', async () => {
        const card = 'CardIdRead';
        const filePath = soloChatPath(server, card, 'chatIdRead');
        fs.mkdirSync(path.dirname(filePath), { recursive: true });
        const save = await client.postJson('/api/chats/save', {
            avatar_url: `${card}.png`, file_name: 'chatIdRead', force: true, chat: [chatHeader(card), ...buildMessages(60)],
        });
        expect(save.status).toBe(200);

        const ids = readChatLines(filePath).slice(1).map(message => message.cf_id);
        expect(ids).toHaveLength(60);

        const before = await (await client.postJson('/api/chats/get', {
            avatar_url: `${card}.png`, file_name: 'chatIdRead', paged: true, limit: 15, before_id: ids[40],
        })).json();
        expect(before.anchor_found).toBe(true);
        expect(before.anchor_index).toBe(40);
        expect(before.messages).toHaveLength(15);
        expect(before.messages[0].mes).toBe('message 25');
        expect(before.messages[14].mes).toBe('message 39');

        const around = await (await client.postJson('/api/chats/get', {
            avatar_url: `${card}.png`, file_name: 'chatIdRead', paged: true, limit: 10, around_id: ids[30],
        })).json();
        expect(around.anchor_found).toBe(true);
        expect(around.anchor_index).toBe(30);
        expect(around.messages.findIndex(message => message.mes === 'message 30')).toBe(5);
        expect(around.messages[0].mes).toBe('message 25');

        const unknown = await (await client.postJson('/api/chats/get', {
            avatar_url: `${card}.png`, file_name: 'chatIdRead', paged: true, limit: 15, before_id: 'ZZZZZZZZZZZZZZZZZZZZZZZZZZ',
        })).json();
        expect(unknown.anchor_found).toBe(false);
        expect(unknown.messages).toHaveLength(0);
    }, CASE_TIMEOUT_MS);
});

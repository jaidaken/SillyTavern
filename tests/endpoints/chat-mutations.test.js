import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import yaml from 'yaml';
import { spawn } from 'node:child_process';

import { DEFAULT_HANDLE, allocatePort, SERVER_ROOT } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const CFID_ENV = 'SILLYTAVERN_CHAT_CFID_ENABLED';

const SMOKE_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: true,
    enableCorsProxy: true,
});

/**
 * Boots server.js against a throwaway data root with an explicit environment so the child sees
 * the cf_id flag (Jest sandboxes process.env away from child_process).
 * @param {Record<string, string>} extraEnv Environment overrides for the child.
 * @returns {Promise<{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}>}
 */
async function startServerWithEnv(extraEnv) {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-mut-'));
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
            // Connection refused until the server binds its port.
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
    return { user_name: 'You', character_name: characterName, chat_metadata: { integrity: 'mut-test' } };
}

/**
 * Builds steady-state messages (cf_id already minted) whose mes text encodes the index.
 * @param {number} count Number of messages.
 * @param {(index: number) => object} [extra] Extra per-message fields keyed by index.
 * @returns {object[]} Ordered message objects carrying cf_id.
 */
function buildMinted(count, extra = () => ({})) {
    const messages = [];
    for (let i = 0; i < count; i++) {
        messages.push({
            name: i % 2 === 0 ? 'You' : 'Bot',
            is_user: i % 2 === 0,
            is_system: false,
            mes: `message ${i}`,
            send_date: 1700000000000 + i,
            cf_id: `cf-${String(i).padStart(4, '0')}`,
            extra: {},
            ...extra(i),
        });
    }
    return messages;
}

/**
 * Builds a pre-cf_id (stock ST) chat: no cf_id anywhere.
 * @param {number} count Number of messages.
 * @returns {object[]} Ordered message objects with no cf_id.
 */
function buildPreCfid(count) {
    const messages = [];
    for (let i = 0; i < count; i++) {
        messages.push({
            name: i % 2 === 0 ? 'You' : 'Bot',
            is_user: i % 2 === 0,
            is_system: false,
            mes: `message ${i}`,
            send_date: 1700000000000 + i,
            extra: {},
        });
    }
    return messages;
}

function soloChatPath(server, card, fileName) {
    return path.join(server.userDirectory(), 'chats', card, `${fileName}.jsonl`);
}

function groupChatPath(server, id) {
    return path.join(server.userDirectory(), 'group chats', `${id}.jsonl`);
}

function writeChatFile(filePath, header, messages) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const lines = [JSON.stringify(header), ...messages.map(m => JSON.stringify(m))];
    fs.writeFileSync(filePath, lines.join('\n'), 'utf8');
}

function readRawLines(filePath) {
    return fs.readFileSync(filePath, 'utf8').split('\n').filter(line => line.length > 0);
}

async function loggedInClient(server) {
    const client = new SillyTavernClient(server.baseUrl);
    await client.fetchCsrfToken();
    const login = await client.login(DEFAULT_HANDLE);
    if (login.status !== 200) {
        throw new Error(`login failed: ${login.status} ${await login.text()}`);
    }
    return client;
}

/**
 * Fetches the current FULL token via message-versions (the reader's option-A source).
 * @param {SillyTavernClient} client A logged-in client.
 * @param {object} target The route target selector (avatar_url/file_name or group_id) plus index/cf_id.
 * @returns {Promise<string>} The full change token.
 */
async function fullToken(client, target) {
    const res = await client.postJson('/api/chats/backups/message-versions', target);
    return (await res.json()).change_token;
}

describe('chat mutation family (cf_id ON, steady-state chats)', () => {
    /** @type {Awaited<ReturnType<typeof startServerWithEnv>>} */
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

    test('edit_in_window_leaves_every_above_window_line_byte_identical', async () => {
        const filePath = soloChatPath(server, 'CardEdit', 'chatEdit');
        writeChatFile(filePath, chatHeader('CardEdit'), buildMinted(10));
        const before = readRawLines(filePath);

        // Windowed tail read: limit 3 -> window covers indices 7..9 (window_offset 7 > 0).
        const getRes = await client.postJson('/api/chats/get', { avatar_url: 'CardEdit.png', file_name: 'chatEdit', paged: true, limit: 3 });
        const page = await getRes.json();
        expect(page.messages.length).toBe(3);

        const token = await fullToken(client, { avatar_url: 'CardEdit.png', file_name: 'chatEdit', index: 8 });
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardEdit.png', file_name: 'chatEdit', index: 8, text: 'EDITED', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);
        const body = await res.json();
        expect(body.ok).toBe(true);
        expect(body.index).toBe(8);
        expect(body.total_items).toBe(10);
        expect(typeof body.change_token).toBe('string');
        expect(typeof body.tail_token).toBe('string');
        expect(body.affected_cf_id).toBe('cf-0008');

        const after = readRawLines(filePath);
        expect(after.length).toBe(before.length);
        // Header (line 0) and every message above the window (lines 1..7 == msg 0..6) byte-identical.
        for (let line = 0; line <= 7; line++) {
            expect(after[line]).toBe(before[line]);
        }
        expect(JSON.parse(after[9]).mes).toBe('EDITED');
    }, CASE_TIMEOUT_MS);

    test('metadata_route_persists_world_info_and_rejects_non_string', async () => {
        const filePath = soloChatPath(server, 'CardWi', 'chatWi');
        writeChatFile(filePath, chatHeader('CardWi'), buildMinted(4));
        const beforeLines = readRawLines(filePath);

        const res = await client.postJson('/api/chats/metadata', {
            avatar_url: 'CardWi.png', file_name: 'chatWi', world_info: 'Denny Lore',
        });
        expect(res.status).toBe(200);

        const after = readRawLines(filePath);
        const header = JSON.parse(after[0]);
        expect(header.chat_metadata.world_info).toBe('Denny Lore');
        expect(header.chat_metadata.integrity).toBe('mut-test');
        // Messages untouched by a header-only mutation.
        for (let line = 1; line < beforeLines.length; line++) {
            expect(after[line]).toBe(beforeLines[line]);
        }

        const bad = await client.postJson('/api/chats/metadata', {
            avatar_url: 'CardWi.png', file_name: 'chatWi', world_info: 42,
        });
        expect(bad.status).toBe(400);
        expect((await bad.json()).error).toBe('world_info must be a string');
    }, CASE_TIMEOUT_MS);

    test('get_page_carries_full_token_usable_as_a_mutation_gate_in_one_round_trip', async () => {
        const filePath = soloChatPath(server, 'CardFT', 'chatFT');
        writeChatFile(filePath, chatHeader('CardFT'), buildMinted(12));

        // The windowed reader loads a tail page and gets BOTH tokens in one call.
        const getRes = await client.postJson('/api/chats/get', { avatar_url: 'CardFT.png', file_name: 'chatFT', paged: true, limit: 3 });
        const page = await getRes.json();
        expect(typeof page.full_token).toBe('string');
        expect(page.full_token).not.toBe(page.change_token); // tail token differs from full token

        // It presents page.full_token straight to a mutation, no separate message-versions call.
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardFT.png', file_name: 'chatFT', index: 10, text: 'one round trip', change_token: page.full_token, limit: 3,
        });
        expect(res.status).toBe(200);
        const body = await res.json();
        // The mutation change_token IS the refreshed full token; tail_token refreshes the window path.
        expect(typeof body.change_token).toBe('string');
        expect(typeof body.tail_token).toBe('string');
    }, CASE_TIMEOUT_MS);

    test('returned_tail_token_matches_a_fresh_windowed_get', async () => {
        const filePath = soloChatPath(server, 'CardTok', 'chatTok');
        writeChatFile(filePath, chatHeader('CardTok'), buildMinted(12));

        const token = await fullToken(client, { avatar_url: 'CardTok.png', file_name: 'chatTok', index: 10 });
        const editRes = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardTok.png', file_name: 'chatTok', index: 10, text: 'tok edit', change_token: token, limit: 4,
        });
        const editBody = await editRes.json();

        // The reader adopts editBody.tail_token; a fresh tail /get with the same limit must agree.
        const getRes = await client.postJson('/api/chats/get', { avatar_url: 'CardTok.png', file_name: 'chatTok', paged: true, limit: 4 });
        const page = await getRes.json();
        expect(page.change_token).toBe(editBody.tail_token);
    }, CASE_TIMEOUT_MS);

    test('delete_removes_only_the_target_and_preserves_above_window', async () => {
        const filePath = soloChatPath(server, 'CardDel', 'chatDel');
        writeChatFile(filePath, chatHeader('CardDel'), buildMinted(10));
        const before = readRawLines(filePath);

        const token = await fullToken(client, { avatar_url: 'CardDel.png', file_name: 'chatDel', index: 8 });
        const res = await client.postJson('/api/chats/message/delete', {
            avatar_url: 'CardDel.png', file_name: 'chatDel', index: 8, change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);
        const delBody = await res.json();
        expect(delBody.total_items).toBe(9);
        expect(delBody.affected_cf_id).toBe('cf-0008'); // the removed message's stable id

        const after = readRawLines(filePath);
        expect(after.length).toBe(before.length - 1);
        for (let line = 0; line <= 8; line++) {
            expect(after[line]).toBe(before[line]);
        }
        // The deleted message (old line 9) is gone; old line 10 (msg 9) survives as the new tail.
        expect(after[after.length - 1]).toBe(before[before.length - 1]);
    }, CASE_TIMEOUT_MS);

    test('move_reorders_within_window_and_keeps_above_window_intact', async () => {
        const filePath = soloChatPath(server, 'CardMove', 'chatMove');
        writeChatFile(filePath, chatHeader('CardMove'), buildMinted(10));
        const before = readRawLines(filePath);

        const token = await fullToken(client, { avatar_url: 'CardMove.png', file_name: 'chatMove', index: 8 });
        const res = await client.postJson('/api/chats/message/move', {
            avatar_url: 'CardMove.png', file_name: 'chatMove', index: 8, direction: 'up', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);
        const moveBody = await res.json();
        expect(moveBody.index).toBe(7);
        expect(moveBody.affected_cf_id).toBe('cf-0008'); // the moved message re-anchors by its stable id

        const afterLines = readRawLines(filePath);
        const after = afterLines.map(l => JSON.parse(l));
        const beforeObjs = before.map(l => JSON.parse(l));
        // File lines 0..7 (header + msgs 0..6) untouched; the swap moved msgs 7 and 8 (file lines 8,9).
        for (let line = 0; line <= 7; line++) {
            expect(afterLines[line]).toBe(before[line]);
        }
        expect(after[8].cf_id).toBe(beforeObjs[9].cf_id); // old msg 8 now sits at file line 8
        expect(after[9].cf_id).toBe(beforeObjs[8].cf_id); // old msg 7 pushed down to file line 9
    }, CASE_TIMEOUT_MS);

    test('hide_toggles_is_system_and_preserves_above_window', async () => {
        const filePath = soloChatPath(server, 'CardHide', 'chatHide');
        writeChatFile(filePath, chatHeader('CardHide'), buildMinted(10));
        const before = readRawLines(filePath);

        const token = await fullToken(client, { avatar_url: 'CardHide.png', file_name: 'chatHide', index: 8 });
        const res = await client.postJson('/api/chats/message/hide', {
            avatar_url: 'CardHide.png', file_name: 'chatHide', index: 8, hidden: true, change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        const after = readRawLines(filePath);
        for (let line = 0; line <= 7; line++) {
            expect(after[line]).toBe(before[line]);
        }
        expect(JSON.parse(after[9]).is_system).toBe(true);
    }, CASE_TIMEOUT_MS);

    test('swipe_select_syncs_mes_and_preserves_other_swipes', async () => {
        const filePath = soloChatPath(server, 'CardSwipe', 'chatSwipe');
        const messages = buildMinted(10, i => (i === 8 ? { swipes: ['alpha', 'beta', 'gamma'], swipe_id: 0, mes: 'alpha' } : {}));
        writeChatFile(filePath, chatHeader('CardSwipe'), messages);
        const before = readRawLines(filePath);

        const token = await fullToken(client, { avatar_url: 'CardSwipe.png', file_name: 'chatSwipe', index: 8 });
        const res = await client.postJson('/api/chats/message/swipe-select', {
            avatar_url: 'CardSwipe.png', file_name: 'chatSwipe', index: 8, swipe_id: 2, change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        const after = readRawLines(filePath);
        for (let line = 0; line <= 7; line++) {
            expect(after[line]).toBe(before[line]);
        }
        const target = JSON.parse(after[9]);
        expect(target.swipe_id).toBe(2);
        expect(target.mes).toBe('gamma');
        expect(target.swipes).toEqual(['alpha', 'beta', 'gamma']);
    }, CASE_TIMEOUT_MS);

    test('edit_on_swipe_message_updates_active_swipe_slot', async () => {
        const filePath = soloChatPath(server, 'CardSwEdit', 'chatSwEdit');
        const messages = buildMinted(10, i => (i === 8 ? { swipes: ['alpha', 'beta'], swipe_id: 1, mes: 'beta' } : {}));
        writeChatFile(filePath, chatHeader('CardSwEdit'), messages);

        const token = await fullToken(client, { avatar_url: 'CardSwEdit.png', file_name: 'chatSwEdit', index: 8 });
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardSwEdit.png', file_name: 'chatSwEdit', index: 8, text: 'beta-edited', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        const target = JSON.parse(readRawLines(filePath)[9]);
        expect(target.mes).toBe('beta-edited');
        expect(target.swipes).toEqual(['alpha', 'beta-edited']);
    }, CASE_TIMEOUT_MS);

    test('checkpoint_adds_optional_metadata_and_keeps_messages_byte_intact', async () => {
        const filePath = soloChatPath(server, 'CardCkpt', 'chatCkpt');
        writeChatFile(filePath, chatHeader('CardCkpt'), buildMinted(10));
        const before = readRawLines(filePath);

        const token = await fullToken(client, { avatar_url: 'CardCkpt.png', file_name: 'chatCkpt', index: 8 });
        const res = await client.postJson('/api/chats/message/checkpoint', {
            avatar_url: 'CardCkpt.png', file_name: 'chatCkpt', index: 8, name: 'branch point', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        const after = readRawLines(filePath);
        // Every message line (1..10) byte-identical; only the header changed.
        for (let line = 1; line < after.length; line++) {
            expect(after[line]).toBe(before[line]);
        }
        const header = JSON.parse(after[0]);
        expect(Array.isArray(header.chat_metadata.cf_checkpoints)).toBe(true);
        expect(header.chat_metadata.cf_checkpoints[0].name).toBe('branch point');
        expect(header.chat_metadata.cf_checkpoints[0].cf_id).toBe('cf-0008');
    }, CASE_TIMEOUT_MS);

    test('stale_full_token_409s', async () => {
        const filePath = soloChatPath(server, 'CardStale', 'chatStale');
        writeChatFile(filePath, chatHeader('CardStale'), buildMinted(6));
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardStale.png', file_name: 'chatStale', index: 2, text: 'no', change_token: 'v1.6.deadbeefdeadbeef',
        });
        expect(res.status).toBe(409);
        expect((await res.json()).error).toBe('stale');
    }, CASE_TIMEOUT_MS);

    test('concurrent_double_edit_of_same_message_second_409s', async () => {
        const filePath = soloChatPath(server, 'CardRace', 'chatRace');
        writeChatFile(filePath, chatHeader('CardRace'), buildMinted(10));
        const token = await fullToken(client, { avatar_url: 'CardRace.png', file_name: 'chatRace', index: 8 });

        const both = await Promise.all([
            client.postJson('/api/chats/message/edit', { avatar_url: 'CardRace.png', file_name: 'chatRace', index: 8, text: 'first', change_token: token, limit: 3 }),
            client.postJson('/api/chats/message/edit', { avatar_url: 'CardRace.png', file_name: 'chatRace', index: 8, text: 'second', change_token: token, limit: 3 }),
        ]);
        const statuses = both.map(r => r.status).sort();
        expect(statuses).toEqual([200, 409]);
    }, CASE_TIMEOUT_MS);

    test('delete_of_chat_A_never_removes_sibling_chat_B', async () => {
        const pathA = soloChatPath(server, 'CardSib', 'chatA');
        const pathB = soloChatPath(server, 'CardSib', 'chatB');
        writeChatFile(pathA, chatHeader('CardSib'), buildMinted(4));
        writeChatFile(pathB, chatHeader('CardSib'), buildMinted(5));
        const beforeB = fs.readFileSync(pathB, 'utf8');

        const token = await fullToken(client, { avatar_url: 'CardSib.png', file_name: 'chatA', index: 2 });
        const res = await client.postJson('/api/chats/message/delete', {
            avatar_url: 'CardSib.png', file_name: 'chatA', index: 2, change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        expect(fs.existsSync(pathB)).toBe(true);
        expect(fs.readFileSync(pathB, 'utf8')).toBe(beforeB);
    }, CASE_TIMEOUT_MS);

    test('group_chat_edit_and_delete_ride_the_same_path', async () => {
        const filePath = groupChatPath(server, 'group-alpha');
        writeChatFile(filePath, chatHeader('Group Alpha'), buildMinted(8));
        const before = readRawLines(filePath);

        let token = await fullToken(client, { group_id: 'group-alpha', index: 6 });
        const editRes = await client.postJson('/api/chats/message/edit', {
            group_id: 'group-alpha', index: 6, text: 'group edited', change_token: token, limit: 3,
        });
        expect(editRes.status).toBe(200);
        expect(JSON.parse(readRawLines(filePath)[7]).mes).toBe('group edited');
        for (let line = 0; line <= 6; line++) {
            expect(readRawLines(filePath)[line]).toBe(before[line]);
        }

        token = (await editRes.json()).change_token;
        const delRes = await client.postJson('/api/chats/message/delete', {
            group_id: 'group-alpha', index: 6, change_token: token, limit: 3,
        });
        expect(delRes.status).toBe(200);
        expect((await delRes.json()).total_items).toBe(7);
    }, CASE_TIMEOUT_MS);

    test('group_metadata_write_touches_only_the_group_header_never_messages_nor_solo_files', async () => {
        const groupPath = groupChatPath(server, 'group-meta');
        writeChatFile(groupPath, chatHeader('Group Meta'), buildMinted(6));
        const soloPath = soloChatPath(server, 'CardHold', 'chatHold');
        writeChatFile(soloPath, chatHeader('CardHold'), buildMinted(4));
        const groupBefore = readRawLines(groupPath);
        const soloBefore = fs.readFileSync(soloPath, 'utf8');

        const res = await client.postJson('/api/chats/metadata', {
            group_id: 'group-meta', note_prompt: 'group note', note_depth: 3, world_info: 'Group Lore',
        });
        expect(res.status).toBe(200);
        expect((await res.json()).ok).toBe(true);

        const after = readRawLines(groupPath);
        const header = JSON.parse(after[0]);
        expect(header.chat_metadata.note_prompt).toBe('group note');
        expect(header.chat_metadata.note_depth).toBe(3);
        expect(header.chat_metadata.world_info).toBe('Group Lore');
        expect(header.chat_metadata.integrity).toBe('mut-test');
        expect(after.length).toBe(groupBefore.length);
        // Every message line of the group file byte-identical: the write is header-only.
        for (let line = 1; line < groupBefore.length; line++) {
            expect(after[line]).toBe(groupBefore[line]);
        }
        // The solo chat file never moved at all.
        expect(fs.readFileSync(soloPath, 'utf8')).toBe(soloBefore);
    }, CASE_TIMEOUT_MS);

    test('group_metadata_write_refuses_a_headerless_legacy_group_file', async () => {
        const filePath = groupChatPath(server, 'group-noheader');
        fs.mkdirSync(path.dirname(filePath), { recursive: true });
        fs.writeFileSync(filePath, buildMinted(3).map(m => JSON.stringify(m)).join('\n'), 'utf8');
        const before = fs.readFileSync(filePath, 'utf8');

        const res = await client.postJson('/api/chats/metadata', {
            group_id: 'group-noheader', note_prompt: 'never lands',
        });
        expect(res.status).toBe(400);
        expect((await res.json()).error).toBe('no_header');
        // Fail-closed: the refused write leaves the legacy file byte-identical.
        expect(fs.readFileSync(filePath, 'utf8')).toBe(before);
    }, CASE_TIMEOUT_MS);

    test('branch_prefix_is_byte_identical_and_source_unchanged', async () => {
        const filePath = soloChatPath(server, 'CardBranch', 'chatBranch');
        writeChatFile(filePath, chatHeader('CardBranch'), buildMinted(10));
        const sourceBefore = fs.readFileSync(filePath, 'utf8');
        const sourceLines = readRawLines(filePath);

        const res = await client.postJson('/api/chats/branch', {
            avatar_url: 'CardBranch.png', file_name: 'chatBranch', new_file_name: 'chatBranch-fork', index: 5,
        });
        expect(res.status).toBe(200);
        expect((await res.json()).total_items).toBe(6);

        // Source untouched.
        expect(fs.readFileSync(filePath, 'utf8')).toBe(sourceBefore);
        // Branch: header + messages 0..5 (lines 0..6) byte-identical to the source prefix.
        const forkLines = readRawLines(soloChatPath(server, 'CardBranch', 'chatBranch-fork'));
        expect(forkLines.length).toBe(7);
        for (let line = 0; line < 7; line++) {
            expect(forkLines[line]).toBe(sourceLines[line]);
        }
    }, CASE_TIMEOUT_MS);

    test('branch_into_existing_name_409s_without_touching_it', async () => {
        const filePath = soloChatPath(server, 'CardBr2', 'chatBr2');
        const existing = soloChatPath(server, 'CardBr2', 'taken');
        writeChatFile(filePath, chatHeader('CardBr2'), buildMinted(6));
        writeChatFile(existing, chatHeader('CardBr2'), buildMinted(3));
        const takenBefore = fs.readFileSync(existing, 'utf8');

        const res = await client.postJson('/api/chats/branch', {
            avatar_url: 'CardBr2.png', file_name: 'chatBr2', new_file_name: 'taken', index: 2,
        });
        expect(res.status).toBe(409);
        expect(fs.readFileSync(existing, 'utf8')).toBe(takenBefore);
    }, CASE_TIMEOUT_MS);

    test('duplicate_copies_source_and_leaves_it_byte_intact', async () => {
        const filePath = soloChatPath(server, 'CardDup', 'chatDup');
        writeChatFile(filePath, chatHeader('CardDup'), buildMinted(7));
        const sourceBefore = fs.readFileSync(filePath, 'utf8');

        const res = await client.postJson('/api/chats/duplicate', {
            avatar_url: 'CardDup.png', file_name: 'chatDup', new_file_name: 'chatDup-copy',
        });
        expect(res.status).toBe(200);

        expect(fs.readFileSync(filePath, 'utf8')).toBe(sourceBefore);
        expect(fs.readFileSync(soloChatPath(server, 'CardDup', 'chatDup-copy'), 'utf8')).toBe(sourceBefore);
    }, CASE_TIMEOUT_MS);

    test('duplicate_into_existing_name_409s_without_clobbering', async () => {
        const filePath = soloChatPath(server, 'CardDup2', 'chatDup2');
        const existing = soloChatPath(server, 'CardDup2', 'occupied');
        writeChatFile(filePath, chatHeader('CardDup2'), buildMinted(4));
        writeChatFile(existing, chatHeader('CardDup2'), buildMinted(2));
        const occupiedBefore = fs.readFileSync(existing, 'utf8');

        const res = await client.postJson('/api/chats/duplicate', {
            avatar_url: 'CardDup2.png', file_name: 'chatDup2', new_file_name: 'occupied',
        });
        expect(res.status).toBe(409);
        expect(fs.readFileSync(existing, 'utf8')).toBe(occupiedBefore);
    }, CASE_TIMEOUT_MS);

    test('pre_cfid_chat_edits_by_index_then_save_mints_ids', async () => {
        const filePath = soloChatPath(server, 'CardPre', 'chatPre');
        writeChatFile(filePath, chatHeader('CardPre'), buildPreCfid(8));
        const before = readRawLines(filePath).map(l => JSON.parse(l));
        const messageObjsBefore = before.filter(o => o.is_user !== undefined || o.mes !== undefined);
        expect(messageObjsBefore.every(o => o.cf_id === undefined)).toBe(true);

        const token = await fullToken(client, { avatar_url: 'CardPre.png', file_name: 'chatPre', index: 5 });
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardPre.png', file_name: 'chatPre', index: 5, text: 'pre edited', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);

        const after = readRawLines(filePath).map(l => JSON.parse(l));
        const messageObjs = after.filter(o => o.is_user !== undefined || o.mes !== undefined);
        // Save minted a cf_id onto every message; content above the window preserved by value.
        expect(messageObjs.every(o => typeof o.cf_id === 'string' && o.cf_id.length > 0)).toBe(true);
        for (let i = 0; i < 5; i++) {
            expect(messageObjs[i].mes).toBe(`message ${i}`);
        }
        expect(messageObjs[5].mes).toBe('pre edited');
    }, CASE_TIMEOUT_MS);

    test('cfid_descriptor_addresses_the_right_message_after_mint', async () => {
        const filePath = soloChatPath(server, 'CardPre2', 'chatPre2');
        writeChatFile(filePath, chatHeader('CardPre2'), buildPreCfid(6));

        // First edit by index mints ids across the file.
        let token = await fullToken(client, { avatar_url: 'CardPre2.png', file_name: 'chatPre2', index: 0 });
        await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardPre2.png', file_name: 'chatPre2', index: 0, text: 'seed', change_token: token, limit: 3,
        });

        const minted = readRawLines(filePath).map(l => JSON.parse(l)).filter(o => o.is_user !== undefined || o.mes !== undefined);
        const targetCfId = minted[3].cf_id;
        expect(typeof targetCfId).toBe('string');

        token = await fullToken(client, { avatar_url: 'CardPre2.png', file_name: 'chatPre2', cf_id: targetCfId });
        const res = await client.postJson('/api/chats/message/edit', {
            avatar_url: 'CardPre2.png', file_name: 'chatPre2', cf_id: targetCfId, text: 'by cfid', change_token: token, limit: 3,
        });
        expect(res.status).toBe(200);
        expect((await res.json()).index).toBe(3);

        const afterObjs = readRawLines(filePath).map(l => JSON.parse(l));
        expect(afterObjs.find(o => o.cf_id === targetCfId).mes).toBe('by cfid');
    }, CASE_TIMEOUT_MS);
});

import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { backupBaseName } from '../../src/chat-undo.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

/**
 * @param {string} characterName Character name for the header.
 * @param {string} integrity The chat_metadata.integrity uuid.
 * @param {string} createDate The header create_date.
 * @returns {object} A chat header line.
 */
function header(characterName, integrity, createDate) {
    return { user_name: 'You', character_name: characterName, create_date: createDate, chat_metadata: { integrity } };
}

/**
 * @param {string} mes Message text.
 * @param {boolean} isUser Whether the message is from the user.
 * @param {object} [extra] Extra fields spread onto the message.
 * @returns {object} A message object.
 */
function msg(mes, isUser = false, extra = {}) {
    return { name: isUser ? 'You' : 'Bot', is_user: isUser, mes, send_date: 1700000000000, extra: {}, ...extra };
}

/**
 * @param {SillyTavernServer} server The running server.
 * @param {string} card The card name without extension.
 * @param {string} fileName The chat file name without extension.
 * @returns {string} The absolute chat file path.
 */
function soloChatPath(server, card, fileName) {
    return path.join(server.userDirectory(), 'chats', card, `${fileName}.jsonl`);
}

/**
 * @param {SillyTavernServer} server The running server.
 * @returns {string} The user's backups directory.
 */
function backupsDir(server) {
    return path.join(server.userDirectory(), 'backups');
}

/**
 * Writes a jsonl chat file (header first), creating parent directories.
 * @param {string} filePath Target file path.
 * @param {object} head Header line object.
 * @param {object[]} messages Message objects.
 */
function writeChatFile(filePath, head, messages) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, [JSON.stringify(head), ...messages.map(m => JSON.stringify(m))].join('\n'), 'utf8');
}

/**
 * Seeds a backup file with the exact naming backupChat uses, bypassing the throttle for determinism.
 * @param {SillyTavernServer} server The running server.
 * @param {string} cardName The card name or group id.
 * @param {string} ts The YYYYMMDD-HHMMSS timestamp.
 * @param {object} head Header line object.
 * @param {object[]} messages Message objects.
 */
function writeBackup(server, cardName, ts, head, messages) {
    const dir = backupsDir(server);
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `chat_${backupBaseName(cardName)}_${ts}.jsonl`);
    fs.writeFileSync(file, [JSON.stringify(head), ...messages.map(m => JSON.stringify(m))].join('\n'), 'utf8');
}

/**
 * @param {string} filePath A jsonl chat file.
 * @returns {object[]} Parsed non-empty lines (header first).
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
        throw new Error(`Client failed to log in: ${login.status} ${await login.text()}`);
    }
    return client;
}

describe('chat undo endpoints', () => {
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

    test('restore_message_round_trips_a_real_chat_byte_sane', async () => {
        const card = 'RoundTrip';
        const head = header('RoundTrip', 'u-rt', 'd-rt');
        const current = [msg('m0', true), msg('m1'), msg('v2-edited', true, { extra: { keep: 'yes' } }), msg('m3'), msg('m4', true)];
        writeChatFile(soloChatPath(server, card, 'rt'), head, current);
        const backupMsgs = current.map((m, i) => (i === 2 ? { ...m, mes: 'v2-original' } : m));
        writeBackup(server, card, '20260101-000001', head, backupMsgs);

        const response = await client.postJson('/api/chats/backups/restore-message', {
            avatar_url: 'RoundTrip.png', file_name: 'rt', index: 2, backup_ts: '20260101-000001',
        });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.ok).toBe(true);
        expect(body.restored.index).toBe(2);

        const lines = readChatLines(soloChatPath(server, card, 'rt'));
        expect(lines).toHaveLength(6);
        expect(lines[0].chat_metadata.integrity).toBe('u-rt');
        const restored = lines.slice(1);
        expect(restored[2].mes).toBe('v2-original');
        expect(restored[2].extra.keep).toBe('yes');
        for (const i of [0, 1, 3, 4]) {
            expect(restored[i]).toEqual(current[i]);
        }
    }, CASE_TIMEOUT_MS);

    test('restore_message_syncs_swipes_so_a_later_swipe_keeps_the_restored_text', async () => {
        const card = 'Swipes';
        const head = header('Swipes', 'u-sw', 'd-sw');
        const current = [msg('m0', true), msg('current-text', false, { swipes: ['current-text', 'other'], swipe_id: 0 })];
        writeChatFile(soloChatPath(server, card, 'sw'), head, current);
        const backupMsgs = [msg('m0', true), msg('orig-text', false, { swipes: ['orig-text', 'other'], swipe_id: 0 })];
        writeBackup(server, card, '20260101-000002', head, backupMsgs);

        const response = await client.postJson('/api/chats/backups/restore-message', {
            avatar_url: 'Swipes.png', file_name: 'sw', index: 1, backup_ts: '20260101-000002',
        });
        expect(response.status).toBe(200);

        const restored = readChatLines(soloChatPath(server, card, 'sw')).slice(1);
        expect(restored[1].mes).toBe('orig-text');
        expect(restored[1].swipes[0]).toBe('orig-text');
        expect(restored[1].swipes[1]).toBe('other');
        expect(restored[1].swipes[restored[1].swipe_id]).toBe(restored[1].mes);
    }, CASE_TIMEOUT_MS);

    test('absent_or_single_backup_chat_returns_empty_not_error', async () => {
        const card = 'Empty';
        writeChatFile(soloChatPath(server, card, 'e'), header('Empty', 'u-e', 'd-e'), [msg('only', true)]);

        const versions = await client.postJson('/api/chats/backups/message-versions', { avatar_url: 'Empty.png', file_name: 'e', index: 0 });
        expect(versions.status).toBe(200);
        expect((await versions.json()).versions).toHaveLength(0);

        const snapshots = await client.postJson('/api/chats/backups/snapshots', { avatar_url: 'Empty.png', file_name: 'e' });
        expect(snapshots.status).toBe(200);
        expect((await snapshots.json()).snapshots).toHaveLength(0);

        const restore = await client.postJson('/api/chats/backups/restore-message', { avatar_url: 'Empty.png', file_name: 'e', index: 0, backup_ts: '20200101-000000' });
        expect(restore.status).toBe(404);
    }, CASE_TIMEOUT_MS);

    test('depth_cap_holds_at_50', async () => {
        const card = 'Depth';
        const head = header('Depth', 'u-dp', 'd-dp');
        writeChatFile(soloChatPath(server, card, 'dp'), head, [msg('current', true)]);
        for (let i = 0; i < 60; i++) {
            const ts = `20260101-00${String(i).padStart(2, '0')}00`;
            writeBackup(server, card, ts, head, [msg(`snapshot ${i}`, true)]);
        }

        const response = await client.postJson('/api/chats/backups/snapshots', { avatar_url: 'Depth.png', file_name: 'dp' });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.depth).toBe(50);
        expect(body.truncated).toBe(true);
        expect(body.snapshots).toHaveLength(50);
        expect(body.snapshots[0].backup_ts).toBe('20260101-005900');
    }, CASE_TIMEOUT_MS);

    test('attribution_ignores_another_chat_of_the_same_card', async () => {
        const card = 'Denny';
        const headA = header('Denny', 'u-A', 'date-A');
        const headB = header('Denny', 'u-B', 'date-B');
        writeChatFile(soloChatPath(server, card, 'chatA'), headA, [msg('a-current', true)]);
        writeBackup(server, card, '20260201-000001', headA, [msg('a-old-1', true)]);
        writeBackup(server, card, '20260201-000002', headA, [msg('a-old-2', true)]);
        writeBackup(server, card, '20260201-000003', headB, [msg('b-old-1', true)]);
        writeBackup(server, card, '20260201-000004', headB, [msg('b-old-2', true)]);
        writeBackup(server, card, '20260201-000005', headB, [msg('b-old-3', true)]);

        const response = await client.postJson('/api/chats/backups/snapshots', { avatar_url: 'Denny.png', file_name: 'chatA' });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.depth).toBe(2);
        expect(body.snapshots.map(s => s.backup_ts)).toEqual(['20260201-000002', '20260201-000001']);
        expect(body.basis).toBe('integrity+create_date');
    }, CASE_TIMEOUT_MS);

    test('restore_deleted_reinserts_a_vanished_message', async () => {
        const card = 'Deleted';
        const head = header('Deleted', 'u-del', 'd-del');
        const current = [msg('m0', true), msg('m2')];
        writeChatFile(soloChatPath(server, card, 'del'), head, current);
        writeBackup(server, card, '20260301-000001', head, [msg('m0', true), msg('m1'), msg('m2')]);

        const response = await client.postJson('/api/chats/backups/restore-deleted', {
            avatar_url: 'Deleted.png', file_name: 'del', backup_ts: '20260301-000001',
        });
        expect(response.status).toBe(200);
        expect((await response.json()).restored).toBe(1);

        const restored = readChatLines(soloChatPath(server, card, 'del')).slice(1);
        expect(restored.map(m => m.mes)).toEqual(['m0', 'm1', 'm2']);
    }, CASE_TIMEOUT_MS);

    test('restore_rejects_a_stale_change_token', async () => {
        const card = 'Stale';
        const head = header('Stale', 'u-st', 'd-st');
        writeChatFile(soloChatPath(server, card, 'st'), head, [msg('m0', true), msg('m1')]);
        writeBackup(server, card, '20260401-000001', head, [msg('m0', true), msg('m1-old')]);

        const response = await client.postJson('/api/chats/backups/restore-message', {
            avatar_url: 'Stale.png', file_name: 'st', index: 1, backup_ts: '20260401-000001', change_token: 'v1.0.deadbeefdeadbeef',
        });
        expect(response.status).toBe(409);
        expect((await response.json()).error).toBe('stale');
    }, CASE_TIMEOUT_MS);

    test('a_traversal_backup_ts_is_refused', async () => {
        const card = 'Traversal';
        writeChatFile(soloChatPath(server, card, 'tv'), header('Traversal', 'u-tv', 'd-tv'), [msg('m0', true)]);
        const response = await client.postJson('/api/chats/backups/restore-message', {
            avatar_url: 'Traversal.png', file_name: 'tv', index: 0, backup_ts: '../../../../etc/passwd',
        });
        expect(response.status).toBe(400);
    }, CASE_TIMEOUT_MS);

    test('two_concurrent_restores_serialize_without_clobber', async () => {
        const card = 'Concurrent';
        const head = header('Concurrent', 'u-co', 'd-co');
        writeChatFile(soloChatPath(server, card, 'co'), head, [msg('a', true), msg('b')]);
        writeBackup(server, card, '20260501-000001', head, [msg('a-old', true), msg('b')]);
        writeBackup(server, card, '20260501-000002', head, [msg('a', true), msg('b-old')]);

        const [r1, r2] = await Promise.all([
            client.postJson('/api/chats/backups/restore-message', { avatar_url: 'Concurrent.png', file_name: 'co', index: 0, backup_ts: '20260501-000001' }),
            client.postJson('/api/chats/backups/restore-message', { avatar_url: 'Concurrent.png', file_name: 'co', index: 1, backup_ts: '20260501-000002' }),
        ]);
        expect(r1.status).toBe(200);
        expect(r2.status).toBe(200);

        const restored = readChatLines(soloChatPath(server, card, 'co')).slice(1);
        expect(restored.map(m => m.mes)).toEqual(['a-old', 'b-old']);
    }, CASE_TIMEOUT_MS);

    test('snapshots_restore_replaces_the_whole_chat_and_keeps_identity', async () => {
        const card = 'Whole';
        const head = header('Whole', 'u-wh', 'd-wh');
        writeChatFile(soloChatPath(server, card, 'wh'), head, [msg('m0', true), msg('edited'), msg('m2', true)]);
        writeBackup(server, card, '20260601-000001', head, [msg('m0', true), msg('original'), msg('m2', true)]);

        const response = await client.postJson('/api/chats/backups/snapshots', {
            avatar_url: 'Whole.png', file_name: 'wh', mode: 'restore', backup_ts: '20260601-000001',
        });
        expect(response.status).toBe(200);
        expect((await response.json()).restored).toBe(3);

        const lines = readChatLines(soloChatPath(server, card, 'wh'));
        expect(lines[0].chat_metadata.integrity).toBe('u-wh');
        expect(lines.slice(1).map(m => m.mes)).toEqual(['m0', 'original', 'm2']);
    }, CASE_TIMEOUT_MS);

    test('snapshots_list_reports_the_diff_summary', async () => {
        const card = 'Summary';
        const head = header('Summary', 'u-su', 'd-su');
        writeChatFile(soloChatPath(server, card, 'su'), head, [msg('a', true), msg('b'), msg('c', true)]);
        writeBackup(server, card, '20260701-000001', head, [msg('a', true), msg('b')]);

        const response = await client.postJson('/api/chats/backups/snapshots', { avatar_url: 'Summary.png', file_name: 'su' });
        expect(response.status).toBe(200);
        const snapshot = (await response.json()).snapshots[0];
        expect(snapshot.added).toBe(1);
        expect(snapshot.removed).toBe(0);
        expect(snapshot.basis).toBe('content');
    }, CASE_TIMEOUT_MS);

    test('message_versions_tracks_a_message_by_cf_id_exactly', async () => {
        const card = 'CfId';
        const head = header('CfId', 'u-cf', 'd-cf');
        writeChatFile(soloChatPath(server, card, 'cf'), head, [msg('a', true, { cf_id: 'X' }), msg('v3', false, { cf_id: 'Y' })]);
        writeBackup(server, card, '20260801-000001', head, [msg('a', true, { cf_id: 'X' }), msg('v1', false, { cf_id: 'Y' })]);
        writeBackup(server, card, '20260801-000002', head, [msg('a', true, { cf_id: 'X' }), msg('v2', false, { cf_id: 'Y' })]);

        const response = await client.postJson('/api/chats/backups/message-versions', { avatar_url: 'CfId.png', file_name: 'cf', cf_id: 'Y' });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.versions).toEqual([
            { mes: 'v2', backup_ts: '20260801-000002', matched: 'cf_id' },
            { mes: 'v1', backup_ts: '20260801-000001', matched: 'cf_id' },
        ]);
    }, CASE_TIMEOUT_MS);

    test('restore_refuses_a_token_stale_after_a_concurrent_save_and_does_not_clobber_it', async () => {
        const card = 'Cas';
        const head = header('Cas', 'u-cas', 'd-cas');
        writeChatFile(soloChatPath(server, card, 'cas'), head, [msg('m0', true), msg('m1')]);
        writeBackup(server, card, '20260901-000001', head, [msg('m0', true), msg('m1-old')]);

        // The token the undo UI holds, taken from a read endpoint before the concurrent write.
        const list = await (await client.postJson('/api/chats/backups/snapshots', { avatar_url: 'Cas.png', file_name: 'cas' })).json();
        const token = list.change_token;
        expect(typeof token).toBe('string');

        // A whole-file save lands and changes the file token; the restore is not locked against it.
        const save = await client.postJson('/api/chats/save', {
            avatar_url: 'Cas.png', file_name: 'cas', force: true, chat: [head, msg('m0', true), msg('m1'), msg('concurrent', true)],
        });
        expect(save.status).toBe(200);

        const restore = await client.postJson('/api/chats/backups/restore-message', {
            avatar_url: 'Cas.png', file_name: 'cas', index: 1, backup_ts: '20260901-000001', change_token: token,
        });
        expect(restore.status).toBe(409);
        expect((await restore.json()).error).toBe('stale');

        const lines = readChatLines(soloChatPath(server, card, 'cas')).slice(1);
        expect(lines.map(m => m.mes)).toEqual(['m0', 'm1', 'concurrent']);
    }, CASE_TIMEOUT_MS);
});

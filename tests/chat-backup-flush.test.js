import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import { setConfigFilePath } from '../src/util.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

let trySaveChat;
let flushChatBackups;
let CHAT_BACKUPS_PREFIX;

const tempDirs = [];

async function makeTempDir(label) {
    const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), `st-${label}-`));
    tempDirs.push(dir);
    return dir;
}

function serializeChat(chat) {
    return chat.map(m => JSON.stringify(m)).join('\n');
}

const chatV1 = [
    { user_name: 'User', character_name: 'Seraphina', create_date: '2026-07-11@00h00m00s', chat_metadata: {} },
    { name: 'Seraphina', is_user: false, mes: 'first message' },
];
const chatV2 = [...chatV1, { name: 'User', is_user: true, mes: 'second message' }];

beforeAll(async () => {
    // chats.js reads config at module scope, so the config path must be set before the import
    setConfigFilePath(path.join(repoRoot, 'default', 'config.yaml'));
    ({ trySaveChat, flushChatBackups, CHAT_BACKUPS_PREFIX } = await import('../src/endpoints/chats.js'));
});

afterAll(async () => {
    await Promise.all(tempDirs.map(dir => fs.promises.rm(dir, { recursive: true, force: true })));
});

async function listBackups(backupDir) {
    const files = await fs.promises.readdir(backupDir);
    return files.filter(f => f.startsWith(CHAT_BACKUPS_PREFIX)).sort();
}

describe('flushChatBackups', () => {
    test('resolves when no backups are pending', async () => {
        await expect(flushChatBackups()).resolves.toBeUndefined();
    });

    test('backup triggered through the throttled path lands on disk after flush', async () => {
        const backupDir = await makeTempDir('backup');
        const chatDir = await makeTempDir('chat');

        await trySaveChat(chatV1, path.join(chatDir, 'chat.jsonl'), true, 'flush-user', 'Seraphina', backupDir);
        await flushChatBackups();

        const backups = await listBackups(backupDir);
        expect(backups).toHaveLength(1);
        expect(backups[0]).toMatch(/^chat_seraphina_\d{8}-\d{6}\.jsonl$/);
        const content = await fs.promises.readFile(path.join(backupDir, backups[0]), 'utf8');
        expect(content).toBe(serializeChat(chatV1));
    });

    test('flush executes the pending trailing backup with the latest chat data', async () => {
        const backupDir = await makeTempDir('backup-trailing');
        const chatDir = await makeTempDir('chat-trailing');
        const chatFile = path.join(chatDir, 'chat.jsonl');

        // first save fires the leading edge; second lands inside the throttle window as a pending trailing call
        await trySaveChat(chatV1, chatFile, true, 'trailing-user', 'Seraphina', backupDir);
        await trySaveChat(chatV2, chatFile, true, 'trailing-user', 'Seraphina', backupDir);
        await flushChatBackups();

        const backups = await listBackups(backupDir);
        expect(backups.length).toBeGreaterThanOrEqual(1);
        // timestamps sort lexically; the newest backup must carry the trailing call's data
        const newest = backups[backups.length - 1];
        const content = await fs.promises.readFile(path.join(backupDir, newest), 'utf8');
        expect(content).toBe(serializeChat(chatV2));
    });
});

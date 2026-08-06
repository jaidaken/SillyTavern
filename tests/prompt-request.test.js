import { describe, test, expect, beforeEach, afterEach } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { readSettings, readWorld, readChatForPrompt, buildPromptRequest } from '../src/prompt-request';

/** @type {string} */
let root;

beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'prompt-request-'));
    fs.mkdirSync(path.join(root, 'worlds'), { recursive: true });
    fs.mkdirSync(path.join(root, 'characters'), { recursive: true });
    fs.mkdirSync(path.join(root, 'chats'), { recursive: true });
});

afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
});

function writeChat(name, header, rows) {
    const file = path.join(root, 'chats', `${name}.jsonl`);
    fs.writeFileSync(file, [JSON.stringify(header), ...rows.map(r => JSON.stringify(r))].join('\n') + '\n');
    return file;
}

describe('readSettings', () => {
    test('reads the blob', () => {
        fs.writeFileSync(path.join(root, 'settings.json'), JSON.stringify({ max_context: 4096 }));
        expect(readSettings(path.join(root, 'settings.json')).max_context).toBe(4096);
    });

    test('a missing or corrupt file degrades to defaults rather than failing a send', () => {
        expect(readSettings(path.join(root, 'nope.json'))).toEqual({});
        fs.writeFileSync(path.join(root, 'bad.json'), '{ not json');
        expect(readSettings(path.join(root, 'bad.json'))).toEqual({});
    });
});

describe('readWorld', () => {
    test('merges books in the order given, and the first book wins a shared id', () => {
        fs.writeFileSync(path.join(root, 'worlds', 'card.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'from card' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'global.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'from global' }, 2: { uid: 2, content: 'only global' } } }));

        const world = readWorld(path.join(root, 'worlds'), ['card', 'global']);

        expect(world.entries[1].content).toBe('from card');
        expect(world.entries[2].content).toBe('only global');
    });

    test('skips a book that is missing or unparseable instead of losing the rest', () => {
        fs.writeFileSync(path.join(root, 'worlds', 'good.json'), JSON.stringify({ entries: { 7: { uid: 7, content: 'kept' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'broken.json'), '{ not json');

        const world = readWorld(path.join(root, 'worlds'), ['broken', 'absent', 'good']);

        expect(Object.keys(world.entries)).toEqual(['7']);
    });

    test('no books at all is an empty entry set, not a throw', () => {
        expect(readWorld(path.join(root, 'worlds'), [])).toEqual({ entries: {} });
    });
});

describe('readChatForPrompt', () => {
    test('returns the turns and the header metadata in the builder shape', async () => {
        const file = writeChat('Ada', { user_name: 'Jamie', chat_metadata: { note_prompt: 'the wind rises' } }, [
            { name: 'Ada', mes: 'hello', is_user: false },
            { name: 'Jamie', mes: 'hi', is_user: true },
        ]);

        const { messages, chat_metadata } = await readChatForPrompt(file);

        expect(messages).toEqual([
            { name: 'Ada', mes: 'hello', is_user: false, is_system: false },
            { name: 'Jamie', mes: 'hi', is_user: true, is_system: false },
        ]);
        expect(chat_metadata.note_prompt).toBe('the wind rises');
    });

    test('a missing chat file is an empty window rather than a failure', async () => {
        await expect(readChatForPrompt(path.join(root, 'chats', 'nope.jsonl')))
            .resolves.toEqual({ messages: [], chat_metadata: {} });
    });
});

describe('buildPromptRequest', () => {
    test('assembles every part and marks the window as reaching the head', async () => {
        fs.writeFileSync(path.join(root, 'settings.json'), JSON.stringify({
            max_context: 4096,
            world_info_settings: { world_info: { globalSelect: ['lore'] } },
        }));
        fs.writeFileSync(path.join(root, 'worlds', 'lore.json'), JSON.stringify({ entries: { 3: { uid: 3, content: 'a glade' } } }));
        const chatFilePath = writeChat('Ada', { chat_metadata: {} }, [{ name: 'Jamie', mes: 'hi', is_user: true }]);

        const request = await buildPromptRequest({
            charactersPath: path.join(root, 'characters'),
            worldsPath: path.join(root, 'worlds'),
            settingsPath: path.join(root, 'settings.json'),
            chatFilePath,
            chat: { avatar_url: 'Ada.png', file_name: 'Ada', group_id: null },
            browser: { input: 'hi', utc_offset_minutes: 60, is_mobile: false, generation_type: 'normal', rotation_index: 0 },
        });

        expect(request.settings.max_context).toBe(4096);
        expect(request.world.entries[3].content).toBe('a glade');
        expect(request.messages).toHaveLength(1);
        expect(request.chat.avatar_url).toBe('Ada.png');
        expect(request.browser.input).toBe('hi');
        expect(request.at_head).toBe(true);
        // A card that cannot be read must not stop a send; it degrades to an empty card.
        expect(request.card).toEqual({});
    });

    test('a card linking its own book puts that book ahead of the global selection', async () => {
        fs.writeFileSync(path.join(root, 'settings.json'), JSON.stringify({
            world_info_settings: { world_info: { globalSelect: ['global'] } },
        }));
        fs.writeFileSync(path.join(root, 'worlds', 'global.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'global wins nothing' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'cardbook.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'card book wins' } } }));
        const chatFilePath = writeChat('Ada', { chat_metadata: {} }, []);

        const request = await buildPromptRequest({
            charactersPath: path.join(root, 'characters'),
            worldsPath: path.join(root, 'worlds'),
            settingsPath: path.join(root, 'settings.json'),
            chatFilePath,
            chat: { avatar_url: 'Ada.png', file_name: 'Ada', group_id: null },
        });
        // No readable card here, so the link cannot come from it; the global selection still loads.
        expect(request.world.entries[1].content).toBe('global wins nothing');
        expect(request.browser).toEqual({});
    });
});

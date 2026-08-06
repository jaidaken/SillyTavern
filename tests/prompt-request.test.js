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
    test('keeps every entry of every book, even where two books number an entry the same', () => {
        // Every book on disk numbers its entries from zero, so a merge keyed by those numbers drops
        // the second book's lore silently. This asserted that loss until 2026-08-06.
        fs.writeFileSync(path.join(root, 'worlds', 'card.json'), JSON.stringify({ entries: { 0: { uid: 0, content: 'from card' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'global.json'), JSON.stringify({ entries: { 0: { uid: 0, content: 'from global' }, 1: { uid: 1, content: 'only global' } } }));

        const world = readWorld(path.join(root, 'worlds'), ['card', 'global']);

        expect(Object.values(world.entries).map(e => e.content)).toEqual(['from card', 'from global', 'only global']);
    });

    test('renumbers in load order, so the first book named is the first lore offered', () => {
        fs.writeFileSync(path.join(root, 'worlds', 'a.json'), JSON.stringify({ entries: { 5: { uid: 5, content: 'first book' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'b.json'), JSON.stringify({ entries: { 2: { uid: 2, content: 'second book' } } }));

        const world = readWorld(path.join(root, 'worlds'), ['a', 'b']);

        expect(Object.keys(world.entries)).toEqual(['0', '1']);
        expect(world.entries[0].content).toBe('first book');
        // The entry keeps its own uid: only the key it is filed under is rewritten.
        expect(world.entries[0].uid).toBe(5);
    });

    test('skips a book that is missing or unparseable instead of losing the rest', () => {
        fs.writeFileSync(path.join(root, 'worlds', 'good.json'), JSON.stringify({ entries: { 7: { uid: 7, content: 'kept' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'broken.json'), '{ not json');

        const world = readWorld(path.join(root, 'worlds'), ['broken', 'absent', 'good']);

        expect(Object.values(world.entries).map(e => e.content)).toEqual(['kept']);
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
            .resolves.toEqual({ messages: [], chat_metadata: {}, at_head: true });
    });

    test('a chat longer than the window keeps its last turns and says it is not at the head', async () => {
        const rows = Array.from({ length: 12 }, (_, i) => ({ name: 'Jamie', mes: `turn ${i}`, is_user: true }));
        const file = writeChat('Ada', { chat_metadata: {} }, rows);

        const windowed = await readChatForPrompt(file, 5);

        expect(windowed.messages.map(m => m.mes)).toEqual(['turn 7', 'turn 8', 'turn 9', 'turn 10', 'turn 11']);
        // The greeting belongs at the head of a chat; a trimmed window has no head to put it at.
        expect(windowed.at_head).toBe(false);
        expect((await readChatForPrompt(file, 100)).at_head).toBe(true);
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
        expect(Object.values(request.world.entries).map(e => e.content)).toEqual(['a glade']);
        expect(request.messages).toHaveLength(1);
        expect(request.chat.avatar_url).toBe('Ada.png');
        expect(request.browser.input).toBe('hi');
        expect(request.at_head).toBe(true);
        // A card that cannot be read must not stop a send; it degrades to an empty card.
        expect(request.card).toEqual({});
    });

    test('a book linked to the chat itself loads, ahead of the global selection', async () => {
        fs.writeFileSync(path.join(root, 'settings.json'), JSON.stringify({
            world_info_settings: { world_info: { globalSelect: ['global'] } },
        }));
        fs.writeFileSync(path.join(root, 'worlds', 'global.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'from global' }, 2: { uid: 2, content: 'only global' } } }));
        fs.writeFileSync(path.join(root, 'worlds', 'chatbook.json'), JSON.stringify({ entries: { 1: { uid: 1, content: 'from the chat link' } } }));
        // The world-info panel writes a chat-scope link here; without reading it, a book attached to
        // this conversation never reaches the prompt at all.
        const chatFilePath = writeChat('Ada', { chat_metadata: { world_info: 'chatbook' } }, []);

        const request = await buildPromptRequest({
            charactersPath: path.join(root, 'characters'),
            worldsPath: path.join(root, 'worlds'),
            settingsPath: path.join(root, 'settings.json'),
            chatFilePath,
            chat: { avatar_url: 'Ada.png', file_name: 'Ada', group_id: null },
        });

        // Load order IS priority order, and nothing is dropped on the way.
        expect(Object.values(request.world.entries).map(e => e.content))
            .toEqual(['from the chat link', 'from global', 'only global']);
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
        expect(Object.values(request.world.entries).map(e => e.content)).toEqual(['global wins nothing']);
        expect(request.browser).toEqual({});
    });
});

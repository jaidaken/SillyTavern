import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { openTwoHandleSessions } from '../util/sessions.js';
import { SseStream } from '../util/sse-stream.js';
import { characterCardV2 } from '../util/fixtures.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 60000;
const SECOND_HANDLE = 'p2csecond';
const QUIET_WINDOW_MS = 750;
const ORIGIN_CLIENT_ID = 'origin-tab-1';

const PNG_PIXEL = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64',
);

describe('persist-site client events', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {import('../util/st-client.js').SillyTavernClient} */
    let first;
    /** @type {import('../util/st-client.js').SillyTavernClient} */
    let second;
    /** @type {SseStream[]} */
    const opened = [];

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start({ clientEvents: { heartbeatSeconds: 60, probeSeconds: 3600 } });
        ({ first, second } = await openTwoHandleSessions(server, SECOND_HANDLE));
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await Promise.all(opened.map(stream => stream.close()));
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    /**
     * @param {import('../util/st-client.js').SillyTavernClient} client Logged-in client
     * @param {object} [options] Extra stream options
     * @returns {Promise<SseStream>} An open stream, closed during teardown
     */
    async function openStream(client, { pathname = '/api/events', ...options } = {}) {
        const stream = await SseStream.open(server.baseUrl, pathname, {
            cookieHeader: client.cookieHeader,
            csrfToken: client.csrfToken,
            ...options,
        });
        opened.push(stream);
        await stream.waitForFrame(frame => frame.event === 'hello');
        return stream;
    }

    /**
     * Creates a character through the real endpoint so chat routes have a card to target.
     * @param {string} name Character name
     * @returns {Promise<string>} The avatar file name
     */
    async function createCharacter(name) {
        const form = new FormData();
        const card = characterCardV2(name);
        form.append('ch_name', name);
        form.append('file_name', name);
        for (const [key, value] of Object.entries(card.data)) {
            if (typeof value === 'string') form.append(key, value);
        }
        const response = await first.postForm('/api/characters/create', form);
        expect(response.status).toBe(200);
        return (await response.text()).trim();
    }

    test('settings_save_emits_to_the_saving_user', async () => {
        const stream = await openStream(first);

        const response = await first.postJson('/api/settings/save', { probe: Date.now() });
        expect(response.status).toBe(200);

        const event = await stream.waitForFrame(frame => frame.event === 'settings-changed');
        expect(JSON.parse(event.data).source).toBe('settings-save');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('character_create_and_delete_emit_on_their_real_persist_paths', async () => {
        const stream = await openStream(first);
        const avatar = await createCharacter('P2CCreate');

        const created = await stream.waitForFrame(frame => frame.event === 'character-changed');
        expect(JSON.parse(created.data)).toMatchObject({ action: 'create', avatar });
        expect(fs.existsSync(path.join(server.userDirectory(DEFAULT_HANDLE), 'characters', avatar))).toBe(true);

        const deleted = await first.postJson('/api/characters/delete', { avatar_url: avatar });
        expect(deleted.status).toBe(200);

        const deleteEvent = await stream.waitForFrame(
            frame => frame.event === 'character-changed' && JSON.parse(frame.data).action === 'delete',
        );
        expect(JSON.parse(deleteEvent.data).avatar).toBe(avatar);
        expect(fs.existsSync(path.join(server.userDirectory(DEFAULT_HANDLE), 'characters', avatar))).toBe(false);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('preset_save_and_delete_emit_on_their_real_persist_paths', async () => {
        const stream = await openStream(first);

        const saved = await first.postJson('/api/presets/save', {
            name: 'P2CPreset',
            apiId: 'kobold',
            preset: { temp: 0.7 },
        });
        expect(saved.status).toBe(200);
        const saveEvent = await stream.waitForFrame(frame => frame.event === 'preset-changed');
        expect(JSON.parse(saveEvent.data)).toMatchObject({ action: 'save', name: 'P2CPreset' });

        const removed = await first.postJson('/api/presets/delete', { name: 'P2CPreset', apiId: 'kobold' });
        expect(removed.status).toBe(200);
        const deleteEvent = await stream.waitForFrame(
            frame => frame.event === 'preset-changed' && JSON.parse(frame.data).action === 'delete',
        );
        expect(JSON.parse(deleteEvent.data).name).toBe('P2CPreset');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('worldinfo_edit_emits_on_its_real_persist_path', async () => {
        const stream = await openStream(first);

        const edited = await first.postJson('/api/worldinfo/edit', {
            name: 'P2CWorld',
            data: { entries: {} },
        });
        expect(edited.status).toBe(200);

        const event = await stream.waitForFrame(frame => frame.event === 'worldinfo-changed');
        expect(JSON.parse(event.data)).toMatchObject({ action: 'edit', name: 'P2CWorld' });
        expect(fs.existsSync(path.join(server.userDirectory(DEFAULT_HANDLE), 'worlds', 'P2CWorld.json'))).toBe(true);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('background_upload_and_delete_emit_on_their_real_persist_paths', async () => {
        const stream = await openStream(first);

        const form = new FormData();
        form.append('avatar', new Blob([PNG_PIXEL], { type: 'image/png' }), 'p2c-bg.png');
        const uploaded = await first.postForm('/api/backgrounds/upload', form);
        expect(uploaded.status).toBe(200);

        const uploadEvent = await stream.waitForFrame(frame => frame.event === 'background-changed');
        expect(JSON.parse(uploadEvent.data)).toMatchObject({ action: 'upload', name: 'p2c-bg.png' });

        const removed = await first.postJson('/api/backgrounds/delete', { bg: 'p2c-bg.png' });
        expect(removed.status).toBe(200);
        const deleteEvent = await stream.waitForFrame(
            frame => frame.event === 'background-changed' && JSON.parse(frame.data).action === 'delete',
        );
        expect(JSON.parse(deleteEvent.data).name).toBe('p2c-bg.png');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('chat_save_and_append_emit_with_the_appended_messages_in_the_hot_path', async () => {
        const stream = await openStream(first);
        const avatar = await createCharacter('P2CChat');
        await stream.waitForFrame(frame => frame.event === 'character-changed');

        const saved = await first.postJson('/api/chats/save', {
            avatar_url: avatar,
            file_name: 'p2c-chat',
            chat: [{ user_name: 'User', character_name: 'P2CChat', create_date: '2026-01-01' }],
        });
        expect(saved.status).toBe(200);
        const saveEvent = await stream.waitForFrame(frame => frame.event === 'chat-changed');
        expect(JSON.parse(saveEvent.data)).toMatchObject({ action: 'save', file: 'p2c-chat' });

        const appended = await first.postJson('/api/chats/append', {
            avatar_url: avatar,
            file_name: 'p2c-chat',
            messages: [{ name: 'User', is_user: true, mes: 'hot path payload' }],
        });
        expect(appended.status).toBe(200);

        const hot = await stream.waitForFrame(frame => frame.event === 'chat-appended');
        const payload = JSON.parse(hot.data);
        expect(payload.messages).toHaveLength(1);
        expect(payload.messages[0].mes).toBe('hot path payload');
        expect(payload.file).toBe('p2c-chat');
        expect(typeof payload.change_token).toBe('string');
        expect(payload.change_token.length).toBeGreaterThan(0);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('chat_rename_and_delete_emit_on_their_real_persist_paths', async () => {
        const stream = await openStream(first);
        const avatar = await createCharacter('P2CChatOps');
        await stream.waitForFrame(frame => frame.event === 'character-changed');

        const saved = await first.postJson('/api/chats/save', {
            avatar_url: avatar,
            file_name: 'p2c-ops',
            chat: [{ user_name: 'User', character_name: 'P2CChatOps', create_date: '2026-01-01' }],
        });
        expect(saved.status).toBe(200);
        await stream.waitForFrame(frame => frame.event === 'chat-changed');

        const renamed = await first.postJson('/api/chats/rename', {
            avatar_url: avatar,
            original_file: 'p2c-ops.jsonl',
            renamed_file: 'p2c-ops-renamed.jsonl',
            is_group: false,
        });
        expect(renamed.status).toBe(200);
        const renameEvent = await stream.waitForFrame(
            frame => frame.event === 'chat-changed' && JSON.parse(frame.data).action === 'rename',
        );
        expect(JSON.parse(renameEvent.data).file).toBe('p2c-ops-renamed');

        const removed = await first.postJson('/api/chats/delete', {
            avatar_url: avatar,
            chatfile: 'p2c-ops-renamed.jsonl',
        });
        expect(removed.status).toBe(200);
        const deleteEvent = await stream.waitForFrame(
            frame => frame.event === 'chat-changed' && JSON.parse(frame.data).action === 'delete',
        );
        expect(JSON.parse(deleteEvent.data).file).toBe('p2c-ops-renamed.jsonl');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('character_edit_and_edit_avatar_emit_on_their_real_persist_paths', async () => {
        const stream = await openStream(first);
        const avatar = await createCharacter('P2CEdit');
        await stream.waitForFrame(frame => frame.event === 'character-changed');

        const editForm = new FormData();
        editForm.append('avatar_url', avatar);
        editForm.append('ch_name', 'P2CEdit');
        editForm.append('description', 'edited description');
        const edited = await first.postForm('/api/characters/edit', editForm);
        expect(edited.status).toBe(200);

        const editEvent = await stream.waitForFrame(
            frame => frame.event === 'character-changed' && JSON.parse(frame.data).action === 'edit',
        );
        expect(JSON.parse(editEvent.data).avatar).toBe(avatar);

        const avatarForm = new FormData();
        avatarForm.append('avatar_url', avatar);
        avatarForm.append('avatar', new Blob([PNG_PIXEL], { type: 'image/png' }), 'new-face.png');
        const avatarChanged = await first.postForm('/api/characters/edit-avatar', avatarForm);
        expect(avatarChanged.status).toBe(200);

        const avatarEvent = await stream.waitForFrame(
            frame => frame.event === 'character-changed' && JSON.parse(frame.data).action === 'edit-avatar',
        );
        expect(JSON.parse(avatarEvent.data).avatar).toBe(avatar);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('worldinfo_import_emits_on_its_real_persist_path', async () => {
        const stream = await openStream(first);

        const form = new FormData();
        const world = JSON.stringify({ entries: {} });
        form.append('avatar', new Blob([world], { type: 'application/json' }), 'P2CImported.json');
        const imported = await first.postForm('/api/worldinfo/import', form);
        expect(imported.status).toBe(200);

        const event = await stream.waitForFrame(
            frame => frame.event === 'worldinfo-changed' && JSON.parse(frame.data).action === 'import',
        );
        expect(JSON.parse(event.data).name).toBe('P2CImported');
        expect(fs.existsSync(path.join(server.userDirectory(DEFAULT_HANDLE), 'worlds', 'P2CImported.json'))).toBe(true);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('background_rename_emits_on_its_real_persist_path', async () => {
        const stream = await openStream(first);

        const form = new FormData();
        form.append('avatar', new Blob([PNG_PIXEL], { type: 'image/png' }), 'p2c-rename-src.png');
        const uploaded = await first.postForm('/api/backgrounds/upload', form);
        expect(uploaded.status).toBe(200);
        await stream.waitForFrame(frame => frame.event === 'background-changed');

        const renamed = await first.postJson('/api/backgrounds/rename', {
            old_bg: 'p2c-rename-src.png',
            new_bg: 'p2c-rename-dst.png',
        });
        expect(renamed.status).toBe(200);

        const event = await stream.waitForFrame(
            frame => frame.event === 'background-changed' && JSON.parse(frame.data).action === 'rename',
        );
        expect(JSON.parse(event.data).name).toBe('p2c-rename-dst.png');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('origin_client_is_skipped_while_another_tab_of_the_same_user_still_receives', async () => {
        const originStream = await openStream(first, { pathname: `/api/events?clientId=${ORIGIN_CLIENT_ID}` });
        const otherStream = await openStream(first);

        const response = await first.postJson('/api/settings/save', { probe: Date.now() }, {
            'X-ST-Client-Id': ORIGIN_CLIENT_ID,
        });
        expect(response.status).toBe(200);

        const received = await otherStream.waitForFrame(frame => frame.event === 'settings-changed');
        expect(JSON.parse(received.data).source).toBe('settings-save');

        const echoed = await originStream.framesDuring(QUIET_WINDOW_MS);
        expect(echoed).toEqual([]);
        expect(originStream.frames.some(frame => frame.event === 'settings-changed')).toBe(false);

        // Proves the silence above was the skip and not a stream that could never receive:
        // the same save without the header must reach the very same connection.
        const unattributed = await first.postJson('/api/settings/save', { probe: Date.now() });
        expect(unattributed.status).toBe(200);
        const nowReceived = await originStream.waitForFrame(frame => frame.event === 'settings-changed');
        expect(JSON.parse(nowReceived.data).source).toBe('settings-save');

        await originStream.close();
        await otherStream.close();
    }, CASE_TIMEOUT_MS);

    test('a_persist_event_for_one_handle_never_reaches_another_handle', async () => {
        const streamA = await openStream(first);
        const streamB = await openStream(second);

        const beforeB = streamB.frames.length;
        const avatar = await createCharacter('P2CBoundary');

        const received = await streamA.waitForFrame(frame => frame.event === 'character-changed');
        expect(JSON.parse(received.data).avatar).toBe(avatar);

        const leaked = await streamB.framesDuring(QUIET_WINDOW_MS);
        expect(leaked).toEqual([]);
        expect(streamB.frames.length).toBe(beforeB);
        expect(streamB.frames.some(frame => frame.event === 'character-changed')).toBe(false);

        await streamA.close();
        await streamB.close();
    }, CASE_TIMEOUT_MS);
});

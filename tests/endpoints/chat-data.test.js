import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll, afterEach } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { chatMessages } from '../util/fixtures.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

describe('SillyTavern chat and character data endpoints', () => {
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

    describe('characters', () => {
        test('character_create_with_valid_body_writes_default_avatar_and_returns_avatar_name', async () => {
            const response = await client.postJson('/api/characters/create', {
                file_name: 'P8CreateChar',
                ch_name: 'P8CreateChar',
                description: 'p8-create-marker',
                first_mes: 'hello from create',
            });

            expect(response.status).toBe(200);
            expect(await response.text()).toBe('P8CreateChar.png');
            expect(fs.existsSync(path.join(server.userDirectory(), 'characters', 'P8CreateChar.png'))).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('character_create_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/characters/create', { ch_name: 'ShouldNotExist' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('character_create_with_path_separator_in_file_name_is_rejected', async () => {
            const response = await client.postJson('/api/characters/create', {
                file_name: 'sub/dir',
                ch_name: 'BadPath',
            });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('character_all_lists_the_created_character', async () => {
            const response = await client.postJson('/api/characters/all', {});
            expect(response.status).toBe(200);
            const entry = (await response.json()).find(character => character.avatar === 'P8CreateChar.png');
            expect(entry).toBeDefined();
            expect(entry.description).toBe('p8-create-marker');
        }, CASE_TIMEOUT_MS);

        test('character_all_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/characters/all', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('character_get_returns_the_full_card_for_a_known_avatar', async () => {
            const response = await client.postJson('/api/characters/get', { avatar_url: 'P8CreateChar.png' });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.name).toBe('P8CreateChar');
            expect(body.first_mes).toBe('hello from create');
        }, CASE_TIMEOUT_MS);

        test('character_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/characters/get', { avatar_url: 'P8CreateChar.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('character_get_with_path_separator_in_avatar_url_is_rejected', async () => {
            const response = await client.postJson('/api/characters/get', { avatar_url: '../P8CreateChar.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('character_edit_persists_the_updated_description', async () => {
            const response = await client.postJson('/api/characters/edit', {
                avatar_url: 'P8CreateChar.png',
                ch_name: 'P8CreateChar',
                description: 'p8-edited-marker',
                create_date: new Date().toISOString(),
            });
            expect(response.status).toBe(200);

            const fetched = await client.postJson('/api/characters/get', { avatar_url: 'P8CreateChar.png' });
            expect((await fetched.json()).description).toBe('p8-edited-marker');
        }, CASE_TIMEOUT_MS);

        test('character_edit_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/characters/edit', { avatar_url: 'P8CreateChar.png', ch_name: 'X' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('character_edit_with_empty_name_is_rejected', async () => {
            const response = await client.postJson('/api/characters/edit', { avatar_url: 'P8CreateChar.png', ch_name: '' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('character_delete_removes_the_avatar_file_from_disk', async () => {
            const create = await client.postJson('/api/characters/create', { file_name: 'P8DeleteChar', ch_name: 'P8DeleteChar' });
            expect(create.status).toBe(200);
            const avatarPath = path.join(server.userDirectory(), 'characters', 'P8DeleteChar.png');
            expect(fs.existsSync(avatarPath)).toBe(true);

            const response = await client.postJson('/api/characters/delete', { avatar_url: 'P8DeleteChar.png' });
            expect(response.status).toBe(200);
            expect(fs.existsSync(avatarPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('character_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/characters/delete', { avatar_url: 'P8CreateChar.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('character_delete_without_avatar_url_is_rejected', async () => {
            const response = await client.postJson('/api/characters/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('chats', () => {
        const avatarUrl = 'P8CreateChar.png';
        const fileName = 'p8-chat-file';
        const messages = chatMessages('P8CreateChar');

        // Files a test seeds on disk. Cleaned after each test even when an assertion throws first, so a
        // corrupt fixture cannot survive a failure and poison later cases.
        const tempFiles = [];
        afterEach(() => {
            while (tempFiles.length) fs.rmSync(tempFiles.pop(), { force: true });
        });

        test('chat_save_persists_messages_and_returns_ok', async () => {
            const response = await client.postJson('/api/chats/save', {
                avatar_url: avatarUrl,
                file_name: fileName,
                chat: messages,
                force: true,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const chatPath = path.join(server.userDirectory(), 'chats', 'P8CreateChar', `${fileName}.jsonl`);
            expect(fs.existsSync(chatPath)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('chat_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/chats/save', {
                avatar_url: avatarUrl,
                file_name: fileName,
                chat: messages,
            });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_save_with_a_non_array_chat_body_is_rejected', async () => {
            const response = await client.postJson('/api/chats/save', {
                avatar_url: avatarUrl,
                file_name: fileName,
                chat: { not: 'an array' },
            });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'The request\'s body.chat is not an array.' });
        }, CASE_TIMEOUT_MS);

        test('chat_get_round_trips_the_saved_messages', async () => {
            const response = await client.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: fileName });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual(messages);
        }, CASE_TIMEOUT_MS);

        test('chat_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: fileName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_get_with_path_separator_in_avatar_url_is_rejected', async () => {
            const response = await client.postJson('/api/chats/get', { avatar_url: '../escape.png', file_name: fileName });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('chat_get_for_a_missing_chat_file_returns_empty_success', async () => {
            const response = await client.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: 'NoSuchChatEver' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({});
        }, CASE_TIMEOUT_MS);

        test('chat_get_for_an_unreadable_existing_chat_returns_500_not_empty_success', async () => {
            // A directory posing as the .jsonl: stat succeeds w/ size>0 semantics vary, so seed a
            // real unparseable file instead - non-empty bytes that yield zero parseable lines.
            const corruptName = 'CorruptChat';
            const corruptPath = path.join(server.userDirectory(), 'chats', 'P8CreateChar', `${corruptName}.jsonl`);
            tempFiles.push(corruptPath);
            fs.writeFileSync(corruptPath, '{not json at all\n ');

            const response = await client.postJson('/api/chats/get', { avatar_url: avatarUrl, file_name: corruptName });
            expect(response.status).toBe(500);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_removes_the_chat_file_from_disk', async () => {
            const chatPath = path.join(server.userDirectory(), 'chats', 'P8CreateChar', `${fileName}.jsonl`);
            expect(fs.existsSync(chatPath)).toBe(true);

            const response = await client.postJson('/api/chats/delete', { avatar_url: avatarUrl, chatfile: fileName });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });
            expect(fs.existsSync(chatPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/chats/delete', { avatar_url: avatarUrl, chatfile: fileName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_with_path_separator_in_avatar_url_is_rejected', async () => {
            const response = await client.postJson('/api/chats/delete', { avatar_url: '../escape.png', chatfile: fileName });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('groups', () => {
        let groupId;

        test('group_create_writes_metadata_and_returns_it', async () => {
            const response = await client.postJson('/api/groups/create', {
                name: 'P8TestGroup',
                members: ['P8CreateChar.png'],
            });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.name).toBe('P8TestGroup');
            expect(body.members).toEqual(['P8CreateChar.png']);
            expect(body.id).toEqual(expect.any(String));
            groupId = body.id;

            const groupPath = path.join(server.userDirectory(), 'groups', `${groupId}.json`);
            expect(fs.existsSync(groupPath)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('group_create_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/groups/create', { name: 'ShouldNotExist' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('group_all_lists_the_created_group', async () => {
            const response = await client.postJson('/api/groups/all', {});
            expect(response.status).toBe(200);
            const entry = (await response.json()).find(group => group.id === groupId);
            expect(entry).toBeDefined();
            expect(entry.name).toBe('P8TestGroup');
        }, CASE_TIMEOUT_MS);

        test('group_all_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/groups/all', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('group_edit_persists_the_updated_name_to_disk', async () => {
            const response = await client.postJson('/api/groups/edit', {
                id: groupId,
                name: 'P8TestGroupRenamed',
                members: ['P8CreateChar.png'],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const groupPath = path.join(server.userDirectory(), 'groups', `${groupId}.json`);
            expect(JSON.parse(fs.readFileSync(groupPath, 'utf8')).name).toBe('P8TestGroupRenamed');
        }, CASE_TIMEOUT_MS);

        test('group_edit_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/groups/edit', { id: groupId, name: 'X' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('group_edit_without_id_is_rejected', async () => {
            const response = await client.postJson('/api/groups/edit', { name: 'NoId' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('group_delete_removes_the_group_file_from_disk', async () => {
            const groupPath = path.join(server.userDirectory(), 'groups', `${groupId}.json`);
            expect(fs.existsSync(groupPath)).toBe(true);

            const response = await client.postJson('/api/groups/delete', { id: groupId });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });
            expect(fs.existsSync(groupPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('group_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/groups/delete', { id: groupId });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('group_delete_without_id_is_rejected', async () => {
            const response = await client.postJson('/api/groups/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('worldinfo', () => {
        const worldName = 'P8TestWorld';

        test('worldinfo_import_writes_file_and_returns_the_world_name', async () => {
            const worldData = { entries: { '0': { key: ['trigger'], content: 'p8-worldinfo-marker' } } };
            const form = new FormData();
            form.append('avatar', new Blob([JSON.stringify(worldData)], { type: 'application/json' }), `${worldName}.json`);

            const response = await client.postForm('/api/worldinfo/import', form);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ name: worldName });

            const worldPath = path.join(server.userDirectory(), 'worlds', `${worldName}.json`);
            expect(fs.existsSync(worldPath)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_import_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const form = new FormData();
            form.append('avatar', new Blob([JSON.stringify({ entries: {} })], { type: 'application/json' }), 'Anon.json');

            const response = await anonymous.postForm('/api/worldinfo/import', form);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_import_without_an_entries_key_is_rejected', async () => {
            const form = new FormData();
            form.append('avatar', new Blob([JSON.stringify({ not_entries: true })], { type: 'application/json' }), 'Bad.json');

            const response = await client.postForm('/api/worldinfo/import', form);
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_list_includes_the_imported_world', async () => {
            const response = await client.postJson('/api/worldinfo/list', {});
            expect(response.status).toBe(200);
            const entry = (await response.json()).find(world => world.file_id === worldName);
            expect(entry).toBeDefined();
        }, CASE_TIMEOUT_MS);

        test('worldinfo_list_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/worldinfo/list', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_get_returns_the_stored_entries', async () => {
            const response = await client.postJson('/api/worldinfo/get', { name: worldName });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.entries['0'].content).toBe('p8-worldinfo-marker');
        }, CASE_TIMEOUT_MS);

        test('worldinfo_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/worldinfo/get', { name: worldName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_get_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/worldinfo/get', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_edit_overwrites_the_entries_on_disk', async () => {
            const response = await client.postJson('/api/worldinfo/edit', {
                name: worldName,
                data: { entries: { '0': { key: ['trigger'], content: 'p8-worldinfo-edited' } } },
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const worldPath = path.join(server.userDirectory(), 'worlds', `${worldName}.json`);
            expect(JSON.parse(fs.readFileSync(worldPath, 'utf8')).entries['0'].content).toBe('p8-worldinfo-edited');
        }, CASE_TIMEOUT_MS);

        test('worldinfo_edit_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/worldinfo/edit', { name: worldName, data: { entries: {} } });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_edit_without_an_entries_list_is_rejected', async () => {
            const response = await client.postJson('/api/worldinfo/edit', { name: worldName, data: {} });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_delete_removes_the_world_file_from_disk', async () => {
            const worldPath = path.join(server.userDirectory(), 'worlds', `${worldName}.json`);
            expect(fs.existsSync(worldPath)).toBe(true);

            const response = await client.postJson('/api/worldinfo/delete', { name: worldName });
            expect(response.status).toBe(200);
            expect(fs.existsSync(worldPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/worldinfo/delete', { name: worldName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('worldinfo_delete_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/worldinfo/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('presets', () => {
        const presetName = 'P8TestPreset';

        test('preset_save_writes_the_preset_file_and_returns_its_name', async () => {
            const response = await client.postJson('/api/presets/save', {
                apiId: 'openai',
                name: presetName,
                preset: { temperature: 0.7, marker: 'p8-preset-marker' },
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ name: presetName });

            const presetPath = path.join(server.userDirectory(), 'OpenAI Settings', `${presetName}.json`);
            expect(JSON.parse(fs.readFileSync(presetPath, 'utf8')).marker).toBe('p8-preset-marker');
        }, CASE_TIMEOUT_MS);

        test('preset_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/presets/save', { apiId: 'openai', name: 'Anon', preset: {} });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('preset_save_without_a_preset_body_is_rejected', async () => {
            const response = await client.postJson('/api/presets/save', { apiId: 'openai', name: presetName });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('preset_delete_removes_the_preset_file_from_disk', async () => {
            const presetPath = path.join(server.userDirectory(), 'OpenAI Settings', `${presetName}.json`);
            expect(fs.existsSync(presetPath)).toBe(true);

            const response = await client.postJson('/api/presets/delete', { apiId: 'openai', name: presetName });
            expect(response.status).toBe(200);
            expect(fs.existsSync(presetPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('preset_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/presets/delete', { apiId: 'openai', name: presetName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('preset_delete_with_an_empty_name_is_rejected', async () => {
            const response = await client.postJson('/api/presets/delete', { apiId: 'openai', name: '' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('preset_delete_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/presets/delete', { apiId: 'openai' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('preset_restore_reports_a_non_default_preset_as_not_default', async () => {
            const response = await client.postJson('/api/presets/restore', { apiId: 'openai', name: presetName });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ isDefault: false, preset: {} });
        }, CASE_TIMEOUT_MS);

        test('preset_restore_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/presets/restore', { apiId: 'openai', name: presetName });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('stats', () => {
        test('stats_get_returns_the_stats_object_for_the_logged_in_user', async () => {
            const response = await client.postJson('/api/stats/get', {});
            expect(response.status).toBe(200);
            expect(typeof (await response.json())).toBe('object');
        }, CASE_TIMEOUT_MS);

        test('stats_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/stats/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('stats_update_stores_the_provided_stats_object', async () => {
            const response = await client.postJson('/api/stats/update', { p8_marker: 'p8-stats-marker' });
            expect(response.status).toBe(200);

            const fetched = await client.postJson('/api/stats/get', {});
            expect((await fetched.json()).p8_marker).toBe('p8-stats-marker');
        }, CASE_TIMEOUT_MS);

        test('stats_update_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/stats/update', { p8_marker: 'anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('stats_update_with_a_null_body_is_rejected', async () => {
            const response = await client.postRaw('/api/stats/update', 'null', 'application/json');
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('stats_recreate_replaces_manually_set_stats_with_recomputed_values', async () => {
            const response = await client.postJson('/api/stats/recreate', {});
            expect(response.status).toBe(200);

            const fetched = await client.postJson('/api/stats/get', {});
            const body = await fetched.json();
            expect(body).toHaveProperty('timestamp');
            expect(body.p8_marker).toBeUndefined();
        }, CASE_TIMEOUT_MS);

        test('stats_recreate_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/stats/recreate', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });
});

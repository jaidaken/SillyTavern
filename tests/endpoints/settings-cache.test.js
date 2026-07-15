import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

describe('SillyTavern settings payload cache', () => {
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

    test('settings_get_reflects_a_theme_saved_after_the_cache_was_warmed', async () => {
        const warmed = await client.postJson('/api/settings/get', {});
        expect(warmed.status).toBe(200);
        const before = await warmed.json();
        expect(before.themes.some(theme => theme?.name === 'CacheProbeTheme')).toBe(false);

        const saved = await client.postJson('/api/themes/save', { name: 'CacheProbeTheme', main_text_color: '#abcdef' });
        expect(saved.status).toBe(200);

        const refetched = await client.postJson('/api/settings/get', {});
        expect(refetched.status).toBe(200);
        const after = await refetched.json();
        const probe = after.themes.find(theme => theme?.name === 'CacheProbeTheme');
        expect(probe).toBeDefined();
        expect(probe.main_text_color).toBe('#abcdef');
    }, CASE_TIMEOUT_MS);

    test('settings_get_reflects_a_preset_saved_after_the_cache_was_warmed', async () => {
        const warmed = await client.postJson('/api/settings/get', {});
        expect(warmed.status).toBe(200);
        const before = await warmed.json();
        expect(before.openai_setting_names).not.toContain('CacheProbePreset');

        const saved = await client.postJson('/api/presets/save', {
            name: 'CacheProbePreset',
            apiId: 'openai',
            preset: { temperature: 0.42 },
        });
        expect(saved.status).toBe(200);

        const refetched = await client.postJson('/api/settings/get', {});
        expect(refetched.status).toBe(200);
        const after = await refetched.json();
        expect(after.openai_setting_names).toContain('CacheProbePreset');
        const index = after.openai_setting_names.indexOf('CacheProbePreset');
        expect(JSON.parse(after.openai_settings[index]).temperature).toBe(0.42);
    }, CASE_TIMEOUT_MS);

    test('settings_get_serves_the_full_composed_payload_on_an_unchanged_cache_hit', async () => {
        const first = await client.postJson('/api/settings/get', {});
        expect(first.status).toBe(200);
        const firstBody = await first.json();

        const second = await client.postJson('/api/settings/get', {});
        expect(second.status).toBe(200);
        const secondBody = await second.json();

        expect(Array.isArray(secondBody.themes)).toBe(true);
        expect(secondBody.themes).toEqual(firstBody.themes);
        expect(secondBody.openai_setting_names).toEqual(firstBody.openai_setting_names);
        expect(secondBody.world_names).toEqual(firstBody.world_names);
        expect(secondBody.instruct).toEqual(firstBody.instruct);
    }, CASE_TIMEOUT_MS);
});

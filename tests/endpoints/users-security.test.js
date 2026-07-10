import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import { fromBuffer } from 'yauzl';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const NON_ADMIN_HANDLE = 'p8nonadmin';
const CHAT_BACKUPS_DIR = 'backups';

/**
 * Lists the entry names inside a zip archive without extracting file contents.
 * @param {Buffer} buffer Zip archive bytes
 * @returns {Promise<string[]>} Entry file names
 */
function listZipEntryNames(buffer) {
    return new Promise((resolve, reject) => {
        fromBuffer(buffer, { lazyEntries: true }, (err, zipfile) => {
            if (err) return reject(err);
            const names = [];
            zipfile.on('entry', (entry) => {
                names.push(entry.fileName);
                zipfile.readEntry();
            });
            zipfile.on('end', () => resolve(names));
            zipfile.on('error', reject);
            zipfile.readEntry();
        });
    });
}

describe('SillyTavern users, secrets, and backups endpoints', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let client;
    /** @type {SillyTavernClient} */
    let nonAdminClient;

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start();

        client = new SillyTavernClient(server.baseUrl);
        await client.fetchCsrfToken();
        const login = await client.login(DEFAULT_HANDLE);
        if (login.status !== 200) {
            throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
        }

        const created = await client.postJson('/api/users/create', {
            handle: NON_ADMIN_HANDLE,
            name: 'P8 NonAdmin',
            password: '',
            admin: false,
        });
        if (created.status !== 200) {
            throw new Error(`Failed to provision the non-admin fixture user: ${created.status} ${await created.text()}`);
        }

        nonAdminClient = new SillyTavernClient(server.baseUrl);
        await nonAdminClient.fetchCsrfToken();
        const nonAdminLogin = await nonAdminClient.login(NON_ADMIN_HANDLE);
        if (nonAdminLogin.status !== 200) {
            throw new Error(`Non-admin client failed to log in: ${nonAdminLogin.status} ${await nonAdminLogin.text()}`);
        }
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    describe('users-public', () => {
        test('list_returns_enabled_users_without_requiring_a_session', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            await anonymous.fetchCsrfToken();
            const response = await anonymous.postJson('/api/users/list', {});

            expect(response.status).toBe(200);
            const body = await response.json();
            const entry = body.find(user => user.handle === DEFAULT_HANDLE);
            expect(entry).toBeDefined();
            expect(entry.password).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('recover_step1_without_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/recover-step1', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('recover_step1_with_unknown_handle_returns_not_found', async () => {
            const response = await client.postJson('/api/users/recover-step1', { handle: 'p8-no-such-user' });
            expect(response.status).toBe(404);
            expect(await response.json()).toEqual({ error: 'User not found' });
        }, CASE_TIMEOUT_MS);

        test('recover_step2_without_required_fields_is_rejected', async () => {
            const response = await client.postJson('/api/users/recover-step2', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('recover_step2_with_unknown_handle_returns_not_found', async () => {
            const response = await client.postJson('/api/users/recover-step2', { handle: 'p8-no-such-user', code: '000000' });
            expect(response.status).toBe(404);
            expect(await response.json()).toEqual({ error: 'User not found' });
        }, CASE_TIMEOUT_MS);

        test('recover_step2_with_known_handle_and_wrong_code_is_rejected', async () => {
            const response = await client.postJson('/api/users/recover-step2', { handle: DEFAULT_HANDLE, code: '000000' });
            expect(response.status).toBe(403);
            expect(await response.json()).toEqual({ error: 'Incorrect code' });
        }, CASE_TIMEOUT_MS);
    });

    describe('users-private', () => {
        test('me_returns_the_profile_for_the_logged_in_user', async () => {
            const response = await client.get('/api/users/me');
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.handle).toBe(DEFAULT_HANDLE);
            expect(body.admin).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('me_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.get('/api/users/me');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('change_avatar_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/change-avatar', { avatar: '' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('change_avatar_with_a_non_data_url_avatar_is_rejected', async () => {
            const response = await client.postJson('/api/users/change-avatar', { handle: DEFAULT_HANDLE, avatar: 'not-a-data-url' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Invalid data URL' });
        }, CASE_TIMEOUT_MS);

        test('change_avatar_updates_the_avatar_for_own_handle', async () => {
            const response = await client.postJson('/api/users/change-avatar', { handle: DEFAULT_HANDLE, avatar: '' });
            expect(response.status).toBe(204);
        }, CASE_TIMEOUT_MS);

        test('change_avatar_for_another_handle_is_rejected_for_non_admin_client', async () => {
            const response = await nonAdminClient.postJson('/api/users/change-avatar', { handle: DEFAULT_HANDLE, avatar: '' });
            expect(response.status).toBe(403);
            expect(await response.json()).toEqual({ error: 'Unauthorized' });
        }, CASE_TIMEOUT_MS);

        test('change_avatar_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/change-avatar', { handle: DEFAULT_HANDLE, avatar: '' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('change_password_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/change-password', { newPassword: 'irrelevant' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('change_password_for_another_handle_is_rejected_for_non_admin_client', async () => {
            const response = await nonAdminClient.postJson('/api/users/change-password', { handle: DEFAULT_HANDLE, newPassword: 'x' });
            expect(response.status).toBe(403);
            expect(await response.json()).toEqual({ error: 'Unauthorized' });
        }, CASE_TIMEOUT_MS);

        test('change_password_round_trips_a_new_password_and_updates_the_session_version', async () => {
            const changed = await client.postJson('/api/users/change-password', { handle: DEFAULT_HANDLE, newPassword: 'p8-new-secret' });
            expect(changed.status).toBe(204);

            const reLogin = new SillyTavernClient(server.baseUrl);
            await reLogin.fetchCsrfToken();
            const withNewPassword = await reLogin.login(DEFAULT_HANDLE, 'p8-new-secret');
            expect(withNewPassword.status).toBe(200);

            const reverted = await client.postJson('/api/users/change-password', { handle: DEFAULT_HANDLE, newPassword: '' });
            expect(reverted.status).toBe(204);
        }, CASE_TIMEOUT_MS);

        test('change_password_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/change-password', { handle: DEFAULT_HANDLE, newPassword: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('backup_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/backup', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('backup_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/backup', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('backup_for_another_handle_is_rejected_for_non_admin_client', async () => {
            const response = await nonAdminClient.postJson('/api/users/backup', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(403);
            expect(await response.json()).toEqual({ error: 'Unauthorized' });
        }, CASE_TIMEOUT_MS);

        test('backup_archive_excludes_the_secrets_file', async () => {
            const marker = 'sk-p8-backup-marker-should-not-leak';
            const written = await client.postJson('/api/secrets/write', { key: 'api_key_custom', value: marker, label: 'p8-backup' });
            expect(written.status).toBe(200);

            const backup = await client.postJson('/api/users/backup', { handle: DEFAULT_HANDLE });
            expect(backup.status).toBe(200);
            const buffer = Buffer.from(await backup.arrayBuffer());

            const entryNames = await listZipEntryNames(buffer);
            expect(entryNames).not.toContain('secrets.json');
            expect(buffer.toString('latin1')).not.toContain(marker);
        }, CASE_TIMEOUT_MS);

        test('reset_settings_recreates_the_settings_file', async () => {
            const settingsPath = path.join(server.userDirectory(), 'settings.json');
            const response = await client.postJson('/api/users/reset-settings', { password: '' });
            expect(response.status).toBe(204);
            expect(fs.existsSync(settingsPath)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('reset_settings_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/reset-settings', { password: '' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('change_name_missing_fields_is_rejected', async () => {
            const response = await client.postJson('/api/users/change-name', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('change_name_updates_the_display_name', async () => {
            const response = await client.postJson('/api/users/change-name', { handle: DEFAULT_HANDLE, name: 'P8 Renamed User' });
            expect(response.status).toBe(204);

            const me = await client.get('/api/users/me');
            expect((await me.json()).name).toBe('P8 Renamed User');
        }, CASE_TIMEOUT_MS);

        test('change_name_for_another_handle_is_rejected_for_non_admin_client', async () => {
            const response = await nonAdminClient.postJson('/api/users/change-name', { handle: DEFAULT_HANDLE, name: 'Hijacked' });
            expect(response.status).toBe(403);
            expect(await response.json()).toEqual({ error: 'Unauthorized' });
        }, CASE_TIMEOUT_MS);

        test('change_name_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/change-name', { handle: DEFAULT_HANDLE, name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('reset_step1_returns_no_content_and_caches_a_reset_code', async () => {
            const response = await client.postJson('/api/users/reset-step1', {});
            expect(response.status).toBe(204);
        }, CASE_TIMEOUT_MS);

        test('reset_step1_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/reset-step1', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('reset_step2_without_a_code_is_rejected', async () => {
            const response = await client.postJson('/api/users/reset-step2', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('reset_step2_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/reset-step2', { code: '0000' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('logout_invalidates_the_session', async () => {
            const fresh = new SillyTavernClient(server.baseUrl);
            await fresh.fetchCsrfToken();
            const login = await fresh.login(DEFAULT_HANDLE);
            expect(login.status).toBe(200);

            const authorized = await fresh.get('/api/users/me');
            expect(authorized.status).toBe(200);

            const loggedOut = await fresh.postJson('/api/users/logout', {});
            expect(loggedOut.status).toBe(204);

            const afterLogout = await fresh.get('/api/users/me');
            expect(afterLogout.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('logout_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/logout', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('users-admin', () => {
        test('get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/users/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('get_is_rejected_for_non_admin_client', async () => {
            const response = await nonAdminClient.postJson('/api/users/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('get_lists_the_provisioned_non_admin_fixture_user', async () => {
            const response = await client.postJson('/api/users/get', {});
            expect(response.status).toBe(200);
            const entry = (await response.json()).find(user => user.handle === NON_ADMIN_HANDLE);
            expect(entry).toBeDefined();
            expect(entry.admin).toBe(false);
            expect(entry.enabled).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('create_missing_fields_is_rejected', async () => {
            const response = await client.postJson('/api/users/create', { handle: 'incomplete' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('create_with_a_handle_that_already_exists_is_rejected', async () => {
            const response = await client.postJson('/api/users/create', { handle: NON_ADMIN_HANDLE, name: 'Duplicate' });
            expect(response.status).toBe(409);
            expect(await response.json()).toEqual({ error: 'User already exists' });
        }, CASE_TIMEOUT_MS);

        test('slugify_converts_text_to_a_url_safe_handle', async () => {
            const response = await client.postJson('/api/users/slugify', { text: 'Héllo World!' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('hello-world');
        }, CASE_TIMEOUT_MS);

        test('slugify_missing_text_is_rejected', async () => {
            const response = await client.postJson('/api/users/slugify', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('disable_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/disable', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('disable_cannot_disable_yourself', async () => {
            const response = await client.postJson('/api/users/disable', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Cannot disable yourself' });
        }, CASE_TIMEOUT_MS);

        test('disable_blocks_login_for_the_target_user_until_re_enabled', async () => {
            const disabled = await client.postJson('/api/users/disable', { handle: NON_ADMIN_HANDLE });
            expect(disabled.status).toBe(204);

            const blockedLogin = new SillyTavernClient(server.baseUrl);
            await blockedLogin.fetchCsrfToken();
            const loginWhileDisabled = await blockedLogin.login(NON_ADMIN_HANDLE);
            expect(loginWhileDisabled.status).toBe(403);
            expect(await loginWhileDisabled.json()).toEqual({ error: 'User is disabled' });

            const enabled = await client.postJson('/api/users/enable', { handle: NON_ADMIN_HANDLE });
            expect(enabled.status).toBe(204);

            const reLogin = new SillyTavernClient(server.baseUrl);
            await reLogin.fetchCsrfToken();
            const loginAfterEnable = await reLogin.login(NON_ADMIN_HANDLE);
            expect(loginAfterEnable.status).toBe(200);
        }, CASE_TIMEOUT_MS);

        test('enable_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/enable', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('promote_then_demote_round_trips_the_admin_flag', async () => {
            const promoted = await client.postJson('/api/users/promote', { handle: NON_ADMIN_HANDLE });
            expect(promoted.status).toBe(204);

            const afterPromote = await client.postJson('/api/users/get', {});
            const promotedEntry = (await afterPromote.json()).find(user => user.handle === NON_ADMIN_HANDLE);
            expect(promotedEntry.admin).toBe(true);

            const demoted = await client.postJson('/api/users/demote', { handle: NON_ADMIN_HANDLE });
            expect(demoted.status).toBe(204);

            const afterDemote = await client.postJson('/api/users/get', {});
            const demotedEntry = (await afterDemote.json()).find(user => user.handle === NON_ADMIN_HANDLE);
            expect(demotedEntry.admin).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('promote_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/promote', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('delete_cannot_delete_yourself', async () => {
            const response = await client.postJson('/api/users/delete', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Cannot delete yourself' });
        }, CASE_TIMEOUT_MS);

        test('delete_cannot_delete_the_default_user_even_as_a_different_admin', async () => {
            const promoted = await client.postJson('/api/users/promote', { handle: NON_ADMIN_HANDLE });
            expect(promoted.status).toBe(204);

            const otherAdmin = new SillyTavernClient(server.baseUrl);
            await otherAdmin.fetchCsrfToken();
            const login = await otherAdmin.login(NON_ADMIN_HANDLE);
            expect(login.status).toBe(200);

            const response = await otherAdmin.postJson('/api/users/delete', { handle: DEFAULT_HANDLE });
            expect(response.status).toBe(400);
            expect((await response.json()).error).toMatch(/default user cannot be deleted/);

            const demoted = await client.postJson('/api/users/demote', { handle: NON_ADMIN_HANDLE });
            expect(demoted.status).toBe(204);
        }, CASE_TIMEOUT_MS);

        test('delete_missing_handle_is_rejected', async () => {
            const response = await client.postJson('/api/users/delete', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required fields' });
        }, CASE_TIMEOUT_MS);

        test('delete_removes_the_user_and_purges_its_directory_when_requested', async () => {
            const created = await client.postJson('/api/users/create', { handle: 'p8throwaway', name: 'P8 Throwaway' });
            expect(created.status).toBe(200);
            const throwawayDir = server.userDirectory('p8throwaway');
            expect(fs.existsSync(throwawayDir)).toBe(true);

            const deleted = await client.postJson('/api/users/delete', { handle: 'p8throwaway', purge: true });
            expect(deleted.status).toBe(204);
            expect(fs.existsSync(throwawayDir)).toBe(false);

            const list = await client.postJson('/api/users/get', {});
            expect((await list.json()).find(user => user.handle === 'p8throwaway')).toBeUndefined();
        }, CASE_TIMEOUT_MS);
    });

    describe('secrets', () => {
        test('write_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/secrets/write', { key: 'api_key_openai', value: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('write_with_a_missing_value_is_rejected', async () => {
            const response = await client.postJson('/api/secrets/write', { key: 'api_key_openai' });
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Invalid key or value');
        }, CASE_TIMEOUT_MS);

        test('write_then_read_masks_a_short_value_entirely', async () => {
            const written = await client.postJson('/api/secrets/write', { key: 'api_key_deepseek', value: 'short1', label: 'p8-short' });
            expect(written.status).toBe(200);
            const { id } = await written.json();
            expect(id).toEqual(expect.any(String));

            const state = await client.postJson('/api/secrets/read', {});
            const body = await state.json();
            expect(body.api_key_deepseek).toEqual([{ id, value: '**********', label: 'p8-short', active: true }]);
        }, CASE_TIMEOUT_MS);

        test('read_reports_null_for_a_key_with_no_stored_secret', async () => {
            const response = await client.postJson('/api/secrets/read', {});
            const body = await response.json();
            expect(body.api_key_claude).toBeNull();
        }, CASE_TIMEOUT_MS);

        test('view_is_forbidden_when_key_exposure_is_disabled', async () => {
            const response = await client.postJson('/api/secrets/view', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('find_missing_key_is_rejected', async () => {
            const response = await client.postJson('/api/secrets/find', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('find_is_forbidden_for_a_non_exportable_key_when_exposure_is_disabled', async () => {
            const response = await client.postJson('/api/secrets/find', { key: 'api_key_deepseek' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('find_returns_the_plaintext_value_for_an_exportable_key_without_requiring_exposure', async () => {
            const written = await client.postJson('/api/secrets/write', { key: 'libre_url', value: 'https://p8-libre.example/translate', label: 'p8-url' });
            expect(written.status).toBe(200);

            const response = await client.postJson('/api/secrets/find', { key: 'libre_url' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ value: 'https://p8-libre.example/translate' });
        }, CASE_TIMEOUT_MS);

        test('find_for_an_unknown_key_returns_not_found', async () => {
            const response = await client.postJson('/api/secrets/find', { key: 'lingva_url' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('delete_missing_key_is_rejected', async () => {
            const response = await client.postJson('/api/secrets/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('delete_removes_a_secret_so_read_no_longer_reports_it', async () => {
            const written = await client.postJson('/api/secrets/write', { key: 'api_key_cohere', value: 'to-delete', label: 'p8-delete' });
            const { id } = await written.json();

            const deleted = await client.postJson('/api/secrets/delete', { key: 'api_key_cohere', id });
            expect(deleted.status).toBe(204);

            const state = await client.postJson('/api/secrets/read', {});
            expect((await state.json()).api_key_cohere).toBeNull();
        }, CASE_TIMEOUT_MS);

        test('rotate_missing_fields_is_rejected', async () => {
            const response = await client.postJson('/api/secrets/rotate', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('rotate_activates_a_previously_inactive_secret', async () => {
            const first = await client.postJson('/api/secrets/write', { key: 'api_key_groq', value: 'first-value', label: 'p8-first' });
            const { id: firstId } = await first.json();
            const second = await client.postJson('/api/secrets/write', { key: 'api_key_groq', value: 'second-value', label: 'p8-second' });
            const { id: secondId } = await second.json();
            expect(firstId).not.toBe(secondId);

            const beforeRotate = await client.postJson('/api/secrets/read', {});
            const activeBefore = (await beforeRotate.json()).api_key_groq.find(secret => secret.active);
            expect(activeBefore.id).toBe(secondId);

            const rotated = await client.postJson('/api/secrets/rotate', { key: 'api_key_groq', id: firstId });
            expect(rotated.status).toBe(204);

            const afterRotate = await client.postJson('/api/secrets/read', {});
            const activeAfter = (await afterRotate.json()).api_key_groq.find(secret => secret.active);
            expect(activeAfter.id).toBe(firstId);
        }, CASE_TIMEOUT_MS);

        test('rename_missing_fields_is_rejected', async () => {
            const response = await client.postJson('/api/secrets/rename', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('rename_updates_the_label_of_a_stored_secret', async () => {
            const written = await client.postJson('/api/secrets/write', { key: 'api_key_perplexity', value: 'renamed-secret', label: 'p8-old-label' });
            const { id } = await written.json();

            const renamed = await client.postJson('/api/secrets/rename', { key: 'api_key_perplexity', id, label: 'p8-new-label' });
            expect(renamed.status).toBe(204);

            const state = await client.postJson('/api/secrets/read', {});
            const entry = (await state.json()).api_key_perplexity.find(secret => secret.id === id);
            expect(entry.label).toBe('p8-new-label');
        }, CASE_TIMEOUT_MS);

        test('settings_returns_the_allow_keys_exposure_flag', async () => {
            const response = await client.postJson('/api/secrets/settings', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ allowKeysExposure: false });
        }, CASE_TIMEOUT_MS);
    });

    describe('backups', () => {
        const backupFileName = 'chat_p8_test_backup.jsonl';
        const deleteTargetFileName = 'chat_p8_delete_target.jsonl';

        function writeChatBackupFile(fileName, content) {
            const backupsDir = path.join(server.userDirectory(), CHAT_BACKUPS_DIR);
            fs.mkdirSync(backupsDir, { recursive: true });
            fs.writeFileSync(path.join(backupsDir, fileName), content, 'utf8');
        }

        test('chat_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backups/chat/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_get_lists_a_backup_file_placed_in_the_backups_directory', async () => {
            writeChatBackupFile(backupFileName, JSON.stringify({ name: 'You', is_user: true, mes: 'p8-backup-marker' }));

            const response = await client.postJson('/api/backups/chat/get', {});
            expect(response.status).toBe(200);
            const entry = (await response.json()).find(backup => backup.file_name === backupFileName);
            expect(entry).toBeDefined();
        }, CASE_TIMEOUT_MS);

        test('chat_download_streams_the_backup_file_content', async () => {
            const response = await client.postJson('/api/backups/chat/download', { name: backupFileName });
            expect(response.status).toBe(200);
            const expected = fs.readFileSync(path.join(server.userDirectory(), CHAT_BACKUPS_DIR, backupFileName), 'utf8');
            expect(await response.text()).toBe(expected);
        }, CASE_TIMEOUT_MS);

        test('chat_download_rejects_a_filename_without_the_chat_backup_prefix', async () => {
            const response = await client.postJson('/api/backups/chat/download', { name: 'not-a-backup.txt' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('chat_download_with_a_path_traversal_attempt_is_rejected_not_crashed', async () => {
            const response = await client.postJson('/api/backups/chat/download', { name: '../../../etc/passwd' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('chat_download_for_an_unknown_file_returns_not_found', async () => {
            const response = await client.postJson('/api/backups/chat/download', { name: 'chat_p8_does_not_exist.jsonl' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_rejects_a_filename_without_the_chat_backup_prefix', async () => {
            const response = await client.postJson('/api/backups/chat/delete', { name: 'not-a-backup.txt' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_for_an_unknown_file_returns_not_found', async () => {
            const response = await client.postJson('/api/backups/chat/delete', { name: 'chat_p8_does_not_exist.jsonl' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('chat_delete_removes_the_backup_file_from_disk', async () => {
            writeChatBackupFile(deleteTargetFileName, JSON.stringify({ name: 'You', is_user: true, mes: 'p8-delete-marker' }));
            const filePath = path.join(server.userDirectory(), CHAT_BACKUPS_DIR, deleteTargetFileName);
            expect(fs.existsSync(filePath)).toBe(true);

            const response = await client.postJson('/api/backups/chat/delete', { name: deleteTargetFileName });
            expect(response.status).toBe(200);
            expect(fs.existsSync(filePath)).toBe(false);
        }, CASE_TIMEOUT_MS);
    });
});

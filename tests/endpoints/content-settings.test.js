import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

describe('SillyTavern content, files and settings endpoints', () => {
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

    describe('content-manager', () => {
        test('content_import_url_without_a_url_is_rejected', async () => {
            const response = await client.postJson('/api/content/importURL', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('content_import_url_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/content/importURL', { url: 'https://example.com/card.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('content_import_url_with_a_non_whitelisted_host_is_not_found', async () => {
            const response = await client.postJson('/api/content/importURL', { url: 'https://not-whitelisted.example.com/card.png' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('content_import_uuid_without_a_url_is_rejected', async () => {
            const response = await client.postJson('/api/content/importUUID', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('content_import_uuid_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/content/importUUID', { url: 'some-uuid' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('files', () => {
        test('files_sanitize_filename_strips_illegal_characters', async () => {
            const response = await client.postJson('/api/files/sanitize-filename', { fileName: 'bad:name?.txt' });
            expect(response.status).toBe(200);
            expect((await response.json()).fileName).toBe('badname.txt');
        }, CASE_TIMEOUT_MS);

        test('files_sanitize_filename_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/files/sanitize-filename', { fileName: 'x.txt' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('files_sanitize_filename_with_an_empty_filename_is_rejected', async () => {
            const response = await client.postJson('/api/files/sanitize-filename', { fileName: '' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_sanitize_filename_with_a_missing_field_is_rejected', async () => {
            const response = await client.postJson('/api/files/sanitize-filename', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_upload_writes_the_file_and_returns_its_client_relative_path', async () => {
            const response = await client.postJson('/api/files/upload', {
                name: 'p8-upload.txt',
                data: Buffer.from('p8-file-marker').toString('base64'),
            });
            expect(response.status).toBe(200);
            expect((await response.json()).path).toBe('/user/files/p8-upload.txt');

            const uploadedPath = path.join(server.userDirectory(), 'user', 'files', 'p8-upload.txt');
            expect(fs.readFileSync(uploadedPath, 'utf8')).toBe('p8-file-marker');
        }, CASE_TIMEOUT_MS);

        test('files_upload_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/files/upload', { name: 'anon.txt', data: 'ZGF0YQ==' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('files_upload_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/files/upload', { data: 'ZGF0YQ==' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_upload_with_an_illegal_filename_is_rejected', async () => {
            const response = await client.postJson('/api/files/upload', { name: '../escape.txt', data: 'ZGF0YQ==' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_verify_reports_existing_and_missing_paths', async () => {
            const response = await client.postJson('/api/files/verify', {
                urls: ['/user/files/p8-upload.txt', '/user/files/does-not-exist.txt'],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({
                '/user/files/p8-upload.txt': true,
                '/user/files/does-not-exist.txt': false,
            });
        }, CASE_TIMEOUT_MS);

        test('files_verify_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/files/verify', { urls: [] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('files_verify_with_a_non_array_urls_field_is_rejected', async () => {
            const response = await client.postJson('/api/files/verify', { urls: 'not-an-array' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_delete_removes_the_uploaded_file_from_disk', async () => {
            const uploadedPath = path.join(server.userDirectory(), 'user', 'files', 'p8-upload.txt');
            expect(fs.existsSync(uploadedPath)).toBe(true);

            const response = await client.postJson('/api/files/delete', { path: '/user/files/p8-upload.txt' });
            expect(response.status).toBe(200);
            expect(fs.existsSync(uploadedPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('files_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/files/delete', { path: '/user/files/x.txt' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('files_delete_without_a_path_is_rejected', async () => {
            const response = await client.postJson('/api/files/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_delete_with_a_path_outside_the_files_directory_is_rejected', async () => {
            const response = await client.postJson('/api/files/delete', { path: '../../characters/whatever.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('files_delete_of_a_missing_file_returns_not_found', async () => {
            const response = await client.postJson('/api/files/delete', { path: '/user/files/never-existed.txt' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);
    });

    describe('assets', () => {
        test('assets_get_lists_files_present_on_disk', async () => {
            const bgmDir = path.join(server.userDirectory(), 'assets', 'bgm');
            fs.mkdirSync(bgmDir, { recursive: true });
            fs.writeFileSync(path.join(bgmDir, 'p8-track.mp3'), 'audio-marker');

            const response = await client.postJson('/api/assets/get', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.bgm).toContain('assets/bgm/p8-track.mp3');
        }, CASE_TIMEOUT_MS);

        test('assets_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/assets/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('assets_download_with_an_invalid_url_is_rejected', async () => {
            const response = await client.postJson('/api/assets/download', { url: 'not-a-url', category: 'bgm', filename: 'x.mp3' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('assets_download_with_a_non_whitelisted_host_is_not_found', async () => {
            const response = await client.postJson('/api/assets/download', { url: 'https://not-whitelisted.example.com/x.mp3', category: 'bgm', filename: 'x.mp3' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('assets_download_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/assets/download', { url: 'https://example.com/x.mp3', category: 'bgm', filename: 'x.mp3' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('assets_delete_removes_the_asset_file_from_disk', async () => {
            const assetPath = path.join(server.userDirectory(), 'assets', 'bgm', 'p8-track.mp3');
            expect(fs.existsSync(assetPath)).toBe(true);

            const response = await client.postJson('/api/assets/delete', { category: 'bgm', filename: 'p8-track.mp3' });
            expect(response.status).toBe(200);
            expect(fs.existsSync(assetPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('assets_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/assets/delete', { category: 'bgm', filename: 'p8-track.mp3' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('assets_delete_with_an_unsupported_category_is_rejected', async () => {
            const response = await client.postJson('/api/assets/delete', { category: 'not-a-category', filename: 'x.mp3' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('assets_delete_of_a_missing_asset_returns_bad_request', async () => {
            const response = await client.postJson('/api/assets/delete', { category: 'bgm', filename: 'never-existed.mp3' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('assets_character_lists_the_named_character_folder_contents', async () => {
            const blipDir = path.join(server.userDirectory(), 'characters', 'P8AssetChar', 'blip');
            fs.mkdirSync(blipDir, { recursive: true });
            fs.writeFileSync(path.join(blipDir, 'p8-blip.wav'), 'blip-marker');

            const response = await client.postJson('/api/assets/character?name=P8AssetChar&category=blip', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual(['/characters/P8AssetChar/blip/p8-blip.wav']);
        }, CASE_TIMEOUT_MS);

        test('assets_character_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/assets/character?name=P8AssetChar&category=blip', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('assets_character_without_a_name_query_param_is_rejected', async () => {
            const response = await client.postJson('/api/assets/character?category=blip', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('assets_character_with_an_unsupported_category_is_rejected', async () => {
            const response = await client.postJson('/api/assets/character?name=P8AssetChar&category=nope', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('extensions', () => {
        test('extensions_install_with_an_invalid_url_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/install', { url: 'not-a-url' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_install_with_a_non_http_protocol_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/install', { url: 'ftp://example.com/repo.git' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_install_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/install', { url: 'https://example.com/repo.git' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_update_without_an_extension_name_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/update', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_update_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/update', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_update_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/update', { extensionName: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_branches_without_an_extension_name_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/branches', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_branches_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/branches', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_branches_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/branches', { extensionName: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_switch_without_a_branch_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/switch', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_switch_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/switch', { extensionName: 'p8-does-not-exist', branch: 'main' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_switch_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/switch', { extensionName: 'x', branch: 'main' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_move_without_source_and_destination_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/move', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_move_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/move', { extensionName: 'p8-does-not-exist', source: 'local', destination: 'global' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_move_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/move', { extensionName: 'x', source: 'local', destination: 'global' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_version_without_an_extension_name_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/version', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_version_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/version', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_version_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/version', { extensionName: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_delete_without_an_extension_name_is_rejected', async () => {
            const response = await client.postJson('/api/extensions/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('extensions_delete_of_an_unknown_extension_is_not_found', async () => {
            const response = await client.postJson('/api/extensions/delete', { extensionName: 'p8-does-not-exist' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('extensions_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extensions/delete', { extensionName: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('extensions_discover_lists_available_extension_folders', async () => {
            const response = await client.get('/api/extensions/discover');
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(Array.isArray(body)).toBe(true);
            expect(body.every(entry => typeof entry.type === 'string' && typeof entry.name === 'string')).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('extensions_discover_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.get('/api/extensions/discover');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('data-maid', () => {
        /** @type {string} */
        let orphanFilePath;
        /** @type {string} */
        let token;
        /** @type {string} */
        let hash;

        test('data_maid_report_lists_an_orphaned_uploaded_file', async () => {
            const upload = await client.postJson('/api/files/upload', {
                name: 'p8-orphan.txt',
                data: Buffer.from('p8-orphan-marker').toString('base64'),
            });
            expect(upload.status).toBe(200);
            orphanFilePath = path.join(server.userDirectory(), 'user', 'files', 'p8-orphan.txt');

            const response = await client.postJson('/api/data-maid/report', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            const entry = body.report.files.find(file => file.name === 'p8-orphan.txt');
            expect(entry).toBeDefined();
            expect(typeof body.token).toBe('string');

            token = body.token;
            hash = entry.hash;
        }, CASE_TIMEOUT_MS);

        test('data_maid_report_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/data-maid/report', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_view_returns_the_file_content_for_a_valid_token_and_hash', async () => {
            const response = await client.get(`/api/data-maid/view?token=${token}&hash=${hash}`);
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('p8-orphan-marker');
        }, CASE_TIMEOUT_MS);

        test('data_maid_view_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.get(`/api/data-maid/view?token=${token}&hash=${hash}`);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_view_without_token_or_hash_is_rejected', async () => {
            const response = await client.get('/api/data-maid/view');
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('data_maid_view_with_an_unknown_token_is_forbidden', async () => {
            const response = await client.get('/api/data-maid/view?token=not-a-real-token&hash=abc');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_view_with_an_unknown_hash_is_not_found', async () => {
            const response = await client.get(`/api/data-maid/view?token=${token}&hash=not-a-real-hash`);
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('data_maid_delete_without_token_or_hashes_is_rejected', async () => {
            const response = await client.postJson('/api/data-maid/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('data_maid_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/data-maid/delete', { token, hashes: [hash] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_delete_with_an_unknown_token_is_forbidden', async () => {
            const response = await client.postJson('/api/data-maid/delete', { token: 'not-a-real-token', hashes: [hash] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_delete_removes_the_file_from_disk', async () => {
            expect(fs.existsSync(orphanFilePath)).toBe(true);

            const response = await client.postJson('/api/data-maid/delete', { token, hashes: [hash] });
            expect(response.status).toBe(204);
            expect(fs.existsSync(orphanFilePath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('data_maid_finalize_without_a_token_is_rejected', async () => {
            const response = await client.postJson('/api/data-maid/finalize', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('data_maid_finalize_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/data-maid/finalize', { token });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_finalize_with_an_unknown_token_is_forbidden', async () => {
            const response = await client.postJson('/api/data-maid/finalize', { token: 'not-a-real-token' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('data_maid_finalize_consumes_a_valid_token', async () => {
            const report = await client.postJson('/api/data-maid/report', {});
            expect(report.status).toBe(200);
            const freshToken = (await report.json()).token;

            const response = await client.postJson('/api/data-maid/finalize', { token: freshToken });
            expect(response.status).toBe(204);

            const reused = await client.postJson('/api/data-maid/finalize', { token: freshToken });
            expect(reused.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('search', () => {
        test('search_serpapi_without_a_configured_key_is_rejected', async () => {
            const response = await client.postJson('/api/search/serpapi', { query: 'p8 test' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_serpapi_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/serpapi', { query: 'p8 test' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_transcript_without_an_id_is_rejected', async () => {
            const response = await client.postJson('/api/search/transcript', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_transcript_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/transcript', { id: 'abc' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_searxng_without_a_base_url_or_query_is_rejected', async () => {
            const response = await client.postJson('/api/search/searxng', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_searxng_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/searxng', { baseUrl: 'https://example.com', query: 'x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_tavily_without_a_configured_key_is_rejected', async () => {
            const response = await client.postJson('/api/search/tavily', { query: 'p8 test' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_tavily_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/tavily', { query: 'p8 test' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_koboldcpp_without_a_url_is_rejected', async () => {
            const response = await client.postJson('/api/search/koboldcpp', { query: 'p8 test' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_koboldcpp_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/koboldcpp', { query: 'p8 test', url: 'http://127.0.0.1:1' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_serper_without_a_configured_key_is_rejected', async () => {
            const response = await client.postJson('/api/search/serper', { query: 'p8 test' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_serper_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/serper', { query: 'p8 test' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_zai_without_a_configured_key_is_rejected', async () => {
            const response = await client.postJson('/api/search/zai', { query: 'p8 test' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_zai_without_a_query_is_rejected_once_a_key_is_configured', async () => {
            const written = await client.postJson('/api/secrets/write', { key: 'api_key_zai', value: 'p8-fake-zai-key', label: 'p8' });
            expect(written.status).toBe(200);

            const response = await client.postJson('/api/search/zai', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_zai_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/zai', { query: 'p8 test' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('search_visit_without_a_url_is_rejected', async () => {
            const response = await client.postJson('/api/search/visit', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_visit_with_a_bare_ip_hostname_is_rejected', async () => {
            const response = await client.postJson('/api/search/visit', { url: 'http://127.0.0.1/' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_visit_with_a_non_http_protocol_is_rejected', async () => {
            const response = await client.postJson('/api/search/visit', { url: 'ftp://example.com/file' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('search_visit_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/search/visit', { url: 'https://example.com/' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('settings', () => {
        test('settings_save_then_get_round_trips_the_settings_blob', async () => {
            const saved = await client.postJson('/api/settings/save', { p8_marker: 'p8-settings-marker' });
            expect(saved.status).toBe(200);
            expect(await saved.json()).toEqual({ result: 'ok' });

            const fetched = await client.postJson('/api/settings/get', {});
            expect(fetched.status).toBe(200);
            const body = await fetched.json();
            expect(JSON.parse(body.settings)).toEqual({ p8_marker: 'p8-settings-marker' });
        }, CASE_TIMEOUT_MS);

        test('settings_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/settings/save', { anon: true });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('settings_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/settings/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        /** @type {string} */
        let customSnapshotName;

        test('settings_make_snapshot_then_get_snapshots_lists_the_new_backup', async () => {
            const made = await client.postJson('/api/settings/make-snapshot', {});
            expect(made.status).toBe(204);

            const listed = await client.postJson('/api/settings/get-snapshots', {});
            expect(listed.status).toBe(200);
            const snapshots = await listed.json();
            // Startup already backs up the seeded default settings, so pick the newest by date.
            expect(snapshots.length).toBeGreaterThan(0);
            const latest = snapshots.reduce((a, b) => (b.date > a.date ? b : a));
            expect(latest.name.startsWith('settings_default-user_')).toBe(true);
            customSnapshotName = latest.name;
        }, CASE_TIMEOUT_MS);

        test('settings_get_snapshots_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/settings/get-snapshots', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('settings_load_snapshot_returns_the_persisted_content', async () => {
            const response = await client.postJson('/api/settings/load-snapshot', { name: customSnapshotName });
            expect(response.status).toBe(200);
            expect(JSON.parse(await response.text())).toEqual({ p8_marker: 'p8-settings-marker' });
        }, CASE_TIMEOUT_MS);

        test('settings_load_snapshot_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/settings/load-snapshot', { name: 'settings_default-user_x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('settings_load_snapshot_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/settings/load-snapshot', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('settings_load_snapshot_with_a_name_outside_the_users_backup_prefix_is_rejected', async () => {
            const response = await client.postJson('/api/settings/load-snapshot', { name: 'settings_someone-else_20260101' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('settings_load_snapshot_with_a_path_separator_in_the_name_is_rejected', async () => {
            const response = await client.postJson('/api/settings/load-snapshot', { name: '../escape' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('settings_restore_snapshot_overwrites_the_settings_file_with_the_backup', async () => {
            const changed = await client.postJson('/api/settings/save', { p8_marker: 'p8-changed-after-snapshot' });
            expect(changed.status).toBe(200);

            const restored = await client.postJson('/api/settings/restore-snapshot', { name: customSnapshotName });
            expect(restored.status).toBe(204);

            const fetched = await client.postJson('/api/settings/get', {});
            const body = await fetched.json();
            expect(JSON.parse(body.settings)).toEqual({ p8_marker: 'p8-settings-marker' });
        }, CASE_TIMEOUT_MS);

        test('settings_restore_snapshot_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/settings/restore-snapshot', { name: 'settings_default-user_x' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('settings_restore_snapshot_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/settings/restore-snapshot', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('themes', () => {
        test('themes_save_then_delete_round_trips_the_theme_file', async () => {
            const saved = await client.postJson('/api/themes/save', { name: 'P8Theme', main_text_color: '#fff' });
            expect(saved.status).toBe(200);

            const themePath = path.join(server.userDirectory(), 'themes', 'P8Theme.json');
            expect(JSON.parse(fs.readFileSync(themePath, 'utf8')).main_text_color).toBe('#fff');

            const deleted = await client.postJson('/api/themes/delete', { name: 'P8Theme' });
            expect(deleted.status).toBe(200);
            expect(fs.existsSync(themePath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('themes_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/themes/save', { name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('themes_save_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/themes/save', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('themes_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/themes/delete', { name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('themes_delete_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/themes/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('themes_delete_of_a_missing_theme_is_not_found', async () => {
            const response = await client.postJson('/api/themes/delete', { name: 'P8NeverExisted' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);
    });

    describe('moving-ui', () => {
        test('moving_ui_save_writes_the_preset_file', async () => {
            const response = await client.postJson('/api/moving-ui/save', { name: 'P8MovingUI', someSetting: true });
            expect(response.status).toBe(200);

            const presetPath = path.join(server.userDirectory(), 'movingUI', 'P8MovingUI.json');
            expect(JSON.parse(fs.readFileSync(presetPath, 'utf8')).someSetting).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('moving_ui_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/moving-ui/save', { name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('moving_ui_save_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/moving-ui/save', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('quick-replies', () => {
        test('quick_replies_save_then_delete_round_trips_the_preset_file', async () => {
            const saved = await client.postJson('/api/quick-replies/save', { name: 'P8QuickReply', qrList: [] });
            expect(saved.status).toBe(200);

            const presetPath = path.join(server.userDirectory(), 'QuickReplies', 'P8QuickReply.json');
            expect(fs.existsSync(presetPath)).toBe(true);

            const deleted = await client.postJson('/api/quick-replies/delete', { name: 'P8QuickReply' });
            expect(deleted.status).toBe(200);
            expect(fs.existsSync(presetPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('quick_replies_save_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/quick-replies/save', { name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('quick_replies_save_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/quick-replies/save', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('quick_replies_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/quick-replies/delete', { name: 'Anon' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('quick_replies_delete_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/quick-replies/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('quick_replies_delete_of_a_missing_preset_still_returns_ok', async () => {
            const response = await client.postJson('/api/quick-replies/delete', { name: 'P8NeverExisted' });
            expect(response.status).toBe(200);
        }, CASE_TIMEOUT_MS);
    });
});

import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import { ZipArchive } from 'archiver';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { Jimp } from '../../src/jimp.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;

const TINY_PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

function tinyPngBuffer() {
    return Buffer.from(TINY_PNG_BASE64, 'base64');
}

function tinyPngBlob() {
    return new Blob([tinyPngBuffer()], { type: 'image/png' });
}

async function decodablePngBuffer(size = 1) {
    const image = new Jimp({ width: size, height: size, color: 0xff0000ff });
    return image.getBuffer('image/png');
}

async function buildSpriteZipBuffer(entryName) {
    const archive = new ZipArchive();
    const chunks = [];
    archive.on('data', chunk => chunks.push(chunk));
    const finished = new Promise((resolve, reject) => {
        archive.on('end', resolve);
        archive.on('error', reject);
    });
    archive.append(tinyPngBuffer(), { name: entryName });
    archive.finalize();
    await finished;
    return Buffer.concat(chunks);
}

describe('SillyTavern media and image endpoints', () => {
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

    describe('backgrounds', () => {
        test('background_upload_writes_file_and_returns_sanitized_filename', async () => {
            const form = new FormData();
            form.append('avatar', tinyPngBlob(), 'P8Bg1.png');

            const response = await client.postForm('/api/backgrounds/upload', form);

            expect(response.status).toBe(200);
            expect(await response.text()).toBe('P8Bg1.png');
            expect(fs.existsSync(path.join(server.userDirectory(), 'backgrounds', 'P8Bg1.png'))).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('background_upload_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const form = new FormData();
            form.append('avatar', tinyPngBlob(), 'ShouldNotExist.png');
            const response = await anonymous.postForm('/api/backgrounds/upload', form);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_all_lists_the_uploaded_background_with_metadata', async () => {
            const response = await client.postJson('/api/backgrounds/all', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.config).toEqual({ width: 160, height: 90 });
            const entry = body.images.find(image => image.filename === 'P8Bg1.png');
            expect(entry).toEqual({ filename: 'P8Bg1.png', isAnimated: false });
        }, CASE_TIMEOUT_MS);

        test('background_all_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backgrounds/all', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_folders_returns_folders_and_image_folder_map', async () => {
            const response = await client.postJson('/api/backgrounds/folders', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ folders: [], imageFolderMap: {} });
        }, CASE_TIMEOUT_MS);

        test('background_folders_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backgrounds/folders', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_rename_moves_the_file_on_disk', async () => {
            const response = await client.postJson('/api/backgrounds/rename', { old_bg: 'P8Bg1.png', new_bg: 'P8Bg1Renamed.png' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('ok');

            expect(fs.existsSync(path.join(server.userDirectory(), 'backgrounds', 'P8Bg1.png'))).toBe(false);
            expect(fs.existsSync(path.join(server.userDirectory(), 'backgrounds', 'P8Bg1Renamed.png'))).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('background_rename_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backgrounds/rename', { old_bg: 'P8Bg1Renamed.png', new_bg: 'X.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_rename_with_a_missing_source_file_is_rejected', async () => {
            const response = await client.postJson('/api/backgrounds/rename', { old_bg: 'NoSuchBg.png', new_bg: 'Whatever.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('background_delete_with_a_traversal_name_that_sanitizes_differently_is_forbidden', async () => {
            const response = await client.postJson('/api/backgrounds/delete', { bg: '..' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_delete_with_a_path_separator_is_rejected_as_bad_input', async () => {
            const response = await client.postJson('/api/backgrounds/delete', { bg: 'a/b.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('background_delete_removes_the_file_from_disk', async () => {
            const bgPath = path.join(server.userDirectory(), 'backgrounds', 'P8Bg1Renamed.png');
            expect(fs.existsSync(bgPath)).toBe(true);

            const response = await client.postJson('/api/backgrounds/delete', { bg: 'P8Bg1Renamed.png' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('ok');
            expect(fs.existsSync(bgPath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('background_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backgrounds/delete', { bg: 'P8Bg1Renamed.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('background_delete_of_a_nonexistent_file_is_rejected', async () => {
            const response = await client.postJson('/api/backgrounds/delete', { bg: 'NoSuchBg.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('images', () => {
        let uploadedImagePath;

        test('image_upload_base64_writes_file_under_character_subfolder_and_returns_client_relative_path', async () => {
            const response = await client.postJson('/api/images/upload', {
                image: tinyPngBuffer().toString('base64'),
                format: 'png',
                filename: 'p8-image',
                ch_name: 'P8ImgChar',
            });

            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.path).toBe('/user/images/P8ImgChar/p8-image.png');
            uploadedImagePath = body.path;

            const onDisk = path.join(server.userDirectory(), 'user', 'images', 'P8ImgChar', 'p8-image.png');
            expect(fs.existsSync(onDisk)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('image_upload_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/images/upload', { image: tinyPngBuffer().toString('base64'), format: 'png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('image_upload_without_image_data_is_rejected', async () => {
            const response = await client.postJson('/api/images/upload', { format: 'png' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'No image data provided' });
        }, CASE_TIMEOUT_MS);

        test('image_upload_with_an_invalid_format_is_rejected', async () => {
            const response = await client.postJson('/api/images/upload', { image: tinyPngBuffer().toString('base64'), format: 'exe' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Invalid image format' });
        }, CASE_TIMEOUT_MS);

        test('image_list_returns_the_uploaded_image_for_its_folder', async () => {
            const response = await client.postJson('/api/images/list', { folder: 'P8ImgChar' });
            expect(response.status).toBe(200);
            expect(await response.json()).toContain('p8-image.png');
        }, CASE_TIMEOUT_MS);

        test('image_list_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/images/list', { folder: 'P8ImgChar' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('image_list_without_a_folder_is_rejected', async () => {
            const response = await client.postJson('/api/images/list', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'No folder specified' });
        }, CASE_TIMEOUT_MS);

        test('image_folders_lists_the_character_subfolder', async () => {
            const response = await client.postJson('/api/images/folders', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toContain('P8ImgChar');
        }, CASE_TIMEOUT_MS);

        test('image_folders_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/images/folders', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('image_delete_without_a_path_is_rejected', async () => {
            const response = await client.postJson('/api/images/delete', {});
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('No path specified');
        }, CASE_TIMEOUT_MS);

        test('image_delete_with_a_path_outside_user_images_is_rejected', async () => {
            const response = await client.postJson('/api/images/delete', { path: '/characters/escape.png' });
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Invalid path');
        }, CASE_TIMEOUT_MS);

        test('image_delete_of_a_missing_file_returns_404', async () => {
            const response = await client.postJson('/api/images/delete', { path: '/user/images/P8ImgChar/does-not-exist.png' });
            expect(response.status).toBe(404);
            expect(await response.text()).toBe('File not found');
        }, CASE_TIMEOUT_MS);

        test('image_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/images/delete', { path: uploadedImagePath });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('image_delete_removes_the_uploaded_image_from_disk', async () => {
            const onDisk = path.join(server.userDirectory(), 'user', 'images', 'P8ImgChar', 'p8-image.png');
            expect(fs.existsSync(onDisk)).toBe(true);

            const response = await client.postJson('/api/images/delete', { path: uploadedImagePath });
            expect(response.status).toBe(200);
            expect(fs.existsSync(onDisk)).toBe(false);
        }, CASE_TIMEOUT_MS);
    });

    describe('sprites', () => {
        test('sprite_upload_writes_file_under_character_sprites_folder', async () => {
            const form = new FormData();
            form.append('name', 'P8SpriteChar');
            form.append('label', 'joy');
            form.append('avatar', tinyPngBlob(), 'joy-source.png');

            const response = await client.postForm('/api/sprites/upload', form);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });
            expect(fs.existsSync(path.join(server.userDirectory(), 'characters', 'P8SpriteChar', 'joy.png'))).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('sprite_upload_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const form = new FormData();
            form.append('name', 'P8SpriteChar');
            form.append('label', 'sad');
            form.append('avatar', tinyPngBlob(), 'sad-source.png');
            const response = await anonymous.postForm('/api/sprites/upload', form);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('sprite_upload_without_a_label_is_rejected', async () => {
            const form = new FormData();
            form.append('name', 'P8SpriteChar');
            form.append('avatar', tinyPngBlob(), 'nolabel.png');
            const response = await client.postForm('/api/sprites/upload', form);
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('sprite_get_lists_the_uploaded_sprite_with_derived_label', async () => {
            const response = await client.get('/api/sprites/get?name=P8SpriteChar');
            expect(response.status).toBe(200);
            const sprites = await response.json();
            expect(sprites).toHaveLength(1);
            expect(sprites[0].label).toBe('joy');
            expect(sprites[0].path.startsWith('/characters/P8SpriteChar/joy.png')).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('sprite_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.get('/api/sprites/get?name=P8SpriteChar');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('sprite_get_for_an_unknown_character_returns_an_empty_list', async () => {
            const response = await client.get('/api/sprites/get?name=P8NoSuchSpriteChar');
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual([]);
        }, CASE_TIMEOUT_MS);

        test('sprite_delete_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/sprites/delete', { label: 'joy' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('sprite_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/sprites/delete', { name: 'P8SpriteChar', label: 'joy' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('sprite_delete_removes_the_matching_sprite_file', async () => {
            const spritePath = path.join(server.userDirectory(), 'characters', 'P8SpriteChar', 'joy.png');
            expect(fs.existsSync(spritePath)).toBe(true);

            const response = await client.postJson('/api/sprites/delete', { name: 'P8SpriteChar', label: 'joy' });
            expect(response.status).toBe(200);
            expect(fs.existsSync(spritePath)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('sprite_upload_zip_without_a_file_is_rejected', async () => {
            const form = new FormData();
            form.append('name', 'P8SpriteZipChar');
            const response = await client.postForm('/api/sprites/upload-zip', form);
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('sprite_upload_zip_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const zipBuffer = await buildSpriteZipBuffer('wave.png');
            const form = new FormData();
            form.append('name', 'P8SpriteZipChar');
            form.append('avatar', new Blob([zipBuffer], { type: 'application/zip' }), 'sprites.zip');
            const response = await anonymous.postForm('/api/sprites/upload-zip', form);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('sprite_upload_zip_extracts_images_into_the_sprites_folder', async () => {
            const zipBuffer = await buildSpriteZipBuffer('wave.png');
            const form = new FormData();
            form.append('name', 'P8SpriteZipChar');
            form.append('avatar', new Blob([zipBuffer], { type: 'application/zip' }), 'sprites.zip');

            const response = await client.postForm('/api/sprites/upload-zip', form);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true, count: 1 });
            expect(fs.existsSync(path.join(server.userDirectory(), 'characters', 'P8SpriteZipChar', 'wave.png'))).toBe(true);
        }, CASE_TIMEOUT_MS);
    });

    describe('avatars', () => {
        beforeAll(() => {
            const avatarsDir = path.join(server.userDirectory(), 'User Avatars');
            fs.mkdirSync(avatarsDir, { recursive: true });
            fs.writeFileSync(path.join(avatarsDir, 'P8AvatarSeed.png'), tinyPngBuffer());
        });

        test('avatar_upload_of_a_png_succeeds_and_the_stored_file_decodes_back_to_the_source_dimensions', async () => {
            const sourceBuffer = await decodablePngBuffer(1);
            const form = new FormData();
            form.append('overwrite_name', 'P8Avatar.png');
            form.append('avatar', new Blob([sourceBuffer], { type: 'image/png' }), 'source.png');

            const response = await client.postForm('/api/avatars/upload', form);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ path: 'P8Avatar.png' });

            const avatarPath = path.join(server.userDirectory(), 'User Avatars', 'P8Avatar.png');
            expect(fs.existsSync(avatarPath)).toBe(true);

            const decoded = await Jimp.read(avatarPath);
            expect(decoded.bitmap.width).toBe(1);
            expect(decoded.bitmap.height).toBe(1);

            const listed = await client.postJson('/api/avatars/get', {});
            expect(await listed.json()).toContain('P8Avatar.png');
        }, CASE_TIMEOUT_MS);

        test('avatar_upload_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const form = new FormData();
            form.append('avatar', tinyPngBlob(), 'anon.png');
            const response = await anonymous.postForm('/api/avatars/upload', form);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('avatar_upload_without_a_file_is_rejected', async () => {
            const response = await client.postJson('/api/avatars/upload', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('avatar_upload_with_a_path_separator_in_overwrite_name_is_rejected_as_bad_input', async () => {
            const response = await client.postJson('/api/avatars/upload', { overwrite_name: 'a/b.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('avatar_get_lists_a_seeded_avatar_file', async () => {
            const response = await client.postJson('/api/avatars/get', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toContain('P8AvatarSeed.png');
        }, CASE_TIMEOUT_MS);

        test('avatar_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/avatars/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('avatar_delete_without_the_avatar_field_is_rejected', async () => {
            const response = await client.postJson('/api/avatars/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('avatar_delete_with_a_path_separator_is_rejected_as_bad_input', async () => {
            const response = await client.postJson('/api/avatars/delete', { avatar: 'a/b.png' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('avatar_delete_of_a_missing_file_returns_404', async () => {
            const response = await client.postJson('/api/avatars/delete', { avatar: 'NoSuchAvatar.png' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('avatar_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/avatars/delete', { avatar: 'P8AvatarSeed.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('avatar_delete_removes_the_file_from_disk', async () => {
            const avatarPath = path.join(server.userDirectory(), 'User Avatars', 'P8AvatarSeed.png');
            expect(fs.existsSync(avatarPath)).toBe(true);

            const response = await client.postJson('/api/avatars/delete', { avatar: 'P8AvatarSeed.png' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ result: 'ok' });
            expect(fs.existsSync(avatarPath)).toBe(false);
        }, CASE_TIMEOUT_MS);
    });

    describe('thumbnails', () => {
        let thumbBgSourceBuffer;

        beforeAll(async () => {
            const backgroundsDir = path.join(server.userDirectory(), 'backgrounds');
            fs.mkdirSync(backgroundsDir, { recursive: true });
            thumbBgSourceBuffer = await decodablePngBuffer(1);
            fs.writeFileSync(path.join(backgroundsDir, 'P8ThumbBg.png'), thumbBgSourceBuffer);
        });

        test('thumbnail_get_for_a_png_background_generates_a_resized_thumbnail_via_the_working_jimp_codec', async () => {
            const response = await client.get('/thumbnail?type=bg&file=P8ThumbBg.png');
            expect(response.status).toBe(200);
            expect(response.headers.get('content-type')).toMatch(/^image\//);

            const body = Buffer.from(await response.arrayBuffer());
            expect(body).not.toEqual(thumbBgSourceBuffer);

            const thumbPath = path.join(server.userDirectory(), 'thumbnails', 'bg', 'P8ThumbBg.png');
            expect(fs.existsSync(thumbPath)).toBe(true);

            const decoded = await Jimp.read(thumbPath);
            expect(decoded.bitmap.width).toBe(120);
            expect(decoded.bitmap.height).toBe(120);
        }, CASE_TIMEOUT_MS);

        test('thumbnail_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.get('/thumbnail?type=bg&file=P8ThumbBg.png');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('thumbnail_get_without_required_query_params_is_rejected', async () => {
            const response = await client.get('/thumbnail?type=bg');
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('thumbnail_get_with_an_invalid_type_is_rejected', async () => {
            const response = await client.get('/thumbnail?type=nope&file=P8ThumbBg.png');
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('thumbnail_get_with_a_traversal_filename_is_forbidden', async () => {
            const response = await client.get('/thumbnail?type=bg&file=..');
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('thumbnail_get_for_a_missing_file_returns_404', async () => {
            const response = await client.get('/thumbnail?type=bg&file=NoSuchThumbBg.png');
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);
    });

    describe('image-metadata', () => {
        let folderId;

        beforeAll(() => {
            const backgroundsDir = path.join(server.userDirectory(), 'backgrounds');
            fs.mkdirSync(backgroundsDir, { recursive: true });
            fs.writeFileSync(path.join(backgroundsDir, 'P8MetaBg.png'), tinyPngBuffer());
        });

        test('metadata_folders_create_writes_a_new_folder_and_returns_it', async () => {
            const response = await client.postJson('/api/image-metadata/folders/create', { name: 'P8Folder' });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.name).toBe('P8Folder');
            expect(body.thumbnailFile).toBe('');
            expect(body.id).toEqual(expect.any(String));
            folderId = body.id;
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_create_without_a_name_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/folders/create', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: '"name" is required.' });
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_create_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/create', { name: 'ShouldNotExist' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_get_lists_the_created_folder', async () => {
            const response = await client.postJson('/api/image-metadata/folders/get', {});
            expect(response.status).toBe(200);
            const folders = await response.json();
            expect(folders.find(folder => folder.id === folderId)).toBeDefined();
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/get', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_update_renames_the_folder', async () => {
            const response = await client.postJson('/api/image-metadata/folders/update', { id: folderId, name: 'P8FolderRenamed' });
            expect(response.status).toBe(200);
            expect((await response.json()).name).toBe('P8FolderRenamed');
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_update_without_an_id_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/folders/update', { name: 'X' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_update_for_an_unknown_id_returns_404', async () => {
            const response = await client.postJson('/api/image-metadata/folders/update', { id: 'no-such-id', name: 'X' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_update_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/update', { id: folderId, name: 'X' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_set_thumbnails_batch_updates_the_thumbnail_file', async () => {
            const response = await client.postJson('/api/image-metadata/folders/set-thumbnails', {
                updates: [{ id: folderId, thumbnailFile: 'P8MetaBg.png' }],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const listed = await client.postJson('/api/image-metadata/folders/get', {});
            const folder = (await listed.json()).find(f => f.id === folderId);
            expect(folder.thumbnailFile).toBe('P8MetaBg.png');
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_set_thumbnails_with_a_non_array_body_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/folders/set-thumbnails', { updates: {} });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_set_thumbnails_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/set-thumbnails', { updates: [] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_assign_adds_the_folder_id_to_the_background_image', async () => {
            const response = await client.postJson('/api/image-metadata/folders/assign', {
                id: folderId,
                paths: ['backgrounds/P8MetaBg.png'],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const metadata = await client.postJson('/api/image-metadata/', { path: 'backgrounds/P8MetaBg.png' });
            expect((await metadata.json()).folderIds).toContain(folderId);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_assign_without_a_paths_array_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/folders/assign', { id: folderId });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_assign_with_a_traversal_path_is_handled_as_a_server_error', async () => {
            const response = await client.postJson('/api/image-metadata/folders/assign', {
                id: folderId,
                paths: ['../../etc/passwd'],
            });
            expect(response.status).toBe(500);
            expect(await response.json()).toEqual({ error: 'Internal server error.' });
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_assign_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/assign', { id: folderId, paths: [] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_get_by_path_returns_generated_metadata_for_the_background', async () => {
            const response = await client.postJson('/api/image-metadata/', { path: 'backgrounds/P8MetaBg.png', type: 'bg' });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.hash).toEqual(expect.any(String));
            expect(body.aspectRatio).toBe(1);
            expect(body.isAnimated).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('metadata_get_without_a_path_or_paths_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Either "path" or "paths" is required.' });
        }, CASE_TIMEOUT_MS);

        test('metadata_get_for_a_missing_file_returns_404', async () => {
            const response = await client.postJson('/api/image-metadata/', { path: 'backgrounds/DoesNotExist.png' });
            expect(response.status).toBe(404);
        }, CASE_TIMEOUT_MS);

        test('metadata_get_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/', { path: 'backgrounds/P8MetaBg.png' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_unassign_removes_the_folder_id_from_the_image', async () => {
            const response = await client.postJson('/api/image-metadata/folders/unassign', {
                id: folderId,
                paths: ['backgrounds/P8MetaBg.png'],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const metadata = await client.postJson('/api/image-metadata/', { path: 'backgrounds/P8MetaBg.png' });
            expect((await metadata.json()).folderIds).not.toContain(folderId);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_unassign_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/unassign', { id: folderId, paths: [] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_all_returns_the_index_including_the_background_entry', async () => {
            const response = await client.postJson('/api/image-metadata/all', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.images['backgrounds/P8MetaBg.png']).toBeDefined();
        }, CASE_TIMEOUT_MS);

        test('metadata_all_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/all', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_cleanup_reports_zero_removed_entries_when_nothing_is_orphaned', async () => {
            const response = await client.postJson('/api/image-metadata/cleanup', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ removed: [], count: 0 });
        }, CASE_TIMEOUT_MS);

        test('metadata_cleanup_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/cleanup', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_delete_without_an_id_is_rejected', async () => {
            const response = await client.postJson('/api/image-metadata/folders/delete', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/image-metadata/folders/delete', { id: folderId });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('metadata_folders_delete_removes_the_folder', async () => {
            const response = await client.postJson('/api/image-metadata/folders/delete', { id: folderId });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ok: true });

            const listed = await client.postJson('/api/image-metadata/folders/get', {});
            expect((await listed.json()).find(folder => folder.id === folderId)).toBeUndefined();
        }, CASE_TIMEOUT_MS);
    });

    describe('stable-diffusion (contract only, no live SD backend)', () => {
        const SD_ROUTES = [
            'ping', 'upscalers', 'vaes', 'samplers', 'schedulers',
            'models', 'get-model', 'set-model', 'generate', 'sd-next/upscalers',
        ];

        test.each(SD_ROUTES)('sd_%s_is_rejected_for_anonymous_client', async (route) => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson(`/api/sd/${route}`, {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test.each(SD_ROUTES)('sd_%s_without_a_url_is_handled_as_a_server_error_not_a_crash', async (route) => {
            const body = route === 'set-model' ? { model: 'some-model' } : {};
            const response = await client.postJson(`/api/sd/${route}`, body);
            expect(response.status).toBe(500);
        }, CASE_TIMEOUT_MS);

        test('sd_ping_with_an_unreachable_backend_url_returns_a_handled_server_error', async () => {
            const response = await client.postJson('/api/sd/ping', { url: 'http://127.0.0.1:1/' });
            expect(response.status).toBe(500);
        }, CASE_TIMEOUT_MS);
    });

    describe('caption (contract only, no local captioning model)', () => {
        test('caption_without_image_data_is_rejected_without_invoking_the_model', async () => {
            const response = await client.postJson('/api/extra/caption', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('caption_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extra/caption', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });
});

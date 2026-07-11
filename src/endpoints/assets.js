import path from 'node:path';
import fs from 'node:fs';
import { finished } from 'node:stream/promises';

import mime from 'mime-types';
import express from 'express';
import sanitize from 'sanitize-filename';
import fetch from 'node-fetch';

import { UNSAFE_EXTENSIONS } from '../constants.js';
import { clientRelativePath, isValidUrl } from '../util.js';
import { getHostFromUrl, isHostWhitelisted } from './content-manager.js';
import { log } from '../log.js';

const VALID_CATEGORIES = ['bgm', 'ambient', 'blip', 'live2d', 'vrm', 'character', 'temp'];

/**
 * Validates the input filename for the asset.
 * @param {string} inputFilename Input filename
 * @returns {{error: boolean, message?: string}} Whether validation failed, and why if so
 */
export function validateAssetFileName(inputFilename) {
    if (!/^[a-zA-Z0-9_\-.]+$/.test(inputFilename)) {
        return {
            error: true,
            message: 'Illegal character in filename; only alphanumeric, \'_\', \'-\' are accepted.',
        };
    }

    const inputExtension = path.extname(inputFilename).toLowerCase();
    if (UNSAFE_EXTENSIONS.some(ext => ext === inputExtension)) {
        return {
            error: true,
            message: 'Forbidden file extension.',
        };
    }

    if (inputFilename.startsWith('.')) {
        return {
            error: true,
            message: 'Filename cannot start with \'.\'',
        };
    }

    if (sanitize(inputFilename) !== inputFilename) {
        return {
            error: true,
            message: 'Reserved or long filename.',
        };
    }

    return { error: false };
}

/**
 * Recursive function to get files
 * @param {string} dir - The directory to search for files
 * @param {string[]} files - The array of files to return
 * @returns {Promise<string[]>} - The array of files
 */
async function getFiles(dir, files = []) {
    /** @type {import('node:fs').Dirent[]} */
    let fileList;
    try {
        fileList = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch {
        return files;
    }
    for (const file of fileList) {
        const name = path.join(dir, file.name);
        if (file.isDirectory()) {
            await getFiles(name, files);
        } else {
            files.push(name);
        }
    }
    return files;
}

/**
 * Ensure that the asset folders exist.
 * @param {import('../users.js').UserDirectoryList} directories - The user's directories
 */
async function ensureFoldersExist(directories) {
    const folderPath = path.join(directories.assets);

    for (const category of VALID_CATEGORIES) {
        const assetCategoryPath = path.join(folderPath, category);
        const stat = await fs.promises.stat(assetCategoryPath).catch(() => null);
        if (stat && !stat.isDirectory()) {
            await fs.promises.unlink(assetCategoryPath);
        }
        if (!stat || !stat.isDirectory()) {
            await fs.promises.mkdir(assetCategoryPath, { recursive: true });
        }
    }
}

export const router = express.Router();

/**
 * HTTP POST handler function to retrieve name of all files of a given folder path.
 *
 * @param {Object} request - HTTP Request object. Require folder path in query
 * @param {Object} response - HTTP Response object will contain a list of file path.
 *
 * @returns {void}
 */
router.post('/get', async (request, response) => {
    const folderPath = path.join(request.user.directories.assets);
    let output = {};

    try {
        const rootStat = await fs.promises.stat(folderPath).catch(() => null);
        if (rootStat && rootStat.isDirectory()) {
            await ensureFoldersExist(request.user.directories);

            const folders = (await fs.promises.readdir(folderPath, { withFileTypes: true }))
                .filter(file => file.isDirectory());

            for (const { name: folder } of folders) {
                if (folder == 'temp')
                    continue;

                // Live2d assets
                if (folder == 'live2d') {
                    output[folder] = [];
                    const live2d_folder = path.normalize(path.join(folderPath, folder));
                    const files = await getFiles(live2d_folder);
                    for (let file of files) {
                        if (file.includes('model') && file.endsWith('.json')) {
                            output[folder].push(clientRelativePath(request.user.directories.root, file));
                        }
                    }
                    continue;
                }

                // VRM assets
                if (folder == 'vrm') {
                    output[folder] = { 'model': [], 'animation': [] };
                    // Extract models
                    const vrm_model_folder = path.normalize(path.join(folderPath, 'vrm', 'model'));
                    let files = await getFiles(vrm_model_folder);
                    for (let file of files) {
                        if (!file.endsWith('.placeholder')) {
                            output.vrm.model.push(clientRelativePath(request.user.directories.root, file));
                        }
                    }

                    // Extract models
                    const vrm_animation_folder = path.normalize(path.join(folderPath, 'vrm', 'animation'));
                    files = await getFiles(vrm_animation_folder);
                    for (let file of files) {
                        if (!file.endsWith('.placeholder')) {
                            output.vrm.animation.push(clientRelativePath(request.user.directories.root, file));
                        }
                    }
                    continue;
                }

                // Other assets (bgm/ambient/blip)
                const files = (await fs.promises.readdir(path.join(folderPath, folder)))
                    .filter(filename => {
                        return filename != '.placeholder';
                    });
                output[folder] = [];
                for (const file of files) {
                    output[folder].push(`assets/${folder}/${file}`);
                }
            }
        }
    } catch (err) {
        log.content.error(err);
    }
    return response.send(output);
});

/**
 * HTTP POST handler function to download the requested asset.
 *
 * @param {Object} request - HTTP Request object, expects a url, a category and a filename.
 * @param {Object} response - HTTP Response only gives status.
 *
 * @returns {void}
 */
router.post('/download', async (request, response) => {
    try {
        if (!isValidUrl(request.body.url)) {
            log.content.warn('Asset download failed: Must be a valid URL');
            return response.sendStatus(400);
        }

        const url = String(request.body.url);
        const inputCategory = request.body.category;

        const host = getHostFromUrl(url);
        if (!isHostWhitelisted(host)) {
            log.content.error(`Received an import for "${host}", but site is not whitelisted. This domain must be added to the config key "whitelistImportDomains" to allow import from this source.`);
            return response.sendStatus(404);
        }

        // Check category
        let category = null;
        for (let i of VALID_CATEGORIES)
            if (i == inputCategory)
                category = i;

        if (category === null) {
            log.content.error('Bad request: unsupported asset category.');
            return response.sendStatus(400);
        }

        // Validate filename
        await ensureFoldersExist(request.user.directories);
        const validation = validateAssetFileName(request.body.filename);
        if (validation.error)
            return response.status(400).send(validation.message);

        const temp_path = path.join(request.user.directories.assets, 'temp', request.body.filename);
        const file_path = path.join(request.user.directories.assets, category, request.body.filename);
        log.content.info('Request received to download', url, 'to', file_path);

        // Download to temp
        const res = await fetch(url);
        if (!res.ok || res.body === null) {
            throw new Error(`Unexpected response ${res.statusText}`);
        }
        const destination = path.resolve(temp_path);
        // Delete if previous download failed
        await fs.promises.rm(temp_path, { force: true });
        const fileStream = fs.createWriteStream(destination, { flags: 'wx' });
        // @ts-ignore
        await finished(res.body.pipe(fileStream));

        if (category === 'character') {
            const fileContent = await fs.promises.readFile(temp_path);
            const contentType = mime.lookup(temp_path) || 'application/octet-stream';
            response.setHeader('Content-Type', contentType);
            response.send(fileContent);
            await fs.promises.unlink(temp_path);
            return;
        }

        // Move into asset place
        log.content.info('Download finished, moving file from', temp_path, 'to', file_path);
        await fs.promises.copyFile(temp_path, file_path);
        await fs.promises.unlink(temp_path);
        response.sendStatus(200);
    } catch (error) {
        log.content.error(error);
        response.sendStatus(500);
    }
});

/**
 * HTTP POST handler function to delete the requested asset.
 *
 * @param {Object} request - HTTP Request object, expects a category and a filename
 * @param {Object} response - HTTP Response only gives stats.
 *
 * @returns {void}
 */
router.post('/delete', async (request, response) => {
    const inputCategory = request.body.category;

    // Check category
    let category = null;
    for (let i of VALID_CATEGORIES)
        if (i == inputCategory)
            category = i;

    if (category === null) {
        log.content.error('Bad request: unsupported asset category.');
        return response.sendStatus(400);
    }

    // Validate filename
    const validation = validateAssetFileName(request.body.filename);
    if (validation.error)
        return response.status(400).send(validation.message);

    const file_path = path.join(request.user.directories.assets, category, request.body.filename);
    log.content.info('Request received to delete', category, file_path);

    try {
        await fs.promises.unlink(file_path);
        log.content.info('Asset deleted.');
        return response.sendStatus(200);
    } catch (error) {
        if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
            log.content.error('Asset not found.');
            return response.sendStatus(404);
        }
        log.content.error(error);
        return response.sendStatus(500);
    }
});

///////////////////////////////
/**
 * HTTP POST handler function to retrieve a character background music list.
 *
 * @param {Object} request - HTTP Request object, expects a character name in the query.
 * @param {Object} response - HTTP Response object will contain a list of audio file path.
 *
 * @returns {void}
 */
router.post('/character', async (request, response) => {
    if (request.query.name === undefined) return response.sendStatus(400);

    // For backwards compatibility, don't reject invalid character names, just sanitize them
    const name = sanitize(request.query.name.toString());
    const inputCategory = request.query.category;

    // Check category
    let category = null;
    for (let i of VALID_CATEGORIES)
        if (i == inputCategory)
            category = i;

    if (category === null) {
        log.content.error('Bad request: unsupported asset category.');
        return response.sendStatus(400);
    }

    const folderPath = path.join(request.user.directories.characters, name, category);

    let output = [];
    try {
        const folderStat = await fs.promises.stat(folderPath).catch(() => null);
        if (folderStat && folderStat.isDirectory()) {
            // Live2d assets
            if (category == 'live2d') {
                const folders = await fs.promises.readdir(folderPath, { withFileTypes: true });
                for (const folderInfo of folders) {
                    if (!folderInfo.isDirectory()) continue;

                    const modelFolder = folderInfo.name;
                    const live2dModelPath = path.join(folderPath, modelFolder);
                    for (let file of await fs.promises.readdir(live2dModelPath)) {
                        if (file.includes('model') && file.endsWith('.json'))
                            output.push(path.join('characters', name, category, modelFolder, file));
                    }
                }
                return response.send(output);
            }

            // Other assets
            const files = (await fs.promises.readdir(folderPath))
                .filter(filename => {
                    return filename != '.placeholder';
                });

            for (let i of files)
                output.push(`/characters/${name}/${category}/${i}`);
        }
        return response.send(output);
    } catch (err) {
        log.content.error(err);
        return response.sendStatus(500);
    }
});

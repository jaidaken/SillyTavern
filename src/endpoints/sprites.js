import fs from 'node:fs';
import path from 'node:path';

import express from 'express';
import mime from 'mime-types';
import sanitize from 'sanitize-filename';
import writeFileAtomic from 'write-file-atomic';

import { getImageBuffers } from '../util.js';
import { log } from '../log.js';

/**
 * Gets the path to the sprites folder for the provided character name
 * @param {import('../users.js').UserDirectoryList} directories - User directories
 * @param {string} name - The name of the character
 * @param {boolean} isSubfolder - Whether the name contains a subfolder
 * @returns {string | null} The path to the sprites folder. Null if the name is invalid.
 */
function getSpritesPath(directories, name, isSubfolder) {
    if (isSubfolder) {
        const nameParts = name.split('/');
        const characterName = sanitize(nameParts[0]);
        const subfolderName = sanitize(nameParts[1]);

        if (!characterName || !subfolderName) {
            return null;
        }

        return path.join(directories.characters, characterName, subfolderName);
    }

    name = sanitize(name);

    if (!name) {
        return null;
    }

    return path.join(directories.characters, name);
}

/**
 * Imports base64 encoded sprites from RisuAI character data.
 * The sprites are saved in the character's sprites folder.
 * The additionalAssets and emotions are removed from the data.
 * @param {import('../users.js').UserDirectoryList} directories User directories
 * @param {object} data RisuAI character data
 * @returns {Promise<void>}
 */
export async function importRisuSprites(directories, data) {
    try {
        const name = data?.data?.name;
        const risuData = data?.data?.extensions?.risuai;

        // Not a Risu AI character
        if (!risuData || !name) {
            return;
        }

        let images = [];

        if (Array.isArray(risuData.additionalAssets)) {
            images = images.concat(risuData.additionalAssets);
        }

        if (Array.isArray(risuData.emotions)) {
            images = images.concat(risuData.emotions);
        }

        // No sprites to import
        if (images.length === 0) {
            return;
        }

        // Create sprites folder if it doesn't exist
        const spritesPath = getSpritesPath(directories, name, false);

        // Invalid sprites path
        if (!spritesPath) {
            return;
        }

        const stats = await fs.promises.stat(spritesPath).catch(() => null);
        if (!stats) {
            await fs.promises.mkdir(spritesPath, { recursive: true });
        } else if (!stats.isDirectory()) {
            return;
        }

        log.media.info(`RisuAI: Found ${images.length} sprites for ${name}. Writing to disk.`);
        const files = await fs.promises.readdir(spritesPath);

        outer: for (const [label, fileBase64] of images) {
            // Remove existing sprite with the same label
            for (const file of files) {
                if (path.parse(file).name === label) {
                    log.media.warn(`RisuAI: The sprite ${label} for ${name} already exists. Skipping.`);
                    continue outer;
                }
            }

            const filename = label + '.png';
            const pathToFile = path.join(spritesPath, sanitize(filename));
            await writeFileAtomic(pathToFile, fileBase64, { encoding: 'base64' });
        }

        // Remove additionalAssets and emotions from data (they are now in the sprites folder)
        delete data.data.extensions.risuai.additionalAssets;
        delete data.data.extensions.risuai.emotions;
    } catch (error) {
        log.media.error(error);
    }
}

export const router = express.Router();

router.get('/get', async function (request, response) {
    const name = String(request.query.name);
    const isSubfolder = name.includes('/');
    const spritesPath = getSpritesPath(request.user.directories, name, isSubfolder);
    let sprites = [];

    try {
        const spritesStat = spritesPath ? await fs.promises.stat(spritesPath).catch(() => null) : null;
        if (spritesPath && spritesStat && spritesStat.isDirectory()) {
            const files = (await fs.promises.readdir(spritesPath))
                .filter(file => {
                    const mimeType = mime.lookup(file);
                    return mimeType && mimeType.startsWith('image/');
                });
            const result = [];
            for (const file of files) {
                const pathToSprite = path.join(spritesPath, file);
                const mtime = (await fs.promises.stat(pathToSprite)).mtime?.toISOString().replace(/[^0-9]/g, '').slice(0, 14);

                const fileName = path.parse(pathToSprite).name.toLowerCase();
                // Extract the label from the filename via regex, which can be suffixed with a sub-name, either connected with a dash or a dot.
                // Examples: joy.png, joy-1.png, joy.expressive.png
                const label = fileName.match(/^(.+?)(?:[-\\.].*?)?$/)?.[1] ?? fileName;

                result.push({
                    label: label,
                    path: `/characters/${name}/${file}` + (mtime ? `?t=${mtime}` : ''),
                });
            }
            sprites = result;
        }
    } catch (err) {
        log.media.error(err);
    }
    return response.send(sprites);
});

router.post('/delete', async (request, response) => {
    if (!request.body.name) {
        return response.sendStatus(400);
    }

    const label = request.body.label;
    const name = String(request.body.name);
    const isSubfolder = name.includes('/');
    const spriteName = request.body.spriteName || label;

    if (!spriteName || !name) {
        return response.sendStatus(400);
    }

    try {
        const spritesPath = getSpritesPath(request.user.directories, name, isSubfolder);

        // No sprites folder exists, or not a directory
        const spritesStat = spritesPath ? await fs.promises.stat(spritesPath).catch(() => null) : null;
        if (!spritesPath || !spritesStat || !spritesStat.isDirectory()) {
            return response.sendStatus(404);
        }

        const files = await fs.promises.readdir(spritesPath);

        // Remove existing sprite with the same label
        for (const file of files) {
            if (path.parse(file).name === spriteName) {
                await fs.promises.unlink(path.join(spritesPath, file));
            }
        }

        return response.sendStatus(200);
    } catch (error) {
        log.media.error(error);
        return response.sendStatus(500);
    }
});

router.post('/upload-zip', async (request, response) => {
    const file = request.file;
    const name = String(request.body.name);
    const isSubfolder = name.includes('/');

    if (!file || !name) {
        return response.sendStatus(400);
    }

    try {
        const spritesPath = getSpritesPath(request.user.directories, name, isSubfolder);

        // Invalid sprites path
        if (!spritesPath) {
            return response.sendStatus(400);
        }

        // Create sprites folder if it doesn't exist
        if (!(await fs.promises.stat(spritesPath).catch(() => null))) {
            await fs.promises.mkdir(spritesPath, { recursive: true });
        }

        // Path to sprites is not a directory. This should never happen.
        if (!(await fs.promises.stat(spritesPath)).isDirectory()) {
            return response.sendStatus(404);
        }

        const spritePackPath = path.join(file.destination, file.filename);
        const sprites = await getImageBuffers(spritePackPath);
        const files = await fs.promises.readdir(spritesPath);

        for (const [filename, buffer] of sprites) {
            // Remove existing sprite with the same label
            const existingFile = files.find(file => path.parse(file).name === path.parse(filename).name);

            if (existingFile) {
                await fs.promises.unlink(path.join(spritesPath, existingFile));
            }

            // Write sprite buffer to disk
            const pathToSprite = path.join(spritesPath, sanitize(filename));
            await writeFileAtomic(pathToSprite, buffer);
        }

        // Remove uploaded ZIP file
        await fs.promises.unlink(spritePackPath);
        return response.send({ ok: true, count: sprites.length });
    } catch (error) {
        log.media.error(error);
        return response.sendStatus(500);
    }
});

router.post('/upload', async (request, response) => {
    const file = request.file;
    const label = request.body.label;
    const name = String(request.body.name);
    const isSubfolder = name.includes('/');
    const spriteName = request.body.spriteName || label;

    if (!file || !label || !name) {
        return response.sendStatus(400);
    }

    try {
        const spritesPath = getSpritesPath(request.user.directories, name, isSubfolder);

        // Invalid sprites path
        if (!spritesPath) {
            return response.sendStatus(400);
        }

        // Create sprites folder if it doesn't exist
        if (!(await fs.promises.stat(spritesPath).catch(() => null))) {
            await fs.promises.mkdir(spritesPath, { recursive: true });
        }

        // Path to sprites is not a directory. This should never happen.
        if (!(await fs.promises.stat(spritesPath)).isDirectory()) {
            return response.sendStatus(404);
        }

        const files = await fs.promises.readdir(spritesPath);

        // Remove existing sprite with the same label
        for (const file of files) {
            if (path.parse(file).name === spriteName) {
                await fs.promises.unlink(path.join(spritesPath, file));
            }
        }

        const filename = spriteName + path.parse(file.originalname).ext;
        const spritePath = path.join(file.destination, file.filename);
        const pathToFile = path.join(spritesPath, sanitize(filename));
        // Copy uploaded file to sprites folder
        await fs.promises.cp(spritePath, pathToFile);
        // Remove uploaded file
        await fs.promises.unlink(spritePath);
        return response.send({ ok: true });
    } catch (error) {
        log.media.error(error);
        return response.sendStatus(500);
    }
});

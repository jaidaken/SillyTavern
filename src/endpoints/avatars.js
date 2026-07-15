import path from 'node:path';
import fs from 'node:fs';

import express from 'express';
import sanitize from 'sanitize-filename';
import writeFileAtomic from 'write-file-atomic';

import { getImages, tryParse } from '../util.js';
import { getFileNameValidationFunction } from '../middleware/validateFileName.js';
import { runAvatarCropResize } from './characters.js';
import { invalidateThumbnail } from './thumbnails.js';
import cacheBuster from '../middleware/cacheBuster.js';
import { log } from '../log.js';

export const router = express.Router();

router.post('/get', async function (request, response) {
    const images = await getImages(request.user.directories.avatars);
    response.send(images);
});

router.post('/delete', getFileNameValidationFunction('avatar'), async function (request, response) {
    if (!request.body) return response.sendStatus(400);
    if (!request.body.avatar) return response.sendStatus(400);

    if (request.body.avatar !== sanitize(request.body.avatar)) {
        log.media.error('Malicious avatar name prevented');
        return response.sendStatus(403);
    }

    const fileName = path.join(request.user.directories.avatars, sanitize(request.body.avatar));

    try {
        await fs.promises.unlink(fileName);
    } catch (error) {
        if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
            return response.sendStatus(404);
        }
        throw error;
    }

    await invalidateThumbnail(request.user.directories, 'persona', sanitize(request.body.avatar));
    return response.send({ result: 'ok' });
});

router.post('/upload', getFileNameValidationFunction('overwrite_name'), async (request, response) => {
    if (!request.file) return response.sendStatus(400);

    try {
        const pathToUpload = path.join(request.file.destination, request.file.filename);
        const crop = tryParse(request.query.crop);
        const uploadBuffer = await fs.promises.readFile(pathToUpload);
        const image = await runAvatarCropResize(uploadBuffer, crop);

        // Remove previous thumbnail and bust cache if overwriting
        if (request.body.overwrite_name) {
            await invalidateThumbnail(request.user.directories, 'persona', sanitize(request.body.overwrite_name));
            cacheBuster.bust(request, response);
        }

        const filename = sanitize(request.body.overwrite_name || `${Date.now()}.png`);
        const pathToNewFile = path.join(request.user.directories.avatars, filename);
        await writeFileAtomic(pathToNewFile, image);
        await fs.promises.unlink(pathToUpload);
        return response.send({ path: filename });
    } catch (err) {
        log.media.error('Error uploading user avatar:', err);
        return response.status(400).send('Is not a valid image');
    }
});

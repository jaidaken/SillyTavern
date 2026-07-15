import path from 'node:path';
import fs from 'node:fs';

import express from 'express';
import sanitize from 'sanitize-filename';
import writeFileAtomic from 'write-file-atomic';
import { log } from '../log.js';
import { bustSettingsCache } from './settings.js';

export const router = express.Router();

router.post('/save', async (request, response) => {
    if (!request.body || !request.body.name) {
        return response.sendStatus(400);
    }

    const filename = path.join(request.user.directories.themes, sanitize(`${request.body.name}.json`));
    await writeFileAtomic(filename, JSON.stringify(request.body, null, 4), 'utf8');
    bustSettingsCache(request.user.profile.handle);

    return response.sendStatus(200);
});

router.post('/delete', async (request, response) => {
    if (!request.body || !request.body.name) {
        return response.sendStatus(400);
    }

    try {
        const filename = path.join(request.user.directories.themes, sanitize(`${request.body.name}.json`));
        try {
            await fs.promises.unlink(filename);
        } catch (error) {
            if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
                log.settings.error('Theme file not found:', filename);
                return response.sendStatus(404);
            }
            throw error;
        }
        bustSettingsCache(request.user.profile.handle);
        return response.sendStatus(200);
    } catch (error) {
        log.settings.error(error);
        return response.sendStatus(500);
    }
});

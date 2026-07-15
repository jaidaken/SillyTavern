import path from 'node:path';
import express from 'express';
import sanitize from 'sanitize-filename';
import writeFileAtomic from 'write-file-atomic';
import { bustSettingsCache } from './settings.js';

export const router = express.Router();

router.post('/save', async (request, response) => {
    if (!request.body || !request.body.name) {
        return response.sendStatus(400);
    }

    const filename = path.join(request.user.directories.movingUI, sanitize(`${request.body.name}.json`));
    await writeFileAtomic(filename, JSON.stringify(request.body, null, 4), 'utf8');
    bustSettingsCache(request.user.profile.handle);

    return response.sendStatus(200);
});

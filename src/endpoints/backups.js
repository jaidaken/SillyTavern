import express from 'express';
import { promises as fsPromises } from 'node:fs';
import path from 'node:path';
import sanitize from 'sanitize-filename';
import { CHAT_BACKUPS_PREFIX, getChatInfo } from './chats.js';
import { log } from '../log.js';

export const router = express.Router();

router.post('/chat/get', async (request, response) => {
    try {
        const backupModels = [];
        const backupFiles = await fsPromises
            .readdir(request.user.directories.backups, { withFileTypes: true })
            .then(d => d.filter(d => d.isFile() && path.extname(d.name) === '.jsonl' && d.name.startsWith(CHAT_BACKUPS_PREFIX)).map(d => d.name));

        for (const name of backupFiles) {
            const filePath = path.join(request.user.directories.backups, name);
            const info = await getChatInfo(filePath);
            if (!info || !info.file_name) {
                continue;
            }
            backupModels.push(info);
        }

        return response.json(backupModels);
    } catch (error) {
        log.content.error(error);
        return response.sendStatus(500);
    }
});

router.post('/chat/delete', async (request, response) => {
    try {
        const { name } = request.body;
        const filePath = path.join(request.user.directories.backups, sanitize(name));

        if (!path.parse(filePath).base.startsWith(CHAT_BACKUPS_PREFIX)) {
            log.content.warn('Attempt to delete non-chat backup file:', name);
            return response.sendStatus(400);
        }

        try {
            await fsPromises.unlink(filePath);
        } catch (error) {
            if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
                return response.sendStatus(404);
            }
            throw error;
        }
        return response.sendStatus(200);
    } catch (error) {
        log.content.error(error);
        return response.sendStatus(500);
    }
});

router.post('/chat/download', async (request, response) => {
    try {
        const { name } = request.body;
        const filePath = path.join(request.user.directories.backups, sanitize(name));

        if (!path.parse(filePath).base.startsWith(CHAT_BACKUPS_PREFIX)) {
            log.content.warn('Attempt to download non-chat backup file:', name);
            return response.sendStatus(400);
        }

        const fileStat = await fsPromises.stat(filePath).catch(() => null);
        if (!fileStat) {
            return response.sendStatus(404);
        }

        return response.download(filePath);
    } catch (error) {
        log.content.error(error);
        return response.sendStatus(500);
    }
});

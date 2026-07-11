import fs from 'node:fs';
import path from 'node:path';

import express from 'express';
import sanitize from 'sanitize-filename';

import { invalidateThumbnail } from './thumbnails.js';
import { thumbnailDimensions, readMetadataIndex, renameMetadata, removeMetadata, getOrGenerateMetadataBatch } from './image-metadata.js';
import { getImages } from '../util.js';
import { getFileNameValidationFunction } from '../middleware/validateFileName.js';
import { log } from '../log.js';

export const router = express.Router();

router.post('/all', async function (request, response) {
    try {
        const images = await getImages(request.user.directories.backgrounds);
        const config = { width: thumbnailDimensions.bg[0], height: thumbnailDimensions.bg[1] };

        // Get metadata for all images to provide isAnimated flag to client
        const relativePaths = images.map(img => path.join('backgrounds', img));
        const { results: metadataMap } = await getOrGenerateMetadataBatch(request.user.directories.root, relativePaths, 'bg');

        // Build response with metadata for each image
        const imagesWithMetadata = images.map(img => {
            const relativePath = path.join('backgrounds', img);
            const metadata = metadataMap[relativePath];
            return {
                filename: img,
                isAnimated: metadata?.isAnimated ?? false,
            };
        });

        response.json({ images: imagesWithMetadata, config });
    } catch (error) {
        log.media.error('[Backgrounds] Error fetching backgrounds:', error);
        response.status(500).json({ error: 'Failed to fetch backgrounds' });
    }
});

/**
 * POST /api/backgrounds/folders
 * Returns folders and per-image folderIds from the metadata index.
 * Loaded separately from /all to avoid blocking image rendering.
 */
router.post('/folders', async function (request, response) {
    try {
        const index = await readMetadataIndex(request.user.directories.root);
        const folders = index.folders || [];

        // Build a slim map of image → folderIds for the frontend
        /** @type {Object.<string, string[]>} */
        const imageFolderMap = {};
        for (const [relativePath, meta] of Object.entries(index.images)) {
            if (Array.isArray(meta.folderIds) && meta.folderIds.length > 0) {
                // Strip the directory prefix to get just the filename
                const filename = relativePath.split('/').pop() || relativePath;
                imageFolderMap[filename] = meta.folderIds;
            }
        }

        response.json({ folders, imageFolderMap });
    } catch (error) {
        log.media.error('[Backgrounds] Folders endpoint error:', error);
        response.status(500).json({ error: 'Internal server error.' });
    }
});

router.post('/delete', getFileNameValidationFunction('bg'), async function (request, response) {
    try {
        if (!request.body) return response.sendStatus(400);

        if (request.body.bg !== sanitize(request.body.bg)) {
            log.media.error('Malicious bg name prevented');
            return response.sendStatus(403);
        }

        const fileName = path.join(request.user.directories.backgrounds, sanitize(request.body.bg));

        try {
            await fs.promises.unlink(fileName);
        } catch (error) {
            if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
                log.media.error('BG file not found');
                return response.sendStatus(400);
            }
            throw error;
        }
        await invalidateThumbnail(request.user.directories, 'bg', request.body.bg);

        // Remove metadata for deleted image
        const relativePath = path.join('backgrounds', request.body.bg);
        await removeMetadata(request.user.directories.root, relativePath).catch(err => {
            log.media.warn('[Backgrounds] Failed to remove metadata:', err.message);
        });

        return response.send('ok');
    } catch (err) {
        log.media.error(err);
        response.sendStatus(500);
    }
});

router.post('/rename', async function (request, response) {
    try {
        if (!request.body) return response.sendStatus(400);

        const oldFileName = path.join(request.user.directories.backgrounds, sanitize(request.body.old_bg));
        const newFileName = path.join(request.user.directories.backgrounds, sanitize(request.body.new_bg));

        if (!(await fs.promises.stat(oldFileName).catch(() => null))) {
            log.media.error('BG file not found');
            return response.sendStatus(400);
        }

        if (await fs.promises.stat(newFileName).catch(() => null)) {
            log.media.error('New BG file already exists');
            return response.sendStatus(400);
        }

        await fs.promises.copyFile(oldFileName, newFileName);
        await fs.promises.unlink(oldFileName);
        await invalidateThumbnail(request.user.directories, 'bg', request.body.old_bg);

        // Update metadata for renamed image
        const oldRelativePath = path.join('backgrounds', request.body.old_bg);
        const newRelativePath = path.join('backgrounds', request.body.new_bg);
        await renameMetadata(request.user.directories.root, oldRelativePath, newRelativePath).catch(err => {
            log.media.warn('[Backgrounds] Failed to rename metadata:', err.message);
        });

        return response.send('ok');
    } catch (err) {
        log.media.error(err);
        response.sendStatus(500);
    }
});

router.post('/upload', async function (request, response) {
    try {
        if (!request.body || !request.file) return response.sendStatus(400);

        const img_path = path.join(request.file.destination, request.file.filename);
        const filename = sanitize(request.file.originalname);
        await fs.promises.copyFile(img_path, path.join(request.user.directories.backgrounds, filename));
        await fs.promises.unlink(img_path);
        await invalidateThumbnail(request.user.directories, 'bg', filename);

        // Generate metadata for the new image
        const relativePath = path.join('backgrounds', filename);
        await getOrGenerateMetadataBatch(request.user.directories.root, [relativePath], 'bg').catch(err => {
            log.media.warn('[Backgrounds] Failed to generate metadata for upload:', err.message);
        });

        response.send(filename);
    } catch (err) {
        log.media.error(err);
        response.sendStatus(500);
    }
});

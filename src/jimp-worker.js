import { parentPort } from 'node:worker_threads';

import { Jimp, JimpMime } from './jimp.js';
import { ResizeStrategy } from '@jimp/plugin-resize';

// Importing jimp.js above loads the WASM codecs + installs the file:// fetch shim inside this thread.

/**
 * Generates a thumbnail from a decoded image. Mirrors thumbnails.js processSingleImage.
 * @param {any} task
 * @param {any} image
 * @returns {Promise<{buffer: Buffer, aspectRatio: number, thumbRatio: number}>}
 */
async function handleThumbnail(task, image) {
    const originalWidth = image.bitmap.width;
    const originalHeight = image.bitmap.height;
    const aspectRatio = (originalHeight > 0) ? (originalWidth / originalHeight) : 1.0;

    if (task.type === 'bg') {
        const thumbWidth = Math.round(Math.sqrt(task.targetPixelArea * aspectRatio));
        const thumbHeight = Math.round(Math.sqrt(task.targetPixelArea / aspectRatio));
        image.resize({ w: thumbWidth, h: thumbHeight, mode: ResizeStrategy.BILINEAR });
    } else {
        image.cover({ w: task.coverWidth, h: task.coverHeight });
    }

    const thumbRatio = (image.bitmap.height > 0) ? (image.bitmap.width / image.bitmap.height) : 1.0;
    const buffer = task.pngFormat
        ? await image.getBuffer(JimpMime.png)
        : await image.getBuffer(JimpMime.jpeg, { quality: task.quality, jpegColorSpace: 'ycbcr' });

    return { buffer, aspectRatio, thumbRatio };
}

/**
 * Crops/resizes an avatar from a decoded image. Mirrors characters.js applyAvatarCropResize.
 * @param {any} task
 * @param {any} image
 * @returns {Promise<{buffer: Buffer}>}
 */
async function handleAvatar(task, image) {
    let finalWidth = image.bitmap.width, finalHeight = image.bitmap.height;
    const crop = task.crop;

    if (typeof crop == 'object' && crop && [crop.x, crop.y, crop.width, crop.height].every(x => typeof x === 'number')) {
        image.crop({ x: crop.x, y: crop.y, w: crop.width, h: crop.height });
        if (crop.want_resize) {
            finalWidth = task.avatarWidth;
            finalHeight = task.avatarHeight;
        } else {
            finalWidth = crop.width;
            finalHeight = crop.height;
        }
    }

    image.cover({ w: finalWidth, h: finalHeight });
    const buffer = await image.getBuffer(JimpMime.png);
    return { buffer };
}

if (!parentPort) {
    throw new Error('jimp-worker.js must be run as a worker thread');
}
const port = parentPort;

port.on('message', async (msg) => {
    try {
        const input = Buffer.from(msg.buffer.buffer, msg.buffer.byteOffset, msg.buffer.byteLength);
        const image = await Jimp.fromBuffer(input);
        const result = msg.task.op === 'avatar'
            ? await handleAvatar(msg.task, image)
            : await handleThumbnail(msg.task, image);

        // getBuffer may return a pooled Buffer; copy into a fresh, fully-owned array before transferring.
        const out = new Uint8Array(result.buffer.byteLength);
        out.set(result.buffer);
        port.postMessage({ id: msg.id, result: { ...result, buffer: out } }, [out.buffer]);
    } catch (error) {
        port.postMessage({ id: msg.id, error: error instanceof Error ? error.message : String(error) });
    }
});

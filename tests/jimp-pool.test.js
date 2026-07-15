import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { Jimp, JimpMime } from '../src/jimp.js';
import { ResizeStrategy } from '@jimp/plugin-resize';
import { AVATAR_WIDTH, AVATAR_HEIGHT } from '../src/constants.js';
import { setConfigFilePath } from '../src/util.js';
import * as jimpPool from '../src/jimp-pool.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// characters.js reads config at module load; set the path before importing it for the golden.
setConfigFilePath(path.join(repoRoot, 'default', 'config.yaml'));

/**
 * Builds a deterministic RGBA gradient PNG so resize/encode produce non-trivial bytes.
 * @param {number} width
 * @param {number} height
 * @returns {Promise<Buffer>}
 */
async function makeFixturePng(width, height) {
    const img = new Jimp({ width, height, color: 0x000000ff });
    const data = img.bitmap.data;
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const i = (y * width + x) * 4;
            data[i] = (x * 255 / width) | 0;
            data[i + 1] = (y * 255 / height) | 0;
            data[i + 2] = ((x + y) * 255 / (width + height)) | 0;
            data[i + 3] = 255;
        }
    }
    return await img.getBuffer(JimpMime.png);
}

describe('jimp worker pool', () => {
    /** @type {typeof import('../src/endpoints/characters.js').applyAvatarCropResize} */
    let applyAvatarCropResize;

    beforeAll(async () => {
        ({ applyAvatarCropResize } = await import('../src/endpoints/characters.js'));
    });

    afterAll(async () => {
        await jimpPool.destroy();
    });

    test('avatar op output matches the in-process applyAvatarCropResize bytes', async () => {
        const fixture = await makeFixturePng(100, 80);
        const crop = { x: 10, y: 10, width: 60, height: 40, want_resize: true };

        const golden = await applyAvatarCropResize(await Jimp.fromBuffer(fixture), crop);
        const { buffer } = await jimpPool.run({ op: 'avatar', crop, avatarWidth: AVATAR_WIDTH, avatarHeight: AVATAR_HEIGHT }, fixture);

        expect(Buffer.from(buffer)).toEqual(golden);
    });

    test('thumbnail bg op output matches the same in-process jimp ops', async () => {
        const fixture = await makeFixturePng(300, 200);
        const targetPixelArea = 160 * 90;

        const source = await Jimp.fromBuffer(fixture);
        const aspectRatio = source.bitmap.width / source.bitmap.height;
        const thumbWidth = Math.round(Math.sqrt(targetPixelArea * aspectRatio));
        const thumbHeight = Math.round(Math.sqrt(targetPixelArea / aspectRatio));
        source.resize({ w: thumbWidth, h: thumbHeight, mode: ResizeStrategy.BILINEAR });
        const golden = await source.getBuffer(JimpMime.jpeg, { quality: 95, jpegColorSpace: 'ycbcr' });

        const result = await jimpPool.run({ op: 'thumbnail', type: 'bg', targetPixelArea, pngFormat: false, quality: 95 }, fixture);

        expect(Buffer.from(result.buffer)).toEqual(golden);
        expect(result.aspectRatio).toBeCloseTo(1.5, 10);
        expect(result.thumbRatio).toBeCloseTo(thumbWidth / thumbHeight, 10);
    });

    test('a worker actually decodes, resizes, and re-encodes a valid png', async () => {
        const fixture = await makeFixturePng(40, 30);
        const { buffer } = await jimpPool.run({ op: 'thumbnail', type: 'avatar', coverWidth: 96, coverHeight: 144, pngFormat: true, quality: 95 }, fixture);

        // Output dims differ from the 40x30 input, so this is a genuine decode+resize+encode, not a passthrough.
        const decoded = await Jimp.fromBuffer(Buffer.from(buffer));
        expect(decoded.bitmap.width).toBe(96);
        expect(decoded.bitmap.height).toBe(144);
    });

    test('a large image does not serialize a concurrent small request', async () => {
        const large = await makeFixturePng(2400, 2400);
        const small = await makeFixturePng(8, 8);
        const order = [];

        const largeTask = jimpPool.run({ op: 'thumbnail', type: 'bg', targetPixelArea: 2400 * 2400, pngFormat: true, quality: 95 }, large)
            .then(() => order.push('large'));
        const smallTask = jimpPool.run({ op: 'thumbnail', type: 'avatar', coverWidth: 96, coverHeight: 144, pngFormat: true, quality: 95 }, small)
            .then(() => order.push('small'));

        await Promise.all([largeTask, smallTask]);

        expect(order[0]).toBe('small');
    });
});

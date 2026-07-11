import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test, expect, beforeAll, afterAll, jest } from '@jest/globals';
import { setConfigFilePath } from '../src/util.js';

// uuid 13 is ESM-only; jest's CJS loader cannot require(ESM) on node <24.9, so shim vectra's uuid dep.
jest.mock('uuid', () => ({ v4: () => crypto.randomUUID() }));

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Module-top config reads in the SUTs exit the process without a config path; set it before importing them.
setConfigFilePath(path.join(repoRoot, 'default', 'config.yaml'));

describe('vectra index cache', () => {
    /** @type {import('../src/endpoints/vectors.js')} */
    let vectors;
    /** @type {import('vectra')} */
    let vectra;
    let tmpDir;
    let directories;
    const settings = { model: '' };

    beforeAll(async () => {
        vectors = await import('../src/endpoints/vectors.js');
        vectra = await import('vectra');
        tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'st-perf-vectors-'));
        directories = /** @type {any} */ ({ vectors: tmpDir });
    });

    afterAll(async () => {
        if (tmpDir) {
            await fs.promises.rm(tmpDir, { recursive: true, force: true });
        }
    });

    test('getIndex returns the same instance for repeated calls on one collection', async () => {
        const first = await vectors.getIndex(directories, 'col-same', 'transformers', settings);
        const second = await vectors.getIndex(directories, 'col-same', 'transformers', settings);
        expect(second).toBe(first);
        expect(await first.isIndexCreated()).toBe(true);
    });

    test('evictVectorIndexes forgets an exact collection path (purge route shape)', async () => {
        const before = await vectors.getIndex(directories, 'col-evict', 'transformers', settings);
        vectors.evictVectorIndexes(path.join(tmpDir, 'transformers', 'col-evict'));
        const after = await vectors.getIndex(directories, 'col-evict', 'transformers', settings);
        expect(after).not.toBe(before);
        expect(await after.isIndexCreated()).toBe(true);
    });

    test('evictVectorIndexes prefix-evicts every collection under a source (purge-all shape)', async () => {
        const beforeA = await vectors.getIndex(directories, 'col-pre-a', 'transformers', settings);
        const beforeB = await vectors.getIndex(directories, 'col-pre-b', 'transformers', settings);
        vectors.evictVectorIndexes(path.join(tmpDir, 'transformers'));
        expect(await vectors.getIndex(directories, 'col-pre-a', 'transformers', settings)).not.toBe(beforeA);
        expect(await vectors.getIndex(directories, 'col-pre-b', 'transformers', settings)).not.toBe(beforeB);
    });

    test('cache caps at 32 entries and evicts the oldest', async () => {
        const oldest = await vectors.getIndex(directories, 'lru-0', 'transformers', settings);
        let newest = null;
        for (let i = 1; i <= 32; i++) {
            newest = await vectors.getIndex(directories, `lru-${i}`, 'transformers', settings);
        }
        expect(await vectors.getIndex(directories, 'lru-32', 'transformers', settings)).toBe(newest);
        expect(await vectors.getIndex(directories, 'lru-0', 'transformers', settings)).not.toBe(oldest);
    });

    test('getIndex migrates legacy numeric hashes to strings on first load', async () => {
        const indexPath = path.join(tmpDir, 'transformers', 'col-legacy');
        const legacy = new vectra.LocalIndex(indexPath);
        await legacy.createIndex();
        await legacy.insertItem({ vector: [1, 0, 0], metadata: { hash: 42, text: 'x', index: 0 } });

        const store = await vectors.getIndex(directories, 'col-legacy', 'transformers', settings);
        const items = await store.listItems();
        expect(items).toHaveLength(1);
        expect(items[0].metadata.hash).toBe('42');
    });
});

describe('thumbnail aspect-ratio cache', () => {
    /** @type {import('../src/endpoints/thumbnails.js')} */
    let thumbnails;
    let tmpDir;
    let thumbDir;
    let originalDir;
    let directories;
    const oldTime = new Date(Date.now() - 600000);

    // Signature + IHDR is all image-size reads; CRC and pixel data are never touched.
    function pngHeader(width, height) {
        const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
        const ihdr = Buffer.alloc(25);
        ihdr.writeUInt32BE(13, 0);
        ihdr.write('IHDR', 4);
        ihdr.writeUInt32BE(width, 8);
        ihdr.writeUInt32BE(height, 12);
        ihdr.writeUInt8(8, 16);
        ihdr.writeUInt8(6, 17);
        return Buffer.concat([signature, ihdr]);
    }

    async function placeFiles(name, thumbBuffer, thumbMtime) {
        const originalPath = path.join(originalDir, name);
        const thumbPath = path.join(thumbDir, name);
        await fs.promises.writeFile(originalPath, pngHeader(8, 8));
        await fs.promises.utimes(originalPath, oldTime, oldTime);
        await fs.promises.writeFile(thumbPath, thumbBuffer);
        await fs.promises.utimes(thumbPath, thumbMtime, thumbMtime);
        return thumbPath;
    }

    beforeAll(async () => {
        thumbnails = await import('../src/endpoints/thumbnails.js');
        tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'st-perf-thumbs-'));
        thumbDir = path.join(tmpDir, 'thumbnails-bg');
        originalDir = path.join(tmpDir, 'backgrounds');
        await fs.promises.mkdir(thumbDir, { recursive: true });
        await fs.promises.mkdir(originalDir, { recursive: true });
        directories = /** @type {any} */ ({ thumbnailsBg: thumbDir, backgrounds: originalDir });
    });

    afterAll(async () => {
        if (tmpDir) {
            await fs.promises.rm(tmpDir, { recursive: true, force: true });
        }
    });

    test('second hit serves the cached ratio without re-reading the thumbnail file', async () => {
        const mtime = new Date(Date.now() - 5000);
        const thumbPath = await placeFiles('skip.png', pngHeader(4, 2), mtime);
        const spy = jest.spyOn(fs.promises, 'readFile');
        try {
            const first = await thumbnails.generateThumbnail(directories, 'bg', 'skip.png');
            expect(first.path).toBe(thumbPath);
            expect(first.aspectRatio).toBe(2);
            const readsAfterFirst = spy.mock.calls.filter(([p]) => p === thumbPath).length;
            expect(readsAfterFirst).toBe(1);

            const second = await thumbnails.generateThumbnail(directories, 'bg', 'skip.png');
            expect(second.path).toBe(thumbPath);
            expect(second.aspectRatio).toBe(2);
            expect(spy.mock.calls.filter(([p]) => p === thumbPath).length).toBe(readsAfterFirst);
        } finally {
            spy.mockRestore();
        }
    });

    test('mtime change refreshes the cached ratio from the new file bytes', async () => {
        const thumbPath = await placeFiles('stale.png', pngHeader(4, 2), new Date(Date.now() - 5000));
        expect((await thumbnails.generateThumbnail(directories, 'bg', 'stale.png')).aspectRatio).toBe(2);

        await fs.promises.writeFile(thumbPath, pngHeader(3, 1));
        await fs.promises.utimes(thumbPath, new Date(), new Date());
        expect((await thumbnails.generateThumbnail(directories, 'bg', 'stale.png')).aspectRatio).toBe(3);
    });

    test('invalidateThumbnail deletes the file and evicts the cache entry', async () => {
        const mtime = new Date(Date.now() - 5000);
        const thumbPath = await placeFiles('evict.png', pngHeader(4, 2), mtime);
        expect((await thumbnails.generateThumbnail(directories, 'bg', 'evict.png')).aspectRatio).toBe(2);

        await thumbnails.invalidateThumbnail(directories, 'bg', 'evict.png');
        expect(await fs.promises.stat(thumbPath).catch(() => null)).toBeNull();

        // Recreate with identical mtime: only eviction can explain a fresh read of the new ratio.
        await fs.promises.writeFile(thumbPath, pngHeader(5, 1));
        await fs.promises.utimes(thumbPath, mtime, mtime);
        expect((await thumbnails.generateThumbnail(directories, 'bg', 'evict.png')).aspectRatio).toBe(5);
    });
});

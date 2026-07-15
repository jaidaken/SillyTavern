import { Worker } from 'node:worker_threads';

// A hand-rolled worker pool that runs jimp decode/encode off the event loop.
// Each worker loads the WASM codecs + the file:// fetch shim per-thread (see jimp-worker.js).

const WORKER_URL = new URL('./jimp-worker.js', import.meta.url);
const POOL_SIZE = 2;

/** @typedef {{ worker: Worker, inFlight: Map<number, {resolve: (v: any) => void, reject: (e: Error) => void}> }} PoolEntry */

/** @type {PoolEntry[] | null} */
let workers = null;
let nextTaskId = 1;

/**
 * Spawns one pool worker and wires message/exit handling.
 * @returns {PoolEntry}
 */
function makeWorker() {
    const worker = new Worker(WORKER_URL);
    /** @type {PoolEntry} */
    const entry = { worker, inFlight: new Map() };

    worker.on('message', (msg) => {
        const pending = entry.inFlight.get(msg.id);
        if (!pending) return;
        entry.inFlight.delete(msg.id);
        if (msg.error) {
            pending.reject(new Error(msg.error));
        } else {
            pending.resolve(msg.result);
        }
    });

    const failAll = (err) => {
        for (const pending of entry.inFlight.values()) {
            pending.reject(err);
        }
        entry.inFlight.clear();
        // Respawn a replacement only while the pool is still active.
        if (workers) {
            const idx = workers.indexOf(entry);
            if (idx !== -1) workers[idx] = makeWorker();
        }
    };

    worker.on('error', failAll);
    worker.on('exit', (code) => {
        if (code !== 0) failAll(new Error(`jimp worker exited with code ${code}`));
    });

    return entry;
}

/**
 * @returns {PoolEntry[]}
 */
function ensurePool() {
    if (!workers) {
        workers = Array.from({ length: POOL_SIZE }, () => makeWorker());
    }
    return workers;
}

/**
 * @param {PoolEntry[]} pool
 * @returns {PoolEntry}
 */
function pickWorker(pool) {
    let best = pool[0];
    for (const entry of pool) {
        if (entry.inFlight.size < best.inFlight.size) best = entry;
    }
    return best;
}

/**
 * Zero-copy transfer only when the view owns its whole ArrayBuffer; a pooled/partial
 * view would detach shared memory on transfer, so copy those into a fresh buffer.
 * @param {Uint8Array} buffer
 * @returns {{ data: Uint8Array, transfer: ArrayBuffer[] }}
 */
function toTransferable(buffer) {
    if (buffer.byteOffset === 0 && buffer.byteLength === buffer.buffer.byteLength) {
        const arrayBuffer = /** @type {ArrayBuffer} */ (buffer.buffer);
        return { data: buffer, transfer: [arrayBuffer] };
    }
    const copy = new Uint8Array(buffer.byteLength);
    copy.set(buffer);
    return { data: copy, transfer: [copy.buffer] };
}

/**
 * Runs an image task on a pool worker, transferring the input buffer in.
 * @param {object} task Serializable task descriptor (see jimp-worker.js).
 * @param {Uint8Array} buffer Encoded source image bytes.
 * @returns {Promise<{buffer: Uint8Array, aspectRatio?: number, thumbRatio?: number}>}
 */
export function run(task, buffer) {
    const pool = ensurePool();
    const entry = pickWorker(pool);
    const id = nextTaskId++;
    return new Promise((resolve, reject) => {
        entry.inFlight.set(id, { resolve, reject });
        const { data, transfer } = toTransferable(buffer);
        entry.worker.postMessage({ id, task, buffer: data }, transfer);
    });
}

/**
 * Terminates all workers and rejects any in-flight tasks. Tests call this so the
 * process can exit; the long-lived server never needs to.
 * @returns {Promise<void>}
 */
export async function destroy() {
    if (!workers) return;
    const pool = workers;
    workers = null;
    await Promise.all(pool.map((entry) => {
        for (const pending of entry.inFlight.values()) {
            pending.reject(new Error('jimp pool destroyed'));
        }
        entry.inFlight.clear();
        return entry.worker.terminate();
    }));
}

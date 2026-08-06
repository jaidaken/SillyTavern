/**
 * Node host for the prompt-assembly wasm.
 *
 * The prompt used to be assembled in the browser, which meant a round trip back to this server for
 * every piece of it purely to count tokens. The assembly logic is pure Zig with no browser in it, so
 * it gets a second host here and the counting happens in process: `countTokens` is INJECTED rather
 * than imported, and the whole point of that injection is that no HTTP is involved. The caller hands
 * in the server's own local counter (or, in tests, a plain function).
 *
 * The module ABI is four exports plus a memory:
 *   alloc(len) -> ptr
 *   free(ptr, len)
 *   pieces(ptr, len) -> u64
 *   fit(ptr, len) -> u64
 * Both entry points take utf8 JSON at (ptr, len) and return a packed value carrying the result
 * pointer in the high 32 bits and its byte length in the low 32. The result is owned by the caller
 * and freed here after it has been copied out of wasm memory.
 */

import fs from 'node:fs';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const REQUIRED_EXPORTS = ['alloc', 'free', 'entries', 'pieces', 'fit'];

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

/** Where the built module is expected to land. Override per call while the build path is in flux. */
export const DEFAULT_WASM_PATH = fileURLToPath(new URL('./prompt.wasm', import.meta.url));

/** @type {Map<string, Promise<WebAssembly.Exports>>} */
const modules = new Map();

/** Drops every cached module so a test, or a rebuilt wasm, starts from a cold load. */
export function resetPromptWasmCache() {
    modules.clear();
}

/**
 * Loads and instantiates the prompt wasm, once per path.
 * @param {string} [wasmPath] Path to the module.
 * @returns {Promise<any>} The instance exports, ABI-checked.
 */
export function loadPromptWasm(wasmPath = DEFAULT_WASM_PATH) {
    const cached = modules.get(wasmPath);
    if (cached) {
        return cached;
    }
    const pending = instantiate(wasmPath);
    modules.set(wasmPath, pending);
    // A failed load is not cached: a rebuilt module has to be loadable on the next call.
    pending.catch(() => {
        if (modules.get(wasmPath) === pending) {
            modules.delete(wasmPath);
        }
    });
    return pending;
}

/**
 * @param {string} wasmPath Path to the module.
 * @returns {Promise<any>} The instance exports.
 */
async function instantiate(wasmPath) {
    let bytes;
    try {
        bytes = await fs.promises.readFile(wasmPath);
    } catch (/** @type {any} */ error) {
        throw new Error(`Prompt wasm could not be read at ${wasmPath}: ${error?.message ?? error}`, { cause: error });
    }
    let instance;
    try {
        ({ instance } = await WebAssembly.instantiate(bytes, {}));
    } catch (/** @type {any} */ error) {
        throw new Error(`Prompt wasm at ${wasmPath} failed to instantiate: ${error?.message ?? error}`, { cause: error });
    }
    return assertAbi(instance.exports, wasmPath);
}

/**
 * @param {any} exports Candidate module exports.
 * @param {string} source Where they came from, for the error message.
 * @returns {any} The same exports.
 */
function assertAbi(exports, source) {
    const missing = REQUIRED_EXPORTS.filter(name => typeof exports?.[name] !== 'function');
    if (typeof exports?.memory?.buffer?.byteLength !== 'number') {
        missing.push('memory');
    }
    if (missing.length > 0) {
        throw new Error(`Prompt wasm (${source}) is missing required export(s): ${missing.join(', ')}`);
    }
    return exports;
}

/**
 * Splits the packed return value into its pointer and byte length.
 * @param {unknown} packed Raw return value of pieces or fit.
 * @param {string} call Export name, for the error message.
 * @returns {{ptr: number, len: number}}
 */
function unpack(packed, call) {
    let value;
    try {
        value = BigInt(/** @type {any} */(packed)) & 0xffffffffffffffffn;
    } catch (/** @type {any} */ error) {
        throw new Error(`Prompt wasm ${call} returned a non-integer result: ${String(packed)}`, { cause: error });
    }
    return { ptr: Number(value >> 32n), len: Number(value & 0xffffffffn) };
}

/**
 * Copies a utf8 JSON result out of wasm memory. A region the memory cannot hold is a truncated read
 * and throws rather than decoding whatever happens to be adjacent.
 * @param {any} exports Module exports.
 * @param {number} ptr Result pointer.
 * @param {number} len Result byte length.
 * @param {string} call Export name, for the error message.
 * @returns {any} The parsed result.
 */
function readResult(exports, ptr, len, call) {
    const memory = new Uint8Array(exports.memory.buffer);
    if (ptr <= 0 || len <= 0 || ptr + len > memory.length) {
        throw new Error(`Prompt wasm ${call} returned an unreadable region: ptr ${ptr}, len ${len}, memory ${memory.length} bytes.`);
    }
    let text;
    try {
        text = decoder.decode(memory.subarray(ptr, ptr + len));
    } catch (/** @type {any} */ error) {
        throw new Error(`Prompt wasm ${call} returned bytes that are not valid utf8.`, { cause: error });
    }
    let parsed;
    try {
        parsed = JSON.parse(text);
    } catch (/** @type {any} */ error) {
        throw new Error(`Prompt wasm ${call} returned text that is not JSON: ${text.slice(0, 200)}`, { cause: error });
    }
    if (parsed?.error) {
        throw new Error(`Prompt wasm ${call} reported an error: ${typeof parsed.error === 'string' ? parsed.error : JSON.stringify(parsed.error)}`);
    }
    return parsed;
}

/**
 * One entry-point call: serialize the payload in, read the JSON result out, free both allocations.
 * @param {any} exports Module exports.
 * @param {string} call Export name, pieces or fit.
 * @param {object} payload Value to hand the module as utf8 JSON.
 * @returns {any} The parsed result.
 */
function callEntry(exports, call, payload) {
    const input = encoder.encode(JSON.stringify(payload));
    const inPtr = Number(exports.alloc(input.length));
    if (!Number.isInteger(inPtr) || inPtr <= 0) {
        throw new Error(`Prompt wasm alloc refused ${input.length} bytes for ${call} (returned ${String(inPtr)}).`);
    }
    try {
        const memory = new Uint8Array(exports.memory.buffer);
        if (inPtr + input.length > memory.length) {
            throw new Error(`Prompt wasm alloc returned a region outside memory for ${call}: ptr ${inPtr}, len ${input.length}, memory ${memory.length} bytes.`);
        }
        memory.set(input, inPtr);
        const { ptr, len } = unpack(exports[call](inPtr, input.length), call);
        try {
            return readResult(exports, ptr, len, call);
        } finally {
            exports.free(ptr, len);
        }
    } finally {
        exports.free(inPtr, input.length);
    }
}

/**
 * @param {any} piece One entry of the pieces array.
 * @param {number} index Its position, for the error message.
 * @returns {string} The text whose tokens are counted.
 */
function pieceText(piece, index) {
    if (typeof piece === 'string') {
        return piece;
    }
    if (typeof piece?.text === 'string') {
        return piece.text;
    }
    throw new Error(`Prompt wasm piece ${index} carries no text to count: ${JSON.stringify(piece)?.slice(0, 200)}`);
}

/**
 * Assembles one prompt through the wasm, counting tokens in process between its two calls.
 *
 * pieces returns every candidate piece of the prompt, each piece is costed with the injected
 * counter, and fit is handed the same request plus a `costs` array parallel to those pieces. A
 * failure at any step throws; this never returns a half-built prompt.
 * @param {any} request Assembly request, passed through unchanged.
 * @param {object} options Host wiring.
 * @param {(text: string) => number|Promise<number>} [options.countTokens] Local token counter. Injected, so no HTTP is involved.
 * @param {any} [options.module] Already-instantiated exports. Takes precedence over wasmPath.
 * @param {string} [options.wasmPath] Module path, used when no module is supplied.
 * @returns {Promise<{prompt: string, stop: any[], timed: any, replyPrefix: string}>}
 */
export async function assemblePrompt(request, { countTokens, module = null, wasmPath = DEFAULT_WASM_PATH } = {}) {
    if (!request || typeof request !== 'object') {
        throw new Error('assemblePrompt requires a request object.');
    }
    if (typeof countTokens !== 'function') {
        throw new Error('assemblePrompt requires a countTokens function: counting is injected so the assembly never makes an HTTP call.');
    }
    const exports = module ? assertAbi(module, 'supplied module') : await loadPromptWasm(wasmPath);

    // The clock and the dice seed are the HOST's to supply, not the browser's. A stateless service
    // cannot read a clock without the two build calls disagreeing, and a seed derived from the request
    // would make a swipe reroll identically when a re-draw per send is the intended behaviour. One
    // seed per assembly, shared by every call below, is deterministic within a send and fresh between.
    const seeded = {
        ...request,
        browser: {
            ...(request.browser ?? {}),
            now_ms: request.browser?.now_ms ?? Date.now(),
            seed: request.browser?.seed ?? Number(randomBytes(6).readUIntBE(0, 6)),
        },
    };

    // Lore is budgeted in tokens, so its candidate texts are counted before assembly decides which
    // entries fit. Without this the service falls back to counting bytes for the whole budget.
    const listedEntries = callEntry(exports, 'entries', seeded);
    const entryTexts = Array.isArray(listedEntries?.entries) ? listedEntries.entries : [];
    const wiEntryCosts = [];
    for (let index = 0; index < entryTexts.length; index++) {
        const cost = await countTokens(String(entryTexts[index]));
        if (!Number.isFinite(cost)) {
            throw new Error(`countTokens returned a non-numeric cost for lore entry ${index}: ${String(cost)}`);
        }
        wiEntryCosts.push(cost);
    }
    const withLore = { ...seeded, wi_entry_costs: wiEntryCosts };

    const listed = callEntry(exports, 'pieces', withLore);
    const pieces = listed?.pieces;
    if (!Array.isArray(pieces)) {
        throw new Error(`Prompt wasm pieces returned no pieces array (got ${typeof pieces}).`);
    }
    const costs = [];
    for (let index = 0; index < pieces.length; index++) {
        const cost = await countTokens(pieceText(pieces[index], index));
        if (!Number.isFinite(cost)) {
            throw new Error(`countTokens returned a non-numeric cost for piece ${index}: ${String(cost)}`);
        }
        costs.push(cost);
    }

    const fitted = callEntry(exports, 'fit', { ...withLore, costs });
    if (typeof fitted?.prompt !== 'string') {
        throw new Error(`Prompt wasm fit returned no prompt string (got ${typeof fitted?.prompt}).`);
    }
    const replyPrefix = fitted.replyPrefix ?? fitted.reply_prefix ?? '';
    return {
        prompt: fitted.prompt,
        stop: Array.isArray(fitted.stop) ? fitted.stop : [],
        timed: fitted.timed ?? null,
        replyPrefix: typeof replyPrefix === 'string' ? replyPrefix : '',
    };
}

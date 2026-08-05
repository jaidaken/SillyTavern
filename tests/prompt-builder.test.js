import { describe, test, expect, beforeEach, jest } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { assemblePrompt, loadPromptWasm, resetPromptWasmCache } from '../src/prompt-builder.js';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * A hand-written module implementing the wasm ABI in plain JS, so the whole flow runs with no wasm
 * file present. It records every alloc and free so a test can prove nothing is leaked.
 * @param {object} script What each entry point answers with.
 * @returns {object} The stub and its call log.
 */
function createStub({ pieces, fit, piecesRaw = null, fitRaw = null }) {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const calls = { alloc: [], free: [], pieces: [], fit: [] };
    let next = 16;

    const alloc = (len) => {
        const ptr = next;
        next += len + ((8 - (len % 8)) % 8);
        calls.alloc.push({ ptr, len });
        return ptr;
    };
    const readInput = (ptr, len) => JSON.parse(decoder.decode(new Uint8Array(memory.buffer, ptr, len)));
    const writeResult = (value) => {
        const bytes = encoder.encode(JSON.stringify(value));
        const ptr = alloc(bytes.length);
        new Uint8Array(memory.buffer).set(bytes, ptr);
        return (BigInt(ptr) << 32n) | BigInt(bytes.length);
    };

    const module = {
        memory,
        alloc,
        free: (ptr, len) => calls.free.push({ ptr, len }),
        pieces: (ptr, len) => {
            calls.pieces.push(readInput(ptr, len));
            return piecesRaw !== null ? piecesRaw : writeResult(pieces);
        },
        fit: (ptr, len) => {
            calls.fit.push(readInput(ptr, len));
            return fitRaw !== null ? fitRaw : writeResult(fit);
        },
    };
    return { module, calls };
}

const REQUEST = Object.freeze({
    card: { name: 'Ada' },
    messages: [{ name: 'Ada', mes: 'hello' }],
    settings: { max_context: 4096 },
    chat_metadata: {},
    world: { entries: [] },
    chat: { file_name: 'Ada - 2026' },
    browser: { input: 'hi', utc_offset_minutes: 60, is_mobile: false, generation_type: 'normal', rotation_index: 0 },
});

const THREE_PIECES = { pieces: [{ text: 'system prompt' }, { text: 'first message' }, 'raw string piece'] };
const FIT_RESULT = { prompt: 'assembled prompt', stop: ['\nAda:'], timed: { sticky: [3] }, reply_prefix: 'Ada:' };

describe('assemblePrompt', () => {
    beforeEach(() => resetPromptWasmCache());

    test('returns the fitted prompt and costs every piece exactly once', async () => {
        const { module, calls } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });
        const countTokens = jest.fn(text => text.length);

        const result = await assemblePrompt(REQUEST, { countTokens, module });

        expect(result).toEqual({
            prompt: 'assembled prompt',
            stop: ['\nAda:'],
            timed: { sticky: [3] },
            replyPrefix: 'Ada:',
        });
        expect(countTokens).toHaveBeenCalledTimes(3);
        expect(countTokens.mock.calls.map(args => args[0])).toEqual(['system prompt', 'first message', 'raw string piece']);
        expect(calls.pieces).toHaveLength(1);
        expect(calls.fit).toHaveLength(1);
    });

    test('hands fit the costs in piece order alongside the untouched request', async () => {
        const { module, calls } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });

        await assemblePrompt(REQUEST, { countTokens: text => text.length, module });

        expect(calls.fit[0].costs).toEqual(['system prompt'.length, 'first message'.length, 'raw string piece'.length]);
        expect(calls.fit[0].browser).toEqual(REQUEST.browser);
        expect(calls.pieces[0]).toEqual(REQUEST);
        expect(calls.pieces[0].costs).toBeUndefined();
    });

    test('awaits an async counter and keeps the order of its answers', async () => {
        const { module, calls } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });
        const delays = [3, 1, 2];
        let call = 0;
        const countTokens = () => new Promise(resolve => setTimeout(() => resolve(delays[call++]), 0));

        await assemblePrompt(REQUEST, { countTokens, module });

        expect(calls.fit[0].costs).toEqual([3, 1, 2]);
    });

    test('frees every allocation it made, on the happy path', async () => {
        const { module, calls } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });

        await assemblePrompt(REQUEST, { countTokens: text => text.length, module });

        expect(calls.alloc.length).toBe(4);
        expect(calls.free).toEqual(expect.arrayContaining(calls.alloc));
        expect(calls.free).toHaveLength(calls.alloc.length);
    });

    test('frees the input allocation when the module reports an error', async () => {
        const { module, calls } = createStub({ pieces: { error: 'world info budget is negative' }, fit: FIT_RESULT });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/pieces reported an error: world info budget is negative/);
        expect(calls.free).toEqual(expect.arrayContaining(calls.alloc));
        expect(calls.fit).toHaveLength(0);
    });

    test('rejects when fit reports an error, without returning a partial prompt', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: { error: 'prompt exceeds context' } });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/fit reported an error: prompt exceeds context/);
    });

    test('rejects a module missing every required export, naming each one', async () => {
        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module: {} }))
            .rejects.toThrow('Prompt wasm (supplied module) is missing required export(s): alloc, free, pieces, fit, memory');
    });

    test('rejects a module missing only fit', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });
        delete module.fit;

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/missing required export\(s\): fit$/);
    });

    test('rejects a result region that runs past the end of memory', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT, piecesRaw: (BigInt(65000) << 32n) | 4000n });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/pieces returned an unreadable region: ptr 65000, len 4000/);
    });

    test('rejects a null result pointer', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT, piecesRaw: 0n });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/pieces returned an unreadable region: ptr 0/);
    });

    test('rejects a pieces result carrying no pieces array', async () => {
        const { module } = createStub({ pieces: { note: 'nothing here' }, fit: FIT_RESULT });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow('Prompt wasm pieces returned no pieces array (got undefined).');
    });

    test('rejects a piece with no countable text', async () => {
        const { module } = createStub({ pieces: { pieces: [{ role: 'system' }] }, fit: FIT_RESULT });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow(/piece 0 carries no text to count/);
    });

    test('rejects a fit result with no prompt string', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: { stop: [] } });

        await expect(assemblePrompt(REQUEST, { countTokens: () => 1, module }))
            .rejects.toThrow('Prompt wasm fit returned no prompt string (got undefined).');
    });

    test('rejects a counter that returns something that is not a number', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });

        await expect(assemblePrompt(REQUEST, { countTokens: () => undefined, module }))
            .rejects.toThrow('countTokens returned a non-numeric cost for piece 0: undefined');
    });

    test('refuses to run without an injected counter', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });

        await expect(assemblePrompt(REQUEST, { module }))
            .rejects.toThrow(/requires a countTokens function/);
    });

    test('refuses a request that is not an object', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: FIT_RESULT });

        await expect(assemblePrompt('not a request', { countTokens: () => 1, module }))
            .rejects.toThrow('assemblePrompt requires a request object.');
    });

    test('defaults stop and replyPrefix when fit omits them', async () => {
        const { module } = createStub({ pieces: THREE_PIECES, fit: { prompt: 'bare' } });

        const result = await assemblePrompt(REQUEST, { countTokens: () => 1, module });

        expect(result).toEqual({ prompt: 'bare', stop: [], timed: null, replyPrefix: '' });
    });
});

describe('loadPromptWasm', () => {
    /** @type {string} */
    let dir;

    beforeEach(async () => {
        resetPromptWasmCache();
        dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'prompt-wasm-'));
    });

    test('names the path when the module is not on disk', async () => {
        const missing = path.join(dir, 'absent.wasm');

        await expect(loadPromptWasm(missing)).rejects.toThrow(`Prompt wasm could not be read at ${missing}`);
    });

    test('names the path when the bytes are not a wasm module', async () => {
        const bad = path.join(dir, 'bad.wasm');
        await fs.promises.writeFile(bad, 'this is not wasm');

        await expect(loadPromptWasm(bad)).rejects.toThrow(`Prompt wasm at ${bad} failed to instantiate`);
    });

    test('rejects a real module that instantiates but exports none of the ABI', async () => {
        const empty = path.join(dir, 'empty.wasm');
        await fs.promises.writeFile(empty, Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]));

        await expect(loadPromptWasm(empty))
            .rejects.toThrow(`Prompt wasm (${empty}) is missing required export(s): alloc, free, pieces, fit, memory`);
    });

    test('does not cache a failure, so a fixed module loads on the next call', async () => {
        const later = path.join(dir, 'later.wasm');

        await expect(loadPromptWasm(later)).rejects.toThrow('could not be read');
        await fs.promises.writeFile(later, Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]));
        await expect(loadPromptWasm(later)).rejects.toThrow('missing required export(s)');
    });
});

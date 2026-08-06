import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, test, expect, beforeAll } from '@jest/globals';
import { setConfigFilePath } from '../src/util.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// The backend-header lookup reads config at module top, and without a path that call exits the
// process; set it before the import that triggers it.
setConfigFilePath(path.join(repoRoot, 'default', 'config.yaml'));

/** @type {typeof import('../src/token-count.js')} */
let sut;
/** @type {typeof import('../src/token-count.js').bestMatchTokenizer} */
let bestMatchTokenizer;
/** @type {typeof import('../src/token-count.js').estimateTokens} */
let estimateTokens;
/** @type {typeof import('../src/token-count.js').createTokenCounter} */
let createTokenCounter;

beforeAll(async () => {
    sut = await import('../src/token-count.js');
    ({ bestMatchTokenizer, estimateTokens, createTokenCounter } = sut);
});

/**
 * A stand-in for a backend that carries its own tokenizer. Real HTTP rather than a mocked fetch, so
 * the url building and the response reading are exercised as they run in production.
 * @param {(body: any) => {status: number, json: any}} reply What to answer each encode request with.
 * @returns {Promise<{url: string, requests: number, stop: () => Promise<void>}>}
 */
async function fakeBackend(reply) {
    const state = { requests: 0 };
    const server = http.createServer((request, response) => {
        state.requests += 1;
        const chunks = [];
        request.on('data', chunk => chunks.push(chunk));
        request.on('end', () => {
            const answer = reply(JSON.parse(Buffer.concat(chunks).toString('utf8')));
            response.writeHead(answer.status, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify(answer.json));
        });
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const { port } = /** @type {import('node:net').AddressInfo} */ (server.address());
    return {
        url: `http://127.0.0.1:${port}`,
        get requests() { return state.requests; },
        stop: () => new Promise(resolve => server.close(() => resolve(undefined))),
    };
}

describe('bestMatchTokenizer', () => {
    test('a connected backend that carries its own tokenizer counts with that one', () => {
        expect(bestMatchTokenizer('llamacpp', 'some-model', true)).toBe('remote');
        expect(bestMatchTokenizer('tabby', 'some-model', true)).toBe('remote');
        expect(bestMatchTokenizer('koboldcpp', 'some-model', true)).toBe('remote');
        expect(bestMatchTokenizer('vllm', 'some-model', true)).toBe('remote');
        expect(bestMatchTokenizer('aphrodite', 'some-model', true)).toBe('remote');
    });

    test('an unconfigured backend falls to a local model even when its type carries a tokenizer', () => {
        expect(bestMatchTokenizer('llamacpp', 'mistral-7b', false)).toBe('mistral');
    });

    test('a backend without its own tokenizer picks a local model by model name', () => {
        expect(bestMatchTokenizer('ooba', 'Meta-Llama-3-8B', true)).toBe('llama3');
        expect(bestMatchTokenizer('generic', 'Mixtral-8x7B', true)).toBe('mistral');
        expect(bestMatchTokenizer('generic', 'gemma-2-9b', true)).toBe('gemma');
        expect(bestMatchTokenizer('generic', 'Mistral-Nemo', true)).toBe('mistral');
        expect(bestMatchTokenizer('generic', 'pixtral-12b', true)).toBe('nemo');
        expect(bestMatchTokenizer('generic', 'deepseek-v3', true)).toBe('deepseek');
        expect(bestMatchTokenizer('generic', 'Yi-34B', true)).toBe('yi');
        expect(bestMatchTokenizer('generic', 'jamba-mini', true)).toBe('jamba');
        expect(bestMatchTokenizer('generic', 'command-r-plus', true)).toBe('command-r');
        expect(bestMatchTokenizer('generic', 'command-a-03', true)).toBe('command-a');
        expect(bestMatchTokenizer('generic', 'Qwen2-7B', true)).toBe('qwen2');
    });

    test('a model name matching nothing is counted with llama, the ladder default', () => {
        expect(bestMatchTokenizer('generic', 'some-unknown-model', true)).toBe('llama');
        expect(bestMatchTokenizer('', '', false)).toBe('llama');
    });
});

describe('estimateTokens', () => {
    test('estimates from utf8 bytes, so a multi-byte character costs more than an ascii one', () => {
        expect(estimateTokens('abcdefg')).toBe(3);
        // Four bytes each, so seven of them is 28 bytes rather than 7.
        expect(estimateTokens('🙂🙂🙂🙂🙂🙂🙂')).toBe(9);
        expect(estimateTokens('')).toBe(0);
    });
});

// The local tier reads its model file relative to the server's working directory, so it is covered
// end to end in the generation route test rather than faked here. What these cover is the tier that
// leaves the box, which is cwd-independent and the one that can silently cost a prompt wrong.
describe('createTokenCounter over a backend that carries its own tokenizer', () => {
    const directories = { root: os.tmpdir() };

    test('counts with the backend and returns the count it reports', async () => {
        const backend = await fakeBackend((body) => ({ status: 200, json: { length: String(body.content).length } }));
        try {
            const counter = createTokenCounter({ directories, apiType: 'llamacpp', model: 'm', apiServer: backend.url });

            expect(await counter('a repeated turn')).toBe(15);
        } finally {
            await backend.stop();
        }
    });

    test('is asked once for a text that appears twice in one prompt', async () => {
        const backend = await fakeBackend((body) => ({ status: 200, json: { length: String(body.content).length } }));
        try {
            const counter = createTokenCounter({ directories, apiType: 'llamacpp', model: 'm', apiServer: backend.url });
            await counter('a repeated turn');
            await counter('a repeated turn');

            expect(backend.requests).toBe(1);
        } finally {
            await backend.stop();
        }
    });

    test('strips carriage returns before counting, matching what the client sent to be counted', async () => {
        const seen = [];
        const backend = await fakeBackend((body) => {
            seen.push(String(body.content));
            return { status: 200, json: { length: String(body.content).length } };
        });
        try {
            const counter = createTokenCounter({ directories, apiType: 'llamacpp', model: 'm', apiServer: backend.url });

            expect(await counter('one\r\ntwo')).toBe(await counter('one\ntwo'));
            expect(seen).toEqual(['one\ntwo']);
        } finally {
            await backend.stop();
        }
    });

    test('a failure costs the whole prompt by estimate, not just the piece that failed', async () => {
        const backend = await fakeBackend(() => ({ status: 500, json: { error: 'nope' } }));
        try {
            const counter = createTokenCounter({ directories, apiType: 'llamacpp', model: 'm', apiServer: backend.url });

            expect(await counter('the first piece')).toBe(estimateTokens('the first piece'));
            expect(await counter('a later piece')).toBe(estimateTokens('a later piece'));

            // Latched after the first failure: the later piece never went to the backend at all, so
            // one budget is never spent against a mix of exact counts and estimates.
            expect(backend.requests).toBe(1);
        } finally {
            await backend.stop();
        }
    });
});

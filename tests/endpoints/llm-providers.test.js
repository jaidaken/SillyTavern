import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE, SERVER_ROOT, allocatePort } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { readAllChunks } from '../../src/util.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const SAMPLE_TEXT = 'The quick brown fox jumps over the lazy dog.';

// SECRET_KEYS values, inlined rather than imported: secrets.js reads getConfigValue() at module
// load time, which requires the server's CONFIG_PATH global that only exists inside the spawned process.
const SECRET_KEYS = {
    WORKERS_AI: 'api_key_workers_ai',
    AZURE_TTS: 'api_key_azure_tts',
    NOVEL: 'api_key_novel',
    DEEPL: 'deepl',
    LIBRE_URL: 'libre_url',
    LINGVA_URL: 'lingva_url',
    ONERING_URL: 'oneringtranslator_url',
    DEEPLX_URL: 'deeplx_url',
    OPENROUTER: 'api_key_openrouter',
    MINIMAX: 'api_key_minimax',
    MINIMAX_GROUP_ID: 'minimax_group_id',
    VOLCENGINE_APP_ID: 'volcengine_app_id',
    VOLCENGINE_ACCESS_KEY: 'volcengine_access_key',
};

/**
 * Ad hoc HTTP double for provider routes whose upstream base URL is caller-configurable
 * (reverse_proxy, provider_endpoint, apiHost, or a URL secret). Each test swaps `handler`
 * immediately before making its request; tests never run concurrently within this file.
 */
class LocalMock {
    port = 0;
    server = null;
    handler = (_req, res) => {
        res.writeHead(404);
        res.end();
    };

    async start() {
        this.port = await allocatePort();
        this.server = http.createServer(async (req, res) => {
            const chunks = await readAllChunks(req);
            const body = Buffer.concat(chunks).toString('utf8');
            this.handler(req, res, body);
        });
        await new Promise((resolve, reject) => {
            this.server.once('error', reject);
            this.server.listen(this.port, '127.0.0.1', resolve);
        });
    }

    get url() {
        return `http://127.0.0.1:${this.port}`;
    }

    async stop() {
        await new Promise(resolve => this.server.close(resolve));
    }
}

const TOKENIZER_ROUTES = [
    ['llama encode', '/api/tokenizers/llama/encode'],
    ['nerdstash encode', '/api/tokenizers/nerdstash/encode'],
    ['nerdstash_v2 encode', '/api/tokenizers/nerdstash_v2/encode'],
    ['mistral encode', '/api/tokenizers/mistral/encode'],
    ['yi encode', '/api/tokenizers/yi/encode'],
    ['gemma encode', '/api/tokenizers/gemma/encode'],
    ['jamba encode', '/api/tokenizers/jamba/encode'],
    ['gpt2 encode', '/api/tokenizers/gpt2/encode'],
    ['claude encode', '/api/tokenizers/claude/encode'],
    ['llama3 encode', '/api/tokenizers/llama3/encode'],
    ['qwen2 encode', '/api/tokenizers/qwen2/encode'],
    ['command-r encode', '/api/tokenizers/command-r/encode'],
    ['command-a encode', '/api/tokenizers/command-a/encode'],
    ['nemo encode', '/api/tokenizers/nemo/encode'],
    ['deepseek encode', '/api/tokenizers/deepseek/encode'],
    ['llama decode', '/api/tokenizers/llama/decode'],
    ['nerdstash decode', '/api/tokenizers/nerdstash/decode'],
    ['nerdstash_v2 decode', '/api/tokenizers/nerdstash_v2/decode'],
    ['mistral decode', '/api/tokenizers/mistral/decode'],
    ['yi decode', '/api/tokenizers/yi/decode'],
    ['gemma decode', '/api/tokenizers/gemma/decode'],
    ['jamba decode', '/api/tokenizers/jamba/decode'],
    ['gpt2 decode', '/api/tokenizers/gpt2/decode'],
    ['claude decode', '/api/tokenizers/claude/decode'],
    ['llama3 decode', '/api/tokenizers/llama3/decode'],
    ['qwen2 decode', '/api/tokenizers/qwen2/decode'],
    ['command-r decode', '/api/tokenizers/command-r/decode'],
    ['command-a decode', '/api/tokenizers/command-a/decode'],
    ['nemo decode', '/api/tokenizers/nemo/decode'],
    ['deepseek decode', '/api/tokenizers/deepseek/decode'],
    ['openai encode', '/api/tokenizers/openai/encode'],
    ['openai decode', '/api/tokenizers/openai/decode'],
    ['openai count', '/api/tokenizers/openai/count'],
    ['remote kobold count', '/api/tokenizers/remote/kobold/count'],
    ['remote textgenerationwebui encode', '/api/tokenizers/remote/textgenerationwebui/encode'],
];

const OPENAI_ROUTES = [
    ['caption-image', '/api/openai/caption-image'],
    ['generate-voice', '/api/openai/generate-voice'],
    ['electronhub generate-voice', '/api/openai/electronhub/generate-voice'],
    ['electronhub models', '/api/openai/electronhub/models'],
    ['chutes generate-voice', '/api/openai/chutes/generate-voice'],
    ['chutes models embedding', '/api/openai/chutes/models/embedding'],
    ['nanogpt models embedding', '/api/openai/nanogpt/models/embedding'],
    ['siliconflow models embedding', '/api/openai/siliconflow/models/embedding'],
    ['workers-ai models embedding', '/api/openai/workers-ai/models/embedding'],
    ['generate-image', '/api/openai/generate-image'],
    ['generate-video', '/api/openai/generate-video'],
    ['custom generate-voice', '/api/openai/custom/generate-voice'],
    ['transcribe-audio', '/api/openai/transcribe-audio'],
    ['groq transcribe-audio', '/api/openai/groq/transcribe-audio'],
    ['mistral transcribe-audio', '/api/openai/mistral/transcribe-audio'],
    ['zai transcribe-audio', '/api/openai/zai/transcribe-audio'],
    ['chutes transcribe-audio', '/api/openai/chutes/transcribe-audio'],
];

const GOOGLE_ROUTES = [
    ['caption-image', '/api/google/caption-image'],
    ['list-voices', '/api/google/list-voices'],
    ['generate-voice', '/api/google/generate-voice'],
    ['list-native-voices', '/api/google/list-native-voices'],
    ['generate-native-tts', '/api/google/generate-native-tts'],
    ['generate-image', '/api/google/generate-image'],
    ['generate-video', '/api/google/generate-video'],
];

const TRANSLATE_ROUTES = [
    ['libre', '/api/translate/libre'],
    ['google', '/api/translate/google'],
    ['yandex', '/api/translate/yandex'],
    ['lingva', '/api/translate/lingva'],
    ['deepl', '/api/translate/deepl'],
    ['onering', '/api/translate/onering'],
    ['deeplx', '/api/translate/deeplx'],
    ['bing', '/api/translate/bing'],
];

const OPENROUTER_ROUTES = [
    ['models providers', '/api/openrouter/models/providers'],
    ['models multimodal', '/api/openrouter/models/multimodal'],
    ['models embedding', '/api/openrouter/models/embedding'],
    ['models image', '/api/openrouter/models/image'],
    ['credits', '/api/openrouter/credits'],
    ['image generate', '/api/openrouter/image/generate'],
];

const NOVELAI_ROUTES = [
    ['status', '/api/novelai/status'],
    ['generate', '/api/novelai/generate'],
    ['generate-image', '/api/novelai/generate-image'],
    ['generate-voice', '/api/novelai/generate-voice'],
];

const ANTHROPIC_ROUTES = [
    ['caption-image', '/api/anthropic/caption-image'],
];

const AZURE_ROUTES = [
    ['list', '/api/azure/list'],
    ['generate', '/api/azure/generate'],
];

const NANOGPT_ROUTES = [
    ['credits', '/api/nanogpt/credits'],
    ['models providers', '/api/nanogpt/models/providers'],
];

const MINIMAX_ROUTES = [
    ['generate-voice', '/api/minimax/generate-voice'],
];

const VOLCENGINE_ROUTES = [
    ['generate-voice', '/api/volcengine/generate-voice'],
];

const HORDE_ROUTES = [
    ['text-workers', '/api/horde/text-workers'],
    ['text-models', '/api/horde/text-models'],
    ['status', '/api/horde/status'],
    ['cancel-task', '/api/horde/cancel-task'],
    ['task-status', '/api/horde/task-status'],
    ['generate-text', '/api/horde/generate-text'],
    ['sd-samplers', '/api/horde/sd-samplers'],
    ['sd-models', '/api/horde/sd-models'],
    ['caption-image', '/api/horde/caption-image'],
    ['user-info', '/api/horde/user-info'],
    ['generate-image', '/api/horde/generate-image'],
];

describe('SillyTavern LLM provider and tokenizer endpoints', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let client;
    /** @type {SillyTavernClient} Never logs in; global auth middleware must reject it everywhere below. */
    let anonymous;
    /** @type {LocalMock} */
    let mock;

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start();

        // Pre-seed the tokenizer cache with llama3.json so the GitHub-hosted web tokenizers resolve from disk, not the network.
        const cacheDir = path.join(server.dataRoot, '_cache');
        fs.mkdirSync(cacheDir, { recursive: true });
        const llama3Source = path.join(SERVER_ROOT, 'src', 'tokenizers', 'llama3.json');
        for (const name of ['qwen2.json', 'command-r.json', 'command-a.json', 'nemo.json', 'deepseek.json']) {
            fs.copyFileSync(llama3Source, path.join(cacheDir, name));
        }

        client = new SillyTavernClient(server.baseUrl);
        await client.fetchCsrfToken();
        const login = await client.login(DEFAULT_HANDLE);
        if (login.status !== 200) {
            throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
        }

        anonymous = new SillyTavernClient(server.baseUrl);

        mock = new LocalMock();
        await mock.start();
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await mock?.stop();
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    /**
     * @param {string} key SECRET_KEYS value
     * @param {string} value Secret value to store
     */
    async function writeSecret(key, value) {
        const response = await client.postJson('/api/secrets/write', { key, value, label: 'p8llm' });
        expect(response.status).toBe(200);
    }

    describe('auth contract: every provider and tokenizer route rejects anonymous requests', () => {
        test.each([
            ...TOKENIZER_ROUTES,
            ...OPENAI_ROUTES,
            ...GOOGLE_ROUTES,
            ...TRANSLATE_ROUTES,
            ...OPENROUTER_ROUTES,
            ...NOVELAI_ROUTES,
            ...ANTHROPIC_ROUTES,
            ...AZURE_ROUTES,
            ...NANOGPT_ROUTES,
            ...MINIMAX_ROUTES,
            ...VOLCENGINE_ROUTES,
            ...HORDE_ROUTES,
        ])('%s (%s) returns 403 for an anonymous client', async (_name, routePath) => {
            const response = await anonymous.postJson(routePath, {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('tokenizers: local sentencepiece and tiktoken models (fully offline, deterministic)', () => {
        test('llama_decode_concatenates_per_token_chunks_without_word_boundary_spaces', async () => {
            const encoded = await client.postJson('/api/tokenizers/llama/encode', { text: SAMPLE_TEXT });
            expect(encoded.status).toBe(200);
            const encodedBody = await encoded.json();
            expect(encodedBody.count).toBe(encodedBody.ids.length);
            expect(encodedBody.ids.length).toBeGreaterThan(0);

            const decoded = await client.postJson('/api/tokenizers/llama/decode', { ids: encodedBody.ids });
            expect(decoded.status).toBe(200);
            const decodedBody = await decoded.json();
            // Per-id decode+join (SentencePieceProcessor#decodeIds([id])) drops every inter-word space.
            expect(decodedBody.text).toBe('Thequickbrownfoxjumpsoverthelazydog.');
            expect(decodedBody.chunks).toEqual(['The', 'quick', 'brown', 'fo', 'x', 'j', 'umps', 'over', 'the', 'lazy', 'dog', '.']);
        }, CASE_TIMEOUT_MS);

        test('llama_encode_of_empty_text_returns_zero_count_and_no_ids', async () => {
            const response = await client.postJson('/api/tokenizers/llama/encode', { text: '' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ ids: [], count: 0, chunks: [] });
        }, CASE_TIMEOUT_MS);

        test('llama_decode_of_empty_ids_returns_empty_text', async () => {
            const response = await client.postJson('/api/tokenizers/llama/decode', { ids: [] });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ text: '', chunks: [] });
        }, CASE_TIMEOUT_MS);

        test.each([
            ['nerdstash', '/api/tokenizers/nerdstash/encode'],
            ['nerdstash_v2', '/api/tokenizers/nerdstash_v2/encode'],
            ['mistral', '/api/tokenizers/mistral/encode'],
            ['yi', '/api/tokenizers/yi/encode'],
            ['gemma', '/api/tokenizers/gemma/encode'],
            ['jamba', '/api/tokenizers/jamba/encode'],
        ])('%s_encode_returns_a_consistent_ids_count_and_chunks_shape', async (_name, routePath) => {
            const response = await client.postJson(routePath, { text: SAMPLE_TEXT });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.count).toBe(body.ids.length);
            expect(body.ids.length).toBeGreaterThan(0);
            expect(body.ids.every(id => Number.isInteger(id))).toBe(true);
            expect(Array.isArray(body.chunks)).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('gpt2_encode_decode_round_trips_the_sentence_exactly', async () => {
            const encoded = await client.postJson('/api/tokenizers/gpt2/encode', { text: SAMPLE_TEXT });
            expect(encoded.status).toBe(200);
            const encodedBody = await encoded.json();
            expect(encodedBody.count).toBe(encodedBody.ids.length);

            const decoded = await client.postJson('/api/tokenizers/gpt2/decode', { ids: encodedBody.ids });
            expect(decoded.status).toBe(200);
            expect((await decoded.json()).text).toBe(SAMPLE_TEXT);
        }, CASE_TIMEOUT_MS);

        test('gpt2_decode_of_empty_ids_returns_empty_text', async () => {
            const response = await client.postJson('/api/tokenizers/gpt2/decode', { ids: [] });
            expect(response.status).toBe(200);
            expect((await response.json()).text).toBe('');
        }, CASE_TIMEOUT_MS);

        test('claude_encode_decode_round_trips_the_sentence_exactly', async () => {
            const encoded = await client.postJson('/api/tokenizers/claude/encode', { text: SAMPLE_TEXT });
            expect(encoded.status).toBe(200);
            const encodedBody = await encoded.json();
            expect(encodedBody.count).toBe(encodedBody.ids.length);
            expect(encodedBody.ids.length).toBeGreaterThan(0);

            const decoded = await client.postJson('/api/tokenizers/claude/decode', { ids: encodedBody.ids });
            expect(decoded.status).toBe(200);
            expect((await decoded.json()).text).toBe(SAMPLE_TEXT);
        }, CASE_TIMEOUT_MS);

        test('llama3_encode_decode_round_trips_the_sentence_exactly', async () => {
            const encoded = await client.postJson('/api/tokenizers/llama3/encode', { text: SAMPLE_TEXT });
            expect(encoded.status).toBe(200);
            const encodedBody = await encoded.json();
            expect(encodedBody.count).toBe(encodedBody.ids.length);

            const decoded = await client.postJson('/api/tokenizers/llama3/decode', { ids: encodedBody.ids });
            expect(decoded.status).toBe(200);
            expect((await decoded.json()).text).toBe(SAMPLE_TEXT);
        }, CASE_TIMEOUT_MS);

        test('llama_encode_rejects_a_missing_request_body', async () => {
            const response = await client.postRaw('/api/tokenizers/llama/encode', 'null', 'application/json');
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('tokenizers: GitHub-hosted web tokenizers, cache-seeded to avoid a live network fetch', () => {
        test('qwen2_encode_decode_round_trips_and_matches_the_llama3_route_byte_for_byte', async () => {
            // The test cache seed (beforeAll) points qwen2's model file at the same llama3.json
            // content llama3_tokenizer loads, so both routes must tokenize this text identically.
            const qwen2Encoded = await client.postJson('/api/tokenizers/qwen2/encode', { text: SAMPLE_TEXT });
            const llama3Encoded = await client.postJson('/api/tokenizers/llama3/encode', { text: SAMPLE_TEXT });
            expect(qwen2Encoded.status).toBe(200);
            expect(await qwen2Encoded.json()).toEqual(await llama3Encoded.json());

            const qwen2Body = await (await client.postJson('/api/tokenizers/qwen2/encode', { text: SAMPLE_TEXT })).json();
            const decoded = await client.postJson('/api/tokenizers/qwen2/decode', { ids: qwen2Body.ids });
            expect(decoded.status).toBe(200);
            expect((await decoded.json()).text).toBe(SAMPLE_TEXT);
        }, CASE_TIMEOUT_MS);

        test.each([
            ['command-r', '/api/tokenizers/command-r/encode'],
            ['command-a', '/api/tokenizers/command-a/encode'],
            ['nemo', '/api/tokenizers/nemo/encode'],
            ['deepseek', '/api/tokenizers/deepseek/encode'],
        ])('%s_encode_matches_the_llama3_route_byte_for_byte_via_the_shared_cache_seed', async (_name, routePath) => {
            const response = await client.postJson(routePath, { text: SAMPLE_TEXT });
            const llama3Response = await client.postJson('/api/tokenizers/llama3/encode', { text: SAMPLE_TEXT });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual(await llama3Response.json());
        }, CASE_TIMEOUT_MS);
    });

    describe('tokenizers: /openai/encode, /openai/decode, /openai/count', () => {
        test('openai_encode_decode_with_no_model_query_round_trips_via_the_default_gpt_3_5_tiktoken_model', async () => {
            const encoded = await client.postJson('/api/tokenizers/openai/encode', { text: SAMPLE_TEXT });
            expect(encoded.status).toBe(200);
            const encodedBody = await encoded.json();
            expect(encodedBody.count).toBe(encodedBody.ids.length);

            const decoded = await client.postJson('/api/tokenizers/openai/decode', { ids: encodedBody.ids });
            expect(decoded.status).toBe(200);
            expect((await decoded.json()).text).toBe(SAMPLE_TEXT);
        }, CASE_TIMEOUT_MS);

        test('openai_encode_with_model_claude_query_dispatches_to_the_same_tokenizer_as_the_claude_route', async () => {
            const viaOpenai = await client.postJson('/api/tokenizers/openai/encode?model=claude-3-opus', { text: SAMPLE_TEXT });
            const viaClaude = await client.postJson('/api/tokenizers/claude/encode', { text: SAMPLE_TEXT });
            expect(viaOpenai.status).toBe(200);
            expect(await viaOpenai.json()).toEqual(await viaClaude.json());
        }, CASE_TIMEOUT_MS);

        test('openai_encode_with_model_llama_query_dispatches_to_the_same_sentencepiece_tokenizer_as_the_llama_route', async () => {
            const viaOpenai = await client.postJson('/api/tokenizers/openai/encode?model=llama-2-7b', { text: SAMPLE_TEXT });
            const viaLlama = await client.postJson('/api/tokenizers/llama/encode', { text: SAMPLE_TEXT });
            expect(viaOpenai.status).toBe(200);
            expect(await viaOpenai.json()).toEqual(await viaLlama.json());
        }, CASE_TIMEOUT_MS);

        test('openai_count_with_no_model_query_returns_the_exact_chatml_token_count_for_a_single_message', async () => {
            const response = await client.postJson('/api/tokenizers/openai/count', [
                { role: 'user', content: 'Hello world' },
            ]);
            expect(response.status).toBe(200);
            // 9 = tokensPerMessage(3) + encode('user')+encode('Hello world') via tiktoken cl100k_base(3) + tokensPadding(3).
            expect(await response.json()).toEqual({ token_count: 9 });
        }, CASE_TIMEOUT_MS);

        test('openai_count_with_a_non_array_body_silently_falls_back_to_a_byte_length_guesstimate_instead_of_400', async () => {
            // `for (const msg of req.body)` throws on a non-array; the outer catch swallows it into a guesstimate.
            const response = await client.postJson('/api/tokenizers/openai/count', { not: 'an array' });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(typeof body.token_count).toBe('number');
            expect(body.token_count).toBeGreaterThan(0);
        }, CASE_TIMEOUT_MS);
    });

    describe('tokenizers: /remote/kobold/count and /remote/textgenerationwebui/encode (caller-configurable url)', () => {
        test('remote_kobold_count_forwards_to_the_configured_url_and_returns_its_count_and_ids', async () => {
            mock.handler = (req, res) => {
                expect(req.method).toBe('POST');
                expect(req.url).toBe('/extra/tokencount');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ value: 5, ids: [1, 2, 3, 4, 5] }));
            };

            const response = await client.postJson('/api/tokenizers/remote/kobold/count', {
                text: SAMPLE_TEXT,
                url: mock.url,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ count: 5, ids: [1, 2, 3, 4, 5] });
        }, CASE_TIMEOUT_MS);

        test('remote_kobold_count_with_an_unset_url_returns_200_with_an_error_flag_instead_of_400', async () => {
            // No validation on `url`: an absent value becomes the literal string "undefined" and fails silently.
            const response = await client.postJson('/api/tokenizers/remote/kobold/count', { text: SAMPLE_TEXT });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ error: true });
        }, CASE_TIMEOUT_MS);

        test('remote_textgenerationwebui_encode_with_default_api_type_hits_v1_internal_encode', async () => {
            mock.handler = (req, res) => {
                expect(req.method).toBe('POST');
                expect(req.url).toBe('/v1/internal/encode');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ tokens: [10, 20, 30] }));
            };

            const response = await client.postJson('/api/tokenizers/remote/textgenerationwebui/encode', {
                text: SAMPLE_TEXT,
                url: mock.url,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ count: 3, ids: [10, 20, 30] });
        }, CASE_TIMEOUT_MS);

        test('remote_textgenerationwebui_encode_with_tabby_api_type_hits_v1_token_encode', async () => {
            mock.handler = (req, res) => {
                expect(req.url).toBe('/v1/token/encode');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ tokens: [1, 2] }));
            };

            const response = await client.postJson('/api/tokenizers/remote/textgenerationwebui/encode', {
                text: SAMPLE_TEXT,
                url: mock.url,
                api_type: 'tabby',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ count: 2, ids: [1, 2] });
        }, CASE_TIMEOUT_MS);

        test('remote_textgenerationwebui_encode_returns_an_error_flag_when_the_upstream_responds_with_an_error_status', async () => {
            mock.handler = (_req, res) => {
                res.writeHead(500);
                res.end();
            };

            const response = await client.postJson('/api/tokenizers/remote/textgenerationwebui/encode', {
                text: SAMPLE_TEXT,
                url: mock.url,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ error: true });
        }, CASE_TIMEOUT_MS);
    });

    describe('openai.js provider proxy (caption/tts/image/video/transcription grab-bag)', () => {
        test.each([
            ['generate-voice', '/api/openai/generate-voice'],
            ['electronhub generate-voice', '/api/openai/electronhub/generate-voice'],
            ['electronhub models', '/api/openai/electronhub/models'],
            ['chutes generate-voice', '/api/openai/chutes/generate-voice'],
            ['chutes models embedding', '/api/openai/chutes/models/embedding'],
            ['nanogpt models embedding', '/api/openai/nanogpt/models/embedding'],
            ['siliconflow models embedding', '/api/openai/siliconflow/models/embedding'],
            ['workers-ai models embedding', '/api/openai/workers-ai/models/embedding'],
            ['generate-image', '/api/openai/generate-image'],
            ['generate-video', '/api/openai/generate-video'],
            ['transcribe-audio', '/api/openai/transcribe-audio'],
            ['groq transcribe-audio', '/api/openai/groq/transcribe-audio'],
            ['mistral transcribe-audio', '/api/openai/mistral/transcribe-audio'],
            ['zai transcribe-audio', '/api/openai/zai/transcribe-audio'],
            ['chutes transcribe-audio', '/api/openai/chutes/transcribe-audio'],
        ])('%s returns 400 when its provider key is not configured (needs a live provider beyond this)', async (_name, routePath) => {
            const response = await client.postJson(routePath, {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('caption_image_with_api_openai_and_no_key_returns_400', async () => {
            const response = await client.postJson('/api/openai/caption-image', { api: 'openai', model: 'gpt-4o', prompt: 'x', image: 'data:image/png;base64,iVBORw0KGgo=' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('workers_ai_models_embedding_with_a_key_but_no_account_id_returns_400', async () => {
            await writeSecret(SECRET_KEYS.WORKERS_AI, 'fake-workers-ai-key');
            const response = await client.postJson('/api/openai/workers-ai/models/embedding', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('custom_generate_voice_requires_no_api_key_unlike_its_siblings_and_returns_400_only_for_a_missing_endpoint', async () => {
            // Unlike its sibling TTS routes, this one never checks CUSTOM_OPENAI_TTS before forwarding.
            const response = await client.postJson('/api/openai/custom/generate-voice', { input: 'hi' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('custom_generate_voice_forwards_to_the_configured_endpoint_and_streams_back_its_response_body', async () => {
            const audioBytes = Buffer.from('fake-mp3-bytes');
            mock.handler = (req, res) => {
                expect(req.method).toBe('POST');
                res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
                res.end(audioBytes);
            };

            const response = await client.postJson('/api/openai/custom/generate-voice', {
                input: 'hello',
                provider_endpoint: mock.url,
            });
            expect(response.status).toBe(200);
            expect(response.headers.get('content-type')).toBe('audio/mpeg');
            expect(Buffer.from(await response.arrayBuffer())).toEqual(audioBytes);
        }, CASE_TIMEOUT_MS);

        test('caption_image_with_api_custom_forwards_to_the_configured_server_url_and_extracts_the_chat_completion_caption', async () => {
            mock.handler = (req, res) => {
                expect(req.url).toBe('/chat/completions');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ choices: [{ message: { content: 'a mocked caption' } }] }));
            };

            const response = await client.postJson('/api/openai/caption-image', {
                api: 'custom',
                server_url: mock.url,
                model: 'x',
                prompt: 'describe this',
                image: 'data:image/png;base64,iVBORw0KGgo=',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ caption: 'a mocked caption' });
        }, CASE_TIMEOUT_MS);
    });

    describe('google.js provider proxy', () => {
        test('list_voices_is_a_fully_local_route_returning_the_google_translate_language_map', async () => {
            const response = await client.postJson('/api/google/list-voices', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.en).toBe('English');
        }, CASE_TIMEOUT_MS);

        test('list_native_voices_is_a_fully_local_route_returning_the_hardcoded_gemini_voice_list', async () => {
            const response = await client.postJson('/api/google/list-native-voices', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.voices).toHaveLength(30);
            expect(body.voices[0]).toEqual({ name: 'Zephyr', voice_id: 'Zephyr', lang: 'en-US', description: 'Bright' });
        }, CASE_TIMEOUT_MS);

        test('caption_image_via_reverse_proxy_forwards_to_the_configured_url_and_extracts_the_candidate_text', async () => {
            mock.handler = (req, res) => {
                expect(req.headers['x-goog-api-key']).toBe('test-proxy-password');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'a mocked gemini caption' }] } }] }));
            };

            const response = await client.postJson('/api/google/caption-image', {
                reverse_proxy: mock.url,
                proxy_password: 'test-proxy-password',
                model: 'gemini-2.0-flash',
                prompt: 'describe this',
                image: 'data:image/png;base64,iVBORw0KGgo=',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ caption: 'a mocked gemini caption' });
        }, CASE_TIMEOUT_MS);

        test('caption_image_via_reverse_proxy_returns_500_when_the_upstream_error_body_is_not_json', async () => {
            // `result.json()` on the empty 503 body throws, caught by the outer catch as a generic 500.
            mock.handler = (_req, res) => {
                res.writeHead(503);
                res.end();
            };

            const response = await client.postJson('/api/google/caption-image', {
                reverse_proxy: mock.url,
                proxy_password: 'test-proxy-password',
                model: 'gemini-2.0-flash',
                prompt: 'describe this',
                image: 'data:image/png;base64,iVBORw0KGgo=',
            });
            expect(response.status).toBe(500);
        }, CASE_TIMEOUT_MS);

        test('generate_image_via_reverse_proxy_forwards_to_the_configured_url_and_returns_the_base64_image', async () => {
            mock.handler = (_req, res) => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ predictions: [{ bytesBase64Encoded: 'ZmFrZS1pbWFnZS1ieXRlcw==' }] }));
            };

            const response = await client.postJson('/api/google/generate-image', {
                reverse_proxy: mock.url,
                proxy_password: 'test-proxy-password',
                prompt: 'a cat',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ image: 'ZmFrZS1pbWFnZS1ieXRlcw==' });
        }, CASE_TIMEOUT_MS);
    });

    describe('anthropic.js caption-image', () => {
        test('caption_image_never_checks_that_a_claude_key_is_configured_before_calling_the_provider', async () => {
            // Unlike novelai/openai/google, this route never checks the CLAUDE secret is present.
            mock.handler = (req, res) => {
                expect(req.headers['x-api-key']).toBe('test-proxy-password');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ content: [{ text: 'a mocked claude caption' }] }));
            };

            const response = await client.postJson('/api/anthropic/caption-image', {
                reverse_proxy: mock.url,
                proxy_password: 'test-proxy-password',
                model: 'claude-3-opus',
                prompt: 'describe this',
                image: 'data:image/png;base64,iVBORw0KGgo=',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ caption: 'a mocked claude caption' });
        }, CASE_TIMEOUT_MS);

        test('caption_image_via_reverse_proxy_forwards_the_upstream_error_status', async () => {
            mock.handler = (_req, res) => {
                res.writeHead(429, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'rate limited' }));
            };

            const response = await client.postJson('/api/anthropic/caption-image', {
                reverse_proxy: mock.url,
                proxy_password: 'test-proxy-password',
                model: 'claude-3-opus',
                prompt: 'describe this',
                image: 'data:image/png;base64,iVBORw0KGgo=',
            });
            expect(response.status).toBe(429);
            expect(await response.json()).toEqual({ error: true });
        }, CASE_TIMEOUT_MS);
    });

    describe('azure.js TTS proxy (needs a live provider beyond the auth/bad-input contract)', () => {
        test('list_without_a_configured_key_returns_403_not_400', async () => {
            // Azure is the odd one out among this batch: a missing key is a 403 here, where most
            // other providers in this file (novelai, google, openai TTS routes) return 400.
            const response = await client.postJson('/api/azure/list', { region: 'eastus' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('list_with_a_key_but_no_region_returns_400', async () => {
            await writeSecret(SECRET_KEYS.AZURE_TTS, 'fake-azure-key');
            const response = await client.postJson('/api/azure/list', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('generate_without_a_configured_key_returns_403_not_400', async () => {
            const response = await anonymous.postJson('/api/azure/generate', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('generate_with_a_key_but_missing_text_voice_or_region_returns_400', async () => {
            const response = await client.postJson('/api/azure/generate', { text: 'hi' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('nanogpt.js endpoint router (needs a live provider beyond the auth/bad-input contract)', () => {
        test('credits_without_a_configured_key_returns_400', async () => {
            const response = await client.postJson('/api/nanogpt/credits', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('models_providers_without_a_model_returns_400_with_a_default_shaped_body_and_needs_no_key', async () => {
            // This route needs no NANOGPT key at all, unlike its sibling /credits.
            const response = await client.postJson('/api/nanogpt/models/providers', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ supportsProviderSelection: false, providers: [] });
        }, CASE_TIMEOUT_MS);
    });

    describe('openrouter.js (models/* routes always call the live provider; credits and image/generate gate on a key)', () => {
        test('credits_without_a_configured_key_returns_400', async () => {
            const response = await client.postJson('/api/openrouter/credits', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('image_generate_without_a_configured_key_returns_400_with_a_json_error_body', async () => {
            const response = await client.postJson('/api/openrouter/image/generate', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'OpenRouter API key not found' });
        }, CASE_TIMEOUT_MS);

        test('image_generate_with_a_key_but_missing_model_or_prompt_returns_400', async () => {
            await writeSecret(SECRET_KEYS.OPENROUTER, 'fake-openrouter-key');
            const response = await client.postJson('/api/openrouter/image/generate', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Model and prompt are required' });
        }, CASE_TIMEOUT_MS);
    });

    describe('novelai.js (needs a live provider beyond the auth/bad-input contract)', () => {
        test.each([
            ['status', '/api/novelai/status'],
            ['generate', '/api/novelai/generate'],
            ['generate-image', '/api/novelai/generate-image'],
            ['generate-voice', '/api/novelai/generate-voice'],
        ])('%s without a configured access token returns 400', async (_name, routePath) => {
            const response = await client.postJson(routePath, {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('generate_voice_with_a_token_but_missing_text_or_voice_returns_400', async () => {
            await writeSecret(SECRET_KEYS.NOVEL, 'fake-novel-token');
            const response = await client.postJson('/api/novelai/generate-voice', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });

    describe('translate.js', () => {
        test.each([
            ['google', '/api/translate/google'],
            ['yandex', '/api/translate/yandex'],
            ['bing', '/api/translate/bing'],
        ])('%s returns 400 for a missing text or lang (needs a live provider for its happy path)', async (_name, routePath) => {
            const response = await client.postJson(routePath, {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('deepl_without_a_configured_key_returns_400', async () => {
            const response = await client.postJson('/api/translate/deepl', { text: 'hi', lang: 'de' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('deepl_with_a_key_but_missing_text_or_lang_returns_400', async () => {
            await writeSecret(SECRET_KEYS.DEEPL, 'fake-deepl-key');
            const response = await client.postJson('/api/translate/deepl', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('libre_without_a_configured_url_returns_400', async () => {
            const response = await client.postJson('/api/translate/libre', { text: 'hi', lang: 'de' });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('libre_with_a_configured_url_forwards_the_text_and_returns_the_translated_string', async () => {
            await writeSecret(SECRET_KEYS.LIBRE_URL, mock.url);
            mock.handler = (req, res, body) => {
                expect(JSON.parse(body)).toEqual(expect.objectContaining({ q: 'hello', target: 'de' }));
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ translatedText: 'hallo' }));
            };

            const response = await client.postJson('/api/translate/libre', { text: 'hello', lang: 'de' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('hallo');
        }, CASE_TIMEOUT_MS);

        test('lingva_with_a_configured_url_forwards_the_text_and_returns_the_translation', async () => {
            await writeSecret(SECRET_KEYS.LINGVA_URL, mock.url);
            mock.handler = (req, res) => {
                expect(req.url).toBe('/auto/de/hello');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ translation: 'hallo-lingva' }));
            };

            const response = await client.postJson('/api/translate/lingva', { text: 'hello', lang: 'de' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('hallo-lingva');
        }, CASE_TIMEOUT_MS);

        test('onering_with_a_configured_url_forwards_the_text_as_query_params_and_returns_the_result', async () => {
            await writeSecret(SECRET_KEYS.ONERING_URL, mock.url);
            mock.handler = (req, res) => {
                const query = new URL(req.url, mock.url).searchParams;
                expect(query.get('text')).toBe('hello');
                expect(query.get('from_lang')).toBe('en');
                expect(query.get('to_lang')).toBe('de');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ result: 'hallo-onering' }));
            };

            const response = await client.postJson('/api/translate/onering', { text: 'hello', from_lang: 'en', to_lang: 'de' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('hallo-onering');
        }, CASE_TIMEOUT_MS);

        test('deeplx_with_a_configured_url_forwards_the_text_and_returns_the_data_field', async () => {
            await writeSecret(SECRET_KEYS.DEEPLX_URL, mock.url);
            mock.handler = (req, res, body) => {
                expect(JSON.parse(body)).toEqual({ text: 'hello', source_lang: 'auto', target_lang: 'de' });
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ data: 'hallo-deeplx' }));
            };

            const response = await client.postJson('/api/translate/deeplx', { text: 'hello', lang: 'de' });
            expect(response.status).toBe(200);
            expect(await response.text()).toBe('hallo-deeplx');
        }, CASE_TIMEOUT_MS);
    });

    describe('minimax.js generate-voice', () => {
        test('generate_voice_with_missing_fields_returns_400_with_a_json_error_body', async () => {
            const response = await client.postJson('/api/minimax/generate-voice', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Missing required parameters: text, voiceId, apiKey, and groupId are required' });
        }, CASE_TIMEOUT_MS);

        test('generate_voice_with_a_configured_api_host_forwards_the_request_and_decodes_the_hex_audio_payload', async () => {
            await writeSecret(SECRET_KEYS.MINIMAX, 'fake-minimax-key');
            await writeSecret(SECRET_KEYS.MINIMAX_GROUP_ID, 'fake-group-id');
            mock.handler = (req, res) => {
                expect(req.url).toBe('/v1/t2a_v2?GroupId=fake-group-id');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ base_resp: { status_code: 0 }, data: { audio: '48656c6c6f' } }));
            };

            const response = await client.postJson('/api/minimax/generate-voice', {
                text: 'hello',
                voiceId: 'voice-1',
                apiHost: mock.url,
            });
            expect(response.status).toBe(200);
            expect(response.headers.get('content-type')).toBe('audio/mpeg');
            expect(Buffer.from(await response.arrayBuffer())).toEqual(Buffer.from('Hello'));
        }, CASE_TIMEOUT_MS);
    });

    describe('volcengine.js generate-voice', () => {
        test('generate_voice_without_app_id_or_access_key_returns_403', async () => {
            const response = await client.postJson('/api/volcengine/generate-voice', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('generate_voice_with_credentials_but_missing_fields_returns_400', async () => {
            await writeSecret(SECRET_KEYS.VOLCENGINE_APP_ID, 'fake-app-id');
            await writeSecret(SECRET_KEYS.VOLCENGINE_ACCESS_KEY, 'fake-access-key');
            const response = await client.postJson('/api/volcengine/generate-voice', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('generate_voice_with_a_configured_endpoint_decodes_the_streamed_base64_audio_chunks', async () => {
            mock.handler = (req, res) => {
                expect(req.headers['x-api-app-id']).toBe('fake-app-id');
                res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
                const chunk = JSON.stringify({ code: 0, data: Buffer.from('ab').toString('base64') });
                res.end(chunk + '\n');
            };

            const response = await client.postJson('/api/volcengine/generate-voice', {
                provider_endpoint: mock.url,
                resource_id: 'res-1',
                text: 'hello',
                voice_speaker: 'speaker-1',
            });
            expect(response.status).toBe(200);
            expect(response.headers.get('content-type')).toBe('audio/mpeg');
            expect(Buffer.from(await response.arrayBuffer())).toEqual(Buffer.from('ab'));
        }, CASE_TIMEOUT_MS);
    });

    describe('horde.js (needs a live provider beyond the routes below; base URLs are hardcoded, not configurable)', () => {
        test('sd_samplers_is_a_fully_local_route_returning_the_stable_sampler_enum', async () => {
            const response = await client.postJson('/api/horde/sd-samplers', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual([
                'lcm', 'k_lms', 'k_heun', 'k_euler_a', 'k_euler', 'k_dpm_2', 'k_dpm_2_a', 'DDIM',
                'PLMS', 'k_dpm_fast', 'k_dpm_adaptive', 'k_dpmpp_2s_a', 'k_dpmpp_2m', 'dpmsolver', 'k_dpmpp_sde',
            ]);
        }, CASE_TIMEOUT_MS);

        test('user_info_without_a_configured_token_returns_anonymous_true_with_no_network_call', async () => {
            const response = await client.postJson('/api/horde/user-info', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ anonymous: true });
        }, CASE_TIMEOUT_MS);

        test('generate_image_without_a_prompt_returns_400_before_any_network_call', async () => {
            const response = await client.postJson('/api/horde/generate-image', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);
    });
});

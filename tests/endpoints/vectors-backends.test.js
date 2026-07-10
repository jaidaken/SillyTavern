import fs from 'node:fs';
import path from 'node:path';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { MockServer } from '../util/mock-server.js';
import { SillyTavernServer, DEFAULT_HANDLE, allocatePort } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
// First request per transformers task downloads the model for real (whisper-small is the slowest); later requests hit the in-process cache.
const MODEL_CASE_TIMEOUT_MS = 150000;

describe('SillyTavern vectors, classify, speech and backend proxy endpoints', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {MockServer} */
    let upstream;
    /** @type {SillyTavernClient} */
    let client;
    /** @type {string} */
    let upstreamBase;

    beforeAll(async () => {
        const upstreamPort = await allocatePort();
        upstream = new MockServer({ port: upstreamPort, host: '127.0.0.1' });
        await upstream.start();
        upstreamBase = `http://127.0.0.1:${upstreamPort}`;

        server = new SillyTavernServer();
        await server.start();

        client = new SillyTavernClient(server.baseUrl);
        await client.fetchCsrfToken();
        const login = await client.login(DEFAULT_HANDLE);
        if (login.status !== 200) {
            throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
        }
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await upstream?.stop();
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    describe('vector store', () => {
        const collectionId = 'P8VectorCollection';
        const source = 'koboldcpp';
        const model = 'P8VectorModel';
        const text = 'hello vector world';
        const hash = 778899;
        const embeddings = { [text]: [0.11, 0.22, 0.33, 0.44] };
        const indexDir = () => path.join(server.userDirectory(), 'vectors', source, collectionId, model);

        test('vector_insert_writes_an_item_and_creates_the_index_on_disk', async () => {
            const response = await client.postJson('/api/vector/insert', {
                collectionId,
                source,
                model,
                embeddings,
                items: [{ hash, text, index: 0 }],
            });
            expect(response.status).toBe(200);
            expect(fs.existsSync(indexDir())).toBe(true);
        }, CASE_TIMEOUT_MS);

        test('vector_insert_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/insert', { collectionId, source, model, embeddings, items: [] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_insert_without_an_items_array_is_rejected', async () => {
            const response = await client.postJson('/api/vector/insert', { collectionId, source, model });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_list_returns_the_hash_of_the_inserted_item', async () => {
            const response = await client.postJson('/api/vector/list', { collectionId, source, model });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual([hash]);
        }, CASE_TIMEOUT_MS);

        test('vector_list_without_a_collection_id_is_rejected', async () => {
            const response = await client.postJson('/api/vector/list', { source, model });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_list_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/list', { collectionId, source, model });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_query_returns_the_matching_item_metadata_and_hash', async () => {
            const response = await client.postJson('/api/vector/query', {
                collectionId, source, model, embeddings, searchText: text, topK: 5, threshold: 0,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({
                metadata: [{ hash, text, index: 0 }],
                hashes: [hash],
            });
        }, CASE_TIMEOUT_MS);

        test('vector_query_without_search_text_is_rejected', async () => {
            const response = await client.postJson('/api/vector/query', { collectionId, source, model });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_query_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/query', { collectionId, source, model, searchText: text });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_query_multi_groups_results_by_collection_id', async () => {
            const response = await client.postJson('/api/vector/query-multi', {
                collectionIds: [collectionId], source, model, embeddings, searchText: text, topK: 5, threshold: 0,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({
                [collectionId]: { hashes: [hash], metadata: [{ hash, text, index: 0 }] },
            });
        }, CASE_TIMEOUT_MS);

        test('vector_query_multi_without_a_collection_ids_array_is_rejected', async () => {
            const response = await client.postJson('/api/vector/query-multi', { collectionId, source, model, searchText: text });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_query_multi_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/query-multi', { collectionIds: [collectionId], source, model, searchText: text });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_delete_removes_the_item_by_hash', async () => {
            const response = await client.postJson('/api/vector/delete', { collectionId, hashes: [hash], source, model });
            expect(response.status).toBe(200);

            const listed = await client.postJson('/api/vector/list', { collectionId, source, model });
            expect(await listed.json()).toEqual([]);
        }, CASE_TIMEOUT_MS);

        test('vector_delete_without_a_hashes_array_is_rejected', async () => {
            const response = await client.postJson('/api/vector/delete', { collectionId, source, model });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_delete_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/delete', { collectionId, hashes: [hash], source, model });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_purge_removes_the_collection_index_from_disk', async () => {
            await client.postJson('/api/vector/insert', {
                collectionId, source, model, embeddings, items: [{ hash, text, index: 0 }],
            });
            expect(fs.existsSync(indexDir())).toBe(true);

            const response = await client.postJson('/api/vector/purge', { collectionId });
            expect(response.status).toBe(200);
            expect(fs.existsSync(path.join(server.userDirectory(), 'vectors', source, collectionId))).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('vector_purge_without_a_collection_id_is_rejected', async () => {
            const response = await client.postJson('/api/vector/purge', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('vector_purge_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/purge', { collectionId });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('vector_purge_all_removes_every_source_directory_from_disk', async () => {
            const purgeAllCollectionId = 'P8PurgeAllCollection';
            await client.postJson('/api/vector/insert', {
                collectionId: purgeAllCollectionId, source, model, embeddings, items: [{ hash, text, index: 0 }],
            });
            const sourceDir = path.join(server.userDirectory(), 'vectors', source);
            expect(fs.existsSync(sourceDir)).toBe(true);

            const response = await client.postJson('/api/vector/purge-all', {});
            expect(response.status).toBe(200);
            expect(fs.existsSync(sourceDir)).toBe(false);
        }, CASE_TIMEOUT_MS);

        test('vector_purge_all_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/vector/purge-all', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('classify', () => {
        test('classify_labels_returns_the_goemotions_label_set', async () => {
            const response = await client.postJson('/api/extra/classify/labels', {});
            expect(response.status).toBe(200);
            const { labels } = await response.json();
            expect(labels).toHaveLength(28);
            expect(labels).toEqual(expect.arrayContaining(['joy', 'neutral', 'admiration']));
        }, MODEL_CASE_TIMEOUT_MS);

        test('classify_labels_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extra/classify/labels', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('classify_returns_a_score_sorted_classification_for_the_given_text', async () => {
            const response = await client.postJson('/api/extra/classify/', { text: 'I am so happy today!' });
            expect(response.status).toBe(200);
            const { classification } = await response.json();
            expect(classification.length).toBeGreaterThan(0);
            expect(classification.length).toBeLessThanOrEqual(5);
            for (const entry of classification) {
                expect(typeof entry.label).toBe('string');
                expect(typeof entry.score).toBe('number');
            }
            for (let i = 1; i < classification.length; i++) {
                expect(classification[i - 1].score).toBeGreaterThanOrEqual(classification[i].score);
            }
        }, CASE_TIMEOUT_MS);

        test('classify_caches_the_result_for_a_repeated_text', async () => {
            const text = 'The cache marker text for classification.';
            const first = await client.postJson('/api/extra/classify/', { text });
            expect(first.status).toBe(200);
            const second = await client.postJson('/api/extra/classify/', { text });
            expect(second.status).toBe(200);
            expect(await second.json()).toEqual(await first.json());
        }, CASE_TIMEOUT_MS);

        test('classify_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/extra/classify/', { text: 'ignored' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('classify_without_text_returns_a_clean_server_error_not_a_crash', async () => {
            const response = await client.postJson('/api/extra/classify/', {});
            expect(response.status).toBe(500);
            expect(await response.text()).toBe('Internal Server Error');
        }, CASE_TIMEOUT_MS);
    });

    describe('speech', () => {
        test('speech_recognize_with_malformed_audio_data_returns_a_clean_server_error_not_a_crash', async () => {
            const response = await client.postJson('/api/speech/recognize', { audio: 'not-a-real-data-uri' });
            expect(response.status).toBe(500);
            expect(await response.text()).toBe('Internal Server Error');
        }, MODEL_CASE_TIMEOUT_MS);

        test('speech_recognize_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/speech/recognize', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('speech_recognize_without_audio_returns_a_clean_server_error', async () => {
            const response = await client.postJson('/api/speech/recognize', {});
            expect(response.status).toBe(500);
            expect(await response.text()).toBe('Internal Server Error');
        }, CASE_TIMEOUT_MS);

        test('speech_synthesize_without_speaker_embeddings_returns_a_clean_server_error', async () => {
            const response = await client.postJson('/api/speech/synthesize', { text: 'hello world' });
            expect(response.status).toBe(500);
            expect(await response.text()).toBe('Internal Server Error');
        }, MODEL_CASE_TIMEOUT_MS);

        test('speech_synthesize_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/speech/synthesize', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('backends: chat-completions', () => {
        test('chat_completions_generate_with_custom_source_forwards_the_request_and_returns_the_upstream_response', async () => {
            const response = await client.postJson('/api/backends/chat-completions/generate', {
                chat_completion_source: 'custom',
                custom_url: `${upstreamBase}/v1`,
                model: 'gpt-4o',
                max_tokens: 7,
                messages: [{ role: 'user', content: 'Hello, proxy!' }],
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({
                choices: [{
                    finish_reason: 'stop',
                    index: 0,
                    message: {
                        role: 'assistant',
                        reasoning_content: 'gpt-4o\n1\n7',
                        content: 'Hello, proxy!',
                    },
                }],
                created: 0,
                model: 'gpt-4o',
            });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_generate_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/chat-completions/generate', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_completions_generate_with_an_unsupported_source_is_rejected', async () => {
            const response = await client.postJson('/api/backends/chat-completions/generate', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: true });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_status_with_custom_source_lists_the_upstream_models', async () => {
            const response = await client.postJson('/api/backends/chat-completions/status', {
                chat_completion_source: 'custom',
                custom_url: `${upstreamBase}/v1`,
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ object: 'list', data: [{ id: 'mock-model', object: 'model' }] });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_status_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/chat-completions/status', {});
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_completions_status_with_an_unsupported_source_is_rejected', async () => {
            const response = await client.postJson('/api/backends/chat-completions/status', {});
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: true });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_bias_maps_encoded_tokens_to_their_bias_values', async () => {
            const response = await client.postJson('/api/backends/chat-completions/bias', [
                { text: 'a', value: 1 },
                { text: 'b', value: -1 },
            ]);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ '64': 1, '65': -1 });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_bias_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/chat-completions/bias', []);
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_completions_bias_with_a_non_array_body_is_rejected', async () => {
            const response = await client.postJson('/api/backends/chat-completions/bias', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('chat_completions_process_merges_consecutive_same_role_messages', async () => {
            const response = await client.postJson('/api/backends/chat-completions/process', {
                messages: [{ role: 'user', content: 'a' }, { role: 'user', content: 'b' }],
                type: 'merge',
            });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ messages: [{ role: 'user', content: 'a\n\nb' }] });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_process_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/chat-completions/process', { messages: [], type: 'merge' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('chat_completions_process_with_a_non_array_messages_is_rejected', async () => {
            const response = await client.postJson('/api/backends/chat-completions/process', { messages: 'not-an-array', type: 'merge' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Invalid messages format' });
        }, CASE_TIMEOUT_MS);

        test('chat_completions_process_with_an_unknown_type_is_rejected', async () => {
            const response = await client.postJson('/api/backends/chat-completions/process', { messages: [], type: 'not-a-real-type' });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: 'Unknown processing type' });
        }, CASE_TIMEOUT_MS);
    });

    describe('backends: kobold', () => {
        test('kobold_status_reports_fallback_values_when_extra_endpoints_are_unavailable', async () => {
            const response = await client.postJson('/api/backends/kobold/status', { api_server: upstreamBase });
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body).toEqual({ koboldUnitedVersion: '0.0.0', koboldCppVersion: '0.0', model: 'no_connection' });
        }, CASE_TIMEOUT_MS);

        test('kobold_status_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/kobold/status', { api_server: upstreamBase });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('kobold_status_without_api_server_is_rejected_with_bad_request', async () => {
            const response = await client.postJson('/api/backends/kobold/status', {});
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Bad Request');
        }, CASE_TIMEOUT_MS);

        test('kobold_status_with_a_non_string_api_server_is_rejected_with_bad_request', async () => {
            const response = await client.postJson('/api/backends/kobold/status', { api_server: 12345 });
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Bad Request');
        }, CASE_TIMEOUT_MS);

        test('kobold_generate_against_an_upstream_without_the_generate_route_is_rejected_with_the_upstream_error', async () => {
            const response = await client.postJson('/api/backends/kobold/generate', { api_server: upstreamBase, prompt: 'hi', max_length: 10 });
            expect(response.status).toBe(400);
            expect(await response.json()).toEqual({ error: { message: '' } });
        }, CASE_TIMEOUT_MS);

        test('kobold_generate_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/kobold/generate', { api_server: upstreamBase, prompt: 'hi' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('kobold_generate_without_api_server_is_rejected_with_bad_request', async () => {
            const response = await client.postJson('/api/backends/kobold/generate', {});
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Bad Request');
        }, CASE_TIMEOUT_MS);

        test('kobold_embed_without_a_server_is_rejected', async () => {
            const response = await client.postJson('/api/backends/kobold/embed', {});
            expect(response.status).toBe(400);
            expect(await response.text()).toBe('Bad Request');
        }, CASE_TIMEOUT_MS);

        test('kobold_embed_against_an_unsupported_upstream_endpoint_returns_a_clean_server_error', async () => {
            const response = await client.postJson('/api/backends/kobold/embed', { server: upstreamBase, items: ['hi'] });
            expect(response.status).toBe(500);
            expect(await response.text()).toBe('Internal server error');
        }, CASE_TIMEOUT_MS);

        test('kobold_embed_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/kobold/embed', { server: upstreamBase, items: ['hi'] });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('kobold_transcribe_audio_without_server_or_file_is_rejected', async () => {
            const response = await client.postJson('/api/backends/kobold/transcribe-audio', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('kobold_transcribe_audio_without_a_file_is_rejected', async () => {
            const response = await client.postJson('/api/backends/kobold/transcribe-audio', { server: upstreamBase });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('kobold_transcribe_audio_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/kobold/transcribe-audio', { server: upstreamBase });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);
    });

    describe('backends: text-completions', () => {
        test('text_completions_status_lists_models_from_an_ooba_style_upstream', async () => {
            const response = await client.postJson('/api/backends/text-completions/status', { api_server: upstreamBase, api_type: 'ooba' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ result: 'mock-model', data: [{ id: 'mock-model', object: 'model' }] });
        }, CASE_TIMEOUT_MS);

        test('text_completions_status_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/text-completions/status', { api_server: upstreamBase, api_type: 'ooba' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('text_completions_status_without_api_server_reports_a_clean_offline_result', async () => {
            const response = await client.postJson('/api/backends/text-completions/status', {});
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ online: false });
        }, CASE_TIMEOUT_MS);

        test('text_completions_props_without_a_server_url_is_rejected', async () => {
            const response = await client.postJson('/api/backends/text-completions/props', {});
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('text_completions_props_against_an_upstream_without_the_props_route_is_rejected', async () => {
            const response = await client.postJson('/api/backends/text-completions/props', { server_url: upstreamBase });
            expect(response.status).toBe(400);
        }, CASE_TIMEOUT_MS);

        test('text_completions_props_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/text-completions/props', { server_url: upstreamBase });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('text_completions_generate_against_an_ooba_style_upstream_without_the_completions_route_returns_an_embedded_error', async () => {
            const response = await client.postJson('/api/backends/text-completions/generate', { api_server: upstreamBase, api_type: 'ooba', prompt: 'hi' });
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ error: true, status: 404, response: '' });
        }, CASE_TIMEOUT_MS);

        test('text_completions_generate_is_rejected_for_anonymous_client', async () => {
            const anonymous = new SillyTavernClient(server.baseUrl);
            const response = await anonymous.postJson('/api/backends/text-completions/generate', { api_server: upstreamBase, api_type: 'ooba', prompt: 'hi' });
            expect(response.status).toBe(403);
        }, CASE_TIMEOUT_MS);

        test('text_completions_generate_without_api_server_reflects_the_thrown_error_message', async () => {
            const response = await client.postJson('/api/backends/text-completions/generate', {});
            expect(response.status).toBe(200);
            const body = await response.json();
            expect(body.error).toBe(true);
            expect(body.status).toBe('UNKNOWN');
            expect(body.response).toMatch(/Cannot read properties of undefined/);
        }, CASE_TIMEOUT_MS);
    });
});

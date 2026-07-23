import { describe, test, expect, beforeAll, afterAll, beforeEach } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { loginAs } from '../util/sessions.js';
import { SseStream } from '../util/sse-stream.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 60000;
const CARD = 'P2C2Card';

describe('message mutation client events', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {import('../util/st-client.js').SillyTavernClient} */
    let client;
    /** @type {SseStream|null} */
    let stream = null;
    let avatar = '';
    let chatFile = '';
    let chatIndex = 0;

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start({ clientEvents: { heartbeatSeconds: 60, probeSeconds: 3600 } });
        client = await loginAs(server.baseUrl, DEFAULT_HANDLE);

        const form = new FormData();
        form.append('ch_name', CARD);
        form.append('file_name', CARD);
        const created = await client.postForm('/api/characters/create', form);
        expect(created.status).toBe(200);
        avatar = (await created.text()).trim();
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await stream?.close();
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    // Each case gets its own chat file so a mutation cannot disturb the next one.
    beforeEach(async () => {
        await stream?.close();
        chatIndex += 1;
        chatFile = `p2c2-chat-${chatIndex}`;

        const saved = await client.postJson('/api/chats/save', {
            avatar_url: avatar,
            file_name: chatFile,
            chat: [
                { user_name: 'User', character_name: CARD, create_date: '2026-01-01', chat_metadata: {} },
                { name: 'User', is_user: true, mes: 'first' },
                { name: CARD, is_user: false, mes: 'second', swipes: ['second', 'alternate'], swipe_id: 0 },
            ],
        });
        expect(saved.status).toBe(200);

        stream = await SseStream.open(server.baseUrl, '/api/events', {
            cookieHeader: client.cookieHeader,
            csrfToken: client.csrfToken,
        });
        await stream.waitForFrame(frame => frame.event === 'hello');
    });

    /**
     * Calls a mutation route and returns the event it produced.
     * @param {string} route Route under /api/chats
     * @param {object} body Extra request fields
     * @returns {Promise<object>} The parsed chat-changed payload
     */
    async function mutateAndReadEvent(route, body) {
        const response = await client.postJson(`/api/chats${route}`, {
            avatar_url: avatar,
            file_name: chatFile,
            ...body,
        });
        expect(response.status).toBe(200);

        const event = await stream.waitForFrame(
            frame => frame.event === 'chat-changed' && JSON.parse(frame.data).action === 'message-mutation',
        );
        return JSON.parse(event.data);
    }

    test('message_edit_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/edit', { index: 0, text: 'edited text' });

        expect(payload.op).toBe('/message/edit');
        expect(payload.card).toBe(CARD);
    }, CASE_TIMEOUT_MS);

    test('message_delete_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/delete', { index: 0 });

        expect(payload.op).toBe('/message/delete');
    }, CASE_TIMEOUT_MS);

    test('message_move_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/move', { index: 1, direction: 'up' });

        expect(payload.op).toBe('/message/move');
    }, CASE_TIMEOUT_MS);

    test('message_hide_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/hide', { index: 0, hidden: true });

        expect(payload.op).toBe('/message/hide');
    }, CASE_TIMEOUT_MS);

    test('message_swipe_select_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/swipe-select', { index: 1, swipe_id: 1 });

        expect(payload.op).toBe('/message/swipe-select');
    }, CASE_TIMEOUT_MS);

    test('message_checkpoint_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/message/checkpoint', { index: 0, name: 'mark' });

        expect(payload.op).toBe('/message/checkpoint');
    }, CASE_TIMEOUT_MS);

    test('metadata_edit_emits_a_message_mutation_event', async () => {
        const payload = await mutateAndReadEvent('/metadata', { note_prompt: 'a note' });

        expect(payload.op).toBe('/metadata');
    }, CASE_TIMEOUT_MS);
});

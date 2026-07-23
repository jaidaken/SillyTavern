import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';
import { openTwoHandleSessions, loginAs } from '../util/sessions.js';
import { SseStream } from '../util/sse-stream.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 60000;
const SECOND_HANDLE = 'p2asecond';
const REVOKED_HANDLE = 'p2arevoked';
const HEARTBEAT_SECONDS = 1;
const RING_CAPACITY = 64;
const MAX_CONNECTIONS_PER_HANDLE = 16;

// Long enough for the observed handle to have received an event if the boundary leaked.
const QUIET_WINDOW_MS = 750;

describe('SillyTavern client event stream', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let first;
    /** @type {SillyTavernClient} */
    let second;
    /** @type {SseStream[]} */
    const opened = [];

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start({ clientEvents: { heartbeatSeconds: HEARTBEAT_SECONDS } });
        ({ first, second } = await openTwoHandleSessions(server, SECOND_HANDLE));
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await Promise.all(opened.map(stream => stream.close()));
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    /**
     * Opens a stream carrying a client's session and closes it during teardown.
     * @param {SillyTavernClient} client Logged-in client
     * @param {object} [options] Extra stream options
     * @returns {Promise<SseStream>} An open stream
     */
    async function openStream(client, options = {}) {
        const stream = await SseStream.open(server.baseUrl, '/api/events', {
            cookieHeader: client.cookieHeader,
            csrfToken: client.csrfToken,
            ...options,
        });
        opened.push(stream);
        return stream;
    }

    /**
     * @param {SseStream} stream Stream to read from
     * @returns {Promise<number>} The connection id issued at stream open
     */
    async function connectionIdOf(stream) {
        const hello = await stream.waitForFrame(frame => frame.event === 'hello');
        return JSON.parse(hello.data).connectionId;
    }

    /**
     * @param {SillyTavernClient} client Client whose settings are saved
     * @returns {Promise<void>} Resolves once the save succeeded
     */
    async function saveSettings(client) {
        const response = await client.postJson('/api/settings/save', { probe: Date.now() });
        expect(response.status).toBe(200);
    }

    test('stream_is_not_compressed_and_delivers_frames_incrementally', async () => {
        // The request carries a browser-typical Accept-Encoding on purpose. Without it the global
        // compression() middleware never engages and this test would pass over a channel that is
        // dead in every real browser, so this header must never be dropped from the helper.
        const stream = await openStream(first);
        await connectionIdOf(stream);

        expect(stream.status).toBe(200);
        expect(stream.contentType).toContain('text/event-stream');
        expect(stream.contentEncoding).toBe('');

        await saveSettings(first);
        await stream.waitForFrame(frame => frame.event === 'settings-changed');
        await saveSettings(first);
        await stream.waitForFrameCount(3);

        // Arrival while the response is still open is the property under test. A compressed
        // stream delivers nothing until it ends, so the waits above would time out instead.
        expect(stream.ended).toBe(false);
        expect(stream.arrivedIncrementally(3, 1)).toBe(true);
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('event_for_one_handle_never_reaches_a_stream_owned_by_another_handle', async () => {
        const streamA = await openStream(first);
        const streamB = await openStream(second);
        await connectionIdOf(streamA);
        await connectionIdOf(streamB);

        const beforeB = streamB.frames.length;
        await saveSettings(first);

        const received = await streamA.waitForFrame(frame => frame.event === 'settings-changed');
        expect(JSON.parse(received.data).source).toBe('settings-save');

        const leaked = await streamB.framesDuring(QUIET_WINDOW_MS);
        expect(leaked).toEqual([]);
        expect(streamB.frames.length).toBe(beforeB);
        expect(streamB.frames.some(frame => frame.event === 'settings-changed')).toBe(false);

        await streamA.close();
        await streamB.close();
    }, CASE_TIMEOUT_MS);

    test('closed_stream_is_removed_from_the_registry', async () => {
        const keep = await openStream(second);
        const transient = await openStream(second);
        const keepId = await connectionIdOf(keep);
        await connectionIdOf(transient);

        const before = await second.postJson('/api/events/visibility', { id: keepId, visible: false });
        const openBefore = (await before.json()).connections;
        expect(openBefore).toBeGreaterThanOrEqual(2);

        await transient.close();
        await new Promise(resolve => setTimeout(resolve, QUIET_WINDOW_MS));

        const after = await second.postJson('/api/events/visibility', { id: keepId, visible: false });
        expect((await after.json()).connections).toBe(openBefore - 1);

        await keep.close();
    }, CASE_TIMEOUT_MS);

    test('visibility_beacon_counts_only_streams_reporting_a_visible_tab', async () => {
        const stream = await openStream(first);
        const id = await connectionIdOf(stream);

        const hidden = await first.postJson('/api/events/visibility', { id, visible: false });
        expect(hidden.status).toBe(200);
        expect((await hidden.json()).visible).toBe(0);

        const shown = await first.postJson('/api/events/visibility', { id, visible: true });
        expect((await shown.json()).visible).toBe(1);

        const hiddenAgain = await first.postJson('/api/events/visibility', { id, visible: false });
        expect((await hiddenAgain.json()).visible).toBe(0);

        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('visibility_beacon_rejects_a_connection_id_belonging_to_another_handle', async () => {
        const streamA = await openStream(first);
        const idA = await connectionIdOf(streamA);

        const response = await second.postJson('/api/events/visibility', { id: idA, visible: true });

        expect(response.status).toBe(404);
        await streamA.close();
    }, CASE_TIMEOUT_MS);

    test('visibility_beacon_rejects_a_body_that_is_not_a_json_object', async () => {
        const response = await first.postRaw('/api/events/visibility', 'id=1&visible=true', 'text/plain');

        expect(response.status).toBe(400);
        expect((await response.json()).error).toContain('JSON body');
    }, CASE_TIMEOUT_MS);

    test('visibility_beacon_rejects_unknown_fields', async () => {
        const stream = await openStream(first);
        const id = await connectionIdOf(stream);

        const response = await first.postJson('/api/events/visibility', { id, visible: true, handle: DEFAULT_HANDLE });

        expect(response.status).toBe(400);
        expect((await response.json()).error).toContain('handle');
        await stream.close();
    }, CASE_TIMEOUT_MS);

    test('visibility_beacon_rejects_a_non_integer_connection_id', async () => {
        const response = await first.postJson('/api/events/visibility', { id: 'first', visible: true });

        expect(response.status).toBe(400);
        expect((await response.json()).error).toContain('positive integer');
    }, CASE_TIMEOUT_MS);

    test('stream_for_an_account_disabled_mid_stream_is_closed_on_the_next_heartbeat', async () => {
        const created = await first.postJson('/api/users/create', {
            handle: REVOKED_HANDLE,
            name: 'Revoked',
            password: '',
            admin: false,
        });
        expect(created.status).toBe(200);

        const revoked = await loginAs(server.baseUrl, REVOKED_HANDLE);
        const stream = await openStream(revoked);
        await connectionIdOf(stream);
        expect(stream.ended).toBe(false);

        const disabled = await first.postJson('/api/users/disable', { handle: REVOKED_HANDLE });
        expect(disabled.status).toBe(204);

        const closed = await stream.waitForEnd(HEARTBEAT_SECONDS * 1000 * 6);
        expect(closed).toBe(true);
        expect(stream.frames.some(frame => frame.event === 'settings-changed')).toBe(false);
    }, CASE_TIMEOUT_MS);

    test('resume_replays_only_the_events_the_client_missed', async () => {
        const stream = await openStream(second);
        await connectionIdOf(stream);

        await saveSettings(second);
        const first_event = await stream.waitForFrame(frame => frame.event === 'settings-changed');
        const resumeFrom = Number(first_event.id);
        await stream.close();

        await saveSettings(second);
        await saveSettings(second);

        const resumed = await openStream(second, { lastEventId: String(resumeFrom) });
        const replayed = await resumed.waitForFrameCount(3);

        const events = replayed.filter(frame => frame.event === 'settings-changed');
        expect(events).toHaveLength(2);
        expect(events.map(frame => Number(frame.id))).toEqual([resumeFrom + 1, resumeFrom + 2]);
        expect(replayed.some(frame => frame.event === 'resync')).toBe(false);
        await resumed.close();
    }, CASE_TIMEOUT_MS);

    test('resume_from_an_id_the_ring_can_no_longer_cover_emits_resync', async () => {
        const client = await loginAs(server.baseUrl, SECOND_HANDLE);
        for (let index = 0; index < RING_CAPACITY + 4; index++) {
            await saveSettings(client);
        }

        const resumed = await openStream(client, { lastEventId: '1' });
        const resync = await resumed.waitForFrame(frame => frame.event === 'resync');

        expect(JSON.parse(resync.data).reason).toBe('replay-unavailable');
        expect(resumed.frames.some(frame => frame.event === 'settings-changed')).toBe(false);
        await resumed.close();
    }, CASE_TIMEOUT_MS);

    test('resume_from_an_id_ahead_of_the_server_emits_resync_and_later_events_still_arrive', async () => {
        const client = await loginAs(server.baseUrl, SECOND_HANDLE);
        const resumed = await openStream(client, { lastEventId: '999999' });
        await resumed.waitForFrame(frame => frame.event === 'resync');

        await saveSettings(client);
        const live = await resumed.waitForFrame(frame => frame.event === 'settings-changed');

        expect(Number(live.id)).toBeLessThan(999999);
        expect(Number(live.id)).toBeGreaterThan(0);
        await resumed.close();
    }, CASE_TIMEOUT_MS);

    test('connection_cap_evicts_the_oldest_stream_instead_of_locking_the_client_out', async () => {
        const client = await loginAs(server.baseUrl, DEFAULT_HANDLE);
        for (const stream of opened.splice(0, opened.length)) {
            await stream.close();
        }
        await new Promise(resolve => setTimeout(resolve, QUIET_WINDOW_MS));

        /** @type {SseStream[]} */
        const streams = [];
        for (let index = 0; index < MAX_CONNECTIONS_PER_HANDLE; index++) {
            const stream = await SseStream.open(server.baseUrl, '/api/events', {
                cookieHeader: client.cookieHeader,
                csrfToken: client.csrfToken,
            });
            streams.push(stream);
            await connectionIdOf(stream);
        }
        expect(streams[0].ended).toBe(false);

        const overflow = await SseStream.open(server.baseUrl, '/api/events', {
            cookieHeader: client.cookieHeader,
            csrfToken: client.csrfToken,
        });
        const overflowId = await connectionIdOf(overflow);

        expect(overflow.status).toBe(200);
        expect(await streams[0].waitForEnd(QUIET_WINDOW_MS * 4)).toBe(true);

        const beacon = await client.postJson('/api/events/visibility', { id: overflowId, visible: true });
        expect(beacon.status).toBe(200);
        expect((await beacon.json()).connections).toBe(MAX_CONNECTIONS_PER_HANDLE);

        await Promise.all([...streams, overflow].map(stream => stream.close()));
    }, CASE_TIMEOUT_MS);

    test('stream_without_a_session_is_denied', async () => {
        const anonymous = new SillyTavernClient(server.baseUrl);
        await anonymous.fetchCsrfToken();

        const response = await anonymous.get('/api/events');

        expect(response.status).toBe(403);
        await response.arrayBuffer();
    }, CASE_TIMEOUT_MS);
});

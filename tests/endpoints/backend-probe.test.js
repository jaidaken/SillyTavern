import http from 'node:http';

import { describe, test, expect, beforeAll, afterAll, beforeEach } from '@jest/globals';

import { SillyTavernServer, DEFAULT_HANDLE } from '../util/st-server.js';
import { loginAs } from '../util/sessions.js';
import { SseStream } from '../util/sse-stream.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 60000;
const PROBE_SECONDS = 1;
const PROBE_MS = PROBE_SECONDS * 1000;

/**
 * Stub text completion backend. Counts probes and can be switched between reachable and failing,
 * so the tests never depend on a real backend being installed.
 */
class StubBackend {
    #server;
    #port = 0;
    /** @type {import('node:http').ServerResponse[]} */
    #stalled = [];
    requests = 0;
    healthy = true;
    stalling = false;

    /** @returns {string} Base URL clients should be pointed at. */
    get url() {
        return `http://127.0.0.1:${this.#port}`;
    }

    /** @returns {Promise<void>} Resolves once the stub is listening. */
    async start() {
        this.#server = http.createServer((request, response) => {
            if (!request.url?.startsWith('/v1/models')) {
                response.writeHead(404).end();
                return;
            }
            this.requests += 1;
            // A wedged backend accepts the connection and never answers, which is the case a
            // connection-refused stub cannot reach: only the probe timeout can end it.
            if (this.stalling) {
                this.#stalled.push(response);
                return;
            }
            if (!this.healthy) {
                response.writeHead(500).end();
                return;
            }
            response.writeHead(200, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify({ data: [{ id: 'stub-model' }] }));
        });
        await new Promise(resolve => this.#server.listen(0, '127.0.0.1', () => resolve(undefined)));
        const address = this.#server.address();
        if (address === null || typeof address === 'string') {
            throw new Error('Failed to read the stub backend address.');
        }
        this.#port = address.port;
    }

    /** Releases every held-open request so the stub can shut down. */
    releaseStalled() {
        for (const response of this.#stalled.splice(0, this.#stalled.length)) {
            response.destroy();
        }
    }

    /** @returns {Promise<void>} Resolves once the stub has stopped. */
    async stop() {
        this.releaseStalled();
        await new Promise(resolve => this.#server.close(resolve));
    }
}

describe('presence-gated backend probe', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {StubBackend} */
    let backend;
    /** @type {import('../util/st-client.js').SillyTavernClient} */
    let client;
    /** @type {SseStream[]} */
    let opened = [];

    beforeAll(async () => {
        backend = new StubBackend();
        await backend.start();

        server = new SillyTavernServer();
        await server.start({
            clientEvents: { heartbeatSeconds: 60, probeSeconds: PROBE_SECONDS, probeTimeoutSeconds: 2 },
        });
        client = await loginAs(server.baseUrl, DEFAULT_HANDLE);
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await Promise.all(opened.map(stream => stream.close()));
        await server?.stop();
        await backend?.stop();
    }, BOOT_TIMEOUT_MS);

    beforeEach(async () => {
        await Promise.all(opened.map(stream => stream.close()));
        opened = [];
        backend.requests = 0;
        backend.healthy = true;
        backend.stalling = false;
        backend.releaseStalled();
        await new Promise(resolve => setTimeout(resolve, PROBE_MS));
        backend.requests = 0;
    });

    /**
     * @param {string} url Backend base URL to store in the user's settings
     * @returns {Promise<void>} Resolves once the connection is persisted
     */
    async function pointAtBackend(url) {
        const response = await client.postJson('/api/settings/set-connection', {
            api_type: 'generic',
            api_server: url,
        });
        expect(response.status).toBe(200);
    }

    /**
     * @returns {Promise<{stream: SseStream, connectionId: number}>} An open stream and its id
     */
    async function openStream() {
        const stream = await SseStream.open(server.baseUrl, '/api/events', {
            cookieHeader: client.cookieHeader,
            csrfToken: client.csrfToken,
        });
        opened.push(stream);
        const hello = await stream.waitForFrame(frame => frame.event === 'hello');
        return { stream, connectionId: JSON.parse(hello.data).connectionId };
    }

    /**
     * @param {number} connectionId Connection to report on
     * @param {boolean} visible Reported visibility
     * @returns {Promise<void>} Resolves once the beacon is accepted
     */
    async function reportVisible(connectionId, visible) {
        const response = await client.postJson('/api/events/visibility', { id: connectionId, visible });
        expect(response.status).toBe(200);
    }

    test('no_probe_runs_while_no_connection_reports_a_visible_tab', async () => {
        await pointAtBackend(backend.url);
        const { connectionId } = await openStream();
        await reportVisible(connectionId, false);

        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 4));

        expect(backend.requests).toBe(0);
    }, CASE_TIMEOUT_MS);

    test('arming_probes_immediately_rather_than_waiting_a_full_interval', async () => {
        await pointAtBackend(backend.url);
        const { stream, connectionId } = await openStream();

        const started = Date.now();
        await reportVisible(connectionId, true);
        const event = await stream.waitForFrame(frame => frame.event === 'backend-status');

        expect(JSON.parse(event.data).status).toBe('online');
        expect(Date.now() - started).toBeLessThan(PROBE_MS);
        expect(backend.requests).toBeGreaterThanOrEqual(1);
    }, CASE_TIMEOUT_MS);

    test('many_visible_connections_share_a_single_probe_per_interval', async () => {
        await pointAtBackend(backend.url);
        const first = await openStream();
        const second = await openStream();
        const third = await openStream();

        await reportVisible(first.connectionId, true);
        await reportVisible(second.connectionId, true);
        await reportVisible(third.connectionId, true);

        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 3));

        // Three visible tabs over three intervals would be nine probes if they were not coalesced.
        expect(backend.requests).toBeGreaterThanOrEqual(2);
        expect(backend.requests).toBeLessThanOrEqual(5);
    }, CASE_TIMEOUT_MS);

    test('an_unchanged_status_emits_no_further_events', async () => {
        await pointAtBackend(backend.url);
        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);

        await stream.waitForFrame(frame => frame.event === 'backend-status');
        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 3));

        const statusEvents = stream.frames.filter(frame => frame.event === 'backend-status');
        expect(statusEvents).toHaveLength(1);
        expect(backend.requests).toBeGreaterThanOrEqual(2);
    }, CASE_TIMEOUT_MS);

    test('a_status_change_emits_exactly_one_event_per_transition', async () => {
        await pointAtBackend(backend.url);
        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);

        const online = await stream.waitForFrame(frame => frame.event === 'backend-status');
        expect(JSON.parse(online.data).status).toBe('online');

        backend.healthy = false;
        const asleep = await stream.waitForFrame(
            frame => frame.event === 'backend-status' && JSON.parse(frame.data).status === 'asleep',
            PROBE_MS * 6,
        );
        expect(JSON.parse(asleep.data).status).toBe('asleep');

        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 3));
        const statusEvents = stream.frames.filter(frame => frame.event === 'backend-status');
        expect(statusEvents).toHaveLength(2);
    }, CASE_TIMEOUT_MS);

    test('an_unreachable_backend_reports_asleep_and_leaves_the_probe_running', async () => {
        await pointAtBackend('http://127.0.0.1:1');
        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);

        const asleep = await stream.waitForFrame(frame => frame.event === 'backend-status', PROBE_MS * 6);
        expect(JSON.parse(asleep.data).status).toBe('asleep');

        await pointAtBackend(backend.url);
        const recovered = await stream.waitForFrame(
            frame => frame.event === 'backend-status' && JSON.parse(frame.data).status === 'online',
            PROBE_MS * 8,
        );

        expect(JSON.parse(recovered.data).status).toBe('online');
    }, CASE_TIMEOUT_MS);

    test('a_backend_that_accepts_and_never_answers_is_reported_asleep_after_the_timeout', async () => {
        await pointAtBackend(backend.url);
        backend.stalling = true;

        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);

        const asleep = await stream.waitForFrame(frame => frame.event === 'backend-status', PROBE_MS * 10);
        expect(JSON.parse(asleep.data).status).toBe('asleep');

        // The 2s probe timeout outlasts the 1s interval, so without the in-flight guard the
        // stalled probes would stack up one per tick instead of waiting for the previous one.
        expect(backend.requests).toBeLessThanOrEqual(4);

        backend.stalling = false;
        backend.releaseStalled();
        const recovered = await stream.waitForFrame(
            frame => frame.event === 'backend-status' && JSON.parse(frame.data).status === 'online',
            PROBE_MS * 10,
        );

        expect(JSON.parse(recovered.data).status).toBe('online');
    }, CASE_TIMEOUT_MS);

    test('hiding_every_tab_stops_the_probe', async () => {
        await pointAtBackend(backend.url);
        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);
        await stream.waitForFrame(frame => frame.event === 'backend-status');

        await reportVisible(connectionId, false);
        await new Promise(resolve => setTimeout(resolve, PROBE_MS));
        const settled = backend.requests;

        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 3));

        expect(backend.requests).toBe(settled);
    }, CASE_TIMEOUT_MS);

    test('closing_the_only_visible_stream_stops_the_probe', async () => {
        await pointAtBackend(backend.url);
        const { stream, connectionId } = await openStream();
        await reportVisible(connectionId, true);
        await stream.waitForFrame(frame => frame.event === 'backend-status');

        await stream.close();
        await new Promise(resolve => setTimeout(resolve, PROBE_MS));
        const settled = backend.requests;

        await new Promise(resolve => setTimeout(resolve, PROBE_MS * 3));

        expect(backend.requests).toBe(settled);
    }, CASE_TIMEOUT_MS);
});

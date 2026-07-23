import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import express from 'express';
import compression from 'compression';

import { SseStream } from './util/sse-stream.js';

const FRAME_INTERVAL_MS = 120;
const FRAME_COUNT = 3;

// compression() ignores payloads under its 1kb threshold, so frames must be large
// enough that the encoder actually engages and the buffered arm is real.
const PADDING = 'x'.repeat(600);

/**
 * Writes SSE frames on an interval, optionally marking the response as not transformable.
 * @param {import('express').Request} request Express request
 * @param {import('express').Response} response Express response
 * @param {boolean} noTransform Whether to send Cache-Control: no-transform
 */
function streamFrames(request, response, noTransform) {
    response.setHeader('Content-Type', 'text/event-stream');
    response.setHeader('Cache-Control', noTransform ? 'no-cache, no-transform' : 'no-cache');
    response.flushHeaders();

    let sent = 0;
    const timer = setInterval(() => {
        sent += 1;
        response.write(`id: ${sent}\nevent: tick\ndata: {"frame":${sent},"pad":"${PADDING}"}\n\n`);
        if (sent >= FRAME_COUNT) {
            clearInterval(timer);
            response.end();
        }
    }, FRAME_INTERVAL_MS);

    request.on('close', () => clearInterval(timer));
}

describe('SseStream scaffolding', () => {
    /** @type {import('node:http').Server} */
    let server;
    let baseUrl = '';
    /** @type {SseStream[]} */
    const opened = [];

    beforeAll(async () => {
        const app = express();
        app.use(compression());

        app.get('/no-transform', (request, response) => streamFrames(request, response, true));
        app.get('/plain', (request, response) => streamFrames(request, response, false));

        app.get('/silent', (request, response) => {
            response.setHeader('Content-Type', 'text/event-stream');
            response.setHeader('Cache-Control', 'no-cache, no-transform');
            response.flushHeaders();
            request.on('close', () => response.end());
        });

        app.get('/late-frame', (request, response) => {
            response.setHeader('Content-Type', 'text/event-stream');
            response.setHeader('Cache-Control', 'no-cache, no-transform');
            response.flushHeaders();
            const timer = setTimeout(() => {
                response.write('id: 9\nevent: leak\ndata: {"leaked":true}\n\n');
            }, FRAME_INTERVAL_MS);
            request.on('close', () => clearTimeout(timer));
        });

        await new Promise((resolve) => {
            server = app.listen(0, '127.0.0.1', () => resolve(undefined));
        });
        const address = server.address();
        if (address === null || typeof address === 'string') {
            throw new Error('Failed to read the probe server address.');
        }
        baseUrl = `http://127.0.0.1:${address.port}`;
    });

    afterAll(async () => {
        await Promise.all(opened.map(stream => stream.close()));
        await new Promise(resolve => server.close(resolve));
    });

    /**
     * @param {string} pathname Route to open
     * @returns {Promise<SseStream>} An open stream, closed during teardown
     */
    async function open(pathname) {
        const stream = await SseStream.open(baseUrl, pathname);
        opened.push(stream);
        return stream;
    }

    test('reader_records_frames_incrementally_when_the_response_is_not_transformed', async () => {
        const stream = await open('/no-transform');
        const frames = await stream.waitForFrameCount(FRAME_COUNT);

        expect(stream.contentEncoding).toBe('');
        expect(frames).toHaveLength(FRAME_COUNT);
        expect(frames.map(frame => frame.event)).toEqual(['tick', 'tick', 'tick']);
        expect(JSON.parse(frames[0].data).frame).toBe(1);
        expect(frames[0].id).toBe('1');
        expect(stream.arrivedIncrementally()).toBe(true);
    });

    test('reader_reports_buffered_arrival_when_compression_transforms_the_response', async () => {
        const stream = await open('/plain');
        const frames = await stream.waitForFrameCount(FRAME_COUNT);

        expect(stream.contentEncoding).not.toBe('');
        expect(frames).toHaveLength(FRAME_COUNT);
        expect(stream.arrivedIncrementally()).toBe(false);
    });

    test('waitForFrame_resolves_with_the_matching_event', async () => {
        const stream = await open('/no-transform');
        const frame = await stream.waitForFrame(candidate => JSON.parse(candidate.data).frame === FRAME_COUNT);

        expect(frame.id).toBe(String(FRAME_COUNT));
        expect(frame.event).toBe('tick');
    });

    test('framesDuring_observes_nothing_on_a_silent_stream', async () => {
        const stream = await open('/silent');
        const observed = await stream.framesDuring(FRAME_INTERVAL_MS * 4);

        expect(observed).toEqual([]);
        expect(stream.status).toBe(200);
    });

    test('framesDuring_observes_a_frame_that_does_arrive', async () => {
        const stream = await open('/late-frame');
        const observed = await stream.framesDuring(FRAME_INTERVAL_MS * 4);

        expect(observed).toHaveLength(1);
        expect(observed[0].event).toBe('leak');
    });
});

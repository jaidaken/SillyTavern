import express from 'express';

import { getAccountVersion, getUserByHandle } from '../users.js';
import {
    RETRY_HINT_MS,
    connectionCount,
    registerConnection,
    resumeConnection,
    setVisibility,
    unregisterConnection,
    visibleCount,
} from '../client-events.js';

export const router = express.Router();

const VISIBILITY_FIELDS = new Set(['id', 'visible']);

/**
 * Reads the resume position from the SSE header, falling back to the query string.
 * @param {import('express').Request} request Express request
 * @returns {number|null} The last event id the client saw, or null for a fresh stream
 */
function readLastEventId(request) {
    const raw = request.headers['last-event-id'] ?? request.query.lastEventId;
    if (typeof raw !== 'string' || raw.length === 0) {
        return null;
    }
    const parsed = Number.parseInt(raw, 10);
    return Number.isInteger(parsed) ? parsed : Number.NaN;
}

router.get('/', async function (request, response) {
    const handle = request.user?.profile?.handle;
    if (!handle) {
        return response.sendStatus(403);
    }

    const user = await getUserByHandle(handle);
    if (!user || !user.enabled) {
        return response.sendStatus(403);
    }

    response.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    // no-transform is what stops the global compression() middleware from encoding this
    // response and holding it in the encoder, which would deliver nothing until the stream ends.
    response.setHeader('Cache-Control', 'no-cache, no-transform');
    response.setHeader('Connection', 'keep-alive');
    response.setHeader('X-Accel-Buffering', 'no');
    response.flushHeaders();

    const clientId = typeof request.query.clientId === 'string' ? request.query.clientId : '';
    const connection = registerConnection(handle, response, {
        accountVersion: getAccountVersion(user),
        clientId,
    });

    request.on('close', () => unregisterConnection(connection));

    response.write(`retry: ${RETRY_HINT_MS}\n\n`);
    response.write(`event: hello\ndata: ${JSON.stringify({ connectionId: connection.id })}\n\n`);
    resumeConnection(connection, readLastEventId(request));
});

router.post('/visibility', function (request, response) {
    const handle = request.user?.profile?.handle;
    if (!handle) {
        return response.sendStatus(403);
    }

    // A beacon sent as text/plain leaves req.body undefined under Express 5, so this must be
    // guarded before destructuring or the request throws instead of failing as a bad request.
    const body = request.body;
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return response.status(400).send({ error: 'A JSON body with id and visible is required.' });
    }

    const unknown = Object.keys(body).filter(key => !VISIBILITY_FIELDS.has(key));
    if (unknown.length > 0) {
        return response.status(400).send({ error: `Unexpected fields: ${unknown.join(', ')}` });
    }

    const { id, visible } = body;
    if (!Number.isInteger(id) || id <= 0 || typeof visible !== 'boolean') {
        return response.status(400).send({ error: 'Field id must be a positive integer and visible a boolean.' });
    }

    if (!setVisibility(handle, id, visible)) {
        return response.status(404).send({ error: 'No such connection.' });
    }

    return response.send({ visible: visibleCount(handle), connections: connectionCount(handle) });
});

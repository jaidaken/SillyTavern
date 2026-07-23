import { getAccountVersion, getUserByHandle } from './users.js';
import { getConfigValue } from './util.js';
import { log } from './log.js';

const RING_CAPACITY = 64;
const MAX_RING_HANDLES = 32;
const MAX_CONNECTIONS_PER_HANDLE = 16;
const HEARTBEAT_INTERVAL_MS = Math.max(1, getConfigValue('clientEvents.heartbeatSeconds', 15, 'number')) * 1000;
const MAX_BUFFERED_BYTES = 1024 * 1024;
export const RETRY_HINT_MS = 3000;

/**
 * @typedef {object} ClientConnection
 * @property {number} id Identifier the client echoes back on the visibility beacon
 * @property {string} handle Owning user handle
 * @property {import('express').Response} response Held-open response
 * @property {string} accountVersion Account version captured when the stream opened
 * @property {string} clientId Origin tag used to skip echoing an event back to its author
 * @property {boolean} visible Whether the owning tab reports itself visible
 * @property {number} openedAt Registration timestamp, used to evict the oldest connection
 */

/**
 * @typedef {object} HandleState
 * @property {string} handle Owning user handle
 * @property {Set<ClientConnection>} connections Open streams for this handle
 * @property {number} nextId High-water event id, never reset while the process lives
 * @property {{id: number, event: string, data: string}[]} ring Replayable recent events
 * @property {number} lastActive Timestamp of the last activity, used to prune rings
 */

/** @type {Map<string, HandleState>} */
const states = new Map();

/** @type {NodeJS.Timeout|null} */
let heartbeatTimer = null;
let nextConnectionId = 1;

/** @type {((handle: string) => void)[]} */
const presenceListeners = [];

/**
 * Subscribes to changes in how many streams of a handle report a visible tab.
 * @param {(handle: string) => void} listener Called with the handle whose presence changed
 * @returns {void}
 */
export function onPresenceChange(listener) {
    presenceListeners.push(listener);
}

/**
 * @param {string} handle Handle whose presence may have changed
 * @returns {void}
 */
function notifyPresenceChange(handle) {
    for (const listener of presenceListeners) {
        try {
            listener(handle);
        } catch (error) {
            log.sys.error('Client event presence listener failed:', error);
        }
    }
}

/**
 * The ONLY function in this module that iterates connections. Every caller supplies exactly
 * one handle, so an event can never reach a connection registered under a different handle.
 * @param {string} handle Owning user handle
 * @param {(connection: ClientConnection, state: HandleState) => void} visit Called per connection
 * @returns {void}
 */
function forEachConnection(handle, visit) {
    const state = states.get(handle);
    if (!state) {
        return;
    }
    for (const connection of [...state.connections]) {
        visit(connection, state);
    }
}

/**
 * @param {string} handle Owning user handle
 * @returns {HandleState} The existing state, or a fresh one
 */
function getState(handle) {
    let state = states.get(handle);
    if (!state) {
        state = { handle, connections: new Set(), nextId: 0, ring: [], lastActive: Date.now() };
        states.set(handle, state);
    }
    return state;
}

/**
 * Writes a raw chunk, dropping the connection if its socket has stopped draining.
 * @param {ClientConnection} connection Target connection
 * @param {string} chunk Bytes to write
 * @returns {boolean} True when the chunk was accepted
 */
function writeChunk(connection, chunk) {
    const response = connection.response;
    if (response.writableEnded || response.destroyed) {
        return false;
    }
    try {
        response.write(chunk);
        // Second layer behind no-transform: measured to keep the stream live on its own if the
        // header is ever lost, since compression() only releases encoded bytes when flushed.
        if (typeof response.flush === 'function') {
            response.flush();
        }
    } catch (error) {
        log.sys.warn('Client event write failed, dropping connection:', error);
        closeConnection(connection);
        return false;
    }
    if (response.writableLength > MAX_BUFFERED_BYTES) {
        log.sys.warn(`Client event connection ${connection.id} exceeded the write buffer cap, dropping it.`);
        closeConnection(connection);
        return false;
    }
    return true;
}

/**
 * @param {ClientConnection} connection Target connection
 * @param {string} event Event name
 * @param {unknown} payload JSON-serializable payload
 * @param {number|null} id Event id, omitted for stream-control frames
 * @returns {boolean} True when the frame was accepted
 */
function writeEvent(connection, event, payload, id = null) {
    const prefix = id === null ? '' : `id: ${id}\n`;
    return writeChunk(connection, `${prefix}event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

/**
 * Ends a connection and removes it from its handle's set.
 * @param {ClientConnection} connection Target connection
 * @returns {void}
 */
function closeConnection(connection) {
    unregisterConnection(connection);
    const response = connection.response;
    if (!response.writableEnded) {
        try {
            response.end();
        } catch {
            response.destroy();
        }
    }
}

/**
 * Drops the oldest ring payloads once too many handles hold one. The id counter is deliberately
 * left intact: resetting it would let a later event reuse an id a client has already seen.
 * @returns {void}
 */
function pruneRings() {
    const withRings = [...states.values()].filter(state => state.ring.length > 0);
    if (withRings.length <= MAX_RING_HANDLES) {
        return;
    }
    withRings.sort((a, b) => a.lastActive - b.lastActive);
    for (const state of withRings.slice(0, withRings.length - MAX_RING_HANDLES)) {
        state.ring = [];
    }
}

/**
 * Registers a stream, evicting the handle's oldest connection when the cap is reached.
 * Eviction rather than rejection is deliberate: a black-holed socket can hold a slot for a very
 * long time, and rejecting would let stale connections lock a flapping client out of its own stream.
 * @param {string} handle Owning user handle
 * @param {import('express').Response} response Held-open response
 * @param {object} options Connection metadata
 * @param {string} options.accountVersion Account version captured when the stream opened
 * @param {string} [options.clientId] Origin tag supplied by the client
 * @returns {ClientConnection} The registered connection
 */
export function registerConnection(handle, response, options) {
    const state = getState(handle);
    state.lastActive = Date.now();

    while (state.connections.size >= MAX_CONNECTIONS_PER_HANDLE) {
        const oldest = state.connections.values().next().value;
        if (!oldest) {
            break;
        }
        log.sys.warn(`Client event cap reached for ${handle}, evicting connection ${oldest.id}.`);
        closeConnection(oldest);
    }

    /** @type {ClientConnection} */
    const connection = {
        id: nextConnectionId++,
        handle,
        response,
        accountVersion: options.accountVersion,
        clientId: options.clientId ?? '',
        visible: false,
        openedAt: Date.now(),
    };
    state.connections.add(connection);
    armHeartbeat();
    return connection;
}

/**
 * @param {ClientConnection} connection Target connection
 * @returns {void}
 */
export function unregisterConnection(connection) {
    const state = states.get(connection.handle);
    if (!state) {
        return;
    }
    state.connections.delete(connection);
    state.lastActive = Date.now();
    if (![...states.values()].some(candidate => candidate.connections.size > 0)) {
        disarmHeartbeat();
    }
    if (connection.visible) {
        notifyPresenceChange(connection.handle);
    }
}

/**
 * Emits an event to every stream owned by one handle, and to no other handle.
 * @param {string} handle Owning user handle
 * @param {string} event Event name
 * @param {unknown} payload JSON-serializable payload
 * @param {string} [originClientId] When set, the originating client is skipped
 * @returns {number} Event id assigned to this event
 */
export function emitToUser(handle, event, payload, originClientId = '') {
    const state = getState(handle);
    state.nextId += 1;
    state.lastActive = Date.now();

    const id = state.nextId;
    const data = JSON.stringify(payload);
    state.ring.push({ id, event, data });
    while (state.ring.length > RING_CAPACITY) {
        state.ring.shift();
    }
    pruneRings();

    forEachConnection(handle, (connection) => {
        if (originClientId && connection.clientId === originClientId) {
            return;
        }
        writeChunk(connection, `id: ${id}\nevent: ${event}\ndata: ${data}\n\n`);
    });

    return id;
}

/**
 * Decides what a resuming client can be given.
 * A resume that cannot be fully satisfied from the ring reports incomplete, so the caller
 * tells the client to resynchronise rather than leaving it believing it is current.
 * @param {string} handle Owning user handle
 * @param {number|null} lastEventId Last event id the client saw, or null for a fresh stream
 * @returns {{frames: {id: number, event: string, data: string}[], complete: boolean}} Replay decision
 */
function replayFor(handle, lastEventId) {
    const state = getState(handle);
    if (lastEventId === null) {
        return { frames: [], complete: true };
    }
    if (!Number.isInteger(lastEventId) || lastEventId < 0 || lastEventId > state.nextId) {
        return { frames: [], complete: false };
    }
    if (lastEventId === state.nextId) {
        return { frames: [], complete: true };
    }
    if (state.ring.length === 0 || state.ring[0].id > lastEventId + 1) {
        return { frames: [], complete: false };
    }
    return { frames: state.ring.filter(frame => frame.id > lastEventId), complete: true };
}

/**
 * Replays buffered events onto a freshly opened connection.
 * @param {ClientConnection} connection Target connection
 * @param {number|null} lastEventId Last event id the client saw
 * @returns {void}
 */
export function resumeConnection(connection, lastEventId) {
    const { frames, complete } = replayFor(connection.handle, lastEventId);
    if (!complete) {
        writeEvent(connection, 'resync', { reason: 'replay-unavailable' });
        return;
    }
    for (const frame of frames) {
        writeChunk(connection, `id: ${frame.id}\nevent: ${frame.event}\ndata: ${frame.data}\n\n`);
    }
}

/**
 * Marks a connection visible or hidden. The lookup is scoped to the caller's own handle,
 * so a caller cannot discover or alter a connection belonging to anyone else.
 * @param {string} handle Owning user handle
 * @param {number} connectionId Connection identifier issued at stream open
 * @param {boolean} visible Reported visibility
 * @returns {boolean} True when a connection owned by this handle matched
 */
export function setVisibility(handle, connectionId, visible) {
    let matched = false;
    let changed = false;
    forEachConnection(handle, (connection) => {
        if (connection.id === connectionId) {
            changed = connection.visible !== visible;
            connection.visible = visible;
            matched = true;
        }
    });
    if (matched) {
        getState(handle).lastActive = Date.now();
    }
    if (changed) {
        notifyPresenceChange(handle);
    }
    return matched;
}

/**
 * @param {string} handle Owning user handle
 * @returns {number} Number of streams reporting a visible tab
 */
export function visibleCount(handle) {
    let count = 0;
    forEachConnection(handle, (connection) => {
        if (connection.visible) {
            count += 1;
        }
    });
    return count;
}

/**
 * @param {string} handle Owning user handle
 * @returns {number} Number of open streams for this handle
 */
export function connectionCount(handle) {
    return states.get(handle)?.connections.size ?? 0;
}

/**
 * Re-checks that every streaming account is still enabled and unchanged, then pings the survivors.
 * A stream is one request held open indefinitely, so the per-request checks in setUserDataMiddleware
 * never run again for it; without this an account disabled mid-stream keeps receiving live events.
 * @returns {Promise<void>} Resolves once every handle has been checked
 */
async function heartbeatTick() {
    for (const [handle, state] of [...states]) {
        if (state.connections.size === 0) {
            continue;
        }
        /** @type {import('./users.js').User|null} */
        let user;
        try {
            user = await getUserByHandle(handle);
        } catch (error) {
            log.sys.error('Client event revalidation failed:', error);
            continue;
        }
        const revoked = !user || !user.enabled;
        const version = user ? getAccountVersion(user) : '';
        forEachConnection(handle, (connection) => {
            if (revoked || version !== connection.accountVersion) {
                log.sys.warn(`Client event connection ${connection.id} revoked for ${handle}, closing.`);
                closeConnection(connection);
                return;
            }
            writeChunk(connection, ': ping\n\n');
        });
    }
}

/** Starts the shared heartbeat once at least one stream is open. */
function armHeartbeat() {
    if (heartbeatTimer) {
        return;
    }
    heartbeatTimer = setInterval(() => {
        heartbeatTick().catch(error => log.sys.error('Client event heartbeat failed:', error));
    }, HEARTBEAT_INTERVAL_MS);
    heartbeatTimer.unref();
}

/** Stops the heartbeat once the last stream closes. */
function disarmHeartbeat() {
    if (!heartbeatTimer) {
        return;
    }
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
}

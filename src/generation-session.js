/**
 * Server-owned generation sessions.
 *
 * The browser no longer owns a generation: it starts one, then watches it. This module holds the
 * running generations in memory, keyed by a server-issued id and scoped to the owning user handle,
 * and keeps an ORDERED FRAME LOG so a viewer that drops (refresh, tab close, network loss) can
 * re-attach at a cursor and receive exactly the frames it missed.
 *
 * Memory only, by operator decision: this survives a browser refresh, a tab close, a network drop
 * and multiple tabs. It does not survive a node restart.
 */

import crypto from 'node:crypto';

import { log } from './log.js';

/** @type {Map<string, GenerationSession>} */
const sessions = new Map();

const COMPLETED_TTL_MS = 10 * 60 * 1000;

// A finished generation is a few hundred KB of frames at most. The cap bounds a runaway upstream
// that streams without ever ending; past it the log stops growing and replay reports itself partial.
const MAX_FRAME_BYTES = 8 * 1024 * 1024;

/** Terminal payload the client framer already recognises as end-of-generation. */
export const DONE_PAYLOAD = '[DONE]';

export const Status = Object.freeze({
    running: 'running',
    done: 'done',
    stopped: 'stopped',
    error: 'error',
});

/**
 * @typedef {object} GenerationTarget
 * @property {string} filePath Resolved chat file path, derived server-side from the request user.
 * @property {string} cardName Card name or group id, used for backups and cache busting.
 * @property {string|null} fileName Solo chat file name without extension, null for a group.
 * @property {string|null} avatarUrl Solo character avatar url, null for a group.
 * @property {string|null} groupId Group chat id, null for a solo chat.
 * @property {string} characterName Display name written onto the assistant turn.
 */

export class GenerationSession {
    /**
     * @param {string} handle Owning user handle, taken from the server-side session.
     * @param {GenerationTarget} target Resolved chat target.
     */
    constructor(handle, target) {
        this.id = crypto.randomUUID();
        this.handle = handle;
        this.target = target;
        // The request user is held for the whole generation: the completion write happens after the
        // starting request is gone, and it must still land in that user's own directories.
        this.user = null;
        this.text = '';
        this.thinking = '';
        /** @type {{id: number, data: string}[]} */
        this.frames = [];
        this.frameBytes = 0;
        this.replayComplete = true;
        this.nextFrameId = 0;
        this.status = Status.running;
        this.controller = new AbortController();
        this.startedAt = Date.now();
        this.endedAt = 0;
        this.persisted = false;
        this.errorMessage = '';
        /** @type {Set<(frame: {id: number, data: string}|null) => void>} */
        this.listeners = new Set();
        /** @type {NodeJS.Timeout|null} */
        this.reapTimer = null;
    }

    get lastEventId() {
        return this.nextFrameId;
    }

    get active() {
        return this.status === Status.running;
    }

    /**
     * Records one upstream payload and hands it to every attached viewer.
     * The payload is stored exactly as it will be replayed, so a re-attach is byte-identical to the
     * live stream rather than a reconstruction from the accumulated text.
     * @param {string} data The raw SSE data payload, without the `data: ` prefix.
     * @returns {void}
     */
    pushFrame(data) {
        if (this.status !== Status.running) {
            return;
        }
        this.accumulate(data);
        this.nextFrameId += 1;
        const frame = { id: this.nextFrameId, data };
        if (this.frameBytes + data.length > MAX_FRAME_BYTES) {
            this.replayComplete = false;
        } else {
            this.frames.push(frame);
            this.frameBytes += data.length;
        }
        this.notify(frame);
    }

    /**
     * @param {string} data The raw SSE data payload.
     * @returns {void}
     */
    accumulate(data) {
        if (data === DONE_PAYLOAD) {
            return;
        }
        try {
            const parsed = JSON.parse(data);
            const choice = parsed?.choices?.[0];
            if (!choice) {
                return;
            }
            if (typeof choice.text === 'string') {
                this.text += choice.text;
            }
            if (typeof choice.thinking === 'string') {
                this.thinking += choice.thinking;
            }
        } catch {
            // Keepalives and non-JSON control payloads still belong in the frame log, but carry no text.
        }
    }

    /**
     * Frames a viewer at `cursor` has not seen. A cursor beyond what the log can serve reports
     * incomplete, so the caller tells the viewer to resynchronise rather than silently skip tokens.
     * @param {number} cursor Last frame id the viewer already holds. Zero means a fresh viewer.
     * @returns {{frames: {id: number, data: string}[], complete: boolean}}
     */
    framesSince(cursor) {
        if (!Number.isInteger(cursor) || cursor < 0 || cursor > this.nextFrameId) {
            return { frames: [], complete: false };
        }
        if (!this.replayComplete) {
            return { frames: [], complete: false };
        }
        const first = this.frames.length > 0 ? this.frames[0].id : this.nextFrameId + 1;
        if (this.frames.length > 0 && first > cursor + 1) {
            return { frames: [], complete: false };
        }
        return { frames: this.frames.filter(frame => frame.id > cursor), complete: true };
    }

    /**
     * @param {(frame: {id: number, data: string}|null) => void} listener Called per new frame, then once with null at end.
     * @returns {() => void} Unsubscribe.
     */
    subscribe(listener) {
        this.listeners.add(listener);
        return () => this.listeners.delete(listener);
    }

    /**
     * @param {{id: number, data: string}|null} frame The new frame, or null for the terminal signal.
     * @returns {void}
     */
    notify(frame) {
        for (const listener of [...this.listeners]) {
            try {
                listener(frame);
            } catch (error) {
                log.net.error('Generation listener failed:', error);
            }
        }
    }

    /**
     * Ends the generation: emits the terminal frame, wakes every viewer, and arms the reap timer.
     * Idempotent, so a natural end racing an abort seals once.
     * @param {string} status One of Status.done / Status.stopped / Status.error.
     * @param {string} [errorMessage] Detail for the error case.
     * @returns {void}
     */
    finish(status, errorMessage = '') {
        if (this.status !== Status.running) {
            return;
        }
        // The terminal frame rides the log so a viewer that attaches after the end still learns the
        // generation is over from the same sentinel the live stream carried.
        this.nextFrameId += 1;
        const frame = { id: this.nextFrameId, data: DONE_PAYLOAD };
        this.frames.push(frame);
        this.frameBytes += frame.data.length;
        this.status = status;
        this.errorMessage = errorMessage;
        this.endedAt = Date.now();
        this.notify(frame);
        this.notify(null);
        this.armReap();
    }

    /**
     * Aborts the upstream request. Only an explicit stop reaches this; a client disconnect never does.
     * @returns {void}
     */
    abort() {
        try {
            this.controller.abort();
        } catch (error) {
            log.net.warn('Generation abort failed:', error);
        }
    }

    /** @returns {void} */
    armReap() {
        if (this.reapTimer) {
            return;
        }
        this.reapTimer = setTimeout(() => {
            if (sessions.get(this.id) === this) {
                sessions.delete(this.id);
            }
        }, COMPLETED_TTL_MS);
        this.reapTimer.unref?.();
    }
}

/**
 * @param {string} handle Owning user handle, from the server-side session.
 * @param {GenerationTarget} target Resolved chat target.
 * @returns {GenerationSession}
 */
export function createSession(handle, target) {
    const session = new GenerationSession(handle, target);
    sessions.set(session.id, session);
    return session;
}

/**
 * Looks a session up under one handle. The handle always comes from the server-side session, so a
 * caller can never reach a generation belonging to anyone else by guessing its id.
 * @param {string} handle Owning user handle.
 * @param {unknown} id Requested generation id.
 * @returns {GenerationSession|null}
 */
export function getSession(handle, id) {
    if (typeof id !== 'string' || id.length === 0) {
        return null;
    }
    const session = sessions.get(id);
    if (!session || session.handle !== handle) {
        return null;
    }
    return session;
}

/**
 * The running generation for one chat file, scoped to the owning handle.
 * @param {string} handle Owning user handle.
 * @param {string} filePath Resolved chat file path.
 * @returns {GenerationSession|null}
 */
export function findActiveForChat(handle, filePath) {
    for (const session of sessions.values()) {
        if (session.handle === handle && session.active && session.target.filePath === filePath) {
            return session;
        }
    }
    return null;
}

/**
 * @param {string} handle Owning user handle.
 * @returns {GenerationSession[]} Running generations owned by this handle.
 */
export function listActive(handle) {
    return [...sessions.values()].filter(session => session.handle === handle && session.active);
}

/** Test seam: drops every session so one suite's registry cannot leak into the next. */
export function resetSessions() {
    for (const session of sessions.values()) {
        if (session.reapTimer) {
            clearTimeout(session.reapTimer);
        }
    }
    sessions.clear();
}

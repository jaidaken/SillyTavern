import { describe, test, expect, jest, beforeEach, afterEach } from '@jest/globals';

import {
    createSession,
    findActiveForChat,
    listActive,
    resetSessions,
    Status,
    IDLE_TIMEOUT_MS,
    WALL_CLOCK_TIMEOUT_MS,
    MAX_ACTIVE_PER_HANDLE,
} from '../src/generation-session.js';

const HANDLE = 'default-user';
const OTHER_HANDLE = 'someone-else';

/**
 * @param {string} filePath The chat file the generation targets.
 * @returns {import('../src/generation-session.js').GenerationTarget} A minimal target.
 */
function target(filePath) {
    return {
        filePath,
        cardName: 'Seraphina',
        fileName: 'watchdog-chat',
        avatarUrl: 'Seraphina.png',
        groupId: null,
        characterName: 'Seraphina',
    };
}

/**
 * @param {string} text The token text carried by the frame.
 * @returns {string} An SSE data payload the session accumulates.
 */
function tokenFrame(text) {
    return JSON.stringify({ choices: [{ text }] });
}

describe('generation watchdog', () => {
    beforeEach(() => {
        jest.useFakeTimers();
        resetSessions();
    });

    afterEach(() => {
        resetSessions();
        jest.useRealTimers();
    });

    test('an upstream that never answers ends as error on the idle bound', () => {
        const session = createSession(HANDLE, target('/chats/a.jsonl'));
        expect(session.status).toBe(Status.running);

        jest.advanceTimersByTime(IDLE_TIMEOUT_MS - 1000);
        expect(session.status).toBe(Status.running);
        expect(session.controller.signal.aborted).toBe(false);

        jest.advanceTimersByTime(1000);
        expect(session.status).toBe(Status.error);
        expect(session.errorMessage).toMatch(/no upstream frame for 180s/);
        // Reaping the session without releasing the socket would trade a wedged chat for a leak.
        expect(session.controller.signal.aborted).toBe(true);
    });

    test('the chat unwedges once the idle bound has expired', () => {
        const filePath = '/chats/wedged.jsonl';
        const session = createSession(HANDLE, target(filePath));
        // findActiveForChat is the exact predicate POST /start refuses a second generation on, so a
        // null here is what lets the next start through.
        expect(findActiveForChat(HANDLE, filePath)).toBe(session);

        jest.advanceTimersByTime(IDLE_TIMEOUT_MS);

        expect(session.active).toBe(false);
        expect(findActiveForChat(HANDLE, filePath)).toBeNull();
        expect(listActive(HANDLE)).toEqual([]);

        const next = createSession(HANDLE, target(filePath));
        expect(next.id).not.toBe(session.id);
        expect(findActiveForChat(HANDLE, filePath)).toBe(next);
    });

    test('the idle bound is measured from the last frame, not from the start', () => {
        const session = createSession(HANDLE, target('/chats/b.jsonl'));

        jest.advanceTimersByTime(IDLE_TIMEOUT_MS - 1000);
        session.pushFrame(tokenFrame('tok '));
        jest.advanceTimersByTime(IDLE_TIMEOUT_MS - 2000);
        expect(session.status).toBe(Status.running);
        expect(session.text).toBe('tok ');

        jest.advanceTimersByTime(2000);
        expect(session.status).toBe(Status.error);
    });

    test('an upstream that trickles forever still ends on the wall clock', () => {
        const session = createSession(HANDLE, target('/chats/c.jsonl'));
        const step = IDLE_TIMEOUT_MS - 1000;

        for (let elapsed = 0; elapsed <= WALL_CLOCK_TIMEOUT_MS && session.active; elapsed += step) {
            jest.advanceTimersByTime(step);
            session.pushFrame(tokenFrame('tok '));
        }

        expect(session.status).toBe(Status.error);
        expect(session.errorMessage).toMatch(/no end after 1800s/);
        expect(session.text.length).toBeGreaterThan(0);
    });

    test('an expiry runs the route completion path when one is installed', () => {
        const session = createSession(HANDLE, target('/chats/d.jsonl'));
        const reasons = [];
        session.onExpire = (reason) => reasons.push(reason);

        jest.advanceTimersByTime(IDLE_TIMEOUT_MS);

        expect(reasons.length).toBe(1);
        expect(reasons[0]).toMatch(/no upstream frame/);

        // The hook owns the ending, so nothing sealed the session behind its back; the route's
        // finishGeneration is what claims the status and persists the partial turn.
        expect(session.status).toBe(Status.running);
        // The socket is released either way: it does not depend on the hook being wired correctly.
        expect(session.controller.signal.aborted).toBe(true);

        jest.advanceTimersByTime(WALL_CLOCK_TIMEOUT_MS);
        expect(reasons.length).toBe(1);
    });

    test('a finished generation is not re-sealed by a later deadline', () => {
        const session = createSession(HANDLE, target('/chats/e.jsonl'));
        session.pushFrame(tokenFrame('done '));
        session.finish(Status.done, '');

        jest.advanceTimersByTime(WALL_CLOCK_TIMEOUT_MS * 2);

        expect(session.status).toBe(Status.done);
        expect(session.errorMessage).toBe('');
        expect(session.idleTimer).toBeNull();
        expect(session.wallTimer).toBeNull();
        // A generation that ended on its own closed its own socket; a stale deadline must not fire a
        // second abort at a stream that is already gone.
        expect(session.controller.signal.aborted).toBe(false);
    });

    test('the active count is scoped per handle rather than globally', () => {
        for (let i = 0; i < MAX_ACTIVE_PER_HANDLE; i++) {
            createSession(HANDLE, target(`/chats/mine-${i}.jsonl`));
        }
        createSession(OTHER_HANDLE, target('/chats/theirs.jsonl'));

        expect(listActive(HANDLE).length).toBe(MAX_ACTIVE_PER_HANDLE);
        expect(listActive(OTHER_HANDLE).length).toBe(1);
    });
});

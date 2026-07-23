/**
 * Reads a text/event-stream response, recording every frame with the time it arrived.
 * Arrival times are the point of this helper: a buffered stream still delivers every
 * byte eventually, so only timing distinguishes a live channel from a dead one.
 */

// Browsers always send Accept-Encoding, which makes the global compression() middleware
// encode a text/event-stream response and hold it in the encoder until the response ends.
// An SSE response never ends, so the client receives nothing at all. A probe that omits
// this header streams cleanly and hides the failure, so it must never be dropped.
export const BROWSER_ACCEPT_ENCODING = 'gzip, deflate, br';

const DEFAULT_WAIT_MS = 5000;

export class SseStream {
    #controller = new AbortController();
    /** @type {{id: string|null, event: string, data: string, ms: number}[]} */
    #frames = [];
    /** @type {{text: string, ms: number}[]} */
    #comments = [];
    /** @type {(() => void)[]} */
    #waiters = [];
    #buffer = '';
    #startedAt = 0;
    #closed = false;
    #ended = false;
    /** @type {Response|null} */
    #response = null;
    /** @type {Promise<void>|null} */
    #pump = null;
    /** @type {Error|null} */
    #failure = null;

    /**
     * Opens a stream and resolves once the response headers have arrived.
     * @param {string} baseUrl Base URL of a running server
     * @param {string} pathname Request path
     * @param {object} options Session plumbing and header overrides
     * @param {string} [options.cookieHeader] Cookie header carrying the session
     * @param {string} [options.csrfToken] CSRF token for the session
     * @param {string} [options.lastEventId] Value for the Last-Event-ID resume header
     * @param {string} [options.acceptEncoding] Overrides the browser-typical encoding header
     * @returns {Promise<SseStream>} An open stream
     */
    static async open(baseUrl, pathname, options = {}) {
        const stream = new SseStream();
        await stream.#connect(baseUrl, pathname, options);
        return stream;
    }

    /** @returns {number} HTTP status of the stream response. */
    get status() {
        return this.#response?.status ?? 0;
    }

    /** @returns {string} Content-Encoding of the response, or an empty string when absent. */
    get contentEncoding() {
        return this.#response?.headers.get('content-encoding') ?? '';
    }

    /** @returns {string} Content-Type of the response, or an empty string when absent. */
    get contentType() {
        return this.#response?.headers.get('content-type') ?? '';
    }

    /** @returns {{id: string|null, event: string, data: string, ms: number}[]} Frames received so far. */
    get frames() {
        return [...this.#frames];
    }

    /** @returns {{text: string, ms: number}[]} Comment frames received so far, such as heartbeats. */
    get comments() {
        return [...this.#comments];
    }

    /** @returns {number[]} Arrival time of each frame, in ms since the request was sent. */
    get arrivalTimes() {
        return this.#frames.map(frame => frame.ms);
    }

    /**
     * Reports whether frames arrived spread over time rather than all at once at the end.
     * A buffered response delivers every frame in a single chunk, so their arrival times collapse together.
     * @param {number} minimumFrames Frames required before the answer is meaningful
     * @param {number} minimumSpreadMs Milliseconds that must separate the first and last frame
     * @returns {boolean} True when arrival was incremental
     */
    arrivedIncrementally(minimumFrames = 2, minimumSpreadMs = 50) {
        if (this.#frames.length < minimumFrames) {
            return false;
        }
        const times = this.arrivalTimes;
        const distinct = new Set(times);
        const spread = times[times.length - 1] - times[0];
        return distinct.size >= minimumFrames && spread >= minimumSpreadMs;
    }

    /**
     * Waits for a frame matching the predicate, including frames already received.
     * @param {(frame: {id: string|null, event: string, data: string, ms: number}) => boolean} predicate Frame matcher
     * @param {number} timeoutMs Bound on the wait
     * @returns {Promise<{id: string|null, event: string, data: string, ms: number}>} The matching frame
     */
    async waitForFrame(predicate, timeoutMs = DEFAULT_WAIT_MS) {
        const found = await this.#waitUntil(() => this.#frames.find(predicate), timeoutMs);
        if (!found) {
            throw new Error(`No frame matched within ${timeoutMs} ms. Received: ${JSON.stringify(this.#frames)}`);
        }
        return found;
    }

    /**
     * Waits until at least the requested number of frames have arrived.
     * @param {number} count Frames required
     * @param {number} timeoutMs Bound on the wait
     * @returns {Promise<{id: string|null, event: string, data: string, ms: number}[]>} The frames received
     */
    async waitForFrameCount(count, timeoutMs = DEFAULT_WAIT_MS) {
        const ready = await this.#waitUntil(() => (this.#frames.length >= count ? this.frames : undefined), timeoutMs);
        if (!ready) {
            throw new Error(`Only ${this.#frames.length} of ${count} frames arrived within ${timeoutMs} ms.`);
        }
        return ready;
    }

    /**
     * Collects the frames that arrive during a quiet window, for proving a stream received nothing.
     * The window is real elapsed time because the server under test is a separate process,
     * so no virtual clock reaches it.
     * @param {number} windowMs Length of the observation window
     * @returns {Promise<{id: string|null, event: string, data: string, ms: number}[]>} Frames that arrived during the window
     */
    async framesDuring(windowMs) {
        const before = this.#frames.length;
        await new Promise(resolve => setTimeout(resolve, windowMs));
        return this.#frames.slice(before);
    }

    /** @returns {Promise<void>} Resolves once the stream is aborted and the reader has stopped. */
    async close() {
        if (this.#closed) {
            return;
        }
        this.#closed = true;
        this.#controller.abort();
        await this.#pump?.catch(() => { });
    }

    /**
     * @param {string} baseUrl Base URL of a running server
     * @param {string} pathname Request path
     * @param {object} options Session plumbing and header overrides
     * @returns {Promise<void>} Resolves once headers have arrived
     */
    async #connect(baseUrl, pathname, options) {
        /** @type {Record<string, string>} */
        const headers = {
            'Accept': 'text/event-stream',
            'Accept-Encoding': options.acceptEncoding ?? BROWSER_ACCEPT_ENCODING,
        };
        if (options.cookieHeader) headers['Cookie'] = options.cookieHeader;
        if (options.csrfToken) headers['x-csrf-token'] = options.csrfToken;
        if (options.lastEventId) headers['Last-Event-ID'] = options.lastEventId;

        this.#startedAt = Date.now();
        this.#response = await fetch(`${baseUrl}${pathname}`, { headers, signal: this.#controller.signal });

        if (!this.#response.body) {
            this.#notify();
            return;
        }
        this.#pump = this.#read(this.#response.body);
    }

    /**
     * @param {ReadableStream<Uint8Array>} body Response body stream
     * @returns {Promise<void>} Resolves when the body ends or is aborted
     */
    async #read(body) {
        const decoder = new TextDecoder();
        try {
            for await (const chunk of body) {
                this.#buffer += decoder.decode(chunk, { stream: true });
                this.#drain();
            }
        } catch (error) {
            if (!this.#closed) {
                this.#failure = error instanceof Error ? error : new Error(String(error));
            }
        } finally {
            this.#ended = true;
            this.#notify();
        }
    }

    /** @returns {boolean} Whether the server has ended or dropped the stream. */
    get ended() {
        return this.#ended;
    }

    /**
     * Waits for the server to end or drop the stream.
     * @param {number} timeoutMs Bound on the wait
     * @returns {Promise<boolean>} True when the stream ended within the window
     */
    async waitForEnd(timeoutMs = DEFAULT_WAIT_MS) {
        const ended = await this.#waitUntil(() => (this.#ended ? true : undefined), timeoutMs);
        return ended === true;
    }

    /** Splits the buffer into complete frames and records each one. */
    #drain() {
        const normalized = this.#buffer.replace(/\r\n/g, '\n');
        const blocks = normalized.split('\n\n');
        this.#buffer = blocks.pop() ?? '';
        for (const block of blocks) {
            this.#record(block);
        }
        if (blocks.length > 0) {
            this.#notify();
        }
    }

    /**
     * @param {string} block One complete frame body, without its terminating blank line
     */
    #record(block) {
        const ms = Date.now() - this.#startedAt;
        /** @type {string|null} */
        let id = null;
        let event = '';
        /** @type {string[]} */
        const data = [];

        for (const line of block.split('\n')) {
            if (line.length === 0) continue;
            if (line.startsWith(':')) {
                this.#comments.push({ text: line.slice(1).trim(), ms });
                continue;
            }
            const separator = line.indexOf(':');
            const field = separator === -1 ? line : line.slice(0, separator);
            const value = separator === -1 ? '' : line.slice(separator + 1).replace(/^ /, '');
            if (field === 'id') id = value;
            else if (field === 'event') event = value;
            else if (field === 'data') data.push(value);
        }

        // A block carrying no data field dispatches no message, so retry-only and id-only
        // blocks must not be recorded as frames.
        if (data.length > 0) {
            this.#frames.push({ id, event: event || 'message', data: data.join('\n'), ms });
        }
    }

    /**
     * @template T
     * @param {() => T|undefined} probe Returns a truthy result once the condition holds
     * @param {number} timeoutMs Bound on the wait
     * @returns {Promise<T|undefined>} The probe result, or undefined on timeout
     */
    #waitUntil(probe, timeoutMs) {
        const immediate = probe();
        if (immediate) {
            return Promise.resolve(immediate);
        }
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this.#waiters = this.#waiters.filter(waiter => waiter !== check);
                resolve(undefined);
            }, timeoutMs);
            const check = () => {
                const result = probe();
                if (!result) {
                    return;
                }
                clearTimeout(timer);
                this.#waiters = this.#waiters.filter(waiter => waiter !== check);
                resolve(result);
            };
            this.#waiters.push(check);
        });
    }

    /** Wakes every pending waiter so it can re-probe. */
    #notify() {
        for (const waiter of [...this.#waiters]) {
            waiter();
        }
    }

    /** @returns {Error|null} The transport failure, if the stream died unexpectedly. */
    get failure() {
        return this.#failure;
    }
}

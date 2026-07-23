/**
 * HTTP client that carries the session cookie and CSRF token across requests,
 * the way the browser frontend does.
 */
export class SillyTavernClient {
    #baseUrl = '';
    /** @type {Map<string, string>} */
    #cookies = new Map();
    #csrfToken = '';

    /**
     * @param {string} baseUrl Base URL of a running server
     */
    constructor(baseUrl) {
        this.#baseUrl = baseUrl;
    }

    /** @returns {string} The CSRF token issued to this client, or an empty string. */
    get csrfToken() {
        return this.#csrfToken;
    }

    /** @returns {string[]} Names of the cookies currently held by this client. */
    get cookieNames() {
        return [...this.#cookies.keys()];
    }

    /** @returns {string} The Cookie header for this session, for requests made outside this client. */
    get cookieHeader() {
        return [...this.#cookies].map(([name, value]) => `${name}=${value}`).join('; ');
    }

    /**
     * Requests a CSRF token, which also establishes the session cookie.
     * @returns {Promise<string>} The issued token
     */
    async fetchCsrfToken() {
        const response = await this.#send('/csrf-token', { headers: this.#headers() });
        const body = await response.json();
        this.#csrfToken = body.token;
        return body.token;
    }

    /**
     * Performs a login round-trip against the public users router.
     * @param {string} handle User handle
     * @param {string} password User password
     * @returns {Promise<Response>} The login response
     */
    login(handle, password = '') {
        return this.postJson('/api/users/login', { handle, password });
    }

    /**
     * @param {string} pathname Request path
     * @returns {Promise<Response>} The response
     */
    get(pathname) {
        return this.#send(pathname, { headers: this.#headers() });
    }

    /**
     * @param {string} pathname Request path
     * @param {object} body JSON request body
     * @param {Record<string, string>} [extraHeaders] Additional request headers
     * @returns {Promise<Response>} The response
     */
    postJson(pathname, body, extraHeaders = {}) {
        return this.#send(pathname, {
            method: 'POST',
            headers: this.#headers({ 'Content-Type': 'application/json', ...extraHeaders }),
            body: JSON.stringify(body),
        });
    }

    /**
     * Posts a body verbatim, so a test can send payloads that JSON.stringify could never produce.
     * @param {string} pathname Request path
     * @param {string} body Raw request body
     * @param {string} contentType Value of the Content-Type header
     * @returns {Promise<Response>} The response
     */
    postRaw(pathname, body, contentType) {
        return this.#send(pathname, {
            method: 'POST',
            headers: this.#headers({ 'Content-Type': contentType }),
            body,
        });
    }

    /**
     * @param {string} pathname Request path
     * @param {FormData} form Multipart form body
     * @returns {Promise<Response>} The response
     */
    postForm(pathname, form) {
        return this.#send(pathname, { method: 'POST', headers: this.#headers(), body: form });
    }

    /**
     * Posts through the CORS proxy route to an absolute upstream URL.
     * @param {string} targetUrl Absolute upstream URL
     * @param {object} body JSON request body
     * @returns {Promise<Response>} The response
     */
    postThroughProxy(targetUrl, body) {
        return this.postJson(`/proxy/${targetUrl}`, body);
    }

    /**
     * @param {Record<string, string>} extra Additional headers
     * @returns {Record<string, string>} Headers including session cookie and CSRF token
     */
    #headers(extra = {}) {
        const headers = { ...extra };
        if (this.#cookies.size > 0) {
            headers['Cookie'] = [...this.#cookies].map(([name, value]) => `${name}=${value}`).join('; ');
        }
        if (this.#csrfToken) {
            headers['x-csrf-token'] = this.#csrfToken;
        }
        return headers;
    }

    /**
     * @param {Response} response Response to read Set-Cookie headers from
     */
    #absorbCookies(response) {
        for (const cookie of response.headers.getSetCookie()) {
            const [pair] = cookie.split(';');
            const separator = pair.indexOf('=');
            if (separator > 0) {
                this.#cookies.set(pair.slice(0, separator).trim(), pair.slice(separator + 1));
            }
        }
    }

    /**
     * @param {string} pathname Request path
     * @param {RequestInit} init Fetch options
     * @returns {Promise<Response>} The response
     */
    async #send(pathname, init) {
        const response = await fetch(`${this.#baseUrl}${pathname}`, init);
        this.#absorbCookies(response);
        return response;
    }
}

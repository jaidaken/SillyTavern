import { DEFAULT_HANDLE } from './st-server.js';
import { SillyTavernClient } from './st-client.js';

/**
 * Logs a fresh client into an existing handle.
 * @param {string} baseUrl Base URL of a running server
 * @param {string} handle User handle to log in as
 * @param {string} password Account password
 * @returns {Promise<SillyTavernClient>} A logged-in client
 */
export async function loginAs(baseUrl, handle, password = '') {
    const client = new SillyTavernClient(baseUrl);
    await client.fetchCsrfToken();
    const response = await client.login(handle, password);
    if (response.status !== 200) {
        throw new Error(`Failed to log in as ${handle}: ${response.status} ${await response.text()}`);
    }
    return client;
}

/**
 * Provisions a second account and returns a logged-in client for each handle.
 * The two sessions are the substrate for the cross-handle boundary proof: anything
 * emitted for one handle must be observable on that handle's stream and on no other.
 * @param {import('./st-server.js').SillyTavernServer} server A started server
 * @param {string} secondHandle Handle to create for the second session
 * @returns {Promise<{first: SillyTavernClient, second: SillyTavernClient, firstHandle: string, secondHandle: string}>} Two logged-in clients
 */
export async function openTwoHandleSessions(server, secondHandle) {
    const first = await loginAs(server.baseUrl, DEFAULT_HANDLE);

    const created = await first.postJson('/api/users/create', {
        handle: secondHandle,
        name: secondHandle,
        password: '',
        admin: false,
    });
    if (created.status !== 200) {
        throw new Error(`Failed to provision ${secondHandle}: ${created.status} ${await created.text()}`);
    }

    const second = await loginAs(server.baseUrl, secondHandle);

    return { first, second, firstHandle: DEFAULT_HANDLE, secondHandle };
}

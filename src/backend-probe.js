import fs from 'node:fs';
import path from 'node:path';

import { SETTINGS_FILE } from './constants.js';
import { emitToUser, onPresenceChange, visibleCount } from './client-events.js';
import { getModelsStatusUrl } from './endpoints/backends/text-completions.js';
import { getUserDirectories } from './users.js';
import { getConfigValue, trimV1 } from './util.js';
import { log } from './log.js';

const PROBE_INTERVAL_MS = Math.max(1, getConfigValue('clientEvents.probeSeconds', 20, 'number')) * 1000;
const PROBE_TIMEOUT_MS = Math.max(1, getConfigValue('clientEvents.probeTimeoutSeconds', 10, 'number')) * 1000;

export const BACKEND_STATUS_EVENT = 'backend-status';
export const STATUS_ONLINE = 'online';
export const STATUS_ASLEEP = 'asleep';

/**
 * @typedef {object} ProbeState
 * @property {NodeJS.Timeout} timer Interval driving this handle's probe
 * @property {boolean} inFlight Whether a probe is currently outstanding
 * @property {string} lastStatus Last status emitted, used to emit only on transition
 */

/** @type {Map<string, ProbeState>} */
const probes = new Map();

/**
 * Reads the backend a user has configured for text completion.
 * @param {string} handle User handle
 * @returns {Promise<{apiType: string, baseUrl: string}|null>} The configured backend, or null when none is set
 */
async function readConfiguredBackend(handle) {
    try {
        const directories = getUserDirectories(handle);
        const raw = await fs.promises.readFile(path.join(directories.root, SETTINGS_FILE), 'utf8');
        const settings = JSON.parse(raw);
        const textgen = settings?.textgenerationwebui_settings;
        const apiType = textgen?.type;
        if (typeof apiType !== 'string' || apiType.length === 0) {
            return null;
        }
        const server = textgen?.server_urls?.[apiType];
        if (typeof server !== 'string' || server.length === 0) {
            return null;
        }
        return { apiType, baseUrl: trimV1(server.replace('localhost', '127.0.0.1')) };
    } catch {
        return null;
    }
}

/**
 * Probes a handle's backend once and emits only when the status changed.
 * A probe failure is the asleep result, never an exception: throwing here would take the
 * interval callback down and leave the handle armed but never probing again.
 * @param {string} handle User handle
 * @returns {Promise<void>} Resolves once the probe settled
 */
async function runProbe(handle) {
    const state = probes.get(handle);
    if (!state || state.inFlight) {
        return;
    }

    // Claimed before the first await: the settings read yields, so a flag set after it would
    // let a second tick pass the check above and probe concurrently.
    state.inFlight = true;
    try {
        const backend = await readConfiguredBackend(handle);
        if (!backend) {
            return;
        }

        /** @type {string} */
        let status;
        try {
            const response = await fetch(getModelsStatusUrl(backend.apiType, backend.baseUrl), {
                method: 'GET',
                headers: { 'Content-Type': 'application/json' },
                signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
            });
            status = response.ok ? STATUS_ONLINE : STATUS_ASLEEP;
        } catch {
            status = STATUS_ASLEEP;
        }

        if (!probes.has(handle) || state.lastStatus === status) {
            return;
        }
        state.lastStatus = status;
        emitToUser(handle, BACKEND_STATUS_EVENT, { status, apiType: backend.apiType });
    } finally {
        state.inFlight = false;
    }
}

/**
 * @param {string} handle User handle
 * @returns {void}
 */
function arm(handle) {
    const timer = setInterval(() => {
        runProbe(handle).catch(error => log.net.error('Backend probe failed:', error));
    }, PROBE_INTERVAL_MS);
    timer.unref();
    probes.set(handle, { timer, inFlight: false, lastStatus: '' });
    runProbe(handle).catch(error => log.net.error('Backend probe failed:', error));
}

/**
 * @param {string} handle User handle
 * @returns {void}
 */
function disarm(handle) {
    const state = probes.get(handle);
    if (!state) {
        return;
    }
    clearInterval(state.timer);
    probes.delete(handle);
}

/**
 * Arms or disarms a handle's probe to match whether any of its tabs is visible.
 * One timer per handle is what coalesces N visible tabs into a single probe per interval.
 * @param {string} handle User handle
 * @returns {void}
 */
function syncProbe(handle) {
    const shouldProbe = visibleCount(handle) > 0;
    if (shouldProbe && !probes.has(handle)) {
        arm(handle);
        return;
    }
    if (!shouldProbe && probes.has(handle)) {
        disarm(handle);
    }
}

/** Subscribes the probe to presence changes. Call once during server startup. */
export function initBackendProbe() {
    onPresenceChange(syncProbe);
}

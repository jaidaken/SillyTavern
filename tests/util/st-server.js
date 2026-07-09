import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import yaml from 'yaml';

export const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const READY_TIMEOUT_MS = 120000;
const READY_POLL_INTERVAL_MS = 100;
const STOP_TIMEOUT_MS = 15000;

export const DEFAULT_HANDLE = 'default-user';

/**
 * Config overrides layered over default/config.yaml by addMissingConfigValues.
 * User accounts make the login round-trip observable; the CORS proxy is off by default.
 */
const SMOKE_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: true,
    enableCorsProxy: true,
});

/**
 * Reserves a free TCP port on the loopback interface.
 * @returns {Promise<number>} A port number that was free at the time of the call.
 */
export function allocatePort() {
    return new Promise((resolve, reject) => {
        const probe = net.createServer();
        probe.once('error', reject);
        probe.listen(0, '127.0.0.1', () => {
            const address = probe.address();
            if (address === null || typeof address === 'string') {
                probe.close(() => reject(new Error('Failed to read the probe socket address.')));
                return;
            }
            const { port } = address;
            probe.close(() => resolve(port));
        });
    });
}

/**
 * Boots `server.js` as a child process against a throwaway data root and config file.
 */
export class SillyTavernServer {
    /** @type {import('child_process').ChildProcess|null} */
    #child = null;
    /** @type {number|null} */
    #exitCode = null;
    #port = 0;
    #tempDir = '';
    #logPath = '';

    /** @returns {string} Base URL of the running server. */
    get baseUrl() {
        return `http://127.0.0.1:${this.#port}`;
    }

    /** @returns {string} Data root passed to the server. */
    get dataRoot() {
        return path.join(this.#tempDir, 'data');
    }

    /**
     * Resolves a user's data directory under the throwaway data root.
     * @param {string} handle User handle
     * @returns {string} Absolute path to the user directory
     */
    userDirectory(handle = DEFAULT_HANDLE) {
        return path.join(this.dataRoot, handle);
    }

    /**
     * Starts the server and resolves once it answers HTTP requests.
     * @returns {Promise<void>}
     */
    async start() {
        this.#tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-smoke-'));
        this.#logPath = path.join(this.#tempDir, 'server.log');
        const configPath = path.join(this.#tempDir, 'config.yaml');
        fs.writeFileSync(configPath, yaml.stringify(SMOKE_CONFIG), 'utf8');

        // Port 0 is unusable: getIPv4ListenUrl() renders an empty port as 80.
        this.#port = await allocatePort();

        const logFd = fs.openSync(this.#logPath, 'a');
        this.#child = spawn(process.execPath, [
            path.join(SERVER_ROOT, 'server.js'),
            '--configPath', configPath,
            '--dataRoot', this.dataRoot,
            '--port', String(this.#port),
        ], { cwd: SERVER_ROOT, stdio: ['ignore', logFd, logFd] });
        fs.closeSync(logFd);

        this.#child.once('exit', (code) => {
            this.#exitCode = code ?? -1;
        });

        try {
            await this.#waitUntilReady();
        } catch (error) {
            await this.stop();
            throw error;
        }
    }

    /**
     * Terminates the server and removes the throwaway data root.
     * @returns {Promise<void>}
     */
    async stop() {
        const child = this.#child;
        if (child && this.#exitCode === null) {
            const exited = new Promise(resolve => child.once('exit', resolve));
            child.kill('SIGTERM');
            const killTimer = setTimeout(() => child.kill('SIGKILL'), STOP_TIMEOUT_MS);
            await exited;
            clearTimeout(killTimer);
        }
        this.#child = null;

        if (this.#tempDir) {
            fs.rmSync(this.#tempDir, { recursive: true, force: true });
            this.#tempDir = '';
        }
    }

    /**
     * Polls an unauthenticated route until the server binds its port.
     * @returns {Promise<void>}
     */
    async #waitUntilReady() {
        const deadline = Date.now() + READY_TIMEOUT_MS;
        while (Date.now() < deadline) {
            if (this.#exitCode !== null) {
                throw new Error(`Server exited with code ${this.#exitCode} before becoming ready.\n${this.#readLog()}`);
            }
            try {
                const response = await fetch(`${this.baseUrl}/csrf-token`);
                await response.arrayBuffer();
                if (response.ok) {
                    return;
                }
            } catch {
                // Connection is refused until the server finishes startup and binds.
            }
            await new Promise(resolve => setTimeout(resolve, READY_POLL_INTERVAL_MS));
        }
        throw new Error(`Server did not become ready within ${READY_TIMEOUT_MS} ms.\n${this.#readLog()}`);
    }

    /**
     * Reads the captured server output for failure diagnostics.
     * @returns {string} The tail of the server log
     */
    #readLog() {
        try {
            return fs.readFileSync(this.#logPath, 'utf8').split('\n').slice(-40).join('\n');
        } catch {
            return '(no server log captured)';
        }
    }
}

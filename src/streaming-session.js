/**
 * Server-side streaming session tracker.
 *
 * When a generate request carries `chat_file` and `avatar_url`, the backend buffers the SSE
 * stream instead of relying on the frontend to persist. If the client disconnects mid-generation,
 * the backend keeps the upstream alive, accumulates the response, and appends it to the chat file
 * on completion.
 */

import path from 'node:path';

import { log } from './log.js';
import { tryReadFile, tryWriteFile } from './util.js';

/** @type {Map<string, StreamingSession>} */
const sessions = new Map();

const COMPLETED_TTL_MS = 5 * 60 * 1000;

export class StreamingSession {
    chatFile;
    avatarUrl;
    characterName;
    text = '';
    thinking = '';
    done = false;
    clientConnected = true;
    startedAt = Date.now();
    persisted = false;

    constructor(chatFile, avatarUrl, characterName) {
        this.chatFile = chatFile;
        this.avatarUrl = avatarUrl;
        this.characterName = characterName;
    }

    feedChoice(choice) {
        if (choice.text) this.text += choice.text;
        if (choice.thinking) this.thinking += choice.thinking;
    }

    async persist() {
        if (this.persisted) return true;
        if (!this.text && !this.thinking) return false;

        try {
            const raw = await tryReadFile(this.chatFile);
            if (raw === null || raw.length === 0) {
                log.net.warn(`StreamingSession persist: chat file not found: ${this.chatFile}`);
                return false;
            }

            const message = {
                name: this.characterName,
                is_user: false,
                is_system: false,
                send_date: Date.now(),
                mes: this.text,
                extra: { reasoning: this.thinking },
            };

            const appendedLine = JSON.stringify(message);
            const base = raw.endsWith('\n') ? raw.slice(0, -1) : raw;
            await tryWriteFile(this.chatFile, `${base}\n${appendedLine}`);
            this.persisted = true;
            log.net.info(`StreamingSession: appended assistant turn to ${path.basename(this.chatFile)} (${this.text.length} chars)`);
            return true;
        } catch (error) {
            log.net.error('StreamingSession persist failed:', error);
            return false;
        }
    }

    async seal() {
        this.done = true;
        if (!this.clientConnected) {
            await this.persist();
        }
        setTimeout(() => {
            if (sessions.get(this.chatFile) === this) {
                sessions.delete(this.chatFile);
            }
        }, COMPLETED_TTL_MS);
    }

    disconnect() {
        this.clientConnected = false;
    }
}

/**
 * Register or retrieve a session for a chat file path.
 * @param {string} chatFile
 * @param {StreamingSession} [session]
 */
export function getSession(chatFile, session) {
    if (session) sessions.set(chatFile, session);
    return sessions.get(chatFile);
}

/**
 * List all active sessions (for the /api/chats/pending endpoint).
 * @param {string} [chatFile]
 */
export function listPending(chatFile) {
    const result = [];
    for (const [key, session] of sessions) {
        if (chatFile && key !== chatFile) continue;
        if (session.persisted) continue;
        result.push({
            chatFile: session.chatFile,
            avatarUrl: session.avatarUrl,
            characterName: session.characterName,
            text: session.text,
            thinking: session.thinking,
            done: session.done,
            clientConnected: session.clientConnected,
            startedAt: session.startedAt,
        });
    }
    return result;
}

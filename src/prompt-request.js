/**
 * Gathers everything the prompt builder needs, from the server's own files.
 *
 * The builder is a pure function: it reads nothing and it writes nothing. This is the half that goes
 * to disk, so the two stay separable and the builder stays testable without a filesystem. The shape it
 * produces is the contract the wasm service parses.
 */

import fs from 'node:fs';
import path from 'node:path';

import { parse as parseCard } from './character-card-parser.js';

/**
 * A character card as JSON, read from its png.
 * @param {string} charactersPath The user's characters directory.
 * @param {string} avatarUrl Card file name, with or without the png extension.
 * @returns {Promise<any>} The parsed card, or an empty object when it cannot be read.
 */
export async function readCard(charactersPath, avatarUrl) {
    const file = String(avatarUrl || '').endsWith('.png') ? String(avatarUrl) : `${avatarUrl}.png`;
    const full = path.join(charactersPath, file);
    if (!fs.existsSync(full)) {
        return {};
    }
    try {
        const raw = await parseCard(full, 'png');
        return typeof raw === 'string' ? JSON.parse(raw) : (raw ?? {});
    } catch {
        return {};
    }
}

/**
 * How many trailing turns a prompt is built from. No budget can reach past this many messages, and
 * every one of them is costed with the tokenizer, so reading a whole long chat would spend thousands
 * of encode calls to trim almost all of them away. Same window the browser used.
 */
export const PROMPT_WINDOW = 300;

/**
 * The turns and the header metadata of a chat, in the shape the builder takes. The greeting is NOT
 * synthesised here: whether to rebuild it depends on reaching the head of the file, which the builder
 * decides from `at_head`.
 * @param {string} filePath Resolved chat file path.
 * @param {number} [limit] Keep at most this many trailing turns.
 * @returns {Promise<{messages: object[], chat_metadata: object, at_head: boolean}>}
 */
export async function readChatForPrompt(filePath, limit = PROMPT_WINDOW) {
    if (!filePath || !fs.existsSync(filePath)) {
        return { messages: [], chat_metadata: {}, at_head: true };
    }
    // Parsed here rather than through the chat endpoint: importing that module pulls in the config
    // bootstrap, which a unit test has no reason to stand up to read a jsonl file.
    const lines = fs.readFileSync(filePath, 'utf8').split('\n').filter(line => line.trim().length > 0);
    const messages = [];
    let chat_metadata = {};
    for (const [index, line] of lines.entries()) {
        let row;
        try {
            row = JSON.parse(line);
        } catch {
            continue;
        }
        if (index === 0 && row && typeof row.mes !== 'string') {
            chat_metadata = row.chat_metadata ?? {};
            continue;
        }
        if (!row || typeof row.mes !== 'string') {
            continue;
        }
        messages.push({
            name: typeof row.name === 'string' ? row.name : '',
            mes: row.mes,
            is_user: Boolean(row.is_user),
            is_system: Boolean(row.is_system),
        });
    }
    // at_head says whether the window starts at the file's first turn, which is what tells the builder
    // to rebuild the greeting. A trimmed window does not, and a greeting added mid-chat would be wrong.
    if (limit > 0 && messages.length > limit) {
        return { messages: messages.slice(-limit), chat_metadata, at_head: false };
    }
    return { messages, chat_metadata, at_head: true };
}

/**
 * The user's settings blob. Returned as an object so a missing or corrupt file degrades to defaults
 * rather than failing a send.
 * @param {string} settingsPath Path to settings.json.
 * @returns {any} Parsed settings, or an empty object.
 */
export function readSettings(settingsPath) {
    try {
        return JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    } catch {
        return {};
    }
}

/**
 * The world-info book a card links, merged with the globally-selected ones, in the single-book shape
 * the builder parses. Entries keep their own ids so activation order is the file's.
 * @param {string} worldsPath The user's worlds directory.
 * @param {string[]} names Book names to load, in priority order.
 * @returns {object} `{ entries }`, empty when nothing loads.
 */
export function readWorld(worldsPath, names) {
    const entries = {};
    for (const name of names ?? []) {
        const file = path.join(worldsPath, `${name}.json`);
        if (!fs.existsSync(file)) {
            continue;
        }
        try {
            const book = JSON.parse(fs.readFileSync(file, 'utf8'));
            for (const [key, value] of Object.entries(book?.entries ?? {})) {
                // A later book never overwrites an earlier one: the caller's order IS the priority.
                if (!(key in entries)) {
                    entries[key] = value;
                }
            }
        } catch {
            continue;
        }
    }
    return { entries };
}

/**
 * The complete builder request for one generation.
 * @param {object} params Everything the caller resolved from the request user.
 * @param {string} params.charactersPath User's characters directory.
 * @param {string} params.worldsPath User's worlds directory.
 * @param {string} params.settingsPath User's settings.json.
 * @param {string} params.chatFilePath Resolved chat file.
 * @param {any} params.chat Chat descriptor, passed through to the builder.
 * @param {object} [params.browser] The four values only a browser knows.
 * @returns {Promise<object>} The request the wasm service parses.
 */
export async function buildPromptRequest({ charactersPath, worldsPath, settingsPath, chatFilePath, chat, browser = {} }) {
    const settings = readSettings(settingsPath);
    const card = await readCard(charactersPath, chat?.avatar_url ?? '');
    const { messages, chat_metadata, at_head } = await readChatForPrompt(chatFilePath);
    const linked = card?.data?.extensions?.world ? [card.data.extensions.world] : [];
    const globals = settings?.world_info_settings?.world_info?.globalSelect ?? [];
    return {
        card,
        messages,
        settings,
        chat_metadata,
        world: readWorld(worldsPath, [...linked, ...globals]),
        chat,
        at_head,
        browser,
    };
}

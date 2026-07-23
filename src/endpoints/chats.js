import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import crypto from 'node:crypto';

import express from 'express';
import sanitize from 'sanitize-filename';
import writeFileAtomic from 'write-file-atomic';
import _ from 'lodash';

import validateAvatarUrlMiddleware from '../middleware/validateFileName.js';
import {
    getConfigValue,
    humanizedDateTime,
    tryParse,
    generateTimestamp,
    removeOldBackups,
    formatBytes,
    tryWriteFile,
    tryReadFile,
    tryDeleteFile,
    readFirstLine,
    isPathUnderParent,
} from '../util.js';
import { log } from '../log.js';
import { emitForRequest } from '../client-events.js';
import { bustCharacterListCacheForCharacter } from './characters.js';
import {
    backupBaseName,
    chatIdentity,
    identityBasis,
    discoverChatBackups,
    versionInBackup,
    restoreDeletedMessages,
    diffSummary,
} from '../chat-undo.js';

const isBackupEnabled = !!getConfigValue('backups.chat.enabled', true, 'boolean');
const maxTotalChatBackups = Number(getConfigValue('backups.chat.maxTotalBackups', -1, 'number'));
const throttleInterval = Number(getConfigValue('backups.chat.throttleInterval', 10_000, 'number'));
const checkIntegrity = !!getConfigValue('backups.chat.checkIntegrity', true, 'boolean');

// Ships dark: off unless the operator sets chat.cfId.enabled (or SILLYTAVERN_CHAT_CFID_ENABLED).
const cfIdEnabled = !!getConfigValue('chat.cfId.enabled', false, 'boolean');

export const CHAT_BACKUPS_PREFIX = 'chat_';

/**
 * Saves a chat to the backups directory.
 * @param {string} directory The user's backup directory.
 * @param {string} name The name of the chat.
 * @param {string} data The serialized chat to save.
 * @param {string} backupPrefix The file prefix. Typically CHAT_BACKUPS_PREFIX.
 * @returns {Promise<void>}
 */
async function backupChat(directory, name, data, backupPrefix = CHAT_BACKUPS_PREFIX) {
    try {
        if (!isBackupEnabled) { return; }
        const directoryExists = await fs.promises.access(directory).then(() => true, () => false);
        if (!directoryExists) {
            log.chat.error(`The chat couldn't be backed up because no directory exists at ${directory}!`);
        }
        // replace non-alphanumeric characters with underscores
        name = sanitize(name).replace(/[^a-z0-9]/gi, '_').toLowerCase();

        const backupFile = path.join(directory, `${backupPrefix}${name}_${generateTimestamp()}.jsonl`);

        await tryWriteFile(backupFile, data);
        await removeOldBackups(directory, `${backupPrefix}${name}_`);
        if (isNaN(maxTotalChatBackups) || maxTotalChatBackups < 0) {
            return;
        }
        await removeOldBackups(directory, backupPrefix, maxTotalChatBackups);
    } catch (err) {
        log.chat.error(`Could not backup chat for ${name}`, err);
    }
}

/**
 * @type {Map<string, import('lodash').DebouncedFunc<typeof backupChat>>}
 */
const backupFunctions = new Map();

/**
 * Gets a backup function for a user.
 * @param {string} handle User handle
 * @returns {import('lodash').DebouncedFunc<typeof backupChat>} Backup function
 */
function getBackupFunction(handle) {
    let func = backupFunctions.get(handle);
    if (!func) {
        func = _.throttle(backupChat, throttleInterval, { leading: true, trailing: true });
        backupFunctions.set(handle, func);
    }
    return func;
}

/**
 * Gets a preview message from a chat message string.
 * @param {string} [lastMessage] - The message to truncate
 * @returns {string} A truncated preview of the last message or empty string if no messages
 */
function getPreviewMessage(lastMessage) {
    const strlen = 400;

    if (!lastMessage) {
        return '';
    }

    return lastMessage.length > strlen
        ? '...' + lastMessage.substring(lastMessage.length - strlen)
        : lastMessage;
}

/**
 * Flushes pending throttled chat backups. Awaited by the graceful-shutdown path in server-main.js.
 * @returns {Promise<void>}
 */
export async function flushChatBackups() {
    const results = await Promise.allSettled([...backupFunctions.values()].map(func => func.flush()));
    for (const result of results) {
        if (result.status === 'rejected') {
            log.chat.error('Could not flush a pending chat backup', result.reason);
        }
    }
}

/**
 * Imports a chat from Ooba's format.
 * @param {string} userName User name
 * @param {string} characterName Character name
 * @param {object} jsonData JSON data
 * @returns {string} Chat data
 */
function importOobaChat(userName, characterName, jsonData) {
    /** @type {object[]} */
    const chat = [{
        chat_metadata: {},
        user_name: 'unused',
        character_name: 'unused',
    }];

    for (const arr of jsonData.data_visible) {
        if (arr[0]) {
            const userMessage = {
                name: userName,
                is_user: true,
                send_date: new Date().toISOString(),
                mes: arr[0],
                extra: {},
            };
            chat.push(userMessage);
        }
        if (arr[1]) {
            const charMessage = {
                name: characterName,
                is_user: false,
                send_date: new Date().toISOString(),
                mes: arr[1],
                extra: {},
            };
            chat.push(charMessage);
        }
    }

    return chat.map(obj => JSON.stringify(obj)).join('\n');
}

/**
 * Imports a chat from Agnai's format.
 * @param {string} userName User name
 * @param {string} characterName Character name
 * @param {object} jsonData Chat data
 * @returns {string} Chat data
 */
function importAgnaiChat(userName, characterName, jsonData) {
    /** @type {object[]} */
    const chat = [{
        chat_metadata: {},
        user_name: 'unused',
        character_name: 'unused',
    }];

    for (const message of jsonData.messages) {
        const isUser = !!message.userId;
        chat.push({
            name: isUser ? userName : characterName,
            is_user: isUser,
            send_date: new Date().toISOString(),
            mes: message.msg,
            extra: {},
        });
    }

    return chat.map(obj => JSON.stringify(obj)).join('\n');
}

/**
 * Imports a chat from CAI Tools format.
 * @param {string} userName User name
 * @param {string} characterName Character name
 * @param {object} jsonData JSON data
 * @returns {string[]} Converted data
 */
function importCAIChat(userName, characterName, jsonData) {
    /**
     * Converts the chat data to suitable format.
     * @param {object} history Imported chat data
     * @returns {object[]} Converted chat data
     */
    function convert(history) {
        const starter = {
            chat_metadata: {},
            user_name: 'unused',
            character_name: 'unused',
        };

        const historyData = history.msgs.map((msg) => ({
            name: msg.src.is_human ? userName : characterName,
            is_user: msg.src.is_human,
            send_date: new Date().toISOString(),
            mes: msg.text,
            extra: {},
        }));

        return [starter, ...historyData];
    }

    const newChats = (jsonData.histories.histories ?? []).map(history => newChats.push(convert(history).map(obj => JSON.stringify(obj)).join('\n')));
    return newChats;
}

/**
 * Imports a chat from Kobold Lite format.
 * @param {string} _userName User name
 * @param {string} _characterName Character name
 * @param {object} data JSON data
 * @returns {string} Chat data
 */
function importKoboldLiteChat(_userName, _characterName, data) {
    const inputToken = '{{[INPUT]}}';
    const outputToken = '{{[OUTPUT]}}';

    /** @type {(msg: string) => object} */
    function processKoboldMessage(msg) {
        const isUser = msg.includes(inputToken);
        return {
            name: isUser ? userName : characterName,
            is_user: isUser,
            mes: msg.replaceAll(inputToken, '').replaceAll(outputToken, '').trim(),
            send_date: new Date().toISOString(),
            extra: {},
        };
    }

    // Create the header
    const userName = String(data.savedsettings.chatname);
    const characterName = String(data.savedsettings.chatopponent).split('||$||')[0];
    const header = {
        chat_metadata: {},
        user_name: 'unused',
        character_name: 'unused',
    };
    // Format messages
    const formattedMessages = data.actions.map(processKoboldMessage);
    // Add prompt if available
    if (data.prompt) {
        formattedMessages.unshift(processKoboldMessage(data.prompt));
    }
    // Combine header and messages
    const chatData = [header, ...formattedMessages];
    return chatData.map(obj => JSON.stringify(obj)).join('\n');
}

/**
 * Flattens `msg` and `swipes` data from Chub Chat format.
 * Only changes enough to make it compatible with the standard chat serialization format.
 * @param {string} userName User name
 * @param {string} characterName Character name
 * @param {string[]} lines serialised JSONL data
 * @returns {string} Converted data
 */
function flattenChubChat(userName, characterName, lines) {
    function flattenSwipe(swipe) {
        return swipe.message ? swipe.message : swipe;
    }

    function convert(line) {
        const lineData = tryParse(line);
        if (!lineData) return line;

        if (lineData.mes && lineData.mes.message) {
            lineData.mes = lineData?.mes.message;
        }

        if (lineData?.swipes && Array.isArray(lineData.swipes)) {
            lineData.swipes = lineData.swipes.map(swipe => flattenSwipe(swipe));
        }

        return JSON.stringify(lineData);
    }

    return (lines ?? []).map(convert).join('\n');
}

/**
 * Imports a chat from RisuAI format.
 * @param {string} userName User name
 * @param {string} characterName Character name
 * @param {object} jsonData Imported chat data
 * @returns {string} Chat data
 */
function importRisuChat(userName, characterName, jsonData) {
    /** @type {object[]} */
    const chat = [{
        chat_metadata: {},
        user_name: 'unused',
        character_name: 'unused',
    }];

    for (const message of jsonData.data.message) {
        const isUser = message.role === 'user';
        chat.push({
            name: message.name ?? (isUser ? userName : characterName),
            is_user: isUser,
            send_date: new Date(Number(message.time ?? Date.now())).toISOString(),
            mes: message.data ?? '',
            extra: {},
        });
    }

    return chat.map(obj => JSON.stringify(obj)).join('\n');
}

/**
 * Checks if the chat being saved has the same integrity as the one being loaded.
 * @param {string} filePath Path to the chat file
 * @param {string} integritySlug Integrity slug
 * @returns {Promise<boolean>} Whether the chat is intact
 */
async function checkChatIntegrity(filePath, integritySlug) {
    // If the chat file doesn't exist, assume it's intact
    const fileStat = await fs.promises.stat(filePath).catch(() => null);
    if (!fileStat) {
        return true;
    }

    // Parse the first line of the chat file as JSON
    const firstLine = await readFirstLine(filePath);
    const jsonData = tryParse(firstLine);
    const chatIntegrity = jsonData?.chat_metadata?.integrity;

    // If the chat has no integrity metadata, assume it's intact
    if (!chatIntegrity) {
        log.chat.debug(`File "${filePath}" does not have integrity metadata matching "${integritySlug}". The integrity validation has been skipped.`);
        return true;
    }

    // Check if the integrity matches
    return chatIntegrity === integritySlug;
}

/**
 * @typedef {Object} ChatInfo
 * @property {string} [file_id] - The name of the chat file (without extension)
 * @property {string} [file_name] - The name of the chat file (with extension)
 * @property {string} [file_size] - The size of the chat file in a human-readable format
 * @property {number} [chat_items] - The number of chat items in the file
 * @property {string} [mes] - The last message in the chat
 * @property {number|string} [last_mes] - The timestamp of the last message
 * @property {object} [chat_metadata] - Additional chat metadata
 * @property {boolean} [match] - Whether the chat matches the search criteria
 */

/**
 * @typedef {object} ChatInfoCacheEntry
 * @property {number} mtimeMs - File modification time when the entry was derived.
 * @property {number} size - File size in bytes when the entry was derived.
 * @property {number} chat_items - Message count excluding the header line.
 * @property {string} mes - Last message text.
 * @property {number|string} last_mes - Last message timestamp.
 * @property {object} [chat_metadata] - Header chat metadata, if the file carried any.
 */

// Derived chat metadata keyed by absolute file path; the path already includes the user handle dir, so entries are per-user.
// A hit needs an exact mtimeMs+size match with a fresh stat (the out-of-band edit guard); every save/delete/rename busts.
/** @type {Map<string, ChatInfoCacheEntry>} */
const chatInfoCache = new Map();

/**
 * Derives the chat-metadata cache entry from a fresh stat and a chat array, mirroring what getChatInfo streams.
 * @param {import('node:fs').Stats} stats - Fresh stat of the saved file.
 * @param {Array} chatData - The chat array that was just written.
 * @returns {ChatInfoCacheEntry} The cache entry.
 */
function deriveChatInfoCacheEntry(stats, chatData) {
    const lastMessage = chatData[chatData.length - 1];
    const chatMetadata = _.isObjectLike(chatData[0]?.chat_metadata) ? chatData[0].chat_metadata : undefined;
    return {
        mtimeMs: stats.mtimeMs,
        size: stats.size,
        chat_items: chatData.length - 1,
        mes: lastMessage?.mes || '[The message is empty]',
        last_mes: lastMessage?.send_date || new Date(Math.round(stats.mtimeMs)).toISOString(),
        chat_metadata: chatMetadata,
    };
}

/**
 * Refreshes the cache entry after an in-process save so /recent and /search do not re-stream the file.
 * @param {string} filePath - The saved chat file path.
 * @param {Array} chatData - The chat array that was just written.
 * @returns {Promise<void>}
 */
async function updateChatInfoCache(filePath, chatData) {
    if (!Array.isArray(chatData) || chatData.length === 0) {
        chatInfoCache.delete(filePath);
        return;
    }
    const stats = await fs.promises.stat(filePath).catch(() => null);
    if (!stats || stats.size === 0) {
        chatInfoCache.delete(filePath);
        return;
    }
    chatInfoCache.set(filePath, deriveChatInfoCacheEntry(stats, chatData));
}

/**
 * Reads the information from a chat file.
 * @param {string} pathToFile - Path to the chat file
 * @param {object} additionalData - Additional data to include in the result
 * @param {boolean} withMetadata - Whether to read chat metadata
 * @param {ChatMatchFunction|null} matcher - Optional function to match messages
 * @returns {Promise<ChatInfo>}
 *
 * @typedef {(textArray: string[]) => boolean} ChatMatchFunction
 */
export async function getChatInfo(pathToFile, additionalData = {}, withMetadata = false, matcher = null) {
    const parsedPath = path.parse(pathToFile);
    const stats = await fs.promises.stat(pathToFile);
    const hasMatcher = (typeof matcher === 'function');

    /** @type {ChatInfo} */
    const chatData = {
        match: false,
        file_id: parsedPath.name,
        file_name: parsedPath.base,
        file_size: formatBytes(stats.size),
        chat_items: 0,
        mes: '[The chat is empty]',
        last_mes: stats.mtimeMs,
        ...additionalData,
    };

    if (stats.size === 0) {
        return chatData;
    }

    // The metadata short-circuit is unsafe with a content matcher: `match` depends on the query, so a search always streams.
    if (!hasMatcher) {
        const cached = chatInfoCache.get(pathToFile);
        if (cached && cached.mtimeMs === stats.mtimeMs && cached.size === stats.size) {
            chatData.chat_items = cached.chat_items;
            chatData.mes = cached.mes;
            chatData.last_mes = cached.last_mes;
            chatData.match = true;
            if (withMetadata && cached.chat_metadata !== undefined) {
                chatData.chat_metadata = cached.chat_metadata;
            }
            return chatData;
        }
    }

    return new Promise((res) => {
        const fileStream = fs.createReadStream(pathToFile);
        const rl = readline.createInterface({
            input: fileStream,
            crlfDelay: Infinity,
        });

        let lastLine;
        let itemCounter = 0;
        let hasAnyMatch = false;
        let matchBuffer = [];
        // Captured regardless of withMetadata so a cache entry is complete for a later withMetadata read.
        let headerMetadata;
        rl.on('line', (line) => {
            if (itemCounter === 0) {
                const jsonData = tryParse(line);
                if (jsonData && _.isObjectLike(jsonData.chat_metadata)) {
                    headerMetadata = jsonData.chat_metadata;
                }
            }
            // Skip matching if any match was already found
            if (hasMatcher && !hasAnyMatch && itemCounter > 0) {
                const jsonData = tryParse(line);
                if (jsonData) {
                    matchBuffer.push(jsonData.mes || '');
                    if (matcher(matchBuffer)) {
                        hasAnyMatch = true;
                        matchBuffer = [];
                    }
                }
            }
            itemCounter++;
            lastLine = line;
        });
        rl.on('close', () => {
            rl.close();

            if (lastLine) {
                const jsonData = tryParse(lastLine);
                if (jsonData && (jsonData.name || jsonData.character_name || jsonData.chat_metadata)) {
                    const chatItems = itemCounter - 1;
                    const mes = jsonData.mes || '[The message is empty]';
                    const lastMes = jsonData.send_date || new Date(Math.round(stats.mtimeMs)).toISOString();
                    chatData.chat_items = chatItems;
                    chatData.mes = mes;
                    chatData.last_mes = lastMes;
                    chatData.match = hasMatcher ? hasAnyMatch : true;

                    chatInfoCache.set(pathToFile, {
                        mtimeMs: stats.mtimeMs,
                        size: stats.size,
                        chat_items: chatItems,
                        mes: mes,
                        last_mes: lastMes,
                        chat_metadata: headerMetadata,
                    });
                    if (withMetadata && headerMetadata !== undefined) {
                        chatData.chat_metadata = headerMetadata;
                    }

                    res(chatData);
                } else {
                    log.chat.warn('Found an invalid or corrupted chat file:', pathToFile);
                    res({});
                }
            }
        });
    });
}

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * Encodes a millisecond timestamp as the 10-character time component of a ULID.
 * @param {number} time Milliseconds since the epoch.
 * @returns {string} Ten Crockford base32 characters, most significant first.
 */
export function encodeUlidTime(time) {
    let value = Math.max(0, Math.floor(time));
    let out = '';
    for (let i = 0; i < 10; i++) {
        const mod = value % 32;
        out = CROCKFORD[mod] + out;
        value = (value - mod) / 32;
    }
    return out;
}

/**
 * Mints a ULID: a 48-bit time component plus 80 bits of CSPRNG randomness.
 * @param {number} time Milliseconds used for the time component.
 * @returns {string} A 26-character Crockford base32 identifier.
 */
export function mintUlid(time) {
    const bytes = crypto.randomBytes(16);
    let rand = '';
    for (let i = 0; i < 16; i++) {
        rand += CROCKFORD[bytes[i] & 0x1f];
    }
    return encodeUlidTime(time) + rand;
}

/**
 * Assigns a top-level cf_id to every message that lacks one, mutating in place.
 * The line-0 metadata header is skipped and existing ids are preserved. Times stay
 * non-decreasing by array position so ids remain ordered when imports reuse a send_date.
 * @param {Array} chatData The full chat array (header first, then messages).
 * @returns {Array} The same array, mutated.
 */
export function mintChatIds(chatData) {
    if (!Array.isArray(chatData)) {
        return chatData;
    }
    let prevTime = 0;
    for (const entry of chatData) {
        if (!entry || typeof entry !== 'object') {
            continue;
        }
        const isMessage = entry.is_user !== undefined || entry.mes !== undefined;
        if (!isMessage) {
            continue;
        }
        const numeric = Number(entry.send_date);
        const parsed = Number.isFinite(numeric) ? numeric : Date.parse(String(entry.send_date));
        let time = Number.isFinite(parsed) ? parsed : Date.now();
        if (time <= prevTime) {
            time = prevTime + 1;
        }
        prevTime = time;
        if (typeof entry.cf_id !== 'string' || entry.cf_id.length === 0) {
            entry.cf_id = mintUlid(time);
        }
    }
    return chatData;
}

/**
 * FNV-1a 64-bit hash of a string, used for cheap change detection (not cryptographic).
 * @param {string} input The string to hash.
 * @returns {string} A 16-character zero-padded hex digest.
 */
export function fnv1a64(input) {
    const mask = 0xffffffffffffffffn;
    const prime = 0x100000001b3n;
    let hash = 0xcbf29ce484222325n;
    for (let i = 0; i < input.length; i++) {
        hash ^= BigInt(input.charCodeAt(i));
        hash = (hash * prime) & mask;
    }
    return hash.toString(16).padStart(16, '0');
}

export const router = express.Router();

// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Error
class IntegrityMismatchError extends Error {
    constructor(...params) {
        // Pass remaining arguments (including vendor specific ones) to parent constructor
        super(...params);
        // Maintains proper stack trace for where our error was thrown (non-standard)
        if (Error.captureStackTrace) {
            Error.captureStackTrace(this, IntegrityMismatchError);
        }
        this.date = new Date();
    }
}

/**
 * Tries to save the chat data to a file, performing an integrity check if required.
 * @param {Array} chatData The chat array to save.
 * @param {string} filePath Target file path for the data.
 * @param {boolean} skipIntegrityCheck If undefined, the chat's integrity will not be checked.
 * @param {string} handle The users handle, passed to getBackupFunction.
 * @param {string} cardName Passed to backupChat.
 * @param {string} backupDirectory Passed to backupChat.
 */
export async function trySaveChat(chatData, filePath, skipIntegrityCheck = false, handle, cardName, backupDirectory) {
    if (cfIdEnabled) {
        mintChatIds(chatData);
    }
    const jsonlData = chatData?.map(m => JSON.stringify(m)).join('\n');

    const doIntegrityCheck = (checkIntegrity && !skipIntegrityCheck);
    const chatIntegritySlug = doIntegrityCheck ? chatData?.[0]?.chat_metadata?.integrity : undefined;

    if (chatIntegritySlug && !await checkChatIntegrity(filePath, chatIntegritySlug)) {
        throw new IntegrityMismatchError(`Chat integrity check failed for "${filePath}". The expected integrity slug was "${chatIntegritySlug}".`);
    }
    await tryWriteFile(filePath, jsonlData);
    await updateChatInfoCache(filePath, chatData);
    getBackupFunction(handle)(backupDirectory, cardName, jsonlData);
    bustCharacterListCacheForCharacter(handle, cardName);
}

router.post('/save', validateAvatarUrlMiddleware, async function (request, response) {
    try {
        const handle = request.user.profile.handle;
        const cardName = String(request.body.avatar_url).replace('.png', '');
        const chatData = request.body.chat;
        const chatFileName = `${String(request.body.file_name)}.jsonl`;
        const chatFilePath = path.join(request.user.directories.chats, cardName, sanitize(chatFileName));
        if (!isPathUnderParent(request.user.directories.chats, chatFilePath)) {
            return response.sendStatus(400);
        }

        if (Array.isArray(chatData)) {
            await trySaveChat(chatData, chatFilePath, request.body.force, handle, cardName, request.user.directories.backups);
            emitForRequest(request, 'chat-changed', { action: 'save', card: cardName, file: String(request.body.file_name) });
            return response.send({ ok: true });
        } else {
            return response.status(400).send({ error: 'The request\'s body.chat is not an array.' });
        }
    } catch (error) {
        if (error instanceof IntegrityMismatchError) {
            log.chat.error(error.message);
            return response.status(400).send({ error: 'integrity' });
        }
        log.chat.error(error);
        return response.status(500).send({ error: 'An error has occurred, see the console logs for more information.' });
    }
});

/**
 * Gets the chat as an object.
 * @param {string} chatFilePath The full chat file path.
 * @returns {Promise<Array>} If the chatFilePath cannot be read, this will return [].
 */
export async function getChatData(chatFilePath) {
    let chatData = [];

    const chatJSON = await tryReadFile(chatFilePath) ?? '';
    if (chatJSON.length > 0) {
        const lines = chatJSON.split('\n');
        // Iterate through the array of strings and parse each line as JSON
        chatData = lines.map(line => tryParse(line)).filter(x => x);
    } else {
        log.chat.warn(`File not found: ${chatFilePath}. The chat does not exist or is empty.`);
    }

    return chatData;
}

const DEFAULT_PAGE_LIMIT = 100;
// Anti-abuse ceiling only; far above any real chat, never a display cap (invariant 2).
const MAX_PAGE_LIMIT = 100000;

/**
 * Resolves which chat file a request targets, unifying the solo and group families.
 */
class ChatRef {
    /** @param {string} filePath Resolved chat file path. */
    constructor(filePath) {
        this.filePath = filePath;
    }

    /**
     * Resolves a solo character chat, guarding against path traversal.
     * @param {any} user The request user with resolved directories.
     * @param {string} avatarUrl The character avatar url.
     * @param {string} fileName The chat file name without extension.
     * @returns {ChatRef|null} The ref, or null if the path escapes the chats root.
     */
    static solo(user, avatarUrl, fileName) {
        const dirName = String(avatarUrl).replace('.png', '');
        const directoryPath = path.join(user.directories.chats, dirName);
        if (!isPathUnderParent(user.directories.chats, directoryPath)) {
            return null;
        }
        const filePath = path.join(directoryPath, sanitize(`${String(fileName)}.jsonl`));
        if (!isPathUnderParent(user.directories.chats, filePath)) {
            return null;
        }
        return new ChatRef(filePath);
    }

    /**
     * Resolves a group chat, adding the path-traversal guard the stock route lacks.
     * @param {any} user The request user with resolved directories.
     * @param {string} id The group chat id.
     * @returns {ChatRef|null} The ref, or null if the path escapes the group root.
     */
    static group(user, id) {
        const filePath = path.join(user.directories.groupChats, sanitize(`${String(id)}.jsonl`));
        if (!isPathUnderParent(user.directories.groupChats, filePath)) {
            return null;
        }
        return new ChatRef(filePath);
    }
}

/**
 * @typedef {Object} ParsedChat
 * @property {object|null} header The line-0 metadata header, if present.
 * @property {string} headerRaw Raw text of the header line.
 * @property {Array<{raw: string, obj: any}>} messages Parsed message entries in file order.
 */

/**
 * Reads and parses a chat file once, keeping each surviving line's raw text so the
 * change-token hash and the slice indices derive from the same parse.
 * @param {string} filePath Path to the chat file.
 * @returns {Promise<ParsedChat>}
 */
export async function readChatFile(filePath) {
    return parseChatContent(await tryReadFile(filePath) ?? '');
}

/**
 * Parses raw jsonl chat text into a ParsedChat, so the append path can parse an in-memory
 * raw buffer with the exact header detection the spine reads with.
 * @param {string} content Raw chat file text.
 * @returns {ParsedChat}
 */
export function parseChatContent(content) {
    /** @type {object|null} */
    let header = null;
    let headerRaw = '';
    /** @type {Array<{raw: string, obj: any}>} */
    const messages = [];
    if (content.length === 0) {
        return { header, headerRaw, messages };
    }
    for (const raw of content.split('\n')) {
        const obj = tryParse(raw);
        if (!obj) {
            continue;
        }
        const looksLikeHeader = (obj.user_name !== undefined || obj.chat_metadata !== undefined) && obj.is_user === undefined;
        if (header === null && looksLikeHeader) {
            header = obj;
            headerRaw = raw;
            continue;
        }
        messages.push({ raw, obj });
    }
    return { header, headerRaw, messages };
}

/**
 * Hashes the file prefix from the header through the message at anchorIndex inclusive.
 * @param {string} headerRaw Raw header line.
 * @param {Array<{raw: string}>} messages Parsed message entries.
 * @param {number} anchorIndex Inclusive upper bound into messages; -1 hashes the header alone.
 * @returns {string} FNV-1a 64-bit hex digest.
 */
export function prefixHash(headerRaw, messages, anchorIndex) {
    const parts = [headerRaw];
    for (let i = 0; i <= anchorIndex && i < messages.length; i++) {
        parts.push(messages[i].raw);
    }
    return fnv1a64(parts.join('\n'));
}

/**
 * Clamps a caller-supplied page size to a sane range.
 * @param {*} value The requested limit.
 * @returns {number} A limit in [1, MAX_PAGE_LIMIT].
 */
function clampLimit(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) {
        return DEFAULT_PAGE_LIMIT;
    }
    return Math.min(MAX_PAGE_LIMIT, Math.max(1, Math.floor(n)));
}

/**
 * @param {number} count Total message count.
 * @param {string} hash Prefix hash.
 * @returns {string} A change token string.
 */
function buildToken(count, hash) {
    return `v1.${count}.${hash}`;
}

/**
 * @param {string} token A change token.
 * @returns {string|null} The hash component, or null when malformed.
 */
function parseTokenHash(token) {
    const parts = String(token).split('.');
    return parts.length === 3 ? parts[2] : null;
}

/**
 * Normalizes the paging options a request body carries.
 * @param {any} body The request body.
 * @returns {any} Paging options with a computed `paged` flag.
 */
export function readPageOpts(body) {
    const opts = {
        limit: body.limit,
        before_id: typeof body.before_id === 'string' ? body.before_id : undefined,
        around_id: typeof body.around_id === 'string' ? body.around_id : undefined,
        before_index: Number.isInteger(body.before_index) ? body.before_index : undefined,
        around_index: Number.isInteger(body.around_index) ? body.around_index : undefined,
        change_token: typeof body.change_token === 'string' ? body.change_token : undefined,
    };
    opts.paged = body.paged === true
        || opts.before_id !== undefined || opts.around_id !== undefined
        || opts.before_index !== undefined || opts.around_index !== undefined;
    return opts;
}

/**
 * The paged envelope for a chat that is absent or empty.
 * @returns {object} An empty page envelope.
 */
export function emptyChatPage() {
    return {
        messages: [],
        header: null,
        change_token: buildToken(0, fnv1a64('')),
        full_token: buildToken(0, fnv1a64('')),
        has_more_before: false,
        has_more_after: false,
        total_items: 0,
        anchor_index: null,
        anchor_found: false,
    };
}

/**
 * Builds a paged slice of a chat for the reader. Anchors by index (works with the
 * cf_id flag off) or by cf_id (exact match when the flag is on). Returns a 409
 * descriptor when a client-supplied change token no longer matches the prefix it
 * anchored on, so an edit or delete above the window forces a re-sync while a plain
 * append does not.
 * @param {string} filePath Path to the chat file.
 * @param {any} opts Normalized paging options.
 * @returns {Promise<{status: number, body: object}>}
 */
export async function buildChatPage(filePath, opts) {
    const { header, headerRaw, messages } = await readChatFile(filePath);
    const total = messages.length;
    const limit = clampLimit(opts.limit);

    const mode = (opts.before_id !== undefined || opts.before_index !== undefined) ? 'before'
        : (opts.around_id !== undefined || opts.around_index !== undefined) ? 'around'
            : 'tail';

    let anchorIndex = -1;
    let anchorFound = true;
    if (opts.before_id !== undefined) {
        anchorIndex = messages.findIndex(m => m.obj.cf_id === opts.before_id);
        anchorFound = anchorIndex >= 0;
    } else if (opts.around_id !== undefined) {
        anchorIndex = messages.findIndex(m => m.obj.cf_id === opts.around_id);
        anchorFound = anchorIndex >= 0;
    } else if (opts.before_index !== undefined) {
        anchorIndex = opts.before_index;
        anchorFound = anchorIndex >= 0 && anchorIndex <= total;
    } else if (opts.around_index !== undefined) {
        anchorIndex = opts.around_index;
        anchorFound = anchorIndex >= 0 && anchorIndex < total;
    }

    if (mode !== 'tail' && !anchorFound) {
        return {
            status: 200,
            body: {
                messages: [],
                header,
                change_token: buildToken(total, prefixHash(headerRaw, messages, total - 1)),
                full_token: computeFullToken(headerRaw, messages),
                has_more_before: false,
                has_more_after: false,
                total_items: total,
                anchor_index: null,
                anchor_found: false,
            },
        };
    }

    if (opts.change_token !== undefined && mode !== 'tail') {
        const boundary = Math.min(anchorIndex, total - 1);
        const currentHash = prefixHash(headerRaw, messages, boundary);
        const priorHash = parseTokenHash(opts.change_token);
        if (priorHash !== null && priorHash !== currentHash) {
            return { status: 409, body: { error: 'stale', change_token: buildToken(total, currentHash) } };
        }
    }

    let start;
    let end;
    if (mode === 'before') {
        end = Math.min(anchorIndex, total);
        start = Math.max(0, end - limit);
    } else if (mode === 'around') {
        const before = Math.floor(limit / 2);
        const after = limit - before;
        start = Math.max(0, anchorIndex - before);
        end = Math.min(total, anchorIndex + after + 1);
    } else {
        end = total;
        start = Math.max(0, total - limit);
    }

    const slice = messages.slice(start, end).map(m => m.obj);
    const tokenBoundary = total === 0 ? -1 : start;
    return {
        status: 200,
        body: {
            messages: slice,
            header,
            change_token: buildToken(total, prefixHash(headerRaw, messages, tokenBoundary)),
            full_token: computeFullToken(headerRaw, messages),
            has_more_before: start > 0,
            has_more_after: end < total,
            total_items: total,
            anchor_index: mode === 'tail' ? null : anchorIndex,
            anchor_found: anchorFound,
        },
    };
}

router.post('/get', validateAvatarUrlMiddleware, async function (request, response) {
    try {
        const opts = readPageOpts(request.body);
        const dirName = String(request.body.avatar_url).replace('.png', '');
        const directoryPath = path.join(request.user.directories.chats, dirName);
        if (!isPathUnderParent(request.user.directories.chats, directoryPath)) {
            return response.sendStatus(400);
        }
        const chatDirStat = await fs.promises.stat(directoryPath).catch(() => null);

        //if no chat dir for the character is found, make one with the character name
        if (!chatDirStat) {
            if (opts.paged) {
                return response.send(emptyChatPage());
            }
            await fs.promises.mkdir(directoryPath);
            return response.send({});
        }

        if (!request.body.file_name) {
            return response.send(opts.paged ? emptyChatPage() : {});
        }

        const ref = ChatRef.solo(request.user, request.body.avatar_url, request.body.file_name);
        if (!ref) {
            return response.sendStatus(400);
        }

        // Absent file = fresh chat (200 empty); existing-but-unreadable = 500, so the client never
        // seeds a greeting over real history it merely failed to read.
        const fileStat = await fs.promises.stat(ref.filePath).catch(() => null);
        if (!fileStat) {
            return response.send(opts.paged ? emptyChatPage() : {});
        }
        if (opts.paged) {
            const page = await buildChatPage(ref.filePath, opts);
            return response.status(page.status).send(page.body);
        }
        const chatData = await getChatData(ref.filePath);
        if (fileStat.size > 0 && chatData.length === 0) {
            return response.status(500).send({ error: true });
        }
        return response.send(chatData);
    } catch (error) {
        log.chat.error(error);
        return response.status(500).send({ error: true });
    }
});

router.post('/rename', validateAvatarUrlMiddleware, async function (request, response) {
    try {
        if (!request.body || !request.body.original_file || !request.body.renamed_file) {
            return response.sendStatus(400);
        }

        const pathToFolder = request.body.is_group
            ? request.user.directories.groupChats
            : path.join(request.user.directories.chats, String(request.body.avatar_url).replace('.png', ''));
        if (!request.body.is_group && !isPathUnderParent(request.user.directories.chats, pathToFolder)) {
            return response.sendStatus(400);
        }
        const pathToOriginalFile = path.join(pathToFolder, sanitize(request.body.original_file));
        const pathToRenamedFile = path.join(pathToFolder, sanitize(request.body.renamed_file));
        const sanitizedFileName = path.parse(pathToRenamedFile).name;
        log.chat.debug('Old chat name', pathToOriginalFile);
        log.chat.debug('New chat name', pathToRenamedFile);

        const originalFileStat = await fs.promises.stat(pathToOriginalFile).catch(() => null);
        const renamedFileStat = await fs.promises.stat(pathToRenamedFile).catch(() => null);
        if (!originalFileStat || renamedFileStat) {
            log.chat.error('Either Source or Destination files are not available');
            return response.status(400).send({ error: true });
        }

        await fs.promises.copyFile(pathToOriginalFile, pathToRenamedFile);
        await fs.promises.unlink(pathToOriginalFile);
        chatInfoCache.delete(pathToOriginalFile);
        chatInfoCache.delete(pathToRenamedFile);
        log.chat.info('Successfully renamed chat file.');
        emitForRequest(request, 'chat-changed', { action: 'rename', file: sanitizedFileName });
        return response.send({ ok: true, sanitizedFileName });
    } catch (error) {
        log.chat.error('Error renaming chat file:', error);
        return response.status(500).send({ error: true });
    }
});

router.post('/delete', validateAvatarUrlMiddleware, async function (request, response) {
    try {
        if (!path.extname(request.body.chatfile)) {
            request.body.chatfile += '.jsonl';
        }

        const dirName = String(request.body.avatar_url).replace('.png', '');
        const chatFileName = String(request.body.chatfile);
        const chatFilePath = path.join(request.user.directories.chats, dirName, sanitize(chatFileName));
        if (!isPathUnderParent(request.user.directories.chats, chatFilePath)) {
            return response.sendStatus(400);
        }
        //Return success if the file was deleted.
        if (await tryDeleteFile(chatFilePath)) {
            chatInfoCache.delete(chatFilePath);
            emitForRequest(request, 'chat-changed', { action: 'delete', card: dirName, file: chatFileName });
            return response.send({ ok: true });
        } else {
            log.chat.error('The chat file was not deleted.');
            return response.sendStatus(400);
        }
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

router.post('/export', validateAvatarUrlMiddleware, async function (request, response) {
    if (!request.body.file || (!request.body.avatar_url && request.body.is_group === false)) {
        return response.sendStatus(400);
    }
    const pathToFolder = request.body.is_group
        ? request.user.directories.groupChats
        : path.join(request.user.directories.chats, String(request.body.avatar_url).replace('.png', ''));
    const filename = path.join(pathToFolder, sanitize(request.body.file));
    if (!request.body.is_group && !isPathUnderParent(request.user.directories.chats, filename)) {
        return response.sendStatus(400);
    }
    let exportfilename = request.body.exportfilename;
    const exportFileStat = await fs.promises.stat(filename).catch(() => null);
    if (!exportFileStat) {
        const errorMessage = {
            message: `Could not find JSONL file to export. Source chat file: ${filename}.`,
        };
        log.chat.error(errorMessage.message);
        return response.status(404).json(errorMessage);
    }
    try {
        // Short path for JSONL files
        if (request.body.format === 'jsonl') {
            try {
                const rawFile = await fs.promises.readFile(filename, 'utf8');
                const successMessage = {
                    message: `Chat saved to ${exportfilename}`,
                    result: rawFile,
                };

                log.chat.info(`Chat exported as ${exportfilename}`);
                return response.status(200).json(successMessage);
            } catch (err) {
                log.chat.error(err);
                const errorMessage = {
                    message: `Could not read JSONL file to export. Source chat file: ${filename}.`,
                };
                log.chat.error(errorMessage.message);
                return response.status(500).json(errorMessage);
            }
        }

        const readStream = fs.createReadStream(filename);
        const rl = readline.createInterface({
            input: readStream,
        });
        let buffer = '';
        rl.on('line', (line) => {
            const data = JSON.parse(line);
            // Skip non-printable/prompt-hidden messages
            if (data.is_system) {
                return;
            }
            if (data.mes) {
                const name = data.name;
                const message = (data?.extra?.display_text || data?.mes || '').replace(/\r?\n/g, '\n');
                buffer += (`${name}: ${message}\n\n`);
            }
        });
        rl.on('close', () => {
            const successMessage = {
                message: `Chat saved to ${exportfilename}`,
                result: buffer,
            };
            log.chat.info(`Chat exported as ${exportfilename}`);
            return response.status(200).json(successMessage);
        });
    } catch (err) {
        log.chat.error('chat export failed.', err);
        return response.sendStatus(400);
    }
});

router.post('/group/import', async function (request, response) {
    try {
        const filedata = request.file;

        if (!filedata) {
            return response.sendStatus(400);
        }

        const chatname = humanizedDateTime();
        const pathToUpload = path.join(filedata.destination, filedata.filename);
        const pathToNewFile = path.join(request.user.directories.groupChats, `${chatname}.jsonl`);
        await fs.promises.copyFile(pathToUpload, pathToNewFile);
        await fs.promises.unlink(pathToUpload);
        return response.send({ res: chatname });
    } catch (error) {
        log.chat.error(error);
        return response.send({ error: true });
    }
});

router.post('/import', validateAvatarUrlMiddleware, async function (request, response) {
    if (!request.body) return response.sendStatus(400);

    const format = request.body.file_type;
    const avatarUrl = (request.body.avatar_url).replace('.png', '');
    const characterName = sanitize(request.body.character_name) || 'Character';
    const userName = sanitize(request.body.user_name) || 'User';
    const fileNames = [];

    if (!request.file) {
        return response.sendStatus(400);
    }

    const directoryPath = path.join(request.user.directories.chats, avatarUrl);
    if (!isPathUnderParent(request.user.directories.chats, directoryPath)) {
        return response.sendStatus(400);
    }

    try {
        const pathToUpload = path.join(request.file.destination, request.file.filename);
        const data = await fs.promises.readFile(pathToUpload, 'utf8');

        if (format === 'json') {
            await fs.promises.unlink(pathToUpload);
            const jsonData = JSON.parse(data);

            /** @type {(userName: string, characterName: string, data: object) => string|string[]} */
            let importFunc;

            if (jsonData.savedsettings !== undefined) { // Kobold Lite format
                importFunc = importKoboldLiteChat;
            } else if (jsonData.histories !== undefined) { // CAI Tools format
                importFunc = importCAIChat;
            } else if (Array.isArray(jsonData.data_visible)) { // oobabooga's format
                importFunc = importOobaChat;
            } else if (Array.isArray(jsonData.messages)) { // Agnai's format
                importFunc = importAgnaiChat;
            } else if (jsonData.type === 'risuChat') { // RisuAI format
                importFunc = importRisuChat;
            } else { // Unknown format
                log.chat.error('Incorrect chat format .json');
                return response.send({ error: true });
            }

            const handleChat = async (chat) => {
                const fileName = `${characterName} - ${humanizedDateTime()} imported.jsonl`;
                const filePath = path.join(directoryPath, fileName);
                fileNames.push(fileName);
                await writeFileAtomic(filePath, chat, 'utf8');
            };

            const chat = importFunc(userName, characterName, jsonData);

            if (Array.isArray(chat)) {
                for (const chatItem of chat) {
                    await handleChat(chatItem);
                }
            } else {
                await handleChat(chat);
            }

            return response.send({ res: true, fileNames });
        }

        if (format === 'jsonl') {
            let lines = data.split('\n');
            const header = lines[0];

            const jsonData = JSON.parse(header);

            if (!(jsonData.user_name !== undefined || jsonData.name !== undefined || jsonData.chat_metadata !== undefined)) {
                log.chat.error('Incorrect chat format .jsonl');
                return response.send({ error: true });
            }

            // Do a tiny bit of work to import Chub Chat data
            // Processing the entire file is so fast that it's not worth checking if it's a Chub chat first
            let flattenedChat = data;
            try {
                // flattening is unlikely to break, but it's not worth failing to
                // import normal chats in an attempt to import a Chub chat
                flattenedChat = flattenChubChat(userName, characterName, lines);
            } catch (error) {
                log.chat.warn('Failed to flatten Chub Chat data: ', error);
            }

            const fileName = `${characterName} - ${humanizedDateTime()} imported.jsonl`;
            const filePath = path.join(directoryPath, fileName);
            fileNames.push(fileName);
            if (flattenedChat !== data) {
                await writeFileAtomic(filePath, flattenedChat, 'utf8');
            } else {
                await fs.promises.copyFile(pathToUpload, filePath);
            }
            await fs.promises.unlink(pathToUpload);
            response.send({ res: true, fileNames });
        }
    } catch (error) {
        log.chat.error(error);
        return response.send({ error: true });
    }
});

router.post('/group/get', async (request, response) => {
    try {
        if (!request.body || !request.body.id) {
            return response.sendStatus(400);
        }

        const ref = ChatRef.group(request.user, request.body.id);
        if (!ref) {
            return response.sendStatus(400);
        }

        const opts = readPageOpts(request.body);
        if (opts.paged) {
            const fileStat = await fs.promises.stat(ref.filePath).catch(() => null);
            if (!fileStat) {
                return response.send(emptyChatPage());
            }
            const page = await buildChatPage(ref.filePath, opts);
            return response.status(page.status).send(page.body);
        }

        return response.send(await getChatData(ref.filePath));
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

router.post('/group/info', async (request, response) => {
    try {
        if (!request.body || !request.body.id) {
            return response.sendStatus(400);
        }

        const id = request.body.id;
        const chatFilePath = path.join(request.user.directories.groupChats, sanitize(`${id}.jsonl`));

        const chatInfo = await getChatInfo(chatFilePath);
        return response.send(chatInfo);
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

router.post('/group/delete', async (request, response) => {
    try {
        if (!request.body || !request.body.id) {
            return response.sendStatus(400);
        }

        const id = request.body.id;
        const chatFilePath = path.join(request.user.directories.groupChats, sanitize(`${id}.jsonl`));

        //Return success if the file was deleted.
        if (await tryDeleteFile(chatFilePath)) {
            chatInfoCache.delete(chatFilePath);
            return response.send({ ok: true });
        } else {
            log.chat.error('The group chat file was not deleted.');
            return response.sendStatus(400);
        }
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

router.post('/group/save', async function (request, response) {
    try {
        if (!request.body || !request.body.id) {
            return response.sendStatus(400);
        }

        const id = request.body.id;
        const handle = request.user.profile.handle;
        const chatFilePath = path.join(request.user.directories.groupChats, sanitize(`${id}.jsonl`));
        const chatData = request.body.chat;

        if (Array.isArray(chatData)) {
            await trySaveChat(chatData, chatFilePath, request.body.force, handle, String(id), request.user.directories.backups);
            return response.send({ ok: true });
        } else {
            return response.status(400).send({ error: 'The request\'s body.chat is not an array.' });
        }
    } catch (error) {
        if (error instanceof IntegrityMismatchError) {
            log.chat.error(error.message);
            return response.status(400).send({ error: 'integrity' });
        }
        log.chat.error(error);
        return response.status(500).send({ error: 'An error has occurred, see the console logs for more information.' });
    }
});

router.post('/search', validateAvatarUrlMiddleware, async function (request, response) {
    try {
        const { query, avatar_url, group_id } = request.body;

        /** @type {string[]} */
        let chatFiles = [];

        if (group_id) {
            // Find group's chat IDs first
            const groupDir = path.join(request.user.directories.groups);
            const groupFiles = (await fs.promises.readdir(groupDir))
                .filter(file => path.extname(file) === '.json');

            let targetGroup;
            for (const groupFile of groupFiles) {
                try {
                    const groupData = JSON.parse(await fs.promises.readFile(path.join(groupDir, groupFile), 'utf8'));
                    if (groupData.id === group_id) {
                        targetGroup = groupData;
                        break;
                    }
                } catch (error) {
                    log.chat.warn(groupFile, 'group file is corrupted:', error);
                }
            }

            if (!Array.isArray(targetGroup?.chats)) {
                return response.send([]);
            }

            // Find group chat files for given group ID
            const groupChatsDir = path.join(request.user.directories.groupChats);
            for (const chatId of targetGroup.chats) {
                const chatFilePath = path.join(groupChatsDir, `${chatId}.jsonl`);
                const chatFileStat = await fs.promises.stat(chatFilePath).catch(() => null);
                if (chatFileStat) {
                    chatFiles.push(chatFilePath);
                }
            }
        } else {
            // Regular character chat directory
            const character_name = avatar_url.replace('.png', '');
            const directoryPath = path.join(request.user.directories.chats, character_name);

            const chatsDirStat = await fs.promises.stat(directoryPath).catch(() => null);
            if (!chatsDirStat) {
                return response.send([]);
            }

            chatFiles = (await fs.promises.readdir(directoryPath))
                .filter(file => path.extname(file) === '.jsonl')
                .map(fileName => path.join(directoryPath, fileName));
        }

        /**
         * @type {SearchChatResult[]}
         * @typedef {object} SearchChatResult
         * @property {string} [file_name] - The name of the chat file
         * @property {string} [file_size] - The size of the chat file in a human-readable format
         * @property {number} [message_count] - The number of messages in the chat
         * @property {number|string} [last_mes] - The timestamp of the last message
         * @property {string} [preview_message] - A preview of the last message
         */
        const results = [];

        /** @type {string[]} */
        const fragments = query ? query.trim().toLowerCase().split(/\s+/).filter(x => x) : [];

        /** @type {ChatMatchFunction} */
        const hasTextMatch = (textArray) => {
            if (fragments.length === 0) {
                return true;
            }
            return fragments.every(fragment => textArray.some(text => String(text ?? '').toLowerCase().includes(fragment)));
        };

        for (const chatFile of chatFiles) {
            const matcher = query ? hasTextMatch : null;
            const chatInfo = await getChatInfo(chatFile, {}, false, matcher);
            const hasMatch = chatInfo.match || hasTextMatch([chatInfo.file_id ?? '']);

            // Skip corrupted or invalid chat files
            if (!chatInfo.file_name) {
                continue;
            }

            // Empty chats without a file name match are skipped when searching with a query
            if (query && chatInfo.chat_items === 0 && !hasMatch) {
                continue;
            }

            // If no search query or a match was found, include the chat in results
            if (!query || hasMatch) {
                results.push({
                    file_name: chatInfo.file_id,
                    file_size: chatInfo.file_size,
                    message_count: chatInfo.chat_items,
                    last_mes: chatInfo.last_mes,
                    preview_message: getPreviewMessage(chatInfo.mes),
                });
            }
        }

        return response.send(results);
    } catch (error) {
        log.chat.error('Chat search error:', error);
        return response.status(500).json({ error: 'Search failed' });
    }
});

router.post('/recent', async function (request, response) {
    try {
        /** @typedef {{pngFile?: string, groupId?: string, filePath: string, mtime: number}} ChatFile */
        // Mirrors PinnedChat in public/scripts/welcome-screen.js; inlined so the type gate does not pull the frontend bundle in.
        /** @typedef {{group: string, avatar: string, file_name: string}} PinnedChat */
        /** @type {ChatFile[]} */
        const allChatFiles = [];
        /** @type {PinnedChat[]} */
        const pinnedChats = Array.isArray(request.body.pinned) ? request.body.pinned : [];

        const getCharacterChatFiles = async () => {
            const pngDirents = await fs.promises.readdir(request.user.directories.characters, { withFileTypes: true });
            const pngFiles = pngDirents.filter(e => e.isFile() && path.extname(e.name) === '.png').map(e => e.name);

            for (const pngFile of pngFiles) {
                const chatsDirectory = pngFile.replace('.png', '');
                const pathToChats = path.join(request.user.directories.chats, chatsDirectory);
                const pathStats = await fs.promises.stat(pathToChats).catch(() => null);
                if (!pathStats) {
                    continue;
                }
                if (pathStats.isDirectory()) {
                    const chatFiles = await fs.promises.readdir(pathToChats);
                    const jsonlFiles = chatFiles.filter(file => path.extname(file) === '.jsonl');

                    for (const file of jsonlFiles) {
                        const filePath = path.join(pathToChats, file);
                        const stats = await fs.promises.stat(filePath);
                        allChatFiles.push({ pngFile, filePath, mtime: stats.mtimeMs });
                    }
                }
            }
        };

        const getGroupChatFiles = async () => {
            const groupDirents = await fs.promises.readdir(request.user.directories.groups, { withFileTypes: true });
            const groups = groupDirents.filter(e => e.isFile() && path.extname(e.name) === '.json').map(e => e.name);

            for (const group of groups) {
                try {
                    const groupPath = path.join(request.user.directories.groups, group);
                    const groupContents = await fs.promises.readFile(groupPath, 'utf8');
                    const groupData = JSON.parse(groupContents);

                    if (Array.isArray(groupData.chats)) {
                        for (const chat of groupData.chats) {
                            const filePath = path.join(request.user.directories.groupChats, `${chat}.jsonl`);
                            const stats = await fs.promises.stat(filePath).catch(() => null);
                            if (!stats) {
                                continue;
                            }
                            allChatFiles.push({ groupId: groupData.id, filePath, mtime: stats.mtimeMs });
                        }
                    }
                } catch (error) {
                    // Skip group files that can't be read or parsed
                    continue;
                }
            }
        };

        const getRootChatFiles = async () => {
            const dirents = await fs.promises.readdir(request.user.directories.chats, { withFileTypes: true });
            const chatFiles = dirents.filter(e => e.isFile() && path.extname(e.name) === '.jsonl').map(e => e.name);

            for (const file of chatFiles) {
                const filePath = path.join(request.user.directories.chats, file);
                const stats = await fs.promises.stat(filePath);
                allChatFiles.push({ filePath, mtime: stats.mtimeMs });
            }
        };

        await Promise.allSettled([getCharacterChatFiles(), getGroupChatFiles(), getRootChatFiles()]);

        const max = parseInt(request.body.max ?? Number.MAX_SAFE_INTEGER) + pinnedChats.length;
        const isPinned = (/** @type {ChatFile} */ chatFile) => pinnedChats.some(p => p.file_name === path.basename(chatFile.filePath) && (p.avatar === chatFile.pngFile || p.group === chatFile.groupId));
        const recentChats = allChatFiles.sort((a, b) => {
            const isAPinned = isPinned(a);
            const isBPinned = isPinned(b);

            if (isAPinned && !isBPinned) return -1;
            if (!isAPinned && isBPinned) return 1;

            return b.mtime - a.mtime;
        }).slice(0, max);
        const jsonFilesPromise = recentChats.map((file) => {
            const withMetadata = !!request.body.metadata;
            return file.groupId
                ? getChatInfo(file.filePath, { group: file.groupId }, withMetadata)
                : getChatInfo(file.filePath, { avatar: file.pngFile }, withMetadata);
        });

        const chatData = (await Promise.allSettled(jsonFilesPromise)).filter(x => x.status === 'fulfilled').map(x => x.value);
        const validFiles = chatData.filter(i => i.file_name);

        return response.send(validFiles);
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

const UNDO_BACKUP_TS_RE = /^[0-9]{8}-[0-9]{6}$/;

// Per-file write serialization: the change-token gate leaves a read-to-write window a concurrent
// save can slip through, so every undo write runs under this chain and re-checks the token before writing.
/** @type {Map<string, Promise<any>>} */
const undoWriteLocks = new Map();

/**
 * Runs task after any in-flight write on the same file settles, so two undo writes never interleave.
 * @param {string} filePath The chat file being written.
 * @param {() => Promise<any>} task The read-check-write body.
 * @returns {Promise<any>}
 */
function withFileLock(filePath, task) {
    const prev = undoWriteLocks.get(filePath) || Promise.resolve();
    const run = prev.catch(() => {}).then(task);
    const guard = run.catch(() => {});
    undoWriteLocks.set(filePath, guard);
    guard.then(() => {
        if (undoWriteLocks.get(filePath) === guard) {
            undoWriteLocks.delete(filePath);
        }
    });
    return run;
}

/**
 * Full-file change token, matching the tail token the spine issues for a whole read.
 * @param {string} headerRaw Raw header line.
 * @param {Array<{raw: string}>} messages Parsed message entries.
 * @returns {string}
 */
function computeFullToken(headerRaw, messages) {
    return buildToken(messages.length, prefixHash(headerRaw, messages, messages.length - 1));
}

/**
 * Resolves the target chat file and its backup base name for a solo or group undo request.
 * @param {any} request The Express request.
 * @returns {{ref: ChatRef, cardName: string}|null} Null when the ref escapes its root or params are missing.
 */
function resolveUndoRef(request) {
    if (request.body.group_id) {
        const ref = ChatRef.group(request.user, request.body.group_id);
        return ref ? { ref, cardName: String(request.body.group_id) } : null;
    }
    if (!request.body.avatar_url || !request.body.file_name) {
        return null;
    }
    const ref = ChatRef.solo(request.user, request.body.avatar_url, request.body.file_name);
    return ref ? { ref, cardName: String(request.body.avatar_url).replace('.png', '') } : null;
}

/**
 * Resolves a target message index from a cf_id or an absolute message index.
 * @param {any} body The request body.
 * @param {Array} currentObjs Current message objects (header excluded).
 * @returns {number} The index, or -1 when the target cannot be resolved.
 */
function resolveTargetIndex(body, currentObjs) {
    if (typeof body.cf_id === 'string' && body.cf_id.length > 0) {
        return currentObjs.findIndex(m => m.cf_id === body.cf_id);
    }
    if (Number.isInteger(body.index) && body.index >= 0 && body.index < currentObjs.length) {
        return body.index;
    }
    return -1;
}

/**
 * Reads the current chat and finds one discovered backup by its validated timestamp.
 * @param {ChatRef} ref The chat ref.
 * @param {string} cardName The card name or group id.
 * @param {string} backupsDir The user's backups directory.
 * @param {string} backupTs The requested backup timestamp.
 * @returns {Promise<{ok: false, status: number, error: string}|{ok: true, backup: any}>}
 */
async function findRequestedBackup(ref, cardName, backupsDir, backupTs) {
    if (typeof backupTs !== 'string' || !UNDO_BACKUP_TS_RE.test(backupTs)) {
        return { ok: false, status: 400, error: 'bad_backup_ts' };
    }
    const { header } = await readChatFile(ref.filePath);
    const identity = chatIdentity(header);
    const { backups } = await discoverChatBackups(backupsDir, backupBaseName(cardName), identity);
    const backup = backups.find(b => b.ts === backupTs);
    if (!backup || !isPathUnderParent(backupsDir, backup.filePath)) {
        return { ok: false, status: 404, error: 'no_such_backup' };
    }
    return { ok: true, backup };
}

router.post('/backups/message-versions', async function (request, response) {
    try {
        const resolved = resolveUndoRef(request);
        if (!resolved) {
            return response.sendStatus(400);
        }
        const backupsDir = request.user.directories.backups;
        const { header, headerRaw, messages } = await readChatFile(resolved.ref.filePath);
        const currentObjs = messages.map(m => m.obj);
        const identity = chatIdentity(header);
        const targetIndex = resolveTargetIndex(request.body, currentObjs);
        if (targetIndex < 0) {
            return response.status(400).send({ error: 'target_not_found' });
        }

        const { backups, truncated, attributable } = await discoverChatBackups(backupsDir, backupBaseName(resolved.cardName), identity);
        const versions = [];
        let prevText = currentObjs[targetIndex].mes || '';
        for (const backup of backups) {
            const version = versionInBackup(currentObjs, targetIndex, backup.messages);
            if (version === null) {
                break;
            }
            if (version.text !== prevText) {
                versions.push({ mes: version.text, backup_ts: backup.ts, matched: version.matched });
                prevText = version.text;
            }
        }

        // The token a restore call passes back so a save that lands first is caught, not clobbered.
        return response.send({ versions, depth: backups.length, truncated, basis: identityBasis(identity), attributable, change_token: computeFullToken(headerRaw, messages) });
    } catch (error) {
        log.chat.error(error);
        return response.sendStatus(500);
    }
});

router.post('/backups/restore-message', async function (request, response) {
    try {
        const resolved = resolveUndoRef(request);
        if (!resolved) {
            return response.sendStatus(400);
        }
        const handle = request.user.profile.handle;
        const backupsDir = request.user.directories.backups;

        await withFileLock(resolved.ref.filePath, async () => {
            const entry = await readChatFile(resolved.ref.filePath);
            const currentObjs = entry.messages.map(m => m.obj);
            const entryToken = computeFullToken(entry.headerRaw, entry.messages);
            if (typeof request.body.change_token === 'string' && request.body.change_token !== entryToken) {
                return response.status(409).send({ error: 'stale', change_token: entryToken });
            }
            const targetIndex = resolveTargetIndex(request.body, currentObjs);
            if (targetIndex < 0) {
                return response.status(400).send({ error: 'target_not_found' });
            }

            const found = await findRequestedBackup(resolved.ref, resolved.cardName, backupsDir, request.body.backup_ts);
            if (!found.ok) {
                return response.status(found.status).send({ error: found.error });
            }
            const version = versionInBackup(currentObjs, targetIndex, found.backup.messages);
            if (version === null) {
                return response.status(404).send({ error: 'message_absent_in_backup' });
            }

            const target = currentObjs[targetIndex];
            target.mes = version.text;
            if (Array.isArray(target.swipes)) {
                const swipeId = Number.isInteger(request.body.swipe_id) ? request.body.swipe_id
                    : (Number.isInteger(target.swipe_id) ? target.swipe_id : 0);
                if (swipeId >= 0 && swipeId < target.swipes.length) {
                    target.swipes[swipeId] = version.text;
                }
            }

            const recheck = await readChatFile(resolved.ref.filePath);
            if (computeFullToken(recheck.headerRaw, recheck.messages) !== entryToken) {
                return response.status(409).send({ error: 'stale', change_token: computeFullToken(recheck.headerRaw, recheck.messages) });
            }

            const fullArray = entry.header ? [entry.header, ...currentObjs] : currentObjs;
            await trySaveChat(fullArray, resolved.ref.filePath, true, handle, resolved.cardName, backupsDir);
            const after = await readChatFile(resolved.ref.filePath);
            return response.send({ ok: true, change_token: computeFullToken(after.headerRaw, after.messages), restored: { index: targetIndex, matched: version.matched, backup_ts: found.backup.ts } });
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/backups/restore-deleted', async function (request, response) {
    try {
        const resolved = resolveUndoRef(request);
        if (!resolved) {
            return response.sendStatus(400);
        }
        const handle = request.user.profile.handle;
        const backupsDir = request.user.directories.backups;

        await withFileLock(resolved.ref.filePath, async () => {
            const entry = await readChatFile(resolved.ref.filePath);
            const currentObjs = entry.messages.map(m => m.obj);
            const entryToken = computeFullToken(entry.headerRaw, entry.messages);
            if (typeof request.body.change_token === 'string' && request.body.change_token !== entryToken) {
                return response.status(409).send({ error: 'stale', change_token: entryToken });
            }

            const found = await findRequestedBackup(resolved.ref, resolved.cardName, backupsDir, request.body.backup_ts);
            if (!found.ok) {
                return response.status(found.status).send({ error: found.error });
            }

            const { messages: merged, restored, tooLarge } = restoreDeletedMessages(currentObjs, found.backup.messages);
            if (tooLarge) {
                return response.status(413).send({ error: 'too_large' });
            }
            if (restored === 0) {
                return response.send({ ok: true, restored: 0, change_token: entryToken });
            }

            const recheck = await readChatFile(resolved.ref.filePath);
            if (computeFullToken(recheck.headerRaw, recheck.messages) !== entryToken) {
                return response.status(409).send({ error: 'stale', change_token: computeFullToken(recheck.headerRaw, recheck.messages) });
            }

            const fullArray = entry.header ? [entry.header, ...merged] : merged;
            await trySaveChat(fullArray, resolved.ref.filePath, true, handle, resolved.cardName, backupsDir);
            const after = await readChatFile(resolved.ref.filePath);
            return response.send({ ok: true, restored, change_token: computeFullToken(after.headerRaw, after.messages) });
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/backups/snapshots', async function (request, response) {
    try {
        const resolved = resolveUndoRef(request);
        if (!resolved) {
            return response.sendStatus(400);
        }
        const backupsDir = request.user.directories.backups;

        if (request.body.mode === 'restore') {
            const handle = request.user.profile.handle;
            await withFileLock(resolved.ref.filePath, async () => {
                const entry = await readChatFile(resolved.ref.filePath);
                const entryToken = computeFullToken(entry.headerRaw, entry.messages);
                if (typeof request.body.change_token === 'string' && request.body.change_token !== entryToken) {
                    return response.status(409).send({ error: 'stale', change_token: entryToken });
                }
                const found = await findRequestedBackup(resolved.ref, resolved.cardName, backupsDir, request.body.backup_ts);
                if (!found.ok) {
                    return response.status(found.status).send({ error: found.error });
                }

                const recheck = await readChatFile(resolved.ref.filePath);
                if (computeFullToken(recheck.headerRaw, recheck.messages) !== entryToken) {
                    return response.status(409).send({ error: 'stale', change_token: computeFullToken(recheck.headerRaw, recheck.messages) });
                }

                // Keep the current header so the file stays the same chat (identity preserved); take the snapshot's messages.
                const fullArray = entry.header ? [entry.header, ...found.backup.messages] : found.backup.messages;
                await trySaveChat(fullArray, resolved.ref.filePath, true, handle, resolved.cardName, backupsDir);
                const after = await readChatFile(resolved.ref.filePath);
                return response.send({ ok: true, restored: found.backup.messages.length, change_token: computeFullToken(after.headerRaw, after.messages) });
            });
            return;
        }

        const { header, headerRaw, messages } = await readChatFile(resolved.ref.filePath);
        const currentObjs = messages.map(m => m.obj);
        const identity = chatIdentity(header);
        const { backups, truncated, attributable } = await discoverChatBackups(backupsDir, backupBaseName(resolved.cardName), identity);
        const snapshots = backups.map((backup) => {
            const summary = diffSummary(backup.messages, currentObjs);
            const last = backup.messages[backup.messages.length - 1];
            return {
                backup_ts: backup.ts,
                message_count: backup.messages.length,
                last_mes_preview: getPreviewMessage(last?.mes),
                added: summary.added,
                removed: summary.removed,
                edited: summary.edited,
                basis: summary.basis,
                too_large: summary.tooLarge,
            };
        });
        return response.send({ snapshots, depth: backups.length, truncated, basis: identityBasis(identity), attributable, change_token: computeFullToken(headerRaw, messages) });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

/**
 * Tail change token for a parsed chat. Mirrors buildChatPage's tail branch so an append's
 * returned token equals what a later /get tail computes for the same file and limit.
 * @param {string} headerRaw Raw header line.
 * @param {Array<{raw: string}>} messages Parsed message entries.
 * @param {*} limit The caller's window size.
 * @returns {string}
 */
function tailToken(headerRaw, messages, limit) {
    const total = messages.length;
    const start = Math.max(0, total - clampLimit(limit));
    const boundary = total === 0 ? -1 : start;
    return buildToken(total, prefixHash(headerRaw, messages, boundary));
}

/**
 * Appends messages to an existing chat without reading or overwriting the whole file, so a
 * windowed client that holds only a tail can persist new turns. Existing bytes are copied
 * forward verbatim: the header and every prior line stay byte-identical, history never truncates.
 */
router.post('/append', async function (request, response) {
    try {
        const resolved = resolveUndoRef(request);
        if (!resolved) {
            return response.sendStatus(400);
        }
        const messages = request.body.messages;
        const isMessageObject = m => m !== null && typeof m === 'object' && !Array.isArray(m);
        if (!Array.isArray(messages) || messages.length === 0 || !messages.every(isMessageObject)) {
            return response.status(400).send({ error: 'messages must be a non-empty array of objects' });
        }
        const handle = request.user.profile.handle;
        const backupsDir = request.user.directories.backups;

        const fileStat = await fs.promises.stat(resolved.ref.filePath).catch(() => null);
        if (!fileStat || fileStat.size === 0) {
            return response.status(404).send({ error: 'not_found' });
        }

        await withFileLock(resolved.ref.filePath, async () => {
            const raw = await tryReadFile(resolved.ref.filePath);
            if (raw === null || raw.length === 0) {
                return response.status(404).send({ error: 'not_found' });
            }
            const parsed = parseChatContent(raw);
            // Gate on the whole-file token, not the tail token: the tail token depends on the window
            // limit, so a client that re-synced at one limit and appends at another would 409 forever.
            const entryToken = computeFullToken(parsed.headerRaw, parsed.messages);
            if (typeof request.body.change_token === 'string' && request.body.change_token !== entryToken) {
                return response.status(409).send({ error: 'version_mismatch', change_token: entryToken });
            }
            if (cfIdEnabled) {
                mintChatIds(messages);
            }
            const appendedRaw = messages.map(m => JSON.stringify(m)).join('\n');
            const base = raw.endsWith('\n') ? raw.slice(0, -1) : raw;
            await tryWriteFile(resolved.ref.filePath, `${base}\n${appendedRaw}`);
            chatInfoCache.delete(resolved.ref.filePath);
            getBackupFunction(handle)(backupsDir, resolved.cardName, `${base}\n${appendedRaw}`);
            bustCharacterListCacheForCharacter(handle, resolved.cardName);
            const after = await readChatFile(resolved.ref.filePath);
            // Hot path: the appended messages ride the event so another device appends them
            // directly instead of refetching the whole chat file.
            emitForRequest(request, 'chat-appended', {
                card: resolved.cardName,
                file: request.body.file_name ? String(request.body.file_name) : null,
                group_id: request.body.group_id ? String(request.body.group_id) : null,
                messages,
                change_token: computeFullToken(after.headerRaw, after.messages),
            });
            // change_token is the whole-file token (the append gate); tail_token refreshes the reader's
            // window path in the same response, mirroring runMutation's edit/delete contract.
            return response.send({
                ok: true,
                appended: messages.length,
                change_token: computeFullToken(after.headerRaw, after.messages),
                tail_token: tailToken(after.headerRaw, after.messages, request.body.limit),
            });
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

/**
 * Shared read-modify-write body for the windowed mutation family. Resolves the solo/group ref,
 * takes the per-file lock, gates on the FULL token with the restore-message double-read recheck,
 * runs an in-place mutation on the message objects, saves the whole array, and returns the
 * descriptor response the windowed reader needs. The client sends only a descriptor; the whole
 * file is read and rewritten here, so history above the reader's window cannot truncate.
 * @param {any} request Express request.
 * @param {any} response Express response.
 * @param {(objs: Array, body: any, entry: any) => ({index: number, obj: any}|{status: number, error: string})} mutate
 *   In-place mutation returning the touched index plus the affected message object, or an error descriptor.
 * @returns {Promise<void>}
 */
async function runMutation(request, response, mutate) {
    const resolved = resolveUndoRef(request);
    if (!resolved) {
        return response.sendStatus(400);
    }
    const handle = request.user.profile.handle;
    const backupsDir = request.user.directories.backups;

    await withFileLock(resolved.ref.filePath, async () => {
        const entry = await readChatFile(resolved.ref.filePath);
        const currentObjs = entry.messages.map(m => m.obj);
        const entryToken = computeFullToken(entry.headerRaw, entry.messages);
        if (typeof request.body.change_token === 'string' && request.body.change_token !== entryToken) {
            return response.status(409).send({ error: 'stale', change_token: entryToken });
        }

        const result = mutate(currentObjs, request.body, entry);
        if (result && 'status' in result) {
            return response.status(result.status).send({ error: result.error });
        }

        const recheck = await readChatFile(resolved.ref.filePath);
        if (computeFullToken(recheck.headerRaw, recheck.messages) !== entryToken) {
            return response.status(409).send({ error: 'stale', change_token: computeFullToken(recheck.headerRaw, recheck.messages) });
        }

        const fullArray = entry.header ? [entry.header, ...currentObjs] : currentObjs;
        await trySaveChat(fullArray, resolved.ref.filePath, true, handle, resolved.cardName, backupsDir);
        const after = await readChatFile(resolved.ref.filePath);
        // trySaveChat mints cf_ids in place on the saved objects, so the affected object's id is
        // read AFTER the save; delete holds a removed object that keeps its pre-save id (or none).
        const affectedCfId = result.obj && typeof result.obj.cf_id === 'string' ? result.obj.cf_id : null;
        // change_token IS the full token here (the mutation gate), so no separate full_token field;
        // tail_token refreshes the reader's window path in the same response.
        return response.send({
            ok: true,
            change_token: computeFullToken(after.headerRaw, after.messages),
            tail_token: tailToken(after.headerRaw, after.messages, request.body.limit),
            affected_cf_id: affectedCfId,
            index: result.index,
            total_items: after.messages.length,
        });
    });
}

router.post('/message/edit', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body) => {
            if (typeof body.text !== 'string') {
                return { status: 400, error: 'text must be a string' };
            }
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            const target = objs[i];
            target.mes = body.text;
            if (Array.isArray(target.swipes)) {
                const swipeId = Number.isInteger(body.swipe_id) ? body.swipe_id
                    : (Number.isInteger(target.swipe_id) ? target.swipe_id : 0);
                if (swipeId >= 0 && swipeId < target.swipes.length) {
                    target.swipes[swipeId] = body.text;
                }
            }
            return { index: i, obj: target };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/message/delete', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body) => {
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            const removed = objs[i];
            objs.splice(i, 1);
            return { index: i, obj: removed };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/message/move', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body) => {
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            const j = body.direction === 'up' ? i - 1 : body.direction === 'down' ? i + 1 : -1;
            if (j < 0 || j >= objs.length) {
                return { status: 400, error: 'out_of_range' };
            }
            const swap = objs[i];
            objs[i] = objs[j];
            objs[j] = swap;
            return { index: j, obj: objs[j] };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/message/hide', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body) => {
            if (typeof body.hidden !== 'boolean') {
                return { status: 400, error: 'hidden must be a boolean' };
            }
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            objs[i].is_system = body.hidden;
            return { index: i, obj: objs[i] };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/message/swipe-select', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body) => {
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            const target = objs[i];
            if (!Array.isArray(target.swipes) || target.swipes.length === 0) {
                return { status: 400, error: 'no_swipes' };
            }
            if (!Number.isInteger(body.swipe_id) || body.swipe_id < 0 || body.swipe_id >= target.swipes.length) {
                return { status: 400, error: 'swipe_out_of_range' };
            }
            target.swipe_id = body.swipe_id;
            target.mes = target.swipes[body.swipe_id];
            return { index: i, obj: target };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/message/checkpoint', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body, entry) => {
            const i = resolveTargetIndex(body, objs);
            if (i < 0) {
                return { status: 400, error: 'target_not_found' };
            }
            if (!entry.header) {
                return { status: 400, error: 'no_header' };
            }
            const meta = entry.header.chat_metadata = (entry.header.chat_metadata && typeof entry.header.chat_metadata === 'object') ? entry.header.chat_metadata : {};
            const marks = Array.isArray(meta.cf_checkpoints) ? meta.cf_checkpoints : (meta.cf_checkpoints = []);
            const cfId = objs[i].cf_id;
            marks.push({
                index: i,
                cf_id: typeof cfId === 'string' ? cfId : undefined,
                name: typeof body.name === 'string' ? body.name : undefined,
                created: Date.now(),
            });
            return { index: i, obj: objs[i] };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

/**
 * The author's note lives in the chat header, so a note edit is a header mutation and rides the same
 * helper as the message family (full-token gate, double-read recheck, whole-file rewrite).
 * The five keys are a literal allowlist, so a body cannot reach a key the client does not own.
 */
router.post('/metadata', async function (request, response) {
    try {
        await runMutation(request, response, (objs, body, entry) => {
            if (!entry.header) {
                return { status: 400, error: 'no_header' };
            }
            const meta = entry.header.chat_metadata = (entry.header.chat_metadata && typeof entry.header.chat_metadata === 'object') ? entry.header.chat_metadata : {};
            if ('note_prompt' in body) {
                if (typeof body.note_prompt !== 'string') {
                    return { status: 400, error: 'note_prompt must be a string' };
                }
                meta.note_prompt = body.note_prompt;
            }
            if ('note_interval' in body) {
                if (!Number.isFinite(body.note_interval)) {
                    return { status: 400, error: 'note_interval must be a number' };
                }
                meta.note_interval = body.note_interval;
            }
            if ('note_depth' in body) {
                if (!Number.isFinite(body.note_depth)) {
                    return { status: 400, error: 'note_depth must be a number' };
                }
                meta.note_depth = body.note_depth;
            }
            if ('note_position' in body) {
                if (!Number.isFinite(body.note_position)) {
                    return { status: 400, error: 'note_position must be a number' };
                }
                meta.note_position = body.note_position;
            }
            if ('note_role' in body) {
                if (typeof body.note_role !== 'string') {
                    return { status: 400, error: 'note_role must be a string' };
                }
                meta.note_role = body.note_role;
            }
            if ('world_info' in body) {
                if (typeof body.world_info !== 'string') {
                    return { status: 400, error: 'world_info must be a string' };
                }
                meta.world_info = body.world_info;
            }
            if ('timedWorldInfo' in body) {
                if (body.timedWorldInfo === null || typeof body.timedWorldInfo !== 'object' || Array.isArray(body.timedWorldInfo)) {
                    return { status: 400, error: 'timedWorldInfo must be an object' };
                }
                meta.timedWorldInfo = body.timedWorldInfo;
            }
            // No message changed, so there is no affected object to name: the header is the mutation.
            return { index: -1, obj: null };
        });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

/**
 * Resolves the destination ref for a duplicate/branch: a new solo file name in the same character
 * directory, or a new group id. Path traversal is guarded by ChatRef, same as the source.
 * @param {any} request The Express request.
 * @returns {ChatRef|null} The destination ref, or null when params are missing or escape the root.
 */
function resolveDestRef(request) {
    if (request.body.group_id) {
        return typeof request.body.new_id === 'string' && request.body.new_id.length > 0
            ? ChatRef.group(request.user, request.body.new_id) : null;
    }
    if (!request.body.avatar_url || typeof request.body.new_file_name !== 'string' || request.body.new_file_name.length === 0) {
        return null;
    }
    return ChatRef.solo(request.user, request.body.avatar_url, request.body.new_file_name);
}

router.post('/duplicate', async function (request, response) {
    try {
        const source = resolveUndoRef(request);
        const dest = resolveDestRef(request);
        if (!source || !dest) {
            return response.sendStatus(400);
        }
        const sourceStat = await fs.promises.stat(source.ref.filePath).catch(() => null);
        if (!sourceStat) {
            return response.status(404).send({ error: 'not_found' });
        }
        await fs.promises.mkdir(path.dirname(dest.filePath), { recursive: true });
        try {
            // COPYFILE_EXCL fails atomically if the destination exists, so a duplicate never clobbers a sibling.
            await fs.promises.copyFile(source.ref.filePath, dest.filePath, fs.constants.COPYFILE_EXCL);
        } catch (copyError) {
            if (typeof copyError === 'object' && copyError !== null && 'code' in copyError && copyError.code === 'EEXIST') {
                return response.status(409).send({ error: 'exists' });
            }
            throw copyError;
        }
        return response.send({ ok: true });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.post('/branch', async function (request, response) {
    try {
        const source = resolveUndoRef(request);
        const dest = resolveDestRef(request);
        if (!source || !dest) {
            return response.sendStatus(400);
        }
        const { header, headerRaw, messages } = await readChatFile(source.ref.filePath);
        const currentObjs = messages.map(m => m.obj);
        const targetIndex = resolveTargetIndex(request.body, currentObjs);
        if (targetIndex < 0) {
            return response.status(400).send({ error: 'target_not_found' });
        }
        // Copy the source prefix VERBATIM (raw lines, not re-serialized), so the branch's first
        // lines are byte-identical to the source and the source file is never touched.
        const lines = [];
        if (header) {
            lines.push(headerRaw);
        }
        for (let i = 0; i <= targetIndex; i++) {
            lines.push(messages[i].raw);
        }
        await fs.promises.mkdir(path.dirname(dest.filePath), { recursive: true });
        try {
            await fs.promises.writeFile(dest.filePath, lines.join('\n'), { encoding: 'utf8', flag: 'wx' });
        } catch (writeError) {
            if (typeof writeError === 'object' && writeError !== null && 'code' in writeError && writeError.code === 'EEXIST') {
                return response.status(409).send({ error: 'exists' });
            }
            throw writeError;
        }
        const after = await readChatFile(dest.filePath);
        return response.send({ ok: true, total_items: after.messages.length });
    } catch (error) {
        log.chat.error(error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

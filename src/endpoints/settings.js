import fs from 'node:fs';
import path from 'node:path';

import express from 'express';
import _ from 'lodash';
import writeFileAtomic from 'write-file-atomic';
import bytes from 'bytes';

import { SETTINGS_FILE } from '../constants.js';
import { getConfigValue, generateTimestamp, removeOldBackups } from '../util.js';
import { getAllUserHandles, getUserDirectories } from '../users.js';
import { getFileNameValidationFunction } from '../middleware/validateFileName.js';
import { log } from '../log.js';

const ENABLE_EXTENSIONS = !!getConfigValue('extensions.enabled', true, 'boolean');
const ENABLE_EXTENSIONS_AUTO_UPDATE = !!getConfigValue('extensions.autoUpdate', true, 'boolean');
const ENABLE_ACCOUNTS = !!getConfigValue('enableUserAccounts', false, 'boolean');
const ENABLE_REQUEST_COMPRESSION = !!getConfigValue('performance.requestCompression.enabled', false, 'boolean');
const REQUEST_COMPRESSION_MIN = bytes.parse(getConfigValue('performance.requestCompression.minPayloadSize', '256kb'));
const REQUEST_COMPRESSION_MAX = bytes.parse(getConfigValue('performance.requestCompression.maxPayloadSize', '8mb'));
const REQUEST_COMPRESSION_TIMEOUT = Number(getConfigValue('performance.requestCompression.timeout', 3000, 'number'));

// 10 minutes
const AUTOSAVE_INTERVAL = 10 * 60 * 1000;

/**
 * Map of functions to trigger settings autosave for a user.
 * @type {Map<string, function>}
 */
const AUTOSAVE_FUNCTIONS = new Map();

/**
 * Triggers autosave for a user every 10 minutes.
 * @param {string} handle User handle
 * @returns {void}
 */
function triggerAutoSave(handle) {
    if (!AUTOSAVE_FUNCTIONS.has(handle)) {
        const throttledAutoSave = _.throttle(() => backupUserSettings(handle, true).catch(err => log.settings.error('Could not backup settings file', err)), AUTOSAVE_INTERVAL);
        AUTOSAVE_FUNCTIONS.set(handle, throttledAutoSave);
    }

    const functionToCall = AUTOSAVE_FUNCTIONS.get(handle);
    if (functionToCall && typeof functionToCall === 'function') {
        functionToCall();
    }
}

/**
 * Reads and parses files from a directory.
 * @param {string} directoryPath Path to the directory
 * @param {string} fileExtension File extension
 * @returns {Promise<Array>} Parsed files
 */
async function readAndParseFromDirectory(directoryPath, fileExtension = '.json') {
    const files = (await fs.promises.readdir(directoryPath))
        .filter(x => path.parse(x).ext == fileExtension)
        .sort();

    const parsedFiles = [];

    for (const item of files) {
        try {
            const file = await fs.promises.readFile(path.join(directoryPath, item), 'utf-8');
            parsedFiles.push(fileExtension == '.json' ? JSON.parse(file) : file);
        } catch {
            // skip
        }
    }

    return parsedFiles;
}

/**
 * Gets a sort function for sorting strings.
 * @param {*} _
 * @returns {(a: string, b: string) => number} Sort function
 */
function sortByName(_) {
    return (a, b) => a.localeCompare(b);
}

/**
 * Gets backup file prefix for user settings.
 * @param {string} handle User handle
 * @returns {string} File prefix
 */
export function getSettingsBackupFilePrefix(handle) {
    return `settings_${handle}_`;
}

async function readPresetsFromDirectory(directoryPath, options = {}) {
    const {
        sortFunction,
        removeFileExtension = false,
        fileExtension = '.json',
    } = options;

    const files = (await fs.promises.readdir(directoryPath)).sort(sortFunction).filter(x => path.parse(x).ext == fileExtension);
    const fileContents = [];
    const fileNames = [];

    for (const item of files) {
        try {
            const file = await fs.promises.readFile(path.join(directoryPath, item), 'utf8');
            JSON.parse(file);
            fileContents.push(file);
            fileNames.push(removeFileExtension ? item.replace(/\.[^/.]+$/, '') : item);
        } catch {
            // skip
            log.settings.warn(`${item} is not a valid JSON`);
        }
    }

    return { fileContents, fileNames };
}

async function backupSettings() {
    try {
        const userHandles = await getAllUserHandles();

        for (const handle of userHandles) {
            await backupUserSettings(handle, true);
        }
    } catch (err) {
        log.settings.error('Could not backup settings file', err);
    }
}

/**
 * Makes a backup of the user's settings file.
 * @param {string} handle User handle
 * @param {boolean} preventDuplicates Prevent duplicate backups
 * @returns {Promise<void>}
 */
async function backupUserSettings(handle, preventDuplicates) {
    const userDirectories = getUserDirectories(handle);

    const rootStat = await fs.promises.stat(userDirectories.root).catch(() => null);
    if (!rootStat) {
        return;
    }

    const backupFile = path.join(userDirectories.backups, `${getSettingsBackupFilePrefix(handle)}${generateTimestamp()}.json`);
    const sourceFile = path.join(userDirectories.root, SETTINGS_FILE);

    if (preventDuplicates && await isDuplicateBackup(handle, sourceFile)) {
        return;
    }

    const sourceStat = await fs.promises.stat(sourceFile).catch(() => null);
    if (!sourceStat) {
        return;
    }

    await fs.promises.copyFile(sourceFile, backupFile);
    await removeOldBackups(userDirectories.backups, `settings_${handle}`);
}

/**
 * Checks if the backup would be a duplicate.
 * @param {string} handle User handle
 * @param {string} sourceFile Source file path
 * @returns {Promise<boolean>} True if the backup is a duplicate
 */
async function isDuplicateBackup(handle, sourceFile) {
    const latestBackup = await getLatestBackup(handle);
    if (!latestBackup) {
        return false;
    }
    return areFilesEqual(latestBackup, sourceFile);
}

/**
 * Returns true if the two files are equal.
 * @param {string} file1 File path
 * @param {string} file2 File path
 * @returns {Promise<boolean>}
 */
async function areFilesEqual(file1, file2) {
    const stat1 = await fs.promises.stat(file1).catch(() => null);
    const stat2 = await fs.promises.stat(file2).catch(() => null);
    if (!stat1 || !stat2) {
        return false;
    }

    const content1 = await fs.promises.readFile(file1);
    const content2 = await fs.promises.readFile(file2);
    return content1.toString() === content2.toString();
}

/**
 * Gets the latest backup file for a user.
 * @param {string} handle User handle
 * @returns {Promise<string|null>} Latest backup file. Null if no backup exists.
 */
async function getLatestBackup(handle) {
    const userDirectories = getUserDirectories(handle);
    const backupFileNames = (await fs.promises.readdir(userDirectories.backups))
        .filter(x => x.startsWith(getSettingsBackupFilePrefix(handle)));
    const backupFiles = [];
    for (const name of backupFileNames) {
        const stat = await fs.promises.stat(path.join(userDirectories.backups, name));
        backupFiles.push({ name, ctime: stat.ctimeMs });
    }
    const latestBackup = backupFiles.sort((a, b) => b.ctime - a.ctime)[0]?.name;
    if (!latestBackup) {
        return null;
    }
    return path.join(userDirectories.backups, latestBackup);
}

/**
 * Cached non-user portion of the /settings/get payload, keyed by user handle.
 * settings.json (the user settings) is never cached; only the composed presets,
 * themes, worlds and preset-family directories.
 * @type {Map<string, {mtimes: Record<string, number>, payload: object}>}
 */
const SETTINGS_PAYLOAD_CACHE = new Map();

/**
 * Directories whose contents compose the non-user settings payload.
 * @param {import('../users.js').UserDirectoryList} directories User directories
 * @returns {string[]} Directory paths
 */
function getComposedSettingsDirs(directories) {
    return [
        directories.novelAI_Settings,
        directories.openAI_Settings,
        directories.textGen_Settings,
        directories.koboldAI_Settings,
        directories.worlds,
        directories.themes,
        directories.movingUI,
        directories.quickreplies,
        directories.instruct,
        directories.context,
        directories.sysprompt,
        directories.reasoning,
    ];
}

/**
 * Reads directory mtimes for the composed settings dirs.
 * @param {import('../users.js').UserDirectoryList} directories User directories
 * @returns {Promise<Record<string, number>>} Map of dir path to mtimeMs (-1 when missing)
 */
async function probeSettingsDirMtimes(directories) {
    const dirs = getComposedSettingsDirs(directories);
    const entries = await Promise.all(dirs.map(async (dir) => {
        const stat = await fs.promises.stat(dir).catch(() => null);
        return [dir, stat ? stat.mtimeMs : -1];
    }));
    return Object.fromEntries(entries);
}

/**
 * Returns true when two directory mtime maps are identical.
 * @param {Record<string, number>} a First map
 * @param {Record<string, number>} b Second map
 * @returns {boolean}
 */
function settingsDirMtimesMatch(a, b) {
    const keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length) {
        return false;
    }
    return keys.every(key => a[key] === b[key]);
}

/**
 * Composes the non-user portion of the settings payload from disk.
 * @param {import('../users.js').UserDirectoryList} directories User directories
 * @returns {Promise<object>} The composed payload (without the user settings blob)
 */
async function composeSettingsPayload(directories) {
    const { fileContents: novelai_settings, fileNames: novelai_setting_names }
        = await readPresetsFromDirectory(directories.novelAI_Settings, {
            sortFunction: sortByName(directories.novelAI_Settings),
            removeFileExtension: true,
        });

    const { fileContents: openai_settings, fileNames: openai_setting_names }
        = await readPresetsFromDirectory(directories.openAI_Settings, {
            sortFunction: sortByName(directories.openAI_Settings), removeFileExtension: true,
        });

    const { fileContents: textgenerationwebui_presets, fileNames: textgenerationwebui_preset_names }
        = await readPresetsFromDirectory(directories.textGen_Settings, {
            sortFunction: sortByName(directories.textGen_Settings), removeFileExtension: true,
        });

    const { fileContents: koboldai_settings, fileNames: koboldai_setting_names }
        = await readPresetsFromDirectory(directories.koboldAI_Settings, {
            sortFunction: sortByName(directories.koboldAI_Settings), removeFileExtension: true,
        });

    const worldFiles = (await fs.promises.readdir(directories.worlds))
        .filter(file => path.extname(file).toLowerCase() === '.json')
        .sort((a, b) => a.localeCompare(b));
    const world_names = worldFiles.map(item => path.parse(item).name);

    const themes = await readAndParseFromDirectory(directories.themes);
    const movingUIPresets = await readAndParseFromDirectory(directories.movingUI);
    const quickReplyPresets = await readAndParseFromDirectory(directories.quickreplies);

    const instruct = await readAndParseFromDirectory(directories.instruct);
    const context = await readAndParseFromDirectory(directories.context);
    const sysprompt = await readAndParseFromDirectory(directories.sysprompt);
    const reasoning = await readAndParseFromDirectory(directories.reasoning);

    return {
        koboldai_settings,
        koboldai_setting_names,
        world_names,
        novelai_settings,
        novelai_setting_names,
        openai_settings,
        openai_setting_names,
        textgenerationwebui_presets,
        textgenerationwebui_preset_names,
        themes,
        movingUIPresets,
        quickReplyPresets,
        instruct,
        context,
        sysprompt,
        reasoning,
        enable_extensions: ENABLE_EXTENSIONS,
        enable_extensions_auto_update: ENABLE_EXTENSIONS_AUTO_UPDATE,
        enable_accounts: ENABLE_ACCOUNTS,
        request_compression: {
            enabled: ENABLE_REQUEST_COMPRESSION,
            minPayloadSize: REQUEST_COMPRESSION_MIN || 0,
            maxPayloadSize: REQUEST_COMPRESSION_MAX || 0,
            timeout: REQUEST_COMPRESSION_TIMEOUT || 0,
        },
    };
}

/**
 * Busts the composed settings cache for a user. Call from write endpoints that
 * mutate presets, themes, worlds, moving-UI or quick-reply files.
 * @param {string} handle User handle
 * @returns {void}
 */
export function bustSettingsCache(handle) {
    SETTINGS_PAYLOAD_CACHE.delete(handle);
}

export const router = express.Router();

router.post('/save', async function (request, response) {
    try {
        const pathToSettings = path.join(request.user.directories.root, SETTINGS_FILE);
        await writeFileAtomic(pathToSettings, JSON.stringify(request.body, null, 4), 'utf8');
        triggerAutoSave(request.user.profile.handle);
        response.send({ result: 'ok' });
    } catch (err) {
        log.settings.error(err);
        response.send(err);
    }
});

/**
 * Merges only the connection fields into the user's settings, preserving every other key.
 * Lets a windowed client point at a backend without shipping the whole settings blob back.
 */
router.post('/set-connection', async function (request, response) {
    try {
        const apiType = request.body.api_type;
        const apiServer = request.body.api_server;
        const isNonEmptyString = value => typeof value === 'string' && value.length > 0;
        if (!isNonEmptyString(apiType) || !isNonEmptyString(apiServer)) {
            return response.status(400).send({ error: 'api_type and api_server must be non-empty strings' });
        }
        if (apiType === '__proto__' || apiType === 'constructor' || apiType === 'prototype') {
            return response.status(400).send({ error: 'invalid api_type' });
        }

        const pathToSettings = path.join(request.user.directories.root, SETTINGS_FILE);
        const settings = JSON.parse(await fs.promises.readFile(pathToSettings, 'utf8'));
        if (typeof settings !== 'object' || settings === null || Array.isArray(settings)) {
            return response.status(500).send({ error: 'settings file is not an object' });
        }

        settings.main_api = 'textgenerationwebui';
        if (typeof settings.textgenerationwebui_settings !== 'object' || settings.textgenerationwebui_settings === null) {
            settings.textgenerationwebui_settings = {};
        }
        settings.textgenerationwebui_settings.type = apiType;
        if (typeof settings.textgenerationwebui_settings.server_urls !== 'object' || settings.textgenerationwebui_settings.server_urls === null) {
            settings.textgenerationwebui_settings.server_urls = {};
        }
        settings.textgenerationwebui_settings.server_urls[apiType] = apiServer;

        await writeFileAtomic(pathToSettings, JSON.stringify(settings, null, 4), 'utf8');
        triggerAutoSave(request.user.profile.handle);
        return response.send({ ok: true, connection: { api_type: apiType, api_server: apiServer } });
    } catch (error) {
        log.settings.error(error);
        return response.status(500).send({ error: true });
    }
});

// Wintermute's code
router.post('/get', async (request, response) => {
    let settings;
    try {
        const pathToSettings = path.join(request.user.directories.root, SETTINGS_FILE);
        settings = await fs.promises.readFile(pathToSettings, 'utf8');
    } catch (e) {
        return response.sendStatus(500);
    }

    const handle = request.user.profile.handle;
    const directories = request.user.directories;

    // Probe before composing so a write landing mid-compose invalidates the stored snapshot.
    const mtimes = await probeSettingsDirMtimes(directories);
    const cached = SETTINGS_PAYLOAD_CACHE.get(handle);
    if (cached && settingsDirMtimesMatch(cached.mtimes, mtimes)) {
        return response.send({ settings, ...cached.payload });
    }

    const payload = await composeSettingsPayload(directories);
    SETTINGS_PAYLOAD_CACHE.set(handle, { mtimes, payload });
    response.send({ settings, ...payload });
});

router.post('/get-snapshots', async (request, response) => {
    try {
        const snapshots = await fs.promises.readdir(request.user.directories.backups);
        const userFilesPattern = getSettingsBackupFilePrefix(request.user.profile.handle);
        const userSnapshots = snapshots.filter(x => x.startsWith(userFilesPattern));

        const result = [];
        for (const x of userSnapshots) {
            const stat = await fs.promises.stat(path.join(request.user.directories.backups, x));
            result.push({ date: stat.ctimeMs, name: x, size: stat.size });
        }

        response.json(result);
    } catch (error) {
        log.settings.error(error);
        response.sendStatus(500);
    }
});

router.post('/load-snapshot', getFileNameValidationFunction('name'), async (request, response) => {
    try {
        const userFilesPattern = getSettingsBackupFilePrefix(request.user.profile.handle);

        if (!request.body.name || !request.body.name.startsWith(userFilesPattern)) {
            return response.status(400).send({ error: 'Invalid snapshot name' });
        }

        const snapshotName = request.body.name;
        const snapshotPath = path.join(request.user.directories.backups, snapshotName);

        const snapshotStat = await fs.promises.stat(snapshotPath).catch(() => null);
        if (!snapshotStat) {
            return response.sendStatus(404);
        }

        const content = await fs.promises.readFile(snapshotPath, 'utf8');

        response.send(content);
    } catch (error) {
        log.settings.error(error);
        response.sendStatus(500);
    }
});

router.post('/make-snapshot', async (request, response) => {
    try {
        await backupUserSettings(request.user.profile.handle, false);
        response.sendStatus(204);
    } catch (error) {
        log.settings.error(error);
        response.sendStatus(500);
    }
});

router.post('/restore-snapshot', getFileNameValidationFunction('name'), async (request, response) => {
    try {
        const userFilesPattern = getSettingsBackupFilePrefix(request.user.profile.handle);

        if (!request.body.name || !request.body.name.startsWith(userFilesPattern)) {
            return response.status(400).send({ error: 'Invalid snapshot name' });
        }

        const snapshotName = request.body.name;
        const snapshotPath = path.join(request.user.directories.backups, snapshotName);

        const snapshotStat = await fs.promises.stat(snapshotPath).catch(() => null);
        if (!snapshotStat) {
            return response.sendStatus(404);
        }

        const pathToSettings = path.join(request.user.directories.root, SETTINGS_FILE);
        await fs.promises.rm(pathToSettings, { force: true });
        await fs.promises.copyFile(snapshotPath, pathToSettings);

        response.sendStatus(204);
    } catch (error) {
        log.settings.error(error);
        response.sendStatus(500);
    }
});

/**
 * Initializes the settings endpoint
 */
export async function init() {
    await backupSettings();
}

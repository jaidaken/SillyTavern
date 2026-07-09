import process from 'node:process';
import chalk from 'chalk';

import { getConfigValue } from './util.js';
import { LOG_LEVELS } from './constants.js';

const CATEGORIES = [
    'net', 'net.openai', 'net.google',
    'gen', 'prompt', 'wi', 'ext', 'settings',
    'chat', 'tok', 'vectors', 'tts',
    'users', 'chars', 'content', 'search', 'media', 'sys',
];

const LEVEL_NAMES = ['trace', 'debug', 'info', 'warn', 'error'];

const CONSOLE_METHOD = {
    trace: 'debug',
    debug: 'debug',
    info: 'info',
    warn: 'warn',
    error: 'error',
};

// Shared, cached no-op so an inactive (category, level) still resolves to a bound function.
const silent = (() => { }).bind(null);
const badgeCache = new Map();

function hue(category) {
    let hash = 0;
    for (let i = 0; i < category.length; i++) {
        hash = (hash * 31 + category.charCodeAt(i)) >>> 0;
    }
    return hash % 360;
}

function hslToHex(h, s, l) {
    s /= 100;
    l /= 100;
    const k = n => (n + h / 30) % 12;
    const a = s * Math.min(l, 1 - l);
    const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    const toHex = x => Math.round(255 * x).toString(16).padStart(2, '0');
    return `#${toHex(f(0))}${toHex(f(8))}${toHex(f(4))}`;
}

function badge(category) {
    let entry = badgeCache.get(category);
    if (!entry) {
        entry = chalk.bold.hex(hslToHex(hue(category), 60, 45))(`[${category}]`);
        badgeCache.set(category, entry);
    }
    return entry;
}

function normalizeLevel(value) {
    if (typeof value === 'number' && Object.values(LOG_LEVELS).includes(value)) {
        return value;
    }
    if (typeof value === 'string') {
        const upper = value.trim().toUpperCase();
        if (Object.hasOwn(LOG_LEVELS, upper)) {
            return LOG_LEVELS[upper];
        }
    }
    return undefined;
}

function configSpec() {
    const map = new Map();
    const categories = getConfigValue('logging.categories', null);
    if (categories && typeof categories === 'object') {
        for (const [cat, value] of Object.entries(categories)) {
            const level = normalizeLevel(value);
            if (level !== undefined) {
                map.set(cat, level);
            }
        }
    }
    return map;
}

function envSpec() {
    const map = new Map();
    const raw = process.env.ST_LOG;
    if (!raw) {
        return map;
    }
    for (const part of raw.split(',')) {
        const [cat, lvl] = part.split(':').map(s => s && s.trim());
        const level = cat && lvl ? normalizeLevel(lvl) : undefined;
        if (level !== undefined) {
            map.set(cat, level);
        }
    }
    return map;
}

// Config is read once at process startup (util.js caches it synchronously, no watcher), so
// overrides are resolved once here. Precedence low to high: config categories, ST_LOG env.
const DEFAULT_LEVEL = getConfigValue('logging.minLogLevel', LOG_LEVELS.DEBUG, 'number');
const overrides = new Map([...configSpec(), ...envSpec()]);

function resolveThreshold(category) {
    let resolved = DEFAULT_LEVEL;
    if (overrides.has(category)) {
        resolved = overrides.get(category);
    } else {
        const parts = category.split('.');
        while (parts.length > 1) {
            parts.pop();
            const parent = parts.join('.');
            if (overrides.has(parent)) {
                resolved = overrides.get(parent);
                break;
            }
        }
    }
    // sys carries essential startup/shutdown/operational output; it never drops below INFO
    // regardless of config, so an aggressive minLogLevel can't silence it.
    if (category.split('.')[0] === 'sys') {
        return Math.min(resolved, LOG_LEVELS.INFO);
    }
    return resolved;
}

function emitterFor(category, levelName) {
    if (LOG_LEVELS[levelName.toUpperCase()] < resolveThreshold(category)) {
        return silent;
    }
    // Binds the real, unpatched console method: this module evaluates (and captures these
    // refs) before setupLogLevel() ever runs, so category gating is independent of it.
    return console[CONSOLE_METHOD[levelName]].bind(console, badge(category));
}

function buildNode(category) {
    const node = {};
    for (const levelName of LEVEL_NAMES) {
        node[levelName] = emitterFor(category, levelName);
    }
    return node;
}

export const log = {};

for (const category of CATEGORIES) {
    let parent = log;
    let path = '';
    for (const part of category.split('.')) {
        path = path ? `${path}.${part}` : part;
        parent = parent[part] ?? (parent[part] = buildNode(path));
    }
}

import { power_user } from './power-user.js';

export const LOG_LEVELS = Object.freeze({
    TRACE: -1,
    DEBUG: 0,
    INFO: 1,
    WARN: 2,
    ERROR: 3,
    SILENT: 100,
});

const DEFAULT_LEVEL = LOG_LEVELS.INFO;

const CATEGORIES = [
    'net', 'net.openai', 'gen', 'prompt', 'wi', 'ext', 'settings',
    'events', 'chat', 'persona', 'tok', 'vectors', 'tts', 'ui',
];

const LEVEL_NAMES = ['trace', 'debug', 'info', 'warn', 'error'];

const CONSOLE_METHOD = {
    trace: 'debug',
    debug: 'debug',
    info: 'info',
    warn: 'warn',
    error: 'error',
};

// Shared, cached no-op so an inactive (category, level) still resolves to a bound method.
const silent = (() => { }).bind(null);
const badgeCache = new Map();
const onceSeen = new Set();
const nodes = new Map();

function hue(category) {
    let hash = 0;
    for (let i = 0; i < category.length; i++) {
        hash = (hash * 31 + category.charCodeAt(i)) >>> 0;
    }
    return hash % 360;
}

function badge(category) {
    let entry = badgeCache.get(category);
    if (!entry) {
        const style = `background:hsl(${hue(category)},60%,38%);color:#fff;border-radius:3px;padding:0 5px;font-weight:600`;
        entry = [`%c${category}`, style];
        badgeCache.set(category, entry);
    }
    return entry;
}

function parseSpec(raw) {
    const map = new Map();
    if (!raw) {
        return map;
    }
    for (const part of String(raw).split(',')) {
        const [cat, lvl] = part.split(':').map(s => s && s.trim());
        if (!cat || !lvl) {
            continue;
        }
        const upper = lvl.toUpperCase();
        if (Object.hasOwn(LOG_LEVELS, upper)) {
            map.set(cat, LOG_LEVELS[upper]);
        }
    }
    return map;
}

function legacySpec() {
    const map = new Map();
    if (localStorage.getItem('eventTracing') === 'true') {
        map.set('events', LOG_LEVELS.TRACE);
    }
    if (power_user?.console_log_prompts) {
        map.set('prompt', LOG_LEVELS.DEBUG);
    }
    return map;
}

function persistedSpec() {
    if (!power_user?.logging) {
        return new Map();
    }
    const raw = Object.entries(power_user.logging).map(([cat, lvl]) => `${cat}:${lvl}`).join(',');
    return parseSpec(raw);
}

function loadOverrides() {
    const query = parseSpec(new URLSearchParams(location.search).get('log'));
    const stored = parseSpec(localStorage.getItem('ST_LOG'));
    // precedence high to low: query > stored > persisted > legacy
    return new Map([...legacySpec(), ...persistedSpec(), ...stored, ...query]);
}

let overrides = loadOverrides();

function resolveThreshold(category) {
    if (overrides.has(category)) {
        return overrides.get(category);
    }
    const parts = category.split('.');
    while (parts.length > 1) {
        parts.pop();
        const parent = parts.join('.');
        if (overrides.has(parent)) {
            return overrides.get(parent);
        }
    }
    return overrides.has('*') ? overrides.get('*') : DEFAULT_LEVEL;
}

function emitterFor(category, levelName) {
    if (LOG_LEVELS[levelName.toUpperCase()] < resolveThreshold(category)) {
        return silent;
    }
    return console[CONSOLE_METHOD[levelName]].bind(console, ...badge(category));
}

function refreshNode(category, node) {
    for (const levelName of LEVEL_NAMES) {
        node[levelName] = emitterFor(category, levelName);
    }
    const active = resolveThreshold(category) <= LOG_LEVELS.DEBUG;
    node.groupCollapsed = active ? console.groupCollapsed.bind(console, ...badge(category)) : silent;
    node.time = active ? console.time.bind(console) : silent;
    node.timeEnd = active ? console.timeEnd.bind(console) : silent;
    node.table = active ? console.table.bind(console) : silent;
}

function buildNode(category) {
    const node = {};
    refreshNode(category, node);
    nodes.set(category, node);
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

log.once = function (key, ...args) {
    if (onceSeen.has(key)) {
        return;
    }
    onceSeen.add(key);
    console.info(...badge('once'), ...args);
};

log.setLevel = function setLevel(category, levelName) {
    const upper = String(levelName).toUpperCase();
    if (!Object.hasOwn(LOG_LEVELS, upper)) {
        return;
    }
    overrides.set(category, LOG_LEVELS[upper]);
    for (const [path, node] of nodes) {
        refreshNode(path, node);
    }
};

log.resolve = function resolve() {
    overrides = loadOverrides();
    for (const [path, node] of nodes) {
        refreshNode(path, node);
    }
};

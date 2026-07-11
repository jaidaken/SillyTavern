import fs from 'node:fs';
import path from 'node:path';

import { init, parse } from 'es-module-lexer';

import { serverDirectory } from '../server-directory.js';
import { log } from '../log.js';

const PUBLIC_DIRECTORY = path.join(serverDirectory, 'public');
const INDEX_PATH = path.join(PUBLIC_DIRECTORY, 'index.html');
const ENTRY_PATTERN = /<script[^>]+type="module"[^>]+src="([^"]+)"/g;
// Served by the webpack middleware; the on-disk file is the bundler input, so never walk its imports.
const BUNDLE_URL = '/lib.js';

/** @type {string|null} */
let cachedIndexHtml = null;

/**
 * Resolves an import specifier against the importing module's URL path.
 * @param {string} fromUrl URL path of the importing module
 * @param {string} specifier Import specifier
 * @returns {string|null} Resolved URL path, or null for bare/external specifiers
 */
function resolveImport(fromUrl, specifier) {
    if (specifier.startsWith('/')) {
        return path.posix.normalize(specifier);
    }
    if (specifier.startsWith('./') || specifier.startsWith('../')) {
        return path.posix.normalize(path.posix.join(path.posix.dirname(fromUrl), specifier));
    }
    return null;
}

/**
 * Walks the static import graph of the frontend entry modules.
 * @param {string[]} entryUrls URL paths of the module entry points
 * @returns {Promise<string[]>} Every module URL reachable through static imports, in discovery order
 */
async function collectModuleGraph(entryUrls) {
    await init;
    const seen = new Set(entryUrls);
    const queue = [...entryUrls];
    const ordered = [];

    while (queue.length > 0) {
        const url = queue.shift();
        if (url === undefined) {
            break;
        }
        ordered.push(url);

        if (url === BUNDLE_URL) {
            continue;
        }

        const filePath = path.join(PUBLIC_DIRECTORY, url);
        if (!filePath.startsWith(PUBLIC_DIRECTORY) || !fs.existsSync(filePath)) {
            continue;
        }

        const source = fs.readFileSync(filePath, 'utf8');
        const [imports] = parse(source, url);
        for (const record of imports) {
            // d >= 0 marks dynamic imports; those stay lazy on purpose
            if (record.d !== -1 || !record.n) {
                continue;
            }
            const resolved = resolveImport(url, record.n);
            if (resolved && !seen.has(resolved)) {
                seen.add(resolved);
                queue.push(resolved);
            }
        }
    }

    return ordered;
}

/**
 * Returns index.html with modulepreload links for the whole static import graph.
 * Flattens the module discovery waterfall into one parallel fetch burst; computed
 * once per process and served from memory. Falls back to the raw file on any error.
 * @returns {Promise<string>} HTML to serve for the index route
 */
export async function getIndexHtmlWithModulePreloads() {
    if (cachedIndexHtml !== null) {
        return cachedIndexHtml;
    }

    const rawHtml = fs.readFileSync(INDEX_PATH, 'utf8');

    try {
        // HTML src attributes are document-relative even without a leading ./ or /
        const entryUrls = [...rawHtml.matchAll(ENTRY_PATTERN)]
            .map(match => path.posix.normalize('/' + match[1].replace(/^\.?\//, '')))
            .filter(url => !url.startsWith('/..'));
        const graph = await collectModuleGraph(entryUrls);
        const entrySet = new Set(entryUrls);
        const links = graph
            .filter(url => !entrySet.has(url))
            .map(url => `    <link rel="modulepreload" href="${url}">`)
            .join('\n');
        cachedIndexHtml = rawHtml.replace('</head>', `${links}\n</head>`);
        log.sys.info(`Module preload: injected ${graph.length - entrySet.size} links (graph of ${graph.length} modules).`);
    } catch (error) {
        log.sys.error('Module preload: graph walk failed, serving index.html without preloads.', error);
        cachedIndexHtml = rawHtml;
    }

    return cachedIndexHtml;
}

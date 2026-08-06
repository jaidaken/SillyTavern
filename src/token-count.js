/**
 * The token counter a server-side prompt assembly costs its pieces with.
 *
 * The browser resolved a tokenizer per backend and then made one HTTP call per piece of the prompt
 * to have this server count it. Assembling here removes the round trip but must not change the
 * ANSWER, so the resolution ladder below is the same one the client ran (getTokenizerBestMatch,
 * tokenizers.js:293): a connected, supported backend counts with its own tokenizer, and everything
 * else falls to a bundled local model picked by model-name substring. The local tier now runs in
 * process; only the remote tier still leaves the box, exactly as it did before.
 */

import { TEXTGEN_TYPES } from './constants.js';
import { setAdditionalHeadersByType } from './additional-headers.js';
import { getSentencepiceTokenizer, getWebTokenizer } from './endpoints/tokenizers.js';
import { log } from './log.js';

const BYTES_PER_TOKEN = 3.35;

/** Backends whose own tokenizer the client prefers over a local model. */
const REMOTE_TOKENIZER_TYPES = new Set([
    TEXTGEN_TYPES.LLAMACPP,
    TEXTGEN_TYPES.TABBY,
    TEXTGEN_TYPES.KOBOLDCPP,
    TEXTGEN_TYPES.VLLM,
    TEXTGEN_TYPES.APHRODITE,
]);

const SENTENCEPIECE_KINDS = new Set(['llama', 'mistral', 'gemma', 'yi', 'jamba']);
const WEB_KINDS = new Set(['llama3', 'nemo', 'deepseek', 'command-r', 'command-a', 'qwen2']);

/**
 * The tokenizer name a generation counts with.
 * @param {string} apiType The textgen backend type.
 * @param {string} model The model name the backend reported.
 * @param {boolean} connected Whether a backend url is configured at all.
 * @returns {string} 'remote' or a local tokenizer name.
 */
export function bestMatchTokenizer(apiType, model, connected) {
    if (connected && REMOTE_TOKENIZER_TYPES.has(apiType)) {
        return 'remote';
    }
    return localMatch(String(model ?? ''));
}

/**
 * The local model-substring ladder, first match wins, in the client's order.
 * @param {string} model The model name.
 * @returns {string} A local tokenizer name.
 */
function localMatch(model) {
    const name = model.toLowerCase();
    if (name.includes('llama3') || name.includes('llama-3')) return 'llama3';
    if (name.includes('mistral') || name.includes('mixtral')) return 'mistral';
    if (name.includes('gemma')) return 'gemma';
    if (name.includes('nemo') || name.includes('pixtral')) return 'nemo';
    if (name.includes('deepseek')) return 'deepseek';
    if (name.includes('yi')) return 'yi';
    if (name.includes('jamba')) return 'jamba';
    if (name.includes('command-r')) return 'command-r';
    if (name.includes('command-a')) return 'command-a';
    if (name.includes('qwen2')) return 'qwen2';
    return 'llama';
}

/**
 * The length estimate the tokenizer routes fall back to when a model will not load. It is in TOKENS,
 * so it stays in the same unit as the budget the assembly spends.
 * @param {string} text Text to estimate.
 * @returns {number} Estimated token count.
 */
export function estimateTokens(text) {
    return Math.ceil(Buffer.byteLength(text, 'utf8') / BYTES_PER_TOKEN);
}

/**
 * Counts one text through the backend's own tokenizer.
 *
 * The headers come from setAdditionalHeadersBy_Type_ rather than the request-shaped helper: a start
 * body carries its backend under `generate`, so the helper that reads `request.body.api_type` finds
 * nothing there and the backend's api key never reaches it.
 * @param {import('./users.js').UserDirectoryList} directories The user's directories, which hold the backend credentials.
 * @param {string} apiType Backend type.
 * @param {string} baseUrl Backend url.
 * @param {string} model Model name.
 * @param {string|null} secretId Named credential, when the caller picked one.
 * @param {string} text Text to count.
 * @returns {Promise<number|null>} The count, or null when the backend did not answer with one.
 */
async function countRemote(directories, apiType, baseUrl, model, secretId, text) {
    const args = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
    await setAdditionalHeadersByType(args.headers, apiType, baseUrl, directories, secretId);
    let url = String(baseUrl).replace(/\/$/, '').replace(/\/v1$/, '');

    switch (apiType) {
        case TEXTGEN_TYPES.TABBY:
            url += '/v1/token/encode';
            args.body = JSON.stringify({ text, add_bos_token: false, encode_special_tokens: false });
            break;
        case TEXTGEN_TYPES.KOBOLDCPP:
            url += '/api/extra/tokencount';
            args.body = JSON.stringify({ prompt: text, special: false });
            break;
        case TEXTGEN_TYPES.LLAMACPP:
            url += '/tokenize';
            args.body = JSON.stringify({ model, content: text });
            break;
        case TEXTGEN_TYPES.VLLM:
            url += '/tokenize';
            args.body = JSON.stringify({ model, prompt: text });
            break;
        case TEXTGEN_TYPES.APHRODITE:
            url += '/v1/tokenize';
            args.body = JSON.stringify({ model, prompt: text });
            break;
        default:
            url += '/v1/internal/encode';
            args.body = JSON.stringify({ text });
            break;
    }

    const result = await fetch(url, args);
    if (!result.ok) {
        return null;
    }
    /** @type {any} */
    const data = await result.json();
    const count = data?.length ?? data?.count ?? data?.value ?? data?.tokens?.length;
    return Number.isFinite(count) ? Number(count) : null;
}

/**
 * A counter for one assembly: same tokenizer the browser would have used, memoized per text.
 *
 * Every text is stripped of carriage returns first, because the client stripped them before asking
 * for a count and a CR is a token the answer would otherwise gain.
 * @param {object} options Wiring.
 * @param {import('./users.js').UserDirectoryList} [options.directories] The user's directories, which hold the backend credentials.
 * @param {string} options.apiType Backend type.
 * @param {string} options.model Model name.
 * @param {string} options.apiServer Backend url, empty when none is configured.
 * @param {string|null} [options.secretId] Named credential, when the caller picked one.
 * @returns {(text: string) => Promise<number>} The counter assemblePrompt injects.
 */
export function createTokenCounter({ directories = /** @type {any} */ ({}), apiType, model, apiServer, secretId = null }) {
    const connected = typeof apiServer === 'string' && apiServer.length > 0;
    const kind = bestMatchTokenizer(String(apiType ?? ''), String(model ?? ''), connected);
    /** @type {Map<string, number>} */
    const cache = new Map();
    // One failed remote count switches the WHOLE assembly to the estimate. Mixing an exact count for
    // some pieces with an estimate for others spends one budget against two units, which is worse
    // than either alone; the client latched the same way.
    let degraded = false;

    /**
     * @param {string} text Carriage-return-free text.
     * @returns {Promise<number>} The count.
     */
    async function measure(text) {
        if (degraded) {
            return estimateTokens(text);
        }
        if (kind === 'remote') {
            try {
                const count = await countRemote(directories, String(apiType), String(apiServer), String(model ?? ''), secretId, text);
                if (count !== null) {
                    return count;
                }
            } catch (/** @type {any} */ error) {
                log.tok.warn('Backend tokenizer failed, costing the prompt by estimate instead:', error?.message ?? error);
            }
            degraded = true;
            return estimateTokens(text);
        }
        if (SENTENCEPIECE_KINDS.has(kind)) {
            const instance = await getSentencepiceTokenizer(kind)?.get();
            return instance ? instance.encodeIds(text).length : estimateTokens(text);
        }
        if (WEB_KINDS.has(kind)) {
            const instance = await getWebTokenizer(kind)?.get();
            return instance ? Array.from(instance.encode(text)).length : estimateTokens(text);
        }
        return estimateTokens(text);
    }

    return async (text) => {
        const clean = String(text).replaceAll('\r', '');
        const hit = cache.get(clean);
        if (hit !== undefined) {
            return hit;
        }
        const count = await measure(clean);
        cache.set(clean, count);
        return count;
    };
}

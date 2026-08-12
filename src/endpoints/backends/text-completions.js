import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import fetch from 'node-fetch';
import express from 'express';
import _ from 'lodash';

import {
    TEXTGEN_TYPES,
    TOGETHERAI_KEYS,
    OLLAMA_KEYS,
    INFERMATICAI_KEYS,
    OPENROUTER_KEYS,
    VLLM_KEYS,
    FEATHERLESS_KEYS,
    OPENAI_KEYS,
} from '../../constants.js';
import { forwardFetchResponse, trimV1, getConfigValue } from '../../util.js';
import { setAdditionalHeaders, setAdditionalHeadersByType } from '../../additional-headers.js';
import { createHash } from 'node:crypto';
import { log } from '../../log.js';
import { takeReasoningBudget, buildPayload, ReasoningBudgetTracker } from '../../reasoning-budget.js';

export const router = express.Router();

/**
 * Special boy's steaming routine. Wrap this abomination into proper SSE stream.
 * @param {import('node-fetch').Response} jsonStream JSON stream
 * @param {import('express').Request} request Express request
 * @param {import('express').Response} response Express response
 * @returns {Promise<any>} Nothing valuable
 */
async function parseOllamaStream(jsonStream, request, response) {
    try {
        if (!jsonStream.body) {
            throw new Error('No body in the response');
        }

        let partialData = '';
        jsonStream.body.on('data', (data) => {
            const chunk = data.toString();
            partialData += chunk;
            while (true) {
                let json;
                try {
                    json = JSON.parse(partialData);
                } catch (e) {
                    break;
                }
                const text = json.response || '';
                const thinking = json.thinking || '';
                const sseChunk = { choices: [{ text, thinking }] };
                response.write(`data: ${JSON.stringify(sseChunk)}\n\n`);
                partialData = '';
            }
        });

        const onSocketClose = function () {
            if (jsonStream.body instanceof Readable) jsonStream.body.destroy();
            response.end();
        };

        request.socket.on('close', onSocketClose);

        jsonStream.body.on('end', () => {
            log.net.info('Streaming request finished');
            response.write('data: [DONE]\n\n');
            response.end();
        });
    } catch (error) {
        log.net.error('Error forwarding streaming response:', error);
        if (!response.headersSent) {
            return response.status(500).send({ error: true });
        } else {
            return response.end();
        }
    }
}

/**
 * Abort KoboldCpp generation request.
 * @param {import('express').Request} request the generation request
 * @param {string} url Server base URL
 * @returns {Promise<void>} Promise resolving when we are done
 */
async function abortKoboldCppRequest(request, url) {
    try {
        log.net.info('Aborting Kobold generation...');
        const args = {
            method: 'POST',
            headers: {},
        };

        await setAdditionalHeaders(request, args, url);
        const abortResponse = await fetch(`${url}/api/extra/abort`, args);

        if (!abortResponse.ok) {
            log.net.error('Error sending abort request to Kobold:', abortResponse.status, abortResponse.statusText);
        }
    } catch (error) {
        log.net.error(error);
    }
}

/**
 * Resolves the models-listing URL used to check whether a text completion backend is reachable.
 * @param {string} apiType One of TEXTGEN_TYPES
 * @param {string} baseUrl Backend base URL, already trimmed of a trailing /v1
 * @returns {string} URL whose success means the backend is up
 */
export function getModelsStatusUrl(apiType, baseUrl) {
    switch (apiType) {
        case TEXTGEN_TYPES.GENERIC:
        case TEXTGEN_TYPES.OOBA:
        case TEXTGEN_TYPES.VLLM:
        case TEXTGEN_TYPES.APHRODITE:
        case TEXTGEN_TYPES.KOBOLDCPP:
        case TEXTGEN_TYPES.LLAMACPP:
        case TEXTGEN_TYPES.INFERMATICAI:
        case TEXTGEN_TYPES.OPENROUTER:
        case TEXTGEN_TYPES.FEATHERLESS:
            return `${baseUrl}/v1/models`;
        case TEXTGEN_TYPES.DREAMGEN:
            return `${baseUrl}/api/openai/v1/models`;
        case TEXTGEN_TYPES.MANCER:
            return `${baseUrl}/oai/v1/models`;
        case TEXTGEN_TYPES.TABBY:
            return `${baseUrl}/v1/model/list`;
        case TEXTGEN_TYPES.TOGETHERAI:
            return `${baseUrl}/api/models?&info`;
        case TEXTGEN_TYPES.OLLAMA:
            return `${baseUrl}/api/tags`;
        case TEXTGEN_TYPES.HUGGINGFACE:
            return `${baseUrl}/info`;
        default:
            return baseUrl;
    }
}

//************** Ooba/OpenAI text completions API
router.post('/status', async function (request, response) {
    if (!request.body) return response.sendStatus(400);

    try {
        if (request.body.api_server.indexOf('localhost') !== -1) {
            request.body.api_server = request.body.api_server.replace('localhost', '127.0.0.1');
        }

        log.net.debug('Trying to connect to API', request.body);
        const baseUrl = trimV1(request.body.api_server);

        const args = {
            headers: { 'Content-Type': 'application/json' },
        };

        await setAdditionalHeaders(request, args, baseUrl);

        const apiType = request.body.api_type;
        const url = getModelsStatusUrl(apiType, baseUrl);
        let result = '';

        const modelsReply = await fetch(url, args);
        const isPossiblyLmStudio = modelsReply.headers.get('x-powered-by') === 'Express';

        if (!modelsReply.ok) {
            log.net.error('Models endpoint is offline.');
            return response.sendStatus(400);
        }

        /** @type {any} */
        let data = await modelsReply.json();

        // Rewrap to OAI-like response
        if (apiType === TEXTGEN_TYPES.TOGETHERAI && Array.isArray(data)) {
            data = { data: data.map(x => ({ id: x.name, ...x })) };
        }

        if (apiType === TEXTGEN_TYPES.OLLAMA && Array.isArray(data.models)) {
            data = { data: data.models.map(x => ({ id: x.name, ...x })) };
        }

        if (apiType === TEXTGEN_TYPES.HUGGINGFACE) {
            data = { data: [] };
        }

        if (!Array.isArray(data.data)) {
            log.net.error('Models response is not an array.');
            return response.sendStatus(400);
        }

        const modelIds = data.data.map(x => x.id);
        log.net.debug('Models available:', modelIds);

        // Set result to the first model ID
        result = modelIds[0] || 'Valid';

        if (apiType === TEXTGEN_TYPES.OOBA && !isPossiblyLmStudio) {
            try {
                const modelInfoUrl = baseUrl + '/v1/internal/model/info';
                const modelInfoReply = await fetch(modelInfoUrl, args);

                if (modelInfoReply.ok) {
                    /** @type {any} */
                    const modelInfo = await modelInfoReply.json();
                    log.net.debug('Ooba model info:', modelInfo);

                    const modelName = modelInfo?.model_name;
                    result = modelName || result;
                    response.setHeader('x-supports-tokenization', 'true');
                }
            } catch (error) {
                log.net.error(`Failed to get Ooba model info: ${error}`);
            }
        } else if (apiType === TEXTGEN_TYPES.TABBY) {
            try {
                const modelInfoUrl = baseUrl + '/v1/model';
                const modelInfoReply = await fetch(modelInfoUrl, args);

                if (modelInfoReply.ok) {
                    /** @type {any} */
                    const modelInfo = await modelInfoReply.json();
                    log.net.debug('Tabby model info:', modelInfo);

                    const modelName = modelInfo?.id;
                    result = modelName || result;
                } else {
                    // TabbyAPI returns an error 400 if a model isn't loaded

                    result = 'None';
                }
            } catch (error) {
                log.net.error(`Failed to get TabbyAPI model info: ${error}`);
            }
        }

        return response.send({ result, data: data.data });
    } catch (/** @type {any} */ error) {
        // An unreachable backend is not a server error; report it as a clean 200 status so the
        // client shows "not connected" without a red 500 filling the console on every poll.
        const code = error?.cause?.code ?? error?.code;
        if (error?.name === 'TypeError' || code === 'ECONNREFUSED' || code === 'ENOTFOUND' || code === 'EAI_AGAIN' || code === 'ETIMEDOUT') {
            log.net.debug('Text-completions backend unreachable:', request.body?.api_server);
            return response.send({ online: false });
        }
        log.net.error(error);
        return response.sendStatus(500);
    }
});

router.post('/props', async function (request, response) {
    if (!request.body.api_server) return response.sendStatus(400);

    try {
        const baseUrl = trimV1(request.body.api_server);
        const args = {
            headers: {},
        };

        await setAdditionalHeaders(request, args, baseUrl);

        const apiType = request.body.api_type;
        let propsUrl = baseUrl + '/props';
        if (apiType === TEXTGEN_TYPES.LLAMACPP && request.body.model) {
            propsUrl += `?model=${encodeURIComponent(request.body.model)}`;
            log.net.debug(`Querying llama-server props with model parameter: ${request.body.model}`);
        }
        const propsReply = await fetch(propsUrl, args);

        if (!propsReply.ok) {
            return response.sendStatus(400);
        }

        /** @type {any} */
        const props = await propsReply.json();
        // TEMPORARY: llama.cpp's /props endpoint has a bug which replaces the last newline with a \0
        if (apiType === TEXTGEN_TYPES.LLAMACPP && props.chat_template && props.chat_template.endsWith('\u0000')) {
            props.chat_template = props.chat_template.slice(0, -1) + '\n';
        }
        props.chat_template_hash = createHash('sha256').update(props.chat_template).digest('hex');
        log.net.debug(`Model properties: ${JSON.stringify(props)}`);
        return response.send(props);
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

/**
 * Builds the upstream completion request for one backend type. Shared by the /generate route and the
 * server-owned generation start route, so the two can never drift into different upstream bodies.
 *
 * Mutates `params` in place the way the route always has (the per-backend key filters), so callers
 * pass a body they own.
 * @param {import('express').Request} request Express request, used only for the additional-headers lookup.
 * @param {any} params The generation parameters.
 * @param {AbortSignal} signal Abort signal for the upstream fetch.
 * @returns {Promise<{url: string, args: any, apiType: string, baseUrl: string, params: any}>}
 */
export async function buildUpstreamRequest(request, params, signal) {
    if (typeof params.api_server === 'string' && params.api_server.indexOf('localhost') !== -1) {
        params.api_server = params.api_server.replace('localhost', '127.0.0.1');
    }

    const apiType = params.api_type;
    const baseUrl = params.api_server;
    let url = trimV1(baseUrl);

    switch (apiType) {
        case TEXTGEN_TYPES.GENERIC:
        case TEXTGEN_TYPES.VLLM:
        case TEXTGEN_TYPES.FEATHERLESS:
        case TEXTGEN_TYPES.APHRODITE:
        case TEXTGEN_TYPES.OOBA:
        case TEXTGEN_TYPES.TABBY:
        case TEXTGEN_TYPES.KOBOLDCPP:
        case TEXTGEN_TYPES.TOGETHERAI:
        case TEXTGEN_TYPES.INFERMATICAI:
        case TEXTGEN_TYPES.HUGGINGFACE:
            url += '/v1/completions';
            break;
        case TEXTGEN_TYPES.DREAMGEN:
            url += '/api/openai/v1/completions';
            break;
        case TEXTGEN_TYPES.MANCER:
            url += '/oai/v1/completions';
            break;
        case TEXTGEN_TYPES.LLAMACPP:
            url += '/completion';
            break;
        case TEXTGEN_TYPES.OLLAMA:
            url += '/api/generate';
            break;
        case TEXTGEN_TYPES.OPENROUTER:
            url += '/v1/chat/completions';
            break;
    }

    const args = {
        method: 'POST',
        body: JSON.stringify(params),
        headers: { 'Content-Type': 'application/json' },
        signal,
        timeout: 0,
    };

    // Keyed off the params handed in, not request.body: /start nests them under `generate`, so
    // request.body.api_type is undefined there and no auth header would be attached.
    await setAdditionalHeadersByType(args.headers, params.api_type, baseUrl, request.user.directories, params.secret_id ?? null);

    if (apiType === TEXTGEN_TYPES.TOGETHERAI) {
        params = _.pickBy(params, (_v, key) => TOGETHERAI_KEYS.includes(key));
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.INFERMATICAI) {
        params = _.pickBy(params, (_v, key) => INFERMATICAI_KEYS.includes(key));
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.FEATHERLESS) {
        params = _.pickBy(params, (_v, key) => FEATHERLESS_KEYS.includes(key));
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.DREAMGEN) {
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.GENERIC) {
        params = _.pickBy(params, (_v, key) => OPENAI_KEYS.includes(key));
        if (Array.isArray(params.stop)) { params.stop = params.stop.slice(0, 4); }
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.OPENROUTER) {
        if (Array.isArray(params.provider) && params.provider.length > 0) {
            params.provider = {
                allow_fallbacks: params.allow_fallbacks ?? true,
                order: params.provider,
            };
        } else {
            delete params.provider;
        }

        if (Array.isArray(params.quantizations) && params.quantizations.length > 0) {
            params.provider ??= {};
            params.provider.quantizations = params.quantizations;
        }

        params = _.pickBy(params, (_v, key) => OPENROUTER_KEYS.includes(key));
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.VLLM) {
        params = _.pickBy(params, (_v, key) => VLLM_KEYS.includes(key));
        args.body = JSON.stringify(params);
    }

    if (apiType === TEXTGEN_TYPES.OLLAMA) {
        const keepAlive = Number(getConfigValue('ollama.keepAlive', -1, 'number'));
        const numBatch = Number(getConfigValue('ollama.batchSize', -1, 'number'));
        if (numBatch > 0) {
            params.num_batch = numBatch;
        }
        args.body = JSON.stringify({
            model: params.model,
            prompt: params.prompt,
            stream: params.stream ?? false,
            keep_alive: keepAlive,
            raw: true,
            options: _.pickBy(params, (_v, key) => OLLAMA_KEYS.includes(key)),
        });
    }

    return { url, args, apiType, baseUrl, params };
}

/**
 * Aborts a KoboldCpp generation on client disconnect, matching the behaviour the route has always had.
 * @param {import('express').Request} request Express request.
 * @param {string} baseUrl The backend base url.
 * @returns {Promise<void>}
 */
/**
 * Streams an upstream completion to the client, cutting thinking off at its budget and resuming the
 * generation so a reply always follows. See src/reasoning-budget.js for why this exists.
 * @param {import('node-fetch').Response} upstream Upstream streaming response.
 * @param {import('express').Response} response Express response to write to.
 * @param {any} params Generation parameters the upstream request was built from.
 * @param {import('../../reasoning-budget.js').ReasoningBudget} settings Budget settings.
 * @param {(params: any) => Promise<import('node-fetch').Response>} refetch Starts a follow-up generation.
 * @returns {Promise<void>}
 */
async function forwardWithReasoningBudget(upstream, response, params, settings, refetch) {
    if (!upstream.ok || !upstream.body) {
        return await forwardFetchResponse(upstream, response);
    }

    response.statusCode = 200;
    const tracker = new ReasoningBudgetTracker(settings, params.prompt ?? '');

    /**
     * Pipes one upstream stream through, stopping early if the budget runs out.
     * @param {import('node-fetch').Response} stream Upstream stream.
     * @param {boolean} watch Whether to enforce the budget on this stream.
     * @returns {Promise<boolean>} True when the budget ran out and the stream was cut short.
     */
    async function pump(stream, watch) {
        if (!stream.body) {
            return false;
        }

        let buffer = '';
        for await (const chunk of stream.body) {
            buffer += chunk.toString('utf-8');

            let index;
            while ((index = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, index + 1);
                buffer = buffer.slice(index + 1);
                const payload = line.trim().startsWith('data: ') ? line.trim().slice(6).trim() : null;

                if (watch && payload && payload !== '[DONE]') {
                    try {
                        tracker.accept(JSON.parse(payload));
                    } catch {
                        // A malformed or keepalive payload is not an accounting event.
                    }
                }

                if (!response.writableEnded) {
                    response.write(line);
                }

                if (watch && tracker.isExhausted()) {
                    return true;
                }
            }
        }

        if (buffer && !response.writableEnded) {
            response.write(buffer);
        }

        return false;
    }

    try {
        let exhausted = false;
        try {
            exhausted = await pump(upstream, true);
        } catch (error) {
            // Walking away from the first stream tears its request down, which reads as an abort.
            // That is the expected end of a budgeted generation, not a failure.
            if (!tracker.isExhausted()) {
                throw error;
            }
            exhausted = true;
        }

        if (!exhausted) {
            return void (!response.writableEnded && response.end());
        }

        if (!response.writableEnded) {
            // The cut lands mid-event, before the blank line that terminates it. Without this the
            // client joins both data lines into one event and throws parsing it, which aborts the
            // generation and loses the reply.
            response.write('\n');
            response.write(buildPayload(tracker.closingText(), tracker.llamaShape));
        }

        const continuation = await refetch(tracker.continuationParams(params));
        if (continuation.ok && continuation.body) {
            await pump(continuation, false);
        } else {
            log.net.warn('[ReasoningBudget] continuation request failed, ending after the thinking');
        }
    } catch (/** @type {any} */ error) {
        log.net.error('[ReasoningBudget] streaming failed:', error?.stack ?? error);
    } finally {
        // Abandoned only once the continuation has its own generation running: cancelling it any
        // earlier takes the shared abort signal down with it.
        if (upstream.body instanceof Readable && !upstream.body.destroyed) {
            upstream.body.destroy();
        }
        if (!response.writableEnded) {
            response.end();
        }
    }
}

/**
 * Writes the exact generation request to disk when the user has asked for it, so the prompt can be
 * audited byte for byte. Enabled by creating `prompt-dumps.on` in the user's data directory.
 * @param {import('express').Request} request Express request carrying the generation body.
 * @returns {void}
 */
function dumpPromptIfRequested(request) {
    try {
        const dir = request.user?.directories?.root;
        if (!dir || !fs.existsSync(path.join(dir, 'prompt-dumps.on'))) {
            return;
        }

        const record = { at: new Date().toISOString(), body: request.body };
        fs.appendFileSync(path.join(dir, 'prompt-dumps.jsonl'), JSON.stringify(record) + '\n');
    } catch (error) {
        log.net.warn('[PromptDump] could not write the dump:', error);
    }
}

export async function abortKoboldCppIfNeeded(request, baseUrl) {
    await abortKoboldCppRequest(request, trimV1(baseUrl));
}

router.post('/generate', async function (request, response) {
    if (!request.body) return response.sendStatus(400);

    try {
        if (request.body.api_server.indexOf('localhost') !== -1) {
            request.body.api_server = request.body.api_server.replace('localhost', '127.0.0.1');
        }

        const apiType = request.body.api_type;
        const baseUrl = request.body.api_server;
        log.net.debug(request.body);

        const controller = new AbortController();
        request.socket.removeAllListeners('close');
        request.socket.on('close', async function () {
            if (request.body.api_type === TEXTGEN_TYPES.KOBOLDCPP && !response.writableEnded) {
                await abortKoboldCppRequest(request, trimV1(baseUrl));
            }

            controller.abort();
        });

        // Read before the upstream body is built, so the budget keys never reach the backend.
        const reasoningBudget = takeReasoningBudget(request.body);

        // The request log truncates long strings, so it cannot answer questions about the prompt.
        dumpPromptIfRequested(request);

        const { url, args, params } = await buildUpstreamRequest(request, request.body, controller.signal);
        request.body = params;

        if (request.body.api_type === TEXTGEN_TYPES.OLLAMA && request.body.stream) {
            const stream = await fetch(url, args);
            parseOllamaStream(stream, request, response);
        } else if (request.body.stream) {
            const completionsStream = await fetch(url, args);

            if (reasoningBudget) {
                // Its own signal: the first generation is abandoned mid-flight, and sharing one
                // would abort the continuation along with it.
                const continuation = new AbortController();
                request.socket.on('close', () => continuation.abort());
                const refetch = (nextParams) => fetch(url, { ...args, signal: continuation.signal, body: JSON.stringify(nextParams) });
                await forwardWithReasoningBudget(completionsStream, response, params, reasoningBudget, refetch);
            } else {
                await forwardFetchResponse(completionsStream, response);
            }
        } else {
            const completionsReply = await fetch(url, args);

            if (completionsReply.ok) {
                /** @type {any} */
                const data = await completionsReply.json();
                log.net.debug('Endpoint response:', data);

                // Map InfermaticAI response to OAI completions format
                if (apiType === TEXTGEN_TYPES.INFERMATICAI) {
                    data.choices = (data?.choices || []).map(choice => ({ text: choice?.message?.content || choice.text, logprobs: choice?.logprobs, index: choice?.index }));
                }

                return response.send(data);
            } else {
                const text = await completionsReply.text();
                const errorBody = { error: true, status: completionsReply.status, response: text };

                return !response.headersSent
                    ? response.send(errorBody)
                    : response.end();
            }
        }
    } catch (/** @type {any} */ error) {
        const status = error?.status ?? error?.code ?? 'UNKNOWN';
        const text = error?.error ?? error?.statusText ?? error?.message ?? 'Unknown error on /generate endpoint';
        let value = { error: true, status: status, response: text };
        log.net.error('Endpoint error:', error);

        return !response.headersSent
            ? response.send(value)
            : response.end();
    }
});

const ollama = express.Router();

ollama.post('/download', async function (request, response) {
    try {
        if (!request.body.name || !request.body.api_server) return response.sendStatus(400);

        const name = request.body.name;
        const url = String(request.body.api_server).replace(/\/$/, '');
        log.net.debug('Pulling Ollama model:', name);

        const fetchResponse = await fetch(`${url}/api/pull`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                name: name,
                stream: false,
            }),
        });

        if (!fetchResponse.ok) {
            log.net.error('Download error:', fetchResponse.status, fetchResponse.statusText);
            return response.status(500).send({ error: true });
        }

        log.net.debug('Ollama pull response:', await fetchResponse.json());
        return response.send({ ok: true });
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

ollama.post('/caption-image', async function (request, response) {
    try {
        if (!request.body.server_url || !request.body.model) {
            return response.sendStatus(400);
        }

        log.net.debug('Ollama caption request:', request.body);
        const baseUrl = trimV1(request.body.server_url);

        const fetchResponse = await fetch(`${baseUrl}/api/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                model: request.body.model,
                prompt: request.body.prompt,
                images: [request.body.image],
                stream: false,
            }),
        });

        if (!fetchResponse.ok) {
            const errorText = await fetchResponse.text();
            log.net.error('Ollama caption error:', fetchResponse.status, fetchResponse.statusText, errorText);
            return response.status(500).send({ error: true });
        }

        /** @type {any} */
        const data = await fetchResponse.json();
        log.net.debug('Ollama caption response:', data);

        const caption = data?.response || '';

        if (!caption) {
            log.net.error('Ollama caption is empty.');
            return response.status(500).send({ error: true });
        }

        return response.send({ caption });
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

const llamacpp = express.Router();

llamacpp.post('/props', async function (request, response) {
    try {
        if (!request.body.server_url) {
            return response.sendStatus(400);
        }

        log.net.debug('LlamaCpp props request:', request.body);
        const baseUrl = trimV1(request.body.server_url);

        const fetchResponse = await fetch(`${baseUrl}/props`, {
            method: 'GET',
        });

        if (!fetchResponse.ok) {
            log.net.error('LlamaCpp props error:', fetchResponse.status, fetchResponse.statusText);
            return response.status(500).send({ error: true });
        }

        const data = await fetchResponse.json();
        log.net.debug('LlamaCpp props response:', data);

        return response.send(data);
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

llamacpp.post('/slots', async function (request, response) {
    try {
        if (!request.body.server_url) {
            return response.sendStatus(400);
        }
        if (!/^(erase|info|restore|save)$/.test(request.body.action)) {
            return response.sendStatus(400);
        }

        log.net.debug('LlamaCpp slots request:', request.body);
        const baseUrl = trimV1(request.body.server_url);

        let fetchResponse;
        if (request.body.action === 'info') {
            fetchResponse = await fetch(`${baseUrl}/slots`, {
                method: 'GET',
            });
        } else {
            if (!/^\d+$/.test(request.body.id_slot)) {
                return response.sendStatus(400);
            }
            if (request.body.action !== 'erase' && !request.body.filename) {
                return response.sendStatus(400);
            }

            fetchResponse = await fetch(`${baseUrl}/slots/${request.body.id_slot}?action=${request.body.action}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    filename: request.body.action !== 'erase' ? `${request.body.filename}` : undefined,
                }),
            });
        }

        if (!fetchResponse.ok) {
            log.net.error('LlamaCpp slots error:', fetchResponse.status, fetchResponse.statusText);
            return response.status(500).send({ error: true });
        }

        const data = await fetchResponse.json();
        log.net.debug('LlamaCpp slots response:', data);

        return response.send(data);
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

const tabby = express.Router();

tabby.post('/download', async function (request, response) {
    try {
        const baseUrl = String(request.body.api_server).replace(/\/$/, '');

        const args = {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(request.body),
            timeout: 0,
        };

        await setAdditionalHeaders(request, args, baseUrl);

        // Check key permissions
        const permissionResponse = await fetch(`${baseUrl}/v1/auth/permission`, {
            headers: args.headers,
        });

        if (permissionResponse.ok) {
            /** @type {any} */
            const permissionJson = await permissionResponse.json();

            if (permissionJson.permission !== 'admin') {
                return response.status(403).send({ error: true });
            }
        } else {
            log.net.error('API Permission error:', permissionResponse.status, permissionResponse.statusText);
            return response.status(500).send({ error: true });
        }

        const fetchResponse = await fetch(`${baseUrl}/v1/download`, args);

        if (!fetchResponse.ok) {
            log.net.error('Download error:', fetchResponse.status, fetchResponse.statusText);
            return response.status(500).send({ error: true });
        }

        return response.send({ ok: true });
    } catch (error) {
        log.net.error(error);
        return response.sendStatus(500);
    }
});

router.use('/ollama', ollama);
router.use('/llamacpp', llamacpp);
router.use('/tabby', tabby);

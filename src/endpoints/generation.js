/**
 * Server-owned generation routes.
 *
 * start begins a generation and returns immediately; stream is the viewer, resumable at a cursor;
 * stop is the only thing that aborts an upstream, so a client disconnect never kills a generation;
 * active tells a freshly loaded page whether the chat it just opened is mid-reply.
 */

import express from 'express';
import fetch from 'node-fetch';
import writeFileAtomic from 'write-file-atomic';
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';

import { SETTINGS_FILE, TEXTGEN_TYPES } from '../constants.js';
import { log } from '../log.js';
import { emitToUser } from '../client-events.js';
import { createSession, getSession, findActiveForChat, listActive, MAX_ACTIVE_PER_HANDLE, Status, DONE_PAYLOAD } from '../generation-session.js';
import { composeReply } from '../reply-cleanup.js';
import { assemblePrompt } from '../prompt-builder.js';
import { buildPromptRequest } from '../prompt-request.js';
import { createTokenCounter } from '../token-count.js';
import { buildUpstreamRequest } from './backends/text-completions.js';
import { ChatRef, appendChatMessages, updateChatMetadata } from './chats.js';

export const router = express.Router();

const SSE_HEADERS = {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
};

/**
 * Resolves the chat a generation targets. Every path component is derived from the server-side user,
 * and ChatRef rejects anything that escapes the user's chat root, so a crafted body cannot steer the
 * completion write outside the caller's own directories.
 * @param {any} user The request user with resolved directories.
 * @param {any} chat The chat descriptor from the request.
 * @returns {import('../generation-session.js').GenerationTarget & {ref: ChatRef}|null}
 */
function resolveTarget(user, chat) {
    if (!chat || typeof chat !== 'object') {
        return null;
    }
    const characterName = typeof chat.character_name === 'string' ? chat.character_name : '';
    if (chat.group_id) {
        const ref = ChatRef.group(user, chat.group_id);
        if (!ref) {
            return null;
        }
        return {
            ref,
            filePath: ref.filePath,
            cardName: String(chat.group_id),
            fileName: null,
            avatarUrl: null,
            groupId: String(chat.group_id),
            characterName,
        };
    }
    if (!chat.avatar_url || !chat.file_name) {
        return null;
    }
    const ref = ChatRef.solo(user, chat.avatar_url, chat.file_name);
    if (!ref) {
        return null;
    }
    return {
        ref,
        filePath: ref.filePath,
        cardName: String(chat.avatar_url).replace('.png', ''),
        fileName: String(chat.file_name),
        avatarUrl: String(chat.avatar_url),
        groupId: null,
        characterName,
    };
}

/**
 * Whether the completion write would find a chat to append to. appendChatMessages rejects a missing
 * or empty file, so without this check a generation runs to completion and is then discarded.
 * @param {string} filePath Resolved chat file path.
 * @returns {Promise<boolean>}
 */
async function chatFileWritable(filePath) {
    const stat = await fs.promises.stat(filePath).catch(() => null);
    return Boolean(stat && stat.isFile() && stat.size > 0);
}

/**
 * Appends the finished assistant turn through the one chat writer. The client no longer persists it,
 * so this is the only path onto disk and a double append is structurally impossible.
 * @param {import('../generation-session.js').GenerationSession} session The finished session.
 * @returns {Promise<void>}
 */
async function persistAssistantTurn(session) {
    if (session.persisted || (!session.text && !session.thinking)) {
        return;
    }
    // Claimed before the await so a stop racing the natural end cannot both reach the writer.
    session.persisted = true;
    const message = {
        name: session.target.characterName,
        is_user: false,
        is_system: false,
        send_date: Date.now(),
        // The prompt ended with the user's bias, so the model continued FROM it and the bias is part of
        // this turn. Stock prepends it before saving (script.js:6431) and hides it on display.
        mes: composeReply({
            prefix: session.replyPrefix,
            text: session.text,
            trimSentences: session.trimSentences,
            trimSpaces: session.trimSpaces,
        }),
        extra: { reasoning: session.thinking, bias: session.replyPrefix || null },
    };
    try {
        const result = await appendChatMessages(session.user, session.target.ref, session.target.cardName, [message]);
        if (!result.ok) {
            session.persisted = false;
            log.chat.error(`Generation ${session.id}: assistant turn not persisted (${result.status} ${result.error})`);
            return;
        }
        // generation_id lets the tab that watched this generation skip the append it already rendered,
        // while every other tab still gets the turn without refetching the file.
        emitToUser(session.handle, 'chat-appended', {
            card: session.target.cardName,
            file: session.target.fileName,
            group_id: session.target.groupId,
            generation_id: session.id,
            messages: [message],
            change_token: result.change_token,
        });
    } catch (/** @type {any} */ error) {
        session.persisted = false;
        log.chat.error(`Generation ${session.id}: assistant turn write failed:`, error);
    }
}

/**
 * @param {import('../generation-session.js').GenerationSession} session The session to end.
 * @param {string} status Terminal status.
 * @param {string} [detail] Error detail for the log.
 * @returns {Promise<void>}
 */
async function finishGeneration(session, status, detail = '') {
    if (session.status !== Status.running) {
        return;
    }
    if (detail) {
        log.net.warn(`Generation ${session.id} ended as ${status}: ${detail}`);
    }
    session.finish(status, detail);
    // Abort only after the status is claimed: the upstream body errors synchronously when aborted,
    // and that error path would otherwise re-seal a deliberate stop as a failure.
    if (status === Status.stopped) {
        session.abort();
    }
    await persistAssistantTurn(session);
}

/**
 * Pumps the upstream SSE body into the session's frame log. Nothing here is tied to a client
 * connection: the pump owns the generation for its whole life.
 * @param {import('../generation-session.js').GenerationSession} session Target session.
 * @param {any} upstreamBody The upstream response body stream.
 * @param {boolean} isOllama Whether the upstream speaks Ollama's bare-JSON stream.
 * @returns {void}
 */
function pumpUpstream(session, upstreamBody, isOllama) {
    let buffer = '';
    let ended = false;

    const stop = (status, detail) => {
        if (ended) {
            return;
        }
        ended = true;
        if (upstreamBody instanceof Readable && !upstreamBody.destroyed) {
            upstreamBody.destroy();
        }
        finishGeneration(session, status, detail).catch(error => log.net.error('Generation finish failed:', error));
    };

    upstreamBody.on('data', (chunk) => {
        buffer += chunk.toString();
        if (isOllama) {
            for (;;) {
                let parsed;
                try {
                    parsed = JSON.parse(buffer);
                } catch {
                    break;
                }
                buffer = '';
                session.pushFrame(JSON.stringify({ choices: [{ text: parsed.response || '', thinking: parsed.thinking || '' }] }));
            }
            return;
        }
        let newline;
        while ((newline = buffer.indexOf('\n')) !== -1) {
            const line = buffer.slice(0, newline).replace(/\r$/, '');
            buffer = buffer.slice(newline + 1);
            if (!line.startsWith('data:')) {
                continue;
            }
            const payload = line.slice(5).trim();
            if (payload.length === 0) {
                continue;
            }
            if (payload === DONE_PAYLOAD) {
                stop(Status.done, '');
                return;
            }
            session.pushFrame(payload);
        }
    });

    upstreamBody.on('error', (error) => {
        stop(Status.error, `upstream stream failed: ${error?.message ?? error}`);
    });

    upstreamBody.on('end', () => {
        // A final payload with no trailing newline still carries a token.
        const trailing = buffer.trim();
        if (trailing.startsWith('data:')) {
            const payload = trailing.slice(5).trim();
            if (payload.length > 0 && payload !== DONE_PAYLOAD) {
                session.pushFrame(payload);
            }
        }
        stop(Status.done, '');
    });
}

/**
 * @param {import('../generation-session.js').GenerationSession} session Target session.
 * @param {string} url Upstream url.
 * @param {any} args Upstream fetch args.
 * @param {string} apiType The backend type.
 * @returns {Promise<void>}
 */
async function runUpstream(session, url, args, apiType) {
    let upstream;
    try {
        upstream = await fetch(url, args);
    } catch (/** @type {any} */ error) {
        await finishGeneration(session, Status.error, `upstream unreachable: ${error?.message ?? error}`);
        return;
    }
    if (!upstream.ok || !upstream.body) {
        // Several backends echo the offending request, prompt text included, in a 4xx body. The
        // status is the diagnostic; the body is dropped unread rather than logged or buffered.
        if (upstream.body instanceof Readable) {
            upstream.body.destroy();
        }
        session.pushFrame(JSON.stringify({ error: { status: upstream.status, message: 'The backend refused the generation request.' } }));
        await finishGeneration(session, Status.error, `upstream status ${upstream.status}`);
        return;
    }
    pumpUpstream(session, upstream.body, apiType === TEXTGEN_TYPES.OLLAMA);
}

/**
 * Writes the variables a build set: chat variables into the chat's own header metadata, globals into
 * the settings blob, each only when that store was actually written to. A failure here is logged and
 * swallowed: the generation is already running, and losing a variable is not worth failing a reply.
 * @param {import('express').Request} request The request being served.
 * @param {any} target Resolved chat target.
 * @param {object|null} variables Chat variables, or null when none were set.
 * @param {object|null} globalVariables Global variables, or null when none were set.
 * @returns {Promise<void>}
 */
async function commitVariables(request, target, variables, globalVariables) {
    try {
        if (variables) {
            await updateChatMetadata(target.ref, { variables });
        }
        if (globalVariables) {
            const settingsPath = path.join(request.user.directories.root, SETTINGS_FILE);
            const settings = JSON.parse(await fs.promises.readFile(settingsPath, 'utf8'));
            const extensions = settings.extension_settings = settings.extension_settings ?? {};
            extensions.variables = { ...(extensions.variables ?? {}), global: globalVariables };
            await writeFileAtomic(settingsPath, JSON.stringify(settings, null, 4));
        }
    } catch (/** @type {any} */ error) {
        log.net.error('Persisting prompt variables failed:', error?.message ?? error);
    }
}

router.post('/start', async function (request, response) {
    try {
        const body = request.body;
        if (!body || typeof body !== 'object') {
            return response.sendStatus(400);
        }
        const target = resolveTarget(request.user, body.chat);
        if (!target) {
            return response.status(400).send({ error: 'bad_chat_target' });
        }
        const params = body.generate;
        if (!params || typeof params !== 'object' || Array.isArray(params) || typeof params.api_server !== 'string') {
            return response.status(400).send({ error: 'bad_generate_params' });
        }

        if (!await chatFileWritable(target.filePath)) {
            return response.status(404).send({ error: 'no_such_chat' });
        }

        const handle = request.user.profile.handle;
        const running = findActiveForChat(handle, target.filePath);
        if (running) {
            return response.status(409).send({
                error: 'already_running',
                generation_id: running.id,
                last_event_id: running.lastEventId,
            });
        }
        // The 409 above only dedupes one chat file, so a caller varying the chat could otherwise hold
        // an unbounded number of upstream sockets under one handle.
        if (listActive(handle).length >= MAX_ACTIVE_PER_HANDLE) {
            return response.status(429).send({ error: 'too_many_generations', limit: MAX_ACTIVE_PER_HANDLE });
        }

        /** @type {object|null} */
        let pendingVariables = null;
        /** @type {object|null} */
        let pendingGlobalVariables = null;
        // ASSEMBLY IS THE SERVER'S when the caller does not supply a prompt. The builder is the same
        // code the browser runs, proven byte-identical against it over the scenario set, so this is a
        // re-hosting rather than a second implementation. A caller that DOES send a prompt keeps the
        // old path, which is what lets the client move over without a flag day.
        if (typeof params.prompt !== 'string' || params.prompt.length === 0) {
            try {
                const built = await assemblePrompt(
                    await buildPromptRequest({
                        charactersPath: request.user.directories.characters,
                        worldsPath: request.user.directories.worlds,
                        settingsPath: path.join(request.user.directories.root, SETTINGS_FILE),
                        chatFilePath: target.filePath,
                        chat: body.chat,
                        browser: body.browser ?? {},
                    }),
                    {
                        countTokens: createTokenCounter({
                            directories: request.user.directories,
                            apiType: params.api_type,
                            model: params.model,
                            apiServer: params.api_server,
                            secretId: params.secret_id ?? null,
                        }),
                    },
                );
                params.prompt = built.prompt;
                if (Array.isArray(built.stop) && built.stop.length > 0) {
                    params.stop = built.stop;
                }
                if (!body.reply_prefix && built.replyPrefix) {
                    body.reply_prefix = built.replyPrefix;
                }
                // Staged, not written: a {{setvar}} takes effect only if the generation it was built
                // for actually starts, so a refused or unbuildable send leaves the variables alone.
                pendingVariables = built.variables;
                pendingGlobalVariables = built.globalVariables;
            } catch (error) {
                log.net.error('Server-side prompt assembly failed:', error);
                return response.status(500).send({ error: 'prompt_assembly_failed' });
            }
        }

        const session = createSession(handle, target);
        session.user = request.user;
        // Bounded and type-checked: it is client-supplied text that lands in a saved chat file.
        session.replyPrefix = typeof body.reply_prefix === 'string' ? body.reply_prefix.slice(0, 2048) : '';
        session.trimSentences = body.trim_sentences === true;
        session.trimSpaces = body.trim_spaces !== false;
        session.onExpire = (reason) => {
            finishGeneration(session, Status.error, reason).catch(error => log.net.error('Generation watchdog finish failed:', error));
        };
        // The whole design is a token stream; a non-streaming upstream would return one blob with no
        // frames to replay, so the flag is set here rather than trusted from the body.
        params.stream = true;
        const { url, args, apiType } = await buildUpstreamRequest(request, { ...params }, session.controller.signal);
        runUpstream(session, url, args, apiType).catch(error => log.net.error('Generation start failed:', error));

        // The generation is under way, so the staged variable writes are now owed.
        await commitVariables(request, target, pendingVariables, pendingGlobalVariables);

        return response.send({ generation_id: session.id, last_event_id: session.lastEventId });
    } catch (/** @type {any} */ error) {
        log.net.error('Generation start error:', error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

/**
 * The cursor a viewer is resuming from. The query carries it because the door pump builds a fixed
 * header set and cannot send Last-Event-ID; the header is still honoured when a real EventSource
 * reconnects on its own.
 * @param {import('express').Request} request Express request.
 * @returns {number} Zero for a fresh viewer, otherwise the last frame id it holds.
 */
function readCursor(request) {
    const fromQuery = request.query.since;
    if (typeof fromQuery === 'string' && fromQuery.length > 0) {
        const parsed = Number.parseInt(fromQuery, 10);
        return Number.isFinite(parsed) ? parsed : -1;
    }
    const header = request.headers['last-event-id'];
    if (typeof header === 'string' && header.length > 0) {
        const parsed = Number.parseInt(header, 10);
        return Number.isFinite(parsed) ? parsed : -1;
    }
    return 0;
}

router.get('/:id/stream', function (request, response) {
    const handle = request.user.profile.handle;
    const session = getSession(handle, request.params.id);
    if (!session) {
        return response.status(404).send({ error: 'no_such_generation' });
    }

    response.writeHead(200, SSE_HEADERS);
    response.flushHeaders?.();

    const write = (chunk) => {
        if (response.writableEnded || response.destroyed) {
            return false;
        }
        try {
            response.write(chunk);
            if (typeof response.flush === 'function') {
                response.flush();
            }
        } catch (/** @type {any} */ error) {
            log.net.warn('Generation stream write failed:', error);
            return false;
        }
        return true;
    };

    const cursor = readCursor(request);
    const { frames, complete } = session.framesSince(cursor);
    if (!complete) {
        // The viewer asked for frames the log can no longer serve. Telling it to resynchronise beats
        // handing it a stream with a hole in it that it would render as finished text.
        write('event: resync\ndata: {}\n\n');
        return response.end();
    }
    for (const frame of frames) {
        write(`id: ${frame.id}\ndata: ${frame.data}\n\n`);
    }
    if (!session.active) {
        return response.end();
    }

    const unsubscribe = session.subscribe((frame) => {
        if (frame === null) {
            response.end();
            return;
        }
        if (!write(`id: ${frame.id}\ndata: ${frame.data}\n\n`)) {
            unsubscribe();
        }
    });

    // A viewer leaving is not a generation ending: unsubscribe only, never abort.
    request.on('close', unsubscribe);
    response.on('close', unsubscribe);
});

router.post('/:id/stop', async function (request, response) {
    try {
        const handle = request.user.profile.handle;
        const session = getSession(handle, request.params.id);
        if (!session) {
            return response.status(404).send({ error: 'no_such_generation' });
        }
        if (!session.active) {
            return response.send({ ok: true, status: session.status });
        }
        await finishGeneration(session, Status.stopped, '');
        return response.send({ ok: true, status: session.status });
    } catch (/** @type {any} */ error) {
        log.net.error('Generation stop error:', error);
        if (!response.headersSent) {
            return response.sendStatus(500);
        }
    }
});

router.get('/active', function (request, response) {
    try {
        const handle = request.user.profile.handle;
        const target = resolveTarget(request.user, {
            avatar_url: request.query.avatar_url,
            file_name: request.query.file_name,
            group_id: request.query.group_id,
        });
        if (!target) {
            return response.status(400).send({ error: 'bad_chat_target' });
        }
        const session = findActiveForChat(handle, target.filePath);
        if (!session) {
            return response.send({ active: false });
        }
        return response.send({
            active: true,
            generation_id: session.id,
            last_event_id: session.lastEventId,
            character_name: session.target.characterName,
        });
    } catch (/** @type {any} */ error) {
        log.net.error('Generation active lookup error:', error);
        return response.sendStatus(500);
    }
});

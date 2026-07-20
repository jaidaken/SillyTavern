import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
import yaml from 'yaml';
import { spawn } from 'node:child_process';

import { SillyTavernServer, DEFAULT_HANDLE, allocatePort, SERVER_ROOT } from '../util/st-server.js';
import { SillyTavernClient } from '../util/st-client.js';

const BOOT_TIMEOUT_MS = 180000;
const CASE_TIMEOUT_MS = 30000;
const CFID_ENV = 'SILLYTAVERN_CHAT_CFID_ENABLED';

const SMOKE_CONFIG = Object.freeze({
    listen: false,
    whitelistMode: true,
    browserLaunch: { enabled: false },
    enableUserAccounts: true,
    enableCorsProxy: true,
});

/**
 * Boots server.js against a throwaway data root with an explicit environment, so the child
 * process actually sees the cf_id flag (Jest sandboxes process.env away from child_process).
 * @param {Record<string, string>} extraEnv Environment overrides for the child.
 * @returns {Promise<{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}>}
 */
async function startServerWithEnv(extraEnv) {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'st-append-'));
    const dataRoot = path.join(tempDir, 'data');
    const configPath = path.join(tempDir, 'config.yaml');
    const logPath = path.join(tempDir, 'server.log');
    fs.writeFileSync(configPath, yaml.stringify(SMOKE_CONFIG), 'utf8');
    const port = await allocatePort();

    const logFd = fs.openSync(logPath, 'a');
    const child = spawn(process.execPath, [
        path.join(SERVER_ROOT, 'server.js'),
        '--configPath', configPath,
        '--dataRoot', dataRoot,
        '--port', String(port),
    ], { cwd: SERVER_ROOT, stdio: ['ignore', logFd, logFd], env: { ...process.env, ...extraEnv } });
    fs.closeSync(logFd);

    let exitCode = null;
    child.once('exit', code => { exitCode = code ?? -1; });

    const baseUrl = `http://127.0.0.1:${port}`;
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
        if (exitCode !== null) {
            throw new Error(`Server exited with ${exitCode} before ready.\n${fs.readFileSync(logPath, 'utf8').split('\n').slice(-40).join('\n')}`);
        }
        try {
            const response = await fetch(`${baseUrl}/csrf-token`);
            await response.arrayBuffer();
            if (response.ok) {
                break;
            }
        } catch {
            // Connection is refused until the server binds its port.
        }
        await new Promise(resolve => setTimeout(resolve, 100));
    }

    return {
        baseUrl,
        userDirectory: (handle = DEFAULT_HANDLE) => path.join(dataRoot, handle),
        stop: async () => {
            if (child && exitCode === null) {
                const exited = new Promise(resolve => child.once('exit', resolve));
                child.kill('SIGTERM');
                const killTimer = setTimeout(() => child.kill('SIGKILL'), 15000);
                await exited;
                clearTimeout(killTimer);
            }
            fs.rmSync(tempDir, { recursive: true, force: true });
        },
    };
}

/**
 * @param {string} characterName Character name for the header.
 * @returns {object} A chat metadata header line.
 */
function chatHeader(characterName) {
    return { user_name: 'You', character_name: characterName, chat_metadata: { integrity: 'append-test' } };
}

/**
 * @param {number} count Number of messages.
 * @param {(index: number) => object} [extra] Extra per-message fields keyed by index.
 * @returns {object[]} Ordered messages whose mes text encodes its index.
 */
function buildMessages(count, extra = () => ({})) {
    const messages = [];
    for (let i = 0; i < count; i++) {
        messages.push({
            name: i % 2 === 0 ? 'You' : 'Bot',
            is_user: i % 2 === 0,
            mes: `message ${i}`,
            send_date: 1700000000000 + i,
            extra: {},
            ...extra(i),
        });
    }
    return messages;
}

/**
 * @param {string} text The message text.
 * @param {boolean} isUser Whether the message is from the user.
 * @param {number} sendDate The send date epoch millis.
 * @returns {object} An ST-shaped message object.
 */
function newMessage(text, isUser, sendDate) {
    return { name: isUser ? 'You' : 'Bot', is_user: isUser, is_system: false, mes: text, send_date: sendDate, extra: {} };
}

/**
 * @param {{userDirectory: (handle?: string) => string}} server The running server.
 * @param {string} card The character card name without extension.
 * @param {string} fileName The chat file name without extension.
 * @returns {string} The absolute chat file path.
 */
function soloChatPath(server, card, fileName) {
    return path.join(server.userDirectory(), 'chats', card, `${fileName}.jsonl`);
}

/**
 * @param {{userDirectory: (handle?: string) => string}} server The running server.
 * @param {string} id The group chat id.
 * @returns {string} The absolute group chat file path.
 */
function groupChatPath(server, id) {
    return path.join(server.userDirectory(), 'group chats', `${id}.jsonl`);
}

/**
 * Writes a header plus messages as jsonl (no trailing newline), creating parent directories.
 * @param {string} filePath Target file path.
 * @param {object} header Header line object.
 * @param {object[]} messages Message objects.
 */
function writeChatFile(filePath, header, messages) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const lines = [JSON.stringify(header), ...messages.map(m => JSON.stringify(m))];
    fs.writeFileSync(filePath, lines.join('\n'), 'utf8');
}

/**
 * @param {string} filePath A jsonl chat file.
 * @returns {object[]} Parsed non-empty lines (header first, then messages).
 */
function readChatLines(filePath) {
    return fs.readFileSync(filePath, 'utf8').split('\n').filter(line => line.length > 0).map(line => JSON.parse(line));
}

/**
 * @param {{baseUrl: string}} server The running server.
 * @returns {Promise<SillyTavernClient>} A logged-in client.
 */
async function loggedInClient(server) {
    const client = new SillyTavernClient(server.baseUrl);
    await client.fetchCsrfToken();
    const login = await client.login(DEFAULT_HANDLE);
    if (login.status !== 200) {
        throw new Error(`Shared client failed to log in: ${login.status} ${await login.text()}`);
    }
    return client;
}

/**
 * Polls the user's backups directory for a chat backup file and returns its parsed lines.
 * @param {{userDirectory: (handle?: string) => string}} server The running server.
 * @param {string} baseName The sanitized backup base name (card, lowercased, non-alphanumeric to underscore).
 * @returns {Promise<object[]>} Parsed lines of the newest matching backup, or [] if none appeared.
 */
async function pollBackupLines(server, baseName) {
    const dir = path.join(server.userDirectory(), 'backups');
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
        const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter(f => f.startsWith(`chat_${baseName}_`)) : [];
        if (files.length > 0) {
            files.sort();
            const raw = fs.readFileSync(path.join(dir, files[files.length - 1]), 'utf8');
            return raw.split('\n').filter(line => line.length > 0).map(line => JSON.parse(line));
        }
        await new Promise(resolve => setTimeout(resolve, 50));
    }
    return [];
}

describe('chat append (cf_id flag off)', () => {
    /** @type {SillyTavernServer} */
    let server;
    /** @type {SillyTavernClient} */
    let client;

    beforeAll(async () => {
        server = new SillyTavernServer();
        await server.start();
        client = await loggedInClient(server);
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    test('append_preserves_every_existing_line_byte_identical', async () => {
        const filePath = soloChatPath(server, 'CardByte', 'chatByte');
        writeChatFile(filePath, chatHeader('CardByte'), buildMessages(40));
        const before = fs.readFileSync(filePath, 'utf8');

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardByte.png', file_name: 'chatByte',
            messages: [newMessage('appended a', true, 1700000001000), newMessage('appended b', false, 1700000001001)],
        });
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.ok).toBe(true);
        expect(body.appended).toBe(2);

        const after = fs.readFileSync(filePath, 'utf8');
        expect(after.startsWith(`${before}\n`)).toBe(true);
        const lines = readChatLines(filePath);
        expect(lines).toHaveLength(43);
        expect(lines[0]).toEqual(chatHeader('CardByte'));
        expect(lines[40].mes).toBe('message 39');
        expect(lines[41].mes).toBe('appended a');
        expect(lines[42].mes).toBe('appended b');
    }, CASE_TIMEOUT_MS);

    test('append_returns_token_that_equals_a_subsequent_get_tail', async () => {
        const filePath = soloChatPath(server, 'CardTok', 'chatTok');
        writeChatFile(filePath, chatHeader('CardTok'), buildMessages(120));

        const appendResponse = await client.postJson('/api/chats/append', {
            avatar_url: 'CardTok.png', file_name: 'chatTok', limit: 50,
            messages: [newMessage('fresh', true, 1700000002000)],
        });
        expect(appendResponse.status).toBe(200);
        const appendBody = await appendResponse.json();

        const getResponse = await client.postJson('/api/chats/get', {
            avatar_url: 'CardTok.png', file_name: 'chatTok', paged: true, limit: 50,
        });
        const getBody = await getResponse.json();
        expect(appendBody.tail_token).toBe(getBody.change_token);
        expect(appendBody.change_token).toBe(getBody.full_token);
        expect(appendBody.change_token).not.toBe(getBody.change_token);
        expect(getBody.total_items).toBe(121);
        expect(getBody.messages[49].mes).toBe('fresh');
    }, CASE_TIMEOUT_MS);

    test('a_clients_own_append_does_not_stale_a_later_before_read', async () => {
        const filePath = soloChatPath(server, 'CardNo409', 'chatNo409');
        writeChatFile(filePath, chatHeader('CardNo409'), buildMessages(200));

        const tail = await (await client.postJson('/api/chats/get', {
            avatar_url: 'CardNo409.png', file_name: 'chatNo409', paged: true, limit: 50,
        })).json();
        expect(tail.messages[0].mes).toBe('message 150');
        const token = tail.change_token;

        const appendResponse = await client.postJson('/api/chats/append', {
            avatar_url: 'CardNo409.png', file_name: 'chatNo409', limit: 50, change_token: tail.full_token,
            messages: [newMessage('one', true, 1700000003000), newMessage('two', false, 1700000003001)],
        });
        expect(appendResponse.status).toBe(200);

        const before = await client.postJson('/api/chats/get', {
            avatar_url: 'CardNo409.png', file_name: 'chatNo409', paged: true, limit: 50, before_index: 150, change_token: token,
        });
        expect(before.status).toBe(200);
        const beforeBody = await before.json();
        expect(beforeBody.messages[0].mes).toBe('message 100');
        expect(beforeBody.messages[49].mes).toBe('message 149');
    }, CASE_TIMEOUT_MS);

    test('append_with_a_stale_change_token_409s_and_never_writes', async () => {
        const filePath = soloChatPath(server, 'CardStale', 'chatStale');
        writeChatFile(filePath, chatHeader('CardStale'), buildMessages(10));
        const before = fs.readFileSync(filePath, 'utf8');

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardStale.png', file_name: 'chatStale', limit: 100, change_token: 'v1.0.deadbeefdeadbeef',
            messages: [newMessage('should not land', true, 1700000004000)],
        });
        expect(response.status).toBe(409);
        const body = await response.json();
        expect(body.error).toBe('version_mismatch');
        expect(typeof body.change_token).toBe('string');

        const after = fs.readFileSync(filePath, 'utf8');
        expect(after).toBe(before);
        expect(readChatLines(filePath)).toHaveLength(11);
    }, CASE_TIMEOUT_MS);

    test('append_with_the_current_change_token_succeeds', async () => {
        const filePath = soloChatPath(server, 'CardCur', 'chatCur');
        writeChatFile(filePath, chatHeader('CardCur'), buildMessages(10));

        const tail = await (await client.postJson('/api/chats/get', {
            avatar_url: 'CardCur.png', file_name: 'chatCur', paged: true, limit: 100,
        })).json();

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardCur.png', file_name: 'chatCur', limit: 100, change_token: tail.full_token,
            messages: [newMessage('accepted', true, 1700000005000)],
        });
        expect(response.status).toBe(200);
        expect(readChatLines(filePath)).toHaveLength(12);
    }, CASE_TIMEOUT_MS);

    test('append_after_a_larger_limit_resync_still_persists', async () => {
        const filePath = soloChatPath(server, 'CardResync', 'chatResync');
        writeChatFile(filePath, chatHeader('CardResync'), buildMessages(120));

        // A re-sync loads a large window (loaded + BATCH), so the client holds the full-file token
        // minted alongside a limit-150 read; the append then declares the fixed TAIL_LIMIT of 50.
        const resync = await (await client.postJson('/api/chats/get', {
            avatar_url: 'CardResync.png', file_name: 'chatResync', paged: true, limit: 150,
        })).json();
        const tail50 = await (await client.postJson('/api/chats/get', {
            avatar_url: 'CardResync.png', file_name: 'chatResync', paged: true, limit: 50,
        })).json();
        // The two reads share one full token but differ on the limit-dependent tail token: the old
        // tail-token gate would 409 this append forever; the full-token gate must accept it.
        expect(resync.full_token).toBe(tail50.full_token);
        expect(resync.change_token).not.toBe(tail50.change_token);

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardResync.png', file_name: 'chatResync', limit: 50, change_token: resync.full_token,
            messages: [newMessage('after resync', true, 1700000006000)],
        });
        expect(response.status).toBe(200);
        expect(readChatLines(filePath)).toHaveLength(122);
        expect(readChatLines(filePath)[121].mes).toBe('after resync');
    }, CASE_TIMEOUT_MS);

    test('append_still_409s_when_the_file_changed_under_the_client', async () => {
        const filePath = soloChatPath(server, 'CardRace', 'chatRace');
        writeChatFile(filePath, chatHeader('CardRace'), buildMessages(20));

        const view = await (await client.postJson('/api/chats/get', {
            avatar_url: 'CardRace.png', file_name: 'chatRace', paged: true, limit: 50,
        })).json();

        // A concurrent writer appends a line after the client took its view, so the held full token
        // is now stale; the guard must still reject rather than silently write onto a changed file.
        fs.appendFileSync(filePath, '\n' + JSON.stringify(newMessage('outside writer', false, 1700000007000)), 'utf8');
        const before = fs.readFileSync(filePath, 'utf8');

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardRace.png', file_name: 'chatRace', limit: 50, change_token: view.full_token,
            messages: [newMessage('should be rejected', true, 1700000007001)],
        });
        expect(response.status).toBe(409);
        expect((await response.json()).error).toBe('version_mismatch');
        expect(fs.readFileSync(filePath, 'utf8')).toBe(before);
    }, CASE_TIMEOUT_MS);

    test('the_backup_written_on_append_holds_the_full_chat_not_just_the_new_lines', async () => {
        const filePath = soloChatPath(server, 'CardBak', 'chatBak');
        writeChatFile(filePath, chatHeader('CardBak'), buildMessages(15));

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardBak.png', file_name: 'chatBak',
            messages: [newMessage('tail message', true, 1700000006000)],
        });
        expect(response.status).toBe(200);

        const backupLines = await pollBackupLines(server, 'cardbak');
        expect(backupLines.length).toBe(17);
        expect(backupLines[0].chat_metadata.integrity).toBe('append-test');
        expect(backupLines[1].mes).toBe('message 0');
        expect(backupLines[16].mes).toBe('tail message');
    }, CASE_TIMEOUT_MS);

    test('append_to_a_file_ending_in_a_newline_adds_no_blank_line', async () => {
        const filePath = soloChatPath(server, 'CardNL', 'chatNL');
        writeChatFile(filePath, chatHeader('CardNL'), buildMessages(5));
        fs.appendFileSync(filePath, '\n', 'utf8');

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardNL.png', file_name: 'chatNL',
            messages: [newMessage('after newline', false, 1700000007000)],
        });
        expect(response.status).toBe(200);

        const raw = fs.readFileSync(filePath, 'utf8');
        expect(raw.includes('\n\n')).toBe(false);
        const lines = readChatLines(filePath);
        expect(lines).toHaveLength(7);
        expect(lines[6].mes).toBe('after newline');
    }, CASE_TIMEOUT_MS);

    test('concurrent_append_and_whole_file_save_leave_a_parseable_file', async () => {
        const filePath = soloChatPath(server, 'CardRace', 'chatRace');
        writeChatFile(filePath, chatHeader('CardRace'), buildMessages(30));
        const saveArray = [chatHeader('CardRace'), ...buildMessages(30), newMessage('via save', true, 1700000008000)];

        const [appendResponse, saveResponse] = await Promise.all([
            client.postJson('/api/chats/append', {
                avatar_url: 'CardRace.png', file_name: 'chatRace',
                messages: [newMessage('via append', false, 1700000008001)],
            }),
            client.postJson('/api/chats/save', { avatar_url: 'CardRace.png', file_name: 'chatRace', chat: saveArray, force: true }),
        ]);
        expect([200]).toContain(appendResponse.status);
        expect(saveResponse.status).toBe(200);

        const raw = fs.readFileSync(filePath, 'utf8');
        const nonEmpty = raw.split('\n').filter(line => line.length > 0);
        expect(() => nonEmpty.forEach(line => JSON.parse(line))).not.toThrow();
        const parsed = nonEmpty.map(line => JSON.parse(line));
        expect(parsed[0].chat_metadata.integrity).toBe('append-test');
        expect(parsed.length).toBeGreaterThanOrEqual(31);
    }, CASE_TIMEOUT_MS);

    test('append_to_a_group_chat_appends_verbatim', async () => {
        const filePath = groupChatPath(server, 'group-append');
        writeChatFile(filePath, chatHeader('GroupA'), buildMessages(8));

        const response = await client.postJson('/api/chats/append', {
            group_id: 'group-append',
            messages: [newMessage('group tail', false, 1700000009000)],
        });
        expect(response.status).toBe(200);
        const lines = readChatLines(filePath);
        expect(lines).toHaveLength(10);
        expect(lines[9].mes).toBe('group tail');
    }, CASE_TIMEOUT_MS);

    test('append_does_not_mint_cf_id_when_the_flag_is_off', async () => {
        const filePath = soloChatPath(server, 'CardOff', 'chatOff');
        writeChatFile(filePath, chatHeader('CardOff'), buildMessages(4));

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardOff.png', file_name: 'chatOff',
            messages: [newMessage('no id', true, 1700000010000)],
        });
        expect(response.status).toBe(200);
        const lines = readChatLines(filePath);
        expect(lines[5].cf_id).toBeUndefined();
    }, CASE_TIMEOUT_MS);

    test('append_to_an_absent_chat_returns_404', async () => {
        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardGhost.png', file_name: 'nope',
            messages: [newMessage('into the void', true, 1700000011000)],
        });
        expect(response.status).toBe(404);
    }, CASE_TIMEOUT_MS);

    test('append_with_an_empty_messages_array_returns_400', async () => {
        const filePath = soloChatPath(server, 'CardEmpty', 'chatEmpty');
        writeChatFile(filePath, chatHeader('CardEmpty'), buildMessages(3));
        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardEmpty.png', file_name: 'chatEmpty', messages: [],
        });
        expect(response.status).toBe(400);
        expect(readChatLines(filePath)).toHaveLength(4);
    }, CASE_TIMEOUT_MS);

    test('append_with_a_non_object_message_returns_400', async () => {
        const filePath = soloChatPath(server, 'CardBad', 'chatBad');
        writeChatFile(filePath, chatHeader('CardBad'), buildMessages(3));
        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardBad.png', file_name: 'chatBad', messages: ['not an object'],
        });
        expect(response.status).toBe(400);
        expect(readChatLines(filePath)).toHaveLength(4);
    }, CASE_TIMEOUT_MS);

    test('append_rejects_a_path_traversal_file_name', async () => {
        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardTrav.png', file_name: '../../../../etc/passwd',
            messages: [newMessage('escape', true, 1700000012000)],
        });
        expect([400, 404]).toContain(response.status);
    }, CASE_TIMEOUT_MS);
});

describe('chat append (cf_id flag on)', () => {
    /** @type {{baseUrl: string, userDirectory: (handle?: string) => string, stop: () => Promise<void>}} */
    let server;
    /** @type {SillyTavernClient} */
    let client;

    beforeAll(async () => {
        server = await startServerWithEnv({ [CFID_ENV]: 'true' });
        client = await loggedInClient(server);
    }, BOOT_TIMEOUT_MS);

    afterAll(async () => {
        await server?.stop();
    }, BOOT_TIMEOUT_MS);

    test('append_mints_cf_id_on_the_new_messages_only', async () => {
        const filePath = soloChatPath(server, 'CardOn', 'chatOn');
        writeChatFile(filePath, chatHeader('CardOn'), buildMessages(6, i => ({ cf_id: `EXIST${i}` })));

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardOn.png', file_name: 'chatOn',
            messages: [newMessage('minted a', true, 1700000013000), newMessage('minted b', false, 1700000013001)],
        });
        expect(response.status).toBe(200);

        const lines = readChatLines(filePath);
        expect(lines).toHaveLength(9);
        for (let i = 0; i < 6; i++) {
            expect(lines[i + 1].cf_id).toBe(`EXIST${i}`);
            expect(lines[i + 1].mes).toBe(`message ${i}`);
        }
        expect(typeof lines[7].cf_id).toBe('string');
        expect(lines[7].cf_id).toHaveLength(26);
        expect(typeof lines[8].cf_id).toBe('string');
        expect(lines[8].cf_id).not.toBe(lines[7].cf_id);
    }, CASE_TIMEOUT_MS);

    test('append_never_rewrites_an_existing_messages_cf_id_or_content', async () => {
        const filePath = soloChatPath(server, 'CardKeep', 'chatKeep');
        writeChatFile(filePath, chatHeader('CardKeep'), buildMessages(5, i => ({ cf_id: `KEEP${i}` })));
        const beforeLines = readChatLines(filePath);

        const response = await client.postJson('/api/chats/append', {
            avatar_url: 'CardKeep.png', file_name: 'chatKeep',
            messages: [newMessage('added', true, 1700000014000)],
        });
        expect(response.status).toBe(200);

        const afterLines = readChatLines(filePath);
        for (let i = 0; i < beforeLines.length; i++) {
            expect(afterLines[i]).toEqual(beforeLines[i]);
        }
        expect(afterLines[6].mes).toBe('added');
    }, CASE_TIMEOUT_MS);
});

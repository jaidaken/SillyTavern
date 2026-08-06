// The mock server's prompt assembler.
//
// SillyTavern builds the prompt when the client sends none, so devserve.py has to as well or the gate
// would pass a client that never gets one. Long-lived and line-oriented (one request JSON per line in,
// one result JSON per line out) because the tokenizer is a model load: per-process it would be paid on
// every send, and the budget rows need the REAL counts, not an estimate.

import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, 'zig-out', 'bin', 'prompt_service.wasm');

async function main() {
    const { assemblePrompt } = await import(join(here, '..', 'src', 'prompt-builder.js'));
    const { SentencePieceProcessor } = await import('@agnai/sentencepiece-js');
    const sp = new SentencePieceProcessor();
    await sp.load(join(here, '..', 'src', 'tokenizers', 'llama.model'));
    // What the server's own counter does: encodeIds over CR-free text, no BOS, no cleaning.
    const countTokens = (text) => sp.encodeIds(String(text).replaceAll('\r', '')).length;

    process.stdout.write('READY\n');
    const lines = createInterface({ input: process.stdin });
    for await (const line of lines) {
        if (!line.trim()) continue;
        let answer;
        try {
            answer = await assemblePrompt(JSON.parse(line), { countTokens, wasmPath });
        } catch (error) {
            answer = { error: String(error?.message ?? error) };
        }
        process.stdout.write(JSON.stringify(answer) + '\n');
    }
}

main().catch((error) => {
    process.stderr.write(`assemble-for-mock: ${error?.stack ?? error}\n`);
    process.exit(1);
});

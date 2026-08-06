// The mock server's prompt assembler.
//
// devserve.py stands in for SillyTavern in the interaction gate, and SillyTavern now builds the prompt
// itself when the client sends none. A mock that skipped that step would let the gate pass a client
// that never gets a prompt at all, so it runs the SAME builder the real server runs: request JSON on
// stdin, the assembled result on stdout.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

async function main() {
    const request = JSON.parse(readFileSync(0, 'utf8'));
    const { assemblePrompt } = await import(join(here, '..', 'src', 'prompt-builder.js'));
    // Counting by estimate, not by model: the gate asserts what the prompt CONTAINS, and loading a
    // sentencepiece model per send would dominate its runtime for an answer no row looks at.
    const countTokens = (text) => Math.ceil(Buffer.byteLength(String(text), 'utf8') / 3.35);
    const built = await assemblePrompt(request, {
        countTokens,
        wasmPath: join(here, 'zig-out', 'bin', 'prompt_service.wasm'),
    });
    process.stdout.write(JSON.stringify(built));
}

main().catch((error) => {
    process.stdout.write(JSON.stringify({ error: String(error?.message ?? error) }));
    process.exitCode = 1;
});

import fs from 'node:fs/promises';

// Node's fetch (undici) rejects file:// URLs; Jimp's wasm codecs load their .wasm via fetch(new URL(..., import.meta.url)).
// Scoped to .wasm only: user-supplied URLs reaching global fetch (cors proxy, imports) must still fail closed on file://.
if (!globalThis.__stJimpFileFetchShimInstalled) {
    const originalFetch = globalThis.fetch.bind(globalThis);

    globalThis.fetch = async function fetchWithFileUrlSupport(input, init) {
        const url = input instanceof Request ? input.url : String(input);

        if (url.startsWith('file://') && new URL(url).pathname.endsWith('.wasm')) {
            const body = await fs.readFile(new URL(url));
            return new Response(body, {
                status: 200,
                headers: { 'content-type': 'application/wasm' },
            });
        }

        return originalFetch(input, init);
    };

    globalThis.__stJimpFileFetchShimInstalled = true;
}

import { describe, test, expect, jest, beforeEach } from '@jest/globals';

const fetchMock = jest.fn();
jest.unstable_mockModule('node-fetch', () => ({ default: fetchMock }));

const { applyBannedStrings } = await import('../src/banned-strings.js');

/** A backend whose vocabulary spells exactly `singles` as one token, and everything else as three. */
function backendSpelling(singles) {
    return async (_url, init) => {
        const { content } = JSON.parse(init.body);
        const id = 1000 + singles.indexOf(content);
        return { ok: true, json: async () => ({ tokens: singles.includes(content) ? [id] : [1, 2, 3] }) };
    };
}

describe('applyBannedStrings', () => {
    beforeEach(() => fetchMock.mockReset());

    test('a single-token banned string becomes a token ban', async () => {
        fetchMock.mockImplementation(backendSpelling(['delve']));
        const params = { banned_strings: ['delve'] };

        const result = await applyBannedStrings('http://backend-1', {}, params);

        expect(result).toEqual({ covered: 1, uncovered: 0 });
        expect(params.logit_bias).toEqual([[1000, false]]);
    });

    test('the space-prefixed spelling is banned too, since that is the mid-sentence token', async () => {
        fetchMock.mockImplementation(backendSpelling(['delve', ' delve']));
        const params = { banned_strings: ['delve'] };

        await applyBannedStrings('http://backend-2', {}, params);

        expect(params.logit_bias.map(([id]) => id).sort()).toEqual([1000, 1001]);
    });

    test('a multi-token phrase is left alone rather than banning its first word', async () => {
        fetchMock.mockImplementation(backendSpelling([]));
        const params = { banned_strings: ['a mix of fear and', 'shivers down'] };

        const result = await applyBannedStrings('http://backend-3', {}, params);

        expect(result).toEqual({ covered: 0, uncovered: 2 });
        expect(params.logit_bias).toEqual([]);
    });

    test('existing bans survive and no token is banned twice', async () => {
        fetchMock.mockImplementation(backendSpelling(['delve']));
        const params = { banned_strings: ['delve', 'delve'], logit_bias: [[2717, false]] };

        await applyBannedStrings('http://backend-4', {}, params);

        const ids = params.logit_bias.map(([id]) => id);
        expect(ids).toContain(2717);
        expect(new Set(ids).size).toBe(ids.length);
    });

    test('a backend that cannot tokenize costs the generation nothing', async () => {
        fetchMock.mockImplementation(async () => { throw new Error('backend down'); });
        const params = { banned_strings: ['delve'] };

        const result = await applyBannedStrings('http://backend-5', {}, params);

        expect(result).toEqual({ covered: 0, uncovered: 1 });
        expect(params.logit_bias).toEqual([]);
    });

    test('an empty list leaves the request untouched and asks the backend nothing', async () => {
        const params = { banned_strings: [] };

        expect(await applyBannedStrings('http://backend-6', {}, params)).toEqual({ covered: 0, uncovered: 0 });
        expect(fetchMock).not.toHaveBeenCalled();
        expect(params.logit_bias).toBeUndefined();
    });

    test('blank entries are skipped without a lookup', async () => {
        fetchMock.mockImplementation(backendSpelling([]));
        const params = { banned_strings: ['   ', ''] };

        expect(await applyBannedStrings('http://backend-7', {}, params)).toEqual({ covered: 0, uncovered: 2 });
        expect(fetchMock).not.toHaveBeenCalled();
    });

    test('a repeated string is looked up once and served from cache after', async () => {
        fetchMock.mockImplementation(backendSpelling(['cacophony']));
        await applyBannedStrings('http://cache-backend', {}, { banned_strings: ['cacophony'] });
        const callsAfterFirst = fetchMock.mock.calls.length;

        await applyBannedStrings('http://cache-backend', {}, { banned_strings: ['cacophony'] });

        expect(fetchMock.mock.calls.length).toBe(callsAfterFirst);
    });
});

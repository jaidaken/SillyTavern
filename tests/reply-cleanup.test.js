import { describe, test, expect } from '@jest/globals';
import { composeReply, trimToEndSentence } from '../src/reply-cleanup';

describe('trimToEndSentence', () => {
    test('keeps a reply that already ends on a sentence', () => {
        expect(trimToEndSentence('He turned. The lamp guttered.')).toBe('He turned. The lamp guttered.');
    });

    test('drops the trailing incomplete sentence', () => {
        expect(trimToEndSentence('He turned. The lamp gutt')).toBe('He turned.');
    });

    test('treats underscore as a sentence end, as the classic client does', () => {
        // The set is stock's (public/scripts/utils.js), and '_' is in it: the regression that first
        // surfaced this was a prompt bias whose marker ended mid-token at the underscore.
        expect(trimToEndSentence('ZPROMPTBIAS_76000021Z bias tailok')).toBe('ZPROMPTBIAS_');
    });

    test('returns the whole text trimmed when nothing ends a sentence', () => {
        expect(trimToEndSentence('no punctuation here   ')).toBe('no punctuation here');
    });

    test('swallows the space before a sentence end', () => {
        expect(trimToEndSentence('a word . more')).toBe('a word');
    });

    test('keeps an emoji as a sentence end', () => {
        expect(trimToEndSentence('all done 🎉 and then')).toBe('all done 🎉');
    });

    test('returns empty for empty input', () => {
        expect(trimToEndSentence('')).toBe('');
    });
});

describe('composeReply', () => {
    test('prepends the prompt bias the model continued from', () => {
        expect(composeReply({ prefix: 'Bias: ', text: 'the reply.', trimSpaces: false })).toBe('Bias: the reply.');
    });

    test('trims sentences across the bias boundary, not just the generated text', () => {
        expect(composeReply({ prefix: 'ZPROMPTBIAS_76000021Z bias tail', text: 'ok', trimSentences: true }))
            .toBe('ZPROMPTBIAS_');
    });

    test('leaves the text alone when trim_sentences is off', () => {
        expect(composeReply({ prefix: 'ZPROMPTBIAS_76000021Z bias tail', text: 'ok' }))
            .toBe('ZPROMPTBIAS_76000021Z bias tailok');
    });

    test('trims outer whitespace by default and keeps it when trim_spaces is off', () => {
        expect(composeReply({ text: '  padded  ' })).toBe('padded');
        expect(composeReply({ text: '  padded  ', trimSpaces: false })).toBe('  padded  ');
    });

    test('an empty generation with no bias composes to nothing', () => {
        expect(composeReply({})).toBe('');
    });

    test('never returns a longer string than the parts it was given', () => {
        const cases = ['', 'a', 'one. two. three', 'trailing_', '  spaced  ', 'emoji 🎉 tail'];
        for (const prefix of cases) {
            for (const text of cases) {
                for (const trimSentences of [false, true]) {
                    const out = composeReply({ prefix, text, trimSentences, trimSpaces: true });
                    expect(out.length).toBeLessThanOrEqual((prefix + text).length);
                }
            }
        }
    });
});

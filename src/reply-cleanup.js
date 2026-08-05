/**
 * Finished-reply cleanup, server side.
 *
 * The server owns the assistant turn now, so the tail of the classic client's cleanUpMessage
 * (public/script.js:6413) has to run here instead of in the browser: the bias belongs to the reply,
 * and the two trim settings decide what actually lands on disk. Kept to the settings that shape the
 * SAVED text; display-only steps stay in the client.
 */

// Ported from public/scripts/utils.js trimToEndSentence. The set is stock's, '_' included, and the
// classic client's own list carries the "extend this as you see fit" note.
const PUNCTUATION = new Set(['.', '!', '?', '*', '"', ')', '}', '`', ']', '$', '。', '！', '？', '”', '）', '】', '’', '」', '_']);
const EMOJI = /(\p{Emoji_Presentation}|\p{Extended_Pictographic})/u;

/**
 * Drops a trailing incomplete sentence: everything after the last sentence-ending character.
 * @param {string} input Text to trim.
 * @returns {string} The text up to and including the last sentence end.
 */
export function trimToEndSentence(input) {
    if (!input) {
        return '';
    }
    const characters = Array.from(input);
    let last = -1;
    for (let i = characters.length - 1; i >= 0; i--) {
        const char = characters[i];
        const emoji = EMOJI.test(char);
        if (PUNCTUATION.has(char) || emoji) {
            last = (!emoji && i > 0 && /[\s\n]/.test(characters[i - 1])) ? i - 1 : i;
            break;
        }
    }
    if (last === -1) {
        return input.trimEnd();
    }
    return characters.slice(0, last + 1).join('').trimEnd();
}

/**
 * The text of a finished reply as it is saved: the prompt bias the model continued from, then the
 * generated text, then the user's trim settings. One place, so the persisted turn and the final
 * frame the client adopts can never disagree.
 * @param {object} params Composition inputs.
 * @param {string} [params.prefix] Prompt bias the prompt ended with.
 * @param {string} [params.text] Generated text.
 * @param {boolean} [params.trimSentences] power_user.trim_sentences.
 * @param {boolean} [params.trimSpaces] power_user.trim_spaces.
 * @returns {string} The reply to save.
 */
export function composeReply({ prefix = '', text = '', trimSentences = false, trimSpaces = true } = {}) {
    let out = (prefix || '') + (text || '');
    if (trimSentences) {
        out = trimToEndSentence(out);
    }
    if (trimSpaces) {
        out = out.trim();
    }
    return out;
}

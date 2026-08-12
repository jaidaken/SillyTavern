/**
 * What auto-continue measures when deciding a reply is too short.
 *
 * The distinction that matters: a reasoning model spends most of a generation on the thought, so a
 * length test that counts the thought is satisfied by thinking alone and never continues a one-line
 * reply. The thought lives in extra.reasoning and the reply in mes, so measuring mes is correct today
 * by accident of storage. These functions make it correct on purpose, and testable.
 */

/**
 * The text a length target applies to: the reply, never the thought.
 * @param {object} message Chat message
 * @param {string} [message.mes] Reply text
 * @param {object} [message.extra] Message extras, which is where reasoning lives
 * @returns {string} Text to measure
 */
export function measuredReplyText(message) {
    return typeof message?.mes === 'string' ? message.mes : '';
}

/**
 * Whether a reply is short enough to continue.
 * @param {number} replyTokens Token count of the reply alone
 * @param {number} targetLength Configured target, zero or less disables the feature
 * @returns {boolean} True when the reply falls short of the target
 */
export function isBelowTargetLength(replyTokens, targetLength) {
    if (!Number.isFinite(targetLength) || targetLength <= 0) {
        return false;
    }

    return Number(replyTokens) < targetLength;
}

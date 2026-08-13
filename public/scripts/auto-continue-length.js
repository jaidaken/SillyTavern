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
 * Generation overrides that force a continue to produce text. A continue prompt ends where the model
 * chose its stop token and re-sampling re-picks it (measured: 1 token, empty, every trial); banning
 * the stop is the only measured escape that neither re-drafts the message nor opens a new thought
 * (3/3 next-beat). The model no longer ends the generation, the cap does.
 * @param {boolean} isContinue Whether this generation continues an existing message
 * @param {number?} maxTokens Response length configured for this generation
 * @param {number?} forceTokens Continue length setting, zero or less disables forcing
 * @returns {object} Parameter overrides, empty when not a forced continue
 */
export function continueForceParams(isContinue, maxTokens, forceTokens) {
    const force = Number(forceTokens) || 0;
    if (!isContinue || force <= 0) {
        return {};
    }

    const cap = Math.min(force, Number(maxTokens) > 0 ? Number(maxTokens) : force);
    return {
        'max_new_tokens': cap,
        'max_tokens': cap,
        'n_predict': cap,
        'num_predict': cap,
        'ignore_eos': true,
        'ban_eos_token': true,
    };
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

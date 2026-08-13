/**
 * Cue rewriting for reasoning models, as pure functions over explicit tag values.
 *
 * Kept free of imports on purpose: every other reasoning module reaches into power_user, the DOM and
 * script.js, which puts them out of reach of the unit suite. The rules encoded here are the ones that
 * decide whether a model thinks at all and whether its reply survives, so they are the part that has to
 * be testable without a browser or a running model.
 */

/** A bare opened block reads as already finished and gets closed unthought, so a seed is never empty. */
export const DEFAULT_SEED = 'What matters in this moment:';

/**
 * @typedef {object} ReasoningTags
 * @property {string} prefix Opening tag
 * @property {string} suffix Closing tag
 */

/**
 * Whether both tags are configured well enough to rewrite a cue at all.
 * @param {ReasoningTags} tags Reasoning tags
 * @returns {boolean} True when both tags carry content
 */
export function hasUsableTags(tags) {
    return Boolean(tags?.prefix?.trim() && tags?.suffix?.trim());
}

/**
 * Resolves the words a thought opens with.
 * @param {string} seed Configured seed, possibly blank
 * @returns {string} Seed text, never empty
 */
export function resolveSeed(seed) {
    return String(seed ?? '').trim() ? String(seed) : DEFAULT_SEED;
}

/**
 * The part of a text that sits inside a reasoning block still waiting to be closed.
 * @param {string} text Text to inspect, usually the assistant prefix of a prompt
 * @param {ReasoningTags} tags Reasoning tags
 * @returns {string?} The open block including its prefix, or null if nothing left one open
 */
export function openReasoningBlock(text, tags) {
    if (!hasUsableTags(tags)) {
        return null;
    }

    const opened = String(text).lastIndexOf(tags.prefix);
    if (opened < 0) {
        return null;
    }

    const block = String(text).slice(opened);
    return block.includes(tags.suffix) ? null : block;
}

/**
 * Rewrites an assistant cue so the model starts inside a thinking block that already has words in it.
 * @param {string} cue Assistant cue about to end the prompt
 * @param {ReasoningTags & { seed?: string }} options Reasoning tags plus the configured seed
 * @returns {string} The cue with a seeded thought block left open
 */
export function enableThinkingInCue(cue, options) {
    if (!hasUsableTags(options)) {
        return cue;
    }

    const { prefix, suffix } = options;
    const seed = resolveSeed(options.seed);
    const text = String(cue);

    const open = openReasoningBlock(text, options);
    if (open !== null) {
        return open.slice(prefix.length).trim() ? text : text + '\n' + seed;
    }

    const opened = text.lastIndexOf(prefix);
    if (opened >= 0 && text.endsWith(suffix)) {
        const inner = text.slice(opened + prefix.length, text.length - suffix.length);
        if (!inner.trim()) {
            return text.slice(0, text.length - suffix.length) + seed;
        }
    }

    return text + prefix + '\n' + seed;
}

/**
 * Rewrites an assistant cue to say "not thinking this turn", which these templates express as a thought
 * block opened and closed with nothing inside.
 * @param {string} cue Assistant cue about to end the prompt
 * @param {ReasoningTags} tags Reasoning tags
 * @returns {string} The cue with an empty closed block
 */
export function disableThinkingInCue(cue, tags) {
    if (!hasUsableTags(tags)) {
        return cue;
    }

    const { prefix, suffix } = tags;
    const text = String(cue);

    const openBlock = openReasoningBlock(text, tags);
    if (openBlock === null) {
        return text.includes(prefix) ? text : text + prefix + '\n' + suffix;
    }

    const spacing = openBlock.slice(prefix.length).match(/^\s*/)[0] || '\n';
    return text.slice(0, text.length - openBlock.length) + prefix + spacing + suffix;
}

/**
 * The opening tag a reply will be missing because the prompt already supplied it, or null when the
 * reply must be read as written. Getting a non-null answer wrong is expensive in one direction: claim a
 * tag the prompt never opened and the parser reads the entire reply as a thought.
 * @param {string} promptTail Text appended to the prompt as the assistant prefix
 * @param {ReasoningTags & { autoParse?: boolean, alreadyCarrying?: boolean }} options Tags and state
 * @returns {string?} The tag to prepend before parsing, or null
 */
export function prefixCarriedByCue(promptTail, options) {
    if (options?.autoParse === false || options?.alreadyCarrying) {
        return null;
    }

    return openReasoningBlock(promptTail, options) === null ? null : options.prefix;
}

/**
 * Joins the thought a message already had with the one its continuation produced. Losing the first
 * thought would silently discard what the user watched the model write minutes earlier.
 * @param {string} base Thought recorded before the continue
 * @param {string} addition Thought the continuation produced
 * @returns {string} Both thoughts, or whichever exists
 */
export function joinContinuedReasoning(base, addition) {
    const a = String(base ?? '');
    const b = String(addition ?? '');
    if (!a.trim() || !b.trim()) {
        return b.trim() ? b : a;
    }

    return `${a}\n\n${b}`;
}

/**
 * Whether a generation is the assistant's own turn, and so the one whose cue may carry a thought.
 * An impersonation writes as the user, and a quiet prompt is a utility call whose budget should go to
 * the answer rather than to a thought nobody reads.
 * @param {object} kind Generation kind
 * @param {boolean} [kind.isImpersonate] Writing as the user
 * @param {boolean} [kind.isQuiet] Utility generation
 * @param {boolean} [kind.isQuietToLoud] Quiet generation spoken in character
 * @returns {boolean} True when the cue belongs to the character's own reply
 */
export function isThinkingTurn({ isImpersonate = false, isQuiet = false, isQuietToLoud = false } = {}) {
    if (isImpersonate) {
        return false;
    }

    return !isQuiet || isQuietToLoud;
}

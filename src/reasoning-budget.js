/**
 * Reasoning budget for text completion.
 *
 * llama.cpp bounds thinking on its chat endpoint (`--reasoning-budget N`): it counts the tokens
 * generated inside the thought block and writes the closing tag itself once the budget is spent, so
 * the model has no choice but to continue outside the block. The text-completion endpoint never
 * parses the text, so nothing bounds it there and a model that loops on redrafting inside its
 * thought block never emits a reply at all.
 *
 * This reproduces the same behaviour in the proxy: count the thinking as it streams, and at the
 * budget stop the generation and resume it with the closing tag appended to the prompt. The client
 * sees one continuous stream, so both the browser UI and any other frontend get the same result.
 */

import { log } from './log.js';

/**
 * @typedef {object} ReasoningBudget
 * @property {number} budget Token budget for thinking. Zero or less disables the feature.
 * @property {string} prefix Opening tag of the thought block.
 * @property {string} suffix Closing tag of the thought block.
 * @property {string} message Text written before the closing tag when the budget runs out.
 */

/** Request keys consumed here; they are ours, not the backend's, so they never reach upstream. */
const REQUEST_KEYS = ['reasoning_budget', 'reasoning_prefix', 'reasoning_suffix', 'reasoning_budget_message'];

/**
 * Reads the budget settings out of a generation request and removes them from it.
 * @param {any} params Generation parameters, mutated to drop the budget keys.
 * @returns {ReasoningBudget|null} Settings, or null when the feature is off or unusable.
 */
export function takeReasoningBudget(params) {
    const budget = Number(params?.reasoning_budget) || 0;
    const prefix = String(params?.reasoning_prefix ?? '');
    const suffix = String(params?.reasoning_suffix ?? '');
    const message = String(params?.reasoning_budget_message ?? '');

    for (const key of REQUEST_KEYS) {
        delete params?.[key];
    }

    if (budget <= 0 || !prefix.trim() || !suffix.trim()) {
        return null;
    }

    return { budget, prefix, suffix, message };
}

/**
 * Whether a thought block is open at the end of the text: opened by the last prefix, with no suffix
 * closing it. The prompt itself can open one, because a chat template's generation prompt puts the
 * opening tag there rather than making the model produce it.
 * @param {string} text Text to inspect.
 * @param {string} prefix Opening tag.
 * @param {string} suffix Closing tag.
 * @returns {boolean} True when thinking is in progress.
 */
export function isReasoningOpen(text, prefix, suffix) {
    const opened = String(text ?? '').lastIndexOf(prefix);
    if (opened < 0) {
        return false;
    }

    return !String(text).slice(opened).includes(suffix);
}

/**
 * Pulls the generated text out of one streamed payload, across the shapes the text-completion
 * backends emit: llama.cpp `content`, OpenAI completions `choices[].text`, chat deltas.
 * @param {any} data Parsed payload.
 * @returns {string} Generated text, empty when the payload carried none.
 */
export function payloadText(data) {
    if (typeof data?.content === 'string') {
        return data.content;
    }

    const choice = Array.isArray(data?.choices) ? data.choices[0] : null;
    if (typeof choice?.text === 'string') {
        return choice.text;
    }
    if (typeof choice?.delta?.content === 'string') {
        return choice.delta.content;
    }

    return '';
}

/**
 * Builds a payload carrying text, in the same shape as the ones already sent, so the client parses
 * the injected closing tag exactly as it would a generated one.
 * @param {string} text Text to carry.
 * @param {boolean} llamaShape Whether the stream uses llama.cpp's `content` shape.
 * @returns {string} A `data:` line, newlines included.
 */
export function buildPayload(text, llamaShape) {
    const data = llamaShape
        ? { content: text, stop: false }
        : { choices: [{ text, index: 0, finish_reason: null }] };

    return `data: ${JSON.stringify(data)}\n\n`;
}

/**
 * Tracks thinking across a stream and decides when the budget is spent.
 */
export class ReasoningBudgetTracker {
    /**
     * @param {ReasoningBudget} settings Budget settings.
     * @param {string} prompt Prompt the generation started from.
     */
    constructor(settings, prompt) {
        this.settings = settings;
        this.generated = '';
        this.thinkingTokens = 0;
        this.llamaShape = false;
        // The prompt can carry an unclosed block, which is where a seeded thought channel starts.
        this.openInPrompt = isReasoningOpen(prompt, settings.prefix, settings.suffix);
    }

    /**
     * Accounts for one streamed payload.
     * @param {any} data Parsed payload.
     * @returns {void}
     */
    accept(data) {
        if (typeof data?.content === 'string') {
            this.llamaShape = true;
        }

        const text = payloadText(data);
        if (!text) {
            return;
        }

        const wasOpen = this.isOpen();
        this.generated += text;
        // Counted per payload rather than from `tokens_predicted`, which not every backend sends,
        // and which counts the whole generation rather than the part inside the block.
        if (wasOpen) {
            this.thinkingTokens++;
        }
    }

    /**
     * @returns {boolean} Whether a thought block is currently open.
     */
    isOpen() {
        const { prefix, suffix } = this.settings;
        if (isReasoningOpen(this.generated, prefix, suffix)) {
            return true;
        }

        // A block opened by the prompt stays open until the generation closes it.
        return this.openInPrompt && !this.generated.includes(suffix);
    }

    /**
     * @returns {boolean} Whether thinking has run past its budget and must be cut off.
     */
    isExhausted() {
        return this.isOpen() && this.thinkingTokens >= this.settings.budget;
    }

    /**
     * The text that closes the block: the operator's message, then the closing tag.
     * @returns {string} Text to inject into the stream and append to the prompt.
     */
    closingText() {
        return `${this.settings.message}${this.settings.suffix}`;
    }

    /**
     * Parameters for the generation that resumes outside the thought block, continuing from
     * everything produced so far.
     * @param {any} params Original generation parameters.
     * @returns {any} Parameters for the continuation.
     */
    continuationParams(params) {
        const next = { ...params, prompt: `${params.prompt}${this.generated}${this.closingText()}` };

        // Whatever the budget consumed is no longer available to the reply.
        for (const key of ['max_tokens', 'max_new_tokens', 'n_predict', 'num_predict']) {
            if (typeof next[key] === 'number' && next[key] > 0) {
                next[key] = Math.max(16, next[key] - this.thinkingTokens);
            }
        }

        log.gen.info(`[ReasoningBudget] thinking cut off at ${this.thinkingTokens} tokens, resuming for the reply`);
        return next;
    }
}

/**
 * Splitting a streamed generation into reasoning and reply, as a pure state machine.
 *
 * Same reason as reasoning-cue.js: the streaming path lives on a class that reaches into chat state, the
 * DOM and power_user, so the only way to exercise it was a live model. The rules are small and the cost
 * of getting them wrong is a lost reply, so they belong somewhere a test can drive them directly.
 */

/**
 * @typedef {object} SplitResult
 * @property {string} reasoning Text belonging to the thought
 * @property {string} content Text belonging to the reply
 * @property {boolean} parsing Whether the thought is still open
 */

export class ReasoningSplitter {
    /** @type {string} */ #prefix;
    /** @type {string} */ #suffix;
    /** @type {string} */ #carry;
    /** @type {boolean} */ #trim;

    /** Whether everything arriving now belongs to the thought. */
    #parsing = false;

    /** Where the reply starts inside the parse target, once the closing tag has been seen. */
    #contentStart = null;

    /**
     * @param {object} options Splitter options
     * @param {string} options.prefix Opening tag
     * @param {string} options.suffix Closing tag
     * @param {string} [options.carry] Opening tag the prompt supplied, absent from the model's output
     * @param {boolean} [options.trim] Whether to trim surrounding whitespace, as power_user.trim_spaces does
     */
    constructor({ prefix, suffix, carry = '', trim = false }) {
        this.#prefix = prefix;
        this.#suffix = suffix;
        this.#carry = carry;
        this.#trim = trim;
    }

    /** @returns {boolean} Whether a thought is currently open */
    get parsing() {
        return this.#parsing;
    }

    /** @returns {boolean} Whether the closing tag has been seen */
    get closed() {
        return this.#contentStart !== null;
    }

    /**
     * @param {string} text Text to trim
     * @returns {string} Trimmed text when trimming is enabled
     */
    #trimmed(text) {
        return this.#trim ? text.trim() : text;
    }

    /**
     * Splits everything streamed so far. Call with the full accumulated text, not a single chunk.
     * @param {string} streamed Everything the model has emitted this turn
     * @returns {SplitResult} The split as it stands
     */
    update(streamed) {
        if (!this.#prefix || !this.#suffix) {
            return { reasoning: '', content: streamed, parsing: false };
        }

        const target = this.#carry + streamed;

        if (this.#contentStart !== null) {
            return {
                reasoning: this.#reasoningBefore(target),
                content: this.#trimmed(target.slice(this.#contentStart)),
                parsing: false,
            };
        }

        if (!this.#parsing && target.startsWith(this.#prefix) && target.length > this.#prefix.length) {
            this.#parsing = true;
        }

        if (!this.#parsing) {
            return { reasoning: '', content: streamed, parsing: false };
        }

        const inside = target.slice(this.#prefix.length);
        const end = inside.indexOf(this.#suffix);
        if (end < 0) {
            return { reasoning: inside, content: '', parsing: true };
        }

        this.#contentStart = target.indexOf(this.#suffix) + this.#suffix.length;
        this.#parsing = false;
        return {
            reasoning: inside.slice(0, end),
            content: this.#trimmed(target.slice(this.#contentStart)),
            parsing: false,
        };
    }

    /**
     * @param {string} target Full parse target
     * @returns {string} The thought recorded before the closing tag
     */
    #reasoningBefore(target) {
        const inside = target.slice(this.#prefix.length);
        const end = inside.indexOf(this.#suffix);
        return end < 0 ? inside : inside.slice(0, end);
    }

    /**
     * Settles the split once the model has stopped. A thought the model never closed is NOT a thought:
     * the non-streaming parser requires both tags and leaves such a generation as reply text, so a
     * stream that swallowed the whole reply into the thinking box disagrees with the same generation
     * fetched without streaming. The reply is the part the user cannot afford to lose, so it wins.
     * @param {string} streamed Everything the model emitted this turn
     * @returns {SplitResult} The final split
     */
    finalize(streamed) {
        const result = this.update(streamed);
        if (!result.parsing) {
            return result;
        }

        this.#parsing = false;
        return { reasoning: '', content: this.#trimmed(streamed), parsing: false };
    }
}

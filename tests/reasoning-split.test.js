// @ts-check
import { describe, expect, it } from '@jest/globals';

import { ReasoningSplitter } from '../public/scripts/reasoning-split.js';

const PREFIX = '<|channel>thought';
const SUFFIX = '<channel|>';

/** @type {(over?: object) => ReasoningSplitter} */
const splitter = (over = {}) => new ReasoningSplitter({ prefix: PREFIX, suffix: SUFFIX, ...over });

/**
 * Feeds a generation one character at a time, the way a stream arrives.
 * @param {ReasoningSplitter} s Splitter under test
 * @param {string} full Whole generation
 * @returns {import('../public/scripts/reasoning-split.js').SplitResult} Result after the last chunk
 */
function stream(s, full) {
    let last = { reasoning: '', content: '', parsing: false };
    for (let i = 1; i <= full.length; i++) {
        last = s.update(full.slice(0, i));
    }
    return last;
}

describe('ReasoningSplitter with the tag in the model output', () => {
    it('splits_a_closed_thought_from_the_reply', () => {
        const out = stream(splitter(), `${PREFIX}\nthinking${SUFFIX}the reply`);
        expect(out.reasoning).toBe('\nthinking');
        expect(out.content).toBe('the reply');
        expect(out.parsing).toBe(false);
    });

    it('holds_the_reply_empty_while_the_thought_is_still_open', () => {
        const out = stream(splitter(), `${PREFIX}\nstill going`);
        expect(out.content).toBe('');
        expect(out.parsing).toBe(true);
    });

    it('treats_a_generation_with_no_thought_as_all_reply', () => {
        const out = stream(splitter(), 'just a reply, no thinking');
        expect(out.reasoning).toBe('');
        expect(out.content).toBe('just a reply, no thinking');
    });

    it('keeps_a_suffix_that_appears_later_in_the_reply_out_of_the_thought', () => {
        const out = stream(splitter(), `${PREFIX}\nthink${SUFFIX}reply ${SUFFIX} stray`);
        expect(out.reasoning).toBe('\nthink');
        expect(out.content).toBe(`reply ${SUFFIX} stray`);
    });

    it('splits_correctly_on_the_tick_the_closing_tag_completes', () => {
        const out = splitter().update(`${PREFIX}\nthink${SUFFIX}reply`);
        expect(out.reasoning).toBe('\nthink');
        expect(out.content).toBe('reply');
    });

    it('does_not_start_parsing_on_a_prefix_with_nothing_after_it_yet', () => {
        const s = splitter();
        const out = s.update(PREFIX);
        expect(s.parsing).toBe(false);
        expect(out.content).toBe(PREFIX);
    });

    it('survives_a_tag_split_across_chunk_boundaries', () => {
        const s = splitter();
        s.update('<|chan');
        s.update(`${PREFIX}\nhm`);
        const out = s.update(`${PREFIX}\nhm<chan`);
        expect(out.parsing).toBe(true);
        expect(s.update(`${PREFIX}\nhm${SUFFIX}hi`).content).toBe('hi');
    });
});

describe('ReasoningSplitter with the tag carried from the prompt', () => {
    it('splits_when_the_model_emits_only_the_closing_tag', () => {
        const out = stream(splitter({ carry: PREFIX }), `\nthinking${SUFFIX}the reply`);
        expect(out.reasoning).toBe('\nthinking');
        expect(out.content).toBe('the reply');
    });

    it('does_not_lose_the_reply_when_the_carried_thought_is_never_closed', () => {
        const s = splitter({ carry: PREFIX });
        const streamed = 'she thinks, then just talks with no closing tag';
        expect(stream(s, streamed).content).toBe('');
        const settled = s.finalize(streamed);
        expect(settled.content).toBe(streamed);
        expect(settled.reasoning).toBe('');
    });
});

describe('finalize', () => {
    it('leaves_a_properly_closed_split_alone', () => {
        const s = splitter();
        const full = `${PREFIX}\nthink${SUFFIX}reply`;
        stream(s, full);
        const settled = s.finalize(full);
        expect(settled.reasoning).toBe('\nthink');
        expect(settled.content).toBe('reply');
    });

    it('recovers_the_reply_from_a_thought_the_model_never_closed', () => {
        const s = splitter();
        const full = `${PREFIX}\nGale considers it, then answers out loud without ever closing`;
        expect(stream(s, full).content).toBe('');
        expect(s.finalize(full).content).toBe(full);
    });

    it('never_ends_a_generation_with_both_an_empty_reply_and_a_non_empty_thought', () => {
        for (const full of [
            `${PREFIX}\nunclosed thought`,
            `${PREFIX}\nthink${SUFFIX}reply`,
            'no tags at all',
            `${PREFIX}\n`,
        ]) {
            const s = splitter();
            stream(s, full);
            const settled = s.finalize(full);
            expect(settled.content === '' && settled.reasoning !== '').toBe(false);
        }
    });

    it('agrees_with_the_non_streaming_parser_which_needs_both_tags', () => {
        const full = `${PREFIX}\nunclosed`;
        const s = splitter();
        stream(s, full);
        expect(s.finalize(full).content).toBe(full);
    });
});

describe('trim behaviour', () => {
    it('trims_the_reply_when_trimming_is_enabled', () => {
        const out = stream(splitter({ trim: true }), `${PREFIX}\nthink${SUFFIX}\n  reply  `);
        expect(out.content).toBe('reply');
    });

    it('keeps_surrounding_space_when_trimming_is_disabled', () => {
        const out = stream(splitter({ trim: false }), `${PREFIX}\nthink${SUFFIX}  reply  `);
        expect(out.content).toBe('  reply  ');
    });
});

describe('unconfigured tags', () => {
    it('passes_everything_through_as_reply', () => {
        const s = new ReasoningSplitter({ prefix: '', suffix: '' });
        const out = s.update(`${PREFIX}\nthink${SUFFIX}reply`);
        expect(out.content).toBe(`${PREFIX}\nthink${SUFFIX}reply`);
        expect(out.reasoning).toBe('');
    });

    it('passes_through_when_only_the_closing_tag_is_missing', () => {
        const s = new ReasoningSplitter({ prefix: PREFIX, suffix: '' });
        const out = s.update(`${PREFIX}\nthink${SUFFIX}reply`);
        expect(out.reasoning).toBe('');
        expect(out.content).toBe(`${PREFIX}\nthink${SUFFIX}reply`);
        expect(out.parsing).toBe(false);
    });
});

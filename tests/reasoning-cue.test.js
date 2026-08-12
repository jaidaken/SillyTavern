// @ts-check
import { describe, expect, it } from '@jest/globals';

import {
    DEFAULT_SEED,
    disableThinkingInCue,
    enableThinkingInCue,
    isThinkingTurn,
    openReasoningBlock,
    prefixCarriedByCue,
    resolveSeed,
} from '../public/scripts/reasoning-cue.js';

/** Gemma 4's channel tags, the pair this was built against. */
const TAGS = { prefix: '<|channel>thought', suffix: '<channel|>' };
const SEED = 'What matters to Gale in this moment:';
const OPTS = { ...TAGS, seed: SEED };

/** The cue an instruct template produces before any reasoning rewrite. */
const TURN = '<|turn>model\n';

/** @type {(text: string, needle: string) => number} */
const countOf = (text, needle) => text.split(needle).length - 1;

describe('openReasoningBlock', () => {
    it('returns_null_when_no_block_was_opened', () => {
        expect(openReasoningBlock(TURN, TAGS)).toBeNull();
    });

    it('returns_null_for_a_block_that_was_closed_again', () => {
        expect(openReasoningBlock(`${TURN}${TAGS.prefix}\nhm${TAGS.suffix}`, TAGS)).toBeNull();
    });

    it('returns_the_open_block_including_its_prefix', () => {
        expect(openReasoningBlock(`${TURN}${TAGS.prefix}\nhm`, TAGS)).toBe(`${TAGS.prefix}\nhm`);
    });

    it('reports_the_last_block_not_an_earlier_closed_one', () => {
        const text = `${TAGS.prefix}\nold${TAGS.suffix} reply ${TAGS.prefix}\nnew`;
        expect(openReasoningBlock(text, TAGS)).toBe(`${TAGS.prefix}\nnew`);
    });

    it('returns_null_when_either_tag_is_unconfigured', () => {
        expect(openReasoningBlock(`${TURN}${TAGS.prefix}`, { prefix: '', suffix: TAGS.suffix })).toBeNull();
        expect(openReasoningBlock(`${TURN}${TAGS.prefix}`, { prefix: TAGS.prefix, suffix: '   ' })).toBeNull();
    });
});

describe('resolveSeed', () => {
    it('falls_back_to_the_default_for_blank_input', () => {
        expect(resolveSeed('')).toBe(DEFAULT_SEED);
        expect(resolveSeed('   ')).toBe(DEFAULT_SEED);
        expect(resolveSeed(undefined)).toBe(DEFAULT_SEED);
    });

    it('keeps_a_configured_seed_verbatim', () => {
        expect(resolveSeed(SEED)).toBe(SEED);
    });

    it('never_resolves_to_something_a_model_reads_as_an_empty_block', () => {
        expect(resolveSeed('').trim()).not.toBe('');
    });
});

describe('enableThinkingInCue', () => {
    it('opens_and_seeds_a_plain_cue', () => {
        expect(enableThinkingInCue(TURN, OPTS)).toBe(`${TURN}${TAGS.prefix}\n${SEED}`);
    });

    it('leaves_the_block_open_because_a_closed_one_means_not_thinking', () => {
        expect(enableThinkingInCue(TURN, OPTS)).not.toContain(TAGS.suffix);
    });

    it('puts_words_inside_the_block_because_a_bare_opener_is_closed_unthought', () => {
        const out = enableThinkingInCue(TURN, OPTS);
        const inside = out.slice(out.lastIndexOf(TAGS.prefix) + TAGS.prefix.length);
        expect(inside.trim()).not.toBe('');
    });

    it('seeds_a_block_the_template_opened_but_left_empty', () => {
        expect(enableThinkingInCue(`${TURN}${TAGS.prefix}`, OPTS)).toBe(`${TURN}${TAGS.prefix}\n${SEED}`);
    });

    it('reopens_the_empty_closed_block_a_thinking_off_template_emits', () => {
        const off = `${TURN}${TAGS.prefix}\n${TAGS.suffix}`;
        const out = enableThinkingInCue(off, OPTS);
        expect(out).toBe(`${TURN}${TAGS.prefix}\n${SEED}`);
        expect(out).not.toContain(TAGS.suffix);
    });

    it('is_idempotent_and_never_stacks_a_second_block_or_seed', () => {
        const once = enableThinkingInCue(TURN, OPTS);
        const twice = enableThinkingInCue(once, OPTS);
        expect(twice).toBe(once);
        expect(countOf(twice, TAGS.prefix)).toBe(1);
        expect(countOf(twice, SEED)).toBe(1);
    });

    it('leaves_a_cue_alone_when_the_tags_are_not_configured', () => {
        expect(enableThinkingInCue(TURN, { prefix: '', suffix: '', seed: SEED })).toBe(TURN);
    });

    it('falls_back_to_the_default_seed_rather_than_opening_an_empty_block', () => {
        expect(enableThinkingInCue(TURN, { ...TAGS, seed: '  ' })).toBe(`${TURN}${TAGS.prefix}\n${DEFAULT_SEED}`);
    });

    it('keeps_history_above_the_cue_untouched', () => {
        const history = `<|turn>user\nhi<turn|>\n${TAGS.prefix}\nearlier${TAGS.suffix}reply<turn|>\n`;
        const out = enableThinkingInCue(history + TURN, OPTS);
        expect(out.startsWith(history)).toBe(true);
        expect(countOf(out, TAGS.suffix)).toBe(1);
    });
});

describe('disableThinkingInCue', () => {
    it('appends_the_empty_closed_block_that_means_not_thinking', () => {
        expect(disableThinkingInCue(TURN, TAGS)).toBe(`${TURN}${TAGS.prefix}\n${TAGS.suffix}`);
    });

    it('closes_and_empties_a_block_the_cue_left_open', () => {
        const open = `${TURN}${TAGS.prefix}\n${SEED}`;
        const out = disableThinkingInCue(open, TAGS);
        expect(out).toBe(`${TURN}${TAGS.prefix}\n${TAGS.suffix}`);
        expect(out).not.toContain(SEED);
    });

    it('is_idempotent', () => {
        const once = disableThinkingInCue(TURN, TAGS);
        expect(disableThinkingInCue(once, TAGS)).toBe(once);
    });

    it('undoes_an_enable_exactly', () => {
        expect(disableThinkingInCue(enableThinkingInCue(TURN, OPTS), TAGS)).toBe(disableThinkingInCue(TURN, TAGS));
    });

    it('leaves_a_cue_alone_when_the_tags_are_not_configured', () => {
        expect(disableThinkingInCue(TURN, { prefix: TAGS.prefix, suffix: '' })).toBe(TURN);
    });

    it('never_emits_a_closing_tag_with_no_opening_tag_before_it', () => {
        const out = disableThinkingInCue(TURN, TAGS);
        expect(out.indexOf(TAGS.prefix)).toBeLessThan(out.indexOf(TAGS.suffix));
    });
});

describe('prefixCarriedByCue', () => {
    it('carries_the_tag_when_the_cue_left_a_thought_open', () => {
        expect(prefixCarriedByCue(`${TURN}${TAGS.prefix}\n${SEED}`, OPTS)).toBe(TAGS.prefix);
    });

    it('carries_nothing_when_the_cue_never_opened_a_thought', () => {
        expect(prefixCarriedByCue(TURN, OPTS)).toBeNull();
    });

    it('carries_nothing_when_the_cue_closed_the_block_for_thinking_off', () => {
        expect(prefixCarriedByCue(`${TURN}${TAGS.prefix}\n${TAGS.suffix}`, OPTS)).toBeNull();
    });

    it('carries_nothing_when_a_tag_is_already_being_carried', () => {
        expect(prefixCarriedByCue(`${TURN}${TAGS.prefix}\n${SEED}`, { ...OPTS, alreadyCarrying: true })).toBeNull();
    });

    it('carries_nothing_when_auto_parse_is_off', () => {
        expect(prefixCarriedByCue(`${TURN}${TAGS.prefix}\n${SEED}`, { ...OPTS, autoParse: false })).toBeNull();
    });

    it('never_claims_a_tag_for_a_cue_that_disableThinkingInCue_produced', () => {
        expect(prefixCarriedByCue(disableThinkingInCue(TURN, TAGS), OPTS)).toBeNull();
    });

    it('always_claims_the_tag_for_a_cue_that_enableThinkingInCue_produced', () => {
        expect(prefixCarriedByCue(enableThinkingInCue(TURN, OPTS), OPTS)).toBe(TAGS.prefix);
    });
});

describe('isThinkingTurn', () => {
    it('is_true_for_the_characters_own_reply', () => {
        expect(isThinkingTurn({})).toBe(true);
    });

    it('is_false_for_an_impersonation_which_writes_as_the_user', () => {
        expect(isThinkingTurn({ isImpersonate: true })).toBe(false);
    });

    it('is_false_for_a_quiet_utility_generation', () => {
        expect(isThinkingTurn({ isQuiet: true })).toBe(false);
    });

    it('is_true_for_a_quiet_generation_spoken_in_character', () => {
        expect(isThinkingTurn({ isQuiet: true, isQuietToLoud: true })).toBe(true);
    });

    it('treats_impersonation_as_decisive_over_everything_else', () => {
        expect(isThinkingTurn({ isImpersonate: true, isQuiet: true, isQuietToLoud: true })).toBe(false);
    });
});

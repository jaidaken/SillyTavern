// @ts-check
import { describe, expect, it } from '@jest/globals';

import { continueForceParams, isBelowTargetLength, measuredReplyText, trimForcedContinueTail } from '../public/scripts/auto-continue-length.js';
import { ReasoningSplitter } from '../public/scripts/reasoning-split.js';

const PREFIX = '<|channel>thought';
const SUFFIX = '<channel|>';

describe('measuredReplyText', () => {
    it('measures_the_reply', () => {
        expect(measuredReplyText({ mes: 'she answers' })).toBe('she answers');
    });

    it('never_measures_the_thought', () => {
        const thought = 'a very long deliberation that would satisfy any target on its own';
        const message = { mes: 'no.', extra: { reasoning: thought } };
        expect(measuredReplyText(message)).toBe('no.');
        expect(measuredReplyText(message)).not.toContain(thought);
    });

    it('returns_empty_for_a_message_with_no_reply_yet', () => {
        expect(measuredReplyText({ extra: { reasoning: 'thinking' } })).toBe('');
        expect(measuredReplyText(undefined)).toBe('');
    });
});

describe('isBelowTargetLength', () => {
    it('continues_a_reply_under_the_target', () => {
        expect(isBelowTargetLength(40, 200)).toBe(true);
    });

    it('leaves_a_reply_at_the_target_alone', () => {
        expect(isBelowTargetLength(200, 200)).toBe(false);
    });

    it('leaves_a_reply_over_the_target_alone', () => {
        expect(isBelowTargetLength(500, 200)).toBe(false);
    });

    it('is_disabled_by_a_target_of_zero', () => {
        expect(isBelowTargetLength(0, 0)).toBe(false);
    });

    it('is_disabled_by_a_negative_target', () => {
        expect(isBelowTargetLength(5, -10)).toBe(false);
    });

    it('is_disabled_by_a_missing_target', () => {
        expect(isBelowTargetLength(5, NaN)).toBe(false);
        expect(isBelowTargetLength(5, undefined)).toBe(false);
    });
});

describe('the length target against a real split generation', () => {
    /**
     * @param {string} generated Whole generation
     * @returns {{ mes: string, extra: { reasoning: string } }} Message as the handler would store it
     */
    function splitToMessage(generated) {
        const s = new ReasoningSplitter({ prefix: PREFIX, suffix: SUFFIX });
        s.update(generated);
        const out = s.finalize(generated);
        return { mes: out.content, extra: { reasoning: out.reasoning } };
    }

    it('a_long_thought_with_a_short_reply_still_counts_as_short', () => {
        const thought = 'x'.repeat(4000);
        const message = splitToMessage(`${PREFIX}\n${thought}${SUFFIX}Yes.`);
        expect(measuredReplyText(message)).toBe('Yes.');
        expect(isBelowTargetLength(measuredReplyText(message).length, 200)).toBe(true);
    });

    it('a_long_reply_is_not_continued_however_short_the_thought', () => {
        const reply = 'y'.repeat(900);
        const message = splitToMessage(`${PREFIX}\nbrief${SUFFIX}${reply}`);
        expect(isBelowTargetLength(measuredReplyText(message).length, 200)).toBe(false);
    });

    it('a_thought_the_model_never_closed_is_measured_as_reply_not_as_thought', () => {
        const generated = `${PREFIX}\n${'z'.repeat(900)}`;
        const message = splitToMessage(generated);
        expect(message.extra.reasoning).toBe('');
        expect(isBelowTargetLength(measuredReplyText(message).length, 200)).toBe(false);
    });
});

describe('continueForceParams', () => {
    it('bans_the_stop_token_and_caps_the_generation_on_continue', () => {
        const p = continueForceParams(true, 2048, 200);
        expect(p.ignore_eos).toBe(true);
        expect(p.ban_eos_token).toBe(true);
        expect(p.n_predict).toBe(200);
        expect(p.max_new_tokens).toBe(200);
    });

    it('never_exceeds_the_response_length', () => {
        expect(continueForceParams(true, 150, 200).n_predict).toBe(150);
    });

    it('does_nothing_for_a_normal_generation', () => {
        expect(continueForceParams(false, 2048, 200)).toEqual({});
    });

    it('is_disabled_by_a_zero_or_missing_setting', () => {
        expect(continueForceParams(true, 2048, 0)).toEqual({});
        expect(continueForceParams(true, 2048, undefined)).toEqual({});
    });

    it('uses_its_own_cap_when_no_response_length_is_configured', () => {
        expect(continueForceParams(true, null, 200).n_predict).toBe(200);
    });
});

describe('trimForcedContinueTail', () => {
    it('strips_the_underscore_lines_a_forced_continue_pads_with', () => {
        const text = 'She waves over her shoulder. "Peace out!"_\n_\n_\n_\n_';
        expect(trimForcedContinueTail(text)).toBe('She waves over her shoulder. "Peace out!"');
    });

    it('strips_multiline_padding_of_mixed_punctuation', () => {
        expect(trimForcedContinueTail('A real sentence.\n---\n***\n...\n')).toBe('A real sentence.');
    });

    it('leaves_a_normal_ending_alone', () => {
        expect(trimForcedContinueTail('*She hops off the bus.* "See ya!"')).toBe('*She hops off the bus.* "See ya!"');
    });

    it('keeps_junk_looking_lines_in_the_middle_of_the_text', () => {
        const text = 'First beat.\n---\nSecond beat.';
        expect(trimForcedContinueTail(text)).toBe(text);
    });

    it('returns_empty_for_pure_padding', () => {
        expect(trimForcedContinueTail('_\n_\n---\n')).toBe('');
    });
});

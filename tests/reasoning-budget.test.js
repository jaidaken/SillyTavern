import { describe, test, expect } from '@jest/globals';
import { takeReasoningBudget, isReasoningOpen, payloadText, buildPayload, ReasoningBudgetTracker } from '../src/reasoning-budget';

const PREFIX = '<|channel>thought';
const SUFFIX = '<channel|>';
const settings = { budget: 3, prefix: PREFIX, suffix: SUFFIX, message: '' };

describe('takeReasoningBudget', () => {
    test('reads the settings and strips them from the upstream body', () => {
        const params = { prompt: 'x', reasoning_budget: 756, reasoning_prefix: PREFIX, reasoning_suffix: SUFFIX, reasoning_budget_message: 'enough' };
        const budget = takeReasoningBudget(params);

        expect(budget).toEqual({ budget: 756, prefix: PREFIX, suffix: SUFFIX, message: 'enough' });
        expect(params).toEqual({ prompt: 'x' });
    });

    test('is off without a budget, and off without both tags', () => {
        expect(takeReasoningBudget({ reasoning_budget: 0, reasoning_prefix: PREFIX, reasoning_suffix: SUFFIX })).toBeNull();
        expect(takeReasoningBudget({ reasoning_budget: 100, reasoning_prefix: PREFIX })).toBeNull();
        expect(takeReasoningBudget({})).toBeNull();
    });
});

describe('isReasoningOpen', () => {
    test('an unclosed block is open, whoever opened it', () => {
        expect(isReasoningOpen(`<|turn>model\n${PREFIX}\nWhat matters:`, PREFIX, SUFFIX)).toBe(true);
        expect(isReasoningOpen(`${PREFIX} weighing it up`, PREFIX, SUFFIX)).toBe(true);
    });

    test('a closed or absent block is not open', () => {
        expect(isReasoningOpen(`${PREFIX}\n${SUFFIX}`, PREFIX, SUFFIX)).toBe(false);
        expect(isReasoningOpen(`${PREFIX} thinking ${SUFFIX} reply`, PREFIX, SUFFIX)).toBe(false);
        expect(isReasoningOpen('<|turn>model\n', PREFIX, SUFFIX)).toBe(false);
    });

    test('the last opening is the one that counts', () => {
        expect(isReasoningOpen(`${PREFIX} a ${SUFFIX} b ${PREFIX} c`, PREFIX, SUFFIX)).toBe(true);
    });
});

describe('payload shapes', () => {
    test('reads text from every backend shape and nothing from a keepalive', () => {
        expect(payloadText({ content: 'tok' })).toBe('tok');
        expect(payloadText({ choices: [{ text: 'tok' }] })).toBe('tok');
        expect(payloadText({ choices: [{ delta: { content: 'tok' } }] })).toBe('tok');
        expect(payloadText({ choices: [] })).toBe('');
        expect(payloadText(null)).toBe('');
    });

    test('writes a frame in the shape the stream is already using', () => {
        expect(JSON.parse(buildPayload('x', true).replace('data: ', ''))).toEqual({ content: 'x', stop: false });
        expect(JSON.parse(buildPayload('x', false).replace('data: ', '')).choices[0].text).toBe('x');
    });
});

describe('ReasoningBudgetTracker', () => {
    const feed = (tracker, ...texts) => texts.forEach(text => tracker.accept({ content: text }));

    test('a block opened by the prompt is counted from the first token', () => {
        const tracker = new ReasoningBudgetTracker(settings, `story${PREFIX}\nWhat matters:`);
        expect(tracker.isOpen()).toBe(true);

        feed(tracker, 'a', 'b');
        expect(tracker.isExhausted()).toBe(false);
        feed(tracker, 'c');
        expect(tracker.isExhausted()).toBe(true);
    });

    test('thinking that closes on its own is never cut off', () => {
        const tracker = new ReasoningBudgetTracker(settings, `story${PREFIX}\n`);
        feed(tracker, 'a', SUFFIX, 'the reply', ' goes on', ' and on');

        expect(tracker.isOpen()).toBe(false);
        expect(tracker.isExhausted()).toBe(false);
    });

    test('a prompt with no open block leaves ordinary generation alone', () => {
        const tracker = new ReasoningBudgetTracker(settings, '<|turn>model\n');
        feed(tracker, 'a', 'b', 'c', 'd');

        expect(tracker.isOpen()).toBe(false);
        expect(tracker.isExhausted()).toBe(false);
    });

    test('a block the model opens itself is counted too', () => {
        const tracker = new ReasoningBudgetTracker(settings, '<|turn>model\n');
        feed(tracker, PREFIX, 'a', 'b', 'c');

        expect(tracker.isExhausted()).toBe(true);
    });

    test('the continuation carries the thinking plus the closing tag, with the budget deducted', () => {
        const tracker = new ReasoningBudgetTracker({ ...settings, message: '\nEnough.' }, `story${PREFIX}\n`);
        feed(tracker, 'a', 'b', 'c');

        const next = tracker.continuationParams({ prompt: `story${PREFIX}\n`, max_tokens: 100, temperature: 1 });
        expect(next.prompt).toBe(`story${PREFIX}\nabc\nEnough.${SUFFIX}`);
        expect(next.max_tokens).toBe(97);
        expect(next.temperature).toBe(1);
    });

    test('the continuation never asks for a non-positive number of tokens', () => {
        const tracker = new ReasoningBudgetTracker({ ...settings, budget: 1 }, `story${PREFIX}\n`);
        feed(tracker, 'a', 'b', 'c', 'd', 'e');

        expect(tracker.continuationParams({ prompt: 'p', max_tokens: 4 }).max_tokens).toBe(16);
    });

    test('keepalives and empty payloads are not thinking', () => {
        const tracker = new ReasoningBudgetTracker(settings, `story${PREFIX}\n`);
        tracker.accept({ content: '' });
        tracker.accept({ choices: [] });
        tracker.accept(null);

        expect(tracker.isExhausted()).toBe(false);
    });
});

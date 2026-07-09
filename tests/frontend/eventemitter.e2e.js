/* eslint-env browser */
import { test, expect } from '@playwright/test';
import { testSetup } from './frontent-test-utils.js';

test.describe('EventEmitter.emitAndWait', () => {
    test.beforeEach(testSetup.goST);

    test('emit_and_wait_awaits_async_listener_before_resolving', async ({ page }) => {
        const order = await page.evaluate(async () => {
            /** @type {import('../../public/lib/eventemitter.js')} */
            const { EventEmitter } = await import('./lib/eventemitter.js');

            const emitter = new EventEmitter();
            /** @type {string[]} */
            const order = [];

            emitter.on('probe', async () => {
                await new Promise(resolve => setTimeout(resolve, 50));
                order.push('listener');
            });

            await emitter.emitAndWait('probe');
            order.push('caller');

            return order;
        });

        expect(order).toEqual(['listener', 'caller']);
    });

    test('emit_and_wait_awaits_every_listener_in_registration_order', async ({ page }) => {
        const order = await page.evaluate(async () => {
            const { EventEmitter } = await import('./lib/eventemitter.js');

            const emitter = new EventEmitter();
            /** @type {string[]} */
            const order = [];

            emitter.on('probe', async () => {
                await new Promise(resolve => setTimeout(resolve, 30));
                order.push('first');
            });
            emitter.on('probe', async () => {
                await new Promise(resolve => setTimeout(resolve, 10));
                order.push('second');
            });

            await emitter.emitAndWait('probe');
            order.push('caller');

            return order;
        });

        expect(order).toEqual(['first', 'second', 'caller']);
    });

    test('emit_and_wait_catches_async_listener_rejection_without_unhandled_rejection', async ({ page }) => {
        const result = await page.evaluate(async () => {
            const { EventEmitter } = await import('./lib/eventemitter.js');

            /** @type {string[]} */
            const unhandled = [];
            const onUnhandled = event => {
                event.preventDefault();
                unhandled.push(String(event.reason && event.reason.message));
            };
            window.addEventListener('unhandledrejection', onUnhandled);

            const emitter = new EventEmitter();
            /** @type {string[]} */
            const order = [];

            emitter.on('probe', async () => {
                throw new Error('listener-boom');
            });
            emitter.on('probe', async () => {
                order.push('survivor');
            });

            let threw = false;
            try {
                await emitter.emitAndWait('probe');
            } catch {
                threw = true;
            }

            // Give a rejected promise a turn to surface as unhandled if it was dropped.
            await new Promise(resolve => setTimeout(resolve, 100));
            window.removeEventListener('unhandledrejection', onUnhandled);

            return { order, threw, unhandled };
        });

        expect(result.threw).toBe(false);
        expect(result.order).toEqual(['survivor']);
        expect(result.unhandled).toEqual([]);
    });

    test('emit_and_wait_resolves_when_event_has_no_listeners', async ({ page }) => {
        const settled = await page.evaluate(async () => {
            const { EventEmitter } = await import('./lib/eventemitter.js');

            const emitter = new EventEmitter();
            await emitter.emitAndWait('nobody-listening', 'arg');
            return true;
        });

        expect(settled).toBe(true);
    });

    test('emit_and_wait_passes_emitted_arguments_to_listeners', async ({ page }) => {
        const received = await page.evaluate(async () => {
            const { EventEmitter } = await import('./lib/eventemitter.js');

            const emitter = new EventEmitter();
            /** @type {unknown[]} */
            let received = [];

            emitter.on('probe', async (...args) => {
                await new Promise(resolve => setTimeout(resolve, 10));
                received = args;
            });

            await emitter.emitAndWait('probe', 'online', 42);
            return received;
        });

        expect(received).toEqual(['online', 42]);
    });
});

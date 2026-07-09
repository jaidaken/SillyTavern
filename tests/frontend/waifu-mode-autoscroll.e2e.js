/* global document, window, requestAnimationFrame */
import { test, expect } from '@playwright/test';

import { E2E_CHARACTER_NAME } from '../util/fixtures.js';
import { STREAM_CHUNK_COUNT } from '../util/mock-server.js';

const MESSAGE_COUNT = 8;
const FILLER_MESSAGE_HEIGHT_PX = 300;

// The last message is taller than the viewport, so top-aligning it lands strictly above the true bottom.
const LAST_MESSAGE_OVERHANG_PX = 400;

/**
 * Fills #chat with sized messages and scrolls it through the app's own scrollChatToBottom.
 * @param {import('@playwright/test').Page} page Page with SillyTavern loaded
 * @param {boolean} waifuMode Value assigned to power_user.waifuMode before scrolling
 * @returns {Promise<{scrollTop: number, trueBottom: number, topAlignedPosition: number, viewportHeight: number}>} Observed scroll geometry
 */
async function scrollChatToBottomWithSizedMessages(page, waifuMode) {
    return await page.evaluate(({ count, fillerHeight, overhang, waifuMode }) => {
        const context = SillyTavern.getContext();
        context.powerUserSettings.auto_scroll_chat_to_bottom = true;
        context.powerUserSettings.waifuMode = waifuMode;

        const chat = document.getElementById('chat');
        chat.replaceChildren();
        chat.scrollTop = 0;

        const viewportHeight = chat.clientHeight;
        for (let index = 0; index < count; index++) {
            const message = document.createElement('div');
            const isLast = index === count - 1;
            message.className = 'mes';
            message.style.flex = '0 0 auto';
            message.style.height = `${isLast ? viewportHeight + overhang : fillerHeight}px`;
            chat.append(message);
        }

        const topAlignedPosition = chat.lastElementChild.offsetTop - chat.firstElementChild.offsetTop;

        context.scrollChatToBottom();

        return {
            scrollTop: chat.scrollTop,
            trueBottom: chat.scrollHeight - chat.clientHeight,
            topAlignedPosition,
            viewportHeight,
        };
    }, { count: MESSAGE_COUNT, fillerHeight: FILLER_MESSAGE_HEIGHT_PX, overhang: LAST_MESSAGE_OVERHANG_PX, waifuMode });
}

const STREAM_TIMEOUT_MS = 60000;
const SETTLE_TIMEOUT_MS = 10000;
const AT_BOTTOM_TOLERANCE_PX = 5;
const MINIMUM_GROWTH_AFTER_RESUME_PX = 200;
const SCROLL_ATTEMPTS = 20;

/**
 * Selects the seeded character and sends a message, so the mock backend starts streaming a reply.
 * @param {import('@playwright/test').Page} page Page with SillyTavern loaded
 * @returns {Promise<void>}
 */
async function startStreamingReply(page) {
    await page.evaluate(async (characterName) => {
        const { setOnlineStatus } = await import('/script.js');
        const context = SillyTavern.getContext();
        context.powerUserSettings.auto_scroll_chat_to_bottom = true;
        context.powerUserSettings.waifuMode = true;

        window.__generationEnded = false;
        context.eventSource.on(context.eventTypes.GENERATION_ENDED, () => {
            window.__generationEnded = true;
        });

        setOnlineStatus('mock-model');
        const index = context.characters.findIndex(character => character.name === characterName);
        if (index === -1) {
            throw new Error(`Seeded character ${characterName} is missing.`);
        }
        await context.selectCharacterById(index);
    }, E2E_CHARACTER_NAME);

    await page.waitForFunction(() => document.querySelectorAll('#chat .mes').length > 0, undefined, { timeout: STREAM_TIMEOUT_MS });
    await page.locator('#send_textarea').fill('Start streaming.');
    await page.locator('#send_but').click();
}

/**
 * Scrolls the chat to the top and confirms autoscroll stopped re-pinning it, retrying if a chunk arrived first.
 * @param {import('@playwright/test').Page} page Page with a stream in progress
 * @returns {Promise<boolean>} True once the chat stays at the top across two frames
 */
function scrollToTopUntilAutoscrollStops(page) {
    return page.evaluate(async (attempts) => {
        const chat = document.getElementById('chat');
        const nextFrame = () => new Promise(resolve => requestAnimationFrame(() => resolve()));

        for (let attempt = 0; attempt < attempts; attempt++) {
            chat.scrollTop = 0;
            await nextFrame();
            await nextFrame();
            if (chat.scrollTop === 0) {
                return true;
            }
        }
        return false;
    }, SCROLL_ATTEMPTS);
}

/**
 * Scrolls the chat back to the bottom and lets the scroll handler run.
 * @param {import('@playwright/test').Page} page Page with a stream in progress
 * @returns {Promise<number>} Scroll height at the moment autoscroll should resume
 */
function scrollToBottomAndSettle(page) {
    return page.evaluate(async () => {
        const chat = document.getElementById('chat');
        chat.scrollTop = chat.scrollHeight;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
        return chat.scrollHeight;
    });
}

test.describe('Waifu Mode autoscroll', () => {
    test.beforeEach(async ({ page }) => {
        await page.goto('/', { timeout: 60000 });
        await page.waitForFunction('document.getElementById("preloader") === null', { timeout: 60000 });
        await page.waitForFunction('typeof globalThis.SillyTavern?.getContext === "function"', { timeout: 60000 });
    });

    test('waifu_mode_scroll_chat_to_bottom_reaches_true_bottom', async ({ page }) => {
        const scroll = await scrollChatToBottomWithSizedMessages(page, true);

        expect(scroll.viewportHeight).toBeGreaterThan(0);
        expect(scroll.trueBottom).toBeGreaterThan(0);
        expect(scroll.topAlignedPosition).toBe(scroll.trueBottom - LAST_MESSAGE_OVERHANG_PX);
        expect(scroll.scrollTop).toBe(scroll.trueBottom);
    });

    test('waifu_mode_and_normal_mode_scroll_to_the_same_position', async ({ page }) => {
        const waifu = await scrollChatToBottomWithSizedMessages(page, true);
        const normal = await scrollChatToBottomWithSizedMessages(page, false);

        expect(normal.scrollTop).toBe(normal.trueBottom);
        expect(waifu.scrollTop).toBe(normal.scrollTop);
    });

    test('waifu_mode_streaming_autoscroll_resumes_after_user_scrolls_back_to_bottom', async ({ page }) => {
        await startStreamingReply(page);

        await page.waitForFunction(
            text => (document.querySelector('#chat .last_mes .mes_text')?.innerText ?? '').includes(text),
            'Streamed line 4.',
            { timeout: STREAM_TIMEOUT_MS },
        );

        expect(await scrollToTopUntilAutoscrollStops(page)).toBe(true);
        expect(await page.evaluate(() => window.__generationEnded)).toBe(false);

        const heightOnResume = await scrollToBottomAndSettle(page);

        await page.waitForFunction(() => window.__generationEnded === true, undefined, { timeout: STREAM_TIMEOUT_MS });

        const streamedText = await page.evaluate(() => document.querySelector('#chat .last_mes .mes_text').innerText);
        expect(streamedText).toContain(`Streamed line ${STREAM_CHUNK_COUNT}.`);

        const finalHeight = await page.evaluate(() => document.getElementById('chat').scrollHeight);
        expect(finalHeight - heightOnResume).toBeGreaterThan(MINIMUM_GROWTH_AFTER_RESUME_PX);

        await expect.poll(
            () => page.evaluate(() => {
                const chat = document.getElementById('chat');
                return chat.scrollHeight - chat.clientHeight - chat.scrollTop;
            }),
            { timeout: SETTLE_TIMEOUT_MS },
        ).toBeLessThan(AT_BOTTOM_TOLERANCE_PX);
    });
});

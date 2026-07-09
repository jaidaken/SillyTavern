import { test, expect } from '@playwright/test';
import { testSetup } from './frontent-test-utils.js';

// exceptions to the assertion below; keep empty unless a real run proves an entry is expected, unavoidable noise.
const ALLOWLIST = [
];

test.describe('console cleanliness', () => {
    /** @type {string[]} */
    let messages;

    test.beforeEach(async ({ page }) => {
        messages = [];
        page.on('console', msg => {
            if (msg.type() === 'error') {
                messages.push(msg.text());
            }
        });
        page.on('pageerror', error => {
            messages.push(String((error && error.message) || error));
        });
    });
    test.beforeEach(testSetup.awaitST);

    test('page_load_and_settle_produces_no_console_errors_or_page_errors', async () => {
        const matchedEntries = new Set();
        const unexpected = messages.filter(text => {
            const matchIndex = ALLOWLIST.findIndex(entry => entry.pattern.test(text));
            if (matchIndex === -1) {
                return true;
            }
            matchedEntries.add(matchIndex);
            return false;
        });

        const stale = ALLOWLIST.filter((_, index) => !matchedEntries.has(index));

        expect(unexpected, unexpected.join('\n')).toEqual([]);
        expect(stale.map(entry => entry.reason)).toEqual([]);
    });
});

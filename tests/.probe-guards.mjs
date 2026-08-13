import { chromium } from '@playwright/test';
const browser = await chromium.launch({ executablePath: '/run/current-system/sw/bin/google-chrome-stable', headless: true });
const page = await browser.newPage();
await page.goto('http://localhost:18000/', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.SillyTavern?.getContext?.()?.characters?.length > 0, { timeout: 60000 });
await page.waitForTimeout(4000);
const out = await page.evaluate(async () => {
    const st = await import('/script.js');
    const pu = (await import('/scripts/power-user.js')).power_user;
    const { PromptReasoning } = await import('/scripts/reasoning.js');
    return {
        main_api: st.main_api,
        instruct_enabled: pu.instruct.enabled,
        reasoning_enabled: pu.reasoning.enabled,
        auto_parse: pu.reasoning.auto_parse,
        streaming: st.isStreamingEnabled(),
        hasNewStatic: typeof PromptReasoning.latestPromptHasReasoning === 'function',
        cueSeedInModule: (await import('/scripts/reasoning-cue.js')).DEFAULT_SEED,
    };
});
console.log(JSON.stringify(out, null, 1));
await browser.close();

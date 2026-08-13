import { chromium } from '@playwright/test';
const browser = await chromium.launch({ executablePath: '/run/current-system/sw/bin/google-chrome-stable', headless: true });
const page = await browser.newPage();
await page.goto('http://localhost:18000/', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.SillyTavern?.getContext?.()?.characters?.length > 0, { timeout: 60000 });
await page.waitForTimeout(4000);
const out = await page.evaluate(async () => {
    const st = await import('/script.js');
    const pu = (await import('/scripts/power-user.js')).power_user;
    pu.reasoning.enabled = true; // in-memory only, nothing saved
    const ctx = window.SillyTavern.getContext();
    const byRecent = ctx.characters.map((c, i) => ({ i, last: Number(c.date_last_chat ?? 0) })).sort((a, b) => b.last - a.last);
    await st.selectCharacterById(String(byRecent[0].i));
    await new Promise(r => setTimeout(r, 6000));
    const prompt = await new Promise((resolve) => {
        st.eventSource.once(st.event_types.GENERATE_AFTER_COMBINE_PROMPTS, d => resolve(d?.prompt ?? ''));
        st.Generate('continue', {}, true).catch(() => {});
        setTimeout(() => resolve(null), 45000);
    });
    return { tail: prompt?.slice(-160) ?? null };
});
console.log('continue prompt tail:', JSON.stringify(out.tail));
await browser.close();

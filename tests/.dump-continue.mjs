import { chromium } from '@playwright/test';

const browser = await chromium.launch({
    executablePath: '/run/current-system/sw/bin/google-chrome-stable',
    headless: true,
});
const page = await browser.newPage();
page.on('console', m => { if (/error/i.test(m.type())) console.log('[console]', m.text().slice(0, 200)); });

await page.goto('http://localhost:18000/', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.SillyTavern?.getContext?.()?.chat !== undefined, { timeout: 60000 });
await page.waitForTimeout(4000);

const out = await page.evaluate(async () => {
    const st = await import('/script.js');
    const ctx = window.SillyTavern.getContext();
    const res = { chatLength: ctx.chat.length };
    const last = ctx.chat[ctx.chat.length - 1];
    res.lastIsUser = last?.is_user;
    res.lastMesLen = last?.mes?.length;
    res.lastReasoningLen = last?.extra?.reasoning?.length ?? 0;

    const grab = (type) => new Promise((resolve) => {
        let done = false;
        const h = (d) => { if (!done) { done = true; resolve(d?.prompt ?? ''); } };
        st.eventSource.once(st.event_types.GENERATE_AFTER_COMBINE_PROMPTS, h);
        st.Generate(type, {}, true).catch(() => {});
        setTimeout(() => { if (!done) { done = true; resolve(null); } }, 30000);
    });

    res.continuePrompt = await grab('continue');
    res.normalPrompt = await grab('normal');
    return res;
});

const fs = await import('node:fs');
if (out.continuePrompt) fs.writeFileSync('/tmp/claude-1000/continue-prompt.txt', out.continuePrompt);
const tail = (s, n = 320) => s === null ? '(no prompt captured)' : JSON.stringify(s.slice(-n));
console.log('chat length      :', out.chatLength, '| last is_user:', out.lastIsUser);
console.log('last mes chars   :', out.lastMesLen, '| reasoning chars:', out.lastReasoningLen);
console.log('\n--- NORMAL prompt tail ---\n' + tail(out.normalPrompt));
console.log('\n--- CONTINUE prompt tail ---\n' + tail(out.continuePrompt));
if (out.continuePrompt && out.normalPrompt) {
    console.log('\ncontinue == normal ?', out.continuePrompt === out.normalPrompt);
    console.log('continue ends with turn close ?', /<turn\|>\s*$/.test(out.continuePrompt));
    console.log('continue ends with thought open ?', out.continuePrompt.lastIndexOf('<|channel>thought') > out.continuePrompt.lastIndexOf('<channel|>'));
}
await browser.close();

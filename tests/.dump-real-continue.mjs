import { chromium } from '@playwright/test';
import fs from 'node:fs';

const browser = await chromium.launch({
    executablePath: '/run/current-system/sw/bin/google-chrome-stable',
    headless: true,
});
const page = await browser.newPage();
await page.goto('http://localhost:18000/', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.SillyTavern?.getContext?.()?.characters?.length > 0, { timeout: 60000 });
await page.waitForTimeout(4000);

const out = await page.evaluate(async () => {
    const st = await import('/script.js');
    const ctx = window.SillyTavern.getContext();
    // most recently chatted character
    const byRecent = ctx.characters
        .map((c, i) => ({ i, name: c.name, last: Number(c.date_last_chat ?? 0) }))
        .sort((a, b) => b.last - a.last);
    const target = byRecent[0];
    await st.selectCharacterById(String(target.i));
    await new Promise(r => setTimeout(r, 6000));

    const chat = window.SillyTavern.getContext().chat;
    const last = chat[chat.length - 1];
    const res = {
        character: target.name,
        chatLength: chat.length,
        lastIsUser: last?.is_user,
        lastMesTail: last?.mes?.slice(-120),
        lastReasoningLen: last?.extra?.reasoning?.length ?? 0,
    };

    res.continuePrompt = await new Promise((resolve) => {
        let done = false;
        st.eventSource.once(st.event_types.GENERATE_AFTER_COMBINE_PROMPTS, d => { if (!done) { done = true; resolve(d?.prompt ?? ''); } });
        st.Generate('continue', {}, true).catch(() => {});
        setTimeout(() => { if (!done) { done = true; resolve(null); } }, 45000);
    });
    return res;
});

console.log('character        :', out.character, '| chat msgs:', out.chatLength, '| last is_user:', out.lastIsUser);
console.log('last reasoning   :', out.lastReasoningLen, 'chars');
console.log('last mes tail    :', JSON.stringify(out.lastMesTail));
if (out.continuePrompt) {
    fs.writeFileSync('/tmp/claude-1000/real-continue-prompt.txt', out.continuePrompt);
    console.log('prompt saved     :', out.continuePrompt.length, 'chars');
    console.log('--- prompt tail (400) ---');
    console.log(JSON.stringify(out.continuePrompt.slice(-400)));
} else {
    console.log('NO PROMPT CAPTURED');
}
await browser.close();

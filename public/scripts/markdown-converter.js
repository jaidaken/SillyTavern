import { MarkdownIt, markdownItEmoji, markdownItImsize } from '../lib.js';
import { markdownDinkusExclusionRule } from './markdown-dinkus.js';

// Renames double-underscore strong tokens to <u>, reusing markdown-it's emphasis/flanking + nesting logic.
function markdownUnderlineRule(state) {
    for (const token of state.tokens) {
        if (token.type !== 'inline' || !token.children) continue;
        for (const child of token.children) {
            if ((child.type === 'strong_open' || child.type === 'strong_close') && child.markup === '__') {
                child.tag = 'u';
            }
        }
    }
}

export function createMarkdownConverter() {
    const md = new MarkdownIt({ html: true, breaks: true, linkify: false, typographer: false });
    md.use(markdownItEmoji);
    md.use(markdownItImsize);
    md.core.ruler.push('underline', markdownUnderlineRule);
    md.core.ruler.before('normalize', 'dinkus_exclusion', markdownDinkusExclusionRule);
    return md;
}

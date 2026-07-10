import { power_user } from './power-user.js';
import { substituteParams } from '../script.js';

function escapeToNumericEntities(line) {
    return Array.from(line).map((char) => `&#${char.codePointAt(0)};`).join('');
}

// Entity-escapes a matched line pre-block-parse so it renders literally with no residual marker char.
export function markdownDinkusExclusionRule(state) {
    if (!power_user?.markdown_escape_strings) {
        return;
    }

    const exclusions = substituteParams(power_user.markdown_escape_strings)
        .split(',')
        .filter((element) => element.length > 0);

    if (exclusions.length === 0) {
        return;
    }

    state.src = state.src
        .split('\n')
        .map((line) => (exclusions.includes(line) ? escapeToNumericEntities(line) : line))
        .join('\n');
}

import { describe, test, expect } from '@jest/globals';

import {
    diffOps,
    diffSummary,
    keyByContent,
    identityMatches,
    identityBasis,
    versionInBackup,
    restoreDeletedMessages,
    MAX_ALIGN,
} from '../src/chat-undo.js';

/**
 * @param {string} mes Message text.
 * @param {boolean} isUser Whether the message is from the user.
 * @param {object} [extra] Extra fields to spread onto the message.
 * @returns {object} A message object.
 */
function msg(mes, isUser = false, extra = {}) {
    return { name: isUser ? 'You' : 'Bot', is_user: isUser, mes, ...extra };
}

describe('lcs alignment', () => {
    test('lcs_align_never_collapses_two_identical_messages', () => {
        const from = [msg('ok'), msg('ok')];
        const to = [msg('ok')];
        const { ops, tooLarge } = diffOps(from, to, keyByContent);
        expect(tooLarge).toBe(false);
        const deletes = ops.filter(o => o.type === 'delete');
        const matches = ops.filter(o => o.type === 'match');
        expect(deletes).toHaveLength(1);
        expect(matches).toHaveLength(1);
        expect(deletes[0].ai).toBe(0);
        expect(matches[0].ai).toBe(1);
        expect(matches[0].bi).toBe(0);
    });

    test('diff_ops_marks_insert_delete_and_match_positions', () => {
        const from = [msg('a'), msg('b'), msg('c')];
        const to = [msg('a'), msg('x'), msg('c')];
        const { ops } = diffOps(from, to, keyByContent);
        expect(ops.filter(o => o.type === 'delete').map(o => from[o.ai].mes)).toEqual(['b']);
        expect(ops.filter(o => o.type === 'insert').map(o => to[o.bi].mes)).toEqual(['x']);
        expect(ops.filter(o => o.type === 'match')).toHaveLength(2);
    });

    test('diff_ops_bails_when_a_side_exceeds_max_align', () => {
        const big = Array.from({ length: MAX_ALIGN + 1 }, (_, i) => msg(`m${i}`));
        const { tooLarge, ops } = diffOps(big, [msg('a')], keyByContent);
        expect(tooLarge).toBe(true);
        expect(ops).toBeNull();
    });
});

describe('restore-deleted reinsertion', () => {
    test('restore_deleted_reinserts_at_head_when_no_surviving_predecessor', () => {
        const current = [msg('b'), msg('c')];
        const backup = [msg('a'), msg('b'), msg('c')];
        const { messages, restored } = restoreDeletedMessages(current, backup);
        expect(restored).toBe(1);
        expect(messages.map(m => m.mes)).toEqual(['a', 'b', 'c']);
    });

    test('restore_deleted_preserves_relative_order_of_multiple_deletes_sharing_one_anchor', () => {
        const current = [msg('x'), msg('y')];
        const backup = [msg('x'), msg('d1'), msg('d2'), msg('y')];
        const { messages, restored } = restoreDeletedMessages(current, backup);
        expect(restored).toBe(2);
        expect(messages.map(m => m.mes)).toEqual(['x', 'd1', 'd2', 'y']);
    });

    test('restore_deleted_keeps_current_only_additions', () => {
        const current = [msg('x'), msg('new'), msg('y')];
        const backup = [msg('x'), msg('gone'), msg('y')];
        const { messages, restored } = restoreDeletedMessages(current, backup);
        expect(restored).toBe(1);
        expect(messages.map(m => m.mes)).toEqual(['x', 'gone', 'new', 'y']);
    });
});

describe('message version tracking', () => {
    test('version_in_backup_follows_an_edit_through_content_anchors', () => {
        const current = [msg('a'), msg('B-edited'), msg('c')];
        const backup = [msg('a'), msg('B-original'), msg('c')];
        const version = versionInBackup(current, 1, backup);
        expect(version).toEqual({ text: 'B-original', matched: 'content' });
    });

    test('version_in_backup_returns_null_when_the_message_did_not_exist', () => {
        const current = [msg('a'), msg('b'), msg('brand-new')];
        const backup = [msg('a'), msg('b')];
        expect(versionInBackup(current, 2, backup)).toBeNull();
    });

    test('version_in_backup_uses_cf_id_when_present_and_reports_unchanged', () => {
        const current = [msg('a', false, { cf_id: 'X' }), msg('now', false, { cf_id: 'Y' })];
        const backup = [msg('a', false, { cf_id: 'X' }), msg('then', false, { cf_id: 'Y' })];
        expect(versionInBackup(current, 1, backup)).toEqual({ text: 'then', matched: 'cf_id' });
        expect(versionInBackup(current, 0, backup)).toEqual({ text: 'a', matched: 'unchanged' });
    });
});

describe('identity attribution', () => {
    test('identity_matches_requires_every_present_key_to_agree', () => {
        const cur = { integrity: 'u1', create_date: 'd1', character_name: 'Denny' };
        expect(identityMatches(cur, { integrity: 'u1', create_date: 'd1', character_name: 'Denny' })).toBe(true);
        expect(identityMatches(cur, { integrity: 'u1', create_date: 'd2', character_name: 'Denny' })).toBe(false);
        expect(identityMatches(cur, { integrity: 'u2', create_date: 'd1', character_name: 'Denny' })).toBe(false);
    });

    test('identity_matches_rejects_an_unattributable_current_chat', () => {
        const cur = { integrity: null, create_date: null, character_name: 'Denny' };
        expect(identityMatches(cur, { integrity: null, create_date: null, character_name: 'Denny' })).toBe(false);
    });

    test('identity_basis_reports_which_keys_are_load_bearing', () => {
        expect(identityBasis({ integrity: 'u', create_date: 'd', character_name: 'c' })).toBe('integrity+create_date');
        expect(identityBasis({ integrity: null, create_date: 'd', character_name: 'c' })).toBe('create_date');
        expect(identityBasis({ integrity: null, create_date: null, character_name: 'c' })).toBe('none');
    });
});

describe('diff summary', () => {
    test('diff_summary_counts_adds_and_removes_on_the_content_basis', () => {
        const backup = [msg('a'), msg('b')];
        const current = [msg('a'), msg('b'), msg('c')];
        expect(diffSummary(backup, current)).toEqual({ added: 1, removed: 0, edited: 0, basis: 'content', tooLarge: false });
    });

    test('diff_summary_distinguishes_an_edit_from_add_plus_remove_when_cf_id_is_present', () => {
        const backup = [msg('a', false, { cf_id: 'X' }), msg('old', false, { cf_id: 'Y' })];
        const current = [msg('a', false, { cf_id: 'X' }), msg('new', false, { cf_id: 'Y' })];
        expect(diffSummary(backup, current)).toEqual({ added: 0, removed: 0, edited: 1, basis: 'cf_id', tooLarge: false });
    });
});

/**
 * Builds a minimal Character Card V2 payload accepted by importFromJson.
 * @param {string} name Character name
 * @param {object} overrides Fields merged into the card data
 * @returns {object} A V2 character card
 */
export function characterCardV2(name, overrides = {}) {
    return {
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
            name,
            description: '',
            personality: '',
            scenario: '',
            first_mes: '',
            mes_example: '',
            creator_notes: '',
            system_prompt: '',
            post_history_instructions: '',
            alternate_greetings: [],
            tags: [],
            creator: '',
            character_version: '',
            extensions: {},
            ...overrides,
        },
    };
}

/**
 * Builds a chat transcript exercising unicode, quoting, escapes and embedded newlines.
 * @param {string} characterName Name used for the assistant turn
 * @returns {object[]} Chat messages in the on-disk jsonl shape
 */
export function chatMessages(characterName) {
    return [
        {
            name: 'You',
            is_user: true,
            mes: 'first line\nsecond line éè 🚀',
            send_date: 1700000000000,
        },
        {
            name: characterName,
            is_user: false,
            mes: 'reply with "quotes", a \\ backslash and a tab\there',
            send_date: 1700000000001,
        },
    ];
}

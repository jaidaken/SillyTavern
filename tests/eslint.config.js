import js from '@eslint/js';
import globals from 'globals';
import jest from 'eslint-plugin-jest';
import playwright from 'eslint-plugin-playwright';

export default [
    {
        ignores: [
            '**/*.min.js',
            'node_modules/**/*',
        ],
    },
    js.configs.recommended,
    { ...jest.configs['flat/recommended'], files: ['**/*.test.js'] },
    { ...playwright.configs['flat/recommended'], files: ['**/*.e2e.js'] },
    {
        languageOptions: {
            ecmaVersion: 'latest',
            sourceType: 'module',
            globals: {
                ...globals.es2015,
                ...globals.node,
                ...jest.environments.globals.globals,
                SillyTavern: 'readonly',
            },
        },
        settings: {
            jest: {
                version: 30,
            },
        },
        rules: {
            // caughtErrors defaulted to 'none' before ESLint 9; kept explicit to preserve prior behavior.
            'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
            'no-control-regex': 'off',
            'no-constant-condition': ['error', { checkLoops: false }],
            'require-yield': 'off',
            'quotes': ['error', 'single'],
            'semi': ['error', 'always'],
            'indent': ['error', 4, { SwitchCase: 1, FunctionDeclaration: { parameters: 'first' } }],
            'comma-dangle': ['error', 'always-multiline'],
            'eol-last': ['error', 'always'],
            'no-trailing-spaces': 'error',
            'object-curly-spacing': ['error', 'always'],
            'space-infix-ops': 'error',
            'no-unused-expressions': ['error', { allowShortCircuit: true, allowTernary: true }],
            'no-cond-assign': 'error',
            // These rules should eventually be enabled.
            'no-async-promise-executor': 'off',
            'no-inner-declarations': 'off',
        },
    },
];

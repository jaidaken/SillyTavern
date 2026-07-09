import js from '@eslint/js';
import globals from 'globals';
import jsdoc from 'eslint-plugin-jsdoc';

export default [
    {
        ignores: [
            '**/node_modules/**',
            '**/dist/**',
            '**/.git/**',
            'public/lib/**',
            'backups/**',
            'data/**',
            'cache/**',
            'src/tokenizers/**',
            'docker/**',
            'plugins/**',
            '**/*.min.js',
            'public/scripts/extensions/quick-reply/lib/**',
            'public/scripts/extensions/tts/lib/**',
        ],
    },
    js.configs.recommended,
    {
        plugins: {
            jsdoc,
        },
        languageOptions: {
            ecmaVersion: 'latest',
            globals: {
                ...globals.es2015,
            },
        },
        rules: {
            'jsdoc/no-undefined-types': ['warn', { disableReporting: true, markVariablesAsUsed: true }],
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
            'no-unneeded-ternary': 'error',
            'no-irregular-whitespace': ['error', { skipStrings: true, skipTemplates: true }],
            'dot-notation': ['error', { 'allowPattern': '[A-Z]\\w*$' }],
            // These rules should eventually be enabled.
            'no-async-promise-executor': 'off',
            'no-inner-declarations': 'off',
            // Additional formatting rules based on codebase conventions
            'brace-style': ['error', '1tbs', { allowSingleLine: true }],
            'array-bracket-spacing': ['error', 'never'],
            'computed-property-spacing': ['error', 'never'],
            'block-spacing': ['error', 'always'],
            'keyword-spacing': ['error', { before: true, after: true }],
            'space-before-blocks': ['error', 'always'],
            'space-before-function-paren': ['error', { anonymous: 'always', named: 'never', asyncArrow: 'always' }],
            'space-in-parens': ['error', 'never'],
            'comma-spacing': ['error', { before: false, after: true }],
            'key-spacing': ['error', { beforeColon: false, afterColon: true }],
            'func-call-spacing': ['error', 'never'],
            'no-multiple-empty-lines': ['error', { max: 2, maxEOF: 1, maxBOF: 0 }],
            'padded-blocks': ['error', 'never'],
            'no-whitespace-before-property': 'error',
            'space-unary-ops': ['error', { words: true, nonwords: false }],
            'arrow-spacing': ['error', { before: true, after: true }],
            'template-curly-spacing': ['error', 'never'],
            'rest-spread-spacing': ['error', 'never'],
            'generator-star-spacing': ['error', { before: false, after: true }],
            'yield-star-spacing': ['error', { before: false, after: true }],
            'template-tag-spacing': ['error', 'never'],
            'switch-colon-spacing': ['error', { after: true, before: false }],
        },
    },
    {
        // Server-side files (plus this configuration file)
        files: ['src/**/*.js', '*.js', 'plugins/**/*.js'],
        languageOptions: {
            sourceType: 'module',
            globals: {
                ...globals.node,
                globalThis: 'readonly',
                Deno: 'readonly',
            },
        },
    },
    {
        files: ['**/*.cjs'],
        languageOptions: {
            sourceType: 'commonjs',
            globals: {
                ...globals.node,
            },
        },
    },
    {
        files: ['src/**/*.mjs', 'scripts/**/*.mjs'],
        languageOptions: {
            sourceType: 'module',
            globals: {
                ...globals.node,
            },
        },
    },
    {
        // Browser-side files
        files: ['public/**/*.js'],
        languageOptions: {
            sourceType: 'module',
            globals: {
                ...globals.browser,
                ...globals.jquery,
                // These scripts are loaded in HTML; tell ESLint not to complain about them being undefined
                globalThis: 'readonly',
                ePub: 'readonly',
                pdfjsLib: 'readonly',
                toastr: 'readonly',
                SillyTavern: 'readonly',
            },
        },
    },
];

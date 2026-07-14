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
            'no-console': 'error',
            // warn (not error): MacrosParser is deprecated but ~8 first-party call sites still use it;
            // the migration to macros.registry is a tracked follow-up. New usage is flagged, not blocked.
            'no-restricted-properties': ['warn',
                { object: 'document', property: 'write', message: 'document.write blocks parsing and can wipe the page. Render into the DOM instead.' },
                { object: 'MacrosParser', property: 'registerMacro', message: 'MacrosParser is deprecated. Use macros.registry.registerMacro (scripts/macros/macro-system.js) or substituteParams({ dynamicMacros }) instead.' },
                { object: 'MacrosParser', property: 'unregisterMacro', message: 'MacrosParser is deprecated. Use macros.registry.unregisterMacro (scripts/macros/macro-system.js) instead.' },
                { object: 'MacrosParser', property: 'get', message: 'MacrosParser is deprecated. Use macros.registry.getMacro (scripts/macros/macro-system.js) instead.' },
                { object: 'MacrosParser', property: 'has', message: 'MacrosParser is deprecated. Use macros.registry.hasMacro (scripts/macros/macro-system.js) instead.' },
            ],
            'no-restricted-syntax': ['error',
                {
                    selector: 'CallExpression[callee.property.name="open"][arguments.2.value=false]',
                    message: 'Synchronous XMLHttpRequest blocks the main thread. Pass true (or omit the third argument) and use the callback/promise result instead.',
                },
                {
                    selector: 'CallExpression[callee.property.name="ajax"] Property[key.name="async"][value.value=false]',
                    message: 'jQuery.ajax with async:false blocks the main thread. Drop async:false and consume the returned promise instead.',
                },
            ],
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
    {
        // WASM client glue: classic script loaded via <script>, deps via dynamic import().
        files: ['client/glue/*.js'],
        languageOptions: {
            sourceType: 'script',
            globals: {
                ...globals.browser,
            },
        },
    },
    {
        // The logging frameworks bind and call console directly by design; this is their one legitimate implementation.
        files: ['public/scripts/log.js', 'src/log.js'],
        rules: {
            'no-console': 'off',
        },
    },
    {
        // registerDebugFunction dumps missing-translation data to console on explicit user command.
        files: ['public/scripts/i18n.js'],
        rules: {
            'no-console': ['error', { allow: ['log', 'table'] }],
        },
    },
    {
        // Documented speechSynthesis onend GC workaround; the console.log call is load-bearing (see inline comment at the call site).
        files: ['public/scripts/extensions/tts/system.js'],
        rules: {
            'no-console': ['error', { allow: ['log'] }],
        },
    },
    {
        // Two console.trace stack-capture diagnostics, plus setupLogLevel which reassigns
        // console.debug/info/warn/error to gate log output (same role as the log frameworks).
        files: ['src/util.js'],
        rules: {
            'no-console': ['error', { allow: ['trace', 'debug', 'info', 'warn', 'error'] }],
        },
    },
    {
        // The formatted startup banner is intentional operator-facing output, not application logging.
        files: ['src/server-main.js'],
        rules: {
            'no-console': ['error', { allow: ['log'] }],
        },
    },
    {
        // Deprecated public sync-XHR extension APIs (getUrlSync, getTokenCount) kept for
        // third-party extension compat; async replacements exist and are preferred.
        files: ['public/scripts/templates.js', 'public/scripts/tokenizers.js'],
        rules: {
            'no-restricted-syntax': 'off',
        },
    },
    {
        // CLI entry points and build/dev tooling: console is the correct output channel,
        // these run in a Node terminal context, not the application runtime.
        files: ['server.js', 'recover.js', 'plugins.js', 'webpack.config.js', 'scripts/**/*.{js,mjs}', 'src/electron/index.js'],
        rules: {
            'no-console': 'off',
        },
    },
];

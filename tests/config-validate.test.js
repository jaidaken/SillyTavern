import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test, expect } from '@jest/globals';
import yaml from 'yaml';
import { validateConfig, validateEnvOverrides } from '../src/config-validate.js';

const defaultConfig = {
    port: 8000,
    listen: false,
    dataRoot: './data',
    cors: {
        enabled: true,
        maxAge: null,
        methods: ['OPTIONS'],
    },
    listenAddress: {
        ipv4: '0.0.0.0',
        ipv6: '[::]',
    },
};

describe('validateConfig', () => {
    test('should return empty findings for a clean config', () => {
        const userConfig = { port: 9000, cors: { enabled: false, methods: ['GET'] } };
        expect(validateConfig(userConfig, defaultConfig)).toEqual([]);
    });

    test('should report an unknown key at top level', () => {
        const findings = validateConfig({ prot: 8000 }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'prot', kind: 'unknown-key', expected: null, actual: 'number' });
    });

    test('should report an unknown key nested in a known section', () => {
        const findings = validateConfig({ cors: { enabld: true } }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'cors.enabld', kind: 'unknown-key', expected: null, actual: 'boolean' });
    });

    test('should stay silent for an allowlisted key and its children', () => {
        const userConfig = { logging: { categories: { sys: 'warn' } } };
        const defaults = { logging: { minLogLevel: 0 } };
        const options = { allowKeys: ['logging.categories'] };
        expect(validateConfig(userConfig, defaults, options)).toEqual([]);
    });

    test('should report a string value where the default is a number', () => {
        const findings = validateConfig({ port: 'eight thousand' }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'port', kind: 'type-mismatch', expected: 'number', actual: 'string' });
    });

    test('should report a string value where the default is a boolean', () => {
        const findings = validateConfig({ listen: 'yes' }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'listen', kind: 'type-mismatch', expected: 'boolean', actual: 'string' });
    });

    test('should treat an object value where the default is an array as a mismatch', () => {
        const findings = validateConfig({ cors: { methods: { get: true } } }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'cors.methods', kind: 'type-mismatch', expected: 'array', actual: 'object' });
    });

    test('should treat an array value where the default is an object as a mismatch', () => {
        const findings = validateConfig({ listenAddress: ['0.0.0.0'] }, defaultConfig);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'listenAddress', kind: 'type-mismatch', expected: 'object', actual: 'array' });
    });

    test('should skip the type check when the default value is null', () => {
        expect(validateConfig({ cors: { maxAge: 600 } }, defaultConfig)).toEqual([]);
        expect(validateConfig({ cors: { maxAge: 'ten minutes' } }, defaultConfig)).toEqual([]);
    });

    test('should skip the type check when the user value is null', () => {
        expect(validateConfig({ dataRoot: null }, defaultConfig)).toEqual([]);
    });

    test('should not descend into arrays when hunting unknown keys', () => {
        const userConfig = { cors: { methods: [{ madeUp: true }] } };
        expect(validateConfig(userConfig, defaultConfig)).toEqual([]);
    });

    test('should return empty findings for non-object inputs', () => {
        expect(validateConfig(null, defaultConfig)).toEqual([]);
        expect(validateConfig({ port: 1 }, undefined)).toEqual([]);
    });
});

describe('validateEnvOverrides', () => {
    test('should report an env var that matches no known config key', () => {
        const env = { SILLYTAVERN_PROT: '8000', HOME: '/home/user' };
        const findings = validateEnvOverrides(defaultConfig, env);
        expect(findings).toHaveLength(1);
        expect(findings[0]).toEqual({ path: 'SILLYTAVERN_PROT', kind: 'unknown-env', expected: null, actual: null });
    });

    test('should accept env vars derived from top-level and nested keys', () => {
        const env = {
            SILLYTAVERN_PORT: '9000',
            SILLYTAVERN_CORS_ENABLED: 'false',
            SILLYTAVERN_LISTENADDRESS_IPV4: '127.0.0.1',
        };
        expect(validateEnvOverrides(defaultConfig, env)).toEqual([]);
    });

    test('should ignore env vars without the SILLYTAVERN_ prefix', () => {
        const env = { PATH: '/usr/bin', NODE_ENV: 'test' };
        expect(validateEnvOverrides(defaultConfig, env)).toEqual([]);
    });
});

describe('self-clean against the shipped default config', () => {
    test('should produce zero findings when the default config is validated against itself', () => {
        const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
        const shipped = yaml.parse(fs.readFileSync(path.join(repoRoot, 'default/config.yaml'), 'utf8'));
        expect(validateConfig(shipped, shipped)).toEqual([]);
        expect(validateEnvOverrides(shipped, {})).toEqual([]);
    });
});

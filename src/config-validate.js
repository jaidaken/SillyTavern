import path from 'node:path';
import fs from 'node:fs';
import process from 'node:process';

import yaml from 'yaml';
import _ from 'lodash';

import { getConfig, keyToEnv } from './util.js';
import { log } from './log.js';

// logging.categories is read by log.js but has no entry in default/config.yaml.
export const ALLOWED_EXTRA_KEYS = ['logging.categories'];

function typeName(value) {
    if (value === null) return 'null';
    if (Array.isArray(value)) return 'array';
    return typeof value;
}

function isAllowedKey(keyPath, allowKeys) {
    return allowKeys.some((allowed) => keyPath === allowed || keyPath.startsWith(allowed + '.'));
}

/**
 * Compares a user config object against the default config and reports discrepancies.
 * @param {object} userConfig Parsed user config
 * @param {object} defaultConfig Parsed default config
 * @param {object} [options] Validation options
 * @param {string[]} [options.allowKeys] Dot-paths exempt from unknown-key findings
 * @returns {{path: string, kind: string, expected: string|null, actual: string|null}[]} Findings
 */
export function validateConfig(userConfig, defaultConfig, options = {}) {
    const findings = [];
    if (!_.isPlainObject(userConfig) || !_.isPlainObject(defaultConfig)) {
        return findings;
    }
    const allowKeys = options.allowKeys ?? [];
    walk(userConfig, defaultConfig, '', findings, allowKeys);
    return findings;
}

// default/config.yaml has no free-form user-keyed map sections (checked 2026-07-11), so every nested plain object is walked.
function walk(userNode, defaultNode, prefix, findings, allowKeys) {
    for (const [key, userValue] of Object.entries(userNode)) {
        const keyPath = prefix ? `${prefix}.${key}` : key;
        if (!Object.prototype.hasOwnProperty.call(defaultNode, key)) {
            if (!isAllowedKey(keyPath, allowKeys)) {
                findings.push({ path: keyPath, kind: 'unknown-key', expected: null, actual: typeName(userValue) });
            }
            continue;
        }
        const defaultValue = defaultNode[key];
        if (defaultValue === null || defaultValue === undefined) {
            continue;
        }
        if (userValue === null || userValue === undefined) {
            continue;
        }
        const expected = typeName(defaultValue);
        const actual = typeName(userValue);
        if (expected !== actual) {
            findings.push({ path: keyPath, kind: 'type-mismatch', expected, actual });
            continue;
        }
        if (_.isPlainObject(userValue) && _.isPlainObject(defaultValue)) {
            walk(userValue, defaultValue, keyPath, findings, allowKeys);
        }
    }
}

function collectEnvNames(node, prefix, out) {
    for (const [key, value] of Object.entries(node)) {
        const keyPath = prefix ? `${prefix}.${key}` : key;
        out.add(keyToEnv(keyPath));
        if (_.isPlainObject(value)) {
            collectEnvNames(value, keyPath, out);
        }
    }
}

/**
 * Reports SILLYTAVERN_* environment variables that do not correspond to any known config key.
 * @param {object} defaultConfig Parsed default config
 * @param {NodeJS.ProcessEnv} env Environment variables
 * @returns {{path: string, kind: string, expected: string|null, actual: string|null}[]} Findings
 */
export function validateEnvOverrides(defaultConfig, env) {
    const findings = [];
    if (!_.isPlainObject(defaultConfig) || !_.isPlainObject(env)) {
        return findings;
    }
    const known = new Set(ALLOWED_EXTRA_KEYS.map(keyToEnv));
    collectEnvNames(defaultConfig, '', known);
    for (const name of Object.keys(env)) {
        if (name.startsWith('SILLYTAVERN_') && !known.has(name)) {
            findings.push({ path: name, kind: 'unknown-env', expected: null, actual: null });
        }
    }
    return findings;
}

function formatFinding(finding) {
    switch (finding.kind) {
        case 'unknown-key':
            return `Config validation: unknown key "${finding.path}" is not present in default/config.yaml. Check for a typo, or add it to ALLOWED_EXTRA_KEYS in src/config-validate.js to silence this warning.`;
        case 'type-mismatch':
            return `Config validation: key "${finding.path}" has type ${finding.actual}, but default/config.yaml expects ${finding.expected}.`;
        case 'unknown-env':
            return `Config validation: environment variable "${finding.path}" does not correspond to any known config key. Check for a typo.`;
        default:
            return `Config validation: ${finding.kind} at "${finding.path}".`;
    }
}

/**
 * Validates the loaded user config and environment overrides against the shipped default
 * config, logging one warning per finding. Warn-only: never throws or blocks boot.
 * @param {string} serverDirectory Server root directory
 * @returns {Promise<void>}
 */
export async function runConfigValidation(serverDirectory) {
    try {
        const defaultConfigPath = path.join(serverDirectory, 'default/config.yaml');
        const defaultConfig = yaml.parse(await fs.promises.readFile(defaultConfigPath, 'utf8'));
        const userConfig = getConfig();
        const findings = [
            ...validateConfig(userConfig, defaultConfig, { allowKeys: ALLOWED_EXTRA_KEYS }),
            ...validateEnvOverrides(defaultConfig, process.env),
        ];
        for (const finding of findings) {
            log.sys.warn(formatFinding(finding));
        }
    } catch (error) {
        log.sys.warn('Config validation skipped due to an internal error:', error instanceof Error ? error.message : error);
    }
}

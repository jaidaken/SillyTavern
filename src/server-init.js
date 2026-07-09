/**
 * Scripts to be done before starting the server for the first time.
 */
import path from 'node:path';
import process from 'node:process';
import { addMissingConfigValues } from './config-init.js';
import { log } from './log.js';

try {
    addMissingConfigValues(path.join(process.cwd(), './config.yaml'));
} catch (error) {
    log.sys.error(error);
}

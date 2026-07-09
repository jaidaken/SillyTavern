import path from 'node:path';
import fs from 'node:fs';
import { getIpAddress } from '../express-common.js';
import { color, getConfigValue } from '../util.js';
import { log } from '../log.js';

const enableAccessLog = getConfigValue('logging.enableAccessLog', true, 'boolean');

const knownIPs = new Set();

export const getAccessLogPath = () => path.join(globalThis.DATA_ROOT, 'access.log');

export function migrateAccessLog() {
    try {
        if (!fs.existsSync('access.log')) {
            return;
        }
        const logPath = getAccessLogPath();
        if (fs.existsSync(logPath)) {
            return;
        }
        fs.renameSync('access.log', logPath);
        log.sys.info(color.yellow('Migrated access.log to new location:'), logPath);
    } catch (e) {
        log.sys.error('Failed to migrate access log:', e);
        log.sys.info('Please move access.log to the data directory manually.');
    }
}

/**
 * Creates middleware for logging access and new connections
 * @returns {import('express').RequestHandler}
 */
export default function accessLoggerMiddleware() {
    return function (req, res, next) {
        const clientIp = getIpAddress(req, true);
        const userAgent = req.headers['user-agent'];

        if (!knownIPs.has(clientIp)) {
            // Log new connection
            knownIPs.add(clientIp);

            // Write to access log if enabled
            if (enableAccessLog) {
                log.sys.info(color.yellow(`New connection from ${clientIp}; User Agent: ${userAgent}\n`));
                const logPath = getAccessLogPath();
                const timestamp = new Date().toISOString();
                const logLine = `${timestamp} ${clientIp} ${userAgent}\n`;

                fs.appendFile(logPath, logLine, (err) => {
                    if (err) {
                        log.sys.error('Failed to write access log:', err);
                    }
                });
            }
        }

        next();
    };
}

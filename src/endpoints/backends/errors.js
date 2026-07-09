import { log } from '../../log.js';

/**
 * @typedef {'offline'|'unauthorized'|'rate_limited'|'upstream_error'|'bad_request'|'aborted'} BackendErrorType
 */

/** @type {Record<BackendErrorType, number>} */
const HTTP_STATUS_BY_TYPE = {
    offline: 503,
    unauthorized: 403,
    rate_limited: 429,
    upstream_error: 502,
    bad_request: 400,
    aborted: 504,
};

/** @type {Record<BackendErrorType, boolean>} */
const DEFAULT_RETRYABLE_BY_TYPE = {
    offline: true,
    unauthorized: false,
    rate_limited: true,
    upstream_error: true,
    bad_request: false,
    aborted: false,
};

export class BackendError extends Error {
    /**
     * @param {BackendErrorType} type Taxonomy type.
     * @param {string} message Human-readable message.
     * @param {object} [options]
     * @param {number} [options.upstreamStatus] The raw HTTP status returned by the upstream backend, if any.
     * @param {boolean} [options.retryable] Overrides the type's default retryability.
     */
    constructor(type, message, { upstreamStatus, retryable } = {}) {
        super(message);
        this.name = 'BackendError';
        /** @type {BackendErrorType} */
        this.type = type;
        this.httpStatus = HTTP_STATUS_BY_TYPE[type] ?? HTTP_STATUS_BY_TYPE.upstream_error;
        this.upstreamStatus = upstreamStatus;
        this.retryable = retryable ?? DEFAULT_RETRYABLE_BY_TYPE[type] ?? false;
    }
}

/**
 * Classifies an HTTP status returned by an upstream backend into a BackendError.
 * Never maps to 401: a 401 proxied back to the browser resets client Basic auth.
 * @param {number} upstreamStatus The upstream HTTP status code.
 * @param {string} [message] Optional detail message (falls back to a generic one).
 * @returns {BackendError}
 */
export function classifyUpstreamStatus(upstreamStatus, message) {
    /** @type {BackendErrorType} */
    let type;
    if (upstreamStatus === 401 || upstreamStatus === 403) {
        type = 'unauthorized';
    } else if (upstreamStatus === 429) {
        type = 'rate_limited';
    } else if (upstreamStatus >= 400 && upstreamStatus < 500) {
        type = 'bad_request';
    } else {
        type = 'upstream_error';
    }
    return new BackendError(type, message || `Upstream backend returned status ${upstreamStatus}.`, { upstreamStatus });
}

/**
 * Classifies a thrown error from a failed backend fetch (no upstream response was ever received)
 * into a BackendError.
 * @param {any} error The thrown error.
 * @returns {BackendError}
 */
export function classifyFetchError(error) {
    if (error?.name === 'AbortError') {
        return new BackendError('aborted', 'The request to the backend was aborted or timed out.');
    }
    const code = error?.code || error?.cause?.code;
    if (['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH'].includes(code)) {
        return new BackendError('offline', `Could not reach the backend: ${error.message}`);
    }
    if (code === 'ECONNRESET' || code === 'EPIPE') {
        return new BackendError('upstream_error', `Connection to the backend was reset: ${error.message}`, { retryable: true });
    }
    return new BackendError('upstream_error', error?.message || 'An unknown error occurred while contacting the backend.');
}

/**
 * Express error middleware for the backend error contract. For a BackendError, sends
 * `{ error: { type, message, status?, retryable? } }` with the type's fixed HTTP status.
 * Any other error is passed through to the next (generic) error handler.
 * @param {any} err The error passed via next(err).
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
export function backendErrorHandler(err, req, res, next) {
    if (!(err instanceof BackendError) || res.headersSent) {
        return next(err);
    }
    log.net.error(`Backend error [${err.type}] on ${req.method} ${req.originalUrl}: ${err.message}`);
    res.status(err.httpStatus).json({
        error: {
            type: err.type,
            message: err.message,
            status: err.upstreamStatus,
            retryable: err.retryable,
        },
    });
}

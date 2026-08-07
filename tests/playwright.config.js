import { defineConfig } from '@playwright/test';

// Set when the Playwright-managed browser build is absent and a local Chromium must be used.
const executablePath = process.env.ST_E2E_CHROMIUM || undefined;
const baseURL = process.env.ST_BASE_URL || process.env.PLAYWRIGHT_BASE_URL || 'http://127.0.0.1:8000';

export default defineConfig({
    testMatch: '*.e2e.js',
    use: {
        baseURL,
        video: 'only-on-failure',
        screenshot: 'only-on-failure',
        launchOptions: { executablePath },
    },
    webServer: {
        command: 'node util/e2e-server.js',
        url: 'http://127.0.0.1:8001/ready',
        reuseExistingServer: true,
        timeout: 180000,
    },
    workers: 4,
    fullyParallel: true,
});

import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const root = dirname(fileURLToPath(import.meta.url));
const host = process.env.HOST ?? '0.0.0.0';
const port = Number.parseInt(process.env.PORT ?? '8000', 10);
const usageApiUrl = process.env.USAGE_API_URL ?? 'https://chatgpt.com/backend-api/wham/usage';
const resetRequestsApiUrl = process.env.RESET_REQUESTS_API_URL ?? 'https://codex-resets.com/api/reset-requests';
const authFile = process.env.CODEX_AUTH_FILE ?? join(homedir(), '.codex', 'auth.json');
const dashboardApiKey = process.env.DASHBOARD_API_KEY;

export function normalizeUsage(payload) {
  const rateLimit = payload?.rate_limit ?? payload ?? {};
  const primary = rateLimit.primary_window ?? payload?.primary_window ?? {};
  const secondary = rateLimit.secondary_window ?? payload?.secondary_window ?? null;
  const used = Number(primary.used_percent ?? payload?.used_percent ?? 0);
  const secondaryUsed = secondary?.used_percent ?? payload?.weekly_used_percent;

  return {
    remainingPercent: clamp(100 - used),
    weeklyRemainingPercent: secondaryUsed == null ? null : clamp(100 - Number(secondaryUsed)),
    resetAt: primary.reset_at ?? payload?.reset_at ?? null,
    weeklyResetAt: secondary?.reset_at ?? payload?.weekly_reset_at ?? null,
    primaryWindowSeconds: primary.limit_window_seconds ?? null,
    secondaryWindowSeconds: secondary?.limit_window_seconds ?? null,
    plan: payload?.plan_type ?? payload?.plan ?? null,
    limitReached: Boolean(rateLimit.limit_reached ?? payload?.limit_reached)
  };
}

function clamp(value) {
  return Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0;
}

function sendJson(response, status, body) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  response.end(JSON.stringify(body));
}

export function isApiKeyAuthorized(expected, received) {
  if (typeof expected !== 'string' || !expected || typeof received !== 'string') return false;
  const expectedBuffer = Buffer.from(expected);
  const receivedBuffer = Buffer.from(received);
  return expectedBuffer.length === receivedBuffer.length && timingSafeEqual(expectedBuffer, receivedBuffer);
}

export function credentialsFromAuth(auth) {
  const accessToken = auth?.tokens?.access_token;
  const accountId = auth?.tokens?.account_id;
  if (typeof accessToken !== 'string' || !accessToken || /[\r\n]/.test(accessToken)) {
    throw new Error('No valid Codex access token was found. Sign in to Codex first.');
  }
  if (typeof accountId !== 'string' || !accountId || /[\r\n]/.test(accountId)) {
    throw new Error('No valid Codex account ID was found. Sign in to Codex first.');
  }
  return { accessToken, accountId };
}

export function normalizeResetRequests(payload) {
  const lastResetAt = payload?.since;
  if (typeof lastResetAt !== 'string' || !Number.isFinite(Date.parse(lastResetAt))) {
    throw new Error('The reset request service returned an invalid reset date.');
  }
  return { lastResetAt };
}

async function fetchResetRequests() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const upstream = await fetch(resetRequestsApiUrl, {
      headers: { Accept: 'application/json' },
      redirect: 'error',
      signal: controller.signal
    });
    if (!upstream.ok) throw new Error(`Reset request service returned HTTP ${upstream.status}.`);
    return normalizeResetRequests(await upstream.json());
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchUsage() {
  const credentials = credentialsFromAuth(JSON.parse(await readFile(authFile, 'utf8')));

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const upstream = await fetch(usageApiUrl, {
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${credentials.accessToken}`,
        'ChatGPT-Account-Id': credentials.accountId
      },
      redirect: 'error',
      signal: controller.signal
    });
    if (!upstream.ok) throw new Error(`Quota service returned HTTP ${upstream.status}.`);
    return normalizeUsage(await upstream.json());
  } finally {
    clearTimeout(timeout);
  }
}

export function createServer() {
  return http.createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (url.pathname.startsWith('/api/')) {
      if (!dashboardApiKey) {
        sendJson(response, 503, { error: 'DASHBOARD_API_KEY is not configured on the server.' });
        return;
      }
      if (!isApiKeyAuthorized(dashboardApiKey, request.headers['x-api-key'])) {
        sendJson(response, 401, { error: 'A valid X-API-KEY header is required.' });
        return;
      }
    }

    if (request.method === 'GET' && url.pathname === '/api/usage') {
      try {
        sendJson(response, 200, await fetchUsage());
      } catch (error) {
        sendJson(response, 502, { error: error.message });
      }
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/reset-requests') {
      try {
        sendJson(response, 200, await fetchResetRequests());
      } catch (error) {
        sendJson(response, 502, { error: error.message });
      }
      return;
    }

    if (request.method === 'GET' && (url.pathname === '/' || url.pathname === '/app.js' || url.pathname === '/styles.css')) {
      const files = { '/': 'index.html', '/app.js': 'app.js', '/styles.css': 'styles.css' };
      const types = { '/': 'text/html; charset=utf-8', '/app.js': 'text/javascript; charset=utf-8', '/styles.css': 'text/css; charset=utf-8' };
      try {
        response.writeHead(200, { 'Content-Type': types[url.pathname], 'Cache-Control': 'no-store' });
        response.end(await readFile(join(root, 'public', files[url.pathname])));
      } catch {
        response.writeHead(500).end('Unable to load the dashboard.');
      }
      return;
    }
    response.writeHead(404).end('Not found');
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  createServer().listen(port, host, () => console.log(`Quota dashboard listening on http://${host}:${port}`));
}

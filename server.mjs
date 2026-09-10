import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(fileURLToPath(import.meta.url));
const port = Number.parseInt(process.env.PORT ?? '3000', 10);
const usageApiUrl = process.env.USAGE_API_URL;
const usageApiKey = process.env.USAGE_API_KEY;

export function normalizeUsage(payload) {
  const rateLimit = payload?.rate_limit ?? payload ?? {};
  const primary = rateLimit.primary_window ?? payload?.primary_window ?? {};
  const secondary = rateLimit.secondary_window ?? payload?.secondary_window ?? {};
  const used = Number(primary.used_percent ?? payload?.used_percent ?? 0);
  const weeklyUsed = Number(secondary.used_percent ?? payload?.weekly_used_percent ?? 0);

  return {
    remainingPercent: clamp(100 - used),
    weeklyRemainingPercent: clamp(100 - weeklyUsed),
    resetAt: primary.reset_at ?? payload?.reset_at ?? null,
    weeklyResetAt: secondary.reset_at ?? payload?.weekly_reset_at ?? null,
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

async function fetchUsage() {
  if (!usageApiUrl || !usageApiKey) {
    throw new Error('USAGE_API_URL and USAGE_API_KEY must be set on the server.');
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const upstream = await fetch(usageApiUrl, {
      headers: { Accept: 'application/json', 'X-API-KEY': usageApiKey },
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
    if (request.method === 'GET' && url.pathname === '/api/usage') {
      try {
        sendJson(response, 200, await fetchUsage());
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
  createServer().listen(port, () => console.log(`Quota dashboard available at http://localhost:${port}`));
}

import assert from 'node:assert/strict';
import test from 'node:test';
import { credentialsFromAuth, isApiKeyAuthorized, normalizeResetRequests, normalizeUsage } from '../server.mjs';

test('normalizes the documented WHAM response shape', () => {
  assert.deepEqual(normalizeUsage({
    plan_type: 'plus',
    rate_limit: {
      limit_reached: false,
      primary_window: { used_percent: 29, reset_at: 1730000000 },
      secondary_window: { used_percent: 12, reset_at: 1730500000 }
    }
  }), {
    remainingPercent: 71,
    weeklyRemainingPercent: 88,
    resetAt: 1730000000,
    weeklyResetAt: 1730500000,
    primaryWindowSeconds: null,
    secondaryWindowSeconds: null,
    plan: 'plus',
    limitReached: false
  });
});

test('clamps an invalid percentage to the gauge range', () => {
  assert.equal(normalizeUsage({ used_percent: 130 }).remainingPercent, 0);
});

test('does not invent a secondary window when Codex returns null', () => {
  const usage = normalizeUsage({
    rate_limit: {
      primary_window: { used_percent: 10, limit_window_seconds: 604800 },
      secondary_window: null
    }
  });
  assert.equal(usage.weeklyRemainingPercent, null);
  assert.equal(usage.primaryWindowSeconds, 604800);
});

test('reads Codex credentials without returning unrelated auth data', () => {
  assert.deepEqual(credentialsFromAuth({
    tokens: { access_token: 'token', account_id: 'account', refresh_token: 'secret' }
  }), { accessToken: 'token', accountId: 'account' });
});

test('rejects missing credentials and header injection', () => {
  assert.throws(() => credentialsFromAuth({}), /access token/);
  assert.throws(() => credentialsFromAuth({
    tokens: { access_token: 'token\r\nX-Evil: yes', account_id: 'account' }
  }), /access token/);
});

test('validates the last reset date returned by the public service', () => {
  assert.deepEqual(normalizeResetRequests({ since: '2026-09-09T18:23:34.000Z' }), {
    lastResetAt: '2026-09-09T18:23:34.000Z'
  });
  assert.throws(() => normalizeResetRequests({ since: 'not-a-date' }), /invalid reset date/);
});

test('compares dashboard API keys exactly', () => {
  assert.equal(isApiKeyAuthorized('secret', 'secret'), true);
  assert.equal(isApiKeyAuthorized('secret', 'wrong'), false);
  assert.equal(isApiKeyAuthorized('secret', undefined), false);
});

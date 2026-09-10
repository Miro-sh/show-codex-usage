import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeUsage } from '../server.mjs';

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
    plan: 'plus',
    limitReached: false
  });
});

test('clamps an invalid percentage to the gauge range', () => {
  assert.equal(normalizeUsage({ used_percent: 130 }).remainingPercent, 0);
});

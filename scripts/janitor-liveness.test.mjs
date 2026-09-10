// Unit tests for the pure logic in janitor-liveness.mjs
//
// Run with: node --test scripts/*.test.mjs
// (NOT `node --test scripts/` — on Node >= 26 that resolves `scripts` as a
// module and dies with MODULE_NOT_FOUND. github-activity-notifier.test.mjs
// still documents the old form in its header; see PR notes.)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  hoursSince,
  parseBacklogTimestamp,
  assessLiveness,
  formatAge,
  buildSlackMessage,
} from './janitor-liveness.mjs';

const NOW = new Date('2026-08-17T13:00:00Z');

test('hoursSince: normal, missing, unparseable', () => {
  assert.equal(hoursSince('2026-08-17T01:00:00Z', NOW), 12);
  assert.equal(hoursSince(null, NOW), Infinity);
  assert.equal(hoursSince('not-a-date', NOW), Infinity);
});

test('formatAge: sub-hour, hours, days', () => {
  assert.equal(formatAge(0.4), '<1h');
  assert.equal(formatAge(12), '12h');
  assert.equal(formatAge(27 * 24), '27d');
  assert.equal(formatAge(50), '2d 2h');
  assert.equal(formatAge(Infinity), 'never');
});

test('parseBacklogTimestamp: present, absent, missing file, garbage stamp', () => {
  assert.equal(
    parseBacklogTimestamp('# Backlog\n\n_Last updated: 2026-08-17T12:00Z_\n'),
    '2026-08-17T12:00Z',
  );
  assert.equal(parseBacklogTimestamp('# Backlog\n\nno stamp here'), null);
  assert.equal(parseBacklogTimestamp(null), null);
  assert.equal(parseBacklogTimestamp('_Last updated: banana_'), null);
});

// --- The regression this whole script exists for -------------------------

test('REGRESSION: the real 2026-07-21 -> 2026-08-17 outage is caught as `disabled`', () => {
  // dependabot-janitor was disabled_manually on 2026-07-21 and nothing noticed
  // for 27 days. It produced zero FAILED runs in that window, because it
  // produced zero runs at all — so every failure-watching signal stayed silent.
  const a = assessLiveness({
    workflowState: 'disabled_manually',
    lastRunAt: '2026-07-21T13:32:07Z',
    backlogUpdatedAt: null,
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'disabled');
  assert.ok(a.hoursQuiet > 27 * 24 - 1, 'should report ~27 days quiet');
  assert.match(a.reasons[0], /disabled_manually/);
  assert.match(a.reasons[0], /26d|27d/);
});

test('REGRESSION: missing backlog artifact is alertable, not silently OK', () => {
  // dependabot-backlog.md has never been committed to main (404), despite
  // dependabot-janitor.sh naming a downstream weekly digest routine as its
  // consumer. A healthy-looking janitor with no artifact is still broken.
  const a = assessLiveness({
    workflowState: 'active',
    lastRunAt: '2026-08-17T12:00:00Z', // ran an hour ago — looks fine
    backlogUpdatedAt: null, // ...but wrote nothing
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'stale-artifact');
  assert.match(a.reasons[0], /missing or has no parseable/);
});

// --- State classification ------------------------------------------------

test('assessLiveness: active and recent -> ok', () => {
  const a = assessLiveness({
    workflowState: 'active',
    lastRunAt: '2026-08-17T01:00:00Z',
    backlogUpdatedAt: '2026-08-17T01:00:00Z',
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'ok');
  assert.deepEqual(a.reasons, []);
});

test('assessLiveness: active but past threshold -> stalled (a breakage)', () => {
  const a = assessLiveness({
    workflowState: 'active',
    lastRunAt: '2026-08-14T13:00:00Z', // 72h
    backlogUpdatedAt: '2026-08-14T13:00:00Z',
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'stalled');
  assert.match(a.reasons[0], /active but has not completed a run/);
});

test('assessLiveness: disabled outranks stalled (decision vs breakage)', () => {
  // Both conditions are true; the message must say WHY, and "someone turned it
  // off" is actionable in a way that "it stopped" is not.
  const a = assessLiveness({
    workflowState: 'disabled_manually',
    lastRunAt: '2026-06-01T00:00:00Z',
    backlogUpdatedAt: null,
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'disabled');
});

test('assessLiveness: disabled_inactivity (GitHub 60-day auto-disable) is caught', () => {
  const a = assessLiveness({
    workflowState: 'disabled_inactivity',
    lastRunAt: '2026-06-01T00:00:00Z',
    backlogUpdatedAt: null,
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'disabled');
  assert.match(a.reasons[0], /disabled_inactivity/);
});

test('assessLiveness: never-run active workflow is stalled, not ok', () => {
  const a = assessLiveness({
    workflowState: 'active',
    lastRunAt: null,
    backlogUpdatedAt: null,
    now: NOW,
    staleHours: 36,
  });
  assert.equal(a.state, 'stalled');
  assert.match(a.reasons[0], /never completed a run/);
});

test('assessLiveness: staleHours is honoured as a boundary', () => {
  const base = {
    workflowState: 'active',
    backlogUpdatedAt: '2026-08-17T12:00:00Z',
    now: NOW,
  };
  // 35h quiet under a 36h threshold → ok
  assert.equal(
    assessLiveness({ ...base, lastRunAt: '2026-08-16T02:00:00Z', staleHours: 36 }).state,
    'ok',
  );
  // same 35h under a 12h threshold → stalled
  assert.equal(
    assessLiveness({ ...base, lastRunAt: '2026-08-16T02:00:00Z', staleHours: 12 }).state,
    'stalled',
  );
});

// --- Message rendering ---------------------------------------------------

test('buildSlackMessage: includes reason, queue depth, and a link', () => {
  const a = assessLiveness({
    workflowState: 'disabled_manually',
    lastRunAt: '2026-07-21T13:32:07Z',
    backlogUpdatedAt: null,
    now: NOW,
  });
  const msg = buildSlackMessage(a, {
    org: 'wyre-technology',
    repo: '.github',
    workflowFile: 'dependabot-janitor.yml',
    openPrCount: 241,
  });
  assert.match(msg, /disabled/i);
  assert.match(msg, /241 open Dependabot PRs/);
  assert.match(msg, /actions\/workflows\/dependabot-janitor\.yml/);
});

test('buildSlackMessage: omits queue line when the count is unavailable', () => {
  const a = assessLiveness({
    workflowState: 'active',
    lastRunAt: '2026-08-10T13:00:00Z',
    backlogUpdatedAt: null,
    now: NOW,
  });
  const msg = buildSlackMessage(a, {
    org: 'wyre-technology',
    repo: '.github',
    workflowFile: 'dependabot-janitor.yml',
    openPrCount: undefined,
  });
  assert.doesNotMatch(msg, /queued behind it/);
});

// --- Alert escalation policy (awaiting implementation) -------------------

test('shouldAlert: fires the first time a non-ok state appears', { todo: true }, () => {});

test(
  'shouldAlert: does not post identically on every run for 27 days straight',
  { todo: true },
  () => {},
);

test('shouldAlert: never goes permanently silent while the state is non-ok', { todo: true }, () => {});

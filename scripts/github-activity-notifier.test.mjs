// Unit tests for the pure logic in github-activity-notifier.mjs
// Run with: node --test scripts/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseExcludeList,
  isExcludedAuthor,
  classify,
  repoFullName,
  selectNewItems,
  pruneNotified,
  renderSlackPayload,
  buildSearchQuery,
  isoSecondsAgo,
} from './github-activity-notifier.mjs';

test('parseExcludeList always includes asachs01 and lowercases extras', () => {
  const s = parseExcludeList('Foo, BAR ');
  assert.ok(s.has('asachs01'));
  assert.ok(s.has('foo'));
  assert.ok(s.has('bar'));
});

test('isExcludedAuthor: bots, self (case-insensitive), missing, allowed', () => {
  const s = parseExcludeList('');
  assert.equal(isExcludedAuthor('dependabot[bot]', s), true);
  assert.equal(isExcludedAuthor('renovate[bot]', s), true);
  assert.equal(isExcludedAuthor('asachs01', s), true);
  assert.equal(isExcludedAuthor('Asachs01', s), true);
  assert.equal(isExcludedAuthor('', s), true);
  assert.equal(isExcludedAuthor('octocat', s), false);
});

test('classify distinguishes PRs from issues', () => {
  assert.equal(classify({ pull_request: { url: 'x' } }), 'pr');
  assert.equal(classify({}), 'issue');
});

test('repoFullName extracts owner/repo from repository_url', () => {
  assert.equal(
    repoFullName({ repository_url: 'https://api.github.com/repos/wyre-technology/foo-mcp' }),
    'wyre-technology/foo-mcp'
  );
  assert.equal(repoFullName({}), 'unknown/unknown');
});

test('selectNewItems filters excluded + already-notified and sorts ascending', () => {
  const s = parseExcludeList('');
  const items = [
    { node_id: 'C', user: { login: 'octocat' }, created_at: '2026-06-30T12:30:00Z' },
    { node_id: 'A', user: { login: 'dependabot[bot]' }, created_at: '2026-06-30T12:00:00Z' },
    { node_id: 'B', user: { login: 'asachs01' }, created_at: '2026-06-30T12:10:00Z' },
    { node_id: 'D', user: { login: 'hubber' }, created_at: '2026-06-30T12:05:00Z' },
    { node_id: 'E', user: { login: 'seen-user' }, created_at: '2026-06-30T12:20:00Z' },
  ];
  const notified = { E: '2026-06-30T12:20:00Z' };
  const out = selectNewItems(items, notified, s);
  assert.deepEqual(out.map((i) => i.node_id), ['D', 'C']);
});

test('pruneNotified drops entries older than ttl', () => {
  const now = Date.parse('2026-06-30T14:00:00Z');
  const notified = {
    old: '2026-06-30T10:00:00Z', // 4h ago
    fresh: '2026-06-30T13:30:00Z', // 30m ago
  };
  const out = pruneNotified(notified, now, 2 * 60 * 60_000); // ttl 2h
  assert.deepEqual(Object.keys(out), ['fresh']);
});

test('renderSlackPayload: PR icon, link, escaped title', () => {
  const pr = renderSlackPayload({
    pull_request: {},
    number: 42,
    title: 'Fix <stuff> & things',
    html_url: 'https://github.com/wyre-technology/foo/pull/42',
    user: { login: 'octocat' },
    repository_url: 'https://api.github.com/repos/wyre-technology/foo',
  });
  const block = pr.blocks[0].text.text;
  assert.match(pr.text, /New PR/);
  assert.match(block, /🔀/);
  assert.match(block, /wyre-technology\/foo/);
  assert.match(block, /octocat/);
  assert.match(block, /pull\/42/);
  assert.match(block, /&lt;stuff&gt; &amp; things/);
});

test('renderSlackPayload: issue icon', () => {
  const issue = renderSlackPayload({
    number: 7,
    title: 'Bug',
    html_url: 'https://github.com/wyre-technology/foo/issues/7',
    user: { login: 'reporter' },
    repository_url: 'https://api.github.com/repos/wyre-technology/foo',
  });
  assert.match(issue.blocks[0].text.text, /🐛/);
  assert.match(issue.text, /New Issue/);
});

test('buildSearchQuery and isoSecondsAgo format correctly', () => {
  assert.equal(
    buildSearchQuery('wyre-technology', '2026-06-30T13:00:00Z'),
    'org:wyre-technology created:>=2026-06-30T13:00:00Z'
  );
  assert.equal(isoSecondsAgo(Date.parse('2026-06-30T14:00:00.500Z'), 60), '2026-06-30T13:00:00Z');
});

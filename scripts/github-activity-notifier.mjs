#!/usr/bin/env node
// github-activity-notifier.mjs
//
// Polls the wyre-technology org for newly opened issues/PRs and posts each one
// to the #github-activity Slack channel. Excludes any "[bot]" account
// (Dependabot, Renovate, github-actions, ...) and the logins in EXCLUDE_AUTHORS
// (asachs01 is always excluded).
//
// No external dependencies — uses Node's global fetch (Node >= 18).
//
// Detection uses a rolling LOOKBACK window over the GitHub Search API. A small
// committed state file (notified node_ids) provides de-duplication and
// at-least-once delivery, and lets the wider window absorb search-index lag.
//
// Env:
//   GITHUB_TOKEN                       (required) token for the Search API
//   SLACK_GITHUB_ACTIVITY_WEBHOOK_URL  (required unless DRY_RUN) Slack webhook
//   DRY_RUN            "1"/"true" → log intended posts, write nothing
//   LOOKBACK_MINUTES   search window in minutes (default 60)
//   EXCLUDE_AUTHORS    extra comma-separated logins to exclude
//   STATE_FILE         path to state json (default .github/github-activity-state.json)
//   ORG                org to watch (default wyre-technology)

import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const ORG = process.env.ORG || 'wyre-technology';
const API = 'https://api.github.com';
const ALWAYS_EXCLUDE = ['asachs01'];

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in github-activity-notifier.test.mjs)
// ---------------------------------------------------------------------------

export function parseExcludeList(extra) {
  const fromEnv = (extra || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return new Set([...ALWAYS_EXCLUDE.map((s) => s.toLowerCase()), ...fromEnv]);
}

export function isExcludedAuthor(login, excludeSet) {
  if (!login) return true; // ghost / deleted author → skip
  const l = login.toLowerCase();
  if (l.endsWith('[bot]')) return true;
  return excludeSet.has(l);
}

export function classify(item) {
  return item && item.pull_request ? 'pr' : 'issue';
}

export function repoFullName(item) {
  // Search results carry repository_url: https://api.github.com/repos/OWNER/REPO
  const m = /\/repos\/([^/]+\/[^/]+)$/.exec((item && item.repository_url) || '');
  return m ? m[1] : 'unknown/unknown';
}

export function selectNewItems(items, notified, excludeSet) {
  const seen = new Set(Object.keys(notified || {}));
  return items
    .filter((it) => !isExcludedAuthor(it.user && it.user.login, excludeSet))
    .filter((it) => !seen.has(it.node_id))
    .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
}

export function pruneNotified(notified, now, ttlMs) {
  const out = {};
  for (const [id, createdAt] of Object.entries(notified || {})) {
    if (now - new Date(createdAt).getTime() < ttlMs) out[id] = createdAt;
  }
  return out;
}

export function escapeMrkdwn(s) {
  // Slack mrkdwn requires &, <, > to be HTML-entity escaped.
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function renderSlackPayload(item) {
  const type = classify(item);
  const icon = type === 'pr' ? '🔀' : '🐛';
  const label = type === 'pr' ? 'PR' : 'Issue';
  const repo = repoFullName(item);
  const login = (item.user && item.user.login) || 'unknown';
  const num = item.number;
  const title = item.title || '(no title)';
  const url = item.html_url;
  return {
    text: `${icon} New ${label} in ${repo} by ${login}: #${num} ${title}`,
    blocks: [
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text:
            `${icon} *New ${label}* in \`${repo}\` by \`${login}\`\n` +
            `<${url}|#${num} — ${escapeMrkdwn(title)}>`,
        },
      },
    ],
  };
}

export function buildSearchQuery(org, sinceIso) {
  return `org:${org} created:>=${sinceIso}`;
}

export function isoSecondsAgo(now, minutes) {
  return new Date(now - minutes * 60_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

async function loadState(path) {
  try {
    const data = JSON.parse(await readFile(path, 'utf8'));
    return { notified: data.notified || {} };
  } catch (e) {
    if (e.code === 'ENOENT') return { notified: {} };
    throw e;
  }
}

async function saveState(path, state) {
  await writeFile(path, JSON.stringify(state, null, 2) + '\n', 'utf8');
}

async function searchIssues(token, query) {
  const items = [];
  const perPage = 100;
  for (let page = 1; page <= 10; page++) {
    const url =
      `${API}/search/issues?q=${encodeURIComponent(query)}` +
      `&sort=created&order=asc&per_page=${perPage}&page=${page}`;
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'wyre-github-activity-notifier',
      },
    });
    if (!res.ok) {
      throw new Error(
        `GitHub search failed: ${res.status} ${res.statusText} — ${(await res.text()).slice(0, 300)}`
      );
    }
    const data = await res.json();
    const batch = data.items || [];
    items.push(...batch);
    if (batch.length < perPage) break;
  }
  return items;
}

async function postToSlack(webhook, payload) {
  const res = await fetch(webhook, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = (await res.text()).trim();
  if (!res.ok || body !== 'ok') {
    throw new Error(`Slack post failed: ${res.status} ${res.statusText} — ${body.slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const token = process.env.GITHUB_TOKEN;
  const webhook = process.env.SLACK_GITHUB_ACTIVITY_WEBHOOK_URL;
  const dryRun = /^(1|true)$/i.test(process.env.DRY_RUN || '');
  const lookback = Number(process.env.LOOKBACK_MINUTES || 60);
  const stateFile = process.env.STATE_FILE || '.github/github-activity-state.json';
  const excludeSet = parseExcludeList(process.env.EXCLUDE_AUTHORS);

  if (!token) throw new Error('GITHUB_TOKEN is required');
  if (!webhook && !dryRun) {
    throw new Error('SLACK_GITHUB_ACTIVITY_WEBHOOK_URL is required (or set DRY_RUN=1)');
  }

  const now = Date.now();
  const query = buildSearchQuery(ORG, isoSecondsAgo(now, lookback));
  console.log(`[notifier] searching: ${query} (dryRun=${dryRun})`);

  const state = await loadState(stateFile);
  const items = await searchIssues(token, query);
  const fresh = selectNewItems(items, state.notified, excludeSet);
  console.log(`[notifier] ${items.length} item(s) in window, ${fresh.length} new to notify`);

  if (dryRun) {
    for (const it of fresh) console.log(`[dry-run] would post: ${renderSlackPayload(it).text}`);
    console.log('[notifier] dry run — no Slack posts, state unchanged');
    return;
  }

  let failed = false;
  for (const it of fresh) {
    try {
      await postToSlack(webhook, renderSlackPayload(it));
      state.notified[it.node_id] = it.created_at;
      console.log(`[notifier] posted ${repoFullName(it)}#${it.number} by ${it.user.login}`);
    } catch (e) {
      failed = true;
      console.error(`[notifier] ${e.message}`);
      break; // stop; unposted items stay in-window and retry next run
    }
  }

  state.notified = pruneNotified(state.notified, now, lookback * 2 * 60_000);
  await saveState(stateFile, state);

  if (failed) {
    console.error('[notifier] completed with failure(s); state saved, exiting non-zero for retry');
    process.exit(1);
  }
  console.log('[notifier] done');
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  main().catch((e) => {
    console.error(e.stack || String(e));
    process.exit(1);
  });
}

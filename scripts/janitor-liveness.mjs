#!/usr/bin/env node
// janitor-liveness.mjs
//
// Deadman check for dependabot-janitor. Alerts when the janitor is not doing
// its job — whether because it failed, because its schedule stopped firing, or
// because it was disabled and forgotten.
//
// Why this exists: between 2026-07-21 and 2026-08-17 the janitor was
// `disabled_manually` and nothing noticed for 27 days, while the Dependabot
// backlog grew to 241 open PRs. It produced ZERO failed runs in that window,
// because it produced zero runs — so every failure-watching signal was silent
// by construction. This watches for ABSENCE, which is the failure mode that
// actually occurred.
//
// It also watches the backlog artifact: dependabot-janitor.sh writes
// dependabot-backlog.md for a downstream weekly digest routine, and that file
// has never been committed to main (404). A stale-or-missing artifact is the
// same class of silent failure one hop downstream.
//
// No external dependencies — Node's global fetch (Node >= 18).
//
// Env:
//   GITHUB_TOKEN     (required) token for the Actions + contents API
//   SLACK_WEBHOOK_URL(required unless DRY_RUN) Slack incoming webhook
//   DRY_RUN          "1"/"true" → log the intended post, send nothing
//   ORG              org (default wyre-technology)
//   REPO             repo holding the janitor (default .github)
//   WORKFLOW_FILE    janitor workflow filename (default dependabot-janitor.yml)
//   BACKLOG_PATH     backlog artifact path (default dependabot-backlog.md)
//   STALE_HOURS      hours without a run before alerting (default 36)
//   NOW              ISO timestamp override, for tests

import { fileURLToPath } from 'node:url';

const API = 'https://api.github.com';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in janitor-liveness.test.mjs)
// ---------------------------------------------------------------------------

/** Hours between an ISO timestamp and `now`. Null/invalid input → Infinity. */
export function hoursSince(iso, now) {
  if (!iso) return Infinity;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return Infinity;
  return (now.getTime() - t) / 3_600_000;
}

/**
 * Pull the `_Last updated: <ISO>_` stamp out of dependabot-backlog.md.
 * Returns null when the file is missing or carries no parseable stamp —
 * both of which are themselves alertable conditions.
 */
export function parseBacklogTimestamp(markdown) {
  if (!markdown) return null;
  const m = /_Last updated:\s*([0-9T:\-Z]+)_/i.exec(markdown);
  if (!m) return null;
  const t = Date.parse(m[1]);
  return Number.isNaN(t) ? null : m[1];
}

/**
 * Classify janitor health into one of four states. Pure — all inputs explicit.
 *
 * The `disabled` vs `stalled` split is load-bearing. A disabled janitor is a
 * DECISION someone made that has outlived its reason; a stalled one is a
 * BREAKAGE. They need different messages and different escalation, and
 * collapsing them is what let a 27-day gap read as normal.
 *
 * @returns {{state: 'ok'|'disabled'|'stalled'|'stale-artifact', reasons: string[], hoursQuiet: number}}
 */
export function assessLiveness({
  workflowState,
  lastRunAt,
  backlogUpdatedAt,
  now,
  staleHours = 36,
}) {
  const hoursQuiet = hoursSince(lastRunAt, now);
  const reasons = [];

  if (workflowState === 'disabled_manually' || workflowState === 'disabled_inactivity') {
    reasons.push(
      `Workflow is \`${workflowState}\`` +
        (Number.isFinite(hoursQuiet)
          ? ` — last run ${formatAge(hoursQuiet)} ago.`
          : ' — it has never run.'),
    );
    return { state: 'disabled', reasons, hoursQuiet };
  }

  if (hoursQuiet > staleHours) {
    reasons.push(
      Number.isFinite(hoursQuiet)
        ? `Workflow is active but has not completed a run in ${formatAge(hoursQuiet)} (threshold ${staleHours}h).`
        : 'Workflow is active but has never completed a run.',
    );
    return { state: 'stalled', reasons, hoursQuiet };
  }

  const backlogAge = hoursSince(backlogUpdatedAt, now);
  if (backlogAge > staleHours) {
    reasons.push(
      backlogUpdatedAt
        ? `Backlog artifact is ${formatAge(backlogAge)} stale (threshold ${staleHours}h).`
        : 'Backlog artifact is missing or has no parseable `_Last updated:_` stamp.',
    );
    return { state: 'stale-artifact', reasons, hoursQuiet };
  }

  return { state: 'ok', reasons, hoursQuiet };
}

/** "3h" / "2d 4h" / "never" — compact age for humans. */
export function formatAge(hours) {
  if (!Number.isFinite(hours)) return 'never';
  if (hours < 1) return '<1h';
  if (hours < 48) return `${Math.floor(hours)}h`;
  const d = Math.floor(hours / 24);
  const h = Math.floor(hours % 24);
  return h ? `${d}d ${h}h` : `${d}d`;
}

// ---------------------------------------------------------------------------
// Alert escalation policy
// ---------------------------------------------------------------------------

/**
 * Decide whether this run should actually post to Slack.
 *
 * TODO(aaron): implement. This is the judgment call — see the note in the PR.
 *
 * The tension: the janitor sat `disabled_manually` for 27 days. A check that
 * posts an identical message every 6 hours would have produced ~108 Slack
 * messages about a condition the team already knew about, and the predictable
 * result is a muted channel — which reproduces the original silent-absence
 * failure exactly, just with extra steps.
 *
 * But suppressing too aggressively is how 27 days passes unnoticed in the
 * first place. Something has to keep getting louder, or keep being visible,
 * without being ignorable.
 *
 * Inputs available to you:
 * @param {ReturnType<typeof assessLiveness>} assessment  current state + reasons
 * @param {number} runIndex  how many consecutive runs have seen this same
 *                           non-ok state (0 = first time it flipped)
 * @returns {boolean} true → post to Slack this run
 *
 * Some directions, none obviously right:
 *   - Backoff: alert on runs 0, 1, 2, then every Nth — quiet but never silent.
 *   - Escalating severity: same cadence, but the message gets more urgent with
 *     age ("disabled 2 days" → "disabled 3 WEEKS, 241 PRs queued").
 *   - Daily digest for `disabled`, immediate for `stalled` — treat a decision
 *     that's outliving its reason differently from a breakage.
 */
export function shouldAlert(assessment, runIndex) {
  throw new Error('shouldAlert() not implemented — see TODO above');
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

async function gh(path, token) {
  const res = await fetch(`${API}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'wyre-janitor-liveness',
    },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`GitHub ${res.status} on ${path}: ${await res.text()}`);
  return res.json();
}

export function buildSlackMessage(assessment, { org, repo, workflowFile, openPrCount }) {
  const icon = { disabled: '🔕', stalled: '💀', 'stale-artifact': '🥀' }[assessment.state] || '✅';
  const title = {
    disabled: 'Dependabot janitor is disabled',
    stalled: 'Dependabot janitor has stopped running',
    'stale-artifact': 'Dependabot backlog artifact is stale',
  }[assessment.state];

  const lines = [
    `${icon} *${title}*`,
    ...assessment.reasons.map((r) => `• ${r}`),
  ];
  if (typeof openPrCount === 'number') {
    lines.push(`• ${openPrCount} open Dependabot PRs are queued behind it.`);
  }
  lines.push(
    `<https://github.com/${org}/${repo}/actions/workflows/${workflowFile}|View workflow>`,
  );
  return lines.join('\n');
}

async function main() {
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error('GITHUB_TOKEN is required');

  const org = process.env.ORG || 'wyre-technology';
  const repo = process.env.REPO || '.github';
  const workflowFile = process.env.WORKFLOW_FILE || 'dependabot-janitor.yml';
  const backlogPath = process.env.BACKLOG_PATH || 'dependabot-backlog.md';
  const staleHours = Number(process.env.STALE_HOURS || 36);
  const dryRun = /^(1|true)$/i.test(process.env.DRY_RUN || '');
  const now = process.env.NOW ? new Date(process.env.NOW) : new Date();

  const wf = await gh(`/repos/${org}/${repo}/actions/workflows/${workflowFile}`, token);
  if (!wf) throw new Error(`Workflow ${workflowFile} not found in ${org}/${repo}`);

  const runs = await gh(
    `/repos/${org}/${repo}/actions/workflows/${workflowFile}/runs?status=completed&per_page=1`,
    token,
  );
  const lastRunAt = runs?.workflow_runs?.[0]?.updated_at || null;

  const backlogFile = await gh(
    `/repos/${org}/${repo}/contents/${backlogPath}`,
    token,
  );
  const backlogMd = backlogFile?.content
    ? Buffer.from(backlogFile.content, 'base64').toString('utf8')
    : null;

  const assessment = assessLiveness({
    workflowState: wf.state,
    lastRunAt,
    backlogUpdatedAt: parseBacklogTimestamp(backlogMd),
    now,
    staleHours,
  });

  console.log(`state=${assessment.state} quiet=${formatAge(assessment.hoursQuiet)}`);
  assessment.reasons.forEach((r) => console.log(`  - ${r}`));

  if (assessment.state === 'ok') {
    console.log('Janitor is healthy — nothing to report.');
    return;
  }

  const search = await gh(
    `/search/issues?q=${encodeURIComponent(`org:${org} is:pr is:open author:app/dependabot`)}&per_page=1`,
    token,
  );
  const text = buildSlackMessage(assessment, {
    org,
    repo,
    workflowFile,
    openPrCount: search?.total_count,
  });

  if (dryRun) {
    console.log('--- DRY RUN, not posting ---\n' + text);
    return;
  }
  const webhook = process.env.SLACK_WEBHOOK_URL;
  if (!webhook) throw new Error('SLACK_WEBHOOK_URL is required unless DRY_RUN');
  const res = await fetch(webhook, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) throw new Error(`Slack ${res.status}: ${await res.text()}`);
  console.log('Posted to Slack.');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
}

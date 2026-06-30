# GitHub Activity → Slack notifier

Posts a Slack message to **#github-activity** whenever a new issue or PR is
opened anywhere in the `wyre-technology` org by an external/non-excluded author.

## How it works

A scheduled GitHub Action (`.github/workflows/github-activity-notifier.yml`)
runs every ~15 minutes and:

1. Queries the GitHub Search API for issues/PRs **created** in the last
   `LOOKBACK_MINUTES` (default 60) across `org:wyre-technology`.
2. Drops anything authored by a `[bot]` account or by a login in the exclude
   list (`asachs01` is always excluded; add more via `EXCLUDE_AUTHORS`).
3. Skips anything already recorded in `.github/github-activity-state.json`.
4. Posts each remaining item to Slack, then commits the updated state file —
   **only when there was new activity**, so the repo isn't spammed with commits.

### Why a rolling window instead of a "last run" timestamp?

A 60-minute window (well wider than the 15-minute cadence) means the job
automatically catches up after a delayed or skipped run and absorbs the GitHub
Search API's indexing lag, while the `notified` state guarantees no duplicates.
Delivery is **at-least-once**: if a Slack post fails, that item stays in the
window and is retried on the next run.

## Scope

- **Public repos only.** The built-in `GITHUB_TOKEN` can read public search
  results org-wide, so no PAT is needed. To include private repos you'd add a
  fine-grained PAT / GitHub App token with org-wide `issues:read` +
  `pull_requests:read` and pass it as `GITHUB_TOKEN`.
- New repos are covered automatically (the search is org-scoped).
- Triggers on **opened** only — not reopened or edited.

## Configuration

| Setting | Where | Default |
|---------|-------|---------|
| Slack webhook | repo secret `SLACK_GITHUB_ACTIVITY_WEBHOOK_URL` | — (required) |
| Cadence | `schedule.cron` in the workflow | `*/15 * * * *` |
| Lookback window | `LOOKBACK_MINUTES` env in the workflow | `60` |
| Extra excluded authors | `EXCLUDE_AUTHORS` env (comma-separated) | _(none)_ |

### Setting the Slack webhook secret

```sh
printf '%s' '<incoming-webhook-url>' \
  | gh secret set SLACK_GITHUB_ACTIVITY_WEBHOOK_URL --repo wyre-technology/.github --app actions
```

## Testing

- **Unit tests** (pure logic, no network):
  ```sh
  node --test scripts/*.test.mjs
  ```
- **Dry run** against live GitHub (logs intended messages, posts nothing):
  ```sh
  GITHUB_TOKEN="$(gh auth token)" DRY_RUN=1 LOOKBACK_MINUTES=10080 \
    node scripts/github-activity-notifier.mjs
  ```
- **Manual run in CI:** Actions → *github-activity-notifier* → *Run workflow*
  (tick *dry_run* to validate without posting).

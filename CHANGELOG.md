# Changelog

All notable changes to this repository's org-level automation are documented
here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **`mcp-server-release.yml`**: added `pull-requests: write` to the `release`
  job's permissions. `@semantic-release/github`'s `success` step performs an
  `associatedPullRequests` GraphQL read to comment on PRs swept into a release;
  without this scope the read returns `FORBIDDEN` and throws, which reliably
  fails a repo's *first* release (it sweeps many already-merged PRs). Observed
  live on `pax8-mcp` and previously worked around per-repo with
  `successComment: false`; this is the durable fleet fix.

  **Required follow-up (caller repos):** a reusable workflow can only reduce,
  never expand, the caller's granted permissions, so every `*-mcp` thin caller
  (`.github/workflows/release.yml`) must also add `pull-requests: write` to the
  `permissions:` block on the job that invokes this reusable. Until a caller
  adds it, its `release` job still runs without the scope. Callers already list
  `contents/issues/packages/id-token/security-events`; add `pull-requests: write`
  alongside them.

### Added

- **`github-activity-notifier`** workflow + script: posts newly opened
  issues/PRs across the `wyre-technology` org to the #github-activity Slack
  channel. Excludes `[bot]` accounts and `asachs01` (extendable via
  `EXCLUDE_AUTHORS`), de-duplicates via `.github/github-activity-state.json`,
  and runs every 15 minutes. Public repos only; uses the built-in
  `GITHUB_TOKEN`. See `docs/github-activity-notifier.md`.

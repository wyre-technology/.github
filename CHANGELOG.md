# Changelog

All notable changes to this repository's org-level automation are documented
here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`github-activity-notifier`** workflow + script: posts newly opened
  issues/PRs across the `wyre-technology` org to the #github-activity Slack
  channel. Excludes `[bot]` accounts and `asachs01` (extendable via
  `EXCLUDE_AUTHORS`), de-duplicates via `.github/github-activity-state.json`,
  and runs every 15 minutes. Public repos only; uses the built-in
  `GITHUB_TOKEN`. See `docs/github-activity-notifier.md`.

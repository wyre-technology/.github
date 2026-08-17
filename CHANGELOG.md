# Changelog

All notable changes to this repository's org-level automation are documented
here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **`dependabot-janitor.sh`**: `classify()` no longer treats the word "group" in
  a PR title as proof that the PR is minor/patch. It now parses the body's
  per-dependency `Updates \`pkg\` from A to B` markers and requires **every** one
  to be same-major, failing closed on any cross-major, unparseable marker, zero
  markers, or failed body fetch. Supersedes #23, rebased onto post-#36/#38 `main`.

  **This was live, not theoretical.** Measured against the current backlog on
  2026-08-17: of the 118 PRs a dry run would merge, 108 are grouped, and **69 of
  those 108 (64%) contain at least one cross-major bump**, across 62 repos. The
  blanket shortcut would have merged every one of them without inspecting a
  single dependency.

  `is_dev_major`'s allowlist is **not** a defence here — `classify()` returns
  `ELIGIBLE` for grouped PRs *before* the dev-major check runs, so the grouped
  path was strictly more permissive than the single-package path it sits beside.
  Two of the 69 carry a genuinely runtime, non-allowlisted major:
  `ironscales-mcp#38` and `salesbuildr-mcp#55`, both bumping the Docker base
  image `node` from `22-alpine` to `26-alpine` — four majors, straight to
  production on merge.

  This is the same hole that broke `main` via `node-datto-rmm#46` on 2026-07-21.
  #36 responded with a downstream guard, but only for grouped PRs with *no* CI;
  a grouped PR with *green* CI still rode the title shortcut untouched.

  Two changes beyond #23 as authored:
  - **Body fetch moved from `gh pr view` (GraphQL) to `gh api` (REST).**
    Fail-closed is right for a corrupt body, but during a GraphQL outage *every*
    grouped PR would fail closed and the whole backlog would stall behind a
    dependency the classifier does not need. Observed live on 2026-08-17: GraphQL
    returned 503 for hours while REST stayed healthy, making 40 of 108 PRs
    unclassifiable under `gh pr view` and 0 of 108 under `gh api`.
  - **Version-capture regex uses `[^[:space:]]`, not `[^\`[:space:]]`.** Inside a
    bracket expression the latter is the literal set `` { ` [ : s p a c e ] } ``,
    which does not exclude whitespace, so the capture runs greedy across `" to "`
    and yields nothing. A scan built on that construct — run under macOS
    `/bin/bash` 3.2, where `BASH_REMATCH` additionally never populated —
    reported all 108 grouped PRs clean. That false negative is what initially
    mis-classified this hole as latent. `dependabot-janitor.test.sh` now refuses
    to run unless a known-cross-major probe parses first.

  Adds `.github/scripts/dependabot-janitor.test.sh` — 14 assertions, fixtures
  taken from real Dependabot bodies (`abnormal-mcp#50`, `salesbuildr-mcp#55`)
  rather than invented shapes.

- **`mcp-server-release.yml`**: the digest-verification check tested the wrong
  key casing and rejected every legitimate single-platform image. The payload is
  a marshalled OCI image config, whose top-level key is lowercase `config` (with
  a capitalised `Env` nested inside) — `docker image inspect`, a *different*
  command, is what returns capitalised `Config`, and that is the trap. Testing
  `has("Config")` sent every single-platform build down the platform-map branch,
  so the check iterated the wrong values and hard-failed. Blocked `autotask-mcp`
  v2.32.5's deploy; the rejected digest was confirmed by hand against GHCR to be
  a genuine OCI image manifest (image config + 12 layers), not an attestation.
  The check now accepts either casing and is verified against the real config
  blob rather than hand-written fixtures — the previous revision was tested only
  against invented shapes that encoded the same wrong assumption.
  - Also adds failure-time diagnostics: on rejection the step now prints the
    `.Image` payload it actually saw. Without it, diagnosing a false positive
    means pulling the manifest out of the registry by hand, which is what this
    one cost.

- **`mcp-server-release.yml`**: the digest-verification step added in #40 used
  an invalid `--format` template and failed every run it was reached in.
  `docker buildx imagetools inspect --format` exposes exactly three fields —
  `.Name`, `.Manifest`, `.Image` — and no top-level `.Config`, so
  `'{{json .Config}}'` aborts with `template: :1:7: executing "" at <.Config>:
  can't evaluate field Config in type image`. The image config lives under
  `.Image`. Caught live on `autotask-mcp` v2.32.4, the first release to reach
  this step after #40 landed: the image built and pushed to GHCR correctly, but
  the verification failure failed the `docker` job and cascaded `mcp-registry`,
  `security` and the caller's `deploy` to skipped — so a good image never
  reached production. Every repo would have hit this on its next pin bump.
  - Also fixes a latent multi-arch bug in the same check: `.Image` is the config
    object for a single-platform build but a **platform-keyed map** for a
    multi-arch one, so even the corrected `.Image.Config` would fail for any
    caller passing a comma-separated `platforms:`. The check now normalises both
    shapes to a list and requires *every* platform to carry a non-empty
    `Config.Env`, so a multi-arch build cannot pass on one good platform alone.
    Verified against all three manifest shapes (single-platform, multi-platform,
    and a bare attestation-manifest config, which is still correctly rejected).

- **`mcp-server-release.yml`**: restored packing and uploading of the Claude
  Desktop `.mcpb` bundle as a GitHub release asset, via a new `mcpb` job. The
  hand-rolled per-repo workflows this reusable replaced each carried a "Pack and
  upload MCPB bundle" step; it was not carried over, so every repo that migrated
  silently stopped attaching its bundle while its README still told users to
  "download the `.mcpb` from the latest release". Fleet audit on 2026-08-13:
  **25 of the 26 repos with a `pack:mcpb` script publish releases with zero
  assets**; only `itglue-mcp` still ships one, through a repo-local stopgap job
  whose own comment asks for exactly this upstreaming. Reported as
  `autotask-mcp#244` (last bundle `v2.28.8`, first empty release `v2.30.0`,
  regressed by that repo's centralization PR #183).

  The job is **auto-detected** from the presence of a `pack:mcpb` script rather
  than gated on a new input, so affected repos recover by bumping their pin
  alone — no PR against 25 callers. Repos without the script no-op in seconds.
  It `needs: [release]` only, never `docker`, so a pack failure cannot cascade
  into skipping `mcp-registry`/`security`/`deploy`: by that point the release is
  already tagged and published, and a missing bundle is a much smaller problem
  than a missing deploy.

  **Version stamping is load-bearing.** Pack scripts copy `package.json`'s
  version into the bundle's `manifest.json`, but semantic-release does not
  commit its bump back (no `@semantic-release/git`), so `package.json` at the
  release tag still holds the *previous* version. Verified live against
  `autotask-mcp` at `v2.32.2`: packing the tag as-is produces a bundle stamped
  `2.18.0` — the version `main` has been frozen at for 14 releases — while
  stamping first produces the correct `2.32.2`. Without the
  `npm version --no-git-tag-version` step this job would ship a
  plausible-looking but wrongly-versioned bundle, which is worse than shipping
  none. No caller permission changes are required: the job requests
  `contents: write` + `packages: read`, both already granted by existing thin
  callers.

- **`mcp-server-release.yml`**: pinned `provenance: false` on the
  `docker/build-push-action` step and added a digest-resolution verification
  step (`imagetools inspect` + hard-fail on empty `Config.Env`) before handing
  the digest to any caller. Root cause: `docker/build-push-action`'s default
  SLSA provenance attestation adds an `attestation-manifest` sibling to the
  pushed image index, and `steps.push.outputs.digest` can nondeterministically
  resolve to that attestation manifest instead of the real image. This shipped
  attestation-manifest digests as the "image" for `blumira-mcp`, `mimecast-mcp`,
  and `timezest-mcp`'s 2026-07-23 release runs — Azure Container Apps then
  looped forever on `ImagePullFailure`/`ContainerCreateFailure` trying to
  unpack a JSON blob as a container, a silent ~2.5-day outage across all 3
  before an unrelated audit caught it. `provenance: false` removes the failure
  mode at the source; the verification step is defense-in-depth against any
  other manifest-shape surprise (index-with-no-matching-platform, a different
  attestation type, etc.) reaching a caller's deploy job undetected.

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

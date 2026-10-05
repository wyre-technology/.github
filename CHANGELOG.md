# Changelog

All notable changes to this repository's org-level automation are documented
here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`docs/fleet-triage.md`**: design for a scheduled Claude routine covering the
  org-wide PR/issue automation that `dependabot-janitor` does not — liveness,
  issues, non-Dependabot PRs, the code-owner-blocked backlog, release
  decoupling, and agent-authored fixes. Explicitly *not* a second merge policy:
  Dependabot merging stays `dependabot-janitor.sh`'s job and the routine
  consumes its output buckets rather than re-classifying.

  Written after a survey on 2026-08-17 found two silent absence-of-signal
  failures running concurrently: `dependabot-janitor` has been
  `disabled_manually` since 2026-07-21 (27 days, 241 open Dependabot PRs) with
  nothing alerting on the gap, and `dependabot-backlog.md` — which
  `dependabot-janitor.sh` writes and whose comments name a downstream weekly
  digest routine as its consumer — **404s on `main`** and has never been
  committed. Neither is reachable by hardening the merge policy, which is where
  all prior effort went (#28, #36, #38, #23), so liveness is component 1.

  The survey also found, against `main`:
  - `required_status_checks` is `NULL` on **20/20** sampled `*-mcp` repos, so
    CI passing is enforced nowhere at the branch level. The janitor's
    `gh pr checks` read is the only CI gate in the system, and it has been
    wrong twice (#36, #38) with no defense in depth behind it.
  - **#23 is an unclosed but currently-latent hole.** `classify()` retains the
    blanket `grep -qiE '\bgroup\b' -> ELIGIBLE` title shortcut; #36 added only
    a downstream guard for grouped PRs with *no* CI, so a grouped PR with
    *green* CI still auto-merges on a title match. Measured: of the 118 PRs a
    dry run would merge, 108 are grouped, and parsing every dependency out of
    all 108 bodies found **0 cross-major and 0 unparseable** bumps — the groups
    are update-type-scoped today, so the shortcut returns the right answer for
    the wrong reason. Worth rebasing onto post-#36/#38 `main` as defence in
    depth; not a blocker for re-enabling.
  - **Release coupling, not the classifier, is what gates a safe first run.**
    118 merges across 71 repos with `release.yml` still on `push: [main]` means
    up to 71 semantic-release -> GHCR -> Azure deploys in one unbatched wave.
  - **#22 is obsolete and would regress if merged.** It pins
    `actions/checkout` to `v4.3.1`; `main` already SHA-pins `v6.0.3` via #24.
    Close it, don't merge it.

### Fixed

- **`agent-merge-janitor.sh`**: added a pre-flight unresolvable-repo guard,
  closing a silent blind spot (murph, task_1788354182960_04095147). `conduit`
  moved from `wyre-technology` to the `WYRE-AI` org on 2026-08-25, and `gh pr
  list -R wyre-technology/conduit --label auto-merge-ready --json ...` — the
  exact call this script makes — did not error on that; it silently returned
  an empty `[]` at rc=0, which every run since read as "conduit has zero
  eligible PRs" instead of "conduit is unreachable." Verified live
  2026-09-02, both the bug and the fix:
  ```
  gh pr list -R wyre-technology/conduit --label auto-merge-ready --json number   # []  rc=0  (silent, unchanged)
  gh repo view wyre-technology/conduit                                            # GraphQL error, rc=1
  REPOS="cortextos conduit" ./agent-merge-janitor.sh                              # was: silent 0-PR scan
                                                                                   # now: FATAL, exit 1, before any scanning
  ```
  The new `check_repo_resolves()` guard runs once per repo in `REPOS` before
  the labeled-PR listing loop starts (`gh repo view "$ORG/$repo"`, not the
  listing call itself, since that's the one call proven not to error on this
  condition); if any repo doesn't resolve, the script prints which repo(s)
  and exits 1 instead of writing a backlog. Reproduced against a second,
  wholly fictitious repo name to confirm this isn't a conduit-specific patch
  — any future unresolvable entry in `REPOS` now fails the same way.

  **Revised 2026-09-03, later the same day the App-installation gap closed.**
  The first version of this fix (above) dropped `conduit` from `REPOS`
  entirely, since the `wyre-agent-fleet` App used to mint this script's
  `GH_TOKEN` was installed only on `wyre-technology` at the time
  (`task_1788354249320_29879105`), and `cortextos` was still resolving under
  `wyre-technology` too. Both of those have since changed: `cortextos`
  finished its own move to `WYRE-AI` on 2026-08-31, and Aaron installed the
  App on `WYRE-AI` on 2026-09-03 (confirmed live: minting a real token,
  `installation_id=158846229`; task closed). `ORG` now defaults to `WYRE-AI`
  and `REPOS` is back to `"cortextos conduit"` — both repos live under the
  same org today, so no per-repo org override is needed. The guard above is
  unchanged and is exactly why this revision is safe: verified live that
  both repos resolve under `WYRE-AI` and the script runs clean end to end
  (dry-run, exit 0); independently cross-checked the resulting "0 eligible
  PRs" against `gh pr list --label auto-merge-ready` directly on both repos,
  not just the script's own zero.

- **`dependabot-janitor.sh`**: `classify()` no longer treats the word "group" in
  a PR title as proof that the PR is minor/patch. It now parses the body's
  per-dependency `Updates \`pkg\` from A to B` markers and requires **every** one
  to be same-major, failing closed on any cross-major, unparseable marker, zero
  markers, or failed body fetch. Supersedes #23, rebased as #54, and reconciled
  here onto post-#66 dual-org `main` (the body fetch now calls
  `repos/$repo/pulls/$num` directly since `$repo` is already `org/name`, rather
  than the single-org `repos/$ORG/...` #54 was written against).

  **This was live, not theoretical.** Measured against the backlog on
  2026-08-17: of the 118 PRs a dry run would merge, 108 are grouped, and **69 of
  those 108 (64%) contain at least one cross-major bump**, across 62 repos. The
  blanket shortcut would have merged every one of them without inspecting a
  single dependency.

  `is_dev_major`'s allowlist is **not** a defence here — `classify()` returned
  `ELIGIBLE` for grouped PRs *before* the dev-major check ran, so the grouped
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

- **`dependabot-janitor.sh`**: `cortextos` and `conduit` are now in scope
  (explicit carve-outs `^cortextos$|^conduit$` on the repo-selection regex),
  reapplied from #50 onto the dual-org repo-enumeration loop #66 introduced
  after #50 was opened — #50's own diff targeted the old single-org `grep`
  pipeline and no longer applies cleanly, so the carve-out is added to the
  `grep -E` call inside the current `for _org in $ORGS` loop instead. Neither
  repo shares the mcp-server shape this janitor was built for
  (task_1785692635899_03153380); their Dependabot PRs previously got zero
  auto-merge coverage, since `agent-merge-janitor` deliberately excludes any
  package.json/lockfile touch. This is their only auto-merge lane.

- **`mcp-server-release.yml`**: the `release` job's "Detect released version"
  step now runs with `if: always()`, and the `docker` job's gate is now
  `if: always() && needs.release.outputs.released == 'true'`. Rebased from #26
  onto current `main`, which carries a second, unrelated step also named
  `id: detect` (inside the `mcpb` job, added since #26 was opened — it checks
  for a `pack:mcpb` script, not release status). Confirmed by reading both:
  they are different steps in different jobs serving different purposes, so
  #26's fix applies to exactly the one release-detection occurrence and the one
  `docker` gate, unchanged in scope from #26 as authored.

  **Why:** semantic-release creates the tag and GitHub release, then pushes git
  notes as its final action. A flaky/duplicate notes push ("cannot lock ref
  refs/notes/semantic-release-…: reference already exists") fails the Semantic
  Release step even though the release is already complete. Without
  `if: always()`, the detect step (and everything gated on its output) was then
  skipped — a published version with no image, no registry listing, and no
  deploy. Detection keys off the tag-on-HEAD + GitHub release, not the step's
  exit code, so a post-release hiccup can't silently drop artifact publishing.

  Note: the `mcpb` job (added after #26 was opened) has an analogous
  `needs.release.outputs.released == 'true'` gate without `always()`, and would
  have the same latent skip-on-hiccup exposure — out of scope for this
  reconciliation since it wasn't part of #26's reviewed diff and the job didn't
  exist when #26 was authored; flagged here for a follow-up.

- **`scripts/set-required-checks.sh`**: the branch-protection PUT payload
  hardcoded `restrictions: null` and omitted `lock_branch`/`allow_fork_syncing`
  entirely, instead of reading and preserving their current values the way the
  script already does for `required_pull_request_reviews`. Found reviewing
  #55, which cites this script as already run live against 32 `*-mcp` repos.
  Verified live against all 32 target repos (not the smaller spot-check from
  the initial review): none currently have `restrictions`, `lock_branch`, or
  `allow_fork_syncing` configured, so no repo was actually clobbered by the
  gap — but the script mutates fleet-wide branch protection and was going to
  run again, so it's fixed rather than left as a known footgun. Now
  round-trips all three the same read-merge-write way as the review settings,
  including converting `restrictions`' GET-shape (objects with `login`/`slug`)
  to the PUT-shape it actually accepts (arrays of `login`/`slug` strings), and
  extends the pre-write drift check that already guarded review settings to
  cover these three fields too — the script refuses to write if any of them
  would change, the same discipline it already applied to reviews.

- **`mcp-server-release.yml`**: added a `gate` job that holds the release when
  **every** commit since the last tag carries an `Auto-Merged-By:` trailer, plus
  `release-sweeper.yml` + `release-sweeper.sh` to ship the held batch daily.
  `dependabot-janitor.sh` now writes that trailer on its squash merges.

  **Why:** a janitor dry run on 2026-08-17 would merge 118 PRs across 71 repos in
  one sweep. Every caller's `release.yml` fires on `push: [main]`, so that is up
  to 71 semantic-release → GHCR → Azure Container Apps deploys in a single
  unbatched, unreviewed wave — into containers holding live customer API
  credentials. The gate drops the blast radius from "71 production containers
  rolled at 09:00 with nobody watching" to "main is briefly ahead of the
  release".

  **The rule is deliberately narrow.** Only an all-autonomous range is held. If a
  human merged anything since the last tag they are taking responsibility for the
  release, and the accumulated autonomous commits ship alongside — the normal
  case, no ceremony.

  **A gate with no opener is worse than no gate**, because the fleet would
  silently stop releasing — the same silent-absence failure as the 27-day janitor
  outage. `release-sweeper.yml` opens it by pushing one empty `chore(release):`
  commit per held repo, which carries no trailer. `chore:` is not
  version-bumping, so the version still reflects the accumulated `fix:`/`feat:`
  commits. Chosen over `gh workflow run` because that needs `workflow_dispatch`
  on all 58 thin callers; an empty commit needs nothing from the caller and
  leaves an auditable "this batch shipped here" marker.

  Gate logic verified against six cases (nothing-since-tag, 1 autonomous, 2
  autonomous, mixed autonomous+human, post-tag, and the sweeper's own commit
  correctly reopening the gate). Reaches the fleet by pin bump — no caller edits.

- **`mcp-server-release.yml`**: added a workflow-level `concurrency` group.
  No group meant near-simultaneous pushes to a caller's `main` (e.g. two
  dependabot auto-merges seconds apart) could run this workflow twice in
  parallel, both detect the same releasable HEAD via the existing git-tag
  check, and race the MCP Registry publish step. Same mechanism confirmed
  live via meraki-mcp's legacy inline workflow (`WYRE-AI/meraki-mcp#12`,
  murph): 3 merges within 13s on 2026-08-21, 3 green Release runs, 3 failed
  `cannot publish duplicate version` 400s.

  Group is `release-${{ github.repository }}-${{ github.ref }}`.
  `github.ref` alone already fully serializes the actual bug (same-repo,
  near-simultaneous pushes to main) — GitHub scopes concurrency groups
  per-repository automatically, even for a reusable workflow's own group
  declaration, so two different callers of this workflow computing the
  identical literal group string never queue against each other (verified
  against GitHub's docs + community discussion before writing this).
  `github.repository` is included purely for a self-documenting group name
  in the Actions UI, not because it's required for correctness.
  `cancel-in-progress: false` is deliberate — a queued run waits for the
  in-flight release/publish to finish rather than cancelling it mid-publish.

- **`dependabot-janitor.sh` / `dependabot-janitor.yml`**: added dual-org
  support. The *-mcp/node-* fleet moved from being entirely under
  `wyre-technology` to being split across `wyre-technology` (13 repos) and
  `WYRE-AI` (50 repos, `conduit` included) sometime around 2026-08-24
  evening/night. The janitor's repo enumeration was a single-org API call
  (`ORG`, defaulting to `wyre-technology`), so it silently kept scanning
  only the 13 repos still there — no error, just 50 of 63 repos never
  looked at. Almost certainly the real explanation for a persistent
  ~80-108-PR "chronic dependabot backlog" that multiple `scan-mcp-repos`
  cycles reported as steady-state review-gating rather than what it
  actually was: the janitor never reaching those repos at all.

  `ORG` is now `ORGS` (space-separated, default `"wyre-technology
  WYRE-AI"`, with `ORG` kept as a back-compat single-org override). Each
  `REPOS` entry is now an `"org/name"` pair rather than a bare name, so
  every downstream `gh ... -R` call targets the repo's real org directly.
  Verified live: the new enumeration finds 105 repos in scope (85 WYRE-AI
  + 20 wyre-technology, using the script's actual `-mcp$|^mcp|^node-`
  pattern, broader than just the `*-mcp` fleet) vs. the ~20 the old
  single-org call would have found.

  **Not fully live yet — one line still gates it, left in place and
  documented rather than silently forced.** The `wyre-projects-bot` App
  (the one `APP_ID`/`APP_PRIVATE_KEY` mint tokens for) is confirmed NOT
  installed on `WYRE-AI` (verified via `gh api orgs/WYRE-AI/installations`
  — only `digitalocean`, `blacksmith-sh`, `vanta-with-task-management`,
  and two `infisical` apps are). Adding `WYRE-AI` to the token-minting
  step's `owner:` before that install exists risks failing token minting
  outright rather than degrading gracefully (untested, and not worth
  risking the currently-working `wyre-technology` half to find out) — so
  `owner:` is left single-org for now, with the exact one-line change
  documented inline for whoever does the App install. Meanwhile `ORGS`
  already includes `WYRE-AI`, so every `WYRE-AI` repo will show up in the
  run's Errors section (`pr list failed`, an auth failure) until the
  install lands — expected, isolated per-repo (no crash, no effect on
  `wyre-technology` repos), and turns a previously-invisible gap into a
  visible, diagnosable one in the workflow's own summary output.

- **`mcp-server-release.yml`**: the `mcpb` job did not install the MCPB CLI, so
  it failed on 24 of the 26 repos with a `pack:mcpb` script. Pack scripts shell
  out to `npx mcpb pack`; only `autotask-mcp` and `blumira-mcp` carry
  `@anthropic-ai/mcpb` as a dependency, so everywhere else `npx` tried to fetch
  a package literally named `mcpb` from the public registry and died with
  `npm error 404 Not Found - GET https://registry.npmjs.org/mcpb`. The
  hand-rolled per-repo workflows all ran `npm install -g @anthropic-ai/mcpb` for
  exactly this reason; the job omitted it because it was validated only against
  `autotask-mcp`, one of the two repos where the omission is invisible. Caught
  live on `atera-mcp`. `npx` resolves `node_modules/.bin` before the global
  prefix, so a repo pinning its own version still wins — this is a fallback,
  not an override.
  - **Corrected a false claim in this file's own comments.** They stated that
    because `mcpb` needs only `release` and never `docker`, a pack failure
    "cannot cascade into skipping the deploy chain". That holds *within* this
    workflow, but callers invoke the whole file as a **single job**, so every
    job here rolls up into one conclusion — any failure marks the caller's
    `release` job failed and skips a caller `deploy: needs: release`. Confirmed
    on `atera-mcp`: `docker`, `mcp-registry` and `security` all succeeded,
    `mcpb` failed, and `deploy` was skipped regardless. A bug in the `mcpb` job
    is therefore deploy-blocking, and the comments now say so.

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

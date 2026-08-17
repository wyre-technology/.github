# Fleet triage routine

A scheduled Claude cloud routine that handles the parts of org-wide PR/issue
automation that `dependabot-janitor` does not: liveness, issues, non-Dependabot
PRs, the code-owner-blocked backlog, and agent-authored fixes.

> **Naming.** `janitor` merges Dependabot PRs. `warden` is the security-review
> role. This routine is `fleet-triage` — it never owns a merge policy of its own.

## Why

As of 2026-08-17 the org has **416 open PRs** (241 from Dependabot) and **65
open issues** across **100 repos** in janitor scope. `dependabot-janitor`
covers exactly one slice of that — Dependabot PRs — and has been
`disabled_manually` since **2026-07-21**, pending the `.github` CI-split
precondition (`task_1786765529531`, per #50).

Nothing noticed the 27-day gap. That is the actual defect this routine exists
to fix; the backlog is a symptom.

### The failure mode is silent absence, not bad action

Two independent silent failures were live simultaneously:

1. `dependabot-janitor` stopped running on 2026-07-21 and nothing alerted.
2. `dependabot-backlog.md` — which `dependabot-janitor.sh` writes and whose
   comments say "the weekly Claude digest routine reads [it] from its `.github`
   checkout" — **returns 404 on `main`**. It has never been committed. The
   downstream consumer has been reading a file that does not exist.

Both are absence-of-signal failures. Neither would be caught by any amount of
hardening to the merge policy itself, which is where all prior effort went
(#28, #36, #38, #23). Liveness is therefore component 1, not an afterthought.

## What already exists — and is out of scope

| Component | Owns | Status |
|---|---|---|
| `dependabot-janitor.sh` | Dependabot PR merge policy across `-mcp$`/`^mcp`/`^node-` | Disabled since 2026-07-21 |
| `agent-merge-janitor.sh` | cortextos + conduit; excludes any `package.json`/lockfile touch by design | Active |
| `pr-spam-triage.yml` | Auto-closing promotional/badge-spam PRs | Active |
| `github-activity-notifier` | Slack post on new external issue/PR | Active |

**`fleet-triage` does not reimplement any merge policy.** Dependabot PR merging
is `dependabot-janitor.sh`'s job. The routine invokes that script and consumes
its output buckets (`merged` / `majors` / `blocked` / `red` / `conflicts` /
`pending` / `errors`) as facts; it does not re-classify a PR the janitor has
already classified, and it does not merge outside it. This is a hard
constraint, for a concrete reason: the
janitor's policy encodes two production incidents that a fresh implementation
would re-learn the expensive way —

- **`sentinelone-mcp#31`** (2026-07-21): `gh pr checks` exits **0 when every
  check is `skipping`**. Release/deploy-only jobs with no PR-time test job
  produce a vacuous green. Fixed in #38 by comparing total vs. skipping buckets.
- **`node-datto-rmm#46`** (2026-07-21): a grouped Dependabot PR hid a
  TypeScript major behind a title that `classify()` shortcuts to `ELIGIBLE`.
  Auto-merged on a no-CI repo and broke `main`. Partially fixed in #36.

## Trust model

The routine is an LLM. It must never be the thing that decides a merge.

- **Merge decisions come from a deterministic script** (`dependabot-janitor.sh`)
  that the routine invokes and whose exit state it obeys. A poisoned issue body
  can talk a model into anything; it cannot make a bash script exit 0.
- **Identity separation.** Anything the routine authors, it cannot merge. The
  authoring identity is not a CODEOWNER, and every repo has
  `require_code_owner_reviews: true`, so GitHub enforces this independently of
  the routine's own logic.
- **Untrusted input is data, never instruction.** Issue and PR bodies are
  attacker-controlled on 57 of 58 public `*-mcp` repos. The routine follows the
  idiom already documented in `pr-spam-triage.yml`: read metadata via the API,
  pass PR-derived strings through env vars, never interpolate into `run:`.

### Prerequisite: `required_status_checks` is `NULL` fleet-wide

Sampled 20 `*-mcp` repos on 2026-08-17 — **20/20** returned:

```
required_status_checks: NULL
required_approving_review_count: 1
require_code_owner_reviews: true
```

CI passing is enforced **nowhere** at the branch level. The janitor's
`gh pr checks` read is the only CI gate in the system, and that read has been
wrong twice. Setting `required_status_checks` to the `mcp-server-ci.yml`
contexts (`Test (Node 22)`, `Test (Node 24)`) gives defense in depth: a bug in
check-reading then fails closed at the branch instead of merging red.

This should land **before** the janitor is re-enabled, and is independent of
this routine.

## Components

### 1. Liveness / deadman

Alert when `dependabot-janitor` has not completed a run in >36h (cadence is
twice daily), and when `dependabot-backlog.md` is absent or its
`_Last updated:_` stamp is >36h old. Both conditions were true and unnoticed
for 27 days.

Deliberately covers the *absence* of a run, not just a failed one — the
27-day gap produced zero failed runs, because it produced zero runs.

### 2. Issue triage

65 open issues; the janitor is PR-only. Label, deduplicate, identify stale.
No write access beyond labels and comments. Never closes on its own judgment
for anything other than exact duplicates.

### 3. Non-Dependabot PR triage

The janitor filters `--author app/dependabot`; ~175 open PRs fall outside it.
These are triaged and labeled, never auto-merged. External-authored PRs are
the injection surface, and there is no author-trust basis for merging them.

### 4. Code-owner-blocked backlog

`dependabot-janitor.sh` approves (`gh pr review --approve`) to satisfy
non-code-owner review requirements, then buckets anything that still fails as
`blocked`. With `require_code_owner_reviews: true` on 20/20 sampled repos,
this bucket is structurally unresolvable by the janitor.

**This is a policy decision, not an implementation task**, and is called out
as an open question below rather than designed around.

### 5. Release decoupling

Auto-merged commits should land on `main` without shipping to production. The
per-repo `release.yml` is a thin caller on `push: [main]`, and every downstream
job (`docker`, `mcpb`, `mcp-registry`, `security`) already gates on
`needs.release.outputs.released == 'true'`.

Add a `gate` job to `mcp-server-release.yml` that inspects commits since the
last tag for an `Auto-Merged-By:` trailer, and extend the `release` job's
condition:

```yaml
if: >
  github.event_name == 'workflow_dispatch' ||
  (github.event_name == 'push' && github.ref == 'refs/heads/main'
   && needs.gate.outputs.autonomous != 'true')
```

Auto-merged commits accumulate; a daily `workflow_dispatch` ships the batch.
One central edit, propagated by pin bump — the same mechanism the `mcpb` job
restoration used, with no caller edits across the fleet.

### 6. Agent-authored fixes

The routine may open PRs against issues it triages. It cannot merge them
(component 1 of the trust model). Every agent-authored PR requires a human
merge, permanently — this is not a trust level that increases with time.

## Janitor hardening backlog

Verified against `main` on 2026-08-17:

| PR | State | Disposition |
|---|---|---|
| **#50** — add cortextos+conduit to scope | `MERGEABLE` / `CLEAN` | Merge. Current, no conflicts. |
| **#23** — `classify()` reads per-dep bumps, fail-closed | `CONFLICTING` / `DIRTY` | **Rebase and merge.** Still a live hole. |
| **#22** — SHA-pin `actions/checkout` | `CONFLICTING` / `DIRTY` | **Close, do not merge.** Obsolete. |

### #23 is still an open hole

`main`'s `classify()` retains the blanket shortcut:

```bash
if grep -qiE '\bgroup\b' <<<"$title"; then echo ELIGIBLE; return; fi
```

#36 added only a *downstream* guard, for grouped PRs with **no CI**. A grouped
PR with **green** CI still returns `ELIGIBLE` on a title match and can hide a
runtime major — the `node-datto-rmm#46` shape minus the no-CI leg. #23 fixes
the classifier itself by parsing per-dep `from A to B` pairs out of the PR
body and failing closed on any cross-major or unparseable pair.

It conflicts because #36/#38 have since rewritten the surrounding code. It
needs a rebase, not a rewrite.

### #22 is obsolete and merging it would regress

#22 changes `actions/checkout@v4` → SHA-pinned **`v4.3.1`**. `main` already
SHA-pins **`v6.0.3`** (landed via #24, the Node 24 bump). The PR's stated goal
— pin the action that handles the org-wide app token — is already met, at a
newer version. Merging it would downgrade. Close with a pointer to #24.

## Open questions

These are decisions, not implementation gaps. Each needs an answer before the
corresponding component ships.

1. **The CI-split precondition.** #50 states the janitor is disabled pending
   `task_1786765529531`. What is the precondition, and is it satisfied? The
   janitor must not be re-enabled until this is answered — it was turned off
   deliberately.
2. **Code-owner policy.** Resolving the `blocked` bucket means either adding
   the janitor's app as a CODEOWNER, or relaxing `require_code_owner_reviews`
   for Dependabot-authored PRs via a ruleset exemption. The first grants an
   automation the reviewer role; the second narrows a protection. Neither is
   obviously right.
3. **Routine credential scope.** Whether a Claude cloud routine can hold a
   GitHub App installation token (as the janitor workflow does via
   `actions/create-github-app-token`) or requires a PAT. Unverified — the
   `/schedule` mechanism's credential handling was not confirmed. If it cannot
   hold an App token, components needing write access move to a GitHub Actions
   cron and the routine keeps only the read/report work.
4. **Run budget.** 100 repos × per-PR `gh pr checks` is the janitor's current
   cost. Whether one routine invocation can complete that within its wall-clock
   budget is unmeasured; sharding may be required.

## Testing

Follow the existing convention (`scripts/github-activity-notifier.test.mjs`):
colocated `.test.mjs` per script, no network.

- Liveness: table-driven over last-run timestamps and backlog staleness,
  including the "zero runs, zero failures" case that went unnoticed for 27 days.
- Any change to `dependabot-janitor.sh` must add a case covering the incident
  it addresses. #23's rebase needs a grouped-PR-body fixture with a hidden
  cross-major, taken from the real `node-datto-rmm#46` body rather than an
  invented shape.

The CHANGELOG's own record is the argument here: the digest-verification check
was "tested only against invented shapes that encoded the same wrong
assumption." Fixtures come from real payloads.

## Rollout

1. Answer open question 1. Do not proceed until the CI-split precondition is
   resolved.
2. Set `required_status_checks` fleet-wide.
3. Merge #50; rebase and merge #23; close #22.
4. Re-enable `dependabot-janitor` with `dry_run=true` via `workflow_dispatch`;
   review the classification against the 241-PR backlog before a live run.
5. Ship component 1 (liveness) — it is the defect that motivated this document
   and does not depend on anything above.
6. Components 2–6 in order, each independently revertible.

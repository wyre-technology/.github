# Required status checks — fleet baseline

Applied 2026-08-17 to the 32 `*-mcp` repos that have substantive PR CI.

## Why

A survey on 2026-08-17 found `required_status_checks` was **`null` on 20/20
sampled `*-mcp` repos**. Branch protection required 1 approving review plus
code-owner review, but CI passing was enforced **nowhere** at the branch level.

The only CI gate in the system was `dependabot-janitor`'s own `gh pr checks`
read — and that read has been wrong twice (#36: grouped/no-CI; #38: all-skipping
checks reported as green). There was no defence in depth behind it. With these
set, a bug in check-reading fails closed at the branch instead of merging red.

## The two footguns this tooling exists to avoid

**1. A required check that never reports blocks every PR in the repo, forever.**
Contexts are not fleet-uniform — the survey found **21 distinct check
signatures across 58 repos**. `mcp-server-ci.yml` exists but the fleet never
adopted it, so there is no single set of names to require. `Test (Node 22)` is
what the reusable emits and almost nothing actually uses it.

**2. Path-filtered workflows produce no check-run at all on unrelated PRs.**
Requiring one hangs every PR that doesn't touch those paths. `auvik-mcp`'s
`docker-build` is exactly this case, and a sample-of-one survey would have
picked it up as required.

`derive-required-checks.sh` therefore samples the last N PRs per repo and keeps
only names present on **every** sampled PR — intersection, not union. Never
hand-write the context list.

**3. The protection API replaces the whole object.** `PUT
/branches/{branch}/protection` is not a patch. Sending only
`required_status_checks` silently drops `required_pull_request_reviews`.
`set-required-checks.sh` reads current protection, merges, verifies the review
settings are byte-identical before writing, and refuses the write if they
aren't.

## Usage

```sh
# 1. derive (writes contexts.tsv: repo <TAB> always-present <TAB> sometimes)
SP=/tmp/rc bash scripts/derive-required-checks.sh

# 2. dry run — prints the plan, writes nothing
CONTEXTS_TSV=/tmp/rc/contexts.tsv BACKUP_DIR=/tmp/rc/backup \
  DRY_RUN=true bash scripts/set-required-checks.sh

# 3. apply (per-repo rollback JSON lands in BACKUP_DIR)
CONTEXTS_TSV=/tmp/rc/contexts.tsv BACKUP_DIR=/tmp/rc/backup \
  DRY_RUN=false bash scripts/set-required-checks.sh
```

Rollback for a single repo:

```sh
gh api -X PUT /repos/wyre-technology/<repo>/branches/main/protection \
  --input <backup-dir>/<repo>.json
```

## Not covered: 22 repos with no substantive PR CI

Their only passing check is `assert / assert` (the mcp-assert smoke test) —
there is no test/build job to require. Setting required checks there would make
a smoke test mandatory and change nothing about correctness.

`abnormal-mcp`, `action1-mcp`, `atera-mcp`, `avanan-mcp`, `cipp-mcp`,
`connectwise-manage-mcp`, `crewhu-mcp`, `domotz-mcp`, `freshdesk-mcp`,
`halopsa-mcp`, `ironscales-mcp`, `knowbe4-mcp`, `mimecast-mcp`, `ninjaone-mcp`,
`proofpoint-mcp`, `sherweb-mcp`, `spamtitan-mcp`, `syncro-mcp`, `xero-mcp`,
plus `alternative-payments-mcp`, `salesforce-mcp`, `sentinelone-mcp` (no
passing checks at all).

**24 of the 118 PRs a janitor dry run would merge land in these repos**, and the
janitor flagged only **1** of them as `(no CI)` — because `assert / assert`
passing yields `rc=0` with `total != skipping`, so #38's guard reads them as
genuinely validated. Adopting `mcp-server-ci.yml` on these 22 is the real fix
and is tracked separately.

## Baseline

`required-checks-baseline.tsv` records what was applied:
`repo <TAB> required <TAB> excluded-as-inconsistent`.

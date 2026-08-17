#!/usr/bin/env bash
#
# Dependabot janitor: across all wyre-technology mcp-* and node-* repos, auto-merge
# Dependabot patch/minor PRs — AND major bumps of dev/CI tooling (eslint, vitest,
# typescript, @types/*, GitHub Actions, etc.) — whose CI is green. Major bumps of
# RUNTIME dependencies, red CI, conflicts, and code-owner-blocked PRs are reported
# but never merged. A green test suite is treated as sufficient proof for dev/CI
# tooling (it doesn't ship at runtime); runtime majors always need a human.
#
# Requires: gh CLI authenticated via GH_TOKEN (a GitHub App installation token with
# contents:write + pull_requests:write across the org).
#
# Env:
#   ORG          GitHub org (default: wyre-technology)
#   DRY_RUN      if "true", classify and report but do not approve/merge
set -uo pipefail

ORG="${ORG:-wyre-technology}"
DRY_RUN="${DRY_RUN:-false}"

work="$(mktemp -d)"
for cat in merged majors red pending conflicts blocked errors nocheck; do : > "$work/$cat"; done

# Repos in scope: names ending in -mcp, starting with mcp, or starting with node-.
mapfile -t REPOS < <(
  gh api --paginate "/orgs/$ORG/repos?per_page=100" \
    --jq '.[] | select(.archived==false) | .name' \
  | grep -E '(-mcp$|^mcp|^node-)' | sort -u
)
echo "Scanning ${#REPOS[@]} repositories in scope..."

# Return the leading integer (major version) of a semver-ish string.
major_of() { sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$1"; }

# Classify a PR title as ELIGIBLE (patch/minor) or MAJOR.
# Grouped Dependabot PRs are configured to contain only minor/patch updates.
classify() {
  local title="$1"
  if grep -qiE '\bgroup\b' <<<"$title"; then echo ELIGIBLE; return; fi
  # "... from A.B.C to D.E.F"
  if [[ "$title" =~ from[[:space:]]+([0-9][^[:space:]]*)[[:space:]]+to[[:space:]]+([0-9][^[:space:]]*) ]]; then
    local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
    if [[ "$(major_of "$from")" == "$(major_of "$to")" ]]; then echo ELIGIBLE; else echo MAJOR; fi
    return
  fi
  echo MAJOR  # unparseable -> treat conservatively
}

# A MAJOR bump is auto-mergeable (on green CI) only if the bumped package is
# dev/CI tooling — it never ships at runtime, so a green build+lint+test is
# sufficient proof. Everything else (runtime deps) is held for human review,
# even on green CI, because a passing suite can miss behavioural breaking changes.
# Conservative by construction: anything not on this allowlist is treated as runtime.
is_dev_major() {
  local pkg
  pkg="$(sed -nE 's/.*[Bb]ump ([^ ]+) from .*/\1/p' <<<"$1")"
  [[ -z "$pkg" ]] && return 1
  case "$pkg" in
    eslint|vitest|typescript|semantic-release|prettier|tsup|msw|jsdom|rimraf|tslib|ts-node|nodemon|husky|lint-staged|c8|nyc|typedoc|vite|tsx) return 0 ;;
    @vitest/*|@types/*|@typescript-eslint/*|@semantic-release/*|@eslint/*|@testcontainers/*|eslint-*) return 0 ;;
    # GitHub Actions / CI workflow deps (owner/action form)
    actions/*|docker/*|github/*|azure/*|aws-actions/*|dependabot/*|hashicorp/*|gitleaks/*|aquasecurity/*|sigstore/*|softprops/*|peter-evans/*|cycjimmy/*|anthropics/*) return 0 ;;
    *) return 1 ;;
  esac
}

for repo in "${REPOS[@]}"; do
  prs="$(gh pr list -R "$ORG/$repo" --author 'app/dependabot' --state open \
        --json number,title,mergeable 2>/dev/null)" || { echo "$repo: pr list failed" >>"$work/errors"; continue; }
  [[ "$(jq 'length' <<<"$prs")" == "0" ]] && continue

  while IFS=$'\t' read -r num title mergeable; do
    [[ -z "$num" ]] && continue
    label="$repo #$num — $title"

    devmajor=0
    if [[ "$(classify "$title")" == "MAJOR" ]]; then
      if is_dev_major "$title"; then
        devmajor=1   # dev/CI tooling major — eligible for auto-merge on green CI
      else
        echo "$label" >>"$work/majors"; continue   # runtime major — human review
      fi
    fi
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      echo "$label" >>"$work/conflicts"; continue
    fi

    # CI status. gh pr checks exit codes: 0=all pass, 8=pending, 1=failing,
    # non-zero+"no checks" => repo has no checks for this PR.
    checks_out="$(gh pr checks "$num" -R "$ORG/$repo" 2>&1)"; rc=$?
    if [[ $rc -eq 8 ]]; then echo "$label" >>"$work/pending"; continue; fi
    if [[ $rc -ne 0 ]]; then
      if grep -qi 'no checks' <<<"$checks_out"; then
        : # no CI gate; fall through to merge with a flag
        nocheck=1
      else
        echo "$label" >>"$work/red"; continue
      fi
    else
      # rc=0 also covers the vacuous case where EVERY check reports
      # "skipping" (e.g. release/deploy jobs gated to push-to-main only, no
      # dedicated PR-time test job) -- exit code alone can't tell "genuinely
      # validated" from "nothing ran". If every check's bucket is
      # "skipping", there is no real proof; treat it the same as
      # no-checks-at-all rather than as green. A partial mix (some real
      # checks + some skipped release/deploy jobs) still counts as
      # genuinely validated -- only ALL-skipping loses trust. Concrete
      # instance: sentinelone-mcp#31 (2026-07-21), all-skipping/rc=0, would
      # have auto-merged a TS7 major with zero flag -- worse than
      # node-datto-rmm#46's already-flagged "(no CI)" case, since that one
      # at least surfaced in the run summary.
      buckets_json="$(gh pr checks "$num" -R "$ORG/$repo" --json bucket 2>/dev/null)"
      total="$(jq 'length' <<<"${buckets_json:-[]}" 2>/dev/null || echo 0)"
      skipping="$(jq '[.[] | select(.bucket=="skipping")] | length' <<<"${buckets_json:-[]}" 2>/dev/null || echo 0)"
      if [[ "$total" -gt 0 && "$total" == "$skipping" ]]; then
        nocheck=1
      else
        nocheck=0
      fi
    fi

    # A green suite is what makes a dev/CI-tooling major (or a "trust the
    # group" grouped bump) safe to auto-merge. With NO CI at all, there is no
    # proof — not "sufficient proof", none. classify()'s group-shortcut
    # assumes a grouped title never contains a major (true only when
    # dependabot.yml's own update-types actually excludes majors from that
    # group, which isn't guaranteed for PRs opened before such a config
    # change, or on repos without one). This is exactly how node-datto-rmm#46
    # ("bump the dev-dependencies group with 3 updates") auto-merged a hidden
    # typescript major on a no-CI repo and broke main (2026-07-21): the title
    # matched the group-shortcut, devmajor stayed 0, and it fell through on
    # nocheck alone. Hold both cases for human review instead of guessing.
    is_grouped=0; grep -qiE '\bgroup\b' <<<"$title" && is_grouped=1
    if [[ "${nocheck:-0}" == "1" ]] && { [[ "${devmajor:-0}" == "1" ]] || [[ "$is_grouped" == "1" ]]; }; then
      echo "$label (no CI to verify — group/major, held for review)" >>"$work/majors"; continue
    fi

    flag=""; [[ "${nocheck:-0}" == "1" ]] && flag=" (no CI)"; [[ "${devmajor:-0}" == "1" ]] && flag="$flag (dev-major)"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "$label$flag" >>"$work/merged"; continue
    fi

    # Approve (satisfies non-code-owner review requirements) then squash-merge.
    gh pr review "$num" -R "$ORG/$repo" --approve \
      -b "Auto-approved by Dependabot janitor: CI green (patch/minor, or dev/CI-tooling major)." >/dev/null 2>&1
    # The `Auto-Merged-By:` trailer is what mcp-server-release.yml's `gate` job
    # reads to decide whether a push to main may cut a release. When EVERY commit
    # since the last tag carries it, the release is held for the daily batch
    # (release-sweeper.yml) instead of firing an unreviewed
    # semantic-release → GHCR → Azure deploy per repo. Removing this trailer
    # silently re-couples auto-merge to production deploys.
    merge_body="Auto-merged by dependabot-janitor: CI green (patch/minor, or dev/CI-tooling major).

Auto-Merged-By: dependabot-janitor"
    if merge_err="$(gh pr merge "$num" -R "$ORG/$repo" --squash --delete-branch --body "$merge_body" 2>&1)"; then
      echo "$label$flag" >>"$work/merged"
    else
      if grep -qiE 'review|code ?owner|protected|required|base branch policy|not mergeable|auto.?merge' <<<"$merge_err"; then
        echo "$label" >>"$work/blocked"
      else
        echo "$repo #$num: $(tr '\n' ' ' <<<"$merge_err" | head -c 160)" >>"$work/errors"
      fi
    fi
  done < <(jq -r '.[] | "\(.number)\t\(.title)\t\(.mergeable)"' <<<"$prs")
done

# ---- Summary ----
count() { wc -l <"$work/$1" | tr -d ' '; }
section() { local t="$1" f="$2"; echo "### $t ($(count "$f"))"; [[ -s "$work/$f" ]] && sed 's/^/- /' "$work/$f"; echo; }

{
  echo "## 🤖 Dependabot Janitor — $(date -u +%Y-%m-%d\ %H:%MZ)"
  echo "- Repos scanned: ${#REPOS[@]}"
  [[ "$DRY_RUN" == "true" ]] && echo "- **DRY RUN** (no merges performed)"
  echo
  section "✅ Merged"                   merged
  section "🚫 Needs review — major"     majors
  section "🔒 Blocked — needs your approval (code-owner)" blocked
  section "❌ Red CI"                   red
  section "⚠️ Conflicts"               conflicts
  section "⏳ Pending CI (retry next run)" pending
  section "💥 Errors"                  errors
} | tee "$work/summary.md"

# Publish to the GitHub Actions step summary when running in CI.
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$work/summary.md" >>"$GITHUB_STEP_SUMMARY"

# Persist the human-attention backlog (majors + code-owner-blocked) to a file the
# weekly Claude digest routine reads from its .github checkout. Only the items
# that need a human are included; merged/pending/transient buckets are omitted.
backlog="${BACKLOG_FILE:-dependabot-backlog.md}"
{
  echo "<!-- Generated by .github/workflows/dependabot-janitor.yml — do not edit by hand. -->"
  echo "# Dependabot backlog needing human attention"
  echo
  echo "_Last updated: $(date -u +%Y-%m-%dT%H:%MZ)_"
  echo
  echo "## Runtime major-version updates (left for review)"
  echo "_Dev/CI-tooling majors (eslint, vitest, typescript, @types/*, Actions, …) auto-merge on green CI; only runtime-dependency majors land here._"
  echo
  if [[ -s "$work/majors" ]]; then sed 's/^/- /' "$work/majors"; else echo "_none_"; fi
  echo
  echo "## Blocked — code-owner approval required"
  if [[ -s "$work/blocked" ]]; then sed 's/^/- /' "$work/blocked"; else echo "_none_"; fi
  echo
  echo "## Red CI (won't merge until fixed)"
  if [[ -s "$work/red" ]]; then sed 's/^/- /' "$work/red"; else echo "_none_"; fi
} > "$backlog"

rm -rf "$work"

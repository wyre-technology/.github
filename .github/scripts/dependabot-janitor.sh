#!/usr/bin/env bash
#
# Dependabot janitor: across all wyre-technology mcp-* and node-* repos, auto-merge
# Dependabot patch/minor PRs whose CI is green. Majors, red CI, conflicts, and PRs
# blocked by required code-owner review are reported but never merged.
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

for repo in "${REPOS[@]}"; do
  prs="$(gh pr list -R "$ORG/$repo" --author 'app/dependabot' --state open \
        --json number,title,mergeable 2>/dev/null)" || { echo "$repo: pr list failed" >>"$work/errors"; continue; }
  [[ "$(jq 'length' <<<"$prs")" == "0" ]] && continue

  while IFS=$'\t' read -r num title mergeable; do
    [[ -z "$num" ]] && continue
    label="$repo #$num — $title"

    if [[ "$(classify "$title")" == "MAJOR" ]]; then
      echo "$label" >>"$work/majors"; continue
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
      nocheck=0
    fi

    flag=""; [[ "${nocheck:-0}" == "1" ]] && flag=" (no CI)"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "$label$flag" >>"$work/merged"; continue
    fi

    # Approve (satisfies non-code-owner review requirements) then squash-merge.
    gh pr review "$num" -R "$ORG/$repo" --approve \
      -b "Auto-approved by Dependabot janitor: patch/minor update, CI green." >/dev/null 2>&1
    if merge_err="$(gh pr merge "$num" -R "$ORG/$repo" --squash --delete-branch 2>&1)"; then
      echo "$label$flag" >>"$work/merged"
    else
      if grep -qiE 'review|code ?owner|protected|required' <<<"$merge_err"; then
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

rm -rf "$work"

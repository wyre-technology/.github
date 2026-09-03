#!/usr/bin/env bash
#
# Agent Merge Janitor: flags human/agent-authored (non-Dependabot) PRs on the
# repos in REPOS (default: "cortextos conduit", both under the WYRE-AI org —
# see the note above REPOS' default for the org-transfer history) that pass a
# tight, conservative eligibility bar for the low-risk auto-merge lane
# (task_1785685546659).
# Complements dependabot-janitor.sh, which only covers Dependabot PRs on
# -mcp/node- repos.
#
# THIS SCRIPT NEVER MERGES. Per the design's trust-model finding: the
# wyre-agent-fleet App credential (used to post the GO-signal review) is
# fleet-shared today, not scoped to a distinct reviewer identity —
# task_1784224475661 Step 3 (real per-agent GitHub identity) is not yet
# built, and mintInstallationToken() has no caller-identity concept at all.
# So a bot-authored Approve review is a real, verifiable signal that SOME
# process with fleet-level GitHub-App-secret access reviewed this at this
# exact commit — but not yet a genuine reviewer-vs-author separation
# guarantee. Until Aaron closes that gap (Infisical ACL scoping, or Step 3),
# a human keeps the final merge click. This script's job is to do the
# re-verification and produce a trustworthy backlog, nothing more.
#
# GO-signal mechanism: the reviewing agent, after doing real per-PR
# diligence (same discipline as the manual Task-1 merges: CI green,
# mergeable, diff read and matches title/description, no exclusion-path
# hits), posts a formal GitHub PR Review (--approve) using a minted
# wyre-agent-fleet App token — NOT a plain comment, which has no
# self-comment restriction and is trivially forgeable by anyone with PR
# comment access. A Review's `commit_id` is set by GitHub itself to the PR's
# head SHA at review time, so SHA-pinning falls out of the Review API's own
# semantics: any push after the review leaves the review's commit_id stale,
# and this script's re-check catches that automatically — no separate
# SHA-in-text convention needed.
#
#   GH_TOKEN=$(cortextos bus gh-app-token --org WYRE-AI) \
#     gh pr review <n> -R WYRE-AI/<repo> --approve \
#     -b "AUTO-MERGE-GO <reviewing-agent> <head-sha>"
#   gh pr edit <n> -R WYRE-AI/<repo> --add-label auto-merge-ready
#
# Env:
#   ORG        GitHub org (default: WYRE-AI)
#   REPOS      space-separated repo list (default: "cortextos conduit")
#   DRY_RUN    if "true" (default), classify + report only — never touches
#              labels or posts comments, even on a failed re-verify.
#   BACKLOG_FILE  path to write the human-readable summary (default:
#              agent-merge-backlog.md)
#
# Requires: gh CLI authenticated (GH_TOKEN) with pull_requests:write on the
# repos in scope, to read PR reviews/files and (in live mode) remove a stale
# label + post an explanation comment. Never posts approvals itself — that
# is the reviewing agent's job, done by hand, under their own diligence.
set -uo pipefail

# --- Org-transfer history (why ORG/REPOS look the way they do) -------------
# conduit moved from wyre-technology to WYRE-AI on 2026-08-25; cortextos
# followed on 2026-08-31 — both scanned repos now live under WYRE-AI. The
# wyre-agent-fleet GitHub App's installation moved with them (Aaron installed
# it on WYRE-AI 2026-09-03, confirmed live via `gh-app-token --org WYRE-AI`
# minting a real token, installation_id=158846229; task_1788354249320_29879105
# closed). A bare `gh pr list -R <org>/<repo> --label ... --json ...` (the
# exact call this script makes) does NOT error when "<org>/<repo>" doesn't
# resolve — it silently returns an empty `[]` at rc=0, which reads exactly
# like "repo scanned, zero eligible PRs." That's what made conduit's absence
# invisible for over a week after its own move (murph,
# task_1788354182960_04095147) — CORTEXTOS was still fine at the time because
# it hadn't moved yet; if ORG/REPOS ever again point at an org+repo pairing
# that's stale, the SAME silent-blind-spot shape recurs for whatever repo it
# hits. The unresolvable-repo guard below exists precisely so that keeps
# failing loudly instead of going blind again — if you're re-pointing this at
# a new org or repo, trust that guard's exit-1, not a clean "0 eligible."
ORG="${ORG:-WYRE-AI}"
REPOS="${REPOS:-cortextos conduit}"
DRY_RUN="${DRY_RUN:-true}"
BACKLOG_FILE="${BACKLOG_FILE:-agent-merge-backlog.md}"
LABEL="auto-merge-ready"

work="$(mktemp -d)"
for cat in eligible excluded no_go stale_go red pending conflicts no_ci errors; do : > "$work/$cat"; done

# ---------------------------------------------------------------------------
# Exclusion path patterns (deny-by-default). Grep -E, case-insensitive where
# noted. Seeded from conduit's own CODEOWNERS + tonight's incident classes +
# warden's security review (2026-08-02, cortextos control-plane surface).
# ---------------------------------------------------------------------------

# Hard path exclusions — any changed file matching any of these removes
# eligibility, full stop. One pattern per line for readability; joined with
# grep -E -f semantics via a temp file.
EXCLUDE_PATHS_REGEX='
(^|/)migrations/
^src/billing/
^src/reseller/
^\.github/workflows/
^\.github/scripts/
^Dockerfile
docker-compose.*\.ya?ml$
(^|/)terraform/
^k8s/
^scripts/deploy
^CODEOWNERS$
^dependabot\.ya?ml$
^src/daemon/
^src/bus/
^src/hooks/
^templates/
^community/
^package\.json$
^package-lock\.json$
^packages/.*/package\.json$
^yarn\.lock$
^pnpm-lock\.yaml$
approval
human-task
'
# Keyword path exclusion (case-insensitive) — catches auth/credential/etc
# paths that don't fall under the hard list above.
EXCLUDE_KEYWORDS_REGEX='(auth|oauth|credential|secret|token|session|permission|security|sso|saml)'

DIFF_FILES_CAP=15
DIFF_LINES_CAP=400

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# CI status. Mirrors dependabot-janitor.sh's bucket-aware check: rc=8 pending,
# rc=1 failing, rc=0 needs a second look because "all checks skipping" is
# NOT proof of green (the sentinelone-mcp#31 lesson) — treat as no-CI.
ci_status() {
  local n="$1" repo="$2"
  local out rc
  out="$(gh pr checks "$n" -R "$ORG/$repo" 2>&1)"; rc=$?
  if [[ $rc -eq 8 ]]; then echo "PENDING"; return; fi
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'no checks' <<<"$out"; then echo "NO_CI"; return; fi
    echo "RED"; return
  fi
  local buckets total skipping
  buckets="$(gh pr checks "$n" -R "$ORG/$repo" --json bucket 2>/dev/null)"
  total="$(jq 'length' <<<"${buckets:-[]}" 2>/dev/null || echo 0)"
  skipping="$(jq '[.[] | select(.bucket=="skipping")] | length' <<<"${buckets:-[]}" 2>/dev/null || echo 0)"
  if [[ "$total" -gt 0 && "$total" == "$skipping" ]]; then echo "NO_CI"; return; fi
  echo "GREEN"
}

# Path-exclusion check. Returns 0 (excluded) or 1 (clean) via exit code;
# prints the first matching file+pattern to stdout when excluded.
check_path_exclusions() {
  local files="$1"
  local pat
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    local hit
    hit="$(grep -E "$pat" <<<"$files" | head -1)"
    if [[ -n "$hit" ]]; then
      echo "$hit (pattern: $pat)"
      return 0
    fi
  done <<<"$EXCLUDE_PATHS_REGEX"
  local khit
  khit="$(grep -iE "$EXCLUDE_KEYWORDS_REGEX" <<<"$files" | head -1)"
  if [[ -n "$khit" ]]; then
    echo "$khit (keyword pattern)"
    return 0
  fi
  return 1
}

# Test-tamper check: any deleted *.test.ts/*.spec.ts, or a modified test
# file whose it(/test(/expect( call count nets negative. Needs the PR
# files API (gives per-file status + patch), not just changed-file names —
# a diff-size cap alone misses "delete one small high-value test".
check_test_tamper() {
  local n="$1" repo="$2"
  local files_json
  files_json="$(gh api "repos/$ORG/$repo/pulls/$n/files" --paginate 2>/dev/null)" || { echo "could not fetch PR files"; return 0; }
  local hit
  hit="$(jq -r '.[] | select(.filename | test("\\.(test|spec)\\.tsx?$")) | select(.status=="removed") | .filename' <<<"$files_json" | head -1)"
  if [[ -n "$hit" ]]; then
    echo "deleted test file: $hit"
    return 0
  fi
  local modified
  modified="$(jq -r '.[] | select(.filename | test("\\.(test|spec)\\.tsx?$")) | select(.status=="modified") | .filename' <<<"$files_json")"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local patch added removed
    patch="$(jq -r --arg f "$f" '.[] | select(.filename==$f) | .patch // empty' <<<"$files_json")"
    [[ -z "$patch" ]] && continue
    added="$(grep -cE '^\+.*\b(it|test|expect)\(' <<<"$patch" || true)"
    removed="$(grep -cE '^-.*\b(it|test|expect)\(' <<<"$patch" || true)"
    if [[ "${removed:-0}" -gt "${added:-0}" ]]; then
      echo "net-negative assertion count in $f (added=$added removed=$removed)"
      return 0
    fi
  done <<<"$modified"
  return 1
}

# Most recent bot-authored APPROVED review + its pinned commit_id.
# Prints "<login> <commit_id>" or nothing if none found.
latest_bot_approval() {
  local n="$1" repo="$2"
  gh api "repos/$ORG/$repo/pulls/$n/reviews" --paginate 2>/dev/null \
    | jq -r '[.[] | select(.state=="APPROVED") | select(.user.type=="Bot")] | sort_by(.submitted_at) | last | select(. != null) | "\(.user.login) \(.commit_id)"'
}

# Unresolvable-repo guard. `gh pr list -R $ORG/$repo --label ... --json ...`
# (the call scan_one_repo's caller makes below) does NOT error when
# "$ORG/$repo" doesn't resolve — moved, renamed, deleted, or the App just
# lacks access — it silently prints an empty `[]` at rc=0, which reads
# exactly like "repo scanned, zero eligible PRs." That was the whole
# conduit incident (see the note above REPOS' default). Returns 0 (resolves)
# or 1 (does not) via exit code; never prints on the happy path.
check_repo_resolves() {
  local repo="$1"
  gh repo view "$ORG/$repo" --json name >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Main scan
#
# PR_OVERRIDE (optional): space-separated "repo:number" pairs, e.g.
# "cortextos:14 cortextos:16". Bypasses the open+labeled PR listing (and the
# REPOS pre-flight guard below, which only gates that listing) entirely —
# used for retroactive validation against already closed/merged PRs
# (label/open-state don't apply retroactively; CI/review history does, since
# GitHub keeps it). Live/scheduled runs never set this. Each pair is always
# resolved against $ORG, same as REPOS — it cannot target a repo under a
# different org.
# ---------------------------------------------------------------------------

scan_one_repo() {
  local repo="$1" prs="$2"
  [[ "$(jq 'length' <<<"$prs")" == "0" ]] && return

  while IFS=$'\t' read -r num title author is_draft mergeable _merge_state head_sha; do
    [[ -z "$num" ]] && continue
    label_line="$repo #$num — $title (@$author)"

    if [[ "$author" == "dependabot"* || "$author" == "app/dependabot" ]]; then
      continue   # dependabot-janitor's lane, not ours
    fi
    if [[ "$is_draft" == "true" ]]; then
      echo "$label_line (draft)" >>"$work/excluded"; continue
    fi
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      echo "$label_line" >>"$work/conflicts"; continue
    fi

    files="$(gh pr diff "$num" -R "$ORG/$repo" --name-only 2>/dev/null)"
    stat_json="$(gh pr view "$num" -R "$ORG/$repo" --json additions,deletions,changedFiles 2>/dev/null)"
    additions="$(jq -r '.additions // 0' <<<"$stat_json")"
    deletions="$(jq -r '.deletions // 0' <<<"$stat_json")"
    changed="$(jq -r '.changedFiles // 0' <<<"$stat_json")"
    total_lines="$((additions + deletions))"

    if excl_hit="$(check_path_exclusions "$files")"; then
      echo "$label_line -- $excl_hit" >>"$work/excluded"; continue
    fi
    if [[ "$changed" -gt "$DIFF_FILES_CAP" || "$total_lines" -gt "$DIFF_LINES_CAP" ]]; then
      echo "$label_line -- diff too large ($changed files / $total_lines lines, cap $DIFF_FILES_CAP/$DIFF_LINES_CAP)" >>"$work/excluded"; continue
    fi
    if tamper_hit="$(check_test_tamper "$num" "$repo")"; then
      echo "$label_line -- $tamper_hit" >>"$work/excluded"; continue
    fi

    ci="$(ci_status "$num" "$repo")"
    case "$ci" in
      PENDING) echo "$label_line" >>"$work/pending"; continue ;;
      RED) echo "$label_line" >>"$work/red"; continue ;;
      NO_CI) echo "$label_line" >>"$work/no_ci"; continue ;;
    esac

    go="$(latest_bot_approval "$num" "$repo")"
    if [[ -z "$go" ]]; then
      echo "$label_line -- no bot-authored Approve review found" >>"$work/no_go"; continue
    fi
    go_login="${go%% *}"; go_sha="${go##* }"
    if [[ "$go_sha" != "$head_sha" ]]; then
      echo "$label_line -- bot review ($go_login) is pinned to $go_sha, current head is $head_sha (stale — new commit pushed since review)" >>"$work/stale_go"
      if [[ "$DRY_RUN" != "true" ]]; then
        gh pr edit "$num" -R "$ORG/$repo" --remove-label "$LABEL" >/dev/null 2>&1 || true
        gh pr comment "$num" -R "$ORG/$repo" -b "Auto-merge janitor: removing \`$LABEL\` — the bot review is pinned to $go_sha but the current head is $head_sha. A new push invalidates the prior GO signal; re-review needed at the current commit." >/dev/null 2>&1 || true
      fi
      continue
    fi

    # Full pass. Still human-click-gated (per design) -- report only, never merge.
    echo "$label_line -- reviewed by $go_login at $go_sha, CI green, mergeable, clean of all exclusions" >>"$work/eligible"
  done < <(jq -r '.[] | "\(.number)\t\(.title)\t\(.author.login)\t\(.isDraft)\t\(.mergeable)\t\(.mergeStateStatus)\t\(.headRefOid)"' <<<"$prs")
}

if [[ -n "${PR_OVERRIDE:-}" ]]; then
  for pair in $PR_OVERRIDE; do
    repo="${pair%%:*}"; num="${pair##*:}"
    one="$(gh pr view "$num" -R "$ORG/$repo" \
          --json number,title,author,isDraft,mergeable,mergeStateStatus,headRefOid 2>/dev/null)" \
      || { echo "$repo #$num: pr view failed" >>"$work/errors"; continue; }
    scan_one_repo "$repo" "[$one]"
  done
else
  # Pre-flight: verify every repo in REPOS actually resolves under $ORG
  # BEFORE any scanning starts. See check_repo_resolves() above for why this
  # can't be left to the pr-list call itself to catch. Run once per repo,
  # up front, so a bad REPOS entry is one loud failure instead of N silent
  # empty scans.
  unresolvable=()
  for repo in $REPOS; do
    check_repo_resolves "$repo" || unresolvable+=("$ORG/$repo")
  done
  if [[ "${#unresolvable[@]}" -gt 0 ]]; then
    echo "FATAL: the following repo(s) in REPOS do not resolve under ORG=$ORG: ${unresolvable[*]}" >&2
    echo "Refusing to scan — a repo that doesn't resolve returns an empty PR list, not an error, and would otherwise be silently reported as \"zero eligible PRs\" instead of \"unreachable.\"" >&2
    echo "Fix REPOS/ORG (has the repo moved orgs, been renamed, or deleted?) or confirm the GitHub App is installed where the repo now lives, then re-run." >&2
    rm -rf "$work"
    exit 1
  fi

  for repo in $REPOS; do
    prs="$(gh pr list -R "$ORG/$repo" --state open --label "$LABEL" \
          --json number,title,author,isDraft,mergeable,mergeStateStatus,headRefOid,reviewDecision 2>/dev/null)" \
      || { echo "$repo: pr list failed" >>"$work/errors"; continue; }
    scan_one_repo "$repo" "$prs"
  done
fi

# ---- Summary ----
count() { wc -l <"$work/$1" | tr -d ' '; }
section() { local t="$1" f="$2"; echo "### $t ($(count "$f"))"; [[ -s "$work/$f" ]] && sed 's/^/- /' "$work/$f"; echo; }

{
  echo "## 🤖 Agent Merge Janitor — $(date -u +%Y-%m-%d\ %H:%MZ)"
  echo "- Repos scanned: $REPOS"
  echo "- Human click still required to actually merge (see task_1785685546659 design — reviewer/author separation not yet guaranteed)."
  [[ "$DRY_RUN" == "true" ]] && echo "- **DRY RUN** (no labels/comments touched)"
  echo
  section "✅ Ready — human, please merge"      eligible
  section "🚫 Excluded (path/size/test-tamper)"  excluded
  section "⏳ Stale GO — re-review needed"       stale_go
  section "❓ No GO signal yet"                  no_go
  section "❌ Red CI"                            red
  section "⚪ No CI to verify"                    no_ci
  section "⚠️ Conflicts"                         conflicts
  section "⌛ Pending CI (retry next run)"        pending
  section "💥 Errors"                            errors
} | tee "$work/summary.md"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$work/summary.md" >>"$GITHUB_STEP_SUMMARY"

{
  echo "<!-- Generated by agent-merge-janitor.sh — do not edit by hand. -->"
  echo "# Agent-merge backlog needing human attention"
  echo
  echo "_Last updated: $(date -u +%Y-%m-%dT%H:%MZ)_"
  cat "$work/summary.md"
} > "$BACKLOG_FILE"

rm -rf "$work"

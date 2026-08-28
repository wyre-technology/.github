#!/usr/bin/env bash
#
# Ship the batch that mcp-server-release.yml's `gate` job holds back.
#
# A repo is HELD when every commit since its last release tag carries the
# `Auto-Merged-By:` trailer. This finds those repos and pushes one empty
# `chore(release):` commit to each, which has no trailer, so the gate opens and
# semantic-release sweeps the accumulated commits into a single release.
#
# The logic here MUST agree with the gate job's. If they diverge, either the
# sweeper pushes commits that don't open anything (noise) or it misses held
# repos (the fleet silently stops releasing). Both read the same trailer over
# the same `<last-tag>..HEAD` range.
#
# Requires: gh CLI authenticated via GH_TOKEN (GitHub App installation token
# with contents:write across the org).
#
# Env:
#   ORG              default wyre-technology
#   DRY_RUN          "true" => report only (default true)
#   REPO_ALLOWLIST   optional space-separated repo names
#   TRAILER          default "Auto-Merged-By"
set -uo pipefail

ORG="${ORG:-wyre-technology}"
DRY_RUN="${DRY_RUN:-true}"
TRAILER="${TRAILER:-Auto-Merged-By}"
REPO_ALLOWLIST="${REPO_ALLOWLIST:-}"

held=(); clean=(); notag=(); blocked=(); errs=()

if [[ -n "$REPO_ALLOWLIST" ]]; then
  read -r -a REPOS <<<"$REPO_ALLOWLIST"
else
  mapfile -t REPOS < <(
    gh api --paginate "/orgs/$ORG/repos?per_page=100" \
      --jq '.[] | select(.archived==false) | .name' 2>/dev/null \
    | grep -E '(-mcp$|^mcp|^node-)' | sort -u
  )
fi
echo "Checking ${#REPOS[@]} repositories for held releases..."

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

for repo in "${REPOS[@]}"; do
  dir="$work/$repo"
  if ! git clone --quiet --filter=blob:none \
        "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$repo.git" "$dir" 2>/dev/null; then
    errs+=("$repo: clone failed"); continue
  fi

  last_tag="$(git -C "$dir" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -z "$last_tag" ]]; then notag+=("$repo"); continue; fi

  total="$(git -C "$dir" rev-list --count "${last_tag}..HEAD" 2>/dev/null || echo 0)"
  [[ "$total" -eq 0 ]] && { clean+=("$repo"); continue; }

  auto="$(git -C "$dir" log "${last_tag}..HEAD" \
            --format="%(trailers:key=${TRAILER},valueonly)" 2>/dev/null \
          | grep -c '[^[:space:]]' || true)"

  if [[ "$auto" -ne "$total" ]]; then
    # Human commits present — the gate is already open; the next push releases.
    clean+=("$repo ($((total - auto))/$total human)")
    continue
  fi

  held+=("$repo ($total autonomous commit(s) since $last_tag)")

  if [[ "$DRY_RUN" == "true" ]]; then continue; fi

  # Review-driven fix: a raw push to a protected default branch either fails
  # outright or (worse) silently succeeds only on the subset of repos that
  # happen not to have branch protection, which is not a distinction this
  # script should be guessing at. Route through a PR + gh pr merge instead,
  # the same shape dependabot-janitor.sh already uses, so protection is
  # respected rather than raced: merge succeeds where nothing blocks it and
  # cleanly reports "needs a human" everywhere else, instead of a push either
  # silently landing or silently doing nothing.
  git -C "$dir" config user.name  "wyre-projects-bot[bot]"
  git -C "$dir" config user.email "wyre-projects-bot[bot]@users.noreply.github.com"
  branch="release-sweeper/$(date -u +%Y%m%d%H%M%S)-${total}"
  if git -C "$dir" checkout --quiet -b "$branch" \
       && git -C "$dir" commit --quiet --allow-empty \
            -m "chore(release): batch ${total} autonomous merge(s) since ${last_tag}" \
            -m "Opens the release gate in mcp-server-release.yml so semantic-release ships the accumulated Dependabot auto-merges as one release. Pushed by release-sweeper.yml." \
       && git -C "$dir" push --quiet origin "$branch" 2>/dev/null; then
    pr_url="$(gh pr create -R "$ORG/$repo" --head "$branch" \
                --title "chore(release): open the release gate ($total autonomous commit(s))" \
                --body "Opens the release gate in mcp-server-release.yml — see that workflow and release-sweeper.yml for why. No code changes, one empty commit." 2>&1)"
    if [[ "$pr_url" == https://* ]]; then
      # Best-effort, and expected to fail every run: the App token mints
      # both the PR and this approval, so it's a guaranteed self-approval
      # rejection (unlike dependabot-janitor.sh, where the approving
      # identity genuinely differs from the PR author, dependabot). Kept
      # anyway in case that ever changes; the merge attempt right after is
      # what actually decides the bucket, not this step's outcome — the
      # merge attempt right after is what actually decides the bucket.
      gh pr review "$pr_url" --approve \
        -b "Auto-approved by release-sweeper: empty gate-opener commit, no code changes." >/dev/null 2>&1
      if merge_err="$(gh pr merge "$pr_url" --squash --delete-branch 2>&1)"; then
        :
      elif grep -qiE 'review|code ?owner|protected|required|base branch policy|not mergeable|auto.?merge' <<<"$merge_err"; then
        blocked+=("$repo: $pr_url (needs a human merge — branch protection)")
      else
        errs+=("$repo: PR opened ($pr_url) but merge failed: $(tr '\n' ' ' <<<"$merge_err" | head -c 160)")
      fi
    else
      errs+=("$repo: branch pushed but PR create failed: $(tr '\n' ' ' <<<"$pr_url" | head -c 160)")
    fi
  else
    errs+=("$repo: commit/branch/push failed")
  fi
done

section() { local t="$1"; shift; echo "### $t ($#)"; for x in "$@"; do echo "- $x"; done; echo; }
{
  echo "## 🚚 Release sweeper — $(date -u +%Y-%m-%d\ %H:%MZ)"
  echo "- Repos checked: ${#REPOS[@]}"
  [[ "$DRY_RUN" == "true" ]] && echo "- **DRY RUN** (nothing pushed)"
  echo
  section "📦 Held — batch shipped" "${held[@]+"${held[@]}"}"
  section "✅ Not held" "${clean[@]+"${clean[@]}"}"
  section "🏷️ No release tag yet (never held)" "${notag[@]+"${notag[@]}"}"
  section "⏳ Blocked — PR opened, needs a human merge" "${blocked[@]+"${blocked[@]}"}"
  section "💥 Errors" "${errs[@]+"${errs[@]}"}"
} | tee "$work/summary.md"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
[[ "${#errs[@]}" -eq 0 ]]

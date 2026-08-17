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

held=(); clean=(); notag=(); errs=()

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

  git -C "$dir" config user.name  "wyre-projects-bot[bot]"
  git -C "$dir" config user.email "wyre-projects-bot[bot]@users.noreply.github.com"
  if git -C "$dir" commit --quiet --allow-empty \
       -m "chore(release): batch ${total} autonomous merge(s) since ${last_tag}" \
       -m "Opens the release gate in mcp-server-release.yml so semantic-release ships the accumulated Dependabot auto-merges as one release. Pushed by release-sweeper.yml." \
     && git -C "$dir" push --quiet origin HEAD 2>/dev/null; then
    :
  else
    errs+=("$repo: commit/push failed")
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
  section "💥 Errors" "${errs[@]+"${errs[@]}"}"
} | tee "$work/summary.md"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
[[ "${#errs[@]}" -eq 0 ]]

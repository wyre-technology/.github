#!/usr/bin/env bash
#
# Set required_status_checks on *-mcp repos that have substantive PR CI.
#
# WHY: a fleet survey on 2026-08-17 found required_status_checks == null on
# 20/20 sampled *-mcp repos. Branch protection required 1 review + code-owner
# review, but CI passing was enforced NOWHERE at the branch level. The only CI
# gate in the system was dependabot-janitor's own `gh pr checks` read — and that
# read has been wrong twice (#36 all-skipping vacuous green, #38). There was no
# defence in depth behind it.
#
# TWO SAFETY PROPERTIES, both load-bearing:
#
# 1. READ-MERGE-WRITE. PUT /branches/{branch}/protection REPLACES the entire
#    protection object. Sending only required_status_checks would silently drop
#    required_pull_request_reviews (1 approval + code-owner) on every repo it
#    touched. This reads current protection and re-sends it with the checks
#    added.
#
# 2. INTERSECTION-DERIVED CONTEXTS. A required check whose name never reports
#    blocks every PR in that repo forever. Path-filtered workflows (e.g.
#    auvik-mcp's `docker-build`) produce no check-run at all on unrelated PRs,
#    so requiring one hangs those PRs permanently. Contexts come from
#    derive-contexts.sh, which keeps only names present on EVERY sampled recent
#    PR. Never hand-write this list.
#
# Env:
#   CONTEXTS_TSV  repo<TAB>always|sep|list<TAB>sometimes  (required)
#   BACKUP_DIR    where to write per-repo rollback JSON    (required)
#   DRY_RUN       "true" => print planned changes, write nothing (default true)
#   ORG           default wyre-technology
set -uo pipefail

ORG="${ORG:-wyre-technology}"
DRY_RUN="${DRY_RUN:-true}"
CONTEXTS_TSV="${CONTEXTS_TSV:?set CONTEXTS_TSV}"
BACKUP_DIR="${BACKUP_DIR:?set BACKUP_DIR}"
mkdir -p "$BACKUP_DIR"

ok=0; skipped=0; failed=0

while IFS=$'\t' read -r repo always _sometimes; do
  [[ -z "$repo" || -z "$always" ]] && { echo "SKIP $repo (no universal contexts)"; skipped=$((skipped+1)); continue; }

  cur="$(gh api "/repos/$ORG/$repo/branches/main/protection" 2>/dev/null)" || {
    echo "SKIP $repo (no branch protection to merge into)"; skipped=$((skipped+1)); continue; }

  printf '%s' "$cur" > "$BACKUP_DIR/$repo.json"

  # Build the contexts array from the pipe-separated universal list.
  contexts_json="$(printf '%s' "$always" | jq -R 'split("|") | map(select(length>0))')"

  # Read-merge-write: re-send every existing protection field, adding checks.
  # `null` for a field means "not configured" and must be sent as null, not omitted.
  payload="$(jq -n \
    --argjson contexts "$contexts_json" \
    --argjson cur "$cur" \
    '{
      required_status_checks: {
        strict: ($cur.required_status_checks.strict // false),
        contexts: $contexts
      },
      enforce_admins: ($cur.enforce_admins.enabled // false),
      required_pull_request_reviews: (
        if $cur.required_pull_request_reviews == null then null
        else {
          dismiss_stale_reviews: ($cur.required_pull_request_reviews.dismiss_stale_reviews // false),
          require_code_owner_reviews: ($cur.required_pull_request_reviews.require_code_owner_reviews // false),
          required_approving_review_count: ($cur.required_pull_request_reviews.required_approving_review_count // 1)
        } end
      ),
      restrictions: null,
      allow_force_pushes: ($cur.allow_force_pushes.enabled // false),
      allow_deletions: ($cur.allow_deletions.enabled // false),
      required_conversation_resolution: ($cur.required_conversation_resolution.enabled // false),
      required_linear_history: ($cur.required_linear_history.enabled // false),
      block_creations: ($cur.block_creations.enabled // false)
    }')"

  had="$(jq -r '.required_status_checks.contexts // [] | join(", ")' <<<"$cur")"
  want="$(jq -r '.required_status_checks.contexts | join(", ")' <<<"$payload")"
  # Verify the merge preserved reviews before writing anything.
  rev_before="$(jq -c '.required_pull_request_reviews | if .==null then null else {d:.dismiss_stale_reviews,c:.require_code_owner_reviews,n:.required_approving_review_count} end' <<<"$cur")"
  rev_after="$(jq -c '.required_pull_request_reviews | if .==null then null else {d:.dismiss_stale_reviews,c:.require_code_owner_reviews,n:.required_approving_review_count} end' <<<"$payload")"
  if [[ "$rev_before" != "$rev_after" ]]; then
    echo "FAIL $repo — review settings would change ($rev_before -> $rev_after); refusing"
    failed=$((failed+1)); continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf 'PLAN %-32s checks: [%s] -> [%s]   reviews preserved: %s\n' "$repo" "$had" "$want" "$rev_after"
    ok=$((ok+1)); continue
  fi

  if err="$(gh api -X PUT "/repos/$ORG/$repo/branches/main/protection" --input - <<<"$payload" 2>&1 >/dev/null)"; then
    printf 'OK   %-32s -> [%s]\n' "$repo" "$want"; ok=$((ok+1))
  else
    printf 'FAIL %-32s %s\n' "$repo" "$(tr '\n' ' ' <<<"$err" | head -c 140)"; failed=$((failed+1))
  fi
done < "$CONTEXTS_TSV"

echo
echo "planned/applied=$ok skipped=$skipped failed=$failed  (DRY_RUN=$DRY_RUN)"
echo "rollback JSON in $BACKUP_DIR"
[[ "$failed" -eq 0 ]]

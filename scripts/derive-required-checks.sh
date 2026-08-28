#!/usr/bin/env bash
# Derive SAFE required_status_checks contexts per repo.
#
# A required check whose name never reports blocks every PR in the repo
# permanently. A check that is path-filtered at the WORKFLOW level never
# produces a check-run at all on unrelated PRs -- so requiring it hangs those
# PRs forever. (Job-level `if:` skips are fine: they report conclusion
# "skipped", which GitHub counts as satisfied.)
#
# So: sample the last N merged/open PRs per repo and keep only the check names
# that appear on EVERY sampled PR. Intersection, not union. Sample-of-one is
# exactly how you'd pick up a path-filtered check by accident.
set -uo pipefail
SP="${SP:-$(dirname "$0")}"
ORG=wyre-technology
SAMPLE=${SAMPLE:-5}

: > "$SP/contexts.tsv"

# Non-CI checks that must never be required: org automation, bots, and the
# release path (which is push-to-main only and never reports on a PR).
EXCLUDE_RE='add-to-project|triage|smith|^Release|deploy|CodeQL'

while IFS=$'\t' read -r repo _; do
  # newest PRs, any state, to get a representative spread
  mapfile -t shas < <(gh api "/repos/$ORG/$repo/pulls?state=all&per_page=$SAMPLE&sort=updated&direction=desc" \
                        --jq '.[].head.sha' 2>/dev/null </dev/null)
  if [[ "${#shas[@]}" -eq 0 ]]; then
    printf '%s\tNO-PRS\t\n' "$repo" >> "$SP/contexts.tsv"; continue
  fi

  declare -A seen=() ; n=0
  for sha in "${shas[@]}"; do
    names="$(gh api "/repos/$ORG/$repo/commits/$sha/check-runs?per_page=100" \
              --jq '[.check_runs[] | select(.conclusion=="success" or .conclusion=="failure") | .name] | unique | .[]' \
              2>/dev/null </dev/null | grep -vE "$EXCLUDE_RE")"
    [[ -z "$names" ]] && continue
    n=$((n+1))
    while IFS= read -r nm; do
      [[ -z "$nm" ]] && continue
      seen["$nm"]="${seen["$nm"]:-0}"
      seen["$nm"]=$(( ${seen["$nm"]} + 1 ))
    done <<<"$names"
  done

  if [[ "$n" -eq 0 ]]; then
    printf '%s\tNO-CHECKS\t\n' "$repo" >> "$SP/contexts.tsv"
    unset seen; continue
  fi

  # keep only names present on EVERY sampled commit that had checks
  always=(); sometimes=()
  for nm in "${!seen[@]}"; do
    if [[ "${seen[$nm]}" -eq "$n" ]]; then always+=("$nm"); else sometimes+=("$nm"); fi
  done
  IFS=$'\n' always_sorted=($(printf '%s\n' "${always[@]:-}" | sort)); unset IFS
  IFS=$'\n' some_sorted=($(printf '%s\n' "${sometimes[@]:-}" | sort)); unset IFS

  printf '%s\t%s\t%s\n' "$repo" \
    "$(printf '%s|' "${always_sorted[@]:-}" | sed 's/|$//')" \
    "$(printf '%s|' "${some_sorted[@]:-}" | sed 's/|$//')" >> "$SP/contexts.tsv"
  unset seen
done < "$SP/realci.tsv"

echo "derived for $(wc -l < "$SP/contexts.tsv") repos"
echo
echo "=== repos where NOTHING is universal (unsafe to set) ==="
awk -F'\t' '$2==""{print "  "$1"   (inconsistent: "$3")"}' "$SP/contexts.tsv"
echo
echo "=== checks that are only SOMETIMES present (excluded, would hang PRs) ==="
awk -F'\t' '$3!=""{print "  "$1": "$3}' "$SP/contexts.tsv" | head -20

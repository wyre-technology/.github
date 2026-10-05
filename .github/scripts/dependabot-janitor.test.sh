#!/usr/bin/env bash
# Unit tests for the pure classifiers in dependabot-janitor.sh.
#
# Run with:  bash .github/scripts/dependabot-janitor.test.sh
# Requires bash >= 4 (see the BASH_REMATCH self-check below).
#
# The functions are extracted with sed rather than sourced, so the production
# script needs no test-only guard and the sweep never runs here. `gh` is stubbed
# as a shell function, which bash resolves ahead of PATH.
#
# Fixtures are REAL Dependabot bodies captured 2026-08-17, not invented shapes.
# The CHANGELOG records what invented fixtures cost last time: a check "tested
# only against invented shapes that encoded the same wrong assumption."

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dependabot-janitor.sh"
# No $ORG here: classify() fetches "repos/$repo/pulls/$num" directly, since
# $repo is already "org/name" as of the dual-org REPOS format (main, #66).

# --- self-check ------------------------------------------------------------
# macOS /bin/bash is 3.2, where BASH_REMATCH does not populate here. A scan run
# under it silently compared "" to "" and reported every PR clean -- a false
# negative that hid 42 cross-major PRs on 2026-08-17. Refuse to run rather than
# report a comforting wrong answer.
_probe='Updates `x` from 9.1.0 to 10.0.0'
if [[ "$_probe" =~ from[[:space:]]+([0-9][^[:space:]]*)[[:space:]]+to[[:space:]]+([0-9][^[:space:]]*) ]]; then
  if [[ -z "${BASH_REMATCH[1]:-}" ]]; then
    echo "FATAL: BASH_REMATCH not populated under bash $BASH_VERSION — tests would false-pass." >&2
    exit 1
  fi
else
  echo "FATAL: probe regex did not match under bash $BASH_VERSION." >&2
  exit 1
fi

# major_of() is a one-liner (its closing brace is not at column 0), so it gets a
# single-line print. Using a /,/^}/ range for it would run on and swallow
# classify() as well, then the second range would emit classify() a second time —
# producing duplicated, syntactically broken input to eval.
eval "$(sed -n '/^major_of()/p; /^classify()/,/^}/p' "$SCRIPT")"
declare -F classify >/dev/null || { echo "FATAL: could not extract classify() from $SCRIPT" >&2; exit 1; }

pass=0; fail=0
BODY=""
# Stub: classify() fetches the PR body via `gh api ... /pulls/N`.
gh() { printf '%s' "$BODY"; }

check() { # check <desc> <expected> <title> [num] [repo]
  local desc="$1" want="$2" title="$3" num="${4:-1}" repo="${5:-wyre-technology/test-mcp}"
  local got; got="$(classify "$title" "$num" "$repo")"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass+1)); printf '  ok   %s\n' "$desc"
  else
    fail=$((fail+1)); printf '  FAIL %s — want %s, got %s\n' "$desc" "$want" "$got"
  fi
}

echo "major_of()"
[[ "$(major_of 9.39.4)" == "9"  ]] && { pass=$((pass+1)); echo "  ok   9.39.4 -> 9"; }  || { fail=$((fail+1)); echo "  FAIL 9.39.4"; }
[[ "$(major_of 10.0.1)" == "10" ]] && { pass=$((pass+1)); echo "  ok   10.0.1 -> 10"; } || { fail=$((fail+1)); echo "  FAIL 10.0.1"; }
[[ "$(major_of ^6.0.3)" == "6"  ]] && { pass=$((pass+1)); echo "  ok   ^6.0.3 -> 6"; }  || { fail=$((fail+1)); echo "  FAIL ^6.0.3"; }

echo
echo "classify() — single-package PRs (unchanged behaviour)"
check "patch bump -> ELIGIBLE" ELIGIBLE 'chore(deps): bump foo from 1.2.3 to 1.2.4'
check "minor bump -> ELIGIBLE" ELIGIBLE 'chore(deps): bump foo from 1.2.3 to 1.3.0'
check "major bump -> MAJOR"    MAJOR    'chore(deps): bump foo from 1.2.3 to 2.0.0'
check "unparseable -> MAJOR"   MAJOR    'chore(deps): update everything'

echo
echo "REGRESSION: grouped PRs with a hidden cross-major (the #23 hole)"
# Real body, abnormal-mcp#50, captured 2026-08-17. main's blanket
# `group in title -> ELIGIBLE` shortcut would auto-merge this untouched.
BODY='Bumps the dev-dependencies group with 10 updates:

Updates `@eslint/js` from 9.39.4 to 10.0.1
Updates `@modelcontextprotocol/ext-apps` from 1.7.4 to 1.7.5
Updates `@semantic-release/changelog` from 6.0.3 to 7.0.0
'
check "grouped w/ @eslint/js 9->10 + changelog 6->7 -> MAJOR" MAJOR \
  'deps-dev(deps-dev): bump the dev-dependencies group with 10 updates'

# Real body shape, salesbuildr-mcp#55 — a Docker base-image major, and the one
# offender NOT covered by is_dev_major's dev/CI allowlist.
BODY='Bumps node from 22-alpine to 26-alpine.

Updates `node` from 22-alpine to 26-alpine
'
check "grouped w/ runtime node 22->26 base image -> MAJOR" MAJOR \
  'chore(deps): bump the docker group with 1 update'

echo
echo "classify() — grouped PRs that are genuinely same-major stay ELIGIBLE"
BODY='Bumps the dev-dependencies group with 3 updates:

Updates `vitest` from 3.1.0 to 3.2.4
Updates `typescript` from 5.6.2 to 5.7.0
Updates `@types/node` from 22.1.0 to 22.9.0
'
check "all same-major -> ELIGIBLE (no behaviour change)" ELIGIBLE \
  'deps-dev(deps-dev): bump the dev-dependencies group with 3 updates'

echo
echo "classify() — fail-closed paths"
BODY=''
check "empty body -> MAJOR"                 MAJOR 'bump the x group with 2 updates'
BODY='Some prose with no dependabot markers at all.'
check "zero parseable markers -> MAJOR"     MAJOR 'bump the x group with 2 updates'
BODY='Bumps the group.

Updates `weird-pkg` from latest to newest
'
check "unparseable marker -> MAJOR"         MAJOR 'bump the x group with 1 update'
BODY='Bumps the group.

Updates `ok-pkg` from 1.0.0 to 1.1.0
Updates `bad-pkg` from notasemver to 2.0.0
'
check "partial parse does not pass as all-clean -> MAJOR" MAJOR \
  'bump the x group with 2 updates'

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

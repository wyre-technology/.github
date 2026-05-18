#!/usr/bin/env bash
#
# backfill-gwp-diagnostics.sh — one-time backfill of the AllMetrics
# diagnostic setting onto every already-deployed gwp-* Container App.
#
# CONTEXT
#   The mcp-server-deploy.yml reusable workflow gained a "Route container
#   metrics to Log Analytics" step that ensures the `gwp-metrics-to-law`
#   diagnostic setting on each gwp-* CA at release time (wyre-technology/
#   .github#13). That covers FUTURE releases. The ~41 gwp-* CAs already
#   deployed before #13 have no such setting until their next release —
#   so the fleet-wide vendor saturation alert (conduit#149, a log-search
#   rule over AzureMetrics) would be blind to them.
#
#   This script applies the identical diagnostic setting to every existing
#   gwp-* CA, once, so #149 has the full fleet's metrics from day one.
#
# SAFETY
#   - Idempotent: `az monitor diagnostic-settings create` is an upsert on
#     the --name; re-running updates in place. Safe to re-run.
#   - Additive: creates a new named diagnostic setting; does not touch the
#     CA revision, ingress, env, or any existing diagnostic setting. No
#     container restart, no downtime.
#   - Reversible: `az monitor diagnostic-settings delete --name
#     gwp-metrics-to-law --resource <id>` removes it per-CA.
#
# REQUIRES
#   - az CLI logged in with Microsoft.Insights/diagnosticSettings/write on
#     the resource group (the deploy SP's Contributor role covers it).
#
# USAGE
#   ./backfill-gwp-diagnostics.sh                 # apply
#   DRY_RUN=1 ./backfill-gwp-diagnostics.sh       # list only, no writes

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-mcp-gateway-prod}"
LOG_ANALYTICS_WORKSPACE="${LOG_ANALYTICS_WORKSPACE:-mcpgw-prod-logs}"
DIAG_NAME="gwp-metrics-to-law"
DRY_RUN="${DRY_RUN:-0}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
WORKSPACE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LOG_ANALYTICS_WORKSPACE}"

mapfile -t APPS < <(
  az containerapp list -g "$RESOURCE_GROUP" \
    --query "[?starts_with(name,'gwp-')].name" -o tsv | sort
)

echo "Found ${#APPS[@]} gwp-* Container App(s) in ${RESOURCE_GROUP}"
[ "${#APPS[@]}" -eq 0 ] && { echo "nothing to do"; exit 0; }

ok=0; fail=0
for ca in "${APPS[@]}"; do
  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY_RUN would apply ${DIAG_NAME} -> ${ca}"
    continue
  fi
  aca_id="$(az containerapp show -n "$ca" -g "$RESOURCE_GROUP" --query id -o tsv)"
  if az monitor diagnostic-settings create \
       --name "$DIAG_NAME" \
       --resource "$aca_id" \
       --workspace "$WORKSPACE_ID" \
       --metrics '[{"category":"AllMetrics","enabled":true}]' \
       >/dev/null 2>&1; then
    echo "  ok   ${ca}"
    ok=$((ok + 1))
  else
    echo "  FAIL ${ca}"
    fail=$((fail + 1))
  fi
done

echo "---"
echo "applied: ${ok}  failed: ${fail}  total: ${#APPS[@]}"
[ "$fail" -eq 0 ]

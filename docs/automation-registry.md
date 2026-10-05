# WYRE Automation & Tooling Registry

**Source of truth.** This file (in `wyre-technology/.github`, PR-reviewed) is the
canonical registry of our automations, Slack apps, credentials, and vendor
relationships. A Slack canvas in the WYRE AI workspace mirrors it for
day-to-day reading — when they disagree, this file wins. When a real docs
platform exists (SharePoint pending the M365 tenant), this file migrates there.

**Rule:** any PR that adds, retires, or re-points an automation updates this
file in the same PR.

_Last updated: 2026-08-26 · Maintainer: Aaron Sachs (aaron@wyretechnology.com)_

---

## 1. Scheduled automations

### Revenue reporting (`WYRE-AI/revenue-report`)
- **What:** Three surfaces off one shared library:
  1. *Daily report* — MRR, ARR run-rate, conduit/gateway split, trial roster
     with conversion dates + card-on-file, day-over-day deltas.
  2. *Period revenue* (`workflow_dispatch`, `mode=period`) — cash collected
     in a range (paid invoices by paid-at − refunds): `mtd|qtd|ytd|
     last-month|last-30d|2026-07|jul|"YYYY-MM-DD YYYY-MM-DD"`.
  3. *`/revenue` Slack slash command* — live snapshot (no arg) or any period
     expression; replies in-channel.
- **Where:** `#sales-notifications` (WYRE AI Slack); daily weekdays
  ~10:45 UTC.
- **How:** `Revenue` workflow in `WYRE-AI/revenue-report` (snapshot →
  `metrics-data` branch, seeded with full conduit-era history → post). Slash
  command served by the **`revenue-slash` Cloudflare Worker** (source
  `worker/`, deployed on the "WYRE Main" account,
  `revenue-slash.wyre-main.workers.dev`) — verifies the Slack signature,
  ACKs, computes against Stripe, replies via `response_url` with bot-post
  fallback. Migrated 2026-08-26 from conduit's `Subscription Metrics`
  workflow (now disabled; conduit itself was transferred to `WYRE-AI/conduit`).
- **Credentials:** repo Actions secrets `STRIPE_METRICS_KEY` +
  `SLACK_REVENUE_BOT_TOKEN`; worker secrets add `SLACK_SIGNING_SECRET`
  (Infisical **secrets.wyre.ai**, `conduit` project,
  `REVENUE_SLASH_SIGNING_SECRET`). Stripe key = conduit-prod's
  `stripe-secret-key` Container App secret — rotate together.
- **Owner:** Aaron.

### Adoption Watcher
- **What:** Daily usage digest for both products — active orgs, tool calls,
  top orgs/vendors, plan mix, new signups (30d rolling, per-run deltas).
- **Where:** `#product-notifications` (WYRE AI), daily 14:05 UTC.
- **How:** `wyre-technology/adoption-watcher` (renamed from
  `gateway-adoption-watcher` 2026-08-20) `daily.yml` → `script/report.py`
  pulls `/api/admin/metrics` from conduit.wyre.ai + mcp.wyre.ai, posts one
  combined message as "Adoption Watcher" via the **WYRE Notifier** app.
  State snapshot committed to the repo each run.
- **Credentials:** `CONDUIT_ADMIN_TOKEN` (conduit-prod `admin-api-key`),
  `GATEWAY_ADMIN_TOKEN` (mcpgw-prod-kv `admin-api-key`) — repo secrets;
  `SLACK_NOTIFIER_BOT_TOKEN` (org secret).
- **Owner:** Aaron.

### Stars Watcher
- **What:** Daily external-reach digest — GitHub stars/clones/releases across
  the org, MCP Registry + Glama.ai coverage/freshness, PulseMCP traffic.
  Deliberately complementary to Adoption Watcher (reach vs usage), staggered
  14:00 vs 14:05 UTC.
- **Where:** `#github-activity` (WYRE AI), daily 14:00 UTC.
- **How:** `wyre-technology/stars-watcher` `daily.yml` → `script/report.py`,
  posts as "Stars Watcher" via **WYRE Notifier**.
- **Credentials:** `GH_API_TOKEN` (optional PAT for private-repo traffic),
  `SLACK_NOTIFIER_BOT_TOKEN` (org secret).
- **Owner:** Aaron.

### Graphify Archive drift alerts
- **What:** Alerts when gateway knowledge-graph drift is detected vs baseline
  (new drifted files / resolutions). Posts only on change.
- **Where:** `#github-activity` (WYRE AI).
- **How:** `wyre-technology/graphify-archive` `merge-and-alert.yml` →
  `scripts/drift_detect.py`, posts as "Graphify Archive" via **WYRE Notifier**.
- **Credentials:** `SLACK_NOTIFIER_BOT_TOKEN` (org secret).
- **Owner:** Aaron.

### Daily Conduit Simplification Pass
- **What:** Autonomous daily code-quality pass on conduit — one bounded,
  low-risk simplification PR per day (or a no-op). Never merges its own PRs.
- **Where:** GitHub PRs on `wyre-technology/conduit`; no Slack delivery.
- **How:** claude.ai scheduled routine (cloud agent), daily 13:00 UTC, on
  Aaron's wyretechnology claude.ai account.
- **Owner:** Aaron.

## 2. In-app notifiers (product code, event-driven)

### Conduit sales notifier
- **What:** Billing/lifecycle events — new signups, hot leads, seat-sync
  failures, cancellations, payment-at-risk, billing anomalies, managed-AI
  reconciliation anomalies.
- **Where:** `#sales-notifications` (WYRE AI), as "Conduit Billing".
- **How:** `src/billing/sales-notifier.ts` in conduit — `chat.postMessage`
  as the **WYRE Revenue Reporter** app. Legacy wyretalk webhook retained as
  fallback until that workspace is retired. Failures logged and swallowed
  (Slack must never block Stripe webhook ACKs).
- **Credentials:** `slack-sales-bot-token` in **conduit-prod-kv** Key Vault →
  `SLACK_SALES_BOT_TOKEN` env. Channel default in `src/config.ts`.
- **Owner:** Aaron.

### MCP Gateway sales notifier
- Same as above for the legacy gateway, as "Gateway Billing".
- **Credentials:** `slack-sales-bot-token` in **mcpgw-prod-kv**, bicep-gated by
  `hasSlackSalesBotToken` in `azure/params.prod.json`.
- **Owner:** Aaron.

## 3. Slack apps (WYRE AI workspace, team `T0BRHBB2TGW`)

### WYRE Revenue Reporter — app `A0BRQ4PLCPK`
- **Purpose:** All sales/revenue posting (daily report + both sales notifiers).
- **Manifest:** `wyre-technology/conduit` → `slack-app/revenue-reporter/`
  (includes README with rotation runbook + avatar asset).
- **Scopes:** `chat:write`, `chat:write.public`, `chat:write.customize`,
  `commands` (serves `/revenue`).
- **Token copies:** `SLACK_REVENUE_BOT_TOKEN` (conduit repo secret),
  `slack-sales-bot-token` (conduit-prod-kv, mcpgw-prod-kv),
  worker secret on `revenue-slash` (`SLACK_REVENUE_BOT_TOKEN`) and
  `WYRE-AI/revenue-report` repo secret.

### WYRE Notifier — app `A0BRK5LM57F`
- **Purpose:** Shared outbound bot for all CI/automation notifications; each
  consumer stamps its own `username` + `icon_emoji`.
- **Manifest:** `wyre-technology/.github` → `slack-app/notifier/`.
- **Scopes:** `chat:write`, `chat:write.public`, `chat:write.customize`,
  `canvases:write`, `channels:history`, `channels:join` (member of
  #sales-notifications for delivery verification).
- **Token:** `SLACK_NOTIFIER_BOT_TOKEN` — **org-level** Actions secret,
  visible to all repos.

**Token rotation (either app):** from the app's manifest directory, an
authenticated Slack CLI user runs
`slack api apps.developerInstall --team T0BRHBB2TGW app_id=<APP_ID> | jq -r .api_access_tokens.bot`
piped **directly** into `gh secret set` / `az keyvault secret set` — never
printed, never pasted.

## 4. Channel map (WYRE AI)

| Channel | ID | Feeds into it |
| --- | --- | --- |
| #sales-notifications | `C0BRHC5S6CD` | Revenue report, Conduit Billing, Gateway Billing |
| #product-notifications | `C0BSHBQQBQ8` | Adoption Watcher |
| #github-activity | `C0BR5S8F6BZ` | Stars Watcher, Graphify Archive |
| #engineering | `C0BRF0MPWLT` | (registry canvas shared here) |

## 5. Staying on the old wyretalk workspace (deliberate, per Aaron 2026-08-20)

- **afkbot** — full Socket Mode PTO bot on Azure (`ca-afkbot-prod`); tokens in
  its Container App secrets.
- **chattstate-tdx-monitor** — TDX alert workflow, wyretalk `SLACK_WEBHOOK_URL`.
- **`.github` github-activity-notifier** — org-wide commit/PR notifier,
  wyretalk webhook (`SLACK_GITHUB_ACTIVITY_WEBHOOK_URL`). Not yet decided.
- **cortextOS fleet** — `SLACK_BOT_TOKEN` in Infisical (both contexts) is the
  wyretalk `wyre_agents` bot; used by `bus/send-slack.sh` + Socket Mode.

Any of these can be cut over with the WYRE Notifier pattern (§3) when wanted.

## 6. Vendor & account relationships

| Vendor | What for | Owner | Notes |
| --- | --- | --- | --- |
| Slack (WYRE AI workspace) | Team comms + notification surface | Aaron | New workspace, 2026-08 |
| Slack (wyretalk) | Legacy workspace | Aaron | Winding down; §5 items remain |
| Zoom | Meetings | Aaron | Separate account, 2026-08 |
| GitHub (wyre-technology org) | Legacy code home + org Actions secrets | Aaron | Repos migrating to WYRE-AI (conduit transferred 2026-08-26; old URLs redirect) |
| GitHub (WYRE-AI org) | New code home — conduit, revenue-report, node-* SDKs | Aaron | Needs its own org-level Slack secret when notifiers migrate |
| Azure | All prod infra (conduit-prod, mcp-gateway-prod, afkbot, …) + Key Vaults | Aaron | |
| Stripe (WYRE Technology LLC) | Billing — acct `acct_1IPBiHJqtDtyGs4x` | Aaron | |
| Infisical (secrets.wyretechnology.com) | Fleet/agent secret store (`cortex-secret`) | Aaron | `HELPSCOUT_STRIPE_API_KEY` expired — needs rotation |
| Infisical (secrets.wyre.ai) | New-entity secret store — `conduit` project (via `cortex-secret --context conduit`) | Aaron | Holds `REVENUE_SLASH_SIGNING_SECRET` |
| Cloudflare ("WYRE Main" acct) | Workers (`revenue-slash`), DNS | Aaron | |
| claude.ai (wyretechnology account) | Cloud routines, connectors | Aaron | Slack connector still points at wyretalk |
| Microsoft 365 | **Pending — tenant spin-up planned 2026-08-21** | Aaron | Future docs home (SharePoint) |
| HR platform | **Pending — selection/spin-up planned 2026-08-21** | Aaron | TBD |

## 7. Rotation & incident quick-reference

- **Slack bot tokens:** §3 runbook. Rotating a token invalidates the old one —
  update every copy listed for that app in the same sitting.
- **Stripe metrics key:** same value as conduit-prod `stripe-secret-key`;
  rotate in Stripe → update Container App secret + `STRIPE_METRICS_KEY`.
- **Admin metrics tokens:** `admin-api-key` in conduit-prod Container App /
  mcpgw-prod-kv; adoption-watcher README has the exact pipe commands.
- **A notifier goes quiet:** its Actions run goes red on Slack failure (all
  scripts hard-fail on `ok:false`) — check the repo's Actions tab first.

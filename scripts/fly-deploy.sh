#!/usr/bin/env bash
# Deploy the PocketBase SmartParcel backend + dashboard to Fly.io.
#
# Usage: scripts/fly-deploy.sh
#
# Idempotent — run it again to redeploy. Steps:
#   1. generate webhook token/secret into .env (if missing)
#   2. look up your nRF Cloud team ID (if NRFCLOUD_API_KEY is set)
#   3. create the Fly app and a 1 GB volume for the SQLite database
#   4. set secrets and deploy a single machine
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need fly openssl
cd "$ROOT"

[[ -n "${FLY_APP:-}" ]] || die "set FLY_APP in .env (globally unique, becomes https://<FLY_APP>.fly.dev)"
REGION="${FLY_REGION:-arn}"

fly auth whoami >/dev/null 2>&1 || die "not logged in to Fly — run: fly auth login"

# ── 1. Webhook credentials ──
[[ -n "${NRFCLOUD_WEBHOOK_TOKEN:-}" ]]  || set_env NRFCLOUD_WEBHOOK_TOKEN  "$(openssl rand -hex 24)"
[[ -n "${NRFCLOUD_WEBHOOK_SECRET:-}" ]] || set_env NRFCLOUD_WEBHOOK_SECRET "$(openssl rand -hex 32)"

# ── 2. Team ID (needed so the MRS destination verifies automatically) ──
if [[ -z "${NRFCLOUD_TEAM_ID:-}" && -n "${NRFCLOUD_API_KEY:-}" ]]; then
  set_env NRFCLOUD_TEAM_ID "$(lookup_team_id)"
  echo "nRF Cloud team ID: $NRFCLOUD_TEAM_ID"
fi
[[ -n "${NRFCLOUD_TEAM_ID:-}" ]] || echo "warning: NRFCLOUD_TEAM_ID unknown — MRS verification will need the PIN (scripts/mrs.sh verify)" >&2

# ── 3. App + volume ──
if ! fly status --app "$FLY_APP" >/dev/null 2>&1; then
  echo "Creating Fly app $FLY_APP"
  if [[ -n "${FLY_ORG:-}" ]]; then fly apps create "$FLY_APP" --org "$FLY_ORG"
  else fly apps create "$FLY_APP"; fi
fi

if [[ "$(fly volumes list --app "$FLY_APP" --json | jq '[.[] | select(.name == "pb_data")] | length')" == "0" ]]; then
  echo "Creating volume pb_data in $REGION"
  fly volumes create pb_data --app "$FLY_APP" --region "$REGION" --size 1 --yes
fi

# ── 4. Secrets + deploy ──
secrets=(
  "NRFCLOUD_WEBHOOK_TOKEN=$NRFCLOUD_WEBHOOK_TOKEN"
  "NRFCLOUD_WEBHOOK_SECRET=$NRFCLOUD_WEBHOOK_SECRET"
)
[[ -n "${NRFCLOUD_TEAM_ID:-}" ]] && secrets+=("NRFCLOUD_TEAM_ID=$NRFCLOUD_TEAM_ID")
if [[ -n "${PB_ADMIN_EMAIL:-}" && -n "${PB_ADMIN_PASSWORD:-}" ]]; then
  secrets+=("PB_ADMIN_EMAIL=$PB_ADMIN_EMAIL" "PB_ADMIN_PASSWORD=$PB_ADMIN_PASSWORD")
fi
fly secrets set --app "$FLY_APP" --stage "${secrets[@]}" >/dev/null

fly deploy --app "$FLY_APP" --primary-region "$REGION" --ha=false

URL="https://$FLY_APP.fly.dev"
cat <<EOF

Deployed.
  Dashboard : $URL/
  Admin UI  : $URL/_/
  Webhook   : $URL/api/nrfcloud/webhook

Next: point nRF Cloud at it with
  scripts/mrs.sh create
EOF

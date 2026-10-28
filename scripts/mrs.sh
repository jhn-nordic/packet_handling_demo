#!/usr/bin/env bash
# Manage the nRF Cloud Message Routing Service (MRS) destination that sends
# your devices' messages to this PocketBase backend.
#
# Usage: scripts/mrs.sh <command> [args]
#
#   create [BASE_URL]   create or update the destination and wait for verification
#                       BASE_URL defaults to $PUBLIC_URL, then https://$FLY_APP.fly.dev
#   status              show the destination (verified, state, recent errors)
#   list                list all destinations on the team
#   test                ask nRF Cloud to send a test message to the destination
#   resend              send a new verification PIN to the destination
#   verify PIN          verify with the 6-digit PIN (see `fly logs` / `docker compose logs`)
#   delete              delete the destination
#   team                print the API key's team ID (saved to .env if empty)
#
# Every command first checks that NRFCLOUD_API_KEY belongs to NRFCLOUD_TEAM_ID:
# nRF Cloud API keys are per team, and destinations are created on the key's team.
#
# Reads NRFCLOUD_API_KEY, NRFCLOUD_WEBHOOK_TOKEN/SECRET and FLY_APP from .env.
# The destination is found by name: $MRS_DESTINATION_NAME (default smartparcel-<FLY_APP>).
#
# MRS_CATEGORIES (comma-separated) limits which messages are routed; default
# "device_messages,shadow". Set it to "" to route everything.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

NAME="${MRS_DESTINATION_NAME:-smartparcel-${FLY_APP:-local}}"
CATEGORIES="${MRS_CATEGORIES-device_messages,shadow}"

find_id() {
  api "$MRS_API" GET "/destination?pageLimit=100" |
    jq -r --arg n "$NAME" '.items[] | select(.name == $n) | .id' | head -1
}

require_id() {
  local id; id="$(find_id)"
  [[ -n "$id" ]] || die "no destination named '$NAME' — run: scripts/mrs.sh create"
  echo "$id"
}

show() {
  jq '{id, name, url: .config.url, verified, isEnabled, state, filter, errors: [.errors[]? | {createdAt, reason: .reason.message, status: .reason.response.status}]}'
}

cmd_team() {
  echo "$NRFCLOUD_TEAM_ID" # ensure_team already checked/saved it
}

cmd_list() {
  api "$MRS_API" GET "/destination?pageLimit=100" |
    jq -r '.items[] | [.id, .name, (if .verified then "verified" else "UNVERIFIED" end), (.state | join(",")), .config.url] | @tsv' |
    column -t -s $'\t'
}

cmd_status() {
  api "$MRS_API" GET "/destination/$(require_id)" | show
}

cmd_create() {
  local base="${1:-$(default_base_url)}"
  [[ "$base" == https://* ]] || echo "warning: $base is not HTTPS — nRF Cloud requires a valid certificate unless verifySsl is off" >&2
  local url="${base%/}/api/nrfcloud/webhook"

  [[ -n "${NRFCLOUD_WEBHOOK_TOKEN:-}" ]]  || set_env NRFCLOUD_WEBHOOK_TOKEN  "$(openssl rand -hex 24)"
  [[ -n "${NRFCLOUD_WEBHOOK_SECRET:-}" ]] || set_env NRFCLOUD_WEBHOOK_SECRET "$(openssl rand -hex 32)"

  # Make sure the server is up and has the same credentials before nRF Cloud calls it
  local probe
  probe=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' --data '{}' "$url" || true)
  case "$probe" in
    401) ;; # expected: server requires the token we're about to configure
    200) echo "warning: $url accepted an unauthenticated request — is NRFCLOUD_WEBHOOK_TOKEN set on the server?" >&2 ;;
    *)   die "$url is not reachable (HTTP $probe) — deploy first (scripts/fly-deploy.sh or docker compose up)" ;;
  esac

  local body
  body=$(jq -n --arg name "$NAME" --arg url "$url" \
    --arg token "$NRFCLOUD_WEBHOOK_TOKEN" --arg secret "$NRFCLOUD_WEBHOOK_SECRET" \
    --arg cats "$CATEGORIES" '
    {name: $name, isEnabled: true,
     config: {type: "http", url: $url, verifySsl: true, token: $token, secret: $secret}}
    + (if $cats == "" then {} else {filter: {categories: ($cats | split(","))}} end)')

  local id; id="$(find_id)"
  if [[ -n "$id" ]]; then
    echo "Updating destination '$NAME' ($id) → $url"
    api "$MRS_API" PATCH "/destination/$id" "$body" >/dev/null
  else
    echo "Creating destination '$NAME' → $url"
    id=$(api "$MRS_API" POST /destination "$body" | jq -r .id)
  fi

  echo -n "Waiting for verification"
  for _ in $(seq 1 15); do
    if [[ "$(api "$MRS_API" GET "/destination/$id" | jq -r .verified)" == "true" ]]; then
      echo " ✓ verified"
      api "$MRS_API" GET "/destination/$id" | show
      return 0
    fi
    echo -n "."; sleep 2
  done
  echo
  cat >&2 <<EOF
Destination not verified automatically. The server must echo team $NRFCLOUD_TEAM_ID —
if you changed NRFCLOUD_TEAM_ID after deploying, run scripts/fly-deploy.sh again.
The webhook logged a 6-digit PIN — find it with:
  fly logs --app ${FLY_APP:-<app>} | grep PIN      (or: docker compose logs | grep PIN)
then run:
  scripts/mrs.sh verify <PIN>
EOF
  exit 1
}

cmd_test() {
  api "$MRS_API" POST "/destination/$(require_id)/test" | jq .
}

cmd_resend() {
  api "$MRS_API" POST "/destination/$(require_id)/verification" >/dev/null
  echo "Verification PIN sent — check the server logs, then: scripts/mrs.sh verify <PIN>"
}

cmd_verify() {
  [[ "${1:-}" =~ ^[0-9]{6}$ ]] || die "usage: scripts/mrs.sh verify <6-digit PIN>"
  api "$MRS_API" PATCH "/destination/$(require_id)/verification/confirm" \
    "$(jq -n --arg t "$1" '{verificationToken: $t}')" >/dev/null
  echo "Verified ✓"
}

cmd_delete() {
  local id; id="$(require_id)"
  api "$MRS_API" DELETE "/destination/$id" >/dev/null
  echo "Deleted destination '$NAME' ($id)"
}

case "${1:-}" in
  create|status|list|test|resend|verify|delete|team) cmd="$1"; shift; ensure_team; "cmd_$cmd" "$@" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac

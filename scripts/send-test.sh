#!/usr/bin/env bash
# Send fake nRF Cloud MRS deliveries to the webhook — no device needed.
#
# Usage:
#   scripts/send-test.sh [-u URL] [-d DEVICE_ID] [STATE] [PROBABILITY]
#   scripts/send-test.sh [-u URL] --demo        # loop a journey across two fake devices
#
#   STATE       firmware label: Idle | Carrying | "in Car" | Shaking | Impact | "Free Fall" | Placed
#   PROBABILITY integer percent (default 95)
#
# URL defaults to $WEBHOOK_URL, then https://$FLY_APP.fly.dev, then http://localhost:8090,
# with /api/nrfcloud/webhook appended. Signs requests with the token/secret from .env.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

URL="${WEBHOOK_URL:-}"
DEVICE="${TEST_DEVICE_ID:-nrf-test-device-1}"
DEMO=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) URL="$2"; shift 2 ;;
    -d) DEVICE="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ -n "$URL" ]] || URL="$(default_base_url)"
[[ "$URL" == */api/nrfcloud/webhook ]] || URL="${URL%/}/api/nrfcloud/webhook"

send() { # device label probability
  local now_ms msg_id data body sig
  now_ms=$(($(date +%s) * 1000))
  msg_id="$(uuid)"
  data=$(jq -cn --arg c "$2" --argjson p "$3" '{classification:$c, probability:$p}')
  body=$(jq -cn \
    --arg team "${NRFCLOUD_TEAM_ID:-test-team}" --arg dev "$1" --arg id "$msg_id" \
    --arg data "$data" --argjson ts "$now_ms" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"device.messages", timestamp:$at, messages:[{
        teamId:$team, deviceId:$dev, messageId:$id, receivedAt:$at,
        topic:("prod/" + $team + "/m/d/" + $dev + "/d2c"),
        message:{appId:"DETECTION", messageType:"DATA", ts:$ts, data:$data}}]}')

  local headers=(-H "content-type: application/json")
  [[ -n "${NRFCLOUD_WEBHOOK_TOKEN:-}" ]] && headers+=(-H "x-api-key: $NRFCLOUD_WEBHOOK_TOKEN")
  if [[ -n "${NRFCLOUD_WEBHOOK_SECRET:-}" ]]; then
    sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$NRFCLOUD_WEBHOOK_SECRET" -r | cut -d' ' -f1)
    headers+=(-H "x-nrfcloud-signature: $sig")
  fi

  printf '%-22s %-10s %3s%%  → ' "$1" "$2" "$3"
  curl -sS -w ' [%{http_code}]\n' "${headers[@]}" --data-binary "$body" "$URL"
}

if [[ $DEMO -eq 0 ]]; then
  send "$DEVICE" "${ARGS[0]:-Idle}" "${ARGS[1]:-95}"
  exit 0
fi

echo "Demo journey → $URL (Ctrl-C to stop)"
JOURNEY=("Idle" "Carrying" "Carrying" "Placed" "in Car" "in Car" "Shaking" "in Car" "Carrying" "Free Fall" "Impact" "Placed" "Idle")
while true; do
  for label in "${JOURNEY[@]}"; do
    send "nrf-demo-parcel-A" "$label" $((80 + RANDOM % 20))
    sleep 2
    send "nrf-demo-parcel-B" "${JOURNEY[$((RANDOM % ${#JOURNEY[@]}))]}" $((80 + RANDOM % 20))
    sleep 2
  done
done

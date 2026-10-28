# Shared helpers for scripts/*.sh — sourced, not executed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

# Load .env without overriding variables already set in the environment.
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] && continue
    value="${value%\"}"; value="${value#\"}"
    export "$key=$value"
  done < "$ENV_FILE"
fi

die() { echo "error: $*" >&2; exit 1; }

need() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "'$cmd' is required but not installed"
  done
}

need curl jq

uuid() {
  if command -v uuidgen >/dev/null; then uuidgen | tr 'A-Z' 'a-z'
  else cat /proc/sys/kernel/random/uuid; fi
}

# Write KEY=VALUE into .env (replace if present, append otherwise).
set_env() {
  touch "$ENV_FILE"
  if grep -q "^$1=" "$ENV_FILE"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
  export "$1=$2"
}

default_base_url() {
  if [[ -n "${PUBLIC_URL:-}" ]]; then echo "${PUBLIC_URL%/}"
  elif [[ -n "${FLY_APP:-}" ]]; then echo "https://$FLY_APP.fly.dev"
  else echo "http://localhost:8090"; fi
}

# ─── nRF Cloud REST APIs ───────────────────────────────────────────

NRFCLOUD_API="${NRFCLOUD_API:-https://api.nrfcloud.com/v1}"
MRS_API="${MRS_API:-https://api.message-routing.nrfcloud.com/v2}"

# api BASE METHOD PATH [JSON_BODY] — prints the body, fails on non-2xx.
api() {
  [[ -n "${NRFCLOUD_API_KEY:-}" ]] || die "NRFCLOUD_API_KEY is not set (nrfcloud.com → User Account → API key)"
  local out status data=()
  [[ -n "${4:-}" ]] && data=(--data "$4")
  out="$(mktemp)"
  status=$(curl -sS -o "$out" -w '%{http_code}' -X "$2" \
    -H "Authorization: Bearer $NRFCLOUD_API_KEY" \
    -H "content-type: application/json" \
    ${data[@]+"${data[@]}"} "$1$3")
  if [[ "$status" != 2* ]]; then
    echo "$2 $1$3 → HTTP $status" >&2
    cat "$out" >&2; echo >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"; rm -f "$out"
}

# Team ID of the account that owns NRFCLOUD_API_KEY.
lookup_team_id() {
  api "$NRFCLOUD_API" GET /account | jq -r '.team.tenantId // (.mqttTopicPrefix | split("/")[1]) // empty'
}

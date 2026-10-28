# Shared helpers for scripts/*.sh — sourced, not executed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

# Load .env without overriding variables already set in the environment.
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] && continue
    value="${value%$'\r'}"                                  # CRLF line endings
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
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
    if [[ "$status" == 401 ]]; then
      echo >&2 "nRF Cloud rejected NRFCLOUD_API_KEY. It must be the team REST API key: 40 lowercase hex
characters, from nrfcloud.com → (select the team) → User Account → Current Team Details → API key.
Organization Auth Tokens, Memfault keys and device/project keys don't work here."
      [[ "$NRFCLOUD_API_KEY" =~ ^[0-9a-f]{40}$ ]] ||
        echo >&2 "The current value is ${#NRFCLOUD_API_KEY} characters and not 40-hex, so it's a different credential."
    fi
    return 1
  fi
  cat "$out"; rm -f "$out"
}

# nRF Cloud API keys are per user *and* team, and the MRS API has no team
# parameter: destinations are always created on the API key's team. Make sure
# that is the team in NRFCLOUD_TEAM_ID (saving it if empty) before touching MRS.
ensure_team() {
  local account key_team key_team_name
  account="$(api "$NRFCLOUD_API" GET /account)"
  key_team=$(jq -r '.team.tenantId // (.mqttTopicPrefix | split("/")[1]) // empty' <<<"$account")
  key_team_name=$(jq -r '.team.name // empty' <<<"$account")
  [[ -n "$key_team" ]] || die "could not determine the team of NRFCLOUD_API_KEY from GET /account"

  if [[ -z "${NRFCLOUD_TEAM_ID:-}" ]]; then
    set_env NRFCLOUD_TEAM_ID "$key_team"
  elif [[ "$key_team" != "$NRFCLOUD_TEAM_ID" ]]; then
    die "NRFCLOUD_API_KEY belongs to team ${key_team_name:+'$key_team_name' }($key_team),
       but NRFCLOUD_TEAM_ID is $NRFCLOUD_TEAM_ID.
       API keys are per team: on nrfcloud.com switch to team $NRFCLOUD_TEAM_ID,
       open User Account → Current Team Details, and put that API key in .env."
  fi
  echo "nRF Cloud team: ${key_team_name:+$key_team_name }($key_team)" >&2
}

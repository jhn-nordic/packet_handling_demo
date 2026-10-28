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

# ─── nRF Cloud REST API ────────────────────────────────────────────
#
# Message Routing destinations are managed through the organization/project
# scoped endpoints, authenticated with an Organization Auth Token (OAT).
# Destinations are organization-wide; use the organization's default project.

NRFCLOUD_API="${NRFCLOUD_API:-https://api.nrfcloud.com/v1}"

require_nrfcloud_config() {
  if [[ -z "${NRFCLOUD_ORG_TOKEN:-}" && -n "${NRFCLOUD_API_KEY:-}" ]]; then
    die "NRFCLOUD_API_KEY (legacy team API key) is no longer used.
       Create an Organization Auth Token in nRF Cloud (Admin → Organization Auth Tokens)
       and set NRFCLOUD_ORG_TOKEN, NRFCLOUD_ORG and NRFCLOUD_PROJECT in .env instead."
  fi
  [[ -n "${NRFCLOUD_ORG_TOKEN:-}" ]] || die "NRFCLOUD_ORG_TOKEN is not set (nRF Cloud → Admin → Organization Auth Tokens)"
  [[ -n "${NRFCLOUD_ORG:-}" && -n "${NRFCLOUD_PROJECT:-}" ]] ||
    die "set NRFCLOUD_ORG and NRFCLOUD_PROJECT in .env: the slugs in the nRF Cloud URL
       …/organizations/<ORG>/projects/<PROJECT>/… (use the organization's default project)"
}

destinations_url() {
  echo "$NRFCLOUD_API/organizations/$NRFCLOUD_ORG/projects/$NRFCLOUD_PROJECT/destinations"
}

# api METHOD URL [JSON_BODY] — prints the body, fails on non-2xx.
api() {
  require_nrfcloud_config
  local out status data=()
  [[ -n "${3:-}" ]] && data=(--data "$3")
  out="$(mktemp)"
  status=$(curl -sS -o "$out" -w '%{http_code}' -X "$1" \
    -H "Authorization: Bearer $NRFCLOUD_ORG_TOKEN" \
    -H "content-type: application/json" \
    ${data[@]+"${data[@]}"} "$2")
  if [[ "$status" != 2* ]]; then
    echo "$1 $2 → HTTP $status" >&2
    cat "$out" >&2; echo >&2
    rm -f "$out"
    case "$status" in
      401) echo >&2 "nRF Cloud rejected NRFCLOUD_ORG_TOKEN. Create a new one under Admin → Organization Auth Tokens." ;;
      403) echo >&2 "The token isn't allowed to manage destinations in organization '$NRFCLOUD_ORG'. Managing Message Routing needs Organization Admin rights." ;;
      404) echo >&2 "Not found: check NRFCLOUD_ORG='$NRFCLOUD_ORG' and NRFCLOUD_PROJECT='$NRFCLOUD_PROJECT' against the slugs in the nRF Cloud URL. Destinations are managed from the organization's default project." ;;
    esac
    return 1
  fi
  cat "$out"; rm -f "$out"
}

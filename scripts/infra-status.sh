#!/bin/bash
# infra-status.sh — compact status overview of Hetzner (2 projects) / Contabo / Cloudflare / INWX.
# Usage: ./scripts/infra-status.sh   (run on .149 or anywhere with the tokens exported)
#
# Tokens are read from the environment only (config/.env on .149, gitignored).
# Missing/empty tokens or API errors only warn on stderr and skip that section
# (exit code stays 0). Secrets are NEVER printed. No jq required (grep/sed only).

set -euo pipefail

warn() { echo "WARN: $*" >&2; }

hetzner_project_status() {
  local project="$1" token_var="$2"
  local token="${!token_var:-}"
  if [ -z "$token" ]; then
    warn "${token_var} nicht gesetzt - Hetzner-Sektion (${project}) uebersprungen"
    return 0
  fi
  echo "=== Hetzner Cloud (${project}): Server ==="
  local json
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
    https://api.hetzner.cloud/v1/servers || true)
  if [ -z "$json" ]; then
    warn "Hetzner: leere Antwort / curl-Fehler"
    return 0
  fi
  if printf '%s' "$json" | grep -q '"error"'; then
    warn "Hetzner: API-Fehler"
    return 0
  fi
  # One match per server: {"id":N,"name":"...","status":"..."} (field order per API docs).
  local servers locs n nloc i line name status loc
  servers=$(printf '%s' "$json" | grep -oE '\{"id":[0-9]+,"name":"[^"]*","status":"[^"]*"' || true)
  if [ -z "$servers" ]; then
    echo "  (keine Server)"
    return 0
  fi
  n=$(printf '%s' "$servers" | grep -c . || true)
  locs=$(printf '%s' "$json" | grep -oE '"location":\{"id":[0-9]+,"name":"[^"]*"' \
    | sed 's/.*"name":"//; s/"$//' || true)
  nloc=$(printf '%s' "$locs" | grep -c . || true)
  i=0
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    status=$(printf '%s' "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    loc="?"
    if [ "$nloc" -ge $((i + 1)) ]; then
      loc=$(printf '%s\n' "$locs" | sed -n "$((i + 1))p")
    fi
    printf '  %-28s %-10s %s\n' "$name" "$status" "$loc"
    i=$((i + 1))
  done <<< "$servers"
  echo "  ($n Server)"
}

contabo_status() {
  local cid="${CONTABO_CLIENT_ID:-}" csec="${CONTABO_CLIENT_SECRET:-}"
  if [ -z "$cid" ] || [ -z "$csec" ]; then
    warn "CONTABO_CLIENT_ID / CONTABO_CLIENT_SECRET nicht gesetzt - Contabo-Sektion uebersprungen"
    return 0
  fi
  echo "=== Contabo: Instances ==="
  local tokjson tok json
  tokjson=$(curl -sS --max-time 15 \
    --data-urlencode "client_id=$cid" \
    --data-urlencode "client_secret=$csec" \
    --data-urlencode "grant_type=client_credentials" \
    https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token || true)
  if [ -z "$tokjson" ]; then
    warn "Contabo: Token-Abfrage fehlgeschlagen (curl/leere Antwort)"
    return 0
  fi
  tok=$(printf '%s' "$tokjson" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  if [ -z "$tok" ]; then
    warn "Contabo: Token-Abfrage fehlgeschlagen (kein access_token in Antwort)"
    return 0
  fi
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $tok" \
    https://api.contabo.com/v1/compute/instances || true)
  if [ -z "$json" ]; then
    warn "Contabo: Instances-Abfrage fehlgeschlagen (curl/leere Antwort)"
    return 0
  fi
  if printf '%s' "$json" | grep -q '"error"'; then
    warn "Contabo: API-Fehler bei Instances-Abfrage"
    return 0
  fi
  # Split instance array into lines, keep only real instance objects (id + status).
  local objs n i line name status region rest
  objs=$(printf '%s' "$json" \
    | sed -e 's/\[{"id":/[\n{"id":/g' -e 's/},{"id":/\n{"id":/g' \
    | grep -E '^{"id":[0-9]+.*"status":"' || true)
  if [ -z "$objs" ]; then
    echo "  (keine Instances)"
    return 0
  fi
  n=$(printf '%s' "$objs" | grep -c . || true)
  i=0
  while IFS= read -r line; do
    # Extract FIRST occurrence of each field (greedy sed would pick later
    # fields, e.g. the empty "name" inside bootVolume).
    rest="${line#*\"name\":\"}"
    if [ "$rest" != "$line" ]; then name="${rest%%\"*}"; else name=""; fi
    rest="${line#*\"status\":\"}"
    if [ "$rest" != "$line" ]; then status="${rest%%\"*}"; else status=""; fi
    rest="${line#*\"region\":\"}"
    if [ "$rest" != "$line" ]; then region="${rest%%\"*}"; else region=""; fi
    if [ -n "$region" ]; then
      printf '  %-28s %-12s %s\n' "$name" "$status" "$region"
    else
      printf '  %-28s %s\n' "$name" "$status"
    fi
    i=$((i + 1))
  done <<< "$objs"
  echo "  ($n Instances)"
}

cloudflare_status() {
  local token="${CLOUDFLARE_API_TOKEN:-}"
  if [ -z "$token" ]; then
    warn "CLOUDFLARE_API_TOKEN nicht gesetzt - Cloudflare-Sektion uebersprungen"
    return 0
  fi
  echo "=== Cloudflare: Zonen ==="
  local json
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
    https://api.cloudflare.com/client/v4/zones || true)
  if [ -z "$json" ]; then
    warn "Cloudflare: leere Antwort / curl-Fehler"
    return 0
  fi
  if ! printf '%s' "$json" | grep -q '"success":true'; then
    warn "Cloudflare: API-Fehler"
    return 0
  fi
  # One match per zone: {"id":"...","name":"...","status":"..."} (field order per API docs).
  local zones n i line name status
  zones=$(printf '%s' "$json" | grep -oE '\{"id":"[^"]*","name":"[^"]*","status":"[^"]*"' || true)
  if [ -z "$zones" ]; then
    echo "  (keine Zonen)"
    return 0
  fi
  n=$(printf '%s' "$zones" | grep -c . || true)
  i=0
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    status=$(printf '%s' "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    printf '  %-28s %s\n' "$name" "$status"
    i=$((i + 1))
  done <<< "$zones"
  if [ "$n" -eq 1 ]; then
    echo "  (1 Zone)"
  else
    echo "  ($n Zonen)"
  fi
}

inwx_status() {
  local user="${INWX_API_USER:-}" pass="${INWX_API_PASSWORD:-}"
  if [ -z "$user" ] || [ -z "$pass" ]; then
    warn "INWX_API_USER / INWX_API_PASSWORD nicht gesetzt - INWX-Sektion uebersprungen (optional)"
    return 0
  fi
  echo "=== INWX: Domains ==="
  local json domains n domain
  json=$(curl -sS --max-time 15 -u "$user:$pass" -H "Accept: application/json" \
    https://api.inwx.com/rest/domain.list || true)
  if [ -z "$json" ]; then
    warn "INWX: leere Antwort / curl-Fehler"
    return 0
  fi
  if ! printf '%s' "$json" | grep -q '"code":1000'; then
    warn "INWX: API-Fehler (Code != 1000 - Login/Passwort oder Berechtigung pruefen)"
    return 0
  fi
  # Extract every domain name from the resData.domain array.
  domains=$(printf '%s' "$json" | grep -oE '"domain":"[^"]*"' | sed 's/"domain":"//; s/"$//' || true)
  if [ -z "$domains" ]; then
    echo "  (keine Domains)"
    return 0
  fi
  n=0
  while IFS= read -r domain; do
    printf '  %s\n' "$domain"
    n=$((n + 1))
  done <<< "$domains"
  if [ "$n" -eq 1 ]; then
    echo "  (1 Domain)"
  else
    echo "  ($n Domains)"
  fi
}

if ! command -v curl >/dev/null 2>&1; then
  warn "curl ist nicht installiert - Statusabfrage nicht moeglich"
  exit 0
fi

hetzner_project_status "StorageBoxes" "HETZNER_API_TOKEN_STORAGEBOXES"
echo
hetzner_project_status "mittelerde" "HETZNER_API_TOKEN_MITTELERDE"
echo
contabo_status
echo
cloudflare_status
echo
inwx_status

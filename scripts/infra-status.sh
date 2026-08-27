#!/bin/bash
# infra-status.sh — compact status overview of Hetzner (Cloud) / Contabo / Cloudflare / INWX.
# Usage: ./scripts/infra-status.sh   (run on .149 or anywhere with the tokens exported)
#
# Tokens are read from the environment only (config/.env on .149, gitignored).
# Missing/empty tokens or API errors only warn on stderr and skip that section
# (exit code stays 0). Secrets are NEVER printed.
#
# JSON parsing via python3 (im Container via Dockerfile vorhanden); jq wird
# bevorzugt, falls installiert. Kein fragiles grep/sed-Feld-Parsing mehr — die
# Hetzner Cloud API liefert z. B. hübsch formatiertes (mehrzeiliges) JSON, an dem
# Einzeilen-Regexe scheitern.

set -euo pipefail

warn() { echo "WARN: $*" >&2; }

# --- JSON-Helfer: jq bevorzugt, sonst python3 ---------------------------------
# json_rows <schema>  (JSON auf stdin) -> TSV-Zeilen, eine pro Objekt.
#   schema "servers"    -> name \t status \t typ \t location   (Hetzner Cloud)
#   schema "storagebox" -> id \t username \t name \t typ \t status \t location (Hetzner Cloud, Projekt StorageBoxes)
#   schema "contabo"    -> name \t status \t region            (Contabo API)
json_rows() {
  local schema="$1"
  if command -v jq >/dev/null 2>&1; then
    case "$schema" in
      servers)    jq -r '.servers[] | [.name, .status, (.server_type.name // ""), (.location.name // "")] | @tsv' 2>/dev/null || true ;;
      storagebox) jq -r '.storage_boxes[] | [.id, .username, .name, (.storage_box_type.name // ""), .status, ((.storage_box_type.prices[0].location // ""))] | @tsv' 2>/dev/null || true ;;
      contabo)    jq -r '.data[] | [.name, .status, .region] | @tsv' 2>/dev/null || true ;;
    esac
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
kind = sys.argv[1]
d = json.load(sys.stdin)
rows = []
if kind == "servers":
    for s in d.get("servers", []):
        st = s.get("server_type") or {}
        loc = s.get("location") or {}
        rows.append("\t".join([s.get("name", ""), s.get("status", ""), st.get("name", ""), loc.get("name", "")]))
elif kind == "storagebox":
    # Hetzner Cloud API v1: {"storage_boxes": [{"id", "username", "name", "status", "storage_box_type": {...}}]}
    items = d.get("storage_boxes", []) if isinstance(d, dict) else []
    for b in items:
        if not isinstance(b, dict):
            continue
        sbt = b.get("storage_box_type") or {}
        prices = sbt.get("prices") or []
        loc = ""
        if prices and isinstance(prices[0], dict):
            loc = prices[0].get("location", "") or ""
        rows.append("\t".join([str(b.get("id", "")), b.get("username", ""), b.get("name", ""), sbt.get("name", ""), b.get("status", ""), loc]))
elif kind == "contabo":
    for i in d.get("data", []):
        rows.append("\t".join([i.get("name", ""), i.get("status", ""), i.get("region", "")]))
print("\n".join(rows))
' "$schema" 2>/dev/null || true
    return 0
  fi
  warn "weder jq noch python3 verfuegbar - JSON-Parsing nicht moeglich"
  return 1
}

# json_errmsg  (JSON auf stdin) -> "code: message" eines API-Fehlerobjekts, sonst leer.
# Versteht {"error": {"code","message"}} (Hetzner Cloud) und
# {"error":"...","error_description":"..."} (Contabo Keycloak).
json_errmsg() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
e = d.get("error")
if isinstance(e, dict):
    code = e.get("code", "") or ""
    msg = e.get("message", "") or ""
    print((code + ": " + msg).strip(": "))
elif isinstance(e, str):
    desc = d.get("error_description") or ""
    print(e + (": " + desc if desc else ""))
' 2>/dev/null || true
}

# --- Hetzner Cloud (ein Token pro Projekt) -------------------------------------
hetzner_project_status() {
  local project="$1" token_var="$2"
  local token="${!token_var:-}"
  if [ -z "$token" ]; then
    warn "${token_var} nicht gesetzt - Hetzner-Sektion (${project}) uebersprungen"
    return 0
  fi
  echo "=== Hetzner Cloud (${project}): Server ==="
  local json err rows n name status type loc
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
    https://api.hetzner.cloud/v1/servers || true)
  if [ -z "$json" ]; then
    warn "Hetzner: leere Antwort / curl-Fehler"
    return 0
  fi
  if printf '%s' "$json" | grep -q '"error"'; then
    err=$(printf '%s' "$json" | json_errmsg)
    warn "Hetzner: API-Fehler${err:+: $err}"
    return 0
  fi
  rows=$(printf '%s' "$json" | json_rows servers || true)
  if [ -z "$rows" ]; then
    echo "  (keine Server)"
    return 0
  fi
  n=0
  while IFS=$'\t' read -r name status type loc; do
    printf '  %-28s %-10s %-8s %s\n' "$name" "$status" "$type" "$loc"
    n=$((n + 1))
  done <<< "$rows"
  if [ "$n" -eq 1 ]; then
    echo "  (1 Server)"
  else
    echo "  ($n Server)"
  fi
}

# --- Hetzner StorageBoxes (Cloud-API v1, Projekt StorageBoxes) ------------------
# Die StorageBoxes wurden ins Hetzner-Cloud-Projekt 11031986 migriert und sind
# seitdem ueber die Hetzner Cloud API abrufbar:
#   https://api.hetzner.com/v1/storage_boxes (Bearer-Token, projektgebunden)
# Ein separater Token (HETZNER_API_TOKEN_STORAGEBOXES) ist noetig, weil ein
# Cloud-Token nur sein eigenes Projekt sieht. Die alte Robot-API
# (https://robot-ws.your-server.de/storagebox, HTTP Basic Auth) wird nicht mehr
# genutzt - die StorageBoxes sind dort nicht mehr verfuegbar.
hetzner_storageboxes_status() {
  local token="${HETZNER_API_TOKEN_STORAGEBOXES:-}"
  echo "=== Hetzner StorageBoxes (Cloud API, Projekt StorageBoxes) ==="
  if [ -z "$token" ]; then
    warn "HETZNER_API_TOKEN_STORAGEBOXES nicht gesetzt (Cloud-API-Token fuer das StorageBoxes-Projekt 11031986) - Sektion uebersprungen"
    return 0
  fi
  local json err rows n id username name type status loc
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
    https://api.hetzner.com/v1/storage_boxes || true)
  if [ -z "$json" ]; then
    warn "Hetzner StorageBoxes: leere Antwort / curl-Fehler"
    return 0
  fi
  if printf '%s' "$json" | grep -q '"error"'; then
    err=$(printf '%s' "$json" | json_errmsg)
    warn "Hetzner StorageBoxes: API-Fehler${err:+: $err}"
    return 0
  fi
  rows=$(printf '%s' "$json" | json_rows storagebox || true)
  if [ -z "$rows" ]; then
    echo "  (keine StorageBoxes)"
    return 0
  fi
  n=0
  while IFS=$'\t' read -r id username name type status loc; do
    printf '  %-28s %-10s %-8s %-6s Login %s (ID %s)\n' "$name" "$status" "$type" "$loc" "$username" "$id"
    n=$((n + 1))
  done <<< "$rows"
  if [ "$n" -eq 1 ]; then
    echo "  (1 StorageBox)"
  else
    echo "  ($n StorageBoxes)"
  fi
}

# --- Contabo (Cloud API v2, OAuth2 password grant) ----------------------------
# Laut offizieller OpenAPI (https://api.contabo.com) ist der korrekte Flow
# grant_type=password: client_id + client_secret (OAuth2-Client aus der CCP),
# username = API User (die CCP-Email) und password = API Password (separates
# Passwort aus my.contabo.com/api/details, NICHT das CCP-Login-Passwort).
# grant_type=client_credentials scheitert mit "unauthorized_client: Client not
# enabled to retrieve service account".
contabo_status() {
  local cid="${CONTABO_CLIENT_ID:-}" csec="${CONTABO_CLIENT_SECRET:-}"
  local cuser="${CONTABO_API_USER:-}" cpass="${CONTABO_API_PASSWORD:-}"
  if [ -z "$cid" ] || [ -z "$csec" ]; then
    warn "CONTABO_CLIENT_ID / CONTABO_CLIENT_SECRET nicht gesetzt - Contabo-Sektion uebersprungen"
    return 0
  fi
  if [ -z "$cuser" ] || [ -z "$cpass" ]; then
    warn "CONTABO_API_USER / CONTABO_API_PASSWORD nicht gesetzt (API User = CCP-Email, API Password = separates Passwort aus my.contabo.com/api/details) - Contabo-Sektion uebersprungen"
    return 0
  fi
  echo "=== Contabo: Instances ==="
  local tokjson tok json err rows n line name status region rid
  tokjson=$(curl -sS --max-time 15 \
    --data-urlencode "client_id=$cid" \
    --data-urlencode "client_secret=$csec" \
    --data-urlencode "username=$cuser" \
    --data-urlencode "password=$cpass" \
    -d "grant_type=password" \
    https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token || true)
  if [ -z "$tokjson" ]; then
    warn "Contabo: Token-Abfrage fehlgeschlagen (curl/leere Antwort)"
    return 0
  fi
  tok=$(printf '%s' "$tokjson" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  if [ -z "$tok" ]; then
    err=$(printf '%s' "$tokjson" | json_errmsg)
    if [ -n "$err" ]; then
      # err kommt von der API (z. B. "invalid_grant: Invalid user credentials") -
      # keine Secrets, nur der Server-Fehlertext wird ausgegeben.
      warn "Contabo: Token-Abfrage fehlgeschlagen - ${err} (grant_type=password an https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token; API User / API Password aus my.contabo.com/api/details pruefen - das API Password ist ein separates Passwort, nicht das CCP-Login-Passwort)"
    else
      warn "Contabo: Token-Abfrage fehlgeschlagen (kein access_token in der Antwort - Auth-URL und Feldnamen pruefen: client_id/client_secret/username/password/grant_type an https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token)"
    fi
    return 0
  fi
  # x-request-id ist laut OpenAPI Pflicht; im Container kein uuidgen, also
  # /proc/sys/kernel/random/uuid (Fallback: python3).
  if [ -r /proc/sys/kernel/random/uuid ]; then
    rid=$(cat /proc/sys/kernel/random/uuid)
  else
    rid=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || true)
  fi
  [ -n "$rid" ] || rid="infra-status-$$-$(date +%s)"
  json=$(curl -sS --max-time 15 -H "Authorization: Bearer $tok" -H "x-request-id: $rid" \
    https://api.contabo.com/v1/compute/instances || true)
  if [ -z "$json" ]; then
    warn "Contabo: Instances-Abfrage fehlgeschlagen (curl/leere Antwort)"
    return 0
  fi
  if printf '%s' "$json" | grep -qE '"error"|"errors"'; then
    err=$(printf '%s' "$json" | json_errmsg)
    warn "Contabo: API-Fehler bei Instances-Abfrage${err:+: $err}"
    return 0
  fi
  rows=$(printf '%s' "$json" | json_rows contabo || true)
  if [ -z "$rows" ]; then
    echo "  (keine Instances)"
    return 0
  fi
  n=0
  while IFS=$'\t' read -r name status region; do
    if [ -n "$region" ]; then
      printf '  %-28s %-12s %s\n' "$name" "$status" "$region"
    else
      printf '  %-28s %s\n' "$name" "$status"
    fi
    n=$((n + 1))
  done <<< "$rows"
  if [ "$n" -eq 1 ]; then
    echo "  (1 Instance)"
  else
    echo "  ($n Instances)"
  fi
}

# --- Cloudflare (API v4) --------------------------------------------------------
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

# --- INWX (Domain-Registrar, DomRobot) ------------------------------------------
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

hetzner_storageboxes_status
echo
hetzner_project_status "mittelerde" "HETZNER_API_TOKEN_MITTELERDE"
echo
contabo_status
echo
cloudflare_status
echo
inwx_status

#!/bin/sh
# generate-github-token.sh — fetch a short-lived GitHub App installation token.
#
# GitHub App installation tokens expire after ~1h. This script:
#   1. builds a JWT (RS256) signed with the app's private key (.pem),
#   2. exchanges it for an installation access token via the REST API.
#
# Prerequisites (env): GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY_FILE
#   GH_APP_PRIVATE_KEY_FILE — path to the app's private key (PEM) INSIDE the
#   container (host dir ~/.secrets is mounted read-only to /home/node/.secrets).
#   If the configured path is not readable, the newest readable *.pem in the
#   same directory is used instead (GitHub names downloads
#   "<app-slug>.<date>.private-key.pem", so the filename can change).
#
# Usage:
#   GH_APP_ID=123 GH_APP_INSTALLATION_ID=456 GH_APP_PRIVATE_KEY_FILE=/run/secrets/momo-bot.pem \
#     ./generate-github-token.sh            # prints token (default)
#   ... --expires-at                        # prints "token expires_at" (two words)
#   ... --jwt                               # prints only the signed JWT (debug)
#   ... --json                              # prints raw API response
#
# Dependencies: openssl, curl, jq (all present in the openclaw image).
# Alternative implementation with PyJWT is documented in SETUP.md.
set -eu

: "${GH_APP_ID:?GH_APP_ID not set (GitHub App ID, numeric — from App settings)}"
: "${GH_APP_INSTALLATION_ID:?GH_APP_INSTALLATION_ID not set (numeric — from App install page URL /api.github.com/app/installations)}"
: "${GH_APP_PRIVATE_KEY_FILE:?GH_APP_PRIVATE_KEY_FILE not set (path to app private key .pem)}"

# ── Private key resolution ─────────────────────────────────────────
# GH_APP_PRIVATE_KEY_FILE zeigt IN den Container. Das Host-Verzeichnis
# ~/.secrets wird read-only nach /home/node/.secrets gemountet
# (docker-compose.yml). GitHub lädt App-Keys als
# "<app-slug>.<datum>.private-key.pem" herunter — der Dateiname ändert sich
# also bei jeder Key-Regenerierung. Ist der konfigurierte Pfad nicht lesbar,
# fällt das Skript auf die neueste lesbare *.pem im selben Verzeichnis zurück
# (MODE A bleibt damit auch ohne Umbenennen der Host-Datei funktionsfähig).
KEY_FILE=""
if [ -r "$GH_APP_PRIVATE_KEY_FILE" ]; then
    KEY_FILE="$GH_APP_PRIVATE_KEY_FILE"
else
    KEY_DIR="$(dirname "$GH_APP_PRIVATE_KEY_FILE")"
    for f in "$KEY_DIR"/*.pem; do
        [ -f "$f" ] && [ -r "$f" ] || continue
        [ -z "$KEY_FILE" ] || [ "$f" -nt "$KEY_FILE" ] || continue
        KEY_FILE="$f"
    done
fi
if [ -z "$KEY_FILE" ] || [ ! -r "$KEY_FILE" ]; then
    echo "ERROR: private key not readable: $GH_APP_PRIVATE_KEY_FILE (no readable *.pem in ${KEY_DIR:-$(dirname "$GH_APP_PRIVATE_KEY_FILE")})" >&2
    exit 1
fi
if [ "$KEY_FILE" != "$GH_APP_PRIVATE_KEY_FILE" ]; then
    echo "WARN: $GH_APP_PRIVATE_KEY_FILE not readable — using newest key in $(dirname "$KEY_FILE"): $(basename "$KEY_FILE")" >&2
fi

MODE="${1:-token}"   # token | expires-at | jwt | json
# normalize: accept both "--jwt" and "jwt" style flags
case "$MODE" in
    --*) MODE="${MODE#--}" ;;
esac

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ── 1. JWT (RS256) — max lifetime 10 min, iat with clock-skew buffer ──
NOW="$(date +%s)"
IAT="$((NOW - 60))"
EXP="$((NOW + 540))"

HEADER="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
PAYLOAD="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$IAT" "$EXP" "$GH_APP_ID" | b64url)"
SIGNING_INPUT="$HEADER.$PAYLOAD"
SIGNATURE="$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign "$KEY_FILE" | b64url)"
JWT="$SIGNING_INPUT.$SIGNATURE"

if [ "$MODE" = "jwt" ]; then
    printf '%s\n' "$JWT"
    exit 0
fi

# ── 2. Exchange JWT for installation access token ──────────────────
RESP="$(curl -fsSL \
    -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/$GH_APP_INSTALLATION_ID/access_tokens")"

case "$MODE" in
    json)
        printf '%s\n' "$RESP"
        ;;
    expires-at)
        printf '%s %s\n' "$(printf '%s' "$RESP" | jq -r '.token')" "$(printf '%s' "$RESP" | jq -r '.expires_at')"
        ;;
    *)
        printf '%s\n' "$RESP" | jq -r '.token'
        ;;
esac

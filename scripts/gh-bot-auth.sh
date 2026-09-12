#!/bin/bash
# gh-bot-auth.sh — mint a fresh (cached ~45 min) GitHub App installation token for a
# named bot and write its own `gh` hosts.yml, isolated via GH_CONFIG_DIR. Enables two
# bots (`clanker` coder, `claw` reviewer) to coexist on one host with distinct identities.
#
# App config lives in $HOME/.config/gh-bots/<app>.env:
#   GH_APP_ID=...
#   GH_APP_INSTALLATION_ID=...
#   GH_APP_PRIVATE_KEY_FILE=/home/momo/.secrets/<app>.pem
#
# Usage:
#   gh-bot-auth.sh --app clanker             # mint (cached) + write hosts.yml + git helper
#   gh-bot-auth.sh --app clanker --token     # print a fresh token (always re-mints)
#   gh-bot-auth.sh --app clanker --bot-id    # print bot USER id (for commit email)
#
# Dependencies: generate-github-token.sh (same dir), curl, jq, gh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP=""
MODE="auth"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --token) MODE="token"; shift ;;
    --bot-id) MODE="bot-id"; shift ;;
    *) echo "usage: gh-bot-auth.sh --app <clanker|claw> [--token|--bot-id]" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ] || { echo "gh-bot-auth.sh: --app required" >&2; exit 2; }

CFG="$HOME/.config/gh-$APP"
HOSTS_FILE="$CFG/hosts.yml"
BOT_LOGIN="${APP}[bot]"
BOT_ID_FILE="$CFG/bot-id"

# --bot-id: unauthenticated resolution of the bot USER id (for commit email). No mint.
if [ "$MODE" = "bot-id" ]; then
  if [ -f "$BOT_ID_FILE" ]; then
    cat "$BOT_ID_FILE"
    exit 0
  fi
  BOT_ID="$(curl -fsSL "https://api.github.com/users/${APP}%5Bbot%5D" | jq -r '.id' 2>/dev/null || true)"
  if [ -n "$BOT_ID" ] && [ "$BOT_ID" != "null" ]; then
    mkdir -p "$CFG"
    printf '%s\n' "$BOT_ID" > "$BOT_ID_FILE"
    printf '%s\n' "$BOT_ID"
  fi
  exit 0
fi

# token/auth modes need the app creds. `set -a` so the sourced KEY=value pairs are
# EXPORTED into the generate-github-token.sh child process (plain dotenv would not).
ENV_FILE="$HOME/.config/gh-bots/$APP.env"
[ -f "$ENV_FILE" ] || { echo "gh-bot-auth.sh: missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${GH_APP_ID:?GH_APP_ID not set in $ENV_FILE}"
: "${GH_APP_INSTALLATION_ID:?GH_APP_INSTALLATION_ID not set in $ENV_FILE}"
: "${GH_APP_PRIVATE_KEY_FILE:?GH_APP_PRIVATE_KEY_FILE not set in $ENV_FILE}"

if [ "$MODE" = "token" ]; then
  "$SCRIPT_DIR/generate-github-token.sh"
  exit 0
fi

# auth mode: mint only if the cached token is missing or older than 45 min.
STAMP_FILE="$CFG/token-stamp"
need_mint=0
if [ ! -f "$HOSTS_FILE" ] || [ ! -f "$STAMP_FILE" ]; then
  need_mint=1
else
  now="$(date +%s)"
  age="$(( now - $(cat "$STAMP_FILE") ))"
  [ "$age" -ge 2700 ] && need_mint=1
fi

if [ "$need_mint" = "1" ]; then
  TOKEN="$("$SCRIPT_DIR/generate-github-token.sh")"
  [ -n "$TOKEN" ] || { echo "gh-bot-auth.sh: no token returned" >&2; exit 1; }
  mkdir -p "$CFG"
  cat > "$HOSTS_FILE" <<EOF
github.com:
    oauth_token: $TOKEN
    user: $BOT_LOGIN
    git_protocol: https
EOF
  chmod 700 "$CFG"
  chmod 600 "$HOSTS_FILE"
  date +%s > "$STAMP_FILE"
  echo "[gh-bot-auth] $BOT_LOGIN token minted (~1h)"
  # Wire git's credential helper to gh (uses GH_CONFIG_DIR at runtime) so HTTPS
  # git push/clone authenticates as this bot.
  GH_CONFIG_DIR="$CFG" gh auth setup-git --hostname github.com >/dev/null 2>&1 || true
else
  echo "[gh-bot-auth] $BOT_LOGIN token cached (fresh)"
fi

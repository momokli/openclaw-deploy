#!/bin/sh
# gh-app-auth.sh — (re-)authenticate gh/git with a fresh GitHub App token.
#
# Installation tokens expire after ~1h. Call this script
#   - at container start (entrypoint.sh step 5c, app mode), and
#   - from a coding agent whenever `gh auth status` / `git push` starts
#     failing with 401 (token expired) — it takes <2s.
#
# It performs the same job as entrypoint.sh's PAT branch (hosts.yml +
# credential helper), but with a token minted from the GitHub App:
#   1. fetch fresh installation token via generate-github-token.sh
#   2. write /home/node/.config/gh/hosts.yml (bypasses `gh auth login`
#      validation — same trick as entrypoint.sh step 5c)
#   3. wire up git's credential helper (gh auth setup-git)
#   4. patch the runtime openclaw.json so the gh-issues skill's
#      `.skills.entries["gh-issues"].apiKey` fallback is fresh too
#   5. optionally (--setup-git-identity) configure git to commit as
#      "momo-bot[bot]" using the bot user's noreply address
#
# Env: GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY_FILE
#      (optionally GH_TOKEN for the OLD PAT path — not needed for app mode)
#
# Usage:
#   ./gh-app-auth.sh                 # refresh hosts.yml + credential helper
#   ./gh-app-auth.sh --print-token   # only print fresh token (for export)
#   ./gh-app-auth.sh --setup-git-identity   # also configure bot commit identity
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
GH_DIR="${HOME}/.config/gh"
HOSTS_FILE="$GH_DIR/hosts.yml"

: "${GH_APP_ID:?GH_APP_ID not set}"
: "${GH_APP_INSTALLATION_ID:?GH_APP_INSTALLATION_ID not set}"
: "${GH_APP_PRIVATE_KEY_FILE:?GH_APP_PRIVATE_KEY_FILE not set}"

SETUP_GIT_IDENTITY=0
PRINT_TOKEN=0
for arg in "$@"; do
    case "$arg" in
        --setup-git-identity) SETUP_GIT_IDENTITY=1 ;;
        --print-token) PRINT_TOKEN=1 ;;
        *) echo "WARN: unknown argument: $arg" >&2 ;;
    esac
done

# ── 1. Fresh token ────────────────────────────────────────────────
TOKEN="$("$DIR/generate-github-token.sh")"
[ -n "$TOKEN" ] || { echo "ERROR: no token returned" >&2; exit 1; }

if [ "$PRINT_TOKEN" = "1" ]; then
    printf '%s\n' "$TOKEN"
    exit 0
fi

# ── 2. Resolve bot login (usually "<app-slug>[bot]") ──────────────
BOT_LOGIN="$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user | jq -r '.login')"
[ -n "$BOT_LOGIN" ] && [ "$BOT_LOGIN" != "null" ] || BOT_LOGIN="momo-bot[bot]"
echo "[gh-app-auth] authenticated as: $BOT_LOGIN"

# ── 3. Persist gh auth (hosts.yml) — dir must be node-owned ───────
mkdir -p "$GH_DIR"
cat > "$HOSTS_FILE" <<EOF
github.com:
    users:
        "$BOT_LOGIN":
            oauth_token: $TOKEN
    oauth_token: $TOKEN
    user: "$BOT_LOGIN"
    git_protocol: https
EOF
chmod 700 "$GH_DIR"
chmod 600 "$HOSTS_FILE"
echo "[gh-app-auth] hosts.yml updated ($(date -u +%H:%M:%S) UTC, token expires in ~1h)"

# ── 4. Git credential helper ──────────────────────────────────────
if gh auth setup-git --hostname github.com >/dev/null 2>&1; then
    echo "[gh-app-auth] gh credential helper configured"
else
    echo "[gh-app-auth] WARN: gh auth setup-git failed" >&2
fi

# ── 5. Patch runtime openclaw.json (gh-issues skill apiKey fallback) ──
# The gh-issues skill reads `.skills.entries["gh-issues"].apiKey` when the
# GH_TOKEN env var is not set. The runtime config lives in the named volume
# (NOT in git); patch it in place so the fallback carries a fresh token.
OPENCLAW_JSON="${HOME}/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_JSON" ]; then
    TMP="$(mktemp)"
    if jq --arg t "$TOKEN" \
        '.skills.entries["gh-issues"].apiKey = $t' \
        "$OPENCLAW_JSON" > "$TMP" 2>/dev/null; then
        # only overwrite if jq produced valid JSON (i.e. skills key exists or can be added)
        if jq -e . "$TMP" >/dev/null 2>&1; then
            cp "$TMP" "$OPENCLAW_JSON"
            chmod 600 "$OPENCLAW_JSON"
            echo "[gh-app-auth] openclaw.json gh-issues apiKey refreshed"
        fi
    fi
    rm -f "$TMP"
fi

# ── 6. Optional: bot commit identity ──────────────────────────────
# Commits by the app appear as "<slug>[bot]" with a noreply address that
# contains the BOT USER's numeric ID — NOT the app ID (classic gotcha).
# The bot user ID is public: https://api.github.com/users/<slug>%5Bbot%5D
if [ "$SETUP_GIT_IDENTITY" = "1" ]; then
    SLUG="$(printf '%s' "$BOT_LOGIN" | sed 's/\[bot\]$//')"
    BOT_ID="$(curl -fsSL "https://api.github.com/users/${SLUG}%5Bbot%5D" | jq -r '.id' 2>/dev/null || true)"
    if [ -n "$BOT_ID" ] && [ "$BOT_ID" != "null" ]; then
        git config --global user.name "${SLUG}[bot]"
        git config --global user.email "${BOT_ID}+${SLUG}[bot]@users.noreply.github.com"
        echo "[gh-app-auth] git identity set to ${SLUG}[bot] <${BOT_ID}+${SLUG}[bot]@users.noreply.github.com>"
    else
        echo "[gh-app-auth] WARN: could not resolve bot user id — git identity NOT changed" >&2
    fi
fi

echo "[gh-app-auth] done."

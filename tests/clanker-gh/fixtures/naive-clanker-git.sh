#!/bin/bash
# fixtures/naive-clanker-git.sh — PRE-FIX-Stand von scripts/clanker-git (Issue #103).
# Nur fuer tests/clanker-gh/run.sh --red: belegt, dass der git-Credential-Helper das
# ambient GH_TOKEN sieht → push laeuft als Ambient-User.
set -euo pipefail
APP="momo-clanker"
if gh-bot-auth.sh --app "$APP" >/dev/null 2>&1; then
  export GH_CONFIG_DIR="$HOME/.config/gh-$APP"
  BOT_ID="$(gh-bot-auth.sh --app "$APP" --bot-id 2>/dev/null || true)"
  if [ -n "$BOT_ID" ] && [ "$BOT_ID" != "null" ]; then
    export GIT_AUTHOR_NAME="${APP}[bot]"
    export GIT_AUTHOR_EMAIL="${BOT_ID}+${APP}[bot]@users.noreply.github.com"
    export GIT_COMMITTER_NAME="${APP}[bot]"
    export GIT_COMMITTER_EMAIL="${BOT_ID}+${APP}[bot]@users.noreply.github.com"
  else
    echo "clanker-git: WARN could not resolve ${APP}[bot] user id" >&2
  fi
else
  echo "clanker-git: $APP not configured — falling back to default git" >&2
fi
exec git "$@"

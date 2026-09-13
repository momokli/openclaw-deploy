#!/bin/bash
# fixtures/naive-clanker-gh.sh — PRE-FIX-Stand von scripts/clanker-gh (Issue #103).
# Nur fuer tests/clanker-gh/run.sh --red: belegt, dass der Harness den Bug faengt.
# Erwartung: das ambient GH_TOKEN bleibt sichtbar → gh laeuft als Ambient-User.
set -euo pipefail
APP="momo-clanker"
if gh-bot-auth.sh --app "$APP" >/dev/null 2>&1; then
  export GH_CONFIG_DIR="$HOME/.config/gh-$APP"
else
  echo "clanker-gh: $APP not configured — falling back to default gh" >&2
fi
exec gh "$@"

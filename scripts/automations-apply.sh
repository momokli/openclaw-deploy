#!/bin/bash
# Idempotent converge der as-code Automations (mmm-loop, ci-cd-fix-loop).
# Liest die Prompts aus config/automations/*.prompt.md und legt die Cron-Jobs
# über den laufenden Gateway an (Runtime-Objekte, NICHT in openclaw.json).
#
# Nutzung (als Runtime-User, Gateway muss laufen):
#   openclaw automations-apply          # oder: bash scripts/automations-apply.sh
#
# Delivery ist bewusst `none` (--no-deliver), weil Telegram disabled ist und
# die Loops sonst "announce -> last -> no route" failen würden.
# Jobs werden mit `--disabled` angelegt, bis das planet-Routing (deviceId/
# autoDevice) verifiziert ist — dann `--disabled` entfernen bzw. editieren.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="deepseek/deepseek-flash"

apply() {
  local name="$1" key="$2" every="$3" prompt_file="$4"

  if openclaw automations list --all --json 2>/dev/null | grep -q "\"declarationKey\": *\"$key\""; then
    echo "skip  $name (declarationKey $key existiert bereits)"
    return 0
  fi

  echo "apply $name (every $every, isolated, $MODEL, delivery none, disabled)"
  openclaw automations create \
    --name "$name" \
    --declaration-key "$key" \
    --every "$every" \
    --session isolated \
    --model "$MODEL" \
    --no-deliver \
    --disabled \
    --message "$(cat "$DIR/config/automations/$prompt_file")"
  echo "done  $name"
}

apply "mmm-loop"      "mmm-loop:main"        "30m" "mmm-loop.prompt.md"
apply "ci-cd-fix-loop" "ci-cd-fix-loop:main" "15m" "ci-cd-fix-loop.prompt.md"
apply "triage-loop"    "triage-loop:main"     "5m"  "triage-loop.prompt.md"

echo "Automations converged."

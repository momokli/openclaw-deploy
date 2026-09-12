#!/bin/bash
# Idempotent converge der as-code Automations (Runner A/B je Repo).
#
# Runner A ("triage")  = Issue → Dispatch an Orchestrator (kein Review/Merge).
# Runner B ("pr-gate") = PR → rebase/review/merge/reject (kein Issue-Anlegen).
#
# Repos:
#   riftbreaker-battle-mod  → Milestone aus GitHub (dynamisch), Takt 5m
#   openclaw-deploy         → Label/Prio (kein Milestone),         Takt 30m
#
# Liest die Prompts aus config/automations/*.prompt.md und convergt die
# Cron-Jobs über den laufenden Gateway (Runtime-Objekte, NICHT in openclaw.json).
# `create`/`edit` ist idempotent über `--declaration-key`; stale Jobs der alten
# Loop-Generation werden entfernt.
#
# Nutzung (als Runtime-User, Gateway muss laufen):
#   openclaw automations-apply          # oder: bash scripts/automations-apply.sh
#
# Delivery ist `none` (--no-deliver), weil Telegram disabled ist und die
# Runner sonst "announce -> last -> no route" failen würden.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="deepseek/deepseek-flash"
# Ziel-Milestone der rift-*-Runner (Name im GitHub-Milestone).
RIFT_MILESTONE="${RIFT_MILESTONE:-1.0}"

JOBS="$(openclaw automations list --all --json 2>/dev/null || echo '{"jobs":[]}')"

job_id() {
  printf '%s' "$JOBS" | jq -r --arg k "$1" '.jobs[] | select(.declarationKey == $k) | .id' | head -1
}

# apply NAME KEY EVERY PROMPT_FILE [MILESTONE]
apply() {
  local name="$1" key="$2" every="$3" prompt_file="$4" milestone="${5:-}"
  local msg id
  msg="$(cat "$DIR/config/automations/$prompt_file")"
  if [ -n "$milestone" ]; then
    msg="$(printf '%s' "$msg" | sed "s|__RIFT_MILESTONE__|$milestone|g")"
  fi
  id="$(job_id "$key")"

  if [ -n "$id" ]; then
    echo "edit  $name ($key)"
    openclaw automations edit "$id" \
      --name "$name" \
      --every "$every" \
      --model "$MODEL" \
      --no-deliver \
      --enable \
      --message "$msg"
  else
    echo "apply $name ($key, every $every, isolated, $MODEL, delivery none)"
    openclaw automations create \
      --name "$name" \
      --declaration-key "$key" \
      --every "$every" \
      --session isolated \
      --model "$MODEL" \
      --no-deliver \
      --message "$msg"
  fi
  echo "done  $name"
}

# remove_stale KEY...
remove_stale() {
  local key id
  for key in "$@"; do
    id="$(job_id "$key")"
    if [ -n "$id" ]; then
      echo "rm    stale $key ($id)"
      openclaw automations rm "$id"
    else
      echo "skip  stale $key (nicht vorhanden)"
    fi
  done
}

apply "rift-triage"  "rift-triage:main"  "5m"  "rift-triage.prompt.md"  "$RIFT_MILESTONE"
apply "rift-pr-gate" "rift-pr-gate:main" "5m"  "rift-pr-gate.prompt.md" "$RIFT_MILESTONE"
apply "ocd-triage"   "ocd-triage:main"   "30m" "ocd-triage.prompt.md"
apply "ocd-pr-gate"  "ocd-pr-gate:main"  "30m" "ocd-pr-gate.prompt.md"

remove_stale \
  "rbb-triage-loop:main" \
  "milestone-orchestrator:main" \
  "triage-loop:main" \
  "mmm-loop:main" \
  "ci-cd-fix-loop:main"

echo "Automations converged."

#!/bin/bash
# Idempotent converge der as-code Automations (Runner A/B je Repo).
#
# Runner A ("triage")  = Issue → Dispatch an Orchestrator (kein Review/Merge).
# Runner B ("pr-gate") = PR → rebase/review/merge/reject (kein Issue-Anlegen).
#
# Repos:
#   riftbreaker-battle-mod  → Fokus-Milestone wird zur LAUFZEIT ermittelt
#                             (scripts/rift-focus-milestone.sh = kleinster offener
#                             Milestone mit Versions-Titel); Takt 6h (Fallback — die
#                             Arbeit machen die 5-min-Shell-Ticks, siehe docs/automations.md)
#   openclaw-deploy         → Label/Prio (kein Milestone), Takt 30m
#
# Kein Milestone-Name mehr im Prompt: der Platzhalter __RIFT_MILESTONE__ ist entfernt.
# Den Fokus wechselt man, indem man den Fokus-Milestone SCHLIESST — kein Redeploy.
# Methodik: docs/milestone-methodology.md
#
# Liest die Prompts aus config/automations/*.prompt.md und convergt die
# Cron-Jobs über den laufenden Gateway (Runtime-Objekte, NICHT in openclaw.json).
# `create`/`edit` ist idempotent über `--declaration-key`; stale Jobs der alten
# Loop-Generation werden entfernt.
#
# Converge ist bewusst NICHT aktivierend: dieses Script setzt nur die Definition
# (Name, Takt, Modell, Message). Aktivieren bleibt ein expliziter Schritt:
#   openclaw automations enable <uuid>   # bzw. disable
# Sonst würde jeder Deploy die Runner still einschalten.
#
# Nutzung (als Runtime-User, Gateway muss laufen):
#   openclaw automations-apply          # oder: bash scripts/automations-apply.sh
#
# Delivery ist `none` (--no-deliver), weil Telegram disabled ist und die
# Runner sonst "announce -> last -> no route" failen würden.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="openrouter/deepseek/deepseek-v4.1-flash"

JOBS="$(openclaw automations list --all --json 2>/dev/null || echo '{"jobs":[]}')"

job_id() {
  printf '%s' "$JOBS" | jq -r --arg k "$1" '.jobs[] | select(.declarationKey == $k) | .id' | head -1
}

# apply NAME KEY EVERY PROMPT_FILE
apply() {
  local name="$1" key="$2" every="$3" prompt_file="$4"
  local msg id
  msg="$(cat "$DIR/config/automations/$prompt_file")"
  if printf '%s' "$msg" | grep -q '__RIFT_MILESTONE__'; then
    echo "FEHLER: $prompt_file enthaelt noch __RIFT_MILESTONE__." >&2
    echo "        Der Fokus kommt zur Laufzeit aus scripts/rift-focus-milestone.sh." >&2
    exit 1
  fi
  id="$(job_id "$key")"

  if [ -n "$id" ]; then
    echo "edit  $name ($key)"
    # Bewusst KEIN --enable (siehe Kopf): Converge definiert nur.
    openclaw automations edit "$id" \
      --name "$name" \
      --every "$every" \
      --model "$MODEL" \
      --no-deliver \
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

apply "rift-triage"  "rift-triage:main"  "6h"  "rift-triage.prompt.md"
apply "rift-pr-gate" "rift-pr-gate:main" "6h"  "rift-pr-gate.prompt.md"
apply "ocd-triage"   "ocd-triage:main"   "30m" "ocd-triage.prompt.md"
apply "ocd-pr-gate"  "ocd-pr-gate:main"  "30m" "ocd-pr-gate.prompt.md"

remove_stale \
  "rbb-triage-loop:main" \
  "milestone-orchestrator:main" \
  "triage-loop:main" \
  "mmm-loop:main" \
  "ci-cd-fix-loop:main"

echo "Automations converged."

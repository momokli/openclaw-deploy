#!/bin/bash
# Idempotent converge der as-code Automations (Runner A/B je Repo).
#
# Runner A ("triage")  = Issue → Dispatch an einen Orchestrator (kein Review/Merge).
# Runner B ("pr-gate") = PR → rebase/review/merge/reject (kein Issue-Anlegen).
#
# Ein Runner = eine Instanz für EIN Repo. Die Instanzen stehen in
# `config/runners/<profil>.conf`; die Prompts in `config/automations/<profil>-*.prompt.md`.
# Geteilt ist nur die Engine (`scripts/runner-*.sh`).
#
#   rift  → riftbreaker-battle-mod  (Takt 6h Fallback, Ticks 5m)
#   mmm   → momos-music-manager     (Takt 6h Fallback, Ticks 5m)
#   ocd-* → openclaw-deploy         (Label/Prio, kein Milestone, Takt 30m)
#
# Je Runner gibt es ZWEI Ebenen (docs/automations.md):
#   - Agent-Turn   (Modell, 6h Fallback)
#   - Shell-Tick   (--command, 5m, 0 Tokens) — triggert den Agent-Turn nur bei Bedarf
#
# Converge ändert den AKTIV-Status bestehender Jobs NICHT (der `edit`-Pfad fasst
# `enabled` nicht an) und schaltet nichts ab. ACHTUNG: `openclaw automations create`
# legt neue Jobs per Default **enabled** an — wer einen Runner bewusst nur definieren
# will, nimmt hinterher `openclaw automations disable <uuid>`. Das ist relevant für
# den `--command`-Tick: ist er aktiv, feuert er sofort.
#
# Nutzung (als Runtime-User, Gateway muss laufen):
#   openclaw automations-apply          # oder: bash scripts/automations-apply.sh
#
# Delivery ist `none` (--no-deliver), weil Telegram disabled ist und die
# Runner sonst "announce -> last -> no route" failen würden.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="openrouter/deepseek/deepseek-v4.1-flash"
PROFILES="${RUNNER_PROFILES:-rift mmm}"

JOBS="$(openclaw automations list --all --json 2>/dev/null || echo '{"jobs":[]}')"

job_id() {
  printf '%s' "$JOBS" | jq -r --arg k "$1" '.jobs[] | select(.declarationKey == $k) | .id' | head -1
}

# apply_agent NAME KEY EVERY PROMPT_FILE
apply_agent() {
  local name="$1" key="$2" every="$3" prompt_file="$4"
  local msg id
  msg="$(cat "$DIR/config/automations/$prompt_file")"
  if printf '%s' "$msg" | grep -q '__RIFT_MILESTONE__'; then
    echo "FEHLER: $prompt_file enthaelt noch __RIFT_MILESTONE__." >&2
    echo "        Der Fokus kommt zur Laufzeit aus scripts/runner-focus-milestone.sh." >&2
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

# apply_tick NAME KEY PROFILE COMMAND
# Die `--command`-Payload läuft als `sh -lc` auf dem Gateway; RUNNER_PROFILE
# wählt das Repo-Profil (0 Tokens, kein Modell).
apply_tick() {
  local name="$1" key="$2" profile="$3" cmd="$4" id
  id="$(job_id "$key")"

  if [ -n "$id" ]; then
    echo "edit  $name ($key)"
    openclaw automations edit "$id" \
      --name "$name" \
      --every "5m" \
      --command "$cmd" \
      --command-env "RUNNER_PROFILE=$profile" \
      --no-deliver
  else
    echo "apply $name ($key, every 5m, command, profile $profile, delivery none)"
    openclaw automations create \
      --name "$name" \
      --declaration-key "$key" \
      --every "5m" \
      --session isolated \
      --command "$cmd" \
      --command-env "RUNNER_PROFILE=$profile" \
      --no-deliver
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

# Profil-gebundene Runner (A/B + Ticks). Subshell = sauberer Env je Profil.
for profile in $PROFILES; do
  (
    RUNNER_PROFILE="$profile"
    export RUNNER_PROFILE
    # shellcheck source=/dev/null
    . "$DIR/scripts/runner-profile.sh"

    if [ ! -f "$DIR/config/automations/$RUNNER_STATE_PREFIX-triage.prompt.md" ]; then
      echo "skip  Profil $profile (noch keine Prompts: config/automations/$RUNNER_STATE_PREFIX-*.prompt.md)"
      exit 0
    fi

    echo "── Profil $profile ($RUNNER_REPO) ──"
    apply_agent "$RUNNER_STATE_PREFIX-triage"  "$RUNNER_TRIAGE_KEY" "6h" "$RUNNER_STATE_PREFIX-triage.prompt.md"
    apply_agent "$RUNNER_STATE_PREFIX-pr-gate" "$RUNNER_GATE_KEY"   "6h" "$RUNNER_STATE_PREFIX-pr-gate.prompt.md"
    # Die Ticks rufen die Engine per Bare-Name auf. Fehlt sie (setup-native.sh noch
    # nicht gelaufen), NICHTS umbiegen — sonst liefe der laufende Tick ins Leere.
    if command -v runner-triage-tick.sh >/dev/null 2>&1 \
       && command -v runner-pr-gate-tick.sh >/dev/null 2>&1; then
      apply_tick  "$RUNNER_STATE_PREFIX-triage-tick"  "$RUNNER_STATE_PREFIX-triage-tick:main" \
        "$profile" "runner-triage-tick.sh >> $RUNNER_TICK_LOG 2>&1"
      apply_tick  "$RUNNER_STATE_PREFIX-pr-gate-tick" "$RUNNER_STATE_PREFIX-pr-gate-tick:main" \
        "$profile" "runner-pr-gate-tick.sh >> $RUNNER_TICK_LOG 2>&1"
    else
      echo "WARN  $profile: runner-*-tick.sh nicht im PATH (~/.local/bin) — Ticks übersprungen."
      echo "      Erst \"sudo bash scripts/setup-native.sh <user>\" laufen lassen, dann erneut convergen."
    fi
  )
done

# openclaw-deploy: Label/Prio, kein Milestone — eigener Prompt-Satz, kein Profil/Tick.
apply_agent "ocd-triage"  "ocd-triage:main"  "30m" "ocd-triage.prompt.md"
apply_agent "ocd-pr-gate" "ocd-pr-gate:main" "30m" "ocd-pr-gate.prompt.md"

remove_stale \
  "rbb-triage-loop:main" \
  "milestone-orchestrator:main" \
  "triage-loop:main" \
  "mmm-loop:main" \
  "ci-cd-fix-loop:main"

echo "Automations converged."

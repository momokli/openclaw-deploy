#!/bin/bash
# install-runner-engine.sh — installiert die geteilte Runner-Engine in ~/.local/bin.
#
# Bewusst getrennt von `setup-native.sh` (das ist ein Bootstrap für einen FRISCHEN
# Host: Config-Sync, Plugins, Gateway-Service). Auf einer laufenden Instanz würde
# das die Runtime überschreiben — die Engine zu erneuern ist dagegen gefahrlos.
#
# Idempotent, **kein root**: ~/.local/bin gehört dem Runtime-User. Die Automations
# rufen die Skripte per Bare-Name auf (der PATH des Gateway-Service enthält
# ~/.local/bin). Die Profile müssen NEBEN den Skripten liegen, weil
# `runner-profile.sh` sie relativ zur Engine sucht (`runner-profiles/`).
#
# Nutzung:
#   bash scripts/install-runner-engine.sh                 # Ziel: $HOME/.local/bin
#   RUNNER_BIN=/pfad bash scripts/install-runner-engine.sh

set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${RUNNER_BIN:-$HOME/.local/bin}"

install -d -m 755 "$BIN" "$BIN/runner-profiles"

# Engine + Kompatibilitäts-Shims (die laufenden --command-Payloads rufen die
# alten rift-*-Namen auf).
# Diese Liste ist die Wahrheit fuer Installation UND Drift-Check. `runner-close-milestones.sh`
# stand hier frueher NICHT — deshalb lief auf dem Host monatelang eine Version ohne den
# bd3cf3a-Fix, ohne dass es auffiel (Hash-Vergleich am 2026-11-16).
ENGINE_FILES=(
  runner-profile.sh
  runner-focus-milestone.sh
  runner-stale-dispatch.sh
  runner-triage-tick.sh
  runner-pr-gate-tick.sh
  runner-triage-cleanup.sh
  runner-close-milestones.sh
  runner-close-milestone.sh
  rift-focus-milestone.sh
  rift-stale-dispatch.sh
  rift-triage-tick.sh
  rift-pr-gate-tick.sh
  rift-triage-cleanup.sh
)

# Drift-Check (RUNNER_DRIFT_CHECK=1): nichts installieren, nur melden, was abweicht.
if [ "${RUNNER_DRIFT_CHECK:-0}" = "1" ]; then
  drift=0
  for f in "${ENGINE_FILES[@]}"; do
    [ -f "$RUN_DIR/scripts/$f" ] || continue
    if [ ! -f "$BIN/$f" ]; then
      printf 'MISSING %s\n' "$f"; drift=$((drift + 1))
    elif ! cmp -s "$RUN_DIR/scripts/$f" "$BIN/$f"; then
      printf 'DRIFT   %s\n' "$f"; drift=$((drift + 1))
    fi
  done
  [ "$drift" -eq 0 ] && echo "OK: keine Drift ($BIN)" || echo "DRIFT: $drift Datei(en) weichen ab"
  exit 0
fi

for f in "${ENGINE_FILES[@]}"; do
  [ -f "$RUN_DIR/scripts/$f" ] || continue
  install -m 755 "$RUN_DIR/scripts/$f" "$BIN/$f"
done

# Profile (Repo-Bindung je Projekt).
for p in "$RUN_DIR"/config/runners/*.conf; do
  [ -f "$p" ] || continue
  install -m 644 "$p" "$BIN/runner-profiles/$(basename "$p")"
done

# Installations-Manifest (Datei -> sha256 + Repo-Commit): damit ist ein Drift spaeter
# belegbar, ohne die Dateien einzeln zu vergleichen.
{
  printf '# install-runner-engine %s\n' "$(git -C "$RUN_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  for f in "$BIN"/runner-*.sh "$BIN"/rift-*.sh; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
  done
} > "$BIN/.runner-manifest.tmp"
mv "$BIN/.runner-manifest.tmp" "$BIN/.runner-manifest"

echo "Runner-Engine installiert in $BIN:"
ls -1 "$BIN"/runner-*.sh "$BIN"/rift-*.sh 2>/dev/null | sed 's#^#  #'
ls -1 "$BIN"/runner-profiles/*.conf 2>/dev/null | sed 's#^#  #'

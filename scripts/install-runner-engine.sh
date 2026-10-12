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
for f in \
  runner-profile.sh runner-focus-milestone.sh runner-stale-dispatch.sh \
  runner-triage-tick.sh runner-pr-gate-tick.sh runner-triage-cleanup.sh \
  rift-focus-milestone.sh rift-stale-dispatch.sh \
  rift-triage-tick.sh rift-pr-gate-tick.sh rift-triage-cleanup.sh; do
  [ -f "$RUN_DIR/scripts/$f" ] || continue
  install -m 755 "$RUN_DIR/scripts/$f" "$BIN/$f"
done

# Profile (Repo-Bindung je Projekt).
for p in "$RUN_DIR"/config/runners/*.conf; do
  [ -f "$p" ] || continue
  install -m 644 "$p" "$BIN/runner-profiles/$(basename "$p")"
done

echo "Runner-Engine installiert in $BIN:"
ls -1 "$BIN"/runner-*.sh "$BIN"/rift-*.sh 2>/dev/null | sed 's#^#  #'
ls -1 "$BIN"/runner-profiles/*.conf 2>/dev/null | sed 's#^#  #'

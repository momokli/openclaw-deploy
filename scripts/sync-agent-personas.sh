#!/bin/bash
# Sync config/agents/*.md -> per-agent workspace AGENTS.md (native, user momo).
#
# Persona-Mapping:
#   - critic          -> critic            (nicht feature-dev-critic)
#   - web-researcher  -> web-researcher    (nicht feature-dev-web-researcher)
#
# Grund: OpenClaw injiziert nur Bootstrap-Dateien aus dem Agent-Workspace
# (Bug #29387: agentDir/AGENTS.md wird ignoriert), daher muss die Persona
# als <workspace>/AGENTS.md liegen.
#
# Nutzung (als root): sudo bash scripts/sync-agent-personas.sh [RUN_USER]

set -euo pipefail

RUN_USER="${1:-momo}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)/.openclaw"

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausfuehren: sudo bash scripts/sync-agent-personas.sh $RUN_USER"
    exit 1
fi

# Verzeichnisse VOR dem Sync dem Runtime-User zuordnen. `install -d` setzt Owner/Mode
# nur auf dem benannten Zielverzeichnis, `mkdir -p` gar nicht: auf einem frischen Host
# entstuenden ~/.openclaw und ~/.openclaw/workspaces als root:root und der Runtime-User
# koennte in seinem eigenen Workspace keine State-Dateien anlegen (Issue #96).
mkdir -p "$STATE_DIR"
chown "$RUN_USER":"$RUN_USER" "$STATE_DIR"
mkdir -p "$STATE_DIR/workspaces"
chown "$RUN_USER":"$RUN_USER" "$STATE_DIR/workspaces"

map_id() {
    case "$1" in
        orchestrator)          echo "coding-orchestrator" ;;
        thinking-orchestrator) echo "thinking-orchestrator" ;;
        planning-orchestrator) echo "planning-orchestrator" ;;
        operator|plan-builder|researcher|web-researcher|critic) echo "$1" ;;
        *)                     echo "feature-dev-$1" ;;
    esac
}

for f in "$REPO_DIR"/config/agents/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    id="$(map_id "$base")"
    dest="$STATE_DIR/workspaces/$id/AGENTS.md"
    # Owner+Mode direkt beim Anlegen setzen (statt mkdir als root ohne chown).
    install -d -m 700 -o "$RUN_USER" -g "$RUN_USER" "$(dirname "$dest")"
    install -m 644 -o "$RUN_USER" -g "$RUN_USER" "$f" "$dest"
    echo "synced $base -> workspaces/$id/AGENTS.md"
done

echo "Agent personas synced."

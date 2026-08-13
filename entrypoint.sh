#!/bin/sh
# OpenClaw entrypoint: sync git config into runtime home, then start gateway
set -e

SRC="/openclaw-config"
HOME_DIR="/home/node/.openclaw"

log() { echo "[entrypoint] $*"; }

# 1. Gateway config — copy from git if changed
if [ -f "$SRC/openclaw.json" ]; then
    if ! cmp -s "$SRC/openclaw.json" "$HOME_DIR/openclaw.json" 2>/dev/null; then
        cp "$SRC/openclaw.json" "$HOME_DIR/openclaw.json"
        log "openclaw.json updated"
    fi
fi

# 2. Secrets — copy .env into home (OpenClaw reads it there too)
if [ -f "$SRC/.env" ]; then
    cp "$SRC/.env" "$HOME_DIR/.env"
    chmod 600 "$HOME_DIR/.env"
fi

# 3. Agent personas — map flat git files to per-agent AGENTS.md
for f in "$SRC"/agents/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    if [ "$base" = "orchestrator" ]; then
        id="coding-orchestrator"
    else
        id="feature-dev-$base"
    fi
    mkdir -p "$HOME_DIR/agents/$id/agent"
    cp "$f" "$HOME_DIR/agents/$id/agent/AGENTS.md"
done
log "agent personas synced"

# 4. Main agent personas — ALWAYS copy from git (source of truth).
#    MEMORY.md is seeded only if missing (agent writes to it at runtime).
mkdir -p "$HOME_DIR/workspace"
for f in "$SRC"/workspace/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    if [ "$base" = "MEMORY.md" ]; then
        [ -f "$HOME_DIR/workspace/$base" ] || cp "$f" "$HOME_DIR/workspace/$base"
    else
        cp "$f" "$HOME_DIR/workspace/$base"
    fi
done

# 5. Ensure runtime home is owned by node (entrypoint runs as root)
chown -R node:node "$HOME_DIR" 2>/dev/null || true
chown -R node:node "$HOME_DIR/workspace" 2>/dev/null || true

# 6. Start gateway as node (original entrypoint: tini)
exec gosu node tini -s -- "$@"

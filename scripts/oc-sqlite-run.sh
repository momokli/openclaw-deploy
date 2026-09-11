#!/bin/bash
# oc-sqlite-run.sh — container-agnostic runner for scripts/oc-sqlite.mjs.
#
# Picks the live OpenClaw runtime automatically:
#   * Docker container `openclaw` running  → docker exec (pre-native-migration layout)
#   * otherwise                            → native node (post-migration: openclaw-gateway.service)
#
# The native runtime keeps its per-agent SQLite DBs on the host under
# $HOME/.openclaw/agents/<agent>/agent/openclaw-agent.sqlite (in the container that base dir
# is /home/node/.openclaw/agents, which oc-sqlite.mjs falls back to by default).
#
# Usage:
#   OC_START_UTC=2026-08-31T00:00:00Z OC_END_UTC=2026-09-01T00:00:00Z \
#     scripts/oc-sqlite-run.sh > /tmp/oc_sqlite.jsonl
#
# Env (all optional, passed through to oc-sqlite.mjs):
#   OC_START_UTC   ISO-8601 UTC window start (default: now - 24h, see oc-sqlite.mjs)
#   OC_END_UTC     ISO-8601 UTC window end   (default: now)
#   OC_AGENTS_DIR  native per-agent DB base dir (default: $HOME/.openclaw/agents)
#
# Exit: 0 on success, non-zero (with a clear stderr message) when no runtime can produce data.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_sqlite() {
  if [ "$(docker inspect -f '{{.State.Running}}' openclaw 2>/dev/null || true)" = "true" ]; then
    docker exec -i -u node \
      -e "OC_START_UTC=${OC_START_UTC:-}" -e "OC_END_UTC=${OC_END_UTC:-}" \
      openclaw node --input-type=module - < "$SCRIPT_DIR/oc-sqlite.mjs"
    return $?
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "oc-sqlite-run: no running container 'openclaw' and no native node on PATH" >&2
    return 1
  fi
  OC_AGENTS_DIR="${OC_AGENTS_DIR:-$HOME/.openclaw/agents}" \
    node --input-type=module - < "$SCRIPT_DIR/oc-sqlite.mjs"
}

if ! run_sqlite; then
  echo "oc-sqlite-run: SQLite extraction failed (no usable runtime / helper error)" >&2
  exit 1
fi

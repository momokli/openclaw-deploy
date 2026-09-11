#!/bin/bash
# One-time backfill of cost-history.json from the per-agent SQLite DBs.
# Safe to re-run: rebuilds the history from scratch (then cost-snapshot.sh
# adds the current balance for today).
#
# Container-agnostic: extraction goes through scripts/oc-sqlite-run.sh (Docker `openclaw`
# if running, else native node against $HOME/.openclaw/agents). The old
# `*.trajectory.jsonl` files no longer exist since the 2026-08-31 SQLite migration.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd /opt/apps/openclaw
HIST="${OC_COST_HISTORY:-/opt/apps/openclaw/cost-history.json}"

OC_START_UTC="1970-01-01T00:00:00Z" OC_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$SCRIPT_DIR/oc-sqlite-run.sh" > /tmp/oc_sqlite.jsonl

jq -c 'select(.kind == "usage")' /tmp/oc_sqlite.jsonl > /tmp/oc_calls.json

jq -c -s 'group_by(.ts / 1000 | floor | todateiso8601 | split("T")[0])
  | map({ date: (.[0].ts / 1000 | floor | todateiso8601 | split("T")[0]),
          n: length,
          input: (map(.input // 0) | add),
          cacheRead: (map(.cacheRead // 0) | add),
          output: (map(.output // 0) | add),
          reasoning: (map(.reasoning // 0) | add),
          pro: (map(select(.model | contains("pro"))) | length),
          flash: (map(select(.model | contains("flash"))) | length),
          balance: null })
  | sort_by(.date)' /tmp/oc_calls.json > "$HIST"

echo "seeded $(jq length "$HIST") days"

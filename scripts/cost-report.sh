#!/bin/bash
# Cost report for OpenClaw — run on the .149 host.
# Shows OpenRouter balance, per-day token usage, and the pro/flash split.
# Usage: ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/cost-report.sh'

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd /opt/apps/openclaw

echo "=== OpenRouter / Usage ==="
openclaw status --usage 2>&1 \
  | grep -iE 'openrouter|balance' | head -6

# Per-call usage from the per-agent SQLite DBs (all history).
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START="1970-01-01T00:00:00Z"
OC_START_UTC="$START" OC_END_UTC="$END" \
  /opt/node/bin/node "$SCRIPT_DIR/oc-sqlite.mjs" \
  > /tmp/oc_sqlite.jsonl

jq -c 'select(.kind == "usage")' /tmp/oc_sqlite.jsonl > /tmp/oc_calls.jsonl || true

echo
echo "=== Tokens per day (UTC) — calls | input-miss | cacheRead | output | reasoning ==="
jq -sr 'group_by((.ts / 1000 | floor | todateiso8601 | split("T")[0]))
  | map({d:(.[0].ts / 1000 | floor | todateiso8601 | split("T")[0]), n:length,
        in:(map(.input // 0)|add), cr:(map(.cacheRead // 0)|add),
        out:(map(.output // 0)|add), r:(map(.reasoning // 0)|add)})
  | sort_by(.d) | .[] | [.d, .n, .in, .cr, .out, .r] | @tsv' /tmp/oc_calls.jsonl || true

echo
echo "=== Model split (alle Calls) ==="
jq -sr 'group_by(.model) | map([.[0].model, length] | @tsv) | .[]' /tmp/oc_calls.jsonl || true

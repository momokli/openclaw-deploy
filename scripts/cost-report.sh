#!/bin/bash
# Cost report for OpenClaw — run on the .149 host.
# Shows DeepSeek balance, per-day token usage, and the flash/pro split.
# Usage: ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/cost-report.sh'

set -euo pipefail
cd /opt/apps/openclaw

echo "=== DeepSeek Balance ==="
docker compose exec -T -u node openclaw openclaw status --usage 2>&1 \
  | grep -iE 'deepseek|balance' | head -6

# Extract model.completed usage from all session trajectory files.
docker compose exec -T -u node openclaw sh -c \
  'cat /home/node/.openclaw/agents/*/sessions/*.trajectory.jsonl 2>/dev/null' \
  > /tmp/oc_calls_raw.jsonl || true

jq -s -c '[.[] | select(.type=="model.completed") | {ts, modelId, sessionKey, usage: .data.usage}]' \
  /tmp/oc_calls_raw.jsonl > /tmp/oc_calls.json 2>/dev/null || true

echo
echo "=== Tokens per day (UTC) — calls | input-miss | cacheRead | output | reasoning ==="
jq -r 'group_by(.ts | split("T")[0])
  | map({d:(.[0].ts|split("T")[0]), n:length,
        in:(map(.usage.input//0)|add), cr:(map(.usage.cacheRead//0)|add),
        out:(map(.usage.output//0)|add), r:(map(.usage.reasoningTokens//0)|add)})
  | sort_by(.d) | .[] | [.d,.n,.in,.cr,.out,.r] | @tsv' /tmp/oc_calls.json || true

echo
echo "=== Model split (alle Calls) ==="
jq -r 'group_by(.modelId) | map([.[0].modelId, length] | @tsv) | .[]' /tmp/oc_calls.json || true

#!/bin/bash
# One-time backfill of cost-history.json from existing session transcripts.
# Safe to re-run: rebuilds the history from scratch (then cost-snapshot.sh
# adds the current balance for today).
set -euo pipefail
cd /opt/apps/openclaw
HIST="/opt/apps/openclaw/cost-history.json"

docker compose exec -T -u node openclaw sh -c \
  'cat /home/node/.openclaw/agents/*/sessions/*.trajectory.jsonl 2>/dev/null' \
  > /tmp/oc_raw.jsonl || true

jq -s -c '[.[] | select(.type=="model.completed") | {ts, modelId, usage: .data.usage}]' \
  /tmp/oc_raw.jsonl > /tmp/oc_calls.json

jq -c 'group_by(.ts | split("T")[0])
  | map({ date: (.[0].ts | split("T")[0]),
          n: length,
          input: (map(.usage.input // 0) | add),
          cacheRead: (map(.usage.cacheRead // 0) | add),
          output: (map(.usage.output // 0) | add),
          reasoning: (map(.usage.reasoningTokens // 0) | add),
          pro: (map(select(.modelId | contains("pro"))) | length),
          flash: (map(select(.modelId | contains("flash"))) | length),
          balance: null })
  | sort_by(.date)' /tmp/oc_calls.json > "$HIST"

echo "seeded $(jq length "$HIST") days"

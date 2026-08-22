#!/bin/bash
# Append today's cost snapshot to /opt/apps/openclaw/cost-history.json.
# Idempotent: re-running on the same day replaces that day's record.
# Intended to run daily (see openclaw-cost.timer) on the .149 host.
set -euo pipefail
cd /opt/apps/openclaw
HIST="/opt/apps/openclaw/cost-history.json"
TODAY="$(date -u +%Y-%m-%d)"

# 1. DeepSeek balance (from `openclaw status --usage`)
BAL="$(docker compose exec -T -u node openclaw openclaw status --usage 2>/dev/null \
  | grep -iE 'balance' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)"

# 2. Extract model.completed usage from all session trajectory files
docker compose exec -T -u node openclaw sh -c \
  'cat /home/node/.openclaw/agents/*/sessions/*.trajectory.jsonl 2>/dev/null' \
  > /tmp/oc_calls_raw.jsonl || true

jq -s -c '[.[] | select(.type=="model.completed") | {ts, modelId, usage: .data.usage}]' \
  /tmp/oc_calls_raw.jsonl > /tmp/oc_calls.json 2>/dev/null || echo '[]' > /tmp/oc_calls.json

# 3. Today's aggregate + model split
TODAY_STATS="$(jq -c --arg d "$TODAY" '
  map(select(.ts >= ($d + "T00:00:00Z") and .ts < ($d + "T23:59:59Z")))
  | { n: length,
      input: (map(.usage.input // 0) | add),
      cacheRead: (map(.usage.cacheRead // 0) | add),
      output: (map(.usage.output // 0) | add),
      reasoning: (map(.usage.reasoningTokens // 0) | add),
      pro: (map(select(.modelId | contains("pro"))) | length),
      flash: (map(select(.modelId | contains("flash"))) | length) }' \
  /tmp/oc_calls.json)"

# 4. Build record + upsert into history (dedupe by date)
RECORD="$(jq -nc --arg d "$TODAY" --arg bal "$BAL" --argjson s "$TODAY_STATS" '
  { date: $d,
    balance: (if $bal == "" then null else ($bal | tonumber) end),
    n: $s.n, input: $s.input, cacheRead: $s.cacheRead,
    output: $s.output, reasoning: $s.reasoning,
    pro: $s.pro, flash: $s.flash }')"

if [ -f "$HIST" ]; then
  jq -c --argjson rec "$RECORD" '(map(select(.date != $rec.date)) + [$rec]) | sort_by(.date)' \
    "$HIST" > /tmp/oc_hist.json
else
  jq -c --argjson rec "$RECORD" '[$rec]' > /tmp/oc_hist.json
fi
mv /tmp/oc_hist.json "$HIST"

echo "snapshot $TODAY — balance=$BAL n=$(echo "$TODAY_STATS" | jq .n) pro=$(echo "$TODAY_STATS" | jq .pro) flash=$(echo "$TODAY_STATS" | jq .flash)"

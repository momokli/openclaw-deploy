#!/bin/bash
# Append today's cost snapshot to /opt/apps/openclaw/cost-history.json.
# Idempotent: re-running on the same day replaces that day's record.
# Intended to run daily (see openclaw-cost.timer) on the .149 host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd /opt/apps/openclaw
HIST="/opt/apps/openclaw/cost-history.json"
TODAY="$(date -u +%Y-%m-%d)"

# 1. DeepSeek balance (from `openclaw status --usage`)
BAL="$(docker compose exec -T -u node openclaw openclaw status --usage 2>/dev/null \
  | grep -iE 'balance' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)"

# 2. Per-call usage from the per-agent SQLite DBs (today, UTC).
START="${TODAY}T00:00:00Z"
END="$(date -u -d 'tomorrow' +%Y-%m-%d)T00:00:00Z"
docker exec -i -u node \
  -e "OC_START_UTC=$START" -e "OC_END_UTC=$END" \
  openclaw node --input-type=module - < "$SCRIPT_DIR/oc-sqlite.mjs" \
  > /tmp/oc_sqlite.jsonl

jq -c 'select(.kind == "usage")' /tmp/oc_sqlite.jsonl > /tmp/oc_calls.jsonl 2>/dev/null || echo '[]' > /tmp/oc_calls.jsonl

# 3. Today's aggregate + model split
TODAY_STATS="$(jq -c -s '
  { n: length,
    input: (map(.input // 0) | add),
    cacheRead: (map(.cacheRead // 0) | add),
    output: (map(.output // 0) | add),
    reasoning: (map(.reasoning // 0) | add),
    pro: (map(select(.model | contains("pro"))) | length),
    flash: (map(select(.model | contains("flash"))) | length) }' \
  /tmp/oc_calls.jsonl)"

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
  jq -nc --argjson rec "$RECORD" '[$rec]' > /tmp/oc_hist.json
fi
mv /tmp/oc_hist.json "$HIST"

echo "snapshot $TODAY — balance=$BAL n=$(echo "$TODAY_STATS" | jq .n) pro=$(echo "$TODAY_STATS" | jq .pro) flash=$(echo "$TODAY_STATS" | jq .flash)"

#!/bin/bash
# OpenClaw event-level analytics — windowed report of chats, tools, errors, model usage & cost.
#
# Reads the live session trajectory + message logs straight from the openclaw container,
# so it always reflects the current runtime state on .149 (no need to copy files around).
#
# Usage (run on .149, from the repo root):
#   ./scripts/analytics.sh [START_UTC] [END_UTC]
#   ./scripts/analytics.sh 2026-08-22T13:00:00Z 2026-08-23T01:00:00Z
#
#   START/END are ISO-8601 UTC. Berlin time = UTC+2 (summer) / UTC+1 (winter).
#   Example: 22.08 15:00 → 23.08 03:00 Berlin == 13:00Z → 01:00Z.
#   No args = last 24h.
#
# Sections:
#   1) Sessions (chats)   2) Model usage + cost   3) Tools   4) Errors
#
# Raw extracted data is left in /tmp/oc_traj.jsonl and /tmp/oc_msgs.jsonl so you can
# re-query with your own jq. See docs/analytics.md for the event schemas and caveats.
#
# Cost estimate uses official DeepSeek off-peak $/1M (workspace/AGENTS.md). Override via env:
#   PRO_IN PRO_CR PRO_OUT        (default 0.66 / 0.022 / 1.98)
#   FLASH_IN FLASH_CR FLASH_OUT  (default 0.22 / 0.007 / 0.66)
#   (peak hours are 2× off-peak: 01:00–04:00 and 06:00–10:00 UTC)
#
# NOTE: "reasoning" is a SUBSET of "output" (DeepSeek completion_tokens includes reasoning),
# so it is NOT billed on top of output. Verified: total == input + cacheRead + output, and
# output >= reasoning for every call. Do NOT sum output + reasoning when pricing.

set -euo pipefail
cd "$(dirname "$0")/.."

# ── window ────────────────────────────────────────────────────────────
END="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
START="${1:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"

# official DeepSeek off-peak $/1M (overridable via env)
PRO_IN="${PRO_IN:-0.66}";   PRO_CR="${PRO_CR:-0.022}";   PRO_OUT="${PRO_OUT:-1.98}"
FLASH_IN="${FLASH_IN:-0.22}"; FLASH_CR="${FLASH_CR:-0.007}"; FLASH_OUT="${FLASH_OUT:-0.66}"

echo "== OpenClaw analytics — $START → $END (UTC) =="

# ── pull trajectory (session boundaries + model.completed) ────────────
docker compose exec -T -u node openclaw sh -c \
  "find /home/node/.openclaw/agents -name '*.trajectory.jsonl' -type f -exec cat {} + 2>/dev/null" \
  > /tmp/oc_traj.jsonl || true

# ── pull message logs (per-agent attribution + reset snapshots) ───────
# NOTE: include '*.jsonl.reset.*' — those hold the pre-idle-reset turns; skipping them
# undercounts long-lived sessions (main's direct DM). Exclude '.trajectory.jsonl'.
AGENTS="$(docker compose exec -T -u node openclaw sh -c \
  "find /home/node/.openclaw/agents -mindepth 1 -maxdepth 1 -type d -exec basename {} \;" 2>/dev/null || true)"
: > /tmp/oc_msgs.jsonl
for a in $AGENTS; do
  # Some agents (feature-dev-*, diary, coding) have empty or missing sessions/ dirs;
  # find then exits non-zero. Tolerate that: redirect find's stderr and ignore the status.
  docker compose exec -T -u node openclaw sh -c \
    "find /home/node/.openclaw/agents/$a/sessions -maxdepth 1 \( -name '*.jsonl' -o -name '*.jsonl.reset.*' \) ! -name '*.trajectory.jsonl' -type f -exec cat {} + 2>/dev/null" \
    2>/dev/null | sed "s/^/$a\t/" >> /tmp/oc_msgs.jsonl || true
done

# ── jq filters (embedded, see docs/analytics.md) ──────────────────────

cat > /tmp/oc_usage.jq <<'JQ'
split("\t") as $p
| ($p[1] | fromjson?) as $m
| select($m != null and $m.type == "message" and $m.message.role == "assistant"
         and $m.timestamp >= $s and $m.timestamp < $e)
| {agent: $p[0],
   model: ($m.message.model // "?"),
   input: ($m.message.usage.input // 0),
   cacheRead: ($m.message.usage.cacheRead // 0),
   cacheWrite: ($m.message.usage.cacheWrite // 0),
   output: ($m.message.usage.output // 0),
   reasoning: ($m.message.usage.reasoningTokens // 0),
   cost_raw: ($m.message.usage.cost.total // 0)}
JQ

cat > /tmp/oc_usage_agg.jq <<'JQ'
group_by([.agent, .model])
| map({agent: .[0].agent, model: .[0].model, turns: length,
       input: (map(.input)|add), cacheRead: (map(.cacheRead)|add),
       cacheWrite: (map(.cacheWrite)|add), output: (map(.output)|add),
       reasoning: (map(.reasoning)|add), cost_raw: (map(.cost_raw)|add)})
| map(. + {flash: (.model | test("flash"; "i"))})
| map(. + {est: ((if .flash
                  then (.input * $fin + .cacheRead * $fcr + .output * $fout)
                  else (.input * $pin + .cacheRead * $pcr + .output * $pout) end) / 1000000)})
| sort_by(.agent, .model)[]
| [.agent, .model, .turns, .input, .cacheRead, .cacheWrite, .output, .reasoning, .est, .cost_raw] | @tsv
JQ

cat > /tmp/oc_sessions.jq <<'JQ'
[.[] | select(.type == "session.started" and .ts >= $s and .ts < $e)
  | {agent: (.sessionKey|split(":")[1]), sessionKey, ts}]
| group_by(.sessionKey)
| map({agent: .[0].agent, sessionKey: .[0].sessionKey, runs: length,
       first: (map(.ts)|min), last: (map(.ts)|max)})
| sort_by(.first)[]
| [.agent, .sessionKey, .runs, .first, .last] | @tsv
JQ

cat > /tmp/oc_tools.jq <<'JQ'
split("\t") as $p
| ($p[1] | fromjson?) as $m
| select($m != null and $m.type == "message" and $m.timestamp >= $s and $m.timestamp < $e)
| $m.message.content[]?
| select(.type == "toolCall")
| [$p[0], .name] | @tsv
JQ

# default error signature (override via ERR_PATTERN env)
ERR_PATTERN="${ERR_PATTERN:-(?i)error|failed|exception|traceback|command not found|permission denied|no such file|fatal|refused|exit code|denied|unauthorized|bad credentials}"

cat > /tmp/oc_errors.jq <<'JQ'
split("\t") as $p
| ($p[1] | fromjson?) as $m
| select($m != null and $m.type == "message" and $m.timestamp >= $s and $m.timestamp < $e
         and $m.message.role == "toolResult")
| $m.message.content[]?
| select(.type == "text")
| .text as $t
| select($t | test($pat; "i"))
| [$p[0], $m.message.toolName, ($t | gsub("\n"; " ") | .[0:180])] | @tsv
JQ

# ── report ────────────────────────────────────────────────────────────

echo
echo "=== 1) SESSIONS (chats) — agent | sessionKey | runs | first | last ==="
jq -s -r --arg s "$START" --arg e "$END" -f /tmp/oc_sessions.jq /tmp/oc_traj.jsonl
TOTAL_RUNS="$(jq -s -r --arg s "$START" --arg e "$END" \
  '[.[] | select(.type == "session.started" and .ts >= $s and .ts < $e)] | length' /tmp/oc_traj.jsonl)"
echo "(total session-runs: $TOTAL_RUNS)"

echo
echo "=== 2) MODEL USAGE + COST — agent | model | turns | input | cacheRead | cacheWrite | output | reasoning | est_cost$ | raw_cost$ ==="
jq -R -c --arg s "$START" --arg e "$END" -f /tmp/oc_usage.jq /tmp/oc_msgs.jsonl \
  > /tmp/oc_usage_rows.jsonl
jq -s -r \
  --argjson pin "$PRO_IN" --argjson pcr "$PRO_CR" --argjson pout "$PRO_OUT" \
  --argjson fin "$FLASH_IN" --argjson fcr "$FLASH_CR" --argjson fout "$FLASH_OUT" \
  -f /tmp/oc_usage_agg.jq /tmp/oc_usage_rows.jsonl

echo
echo "=== 3) TOOLS — count | agent | tool ==="
jq -R -r --arg s "$START" --arg e "$END" -f /tmp/oc_tools.jq /tmp/oc_msgs.jsonl \
  | sort | uniq -c | sort -rn

echo
echo "=== 4) ERRORS (toolResult) — agent | tool | snippet ==="
jq -R -r --arg s "$START" --arg e "$END" --arg pat "$ERR_PATTERN" -f /tmp/oc_errors.jq /tmp/oc_msgs.jsonl \
  | sort | uniq -c | sort -rn

echo
echo "raw data: /tmp/oc_traj.jsonl (trajectory) · /tmp/oc_msgs.jsonl (attributed messages)"

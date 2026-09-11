#!/bin/bash
# OpenClaw event-level analytics — windowed report of chats, tools, errors, model usage & cost.
#
# Reads the per-agent SQLite DBs (since the 2026-08-31 migration) via scripts/oc-sqlite.mjs,
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
# Raw normalized data is left in /tmp/oc_sqlite.jsonl (one JSON object per line, `kind` ∈
# session|usage|toolCall|toolResult) so you can re-query with your own jq.
# See docs/analytics.md for the schemas and caveats.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── window ────────────────────────────────────────────────────────────
END="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
START="${1:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"

# official DeepSeek off-peak $/1M (overridable via env)
PRO_IN="${PRO_IN:-0.66}";   PRO_CR="${PRO_CR:-0.022}";   PRO_OUT="${PRO_OUT:-1.98}"
FLASH_IN="${FLASH_IN:-0.22}"; FLASH_CR="${FLASH_CR:-0.007}"; FLASH_OUT="${FLASH_OUT:-0.66}"

echo "== OpenClaw analytics — $START → $END (UTC) =="

# ── pull normalized data from per-agent SQLite (read-only) ────────────
# Container-agnostic: Docker `openclaw` if running, else native node (see oc-sqlite-run.sh).
OC_START_UTC="$START" OC_END_UTC="$END" \
  "$SCRIPT_DIR/oc-sqlite-run.sh" > /tmp/oc_sqlite.jsonl

# ── report ────────────────────────────────────────────────────────────

echo
echo "=== 1) SESSIONS (chats) — agent | sessionKey | runs | first | last ==="
jq -s -r '
  [.[] | select(.kind == "session")]
  | group_by(.sessionKey)
  | map({agent: .[0].agent, sessionKey: .[0].sessionKey, runs: length,
         first: ((map(.startedAt)|min)/1000|floor|todateiso8601),
         last:  ((map(.startedAt)|max)/1000|floor|todateiso8601)})
  | sort_by(.first)[]
  | [.agent, .sessionKey, .runs, .first, .last] | @tsv
' /tmp/oc_sqlite.jsonl
TOTAL_RUNS="$(jq -s -r '[.[] | select(.kind == "session")] | length' /tmp/oc_sqlite.jsonl)"
echo "(total session-runs: $TOTAL_RUNS)"

echo
echo "=== 2) MODEL USAGE + COST — agent | model | turns | input | cacheRead | cacheWrite | output | reasoning | est_cost$ | raw_cost$ ==="
jq -s -r \
  --argjson pin "$PRO_IN" --argjson pcr "$PRO_CR" --argjson pout "$PRO_OUT" \
  --argjson fin "$FLASH_IN" --argjson fcr "$FLASH_CR" --argjson fout "$FLASH_OUT" \
  '
  [.[] | select(.kind == "usage")]
  | group_by([.agent, .model])
  | map({agent: .[0].agent, model: .[0].model, turns: length,
         input: (map(.input)|add), cacheRead: (map(.cacheRead)|add),
         cacheWrite: (map(.cacheWrite)|add), output: (map(.output)|add),
         reasoning: (map(.reasoning)|add), cost_raw: (map(.costTotal)|add)})
  | map(. + {flash: (.model | test("flash"; "i"))})
  | map(. + {est: ((if .flash
                    then (.input * $fin + .cacheRead * $fcr + .output * $fout)
                    else (.input * $pin + .cacheRead * $pcr + .output * $pout) end) / 1000000)})
  | sort_by(.agent, .model)[]
  | [.agent, .model, .turns, .input, .cacheRead, .cacheWrite, .output, .reasoning, .est, .cost_raw] | @tsv
  ' /tmp/oc_sqlite.jsonl

echo
echo "=== 3) TOOLS — count | agent | tool ==="
jq -sr '[.[] | select(.kind == "toolCall")] | .[] | [.agent, .name] | @tsv' /tmp/oc_sqlite.jsonl \
  | sort | uniq -c | sort -rn

# default error signature (override via ERR_PATTERN env)
ERR_PATTERN="${ERR_PATTERN:-(?i)error|failed|exception|traceback|command not found|permission denied|no such file|fatal|refused|exit code|denied|unauthorized|bad credentials}"

echo
echo "=== 4) ERRORS (toolResult) — agent | tool | snippet ==="
jq -sr --arg pat "$ERR_PATTERN" '
  [.[] | select(.kind == "toolResult" and (.text | test($pat; "i")))]
  | .[] | [.agent, .toolName, (.text | gsub("\n"; " ") | .[0:180])] | @tsv
' /tmp/oc_sqlite.jsonl \
  | sort | uniq -c | sort -rn

echo
echo "raw data: /tmp/oc_sqlite.jsonl (normalized session/usage/toolCall/toolResult JSONL)"

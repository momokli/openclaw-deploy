# Event-level analytics — `scripts/analytics.sh`

Windowed report of everything OpenClaw did in a time range: **chats, tools, errors,
model usage and cost**. Reads the live container state directly (no file copying), so it's
always current and repeatable — the source of truth is the runtime, not a cached export.

## Run

```sh
ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/analytics.sh [START_UTC] [END_UTC]'

# 22.08 15:00 → 23.08 03:00 Berlin (CEST = UTC+2):
./scripts/analytics.sh 2026-08-22T13:00:00Z 2026-08-23T01:00:00Z
```

- `START`/`END` are ISO-8601 **UTC**. Berlin = UTC+2 (summer) / UTC+1 (winter).
- No args → last 24 h.
- Raw extracted data is left in `/tmp/oc_traj.jsonl` (trajectory) and `/tmp/oc_msgs.jsonl`
  (attributed messages) so you can re-query with your own jq.

## What it reports

1. **Sessions** — `session.started` per `sessionKey` (agent, run count, first/last ts).
2. **Model usage + cost** — per agent+model: turns, input (cache-miss), cacheRead, cacheWrite,
   output, reasoning, `est_cost` (official off-peak prices) and `raw_cost` (OpenClaw's own `usage.cost`).
3. **Tools** — `toolCall` counts per agent+tool.
4. **Errors** — `toolResult` text matching an error signature (override via `ERR_PATTERN`).

## Data sources & schema

Two file kinds per session under `/home/node/.openclaw/agents/<agent>/sessions/`:

| file | content |
|---|---|
| `<id>.trajectory.jsonl` | structured events: `session.started`, `prompt.submitted`, `context.compiled`, `model.completed`, `session.ended`, `trace.*`. `model.completed.data.usage` is the **per-session aggregate**. The agent is `sessionKey.split(":")[1]`. |
| `<id>.jsonl` + `<id>.jsonl.reset.*` | `message` events, `role` ∈ `user`/`assistant`/`toolResult`. Assistant messages carry per-turn `message.usage` (with a `cost` breakdown) and `message.content[]` blocks (`thinking`, `toolCall`, `text`). |

Per-turn `usage` shape (assistant message):

```json
"usage": {
  "input": 15771, "output": 187, "cacheRead": 0, "cacheWrite": 0,
  "reasoningTokens": 105, "totalTokens": 15958,
  "cost": {"input": 0.0022, "output": 0.00005, "cacheRead": 0, "cacheWrite": 0, "total": 0.0023}
}
```

## Gotchas (important for correct analysis)

1. **`reasoning` is a SUBSET of `output`**, not billed on top of it. DeepSeek's
   `completion_tokens` includes reasoning. Verified against the live data:
   `total == input + cacheRead + output` and `output >= reasoning` for every call.
   The old `cost.html` formula `(output + reasoning) × price` **double-counts reasoning**.
2. **Include `*.jsonl.reset.*` snapshots.** `main`'s direct DM is one long-lived session that
   idle-resets every 120 min; the pre-reset turns live in `.reset.*` snapshots. Skipping them
   undercounts `main` ~3× (the original cause of a wrong cost number in early analysis).
3. **`delivery-mirror`** is a free echo/Telegram-delivery pseudo-model (0 tokens, 0 cost) — not an LLM call.
4. **Two cost numbers disagree.** `est_cost` uses the official off-peak DeepSeek prices
   (pro $0.66/$1.98 + cache $0.022; flash $0.22/$0.66 + cache $0.007 per 1M). `raw_cost` is
   OpenClaw's own `usage.cost` field, which implies much higher prices (e.g. pro cacheRead
   ≈ $0.145/M). The gap is almost entirely cache-read pricing — verify against the real
   DeepSeek bill before trusting either number.

## Extending / optimizing

The jq filters are embedded as heredocs in the script (written to `/tmp/oc_*.jq` each run).
To add a metric: extract from `/tmp/oc_msgs.jsonl` (`agent\tjson` lines) or `/tmp/oc_traj.jsonl`,
add a `cat > /tmp/oc_*.jq <<'JQ' … JQ` block, and a report section.

- Prices are env-overridable: `PRO_IN/CR/OUT`, `FLASH_IN/CR/OUT`.
- Error signature is env-overridable: `ERR_PATTERN`.

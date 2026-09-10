# Event-level analytics — `scripts/analytics.sh`

Windowed report of everything OpenClaw did in a time range: **chats, tools, errors,
model usage and cost**. Reads the live per-agent SQLite DBs directly (no file copying), so it's
always current and repeatable — the source of truth is the runtime, not a cached export.

## Run

```sh
ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/analytics.sh [START_UTC] [END_UTC]'

# 22.08 15:00 → 23.08 03:00 Berlin (CEST = UTC+2):
./scripts/analytics.sh 2026-08-22T13:00:00Z 2026-08-23T01:00:00Z
```

- `START`/`END` are ISO-8601 **UTC**. Berlin = UTC+2 (summer) / UTC+1 (winter).
- No args → last 24 h.
- Raw normalized data is left in `/tmp/oc_sqlite.jsonl` (one JSON object per line, `kind` ∈
  `session` | `usage` | `toolCall` | `toolResult`) so you can re-query with your own jq.

## What it reports

1. **Sessions** — per `sessionKey`: agent, run count (`session_windows` started in the window),
   first/last start time.
2. **Model usage + cost** — per agent+model: turns, input (cache-miss), cacheRead, cacheWrite,
   output, reasoning, `est_cost` (official off-peak prices) and `raw_cost` (OpenClaw's own `usage.cost`).
3. **Tools** — `toolCall` counts per agent+tool.
4. **Errors** — `toolResult` text matching an error signature (override via `ERR_PATTERN`).

## Data sources & schema

Since the SQLite migration (2026-08-31) the old
`/home/node/.openclaw/agents/<agent>/sessions/*.jsonl` files no longer exist. Extraction is done
by `scripts/oc-sqlite.mjs` (Node 24, `node:sqlite`, no `sqlite3` CLI needed), which reads the
per-agent DBs at `/home/node/.openclaw/agents/<agent>/agent/openclaw-agent.sqlite`:

| table                       | content                                                                                                                                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `session_windows`           | one row per session "run" (idle-reset chain via `previous_session_id`). `session_key` → `session_id(s)`, `started_at`/`ended_at` (**epoch ms**, nullable), `model`, `status`, `display_name`.                                                          |
| `session_nodes`             | session metadata: `session_key`, `label`, `display_name`, `status`, `parent_session_key`, `current_session_id`.                                                                                                                                        |
| `transcript_events`         | `session_id`, `seq`, `event_json` — the `message` events. Assistant messages carry `message.usage` and `message.content[]` blocks (`thinking`, `toolCall`, `text`). `toolResult` messages carry `message.toolName` and text content.                   |
| `trajectory_runtime_events` | `session.started` / `model.completed` etc. (`ts`, `sessionKey`, `usage`). `model.completed.data.usage` is the per-run aggregate but has **no** cost/reasoning/cacheWrite — the helper therefore reads per-call usage from `transcript_events` instead. |

Per-call `usage` shape (assistant message in `transcript_events.event_json`):

```json
"usage": {
  "input": 15771, "output": 187, "cacheRead": 0, "cacheWrite": 0,
  "reasoningTokens": 105, "totalTokens": 15958,
  "cost": {"input": 0.0022, "output": 0.00005, "cacheRead": 0, "cacheWrite": 0, "total": 0.0023}
}
```

The helper normalizes this into `reasoning` and flat `costInput`/`costCacheRead`/`costOutput`/
`costCacheWrite`/`costTotal` fields (see the header comment in `scripts/oc-sqlite.mjs` for the
full JSONL contract).

## Window semantics

- `session` rows use `session_windows.started_at ∈ [START, END)`.
- `usage`/`toolCall`/`toolResult` rows come from sessions whose window **overlaps** the requested
  range, further filtered by the event's own timestamp ∈ `[START, END)`. This attributes a
  long-lived session to the correct UTC day instead of the day it started.

## Gotchas (important for correct analysis)

1. **`reasoning` is a SUBSET of `output`**, not billed on top of it. DeepSeek's
   `completion_tokens` includes reasoning. Verified against the live data:
   `total == input + cacheRead + output` and `output >= reasoning` for every call.
   The old `cost.html` formula `(output + reasoning) × price` **double-counts reasoning**
   (fixed in `scripts/cost-dashboard.sh`).
2. **Idle-resets are now first-class.** The old `.jsonl.reset.*` snapshot handling is obsolete:
   every idle-reset is a separate `session_windows` row linked via `previous_session_id`, and its
   turns live in `transcript_events` under that `session_id`. No special casing required.
3. **`delivery-mirror`** is a free echo/Telegram-delivery pseudo-model (0 tokens, 0 cost) — not an LLM call.
4. **Two cost numbers disagree.** `est_cost` uses the official off-peak DeepSeek prices
   (pro $0.66/$1.98 + cache $0.022; flash $0.22/$0.66 + cache $0.007 per 1M). `raw_cost` is
   OpenClaw's own `usage.cost` field, which implies much higher prices (e.g. pro cacheRead
   ≈ $0.145/M). The gap is almost entirely cache-read pricing — verify against the real
   DeepSeek bill before trusting either number. They are kept separate and never mixed.

## Extending / optimizing

To add a metric: extend `scripts/oc-sqlite.mjs` (emit another normalized `kind`), then add a jq
aggregation in `scripts/analytics.sh` over `/tmp/oc_sqlite.jsonl`.

- Prices are env-overridable: `PRO_IN/CR/OUT`, `FLASH_IN/CR/OUT`.
- Error signature is env-overridable: `ERR_PATTERN`.
- The helper constrains `transcript_events` scans to sessions overlapping the window
  (via a join on `session_windows`) to keep large multi-agent scans cheap.

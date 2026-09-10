#!/usr/bin/env node
// oc-sqlite.mjs — read per-agent OpenClaw SQLite DBs, emit normalized JSONL for a UTC window.
//
// Replaces the pre-SQLite-migration extraction from
//   /home/node/.openclaw/agents/<agent>/sessions/*.jsonl (and *.trajectory.jsonl).
// Since 2026-08-31 the sessions/usage live in per-agent SQLite DBs:
//   /home/node/.openclaw/agents/<agent>/agent/openclaw-agent.sqlite
//
// Input (env, optional):
//   OC_START_UTC  ISO-8601 UTC start of the window (default: now - 24h)
//   OC_END_UTC    ISO-8601 UTC end of the window   (default: now)
//   OC_AGENTS_DIR base dir of per-agent DBs        (default: /home/node/.openclaw/agents)
//
// Output (stdout): one JSON object per line (JSONL), `kind` ∈ session|usage|toolCall|toolResult.
//   session    {kind, agent, sessionKey, sessionId, previousSessionId, startedAt, endedAt,
//                model, modelProvider, displayName, status, chatType}          (startedAt/endedAt = epoch ms)
//   usage      {kind, agent, sessionId, sessionKey, ts, model, input, cacheRead, cacheWrite,
//                output, reasoning, totalTokens, costInput, costCacheRead, costOutput,
//                costCacheWrite, costTotal}                                    (ts = epoch ms)
//   toolCall   {kind, agent, sessionId, sessionKey, ts, name}
//   toolResult {kind, agent, sessionId, sessionKey, ts, toolName, isError, text}
//
// Window semantics:
//   - `session` rows use session_windows.started_at in [START, END).
//   - `usage`/`toolCall`/`toolResult` rows come from the transcript events of sessions that
//     OVERLAP the window, further filtered by the event's own timestamp in [START, END),
//     so a long-lived session is attributed to the correct UTC day.
//
// Invariants (do NOT violate — see docs/analytics.md):
//   - `reasoning` is a SUBSET of `output`; it is emitted separately and never summed onto output.
//   - total == input + cacheRead + output.
//   - `usage.cost` is the authoritative runtime cost (raw); official off-peak `est_cost` is
//     computed separately by the shell scripts and must not be mixed with it.

import { DatabaseSync } from 'node:sqlite';
import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';

const AGENTS_DIR = process.env.OC_AGENTS_DIR || '/home/node/.openclaw/agents';

function toMs(s) {
  if (s == null || s === '') return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

const now = Date.now();
const START = toMs(process.env.OC_START_UTC) ?? (now - 24 * 60 * 60 * 1000);
const END = toMs(process.env.OC_END_UTC) ?? now;

if (START >= END) {
  process.stderr.write('oc-sqlite: OC_START_UTC must be < OC_END_UTC\n');
  process.exit(2);
}

function agentDbs() {
  if (!existsSync(AGENTS_DIR)) return [];
  const out = [];
  for (const name of readdirSync(AGENTS_DIR)) {
    const dbPath = path.join(AGENTS_DIR, name, 'agent', 'openclaw-agent.sqlite');
    if (existsSync(dbPath)) out.push({ agent: name, dbPath });
  }
  return out;
}

// Prefer the top-level ISO timestamp (matches the old .jsonl event timestamp used by the
// pre-migration scripts); fall back to the nested epoch-ms message timestamp if absent.
function msgTs(ev) {
  if (typeof ev.timestamp === 'string') {
    const t = Date.parse(ev.timestamp);
    if (!Number.isNaN(t)) return t;
  }
  const m = ev.message;
  if (m && typeof m.timestamp === 'number' && Number.isFinite(m.timestamp)) return m.timestamp;
  return null;
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

for (const { agent, dbPath } of agentDbs()) {
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
  } catch (e) {
    process.stderr.write(`oc-sqlite: skip ${agent}: ${e.message}\n`);
    continue;
  }

  try {
    // 1) Sessions started within the window.
    const sessRows = db.prepare(
      `SELECT session_key, session_id, previous_session_id, started_at, ended_at,
              status, model, model_provider, display_name, chat_type
         FROM session_windows
        WHERE started_at >= ? AND started_at < ?
        ORDER BY started_at`
    ).all(START, END);

    for (const r of sessRows) {
      emit({
        kind: 'session',
        agent,
        sessionKey: r.session_key,
        sessionId: r.session_id,
        previousSessionId: r.previous_session_id,
        startedAt: r.started_at,
        endedAt: r.ended_at,
        model: r.model ?? '?',
        modelProvider: r.model_provider ?? '?',
        displayName: r.display_name ?? null,
        status: r.status ?? null,
        chatType: r.chat_type ?? null,
      });
    }

    // 2) Transcript events of sessions that overlap the window (constrained scan).
    const evRows = db.prepare(
      `SELECT t.session_id, w.session_key, t.event_json
         FROM transcript_events t
         JOIN session_windows w ON w.session_id = t.session_id
        WHERE w.started_at < ? AND (w.ended_at IS NULL OR w.ended_at >= ?)`
    ).all(END, START);

    for (const r of evRows) {
      let ev;
      try {
        ev = JSON.parse(r.event_json);
      } catch {
        continue;
      }
      if (ev == null || ev.type !== 'message') continue;

      const ts = msgTs(ev);
      if (ts == null || ts < START || ts >= END) continue;

      const m = ev.message;
      if (m == null) continue;

      if (m.role === 'assistant') {
        const u = m.usage ?? {};
        const c = u.cost ?? {};
        emit({
          kind: 'usage',
          agent,
          sessionId: r.session_id,
          sessionKey: r.session_key,
          ts,
          model: m.model ?? '?',
          input: num(u.input),
          cacheRead: num(u.cacheRead),
          cacheWrite: num(u.cacheWrite),
          output: num(u.output),
          reasoning: num(u.reasoningTokens),
          totalTokens: num(u.totalTokens),
          costInput: num(c.input),
          costCacheRead: num(c.cacheRead),
          costOutput: num(c.output),
          costCacheWrite: num(c.cacheWrite),
          costTotal: num(c.total),
        });
      }

      const content = m.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        if (block == null) continue;
        if (block.type === 'toolCall') {
          emit({
            kind: 'toolCall',
            agent,
            sessionId: r.session_id,
            sessionKey: r.session_key,
            ts,
            name: block.name ?? '?',
          });
        } else if (m.role === 'toolResult' && block.type === 'text') {
          emit({
            kind: 'toolResult',
            agent,
            sessionId: r.session_id,
            sessionKey: r.session_key,
            ts,
            toolName: m.toolName ?? '?',
            isError: !!m.isError,
            text: String(block.text ?? ''),
          });
        }
      }
    }
  } finally {
    db.close();
  }
}

# Announce-Hygiene: Reports cappen + Duplikate deduplizieren

> Kontext: Issue [#27](https://github.com/momokli/openclaw-deploy/issues/27)
> („Subagent-Announcements: lange Berichte werden abgeschnitten und mehrfach zugestellt").
> Verwandt: [`equip-agents.md`](equip-agents.md) (A5), Issue #28 (Completion-Delivery blockt).
> Stand: 2026-09-12, verifiziert gegen OpenClaw `2026.8.1`.

## Symptom

In der `main`-Session kamen Subagent-/Orchestrator-Reports als
`[child result truncated]` an — der Text war **mitten im Satz** abgeschnitten, der Rest
nur per `sessions_history` nachladbar. Zusätzlich kam ein identischer Report **3×** als
Inter-Session-Message an. Beides kostet den Parent Extra-Turns/-Tokens.

## Root Cause (OpenClaw-Code)

Kein Timeout: die Runtime **kappt Announce-Texte hart**. Im Bundle
`dist/worker/worker.mjs` (OpenClaw `2026.8.1`) gibt es drei unabhängige Caps, alle mit
demselben Marker `\n[child result truncated]`:

| Konstante | Wert (Zeichen) | Modul | Wirkung |
|---|---|---|---|
| `MAX_TASK_COMPLETION_RESULT_ESCAPED_CHARS` | 6000 | `internal_events` | Resultat eines `task_completion`-Events (der Report im Announce-Prompt) |
| `MAX_RESULT_CHARS_PER_ITEM` | 6000 | `agent_steering_queue` | Steering-/Announce-Prompt-Item |
| `MAX_CHILD_COMPLETION_RESULT_CHARS` | 512 | `subagent_announce_output` | Child-Completion-Findings (descendant wake) |

Es gibt **keinen Env-/Config-Override** für diese Längen. Konfigurierbar ist nur das
Delivery-Timeout (`agents.defaults.subagents.announceTimeoutMs`), nicht die Textlänge.

Duplikate: Für den Direct-Delivery-Pfad existiert
`buildAnnounceIdempotencyKey(childSessionKey, childRunId)`; der Steer-Fallback und
Delivery-Retries können dasselbe Event dennoch mehrfach anstoßen. Ein Fix auf
Runtime-Ebene ist upstream — hier mitigieren wir **am Sender**.

## Fix (dieses Repo)

`scripts/announce-guard.sh` macht einen Report vor dem Absenden announce-sicher:

- **Cap:** kappt auf `--max-chars` (Default **1500**, Env `ANNOUNCE_MAX_CHARS`) und legt
  den vollen Text als Detail-Datei ab. Die gekappte Ausgabe endet mit
  `…[announce capped at N chars — full report: <pfad>]`.
- **Dedupe:** sha256 des **vollen** Reports (cap-unabhängig); derselbe Report innerhalb
  `--ttl` (Default 3600 s) wird nicht erneut ausgegeben → **Exit 10** (keine Ausgabe).
- UTF-8-sicher (Char-Grenzen, kein halbes Multibyte-Zeichen); leerer Report → Exit 0.

Die Detail-Datei ist der Ort für den vollen Bericht; ist er PR-/Issue-relevant, wird sie
als PR-/Issue-**Comment** angehängt statt in die Announce kopiert.

```sh
# Report aus Datei, gekappt + dedupliziert nach stdout:
scripts/announce-guard.sh report.md

# Details in ein Verzeichnis, eigenes Dedupe-Fenster:
scripts/announce-guard.sh --detail-dir ./out --ttl 600 report.md

# 0 = nie ablaufen, --no-dedupe / --no-cap zum Abschalten:
scripts/announce-guard.sh --ttl 0 report.md
```

Exit-Code | Bedeutung
---|---
`0` | Announce erzeugt (stdout)
`10` | Duplikat innerhalb TTL (keine Ausgabe)
`2` | Usage-/IO-Fehler

## Reporting-Contract (Personas)

Damit der Runtime-Cap nie greift, gilt für Abschluss-Reports von Sub-Agents/Orchestratoren:

- Kurzreport ≤ 1500 Zeichen; **Details** (Diffs, Logs, Listen, Messwerte) in eine Datei
  (`progress-<branch>.md`, `docs/…`) oder als PR-/Issue-Comment.
- Vor dem Absenden: `scripts/announce-guard.sh <report>` — Cap + Dedupe in einem Schritt.
- Auf Duplikate (Exit 10) nicht erneut reporten; ein NO_REPLY/Stille ist korrekt.
- Verankert in `config/agents/orchestrator.md` und `workspace/AGENTS.md`.

## Verifikation

```sh
bash tests/announce-guard/run.sh          # 23 Fälle grün (Exit 0)
bash tests/announce-guard/run.sh --red    # red-before-green: naives `cat` fällt bei Cap+Dedupe durch
```

Offline-Harness, kein Netz: Cap (Zeichengrenze, Marker, Detail-Datei vollständig,
UTF-8-Grenze), Dedupe (Hash, TTL, `--no-dedupe`), Exit-Codes, stdin/Datei, Fehlerfälle.

## Rollback

Rein additiv (neues Script + Tests + Doku + je eine Prompt-Regel). Kein Prod-Pfad
(natives Gateway: `config/openclaw.json` / `scripts/converge-openclaw-config.sh`) berührt →
`git revert <sha>` genügt.

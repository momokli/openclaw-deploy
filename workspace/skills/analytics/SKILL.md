---
name: analytics
description: "OpenClaw-Nutzungs- und Kosten-Report für ein Zeitfenster erstellen (Sessions, Tools, Errors, Model-Usage)."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["ssh"] },
      },
  }
---

# Analytics (OpenClaw)

Use für Event-Level-Reports aus dem Live-Container auf `.149`: Chats, Tools, Errors,
Model-Usage + Kosten. Liest den Runtime-State direkt (kein Datei-Kopieren).

## Aufruf

Läuft auf `.149` (Repo-Root `/opt/apps/openclaw`), von außen via Tailscale:

```bash
ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/analytics.sh [START_UTC] [END_UTC]'

# Beispiel: 22.08 15:00 → 23.08 03:00 Berlin (CEST = UTC+2):
./scripts/analytics.sh 2026-08-22T13:00:00Z 2026-08-23T01:00:00Z
```

- `START`/`END` ISO-8601 **UTC**. Berlin = UTC+2 (Sommer) / UTC+1 (Winter).
- Ohne Args = letzte 24 h.
- Raw-Data bleibt in `/tmp/oc_traj.jsonl` (Trajectory) + `/tmp/oc_msgs.jsonl` (Messages) für eigene `jq`-Queries.

## Kern-Gotchas

1. **`reasoning` ist Teilmenge von `output`** (DeepSeek `completion_tokens` enthält reasoning) →
   NIE `output` + `reasoning` addieren. Verified: `total == input + cacheRead + output` und
   `output >= reasoning`.
2. **`*.jsonl.reset.*`-Snapshots mit einbeziehen** — sonst wird `main` (long-lived DM,
   idle-reset alle 120 min) ~3× unterzählt.
3. **Zwei Kosten-Zahlen, die sich widersprechen:** `est_cost` nutzt offizielle
   DeepSeek-off-peak-Preise; `raw_cost` ist OpenClaws `usage.cost` (impliziert höhere Preise,
   Gap fast komplett cache-read). Gegen echte DeepSeek-Rechnung prüfen.
4. Preise (off-peak, $/1M; peak = 2×, peak-Stunden 01:00–04:00 & 06:00–10:00 UTC):
   - Flash: in `0.22` / cacheRead `0.007` / out `0.66`
   - Pro:   in `0.66` / cacheRead `0.022` / out `1.98`
   - Env-Override: `FLASH_IN/CR/OUT`, `PRO_IN/CR/OUT`.

## Stop-Regel

`est_cost` ≠ `raw_cost` (oder beides ≠ echter DeepSeek-Rechnung) → NICHT Preise/Formel anpassen
oder `output+reasoning` addieren. Stattdessen Raw-Files (`/tmp/oc_traj.jsonl`, `/tmp/oc_msgs.jsonl`)
per `jq` prüfen — insb. ob `*.jsonl.reset.*` enthalten sind und ob `reasoning <= output`.
Leere/verdächtige Ausgabe → erst prüfen, ob `.149`/Container läuft; unklar → Momo fragen.

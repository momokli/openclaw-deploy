---
name: cost-tracking
description: "DeepSeek-Kosten & -Verbrauch abfragen: Balance, Tokens/Tag, Flash-vs-Pro-Split (cost-report.sh) und das cost-Dashboard (cost-dashboard.sh)."
metadata: { "openclaw": { "requires": { "bins": ["ssh"] } } }
---

# Cost Tracking (DeepSeek)

Use für den Schnell-Check von Balance, Token-Verbrauch pro Tag, Flash/Pro-Split und
Kostenschätzung — täglicher Trend statt Event-Level (dafür `analytics`-Skill nutzen).

## Aufruf

Läuft auf `.149` (Repo-Root `/opt/apps/openclaw`), von außen via Tailscale:

```bash
ssh momo@lan 'cd /opt/apps/openclaw && ./scripts/cost-report.sh'
```

Direkt auf `.149`:

```bash
cd /opt/apps/openclaw
./scripts/cost-report.sh        # Balance + Tokens/Tag + Modell-Split
```

Nur Balance manuell:

```bash
docker compose exec -T -u node openclaw openclaw status --usage
```

`cost-report.sh` liefert drei Sektionen: (1) `DeepSeek Balance`, (2)
`Tokens per day (UTC) — calls | input-miss | cacheRead | output | reasoning`, (3)
`Model split (alle Calls)` (`modelId` → Anzahl). Liest die Runtime-Trajectories direkt
(`/home/node/.openclaw/agents/*/sessions/*.trajectory.jsonl`), kein Datei-Kopieren.

## Dashboard + Snapshot

- **URL:** `https://cost.openclaw.simonklimke.de` (hinter Pocket-ID-SSO).
- `scripts/cost-dashboard.sh` generiert `/srv/cost/index.html` aus
  `/opt/apps/openclaw/cost-history.json` (auf `.149`, gitignored). Fehlt die Datei →
  `cost-snapshot.sh` zuerst ausführen.
- `scripts/cost-snapshot.sh` hängt den heutigen Tag an `cost-history.json` an; **idempotent**
  (upsert nach `date`, mehrfach am selben Tag überschreibt denselben Eintrag).
- Automatisierung: `openclaw-cost.timer` (daily) → `cost-snapshot.sh` (ExecStart) +
  `cost-dashboard.sh` (ExecStartPost). Historie-Seed: `cost-seed.sh` (rebuildet alles).
- Modell-Split-Zählung: `contains("pro")` → pro, `contains("flash")` → flash.

## Wichtigste Gotchas (erst lesen)

1. **Preise off-peak = halber Preis.** Peak-Stunden: `01:00–04:00` & `06:00–10:00` UTC
   (= 2× off-peak). Off-peak, $/1M:
   - Flash: in `0.22` / cacheRead `0.007` / out `0.66`
   - Pro: in `0.66` / cacheRead `0.022` / out `1.98`
2. **Cache-Hit ≈ 30× günstiger** als Cache-Miss ($0.007 Flash / $0.022 Pro vs. $0.22/$0.66).
   Cache-Hit-Rate hoch halten ist der größte Kostenhebel. **Pro = 3× Flash.**
3. **Flash-vs-Pro-Routing:** `main` → Flash (default), `coding-orchestrator` → Pro,
   `feature-dev-*` → Flash + `low`; `subagents.model` + `utilityModel` + `compaction.model`
   → Flash. Ein hoher Pro-Anteil im Split deutet auf ungenutztes Flash-Routing / Coding
   direkt über `main`.
4. **Zwei Kosten-Zahlen, die sich widersprechen:** `est. cost` (Dashboard) nutzt offizielle
   DeepSeek-off-peak-Preise; OpenClaws eigenes `usage.cost` (`raw_cost` in `analytics.sh`)
   liegt höher (Gap fast komplett cache-read). Gegen die echte DeepSeek-Rechnung prüfen.
5. **`reasoning` ist Teilmenge von `output`** (DeepSeek `completion_tokens` enthält reasoning) →
   NIE `output + reasoning` summieren. `analytics.sh` rechnet das korrekt; die
   Dashboard-`est. cost`-Formel addiert `output + reasoning` (bewusst "konservativ" =
   leicht überschätzt).
6. **Wirkung kommt zeitversetzt:** `session.reset`/`pruning`/`subagents.model` greifen erst bei
   **neuen** Sessions. Trend über **≥5 Tage** bewerten, nicht nach einem Tag.

## Stop-Regel

Leere/verdächtige Ausgabe, `est. cost` ≠ `raw_cost`, oder `cost-history.json` fehlt →
**nicht** Preise/Formeln anpassen oder Befehle variieren. Erst prüfen, ob `.149`/Container
läuft (`docker compose ps`), dann ob `cost-snapshot.sh` gelaufen ist; unklar → Momo fragen.

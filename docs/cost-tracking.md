# Kosten-Tracking — P1 messen

Stand: 2026-08-22. Ziel: DeepSeek-Verbrauch objektiv messen, damit wir den Effekt der
P1-Änderungen (Routing, Thinking, Kontext-Hygiene) sauber bewerten können.

## Baseline (vor P1-Wirkung, gemessen 2026-08-22)

- **DeepSeek-Balance:** $9.89 (Rest).
- **Burn:** ~$4–7/Tag. 8-21 ≈ $6.5–8 (33 Calls), 8-18 war der Spitzen-Tag (74 Calls, 223M Cache-Read).
- **Modell:** 100% `deepseek-v4-pro`, **0% Flash** (das Flash-Routing griff nicht, weil `feature-dev-*` ungenutzt war).
- **Treiber (aus 290 Transcript-Calls aggregiert):**
  - Cache-Read 455M · Cache-Miss 24.6M · Output 3.4M · Reasoning 2.56M Tokens.
  - `main` (direct DM + eigene Sub-Agents) war der Hauptverbraucher; Thinking lief auf `high`.

## P1-Änderungen (deployed 2026-08-22)

- `session.reset` (idle 120min) + `session.maintenance` — Kontext wächst nicht ungebremst.
- `contextPruning: cache-ttl` — alte Tool-Results trimmen.
- `utilityModel` + `subagents.model` → `deepseek-v4-flash`.
- `main` + `coding-orchestrator` → `thinkingDefault: low`; `feature-dev-*` → Flash + low.

## Messmethode

Auf `.149`:

```sh
cd /opt/apps/openclaw
./scripts/cost-report.sh        # Balance + Tokens/Tag + Modell-Split
```

Oder manuell:

```sh
docker compose exec -T -u node openclaw openclaw status --usage   # Balance
```

## Dashboard (live)

- **URL:** https://cost.openclaw.simonklimke.de (hinter Pocket-ID-SSO).
- Generiert von `openclaw-cost.timer` → `/srv/cost/index.html`.
- SSO: `oauth2-proxy-cost` (lokal `/home/momo/oauth2-proxy-cost/docker-compose.yml`, NICHT in git — enthält Client-Secret) → Pocket ID (`auth.klimk.es`).
- OIDC-Client in Pocket ID: `openclaw-cost`, Callback `https://cost.openclaw.simonklimke.de/oauth2/callback`.

## Was tracken (Woche 1 nach P1)

| Metrik                 | Erwartung                 | Wie                                 |
| ---------------------- | ------------------------- | ----------------------------------- |
| Balance-Delta/Tag      | von ~$5–7 → Richtung $1–2 | `status --usage` täglich            |
| **Flash-vs-Pro-Ratio** | von 0% Flash → >50%       | `cost-report.sh` (Modell-Split)     |
| Cache-Hit-Rate         | bleibt hoch (>90%)        | Session-Liste (`🗄️ % cached`)       |
| Reasoning-Tokens       | sinken (thinking low)     | `cost-report.sh` (reasoning-Spalte) |
| Cache-Read/Tag         | sinkt (session reset)     | `cost-report.sh` (cacheRead-Spalte) |

**Ziel:** $20–40/Monat ≈ **$0.7–1.3/Tag**.

## Wichtig: Wirkung kommt zeitversetzt

`session.reset`/`pruning`/`subagents.model` wirken erst auf **neue** Sessions. Die alten
Sessions mit aufgeblähtem Kontext laufen aus. Deshalb den Trend über **≥5 Tage** bewerten,
nicht nach einem Tag.

## Offene Hebel (Phase 2, falls P1 nicht reicht)

- `models.providers.deepseek.models[].cost` → `/usage cost`-$-Schätzung (Schema erst prüfen).
- Free/Cheap-Fallback (Gemini Flash-Lite, `GEMINI_API_KEY` vorhanden).
- ggf. LiteLLM mit hartem Monats-Budget, oder iblai-Scorer für `main`'s einfache Turns.

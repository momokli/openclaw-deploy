# System-Optimierung — Ernte 2026-09-11

Stand: 2026-09-11 · Source-of-Truth: dieses Repo.

Dieser Ordner sammelt das **live geerntete Wissen** aus der Session vom 11.09. —
Hardware-/Storage-Bestand beider Hosts, die gefundenen Incidents und die daraus
abgeleiteten Optimierungs-Empfehlungen. Zweck: belastbare Grundlage für die
anstehende System-Optimierung („Heavy-Lifting auf `planet`“, Storage, Cleanup).

## Dateien

| Datei | Inhalt |
|---|---|
| [`hosts-inventory.md`](hosts-inventory.md) | Live-Messung `.149` + `planet`: CPU/RAM/Disk/Load, Docker-Nutzung, Storage-Breakdown |
| [`incidents.md`](incidents.md) | 4 gefundene Probleme (Root Cause + Fix + Status) |
| [`storage-analysis.md`](storage-analysis.md) | Wo der Speicher hingeht, was reclaimable ist, rclone-VFS-Cache, Rust-Cache-Befund |
| [`recommendations.md`](recommendations.md) | Optimierungsplan: Heavy-Lifting → `planet`, Storage-Entscheidung, Cleanup, Delivery-Fix |

## Executive Summary

1. **`planet` = `projectmellon.de`** — dieselbe Hetzner-Kiste, die heute schon den
   OpenClaw-Image-Build (GH-Actions-Runner), den `riftbreaker-battle-mod`-Runner und
   AzerothCore-WoW-Compiles fährt. Heavy-Lifting passiert dort **bereits**.
2. **`.149` ist der falsche Ort für schwere Builds.** Live-Beweis: der `mmm-loop` ließ
   `cargo test` auf `momos_music_manager` (Rust + candle/tokenizers/sqlx) **im Container
   auf `.149`** laufen → Load 55–60 auf 16 Cores, Gateway „unhealthy“, Seite ~14 s →
   „nicht erreichbar“. Siehe [`incidents.md`](incidents.md).
3. **Storage-Engpass ist auf `planet`, aber größtenteils reclaimable.** Root 89 % voll,
   aber ~130 G allein aus Docker-Cleanup (48 G Build-Cache + 84 G alte `openclaw-deploy`-Images)
   holbar. **Kein SATA-SSD-Kauf nötig.**
4. **Rust-Cache ist vernachlässigbar (~4 G).** Die dicken Brocken sind Media
   (rclone-VFS-Cache 849 G + `cold:` 48 T), Docker-Images/-Build-Cache und Game-Server-Daten.
5. **`mmm-loop`-Delivery ist gebrochen** (`announce → last`, Telegram disabled in PR #59) —
   Loop läuft, pusht aber nicht. Fix: Delivery auf `none` bzw. gültiges Ziel repointen.

## Verwandte (bereits vorhandene) Docs

- [`docs/dev-loops-planet.md`](../dev-loops-planet.md) — detaillierter Plan „Compute von
  `.149` auf `planet` auslagern“ (Option A = Session-Host-Node). Die Zahlen dort (Stand
  10.09.) werden hier durch die Live-Messung vom 11.09. aktualisiert.
- [`docs/automations.md`](../automations.md) — Automation-Inventar + Kosten-Treiber.
- [`docs/equip-agents.md`](../equip-agents.md) — A10 (`.149`-Last), Delivery-Gotchas.

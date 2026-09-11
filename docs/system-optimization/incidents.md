# Incidents & Befunde (2026-09-11)

Stand: 2026-09-11 · Source-of-Truth: dieses Repo.

Vier konkrete Probleme wurden in der Session gefunden und diagnostiziert.

---

## 1. `notify.sh` (Necesse) — Busy-Loop auf totem Container ✅ gefixt

**Symptom:** Host-Load dauerhaft erhöht; `notify.sh` + `docker logs -f` bei ~1,3 Cores.

**Root Cause:**
- `necesse-notify.service` (systemd, `Restart=always`, `enabled`) führt
  `/srv/necesse-server-docker/notify.sh` aus → `docker logs -f necesse_server | while read …`.
- Der Game-Server-Container `necesse_server` ist aber **seit 4 Wochen tot** (Exit 137).
- Das Skript tailt Logs eines toten Containers in einer Busy-Loop (~1,3 Cores) und
  spammt `container … is not running` in den Journal.

**Fix (ausgeführt 11.09.):**
1. `systemctl stop` + `disable necesse-notify.service`
2. Unit `/etc/systemd/system/necesse-notify.service` gelöscht + `daemon-reload`
3. `notify.sh` gelöscht
4. Container `necesse_server` entfernt
5. Image `karyeet/necesse-server-docker:latest` entfernt (~575 MB frei)

**Nicht angerührt:** `/srv/necesse-server-docker/` (enthält `saves/` = World-Daten).

**Einordnung:** War **nicht** der Haupt-Treiber der Load — nur ~1,3 Cores (~8 %). Siehe #2/#3.

---

## 2. Load-Spike (~14) — Stash-Metadata + rsync-flacs

**Symptom:** Load-Average 1/5/15 min ≈ 3/11/14, klingt danach auf ~2 ab.

**Root Cause (wahrscheinlich):**
- `stash-generate.service` („Generate Stash metadata: sprites/previews/phashes when idle“)
  triggert ffmpeg-basiertes Sprites/Previews/Phash-Generieren im `stash`-Container.
  Lief 09:30:36 und 10:00:42. Das ist der klassische Burst, der alle Cores kurz sättigt.
- `rsync-flacs.timer` → `rsync-flacs.service` läuft **alle ~60 s** dauerhaft
  („Rsync FLACs to the backup server“).

**Einordnung:** Transient, war zum Messzeitpunkt schon abgeklungen. Kein sysstat/sar
historisch aktiv (leer seit 2024) → exakter Nachweis nur per Live-Beobachtung möglich.
**Empfehlung:** sysstat/Prometheus-Historie aktivieren, um die nächste Spitze zu fangen.

---

## 3. „Seite nicht erreichbar“ — `cargo test` (mmm-loop) sättigt `.149` 🔴 wichtigster Befund

**Symptom:** `openclaw.simonklimke.de` nicht erreichbar, obwohl der Host „ruhig“ wirkt.
`openclaw`-Container `Up … (unhealthy)`, öffentliches `healthz` braucht ~14 s.

**Messwerte:** Load **55.63 / 60.40 / 33.30** (16 Cores!), Container-CPU **196 %**,
RAM 11.7/16 GiB, `rust-lld` in State `D` (Disk-I/O).

**Root Cause:**
```
1522432  openclaw-gateway
 └─ sh -c cd /tmp/mmm-issue27 && cargo test 2>&1 | tail -120
     └─ cargo test  (toolchain 1.98.0)
         └─ rustc --crate-name momos_music_manager … (candle_core/nn/transformers, tokenizers, sqlx, axum …)
```
Der OpenClaw-Agent (`mmm-loop`/Task) lässt **`cargo test` auf `momos_music_manager`**
(ein Rust-Projekt mit ML-Deps: candle, tokenizers, sqlx) **im Container auf `.149`** laufen.
Der Build sättigt den alten 16-Core-Xeon + Disk-I/O → Gateway-Healthcheck schlägt fehl,
öffentlicher Endpoint timeoutet.

**Fix (Sofort):** Build killen (z. B. `docker exec openclaw pkill -9 -f "cargo test"`).

**Konsequenz:** Das ist der **Live-Beweis**, dass schwere Builds **nicht auf `.149`**
laufen dürfen. Konkretes Argument für „Heavy-Lifting → `planet`“ (siehe
[`recommendations.md`](recommendations.md) + [`dev-loops-planet.md`](../dev-loops-planet.md)).

---

## 4. `mmm-loop` — Delivery „announce → last“ hat keine Route

**Symptom:** `mmm-loop:main` (`6c979f8d…`, every 30m) Status `ok (not delivered)`.
Delivery `announce -> last (last -> no route, will fail-closed: Channel…)`.

**Root Cause:**
- `last` = „letzte Route der Session“ → zeigt auf Telegram.
- Telegram ist seit **PR #59** (`channels.telegram.enabled: false`) disabled.
- → Announcement kann nicht zugestellt werden (fail-closed). Der Loop **läuft trotzdem**;
  Ergebnisse landen in der Session-History, werden aber nicht gepusht.

**Live-Inventar (11.09., via `openclaw automations list`):**

| Name | Schedule | Delivery | Status |
|---|---|---|---|
| `ci-cd-fix-loop:main` | every 15m | not requested | ok |
| `heartbeat:main` | every 30m | not requested | ok |
| `mmm-loop:main` | every 30m | **announce → last (no route)** | ok (not delivered) |
| `memory-core:memory-dreaming` | cron `0 3 * * *` | not requested | ok |
| `skill-collection-review` ×10 | every 7d | not requested | ok |

(`rbm-loop` / `rbbattle-overnight-loop` aus `docs/automations.md` sind inzwischen **weg** —
ersetzt durch `ci-cd-fix-loop` / `mmm-loop`.)

**Fix:** Delivery repointen, z. B.
`openclaw automations edit 6c979f8d-1a4b-4da8-9717-37be2349bf95 --delivery none`
(oder auf ein gültiges Ziel). Runtime-Eingriff, nicht in git.

**Einordnung:** Funktional „egal“ (Loop läuft), aber sauberer mit `none`/gültigem Ziel,
damit die „not delivered“-Warnung verschwindet.

# Empfehlungen — System-Optimierung (2026-09-11)

Stand: 2026-09-11 · Source-of-Truth: dieses Repo.

Konkreter Plan, abgeleitet aus [`hosts-inventory.md`](hosts-inventory.md),
[`incidents.md`](incidents.md) und [`storage-analysis.md`](storage-analysis.md).

---

## 1. Heavy-Lifting → `planet` (höchste Priorität)

**Erkenntnis:** `planet` = `projectmellon.de` und ist die richtige Maschine dafür
(modern i5-13500, 20T, NVMe, Load ~1.4). Er fährt **bereits** das schwere Zeug:
OpenClaw-Image-Build (GH-Runner), `riftbreaker-battle-mod`-Runner, AzerothCore-Compiles.

**Was neu ist (11.09.):** Der `mmm-loop` beweist, dass **Builds nicht auf `.149`** gehören
(Incident #3). Konkreter nächster Schritt ist, auch die Agent-seitigen Rust-Builds
(`cargo test`, `mmm`-Projekt) auf `planet` zu verlagern.

**Mechanismus:** siehe [`docs/dev-loops-planet.md`](../dev-loops-planet.md) — **Option A**
(`planet` als Session-Host-Node) ist weiterhin der empfohlene Weg: ein Gateway, Worker-Turns
auf `planet`, Modell-Credentials bleiben auf `.149`. **Option C** (nur `ssh planet` für
Builds) ist der risikoärmste erste Schritt, bewegt aber nicht den Agent-Turn selbst.

**Inkrementell starten:** Der OpenClaw-Container hat `planet` bereits in `ssh_config`
+ SSH-Key gemountet → Agents können heute schon schwere Kommandos per `ssh planet` ausführen.

**Brittle-Risiko minimieren:**
- `planet` ist ein geteilter Multi-Service-Host (Media + Game-Server + Builds). Bei
  OpenClaw-Compute dort: **cgroup-Limits** (CPU/RAM) setzen, Worker-Kapazität klein starten
  (nicht 1 Slot/Core bei 20 Cores).
- OpenClaw-Storage auf NVMe halten, **nicht** auf dem rclone-Mount (`cold:`).
- Schwere Game-Builds (AzerothCore) zeitlich von OpenClaw-Last entkoppeln.

---

## 2. Storage-Cleanup (vor jedem Hardware-Kauf)

Reihenfolge:

1. **`planet`: Docker-Cleanup** → ~130 G (Build-Cache 48 G + alte `openclaw-deploy`-Images 84 G).
   - `docker builder prune`
   - alte `ghcr.io/momokli/openclaw-deploy`-Tags entfernen (nur `latest` + letzte N behalten).
2. **`.149`: Container-Writable-Layer (167 G) untersuchen** — welcher Container schreibt in
   die eigene Layer statt in ein Named Volume? (Verdacht: OpenClaw oder Stash.)
3. **`.149`: alte Docker-Images + Build-Cache prunen** (~72 G).
4. **Danach neu messen** (`df -h`, `docker system df`) und erst dann über weitere Schritte
   entscheiden.

## 3. rclone-VFS-Cache cappen (statt SATA-SSD-Kauf)

- `--vfs-cache-max-size` auf ~600 G senken → ~250–350 G NVMe frei.
- Falls OpenClaw-Compute dauerhaft auf `planet` landet: Option **b** prüfen (zweite
  NVMe-Partition exklusiv für OpenClaw) — sauberer als der Soft-Cap-Wettbewerb.
- **Kein** SATA-SSD-Kauf: langsamer als das vorhandene NVMe, und es ist erstmal
  ~380–480 G Headroom reclaimable.

## 4. Delivery-Fix `mmm-loop`

```sh
docker exec -u node openclaw openclaw automations edit \
  6c979f8d-1a4b-4da8-9717-37be2349bf95 --delivery none
```
Oder auf ein gültiges Ziel (Control-UI/Web), falls proaktive Updates gewünscht sind.
Runtime-Eingriff, nicht versioniert. Behebt die „not delivered“-Warnung; der Loop selbst
läuft bereits.

## 5. Observability nachrüsten (damit die nächste Spitze nachweisbar ist)

- sysstat/sar auf `.149` + `planet` aktivieren (war leer/seit 2024 deaktiviert), oder
- Prometheus/node-exporter/cadvisor-Historie nutzen (auf beiden vorhanden).
- Ziel: beim nächsten Load-Spike sofort sehen, ob `stash-generate`, `rsync-flacs`,
  ein `cargo`-Build oder etwas anderes der Treiber ist — statt es nur abklingend zu beobachten.

---

## Entscheidungs-Shortlist (zur Freigabe)

1. `mmm-loop`-Delivery → `none` (1 Befehl, sofort).
2. `planet`-Docker-Cleanup (~130 G) — welche Images safe zu löschen sind, vorher aufzählen.
3. rclone `--vfs-cache-max-size` → 600 G.
4. Agent-Builds (`cargo test` u. ä.) von `.149` auf `planet` verlagern (Option A oder C).
5. sysstat/sar aktivieren.

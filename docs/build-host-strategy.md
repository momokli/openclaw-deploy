# Build-Host-Strategie — Agent-Builds/-Tests auf Planet, `.149` nur Orchestrierung

Stand: 2026-09-10. Entscheidungs-Doku zu Issue [#46](https://github.com/momokli/openclaw-deploy/issues/46)
(Build-Host-Strategie evaluieren) und Meta-Issue [#49](https://github.com/momokli/openclaw-deploy/issues/49)
(Build-/Test-Environment der Coding-Pipeline auf Planet).

## Problem

Die Coding-Pipeline (`feature-dev-*`-Agents) baut/testet aktuell in der Gateway-Sandbox
auf `.149`. Diese Kiste ist CPU-kontendiert (Load-Spitzen ~14/16 Cores, `openclaw` ~60 GiB,
~20 weitere Container — siehe [equip-agents.md](equip-agents.md) A10). Folge in der
`mmm`-Pipeline: `cargo test` (~700 Tests) + Playwright deutlich langsamer, load-induzierte
Test-Flakes (z. B. `tags_bulk_resolve`-Timeout unter Last) → Re-Runs → Pipeline-Zeit explodiert.

Gleichzeitig laufen schwere Build-Lasten (neoForm-Recompile 3 min+, Gametest-Server-Boots,
FTB-Pack-Downloads/-Extractions 500+ Mods) _je nach Aufgabe_ mal auf `.149`/Sandbox, mal auf
planet — ohne festgelegten Build-Host, ohne Baseline, ohne persistente Caches (→ B1 in
`equip-agents.md`).

## Entscheidung

**Container-per-Job Build-Farm auf Planet** (Hetzner EX44, Tailscale `100.77.143.105`,
public `projectmellon.de`). `.149` bleibt reiner Orchestrator (UI, kleine Jobs, Deploy-Trigger).

- Build-/Test-Runtime wird als **eigenständiges Build-Image** von GHCR gezogen — **nicht** ins
  Gateway-Image gebacken (Trennung Gateway-Runtime ≠ Build-Runtime).
- Ausführung als **ephemeraler Container je Job** (`docker run --rm`) mit Limits + warmen Caches.
- `.149` erhält dadurch seine CPU/RAM fürs Gateway zurück; Build-/Test-Last liegt auf dedizierter
  Hardware.

Begründung (SOTA-Abgleich aus #49): Für 1 User + vorhandenen Planet + kein k8s ist eine
Container-Farm das passende Modell ("Daytona light"). Bewusst **nicht**: Firecracker-microVMs
(Ops-Overhead für 1 User), k8s/actions-runner-controller (kein Cluster), SSH direkt in die
Host-Shell (Boundary-Verlust), komplette Verlagerung auf GitHub-hosted CI (Latenz, kein lokales
Debug — aber als Ergänzung für Full-Matrix-Runs sinnvoll, existiert bereits über den
self-hosted Runner).

## Routing-Optionen (aus #49)

| Option                            | Beschreibung                                                                                                             | Pro                                                                                                | Contra                                                                                 |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| (a) OpenClaw-Node-Pairing         | Planet als OpenClaw-Node pairen; Coding-Pipeline-Exec mit `host=node`, Test-Kommandos via `docker exec` in den Container | nativer Weg; Policy/Audit bleibt im Gateway                                                        | parallele Pipelines schwerer; zweiter Node = zweite Policy-/Audit-Fläche; Reife unklar |
| (b) Build-Daemon (Tailscale-only) | kleiner Daemon mit Queue + Log-Streaming, Bearer-auth, nur im Tailnet erreichbar                                         | Queue löst Parallelbetrieb; harte Boundary (kein Host-Shell); entkoppelt von Gateway-Exec-Timeouts | eigener Service (klein, aber zu betreiben)                                             |

**Empfehlung: Option (b) — Tailscale-only Build-Daemon (Queue + Log-Streaming).**

Rationale: Die offene Kernfrage aus #49 ist der **Parallelbetrieb** mehrerer `feature-dev`-Läufe.
Ein Queue-basierter Daemon beantwortet das direkt (FIFO/Concurrency-Limit je nach Planet-Cores),
hält eine harte Sicherheitsgrenze (kein direkter Host-Shell-Zugriff, Bearer-token, nur Tailnet)
und entkoppelt Build-Laufzeiten von den dokumentierten Gateway-Timeout-Problemen auf `.149`
(Announce-Delivery-Timeouts, lange Subagent-Läufe — `equip-agents.md` A6/A10). OpenClaw-Node-Pairing
bleibt als mögliche spätere Evolution offen, falls das native Routing reift und die
Parallel-Anforderungen trivial bleiben.

## Warme Cache-Volumes (größter Zeithebel neben CPU-Entkopplung)

Persistente, zwischen Jobs wiederverwendete Volumes (projekt-/sprachabhängig):

- **Rust:** `CARGO_HOME`/`~/.cargo/registry` + `target/` (Cargo-Registry-Cache + Build-Artefakte)
- **Node:** `node_modules` + `~/.npm` (npm-Cache)
- **Playwright:** `ms-playwright`-Browser-Binaries (`PLAYWRIGHT_BROWSERS_PATH`)
- **Gradle/JVM:** `GRADLE_USER_HOME` (`~/.gradle`, NeoForge-Deps 2–4 GB — vgl. README "Yogglez Dev-Stage")

## Container-Isolationsanforderungen

- **CPU-/Mem-Limits** pro Job (`--cpus`/`--memory`; NeoForge-Devserver braucht 4–8 GB — vgl.
  README `mem_limit: 8g`), damit ein Build nicht den ganzen Planet aufreibt.
- **`tmpfs` für `/dev/shm`** — Default-`shm` (64 MB) ist der dokumentierte Playwright-Blocker
  (siehe #22/#49); Test-DBs (SQLite) ggf. ebenfalls auf tmpfs gegen Flakes.
- **Ephemeral `--rm`** pro Job — kein persistenter Container-State, Rebuilds deterministisch.
- Build-Image via **GHCR** (multi-stage) mit Rust-Toolchain, Node, Playwright+Chromium,
  Liberation-/DejaVu-Fonts, flac/metaflac.

## Offene Fragen an Momo (aus #49, noch nicht entschieden)

1. **Routing**: Option (b) Daemon vs. Option (a) OpenClaw-Node — Empfehlung oben (b), Entscheidung offen.
2. **Security/Boundaries**: Sandbox-Konzept des Gateways vs. Build-Host-Zugriff (Secrets, `/lab`,
   `.149`-Dienste) — was darf der Build-Host/die Container sehen?
3. **Parallele Pipelines**: Ressourcen-Plan auf Planet (Concurrency-Limit, Queue-Fairness).
4. **GitHub-hosted CI als Ergänzung**: für Full-Matrix-Runs nutzen oder Sandbox-only validieren?
5. _(nicht Teil des Build-Env):_ macOS/DMG bleibt lokal bei Momo.

## Baseline / DoD

**Was gemessen wird** (per `scripts/build-benchmark.sh`): Zeit je Build-Phase auf `.149` vs.
Planet — Ressourcen-Snapshot (Cores, Load, RAM, Disk, Toolchain) + (opt-in) ein kleiner,
repräsentativer Node-Compute-Task als Mikro-Baseline. Echte Build-Phasen (neoForm-Recompile,
Gametest-Boot, `cargo test`, Playwright) werden separat und nur bewusst gemessen, **nicht** vom
Benchmark-Script automatisch angestoßen.

**Erfolgskriterien:**

- Dokumentierte Build-Host-Strategie liegt vor (diese Datei). ✅
- Baseline-Messungen je Build-Phase (`.149` vs. Planet) existieren und sind im Repo notiert —
  aktuell **offen**, über `scripts/build-benchmark.sh` zu erheben (→ B8 in `equip-agents.md`).
- Regressionen sind erkennbar: neue Messung wird gegen die notierte Baseline verglichen.

## Verweise

- `docs/equip-agents.md` — Block A10 (`.149`-Last), Block B1/B8 (Build-Env-Fakten).
- `README.md` — Architektur, `planet`/`lan`-Tailscale-Aliase, Yogglez-Dev-Stage (Gradle-Cache-Volume).
- `docs/mesh-first-access.md` — Tailscale-first Admin-SSH.
- `scripts/build-benchmark.sh` — Baseline-Messung.

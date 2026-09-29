# PLAN — OpenClaw Native Cluster (lan Gateway + planet Session-Host)

Stand: 2026-09-16 · Status: **ABGESCHLOSSEN** · Source-of-Truth: dieses Repo.

Ziel: OpenClaw von Docker auf **nativ** migrieren, `planet` als **Session-Host-Node**
anbinden und das ganze Setup **as-code** machen — damit schwere Coding-Builds auf
`planet` laufen und `.149` nur noch orchestriert.

## Zielbild

```
lan (.149)   — Gateway (nativ): Chat + Orchestrierung + Model-Proxy   [leicht]
planet       — Session-Host-Node (nativ): Worker-Turns (cargo/test)   [schwer]
```

**Ein** Gateway, **ein** Node (Session Hosting = Option A). Keine zweite volle Instanz.

---

## Phasen & Status

- [x] **Phase 0 — Research:** OpenClaw-Doku (native install, session hosting, nodes) gelesen.
- [x] **Phase 1 — Declarative Automations:** geklärt → **nicht** deklarativ in `openclaw.json`. As-code = idempotentes Converge-Skript (git → `automations create/edit`).
- [x] **Phase 2 — Native-Install-Rezept:** liegt vor (siehe Findings unten + `scripts/setup-native.sh`).
- [x] **Phase 3 — as-code Grundlagen:** Config kopiert (`~/.openclaw/openclaw.json`), Secrets (`~/.openclaw/.env`), Plugins gepinnt.
- [x] **Phase 4 — lan nativ aufbauen:** Node 24.19 + OpenClaw 2026.8.1 installiert, Gateway als systemd-Service.
- [x] **Phase 5 — planet als Session-Host pairen:** `connect --service --session-host` durch; planet gepaart/approved/connected, `workerRuns` enabled + capacity 4 + isolation none.
- [x] **Phase 6 — Cutover:** Docker-Gateway gestoppt, State gemoved, natives Gateway läuft (healthz/öffentlich 200).
- [x] **Phase 7 — Cluster booten:** Loops as-code neu angelegt (`delivery: none`, disabled). **Routing-Klärung:** `deviceId`/`autoDevice` (Session-Hosting) gilt NICHT für isolated-Cron — nur für managed-worktree-Sessions. Der richtige Weg für schwere Builds ist `exec host=node` (`tools.exec.node: "planet"` gesetzt + mmm-loop-Prompt angepasst).
- [x] **Phase 8 — Docker entfernen (2026-09-16):** Dockerfiles, compose, entrypoint.sh, GHCR-Workflow, Deploy-Webhook, Ansible entfernt. Installation auf `.149` ist Source-of-Truth; Config aus git wird per `setup-native.sh`/`converge-openclaw-config.sh` gespielt. Provider nur noch OpenRouter.

---

## Entscheidungen

| Thema             | Stand                                                    |
| ----------------- | -------------------------------------------------------- |
| Architektur       | 1 Gateway (lan) + 1 Node (planet) — **nicht** 2 Gateways |
| Isolation         | `none` (Prozess, damit `rustup update` am Host wirkt)    |
| Capacity          | 4 Worker-Slots (Start)                                   |
| Node-Version      | 24.19.0 installiert (supported); SOTA = 26 (später)      |
| Cutover-Strategie | **parallel aufbauen, dann Cutover** (nicht „stop first“) |

## Research-Findings (Sub-Agents, 2026-09-11)

- **Automations NICHT deklarierbar** in 2026.8.1 (`openclaw.json` hat kein `cron.jobs`/`automations`-Key; `declarationKey` nur für system-/plugin-owned Jobs). → As-code = idempotentes Converge-Skript (Job-JSON in git → `automations list/get` + `create`/`edit`).
- **`delivery.mode: "none"`** (CLI `--no-deliver`) behebt das „announce → last“-no-route-Problem sauber.
- **Native Install:** `curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard`; Node **26.1+ empfohlen**, 24.16+ supported.
- **Gateway-Service:** `openclaw gateway install` (per-user systemd `openclaw-gateway.service`) + `sudo loginctl enable-linger <user>`.
- **Config-Pfad:** `~/.openclaw/openclaw.json`; Env-Override `OPENCLAW_CONFIG_PATH` (NICHT `OPENCLAW_CONFIG`); State `OPENCLAW_STATE_DIR`; Workspace `OPENCLAW_WORKSPACE_DIR`. **Kein Symlink** (OpenClaw ersetzt Config atomar → Symlink-Ziel wird überschrieben).
- **Secrets:** `~/.openclaw/.env` (daemon-nativer dotenv), kein systemd-EnvironmentFile nötig.
- **Plugins:** `openclaw plugins install @openclaw/<pkg>@2026.8.1 --pin`.
- **Update:** `openclaw update` (convergt offizielle Plugins, erhält Pins).

## Offene Fragen

- [ ] `config/agents/*.md` → per-agent AGENTS.md: natives Shape = per-agent Workspace-Verzeichnisse (`agents.entries.<id>.workspace`). Genaues Layout verifizieren.
- [ ] Worker-Artifact: Credentials bleiben auf Gateway (Doku bestätigt) — planet braucht keine Provider-Keys.

## Risiken

1. Live-Gateway auf `.149` — Änderungen an der Config dürfen Molty nicht lang down nehmen
   (Converge-Merge erhält Runtime-Felder; Config wird atomar geschrieben).
2. `planet` ist geteilter Host (Media/Game-Server) → Worker-Capacity/CPU-Caps nötig.

---

## Verweise

- `docs/dev-loops-planet.md` — Session-Hosting-Plan (Option A).
- `docs/system-optimization/` — geerntetes Wissen (Hosts, Incidents, Storage).
- `docs/automations.md` — Automations-Inventar (Kosten-Treiber, Delivery).

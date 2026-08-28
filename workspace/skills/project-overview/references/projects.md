# Projekt-Index (Momos Setup)

> **Erste Fassung, von Momo zu pflegen.** Stand: 2026-08-28.
> Source-of-Truth = Repo `openclaw-deploy` (nicht `lab/`).

## Was das hier ist

- Self-hosted AI-Agent-Gateway **"Molty"** 🦞 auf Momos Homelab.
- Model: **DeepSeek V4 Flash** (primary) / **V4 Pro** (fallback + heavy coding).
- Live: `https://openclaw.simonklimke.de` (Caddy → Docker auf `.149` = `192.168.178.149`).
- Channels: **Telegram** (`@momomemos_bot`), DM-Pairing.
- STT: **Groq Whisper + Deepgram** (Sprachnachrichten funktionieren).
- Search: **Kagi** via curl (natives `web_search` ist disabled).

## Hosts & Rollen

| Host            | IP              | Rolle               | Services                                                                                  |
| --------------- | --------------- | ------------------- | ----------------------------------------------------------------------------------------- |
| **lan** (.149)  | 192.168.178.149 | Home-Server, Docker | Caddy, OpenClaw, Stash, Paperless, Deemix, Calendar, Bitwarden, Music, Syncthing, Chat... |
| **wish** (.200) | 192.168.178.200 | Home-Server, Docker | Wish, Fairy, Dufs file server                                                             |
| **vm2** (.75)   | 192.168.178.75  | Proxmox VM          | Früher Nomad-Client, jetzt Docker                                                         |
| **vm1** (.84)   | 192.168.178.84  | Proxmox VM          | Früher Nomad-Server, jetzt idle                                                           |
| **pve** (.91)   | 192.168.178.91  | Proxmox Hypervisor  | Home Assistant VM, Storage                                                                |
| **planet**      | Hetzner Metal   | Heavy workloads     | Plex, \*arr-Stack, Downloader                                                             |
| **satellite**   | Hetzner Cloud   | Public endpoints    | Tailscale entry node                                                                      |
| **c0**          | Hetzner Cloud   | Compute             | —                                                                                         |
| **Contabo VPS** | Contabo         | Plex relay          | Plex traffic routing (Plex Inc. requirement)                                              |

### Traffic Flow (Entry Points)

```
Internet
  │
  ├─ projectmellon.de ──────────► Hetzner VPS (Minecraft, Factorio)
  ├─ satellite (sat.az.monocu.be) ► Hetzner Cloud VPS (public endpoints)
  ├─ Contabo VPS ───────────────► Plex relay (backend at Hetzner)
  │
  └─ Cloudflare DNS
       └─ Fritz!Box (Port-Forward 80,443)
            └─ 192.168.178.149 (LAN-Server) ← OpenClaw
                 ├─ Caddy (Reverse Proxy, TLS via Cloudflare ACME)
                 ├─ Stash, Paperless, Deemix, Calendar, Bitwarden, OpenClaw...
                 └─ Routet weiter zu .200, .33 etc.
```

- DNS: systemd-Job alle 5 Min auf `.149` → setzt alle Domains aus `/home/momo/home_domains.txt`
  auf die aktuelle öffentliche IP (Cloudflare).
- Game-Server (Minecraft, Factorio, CS 1.6) können auf jedem Server laufen; Configs in `/lab/games/`.
  Factorio + Minecraft `mellon` laufen auf Hetzner **planet**.

## Services auf `.149` + Deploy-Architektur

**docker-compose.yml** (Projektname `openclaw`):

- `openclaw` — AI-Gateway, `image: ghcr.io/momokli/openclaw-deploy:latest`,
  Port `127.0.0.1:18789:18789`, Netzwerke `default` + `caddy` (extern, `caddy_default`).
- `obsidian-sync` — headless Client für `quill_data`, `image: ghcr.io/momokli/openclaw-obsidian-sync:latest`.

**Volumes (Runtime, NICHT in git):** `openclaw_home`, `openclaw_workspace`, `openclaw_repos`,
`obsidian_config` (+ read-only `/opt/apps/lab:/lab:ro`, `/opt/apps/quill:/quill`).

**GHCR-Deploy-Flow:**

```
push GitHub (main)
  └─ GitHub Actions (self-hosted runner auf projectmellon.de, Hetzner 20 cores)
       ├─ docker build (openclaw + obsidian-sync) → push beide nach GHCR
       └─ POST https://deploy.openclaw.simonklimke.de/deploy   # deploy webhook

.149 (systemd timer alle 30min ODER sofort via webhook)
  └─ scripts/build-and-deploy.sh
       ├─ git pull origin main                        # config sync
       ├─ docker pull beide Images aus GHCR           # image sync
       ├─ docker compose up -d openclaw obsidian-sync
       └─ hash-vergleich → skip wenn nichts neu
```

- Build läuft in **GitHub Actions**, nicht mehr auf projectmellon.de.
- `GHCR_TOKEN` (classic PAT, `write:packages`) weiterhin nötig — built-in `github.token`
  scheitert an `permission_denied: write_package`.

## OpenClaw-Komponenten

**Agenten** (`config/openclaw.json` → `agents.list`):

- `main` — DeepSeek V4 Flash.
- `coding-orchestrator` — DeepSeek V4 Pro.
- `feature-dev-*` (Flash): `planner`, `setup`, `developer`, `verifier`, `tester`, `reviewer`.

Defaults: Sub-Agents erlaubt (`maxSpawnDepth: 2`), `memorySearch` via `gemini-embedding-001`
(extra Pfad `/quill`).

**Channels:** Telegram (enabled, `dmPolicy: pairing`, Gruppen `requireMention: true`,
Mention-Patterns `@molty`/`@openclaw`).

**Tools:**

- Media: `groq/whisper-large-v3-turbo` (audio), `deepgram/nova-3` (audio, de),
  `google/gemini-3-flash-preview` (image). `audio.enabled` + `image.enabled` beide true.
- Search: Kagi (`POST https://kagi.com/api/v1/search`, `Authorization: Bearer <key>`,
  Body `{"query": "..."}`). Natives `web_search` disabled.
- `loopDetection` enabled.

**Session:** `dmScope: per-channel-peer`, Idle-Reset nach 120 Min, Maintenance
(`maxEntries: 300`, `pruneAfter: 14d`).

## Offene Baustellen / To-dos

- **Gemini Vision Key provisionieren:** Config ist gefixt (`image`-Model + `image.enabled`),
  aber `GEMINI_API_KEY` muss noch in `config/.env` auf `.149` (via Ansible + `.env.example`).
- **Server-Branch `feat/separate-state-config` → `main`** umstellen (braucht Approval).
- **Dockerfile base image pinnen** (`openclaw/openclaw:slim` floatet).
- **GHCR-Flow nur teilweise im Repo:** README dokumentiert noch den alten Flow
  (scp → projectmellon → save/load); kein Runner-Setup/Doku für projectmellon.de;
  `scripts/test-branch.sh` noch auf altem local-build-Flow + altem Volume-Layout;
  `ansible/deploy.yml` broken (falsche Pfade) + alter `.env`-Writer.

## Gotchas

- **Nomad ist TOD.** HashiStack (Nomad, Consul, Vault) dekommissioniert; alles läuft jetzt via
  Docker Compose oder systemd. Alte Nomad-Configs im `lab/`-Repo ignorieren.
- **`/lab` ist read-only** (`/opt/apps/lab:/lab:ro`) — `lab/` ist nur noch ein Mount, keine
  Source-of-Truth mehr.
- **Secrets nur in `config/.env` auf `.149`** (gitignored, DIE Secret-Datei). Repo-Root-`.env`
  ist nur lokaler Scratch auf dem Mac und wird NICHT deployt — Keys dort bewirken nichts im Container.
- **Config vs Runtime trennen:** Git = read-only (`config/`, `workspace/`); Runtime = Named Volumes
  (nicht in git). `entrypoint.sh` kopiert/synct die git-Dateien in den Container.

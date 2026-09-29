# Projekt-Index (Momos Setup)

> **Erste Fassung, von Momo zu pflegen.** Stand: 2026-08-28.
> Source-of-Truth = Repo `openclaw-deploy` (nicht `lab/`).

## Was das hier ist

- Self-hosted AI-Agent-Gateway **"Molty"** 🦞 auf Momos Homelab.
- Model: **OpenRouter only** — `openrouter/deepseek/deepseek-v4.1-flash` (primary) /
  `openrouter/deepseek/deepseek-v4-pro` (fallback + heavy coding).
- Live: `https://openclaw.simonklimke.de` (Caddy → natives Gateway auf `.149` = `192.168.178.149`).
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

**Natives Gateway** (systemd-User-Service `openclaw-gateway.service`, kein Docker):

- `openclaw` — AI-Gateway, `/opt/node/bin/node .../openclaw/dist/index.js gateway --port 18789`,
  State `/home/momo/.openclaw/`, Caddy → `127.0.0.1:18789`.

**Config-Converge-Flow (manuell oder per Code):**

```
git openclaw-deploy (deklarativer Seed: config/, workspace/)
  → auf .149 gespielt:
      sudo bash scripts/setup-native.sh momo              # Bootstrap
      sudo bash scripts/converge-openclaw-config.sh momo  # Config → Runtime (Merge)
      sudo bash scripts/sync-agent-personas.sh momo       # agents/*.md → workspaces/<id>/AGENTS.md
```

- Die laufende Installation auf `.149` ist Source-of-Truth für Runtime-State;
  das Repo liefert den deklarativen Seed.

## OpenClaw-Komponenten

**Agenten** (`config/openclaw.json` → `agents.entries`):

- `main` — OpenRouter V4.1 Flash.
- `coding-orchestrator` — OpenRouter V4.1 Flash.
- `feature-dev-*` (Flash): `planner`, `setup`, `developer`, `verifier`, `tester`, `reviewer`.

Defaults: Sub-Agents erlaubt (`maxSpawnDepth: 2`), `memorySearch` via `ollama` /
`nomic-embed-text` (lokal, extra Pfad `/quill`).

**Channels:** Telegram (enabled, `dmPolicy: pairing`, Gruppen `requireMention: true`,
Mention-Patterns `@molty`/`@openclaw`).

**Tools:**

- Media: `groq/whisper-large-v3-turbo` (audio), `deepgram/nova-3` (audio, de),
  `google/gemini-3.6-flash` (image). `audio.enabled` + `image.enabled` beide true.
- Search: Kagi (`POST https://kagi.com/api/v1/search`, `Authorization: Bearer <key>`,
  Body `{"query": "..."}`). Natives `web_search` disabled.
- `loopDetection` enabled.

**Session:** `dmScope: per-channel-peer`, Idle-Reset nach 120 Min, Maintenance
(`maxEntries: 300`, `pruneAfter: 14d`).

## Offene Baustellen / To-dos

- **Gemini Vision Key provisionieren:** Config ist gefixt (`image`-Model + `image.enabled`),
  `GEMINI_API_KEY` liegt in `~/.openclaw/.env` auf `.149` (via `.env.example`).
- **Server-Branch `feat/separate-state-config` → `main`** umstellen (braucht Approval).

## Gotchas

- **Nomad ist TOD.** HashiStack (Nomad, Consul, Vault) dekommissioniert; alles läuft jetzt via
  Docker Compose (Fremd-Services) oder systemd (OpenClaw natives Gateway). Alte Nomad-Configs im
  `lab/`-Repo ignorieren.
- **`/lab` ist read-only** — `lab/` ist nur noch ein Mount/Referenz, keine Source-of-Truth mehr.
- **Secrets nur in `~/.openclaw/.env` auf `.149`** (gitignored, DIE Secret-Datei). Repo-Root-`.env`
  ist nur lokaler Scratch auf dem Mac und wird NICHT deployt — Keys dort bewirken nichts im Gateway.
- **Config vs Runtime trennen:** Git = deklarativer Seed (`config/`, `workspace/`); Runtime =
  `~/.openclaw/` (nicht in git). `converge-openclaw-config.sh` merged die git-Config mit
  Runtime-Feldern statt blind zu kopieren.

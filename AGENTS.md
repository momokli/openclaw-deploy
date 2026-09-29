# OpenClaw Deploy — Repo-Kontext & Handoff

> Source-of-Truth für die OpenClaw-Konfiguration (Seed/Reference) ist DIESES Repo
> (`openclaw-deploy`). Die **laufende Installation auf `.149` ist die operative
> Source-of-Truth** — dieses Repo liefert die deklarative Config, die per
> `scripts/setup-native.sh` + `scripts/converge-openclaw-config.sh` auf die Instanz
> gespielt wird. Runtime-State (Sessions, Plugins, Auth, Memory) lebt NUR auf `.149`.

## Was ist das hier

- Self-hosted AI-Agent-Gateway "Molty" 🦞 auf Momos Homelab.
- **Deployment: nativ** (Node + `openclaw gateway install` als systemd-User-Service
  `openclaw-gateway.service`). **Kein Docker mehr** (Docker/GHCR/Ansible-Flow entfernt 2026-09-16).
- Model: **OpenRouter only** — `openrouter/deepseek/deepseek-v4.1-flash` (primary),
  `openrouter/deepseek/deepseek-v4-pro` (fallback + heavy coding). **Kein** direkter
  DeepSeek-Provider mehr.
- Live: `https://openclaw.simonklimke.de` (Caddy → natives Gateway auf `.149` = `192.168.178.149`).
- Channels: Telegram (`@momomemos_bot`), DM-Pairing.
- STT: Groq Whisper + Deepgram (Sprachnachrichten funktionieren).
- Search: Kagi via curl (natives `web_search` ist disabled).

## Deployment-Architektur (IST-Stand)

```
.149 — natives Gateway (systemd-User-Service openclaw-gateway.service)
  ├─ /opt/node/bin/node .../openclaw/dist/index.js gateway --port 18789
  ├─ State: /home/momo/.openclaw/           (Runtime: Sessions, Plugins, Auth, Memory)
  ├─ Config: /home/momo/.openclaw/openclaw.json   (aus diesem Repo converged)
  ├─ Secrets: /home/momo/.openclaw/.env           (aus diesem Repo .env.example geseedet)
  └─ Caddy → 127.0.0.1:18789

planet — Session-Host-Node (nativ gepaart, `tools.exec.node: "planet"`)
  └─ schwere Worker-Turns (cargo/test/Playwright)
```

Konfiguration wird **manuell oder per Code** gespielt (kein Auto-Deploy mehr):

```sh
# Bootstrap / Re-Seed (einmalig, idempotent):
sudo bash scripts/setup-native.sh momo

# Deklarative Config aus git → Runtime (erhält Runtime-Felder wie auth/plugins/identity):
sudo bash scripts/converge-openclaw-config.sh momo

# Agent-Personas aus git → per-agent workspaces/<id>/AGENTS.md:
sudo bash scripts/sync-agent-personas.sh momo
```

## Config vs Runtime-State (Trennung)

- Git (versioniert, Seed): `config/openclaw.json`, `config/agents/*.md`, `workspace/*.md`
  → werden per Script auf die Instanz gespielt (Konfiguration **manuell oder per Code**).
- Runtime (nur auf `.149`, NICHT in git): `~/.openclaw/` (Sessions/SQLite, Plugins,
  Auth-Profiles, Memory, Workspaces, Devices).

Wichtig (OpenClaw-Verhalten, in `converge-openclaw-config.sh` umgesetzt):

- OpenClaw **ersetzt `~/.openclaw/openclaw.json` atomar** und schreibt eigene
  Runtime-Felder hinein (`auth.profiles`/`auth.order`, `plugins.entries`, `meta.migrations`,
  `agents.entries.<id>.{agentDir,identity,name}`, `skills.entries["gh-issues"].apiKey`).
  Ein blindes Copy der git-Config würde diese Felder löschen → deshalb der Converge-Merge.
- `config/agents/*.md` → per-agent `workspaces/<id>/AGENTS.md` (OpenClaw Bug #29387:
  `agentDir/AGENTS.md` wird ignoriert — nur workspace-Dateien landen im Prompt).

## Secrets (kritisch!)

- **`~/.openclaw/.env` auf `.149`** ist DIE Secret-Datei (gitignored). Wird vom nativen
  Gateway-Daemon gelesen (kein `docker env_file`, kein `entrypoint.sh`-Copy mehr).
  Template: `.env.example` in diesem Repo.
- **`openclaw-deploy/.env` im Repo-Root** ist NICHT deployt — nur lokaler Scratch auf dem Mac.
  Keys hier hinzuzufügen bewirkt NICHTS im Gateway.
- Enthält (laut `.env.example`): `OPENROUTER_API_KEY`, `KAGI_API`, `TELEGRAM_BOT_TOKEN`,
  `OPENCLAW_GATEWAY_TOKEN`, `GH_TOKEN`, `GROQ_API_KEY`, `DEEPGRAM_API_KEY`, `GEMINI_API_KEY`
  sowie Hetzner/Contabo/Cloudflare-Infra-Keys.

## Gemini Vision (Bilder verstehen)

**Status:** Erledigt. Image-Model auf den stabilen GA-Endpoint `google/gemini-3.6-flash`.

**Verifizierte Fakten (OpenClaw-Doku + live `openclaw models list --all --provider google`):**

- Env-Var-Name: `GEMINI_API_KEY` und `GOOGLE_API_KEY` werden beide akzeptiert.
- Provider-ID: `google`, Modell-Format `google/gemini-...`.
- Für Vision MUSS ein Eintrag in `tools.media.models` mit `"capabilities": ["image"]` stehen.
- Config: `{ "provider": "google", "model": "gemini-3.6-flash", "capabilities": ["image"] }`
  plus `"image": { "enabled": true }` unter `tools.media`.

## Analytics (Kosten / Nutzung messen)

- `scripts/analytics.sh [START_UTC] [END_UTC]` (auf `.149`) — Event-Level-Report für ein
  Zeitfenster: Chats, Tools, Errors, Model-Usage, Kosten. Details + Schema + Gotchas:
  `docs/analytics.md`.
- Wichtig: `reasoning` ist Teilmenge von `output` (nicht extra berechnen); `*.jsonl.reset.*`-
  Snapshots mit einbeziehen (sonst wird `main` unterzählt); OpenClaws `usage.cost`-Feld nutzt
  andere Preise als die offiziellen Anbieter-Preise.

## GitHub-App-Auth — Status

- Persönliches PAT (`GH_TOKEN`) läuft weiterhin als Fallback. GitHub-App-Auth für
  `momo-clanker`/`momo-claw` (A/B-Runner) ist in den Wrappern
  (`scripts/{clanker,claw}-{gh,git}`, `scripts/gh-bot-auth.sh`) vorbereitet.
  Details: `docs/github-bot-identity-split.md`, `SETUP.md`.
- App-Tokens laufen nach ~1h ab → Mint-per-Call in den Wrappern (kein persistierter Dauer-Token).

## Arbeitsregeln (Momo)

- **KEINE Quick-Fixes.** Jegliche FIX/CHANGE erst vorlegen → Momo approvt → dann implementieren.
- Änderungen minimal, im Stil des bestehenden Repos.
- Konfiguration: dieses Repo = deklarativer Seed; **die laufende Instanz auf `.149` ist
  Source-of-Truth** für den Runtime-State.

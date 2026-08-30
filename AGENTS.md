# OpenClaw Deploy — Repo-Kontext & Handoff

> Source-of-Truth für das OpenClaw-Deployment ist DIESES Repo (`openclaw-deploy`).
> **Nicht** `lab/` benutzen — das ist veraltet (Nomad-Ära, `lab/services/openclaw/` ist ein alter Stand).

## Was ist das hier

- Self-hosted AI-Agent-Gateway "Molty" 🦞 auf Momos Homelab.
- Model: DeepSeek V4 Flash (primary) / V4 Pro (fallback + heavy coding).
- Live: `https://openclaw.simonklimke.de` (Caddy → Docker auf `.149` = `192.168.178.149`).
- Channels: Telegram (`@momomemos_bot`), DM-Pairing.
- STT: Groq Whisper + Deepgram (Sprachnachrichten funktionieren).
- Search: Kagi via curl (natives `web_search` ist disabled).

## Deployment-Architektur (IST-Stand)

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

Wichtig: der **Build läuft in GitHub Actions**, nicht mehr auf projectmellon.de.
`build-and-deploy.sh` auf `.149` pullt nur noch aus GHCR.

## Config vs Runtime-State (Trennung)

- Git (versioniert, read-only): `config/openclaw.json`, `config/agents/*.md`, `workspace/*.md`
  → gemountet als `/openclaw-config:ro` (`./config` + `./workspace` separat).
- Runtime (Named Volumes, NICHT in git): `openclaw_home`, `openclaw_workspace`,
  `openclaw_repos`, `openclaw_quill_data`.
- `entrypoint.sh` (läuft als root, gosu drop zu node):
  1. kopiert `openclaw.json` wenn geändert
  2. kopiert `config/.env` → `/home/node/.openclaw/.env`
  3. mappt `config/agents/*.md` → per-agent `workspaces/<id>/AGENTS.md`
     (OpenClaw Bug #29387: `agentDir/AGENTS.md` wird ignoriert — nur workspace-Dateien landen im Prompt)
  4. kopiert `workspace/{SOUL,AGENTS,USER,MEMORY}.md` → `workspace/` (explizite Liste, kein Glob;
     `MEMORY.md` nur seeden wenn fehlt)
  5. seeded DeepSeek auth profile auf `main` (env-only auth erreicht Sub-Agents nicht)

## Secrets (kritisch!)

- **`config/.env` auf `.149`** ist DIE Secret-Datei (gitignored). Wird via
  `docker-compose.yml` → `env_file: ./config/.env` injiziert UND von `entrypoint.sh` kopiert.
- **`openclaw-deploy/.env` im Repo-Root** ist NICHT deployt — nur lokaler Scratch auf dem Mac.
  Keys hier hinzuzufügen bewirkt NICHTS im Container.
- Es gibt KEIN `config/.env` im Repo (gitignored) und KEIN `.env.example` als Template.
- `config/.env` auf `.149` enthält (laut README + ansible): `DEEPSEEK_API_KEY`, `KAGI_API`,
  `TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `GH_TOKEN`, `GROQ_API_KEY`, `DEEPGRAM_API_KEY`.

## OFFENE AUFGABE: Gemini Vision (Bilder verstehen)

**Status:** Config gefixt (`image`-Model + `image.enabled` in `config/openclaw.json`).
Offen: `GEMINI_API_KEY` auf `.149` provisionieren (via Ansible + `.env.example`).

**Root cause (2 Blocker):**

1. `config/openclaw.json` → `tools.media.models` hat NUR Audio (groq + deepgram), kein `image`-Model.
2. `GEMINI_API_KEY` liegt nur im Repo-Root-`.env` (nicht deployt), nicht in `config/.env`.

**Verifizierte Fakten (OpenClaw-Doku):**

- Env-Var-Name: `GEMINI_API_KEY` und `GOOGLE_API_KEY` werden beide akzeptiert.
- Provider-ID: `google`, Modell-Format `google/gemini-...`.
- Für Vision MUSS ein Eintrag in `tools.media.models` mit `"capabilities": ["image"]` stehen.
- `env.vars` in `openclaw.json` ist NICHT nötig für Provider-Auth (Provider-Auth liest Env-Vars
  direkt). Nur ergänzen, wenn der Agent den Key selbst in Tools/Scripts braucht.

**Sauberer Fix (3 Schritte, zur Approval):**

1. `config/openclaw.json` → `tools.media.models`:
   ```json
   { "provider": "google", "model": "gemini-3-flash-preview", "capabilities": ["image"] }
   ```
   plus `"image": { "enabled": true }` unter `tools.media`.
2. `GEMINI_API_KEY` in `config/.env` auf `.149` eintragen (NICHT Repo-Root-`.env`).
3. Secret-Provisioning + Docs sauber machen (siehe unten).

## Bekannte Baustellen (gefixt 2026-08-14 / offen)

Gefixt:

- `ansible/deploy.yml`: Struktur (tasks/handlers), Pfade (`{{ playbook_dir }}/../…`), `.env`-Writer
  nicht-destruktiv (`lineinfile`) auf alle 8 Keys inkl. `GEMINI_API_KEY`.
- `ansible/inventory.ini` + `ansible/ansible.cfg` ergänzt. Inventory nutzt `lan` (Tailscale MagicDNS
  → `100.85.52.13`), nicht die LAN-IP `192.168.178.149` (von außerhalb des LANs nicht erreichbar).
- README auf GHCR-Flow aktualisiert.
- `scripts/test-branch.sh` auf lokalen Build (git worktree) + aktuelle Mounts umgestellt.
- `.env.example` (8 Keys) angelegt.
- Workspace-Personas-Sync gefixt: `./workspace:/openclaw-config/workspace:ro` + explizite Liste im
  `entrypoint.sh` (vorher wurde `workspace/` gar nicht gemountet → Personas kamen nie aus git).

Gefixt (2026-08-17):

- `GH_TOKEN` erneuert: neuer classic PAT, Scopes `repo, workflow, write:packages`. Liegt in
  `config/.env` auf `.149` (unquoted) und im Repo-Root-`.env` (Scratch). `gh api user` → OK.
- `config/.env`: `GH_TOKEN` + `GEMINI_API_KEY` ent-quotet (waren gequotet; `entrypoint.sh` kopiert
  1:1 → Sub-Agents hätten gequotete Werte gelesen). Container neu erstellt.
- `ansible/deploy.yml` Gateway-Token-Extraktion gefixt: `regex_search(..., '\1')` liefert in
  Ansible 2.15 eine LISTE → `| default([]) | join('')`. Vorher hätte `lineinfile`
  `OPENCLAW_GATEWAY_TOKEN=['token']` geschrieben (Token-Rotation + Control-UI-Lockout).
- `ansible/deploy.yml` Docker-Tasks laufen jetzt als `momo` statt root (`become: yes` entfernt) —
  root hat keinen ghcr.io-Login. `docker compose exec` mit `-u node` (vorher root →
  `/root/.openclaw` statt `/home/node/.openclaw`).

Gefixt (2026-08-19):

- `docker-compose.yml`: `name: openclaw` top-level gesetzt → deterministischer Compose-Projektname
  (verhindert den `86fd1a1f5da4_`-Präfix-Namen-Konflikt, der `.149` down genommen hat).
- `scripts/build-and-deploy.sh`: räumt stale `openclaw`-Container auf + `--remove-orphans`
  (robuster gegen „container name already in use").
- Deploy-Webhook in Source-of-Truth: `scripts/webhook.py` + `scripts/openclaw-deploy-webhook.service`
  ins Repo, `ansible/deploy.yml` provisioniert Receiver + `webhook-token` + Caddy-Block.
- Alles auf GHCR: `obsidian-sync` wird jetzt in GitHub Actions gebaut + gepusht
  (`ghcr.io/momokli/openclaw-obsidian-sync`), kein lokaler Sidecar-Build mehr auf `.149`.
- KAGI-Search korrekt dokumentiert: `POST https://kagi.com/api/v1/search` + `Authorization: Bearer <key>`
  - JSON-Body `{"query": "..."}` (nicht `/api/v0` + `GET` + `Bot`).
- `config/openclaw.json`: `trustedProxies` auf `172.23.0.0/16` korrigiert (= `caddy_default`-Subnetz,
  nicht `172.17.0.1`/Default-Bridge). **Muss beim Subnetz-Wechsel des Caddy-Netzwerks mitgezogen werden.**
  `env.vars` auf `KAGI_API`+`GH_TOKEN` reduziert; `model.fallbacks` (V4 Flash) ergänzt.

Gefixt (2026-08-26):

- **GH/git-Auth im Container (Root-Cause der „GH token“-Issues):** `Dockerfile` setzte
  `git config --global` als **root** → landete in `/root/.gitconfig`, der runtime-user `node`
  hatte also KEINE git-Identity („Author identity unknown“) und KEINEN `credential.helper`
  (HTTPS-`git push` → „could not read Username for 'https://github.com'“). `gh` selbst lief
  (liest `GH_TOKEN` aus env), aber **git** nicht.
  - `Dockerfile`: `git config --global` → `--file /home/node/.gitconfig` (identity gilt jetzt
    direkt für `node`; `--system` war wegen Build-Cache/base-image-git-prefix unzuverlässig).
  - `entrypoint.sh` (Schritt 5c): `gh auth setup-git --hostname github.com` als `node` + Warnung
    wenn `gh auth status` nicht ok oder `GH_TOKEN` fehlt. `gh` wird dadurch als git-HTTP-
    credential-helper verdrahtet.
- `build.yml`: GHCR-Login nutzt weiterhin `GHCR_TOKEN` (classic PAT, `write:packages`).
  `github.token` wurde getestet, scheitert aber an `permission_denied: write_package`
  (Repo/Org-Actions-Permission lässt `packages: write` für den built-in Token nicht zu).
- README: Secrets sauber getrennt (runtime `config/.env` vs. GitHub repo secrets).

Offen (Live-Touchpoints, brauchen Approval):

- Server-Branch `feat/separate-state-config` → `main` umstellen.
- Dockerfile base image pinnen (`openclaw/openclaw:slim` floatet).

## Arbeitsregeln (Momo)

- **KEINE Quick-Fixes.** Jegliche FIX/CHANGE erst vorlegen → Momo approvt → dann implementieren.
- Änderungen minimal, im Stil des bestehenden Repos.
- Source-of-Truth = dieses Repo. `lab/` ist nur noch der `/opt/apps/lab:/lab:ro` Mount (separate Sache).

## GHCR / Build auf projectmellon.de — Status & Lücken

Der GHCR-Flow ist nur TEILWEISE im Repo.

**Vorhanden (aktuell, GHCR):**

- `.github/workflows/build.yml` — baut via `runs-on: self-hosted` (= Runner auf projectmellon.de)
  und pusht auf `main` nach `ghcr.io/momokli/openclaw-deploy` (`latest` + `:sha`).
- `scripts/build-and-deploy.sh` — pullt aus GHCR (kein lokaler Build mehr).
- `scripts/openclaw-build.{service,timer}` — `ExecStart=/opt/apps/openclaw/scripts/build-and-deploy.sh` (korrekt).
- `docker-compose.yml` — `image: ghcr.io/momokli/openclaw-deploy:latest`.

**Fehlt / stale (die eigentliche Baustelle):**

- **README** dokumentiert noch den ALTEN Flow (`scp Dockerfile → projectmellon → docker save/load`), nicht GHCR.
- **"projectmellon.de" taucht nirgends als explizite Konfiguration auf** — der Build dort läuft nur
  implizit über den `self-hosted`-Runner. Es gibt KEIN Runner-Setup/Script/Doku im Repo.
- **`GHCR_TOKEN`** ist weiterhin nötig (classic PAT, `write:packages`) — der built-in
  `github.token` wurde getestet, scheitert aber an `permission_denied: write_package`.
- **`scripts/test-branch.sh`** nutzt noch den alten local-build-Flow (scp + `docker build` + save/load),
  nicht GHCR, und das alte Volume-Layout (`config:/home/node/.openclaw:ro` statt `config:/openclaw-config:ro`).
- **`ansible/deploy.yml`** broken (falsche `../../services/...`-Pfade) + alter `.env`-Writer.

## Analytics (Kosten / Nutzung messen)

- `scripts/analytics.sh [START_UTC] [END_UTC]` (auf `.149`) — Event-Level-Report für ein
  Zeitfenster: Chats, Tools, Errors, Model-Usage, Kosten. Details + Schema + Gotchas:
  `docs/analytics.md`.
- Wichtig: `reasoning` ist Teilmenge von `output` (nicht extra berechnen); `*.jsonl.reset.*`-
  Snapshots mit einbeziehen (sonst wird `main` unterzählt); OpenClaws `usage.cost`-Feld nutzt
  andere (höhere) Preise als die offiziellen DeepSeek-off-peak-Preise.

## GitHub-App-Auth „momo-bot" — Migration vorbereitet (2026-08-30)

Geplant: persönliches PAT (`GH_TOKEN`, Scopes `repo, workflow, write:packages`) → GitHub App
„momo-bot" (Minimal-Permissions: Contents RW, Pull requests RW, Metadata R; Webhooks aus;
Installation nur auf betroffene Repos). **Noch NICHT aktiv** — solange `GH_APP_*` in
`config/.env` leer sind, läuft alles unverändert mit dem PAT.

- Neue Scripts (im Image unter `/usr/local/bin`, via Dockerfile): `generate-github-token.sh`
  (JWT RS256 via openssl → Installation-Token, ~1h) + `gh-app-auth.sh` (hosts.yml + credential
  helper + openclaw.json-`skills.entries["gh-issues"].apiKey` mit frischem Token; optional
  `--setup-git-identity` → Commits als `momo-bot[bot]`).
- `entrypoint.sh` Schritt 5c: MODE A (App-Vars gesetzt) → frisches Token bei Containerstart;
  MODE B (PAT) → unveränderter Legacy-Pfad.
- `ansible/deploy.yml`: `GH_APP_ID`/`GH_APP_INSTALLATION_ID` optional aus env; Assert erlaubt
  App-Vars statt `GH_TOKEN`. Private Key liegt NICHT in .env, sondern auf dem Host
  (`~/.secrets/momo-bot.pem`, chmod 600) und wird per docker-compose gemountet
  (Mount auskommentiert — aktivieren, sobald App existiert).
- Doku: `SETUP.md` (Web-UI-Schritte, IDs, Gotchas) + offene Fragen an Momo im PR-Body.
- App-Tokens laufen nach ~1h ab → kein persistierter Dauer-Token mehr; Refresh on-demand
  (`gh-app-auth.sh` bei 401) bzw. ggf. systemd-Timer (Entscheidung Momo).

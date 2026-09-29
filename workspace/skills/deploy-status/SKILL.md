---
name: deploy-status
description: "OpenClaw-Deployment (natives Gateway auf .149, Config-Converge) und GitHub-Pages-Deploys prüfen/debuggen: Flow, Status-Checks, Gotchas."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["gh", "ssh"] },
      },
  }
---

# Deploy-Status (OpenClaw)

Use für Status-Checks und Debugging des OpenClaw-Deployments: natives Gateway auf `.149`,
Config-Converge (git → Runtime) und `.149`.

## Flow (IST)

```text
git openclaw-deploy (deklarativer Seed: config/, workspace/)
  → manuell oder per Code auf .149 gespielt:
      sudo bash scripts/setup-native.sh momo              # Bootstrap (einmalig)
      sudo bash scripts/converge-openclaw-config.sh momo  # Config → Runtime (Merge)
      sudo bash scripts/sync-agent-personas.sh momo       # agents/*.md → workspaces/<id>/AGENTS.md

.149 — natives Gateway (systemd-User-Service openclaw-gateway.service)
  ├ /opt/node/bin/node .../openclaw/dist/index.js gateway --port 18789
  ├ State: /home/momo/.openclaw/
  └ Caddy → 127.0.0.1:18789

planet — Session-Host-Node (nativ gepaart, tools.exec.node = "planet")
```

Kein Docker, kein GHCR, kein Auto-Deploy. Die laufende Installation auf `.149` ist
Source-of-Truth für Runtime-State; das Repo liefert den deklarativen Seed.

## Zugriff

- `.149` via Tailscale: `ssh momo@lan` (= `100.85.52.13`; LAN-IP `192.168.178.149`).
- Config-Seed: `config/openclaw.json`, `config/agents/*.md` (dieses Repo).
- Runtime-Config: `/home/momo/.openclaw/openclaw.json`.

## Status prüfen

```bash
ssh momo@lan 'systemctl --user status openclaw-gateway.service'
ssh momo@lan 'curl -sf http://localhost:18789/healthz'
ssh momo@lan 'journalctl --user -u openclaw-gateway.service -n 100'
```

Gateway-Version + Provider/Model-Katalog:

```bash
ssh momo@lan 'sudo -u momo -H openclaw gateway status'
ssh momo@lan 'sudo -u momo -H openclaw models list --all | grep -iE "openrouter|gemini|groq|deepgram"'
```

## Pages-Deploy verifizieren (GitHub Pages)

**NIE** `sleep 20; curl -s <url> | grep …` als Deploy-Verifikation — das ist blind, langsam
und erkennt weder `errored` noch einen stale `built`-Build. Immer der Build-Status **API**:

```bash
gh api repos/<owner>/<repo>/pages/builds/latest --jq '.status'   # built | building | queued | errored
```

Kanonischer Helfer im Repo (Timeout + Backoff + Stale-Schutz):

```bash
scripts/verify-pages.sh <owner/repo> --commit <sha> --url https://<owner>.github.io/<repo>/
```

- Nach dem Push den **Commit-SHA** mitgeben (stärkstes Signal) oder Default-Baseline nutzen:
  ohne `--commit`/`--since` snapshottet das Script den aktuellen `created_at` und akzeptiert nur
  einen **echten neuen** Build (sonst greift das sofort-`built` des Vorgängers = falsch grün).
- **Nach einem Repo-Rename** vor dem ersten Check kurz warten (CDN-Invalidierung):
  `--rename-wait 20` (oder manuell 20 s, dann pollen).
- `--url` prüft nach `built` zusätzlich die Live-URL (HTTP 200); CDN kann hinter dem
  Build-Status nachlaufen.

| `status` | Bedeutung | Aktion |
|---|---|---|
| `queued`, `building` | Build läuft | weiter pollen (Backoff) |
| `built` | fertig | fertig — bei `--url` zusätzlich 200 abwarten |
| `errored`, `cancelled` | fehlgeschlagen | **abbrechen**, Fehler lesen (s. Stop-Regel) |

Exit-Codes `verify-pages.sh`: `0` built (URL ok) · `1` Timeout · `2` errored/cancelled ·
`3` Pages nicht aktiv (404) · `4` Usage/`gh` fehlt · `5` built, aber URL kein 200.

Beispiele: `momokli/yogglez` (`https://momokli.github.io/yogglez/`, `build_type: legacy`),
`momokli/riftbreaker-battle-mod`. `openclaw-deploy` selbst hat **kein** Pages (404).

## Gotchas

1. **Kein Docker/GHCR mehr** — natives Gateway (`openclaw-gateway.service`). Docker gibt es
   auf `.149` nur noch für Fremd-Services (Stash, Paperless, …), NICHT für OpenClaw.
2. **Config-Converge erhält Runtime-Felder** (`auth.profiles`, `plugins.entries`,
   `meta.migrations`, `agents.entries.<id>.{agentDir,identity,name}`) — nie `config/openclaw.json`
   blind kopieren.
3. **Secrets** liegen in `~/.openclaw/.env` (gitignored); Template `.env.example`.
4. **Provider** ist OpenRouter only (`openrouter/deepseek/deepseek-v4.1-flash` primary /
   `deepseek-v4-pro` fallback) + `google/gemini-3.6-flash` (image), `groq`/`deepgram` (audio).
5. **Pages-Verifikation nur über die Build-Status-API** (Abschnitt „Pages-Deploy verifizieren"),
   nie per `sleep`/`curl | grep`. `pages/builds/latest` ist bis zum neuen Build der **alte**
   Build — ohne Baseline/`--commit` wäre ein nacktes „poll bis built" sofort grün (falsch).

## Stop-Regel

Gateway „down"/Config driftet → NICHT blind neu booten oder Config überschreiben. Erst:
(1) `systemctl --user status openclaw-gateway.service` + `journalctl` lesen, (2) prüfen ob
`~/.openclaw/openclaw.json` parsebar ist (`jq .`), (3) `openclaw doctor --fix` in Betracht
ziehen. Unklar → Momo fragen.

Pages-Build `errored`/`cancelled` → NICHT weiter pollen. Ursache lesen:
`gh api repos/<owner>/<repo>/pages/builds/latest --jq '.error.message'` + betroffenen
Pages-Workflow-Run (`.github/workflows/*pages*`, `gh run list --workflow=…`), dann fixen und
neu auslösen.

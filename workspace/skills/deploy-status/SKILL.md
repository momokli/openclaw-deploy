---
name: deploy-status
description: "OpenClaw-Deploy (GHCR-CI/CD, Deploy-Webhook, .149) und GitHub-Pages-Deploys prüfen/debuggen: Flow, API-Status-Checks, Gotchas."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["gh", "ssh"] },
      },
  }
---

# Deploy-Status (OpenClaw)

Use für Status-Checks und Debugging des OpenClaw-Deployments: GHCR-CI/CD-Flow, Deploy-Webhook und `.149`.

## Flow (IST)

```text
push main
  → GitHub Actions (self-hosted Runner auf projectmellon.de, Hetzner)
      ├ docker build openclaw + obsidian-sync
      ├ push beide → GHCR
      │   ghcr.io/momokli/openclaw-deploy / ghcr.io/momokli/openclaw-obsidian-sync
      └ POST https://deploy.openclaw.simonklimke.de/deploy   (Authorization: Bearer $DEPLOY_TOKEN)

.149: systemd-Timer alle 30min ODER sofort via Webhook
  → /opt/apps/openclaw/scripts/build-and-deploy.sh
      ├ git pull origin main
      ├ docker pull beide Images aus GHCR
      ├ Hash-Vergleich → skip wenn nichts neu
      ├ docker compose up -d --force-recreate --remove-orphans openclaw obsidian-sync
      ├ healthz-Check (fail-closed) → Caddy-Netzwerk reconnect → Hashes persistieren
```

## Zugriff

- `.149` via Tailscale: `ssh momo@lan` (= `100.85.52.13`; LAN-IP `192.168.178.149`).
- Deploy-Script: `/opt/apps/openclaw/scripts/build-and-deploy.sh`
- Webhook-Receiver: `scripts/webhook.py` (Port `18791`), systemd-Unit `openclaw-deploy-webhook.service`.
- Webhook startet `openclaw-build.service` → führt `build-and-deploy.sh` aus.

## Status prüfen

GitHub-Run (lokal, mit `GH_TOKEN`):

```bash
gh run list --branch main
gh run view <run-id> --log-failed
```

Auf `.149`:

```bash
ssh momo@lan 'docker ps --filter name=openclaw'
ssh momo@lan 'docker logs openclaw --tail 50'
ssh momo@lan 'docker logs openclaw-obsidian-sync --tail 50'
ssh momo@lan 'docker exec openclaw curl -sf http://localhost:18789/healthz'
```

Compose-Status (aus dem Deploy-Dir, Projektname ist fix `openclaw`):

```bash
ssh momo@lan 'cd /opt/apps/openclaw && docker compose ps'
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

1. **Build NICHT mehr lokal auf projectmellon.de** — läuft in GitHub Actions (`runs-on: self-hosted`). projectmellon.de ist nur der Runner.
2. **`.149` pullt NUR aus GHCR** — kein lokaler Build/Save-Load mehr.
3. Push nach GHCR nur auf `main`; PRs bauen nur, pushen nicht.
4. GHCR-Login nutzt `GHCR_TOKEN` (classic PAT, `write:packages`) — built-in `github.token` scheitert (`permission_denied: write_package`).
5. Webhook-Shared-Secret: `/opt/apps/openclaw/webhook-token` (NICHT in git); GitHub hält denselben Wert als Repo-Secret `DEPLOY_TOKEN`. HTTP 401 = Token-Mismatch.
6. Deploy-Skip basiert auf Hash-Files unter `/opt/apps/openclaw/`: `.deploy-git-hash`, `.deploy-img-hash`, `.deploy-obsidian-img-hash`. „No changes — skipping" heißt nur: alle drei gleich geblieben.
7. Healthz-Check ist **fail-closed**: wird der Container nicht healthy, werden die Hashes NICHT persistiert → nächster Run versucht erneut.
8. **Pages-Verifikation nur über die Build-Status-API** (Abschnitt „Pages-Deploy verifizieren"), nie per `sleep`/`curl | grep`. `pages/builds/latest` ist bis zum neuen Build der **alte**
   Build — ohne Baseline/`--commit` wäre ein nacktes „poll bis built" sofort grün (falsch).

## Stop-Regel

Deploy „hängt" oder „No changes" obwohl ein Change erwartet wird → NICHT blind Webhook re-triggern oder `docker compose up` variieren. Erst: (1) `gh run list` + Run-Log, (2) Hash-Files + Image-IDs auf `.149` vergleichen, (3) Webhook 401/Token prüfen. Unklar → Momo fragen.

Pages-Build `errored`/`cancelled` → NICHT weiter pollen. Ursache lesen:
`gh api repos/<owner>/<repo>/pages/builds/latest --jq '.error.message'` + betroffenen
Pages-Workflow-Run (`.github/workflows/*pages*`, `gh run list --workflow=…`), dann fixen und
neu auslösen.

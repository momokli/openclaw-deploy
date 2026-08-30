# GitHub App „momo-bot" — Setup & Migration vom persönlichen PAT

Dieses Dokument beschreibt, wie die GitHub-Auth des OpenClaw-Deployments vom
**persönlichen PAT** (momokli, Scopes `repo, workflow, write:packages`) auf eine
**GitHub App „momo-bot"** umgestellt wird.

**Warum?** Ein persönliches PAT ist an die Person gebunden, hat unnötig breite
Scopes und ist nicht widerrufbar, ohne den Account zu beeinträchtigen. Eine
GitHub App hat **minimale, pro-Repo-Permissions**, eine eigene Commit-Identität
(`momo-bot[bot]`) und Tokens, die nach **~1 Stunde** ablaufen.

> ⚠️ **Status:** Alles ist vorbereitet, aber **noch nicht aktiv**. Solange die
> `GH_APP_*`-Vars in `config/.env` leer sind, läuft das System unverändert mit
> dem PAT (`GH_TOKEN`). Erst nach der App-Erstellung (Schritt 1–5 unten) und
> Freigabe der offenen Fragen (siehe [PR-Body](#offene-fragen-an-momo)) wird
> umgestellt.

---

## Architektur (Zielbild)

```
momo-bot (GitHub App, Web-UI erstellt)
  ├─ Private Key  → ~/.secrets/momo-bot.pem (Host .149, chmod 600)
  │                  └─ per docker-compose gemountet (→ /home/node/.secrets/momo-bot.pem)
  ├─ App-ID + Installation-ID  → config/.env (GH_APP_ID, GH_APP_INSTALLATION_ID)
  │
  └─ Container-Start (entrypoint.sh Schritt 5c)
       └─ gh-app-auth.sh
            ├─ generate-github-token.sh: JWT (RS256, openssl) → POST
            │    /app/installations/{id}/access_tokens → frisches ~1h-Token
            ├─ hosts.yml wird mit frischem Token geschrieben (gh + git HTTPS)
            ├─ gh auth setup-git (Credential Helper)
            └─ openclaw.json (Runtime): skills.entries["gh-issues"].apiKey
                 bekommt das frische Token (Fallback der gh-issues-Skill)
Agent-Session: bei 401 (Token abgelaufen) → `gh-app-auth.sh` erneut ausführen
```

**Token-Lebensdauer:** Installation-Tokens laufen nach **~1h** ab. Deshalb gibt
es keinen persistierten Dauer-Token mehr (das alte hosts.yml-Modell mit dem PAT
entfällt). Stattdessen: frisches Token bei jedem Containerstart + On-Demand-
Refresh per `gh-app-auth.sh`. Ob zusätzlich ein **systemd-Timer** (alle 30 min)
das hosts.yml aktualisieren soll → **Offene Frage F1**.

---

## Schritt 1 — App registrieren (Web-UI, ~5 min)

Nur über die GitHub-Web-UI möglich (kein REST-Endpoint):

1. https://github.com/settings/apps/new öffnen (Account-Ebene, nicht Org)
2. **GitHub App name:** `momo-bot` (eindeutig; wird Teil der Commit-Identität)
3. **Homepage URL:** `https://github.com/momokli` (Pflichtfeld, egal was)
4. **Webhook:** deaktivieren („Active" abwählen) — wir brauchen keine Events
5. **Permissions** (Minimalprinzip):

   | Permission      | Access    | Warum |
   |-----------------|-----------|-------|
   | Contents        | **Read & write** | Repos klonen/pushen |
   | Pull requests   | **Read & write** | `gh pr create`, Reviews |
   | Issues          | *offen (F2)*    | gh-issues-Skill liest Issues |
   | Metadata        | **Read** (Pflicht, automatisch) | API-Basis |
   | alles andere    | No access | — |

6. **Where can this app be installed?** „Only on this account" (oder „Any
   account" — entscheidet F3)
7. **Create GitHub App** klicken

Danach auf der App-Seite (https://github.com/settings/apps/momo-bot):

- **App ID** notieren → kommt in `config/.env` als `GH_APP_ID`
- **Generate a private key** → lädt `momo-bot.<timestamp>.pem` herunter
  (wird **nur einmal** angezeigt!)

---

## Schritt 2 — Private Key sicher ablegen

```sh
# auf .149 (Deploy-Host), als momo:
mkdir -p ~/.secrets
mv ~/Downloads/momo-bot.*.pem ~/.secrets/momo-bot.pem
chmod 600 ~/.secrets/momo-bot.pem
# sanity check:
openssl rsa -in ~/.secrets/momo-bot.pem -check -noout
```

Dann in `docker-compose.yml` den auskommentierten Mount aktivieren:

```yaml
#      - ${HOME}/.secrets/momo-bot.pem:/home/node/.secrets/momo-bot.pem:ro
```

> ❗ Key wird nur einmal angezeigt. Verloren → neuen Key generieren (App-Seite)
> und alte PEM-Datei löschen.

---

## Schritt 3 — App auf Repos installieren

1. https://github.com/settings/apps/momo-bot → **Install App** (links)
2. Repo-Auswahl: **„Only select repositories"** — betroffene Repos:
   - `openclaw-deploy` (Pflicht — dieses Repo)
   - *offen (F4):* `momos-music-manager`, `mellon-minecraft`, `ftb-skies-2-aero` …
3. **Install** klicken

Die **Installation-ID** steckt in der URL der Installationsseite:
`https://github.com/settings/installations/<INSTALLATION_ID>` →
in `config/.env` als `GH_APP_INSTALLATION_ID`.

---

## Schritt 4 — IDs & Identität

| Was | Woher | Wohin |
|-----|-------|-------|
| App-ID | App-Seite → „App ID" | `GH_APP_ID` in `config/.env` |
| Installation-ID | URL `settings/installations/<id>` | `GH_APP_INSTALLATION_ID` |
| Private Key | Download (nur 1×) | `~/.secrets/momo-bot.pem` auf .149 |

**Commit-Identität** — der klassische Gotcha:

- Commits der App erscheinen als **`momo-bot[bot]`**.
- Die noreply-Email enthält die **BOT-USER-ID** (numerische ID des Bot-Accounts
  `momo-bot[bot]`) — **nicht** die App-ID!
- Ermittlung: `curl https://api.github.com/users/momo-bot%5Bbot%5D` → `.id`
- `gh-app-auth.sh --setup-git-identity` holt die ID automatisch und setzt:
  - `user.name = "momo-bot[bot]"`
  - `user.email = "<BOT_ID>+momo-bot[bot]@users.noreply.github.com"`

---

## Schritt 5 — Umstellung aktivieren

1. `config/.env` auf .149 ergänzen (via `ansible/deploy.yml` — Vars werden beim
   nächsten Playbook-Lauf aus der Umgebung übernommen):

   ```sh
   set -a; source .env; set +a   # GH_APP_ID, GH_APP_INSTALLATION_ID exportiert
   cd ansible && ansible-playbook -i inventory.ini deploy.yml
   ```

2. `docker compose up -d` (bzw. Deploy-Webhook/Timer) — entrypoint.sh Schritt 5c
   erkennt die App-Vars und seedet gh auth mit frischem Token.

3. Verifizieren:

   ```sh
   docker compose exec openclaw gh auth status          # momo-bot[bot]
   docker compose exec openclaw gh-app-auth.sh --print-token
   ```

4. `GH_TOKEN` (PAT) **erst entfernen, wenn alles grün ist** — Fallback bleibt
   bis dahin aktiv.

---

## Offene Fragen an Momo

Alle Entscheidungen, die Momo treffen muss, stehen im **PR-Body** des Migration-
PRs (`feat: GitHub-App momo-bot Auth statt PAT`) — dort direkt kommentieren:

- **F1** Token-Refresh: systemd-Timer (30 min) vs. nur pro-Session/on-demand?
- **F2** Issues-Permission für die App (die gh-issues-Skill-Automation liest Issues)?
- **F3** App-Installation: nur `openclaw-deploy` oder auch weitere Repos (F4)?
- **F4** Welche Repos genau? (`momos-music-manager`, `mellon-minecraft`, `ftb-skies-2-aero` …)
- **F5** SSH-Remotes (`git@github.com:...`) auf HTTPS umstellen?
- **F6** Private-Key-Handling: Bind-Mount (`~/.secrets`) OK, oder Base64 in .env?
- **F7** `read:org` nötig? (PAT zeigte Warnung; App-Tokens haben keine Org-Scopes)
- **F8** Commit-Identität global auf `momo-bot[bot]` umstellen oder nur openclaw-deploy?
- **F9** GHCR-Login (`GHCR_TOKEN` in Actions) ebenfalls auf App umstellen?

Nicht betroffen: `/lab` (sr.ht) liegt außerhalb des GitHub-Scopes. Historische
Commits bleiben unter der alten Identität (kein Rewrite).

---

## Troubleshooting

| Symptom | Ursache | Fix |
|---------|---------|-----|
| `gh auth status` → 401 | Token >1h alt | `gh-app-auth.sh` ausführen |
| `git push` → 403/404 | App nicht auf Repo installiert | Schritt 3, Repo hinzufügen |
| JWT-Fehler „Your token has expired" | iat/exp zu eng | Script nutzt iat−60s / exp 9min |
| `gh api user` → leere Login | Installations-Token | ok: hosts.yml nutzt `momo-bot[bot]` |
| Ansible-Assert schlägt fehl | weder PAT noch App-Vars | `GH_TOKEN` oder `GH_APP_ID`+`GH_APP_INSTALLATION_ID` setzen |

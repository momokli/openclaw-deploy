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
momo-clanker (GitHub App, Web-UI erstellt)
  ├─ Private Key  → ~/.secrets/<app-slug>.<datum>.private-key.pem (Host .149, chmod 600)
  │                  └─ generate-github-token.sh wählt die neueste *.pem automatisch
  ├─ App-ID + Installation-ID  → ~/.openclaw/.env (GH_APP_ID, GH_APP_INSTALLATION_ID)
  │
  └─ Gateway-Host (nativ)
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
entfällt). Stattdessen: frisches Token on-demand per `gh-app-auth.sh` (Mint-per-Call).
Ob zusätzlich ein **systemd-Timer** (alle 30 min) das hosts.yml aktualisieren soll → **Offene Frage F1**.

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
# GitHub lädt den Key als "<app-slug>.<datum>.private-key.pem" herunter.
# Umbenennen ist NICHT nötig: generate-github-token.sh wählt automatisch die
# neueste *.pem in ~/.secrets (Mount-Verzeichnis /home/node/.secrets).
chmod 600 ~/.secrets/*.pem
# sanity check (Dateinamen ggf. anpassen):
openssl rsa -in ~/.secrets/momo-clanker.2026-08-30.private-key.pem -check -noout
```

Dann den Key-Pfad in `~/.openclaw/.env` setzen (`GH_APP_PRIVATE_KEY_FILE`).

> ❗ Key wird nur einmal angezeigt. Verloren → neuen Key generieren (App-Seite)
> und alte PEM-Datei löschen. Bei Regenerierung entsteht eine neue Datei mit
> anderem Zeitstempel im Namen — der Mount bleibt dank Verzeichnis-Mount gültig.

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

1. `~/.openclaw/.env` auf .149 ergänzen (manuell oder per Code):

   ```sh
   # GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY_FILE setzen
   ```

2. `gh-app-auth.sh` ausführen (mintet frisches Token + seedet gh auth + openclaw.json-API-Key).

3. Verifizieren:

   ```sh
   gh auth status          # momo-bot[bot]
   gh-app-auth.sh --print-token
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
- **F9** entfällt (kein GHCR mehr).

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
| App-Auth greift nicht | weder PAT noch App-Vars | `GH_TOKEN` oder `GH_APP_ID`+`GH_APP_INSTALLATION_ID` setzen |

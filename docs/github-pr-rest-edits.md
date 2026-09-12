# GitHub-PR-Metadaten über REST (ohne `read:org`) — Issue #40

> **Standard:** PR-Metadaten (Body, Titel, Base, Labels, Kommentar) werden über die
> **REST-API** geändert (`gh api` bzw. `scripts/pr-metadata.sh`) — **nie** über
> `gh pr edit`. Hintergrund: Der Agent-/Deployment-Token hat nur
> `repo, workflow, write:packages`; die GraphQL-basierten `gh pr …`-Kommandos
> verlangen zusätzlich `read:org` und scheitern.

## Symptom

```
$ gh pr edit 5 --body-file body.md
GraphQL: Your token has not been granted the required scopes to execute this query.
The 'login' field requires one of the following scopes: ['read:org'], but your
token has only been granted the: ['repo', 'workflow', 'write:packages'] scopes.
```

Dasselbe Muster bei `gh pr view`/`gh pr list` (Felder `login`, `name`, `slug` →
`read:org` / `read:discussion`). Wiederholt beobachtet (2026-09-02 Aero-PR #5,
2026-09-12 verifiziert). Betrifft **jeden** Agent-/Prod-Token mit den aktuellen Scopes.

## Root Cause

`gh pr …` (und die `… edit`-Varianten von `gh issue …`) lösen im Hintergrund eine
**GraphQL**-Query ab, die den Viewer (`login`, `name`, `slug` von User/Org) mitliest.
Diese Felder erfordern `read:org`/`read:discussion`. Ohne diese Scopes scheitert die
gesamte Query — unabhängig davon, ob die eigentliche Änderung REST-fähig wäre.
`gh api` spricht dagegen **REST** und funktioniert mit `repo` allein.

## Regel (Standard)

1. **PR-Metadaten-Änderungen nur per REST:** `scripts/pr-metadata.sh` (bevorzugt) oder
   `gh api -X PATCH/POST/DELETE …` (Raw-Rezepte unten).
2. **`gh` bleibt erlaubt für:** `gh issue view/list`, `gh pr create`, `gh pr checks`,
   `gh pr diff`, `gh run …`, `gh api …`, `gh auth status`.
3. **Nicht verwenden:** `gh pr edit`, `gh pr view`, `gh pr list` (GraphQL → `read:org`).
   → Kein Scope-Gefummel, kein Ad-hoc-`curl`-Raten im Agent.

## Helper: `scripts/pr-metadata.sh`

```sh
# PR-Body aus Datei setzen + Read-back (der häufigste Fall):
scripts/pr-metadata.sh -n 87 -R momokli/openclaw-deploy --body-file /tmp/body.md --show

# Titel/Base ändern (PATCH /pulls/<n>):
scripts/pr-metadata.sh -n 87 --title "fix(#40): …" --base main

# Labels (POST/DELETE /issues/<n>/labels):
scripts/pr-metadata.sh -n 87 --add-label triage:merge --remove-label orchestrator:dispatched

# Kommentar posten (POST /issues/<n>/comments):
scripts/pr-metadata.sh -n 87 --comment-file /tmp/report.md
```

- Repo via `-R owner/repo`, sonst `$GH_REPO`, sonst aus `git remote origin` abgeleitet.
- Exit-Vertrag: `0` ok · `2` Usage/Argumente · `3` gh/API-Fehler.
- `--show` liest `number/title/state/base/body` zurück → Pflicht-Read-back nach Edits.

## Raw REST-Rezepte (ohne Helper)

```sh
R=owner/repo; N=87

# Body (Datei → JSON, korrekt gequotet, kein manuelles Escaping):
jq -Rs '{body: .}' body.md | gh api -X PATCH "repos/$R/pulls/$N" --input -

# Titel/Base:
jq -n '{title:"neu", base:"main"}' | gh api -X PATCH "repos/$R/pulls/$N" --input -

# Labels hinzufügen / entfernen (Issues-Endpunkt!):
jq -n '{labels:["triage:merge"]}' | gh api -X POST "repos/$R/issues/$N/labels" --input -
gh api -X DELETE "repos/$R/issues/$N/labels/$(jq -rn --arg s 'orchestrator:dispatched' '$s|@uri')"

# Kommentar:
jq -Rs '{body: .}' comment.md | gh api -X POST "repos/$R/issues/$N/comments" --input -

# Read-back:
gh api "repos/$R/pulls/$N" -q '.title, .body'
```

**`curl`-Variante** (wenn `gh` nicht verfügbar; Token nie in argv/Logs):
`curl -sf -X PATCH -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json"
--data @payload.json "https://api.github.com/repos/$R/pulls/$N"`.

## Pitfalls

- **`-X` nicht vergessen:** `gh api` ist per Default `GET`; Mutationen brauchen
  `-X PATCH|POST|DELETE`.
- **`--input -` statt `-f`:** JSON mit `jq` bauen und über stdin geben — vermeidet
  Quoting-/Escaping-Fehler bei mehrzeiligen Bodies.
- **Labels liegen am Issues-Endpunkt** (`/issues/<n>/labels`), nicht unter `/pulls`.
- **Label-Namen URL-encoden** (`:` → `%3A`), z. B. mit `jq -rn '$s|@uri'`.
- **Shell kann `sh`/dash sein:** keine Prozess-Substitution `<(...)`, kein
  `${PIPESTATUS[0]}` — Datei/`--input -` nutzen.
- **Re-Trigger:** ein `PR edited`-Event startet `pull_request`-Workflows neu → Checks
  gehen kurz auf `pending`/`BLOCKED`, dann `CLEAN`.
- **`gh pr create` funktioniert** (kein Viewer-Resolve) — nur `pr edit/view/list` fallen um.
- **Token niemals ausgeben/echoen** (kein `env | grep GH_TOKEN`, keine Token-in-argv).

## Token-Scope-Alternative (nicht der Standard)

`read:org` (+ `read:discussion`) würde `gh pr edit` reaktivieren:
`gh auth refresh -h github.com -s read:org,read:discussion` (interaktiv) bzw. neuer PAT.
Für Prod hieße das eine Token-Rotation in `config/.env` auf `.149` (Momo-Approval, Secret).
**Bewusst nicht gewählt** — REST deckt alle Fälle ohne Scope-/Secret-Änderung ab.

## Verifikation

- Offline: `bash tests/pr-metadata/run.sh` (gh-PATH-Shim, 14 Tests, red-before-green).
- Live (REST ohne `read:org`):
  `scripts/pr-metadata.sh -n <PR> -R momokli/openclaw-deploy --body-file <f> --show`
  → Body sichtbar im Read-back.
- Gegenprobe: `gh pr view <PR>` liefert weiterhin den `read:org`-GraphQL-Fehler.

## DoD (Issue #40)

`gh pr edit` muss **nicht** funktionieren — der REST-Weg ist der dokumentierte Standard
(dieses Runbook + `scripts/pr-metadata.sh`): kein Ad-hoc-Raten im Agent mehr.

## Rollback

Reine Neu-Dateien (`scripts/pr-metadata.sh`, `tests/pr-metadata/run.sh`,
dieses Runbook) + ein Status-Entry in `docs/equip-agents.md` (B2) →
`git revert <sha>`. Kein Prod-Pfad (Dockerfile/entrypoint/config/ansible/compose) berührt.

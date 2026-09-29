# CI-Läufe nachholen (Re-Run / Dispatch) — wer darf was?

> Problem: Die Bot-Identity `momo-clanker[bot]` kann **keine** GitHub-Actions-Läufe
> re-triggern — `gh run rerun` und `gh workflow run` antworten mit
> `HTTP 403: Resource not accessible by integration`. Stand: 2026-09-16,
> Issue #107. Dieses Runbook benennt **funktionierende** Pfade und ersetzt die
> frühere Annahme, der Dispatch sei ein Bot-Notausgang.

## Symptom

```sh
clanker-gh run rerun 35058976999 --failed --repo momokli/riftbreaker-battle-mod
# HTTP 403: Resource not accessible by integration

clanker-gh workflow run Boot-Test --ref feature/520-pause-dom-native --repo momokli/riftbreaker-battle-mod
# HTTP 403: Resource not accessible by integration (.../actions/workflows/<id>/dispatches)
```

## Root Cause

Die Installation der App `momo-clanker` hat kein **`Actions: write`**. Gesperrt
sind damit für die App-Identity:

- `POST /repos/{owner}/{repo}/actions/runs/{id}/rerun-failed-jobs`
  (`gh run rerun --failed`)
- `POST /repos/{owner}/{repo}/actions/workflows/{id}/dispatches`
  (`gh workflow run`)

Beide Endpunkte verlangen `Actions: write`; `Actions: read` reicht nicht.

**Grundsatz-Entscheidung (Issue #107):** Der Fix hängt **nicht** an einer
App-Permission-Änderung. Der nachfolgende Bot-/Operator-Pfad funktioniert
unabhängig davon, ob `Actions: write` später ergänzt wird.

## Pfade, die tatsächlich funktionieren

### 1. Bot / Orchestrator (nur `Contents: write`, kein `Actions: write`)

Ein Lauf entsteht über das `pull_request`-Event, das auf **Push** in den
PR-Branch feuert. Ein leerer Commit genügt:

```sh
clanker-git commit --allow-empty -m "ci: retrigger <workflow> (empty commit)"
clanker-git push
```

- Erzeugt einen neuen `synchronize`-Lauf für alle `pull_request`-Workflows des
  Branches.
- **Bedingung:** Der PR ist **konfliktfrei**. GitHub legt für `pull_request`-
  Events bei Merge-Konflikt **gar keinen** Lauf an (riftbreaker-battle-mod#443,
  neue Instanz #532) — der Leer-Commit ist dann wirkungslos.

### 2. Konflikthafter PR (kein `pull_request`-Lauf möglich)

Erst den Konflikt lösen (Base in den Branch mergen, Verfahren:
Skill `pr-branch-conflict-rework`), pushen. Mit dem Konflikt-freien Push entsteht
der Lauf.

### 3. Operator / Mensch (mit `Actions: write`)

Der Repo-Owner bzw. ein Token mit `Actions: write` kann direkt re-triggern:

```sh
# GitHub-UI: Actions -> Workflow wählen -> "Run workflow" (workflow_dispatch)
gh workflow run boot-test.yml --ref <branches> --repo momokli/riftbreaker-battle-mod
gh run rerun <run-id> --failed --repo momokli/riftbreaker-battle-mod
```

Das ist der einzige Pfad, der `workflow_dispatch`-Trigger nutzt. Er benötigt ein
**Operator-Token** (nicht die App-Identity `momo-clanker`).

### 4. `Actions: write` doch ergänzen (optional, nicht Voraussetzung)

Installation der App `momo-clanker` um `Actions: write` erweitern. Dann werden
Pfad 3 auch für die Bot-Identity nutzbar. **Kein Blocker** für Pfad 1/2 — bis
dahin gilt: Bot re-triggert über Leer-Commit, Dispatch bleibt Operator-Pfad.

## Entmystifiziert: der „Dispatch-Notausgang"

Die Workflows `boot-test.yml`, `deploy-check.yml`, `deploy.yml` und
`progress.yml` in `momokli/riftbreaker-battle-mod` tragen `workflow_dispatch`.
Für die **App-Identity** ist dieser Trigger **nicht** nutzbar (403, Root Cause
oben). Die Doku dort wurde entsprechend korrigiert (riftbreaker-battle-mod PR,
`Refs #107`).

## Abgrenzung

- Dieses Runbook betrifft das **Re-Triggering** von Läufen. Ob ein Lauf grün ist,
  ist davon unabhängig.
- Ein Required-Check, der auf `cancelled`/`Expected` hängt, ist ein **separates**
  Symptom (siehe `boot-test.yml`-Concurrency-Kommentar zu `queue: max`).

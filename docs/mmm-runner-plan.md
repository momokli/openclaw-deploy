# MMM-Runner — Triage + PR-Gate für `momokli/momos-music-manager`

Stand: 2026-10-01. Status: **LIVE** — die Pipeline läuft.

## Betriebsstand (01.10.)

| Teil                           | Zustand                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Engine auf `planet`            | `~/.local/bin/runner-*.sh` + `runner-profiles/{rift,mmm}.conf` (via `scripts/install-runner-engine.sh`) |
| Automations                    | `rift-triage/-pr-gate` (+Ticks), **`mmm-triage/-pr-gate` (+Ticks)** — alle aktiv                        |
| Branch-Protection `main` (MMM) | Required: `Build + Test (cargo)`, `Conventional-Commit-Titel`, `Issue-Referenz im PR`; `strict`         |
| Release                        | `v1.13.0` (12 Assets, signiert) = `latest`; `latest-main` rollt bei jedem `main`-Push                   |
| MacBook-Instanz                | Kanal `rolling`, **Auto-Update an** → zieht jeden `main`-Build                                          |
| Fokus                          | MMM `1.14.0` (freigegeben), Rift `1.0.18`                                                               |

**Der Kreislauf:** Fokus-Milestone + Issues kuratieren → Tick (5 min) dispatcht das erste Leaf →
7-Stage-Pipeline baut einen PR gegen `main` → Gate reviewt und mergt bei APPROVE + CLEAN +
grünen Checks → `publish` aktualisiert `latest-main` → die MacBook-Instanz zieht es im
Auto-Update-Intervall (4 h).

**Bug beim ersten Live-Lauf gefunden und behoben:** Der Triage-**Agent-Turn** ruft die Engine auf,
erbt aber kein Profil vom Tick — `runner-focus-milestone.sh` fiel auf sein Default-Profil `rift`
zurück und meldete `1.0.18` statt `1.14.0`. Es lief nur gut, weil das Decision-File Vorrang hat.
Die Prompts setzen jetzt explizit `RUNNER_PROFILE=<profil>`.

**Zweiter Befund:** `openclaw automations create` legt neue Jobs **enabled** an — der alte
Kommentar „Converge aktiviert nicht" stimmte nur für bestehende Jobs (der `edit`-Pfad fasst
`enabled` nicht an). Kommentar im Skript korrigiert.

---

Überträgt das `rift-*`-Runner-Setup (Triage A + PR-Gate B, zweistufig, Reconciler)
auf Momo's Music Manager. Methodik unverändert: `docs/milestone-methodology.md`,
Architektur: `docs/runner-architektur.md`, Betrieb: `docs/automations.md`.

## Beschlüsse (2026-10-01)

1. **Merge-Modell = Rift-Modell.** 1 Issue = 1 Branch = 1 PR gegen `main`,
   squash-merge. `review/all-features` wird stillgelegt.
2. **CI voller Umfang.** Leichtes PR-CI + `pr-quality.yml` (Conventional-Commit +
   Closing-Keyword) + Branch-Protection auf `main` → der Gate hat echte Required-Checks.
3. **Ein Runner pro Projekt, ein gemeinsamer Motor.** Runner-_Instanzen_
   (Automation-Job, Prompt, State-Files, Trigger-Key, enable/disable) sind pro Repo
   getrennt; die `runner-*.sh`-Engine ist repo-parametrisch (Profil).

## Trennung (verbindlich)

|                       | Rift                                         | MMM                                       |
| --------------------- | -------------------------------------------- | ----------------------------------------- |
| Automations           | `rift-triage`, `rift-pr-gate`, `rift-*-tick` | `mmm-triage`, `mmm-pr-gate`, `mmm-*-tick` |
| declarationKey        | `rift-*:main`                                | `mmm-*:main`                              |
| Schedules / enable    | eigen                                        | eigen                                     |
| Session pro Lauf      | isoliert                                     | isoliert                                  |
| State-/Decision-Files | `rift-*-*.md`                                | `mmm-*-*.md`                              |
| Prompts               | `config/automations/rift-*.prompt.md`        | `config/automations/mmm-*.prompt.md`      |
| Profil                | `config/runners/rift.conf`                   | `config/runners/mmm.conf`                 |

Geteilt ist **nur** die Engine (`scripts/runner-*.sh`, `scripts/runner-profile.sh`).
Ein Engine-Bug betrifft beide Runner — dafür wird er einmal getestet und einmal
gefixt, statt in zwei driftenden Kopien.

## Phasen

### Phase 1 — Engine generalisieren ✅ (2026-10-01)

- `config/runners/{rift,mmm}.conf` — Profil je Repo (Default-Werte, Env gewinnt).
- `scripts/runner-profile.sh` — Profil-Auflösung (Env-File/Dir, installiert, Repo-Layout).
- Engine `rift-*.sh` → `runner-*.sh`; `rift-*.sh` bleibt als Kompatibilitäts-Shim
  (die laufenden `--command`-Payloads rufen die Bare-Namen auf).
- Repo-spezifisch aus dem Profil: Repo, Bot-Wrapper, Trigger-/Declaration-Keys,
  State-Präfix (Decision-/Marker-/Status-Namen), Hold-/Ausschluss-Labels
  (`needs:player-test` ↔ `needs:manual-test`), `[Release]`-Tracking-Issue (rift 1 / mmm 0),
  Worker-Agenten, Release-Hinweis (Abnahme/Testplan), Log-Ziel.
- `scripts/automations-apply.sh` verwaltet jetzt **auch die Ticks** (`--command`,
  `--command-env RUNNER_PROFILE=…`) und iteriert über die Profile; ohne Prompt wird ein
  Profil übersprungen, ohne installierte Engine werden die Ticks nicht umgebogen.
- `scripts/setup-native.sh` installiert Engine + Shims + Profile nach `~/.local/bin`.
- Tests: 5 Harnesse auf `tests/runner-*` umbenannt (29/58/84/44/17 grün), plus
  `tests/runner-profile/run.sh` (17/17: Auflösung, Env-gewinnt, fail-closed, kein Cross-Repo-Leak)
  und `tests/automations-apply/run.sh` (24/24: angelegte Jobs, `RUNNER_PROFILE` je Tick, kein
  Enable, Ticks bleiben unangetastet ohne installierte Engine).
- Verifiziert gegen die echte Instanz: `RUNNER_PROFILE=mmm runner-focus-milestone.sh` →
  `1.14.0` (approved), `1.15.0`–`1.18.0` gesperrt; `RUNNER_PROFILE=rift` → `1.0.16` (Regression ok).

**Deploy-Reihenfolge (wichtig):** erst `setup-native.sh` (installiert die Engine), dann
`automations-apply.sh`. Andersherum würden die Ticks auf ein noch fehlendes Skript zeigen.

### Phase 2 — Prompts + Automations ✅ (2026-10-01)

- `config/automations/mmm-triage.prompt.md`, `mmm-pr-gate.prompt.md` — Repo, Bot-Wrapper,
  `needs:manual-test`, Decision-Files, `Closes #<n>`-Pflicht, Builds auf `planet`;
  der Release-Modus baut den PR im MMM-Format (Keep a Changelog + `Cargo.toml`/`site`-Bump,
  Tag bleibt Mensch), **kein** `[Release]`-Issue und kein `prod`-Environment.
- **fail-closed nachgezogen:** der PR-Gate-Tick mergt nicht mehr, wenn **null** Check-Runs
  vorliegen (jq's `all` ist auf einem leeren Array `true` — ohne den Count-Guard hätte ein Repo
  ohne PR-CI auf APPROVE + CLEAN blind gemergt). Gilt für rift und mmm.

### Phase 3 — CI-Gate (im MMM-Repo) — vorbereitet, **grün**

**Zwei PRs im MMM-Repo** (+ Tracking-Issues **#85**/#87):

| PR                                          | Basis                        | Inhalt                                | Checks                                    |
| ------------------------------------------- | ---------------------------- | ------------------------------------- | ----------------------------------------- |
| **#88** `fix/flaky-scan-sources-guard-test` | `ci/pr-gate-required-checks` | die flaky Guard-Tests deterministisch | ✅ alle grün                              |
| **#86** `ci/pr-gate-required-checks`        | `main`                       | CI-Infra                              | ⚠️ `Build + Test` rot bis #88 gemergt ist |

**Merge-Reihenfolge (Stack): #88 → #86 → `main`. Erst danach** Branch-Protection +
`enable`. #86 wird durch #88 grün; dessen roter `Build + Test` ist erwartet.

Inhalt von #86:

- `ci-pr.yml` — Job `Build + Test (cargo)` (`cargo build --locked` + `cargo test --locked`,
  mit `flac`/`ffmpeg`/`exiftool`); `fmt`/`clippy` **informativ** (step-level
  `continue-on-error`, damit sie nicht als _failed check_ erscheinen). Bewusst **ohne**
  `branches`-Filter — sonst liefe die CI auf gestackten PRs nicht.
- `pr-quality.yml` — `Conventional-Commit-Titel` + `Issue-Referenz im PR`.
- `build-all.yml` — PR-Trigger auf Packaging-Pfade gefiltert.
- `AGENT.md` — „1 Issue = 1 Branch = 1 PR gegen `main`“, Release-PR + Tag.

**Der Flaky-Befund (behoben in #88):** _vier_ Tests (`folders_scan_sources_*` +
`storage_{backup,backup_wavs,discover_backup}_rejects_concurrent`) feuerten zwei parallele
HTTP-Requests und erwarteten, dass einer abgewiesen wird — das gilt nur, solange der erste
Task noch `Pending`/`Running` ist; auf dem CI-Runner war er längst `Completed`. Der Guard
(`tasks::start_task_unique`) ist **atomar**, also kein Produktionsbug. Jetzt: Unit-Test für den
Guard (deterministisch), HTTP-Tests prüfen nur noch das Handler-Mapping über einen
handregistrierten Task (`spawn_test_app_with_state`).

**Branch-Protection — erst nach grünem `Build + Test` (nicht ausgeführt):**

```sh
gh api -X PUT repos/momokli/momos-music-manager/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build + Test (cargo)", "Conventional-Commit-Titel", "Issue-Referenz im PR"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

Erst danach die vier MMM-Runner `enable`n.

### Phase 4 — Release-PR (MMM-Variante)

- Eigener Release-Prompt: Branch `release/<version>`, CHANGELOG-Abschnitt im
  **Keep-a-Changelog**-Stil (bestehendes MMM-Format), `Cargo.toml` +
  `site/index.html`-Bump, Label `release:human-merge`, **nie** automergen.
- Kein `[Release]`-Tracking-Issue, kein `prod`-Environment, kein Factorio-Format.
- Merge + Tag-Push (`v*` → GitHub-Release → Autoupdater) bleiben Menschenschritte.

### Phase 5 — Divergenz lokaler Stand ↔ GitHub ⚠️ (aufgenommen 01.10.)

**Befund:** `github/main` steht auf `f66feb3` (v1.12.0, `#48`); der lokale `main` ist **44 Commits**
weiter und trägt den **v1.13.0**-Stand — nie gepusht. `review/all-features` = lokaler `main` + 7.

|                         |                                                                         |
| ----------------------- | ----------------------------------------------------------------------- |
| Fast-Forward?           | **ja** — `github/main` ist Vorfahr von `main` (`main..github/main` = 0) |
| Lokale Tags ohne Remote | **11**, darunter `v1.13.0` (remote endet bei `v1.12.0`)                 |
| `review/all-features`   | lokaler `main` + 7 Commits = aktueller `[Unreleased]`-Batch             |

**Aufgenommen als:** PR **#90** (`land/v1.13.0`, Draft, Base `main`) schließt Issue **#89**.
Der Branch zeigt auf exakt `dcdc23c` (identische SHA wie lokales `main`) — reiner Fast-Forward.
Enthält die 44 Commits, **nicht** die 7 `review/all-features`-Commits und **keine** Tags.

### `review/all-features` zerlegt (01.10.)

Die 7 Commits lagen nur auf der Branch. Sie sind in drei reviewbare PRs zerlegt —
**inhaltlich verifiziert** (A bit-identisch zum Original; B nur um die Junk-Entfernung
und `.gitignore` verändert; C identisch):

| PR      | Branch                       | Basis                      | Closes | Umfang                          |
| ------- | ---------------------------- | -------------------------- | ------ | ------------------------------- |
| **#94** | `feat/files-backpack-page`   | `land/v1.13.0`             | #91    | 7 Dateien, +753/−16             |
| **#95** | `fix/tags-playlists-hygiene` | `feat/files-backpack-page` | #92    | 3 Commits, 15 Dateien, +470/−48 |
| **#96** | `docs/rediscovery-plans`     | `land/v1.13.0`             | #93    | 3 Dateien, +807/−1              |

**Warum nicht 7 Einzel-PRs:** der Stapel ist **kumulativ** — die späteren Commits bauen auf
Fixtures der früheren auf (gleiche Dateien: `src/api/files.rs`, `tests/api_files.rs`,
`CHANGELOG.md`, `docs/DECISIONS.md`). Einzel-Cherry-Picks auf den Basisstand kollidieren
daher; nur ein 4-fach gestapelter Satz wäre möglich, ohne Review-Vorteil. Die drei Doku-Commits
sind dagegen unabhängig (`plans/` only) und deshalb separat.

**Fund beim Zerlegen:** `a9c64c8` hatte **`tests/api_files.rs.dbgbak`** mitcommittet — eine
2.845-zeilige Kopie von `tests/api_files.rs` (Cargo entdeckt sie nicht als Test, sie gehörte
aber nie ins Repo). In #95 ist sie **nicht enthalten**; `*.dbgbak` steht jetzt in `.gitignore`.
Damit erreicht sie `main` nie.

### Gesamte Reihenfolge (verbindlich)

1. **#88** in `ci/pr-gate-required-checks` mergen (Test-Fix; macht #86 grün).
2. **#86** nach `main` (CI-Infra).
3. **#90** nach `main` — jetzt prüft `Build + Test` die 44 Commits. Danach ist `main` die Wahrheit.
   **Mit `--delete-branch` mergen** (`land/v1.13.0` löschen), dann retargetet GitHub #94/#96
   automatisch von `land/v1.13.0` auf `main`; sonst die Basen manuell umstellen
   (`gh pr edit <n> --base main`).
4. **Tags pushen** (`v1.13.0` + die 10 fehlenden alten) — eigener, bewusster Schritt:
   ein Tag-Push auf `v*` löst `build-all.yml` **und** den Release-Publish aus.
5. **`review/all-features` auflösen:** #94 → #95 (Stack: #95s Basis ist #94s Branch, GitHub
   retargetet nach dem Merge automatisch) und #96; danach die Branch stilllegen.
6. **Branch-Protection** auf `main` (Befehl oben) und die vier MMM-Runner `enable`n.

Erst danach arbeitet die Triage gegen einen `main`, der zur lokalen Realität passt.

### Später

- Dieselben Offline-Harnesse laufen zusätzlich mit dem `mmm`-Fixture-Profil.
- Doku: `docs/automations.md`, `milestone-methodology.md`, `runner-architektur.md`,
  `README.md`, `AGENTS.md`.

## Verifikation

1. `RUNNER_PROFILE=mmm runner-focus-milestone.sh --json` → `1.14.0`.
2. Ticks im Dry-Run (`RIFT_TICK_DRY=1`) gegen MMM → Decision-File nennt #56.
3. `openclaw automations list` zeigt 4 neue Jobs; enable erst danach.
4. Smoke: #56 dispatchen → PR gegen `main` → Review → Merge → Slot frei.

## Risiken

- **Divergenz lokal ↔ GitHub (Phase 5):** lokaler `main` 44 Commits vor `github/main`,
  11 Tags (u. a. `v1.13.0`) nur lokal. Aufgenommen als PR #90 / Issue #89; Reihenfolge oben.
- **Tag-Push ist ein Publish-Trigger:** `v*` startet `build-all.yml` + Release-Assets +
  Rolling-Cleanup — nie beiläufig pushen.
- **Rust/Planet:** ~1.100 Tests; Orchestrator-Turns müssen auf `planet` laufen
  (`tools.exec.node`). Clone-Ziel `~/repos/momos-music-manager`.
- **`claimed` ohne Verfall** in MMM (kein `issue-claim.yml`).
- Die `rift-*`-Agent-Turns stehen live auf `error` — vor dem Scharfschalten klären.

# Runner-Hardening (2026-11-17)

Drei Fehlschläge aus der Nacht vom 16.11. auf `momokli/momos-music-manager`, ihre
belegten Ursachen und was dagegen gebaut ist. Alle Zahlen sind aus den Logs bzw.
der GitHub-API, nicht aus der Erinnerung.

## 1. Merge auf einem nie reviewten Commit

**Beobachtung.** `momo-claw[bot]` gab um 19:57:25Z `[VERDICT: APPROVE]` für PR #516
auf Commit `7781258`. Ein Mensch push-te danach `c0e78c8` (änderte die Semantik des
Features). Um 20:05:43Z squashte der Tick die Änderung — Inhalt: `c0e78c8`.

**Ursache.** `runner-pr-gate-tick.sh` prüfte nur `Verdict-Präfix + CLEAN + alle Checks
grün`. `head_at` wurde berechnet, aber ausschließlich für den REQUEST_CHANGES-Cooldown
benutzt. Ein `headRefOid` kam im Merge-Pfad nicht vor; das Verdict trug keine
Commit-ID. „decision base is binding" (`d182deb`) meint etwas anderes: den
Basis-Branch eines Release-Stacks.

**Fix.** Das Verdict trägt die reviewte SHA (`[VERDICT: APPROVE] 7781258`), der Tick
vergleicht sie mit `headRefOid`. Mismatch oder fehlende SHA ⇒ **kein Merge**, der PR
geht zurück ins Review (fail-closed). Tests: `tests/runner-pr-gate-tick/run.sh`
(Head gewechselt, Alt-Verdict ohne SHA).

## 2. Milestone mit offenen Issues geschlossen

**Beobachtung.** 20:54:02Z wurde `chore(release): v0.5.0` gemergt, 20:54:12Z war
Milestone #44 `music-api-0.5.0` geschlossen — mit `open_issues: 3` (#512/#513/#518).
Danach meldete `runner-focus-milestone.sh` „kein freigegebener Milestone mit Arbeit"
und beide Runner standen still.

**Ursache.** Nicht der deterministische Cleanup (`runner-close-milestones.sh` filtert
korrekt auf `open_issues == 0` **und** nicht-freigegeben), sondern der pr-gate-Prompt:
„Danach den Milestone schließen" — zweimal, bedingungslos.

**Fix.** Neues `scripts/runner-close-milestone.sh <nr>`: verweigert das Schließen bei
offenen Leaf-Issues oder einem offenen, ungemergten PR. Geparkte Reste (HOLD-Labels,
Epics) blockieren nicht, werden aber protokolliert — sonst bliebe ein Milestone mit
einem einzigen `question`-Issue ewig offen und würde die Queue verstopfen. Der Prompt
ruft jetzt dieses Skript statt eines blanken `PATCH state=closed`.
Tests: `tests/runner-close-milestone/run.sh`.

## 3. Stale-Guard übersieht offene Arbeit

**Beobachtung.** 20:30:08Z wurde PR #517 eröffnet, 20:35:18Z meldete der Guard „kein
verlinkter offener PR" und gab #511 zum Re-Dispatch frei. Um 20:41:56Z wurde #517
gemergt.

**Ursache (teilweise belegt).** Der Link-Scan las `headRefName` und `body`, **nie
`title`**. Im Harness ist damit genau die gemeldete Zeile reproduzierbar (mit
`Closes #N` nur im Titel: alter Code → `REDISPATCH`, Kommentar, Label-Mutation; neuer
Code → `SKIP linked-pr-open`). **Nicht belegt** ist, dass das der Auslöser war: bei
#517 begann der Body mit `Closes #511`, das alte Muster hätte greifen müssen. Die
Marker-Zeile bündelt fünf Bedingungen; welche davon wirklich feuerte, ist offen.
Deshalb protokolliert der Guard ab jetzt `EVIDENCE <nr> prs_open=… linked=… xref=… worker=… age=…`.

**Fix.** Titel wird mitgescannt (beide Skripte, gleiche Semantik), und
`runner-triage-cleanup.sh` ist bei einem `gh pr list`-Fehler **fail-closed**
(`exit 2`) statt `PRS='[]'` — ein API-Fehler darf nicht als „keine offenen PRs" gelten.
Tests: `tests/runner-stale-dispatch/run.sh` (Titel-Variante, rot vor dem Fix),
`tests/runner-triage-cleanup/run.sh`.

## 4. Deploy-Drift (Nebenbefund)

`runner-close-milestones.sh` lief auf dem Host in der Version **vor** `bd3cf3a`
(Hash `662e8e4` vs. Repo `05cd249`); die anderen drei Skripte waren identisch. Grund:
die Datei stand nicht in der Install-Liste von `install-runner-engine.sh` — sie wurde
irgendwann von Hand kopiert und danach nie wieder.

**Fix.** Eine `ENGINE_FILES`-Liste ist jetzt die Wahrheit für Installation und
Drift-Check; `RUNNER_DRIFT_CHECK=1 bash scripts/install-runner-engine.sh` meldet
`DRIFT`/`MISSING` ohne zu installieren; jede Installation schreibt
`~/.local/bin/.runner-manifest` (sha256 + Repo-Commit).

## Offen

- `tests/runner-focus-milestone/run.sh`: **7 Fehler** (Run-ahead-Fälle erwarten 1.0.4,
  bekommen 1.0.3). Bestehen schon vor diesen Änderungen — nicht angefasst, aber es
  könnte heißen, dass Run-ahead nicht greift.
- Ursache von #3 im echten Lauf bleibt unbelegt; die `EVIDENCE`-Zeile macht den
  nächsten Fall entscheidbar.

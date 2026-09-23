# Milestone-Methodik — Fokus-Iterationen für die `rift-*`-Runner

Stand: 2026-09-23. Source-of-Truth: dieses Repo.

**Status:** Die Fokus-Regel ist noch **nicht live**. `config/automations/*.prompt.md` und
`scripts/automations-apply.sh` arbeiten derzeit mit einem fest gesetzten `RIFT_MILESTONE`
(= `1.0`). Dieses Dokument beschreibt den Zielzustand; die Umsetzung (Fokus-Script +
Prompt-Diff) ist der nächste Schritt.

## Idee

Nicht „die Automatik arbeitet Issues ab", sondern: **du kuratierst eine Iteration, die
Automatik arbeitet sie ab.** Der Milestone ist gleichzeitig Arbeitspaket und Freigabe.
Es gibt immer genau **einen** Fokus-Milestone.

## 1 · Fokus-Regel (Runtime, kein Deploy)

Fokus = **kleinster offener Milestone, dessen Titel eine Versionsform ist** (`^1\.`).

- `1.0.1` < `1.1` < `1.2` … → numerisch sortiert, **nicht** nach Milestone-Nummer.
- Ein Parkplatz wie `soon` fällt raus, weil sein Titel keine Version ist.
- **Den Fokus wechselst du, indem du den Fokus-Milestone schließt.** Kein Redeploy, kein
  Repo-Eingriff — der Fortschritt ist der Schalter.
- Ermittelt wird das pro Lauf von `scripts/rift-focus-milestone.sh` (deterministisch,
  offline testbar — Muster wie `rift-stale-dispatch.sh`). Der Prompt enthält danach keinen
  Milestone-Namen mehr, sondern nur den Aufruf.

Damit gilt: **immer genau ein Fokus** (der kleinste). Größere Milestones liegen offen
daneben und sind automatisch inaktiv.

## 2 · Struktur je Iteration

- **Ein Epic-Issue** (`[Epic] …`) trägt das Zielbild und die geordnete Sub-Issue-Liste.
- **Sub-Issues sind klein:** ein abgegrenztes Stück, Akzeptanzkriterien, ein PR.
- Nur **Leaf-Issues** werden dispatcht. Wer Sub-Issues hat, ist ein Epic → nie Dispatch.

Die Reihenfolge ist die Checkliste im Epic (oben → unten). Das ist die Kurations-Hand
des Menschen.

## 3 · Gate der Triage (was dispatcht wird)

Dispatcht wird nur, wenn **alle** Punkte zutreffen:

1. Issue liegt im Fokus-Milestone.
2. Es ist ein **Leaf** — kein Epic, keine Checkliste, kein „Umbrella"/„Sammel"-Issue.
3. Kein Ausschluss-Marker: `claimed` (Mensch dran), `needs:player-test`, `follow-up`,
   `hold`, Interview/Design (`question`), und Spikes nur mit explizitem Go.
4. Der **Slot ist frei** (siehe 4).

Alles andere wird nur im Status-Log geführt („awaiting human" / „awaiting slot").

### Veralteter Dispatch (Issue längst erledigt)

Der Milestone-Filter ist grob: ein Issue kann fertig sein und trotzdem im Fokus-Milestone
liegen (Beispiel **#337** — der Fix-PR #343 war seit dem 13.09. gemergt). Dann dispatcht die
Triage ins Leere, und weil der Worker `done` meldet, blockiert der Slot dauerhaft
(WIP = 1) — der Stale-Guard greift bewusst nicht, ein `done`-Run gilt als gesund.

Deshalb ein expliziter Pfad:

1. **Der Worker prüft zuerst** (~2 Minuten): gibt es einen gemergten PR, dessen Commits in
   `main` sind, und ist der geforderte Check grün? Wenn ja: Kommentar auf dem Issue, dessen
   **ERSTE Zeile `[ALREADY-DONE]`** ist, mit Beleg (PR-Nr., Merge-Commit, Check-Status) —
   **kein** Branch, **kein** PR, keine Pipeline-Stages.
2. **Die Triage räumt auf:** Issues im Fokus-Milestone mit `orchestrator:dispatched`, deren
   letzter Kommentar mit `[ALREADY-DONE]` beginnt, werden geschlossen + Label entfernt.
   Das zählt **nicht** als Slot-Belegung — der Lauf dispatcht danach normal den nächsten
   Kandidaten.

Das ist der Ersatz für perfekte Kuration: die Pipeline erkennt ihren eigenen Irrtum und
räumt ihn auf, statt stehen zu bleiben.

## 4 · Slot: ein Worker, ein PR-Stack

- **WIP = 1 Worker.** Immer höchstens ein Task gleichzeitig: kein Kollidieren, `planet`
  wird nicht überfahren, und ein Task ist einzeln messbar.
- **Stacktiefe ≤ 3.** Ein Worker, aber bis zu drei offene PRs — damit der Worker nie aufs
  Review warten muss.
- **Unabhängige Issues → Basis `main`.** Unabhängig mergebar, keine Kopplung.
- **Abhängige Issues** (im Issue als `Depends on #n` deklariert) → Basis = Branch von #n;
  so bildet sich ein Stack.

### Stack-Regeln (hart)

| Regel                                                                                        | Warum                                                                        |
| -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Basis = Branch des Vorgängers, **nicht** `main`                                              | der PR zeigt nur seinen eigenen Diff                                         |
| Merge **FIFO**: nur der unterste ungemergte PR ist merge-fähig                               | sonst zerfällt die Kette                                                     |
| Nach jedem Merge: `git rebase --onto main <alter-base-head> <branch>` + `--force-with-lease` | **nicht** `gh pr update-branch` — sonst zeigt der PR wieder den ganzen Stack |
| Stirbt ein unterer PR → alle oberen neu auf `main` basen                                     | sonst hängen sie an einer Leiche                                             |

`--delete-branch` beim Merge ist Voraussetzung: GitHub retargetet die darüberliegenden PRs
dann automatisch auf `main`.

## 5 · Rollen und Takte

| Runner             | Rolle                                                          | Takt |
| ------------------ | -------------------------------------------------------------- | ---- |
| `rift-triage` (A)  | Issue → Dispatch (kein Review/Merge)                           | 1 h  |
| `rift-pr-gate` (B) | PR → rebase/review/merge/reject, **nur Fokus-Milestone**, FIFO | 30 m |

- A = `momo-clanker[bot]` (`clanker-gh`/`clanker-git`), B = `momo-claw[bot]` (`claw-gh`/`claw-git`).
- Der Gate merged selbst, aber **nie** `--admin` und nie unter Umgehung von Branch-Protection.
- Den Rebase nach einem Merge gibt der Gate als Handoff an A zurück (History-Eingriff =
  Writer-Rolle; B ist Reviewer).
- Der Gate läuft häufiger als die Triage, weil ein tiefer Stack sonst auf dem untersten
  PR aufläuft.

## 6 · Kuratieren (Menschenarbeit, nicht Automatik)

Vor jeder Iteration, per Hand:

1. Fokus-Milestone anlegen (Versions-Titel) und Epic + Sub-Issues schreiben.
2. Nur **verifizierte** Issues hinein. Nichts importieren, ohne den aktuellen Stand zu
   prüfen — der Ist-Zustand driftet (Beispiel **#372**: als Bug in 1.0 geführt, war längst
   erledigt).
3. Was nicht in die Iteration gehört: in den nächsten Milestone oder zurück in den Parkplatz.
4. Iteration beenden = **Milestone schließen** → der nächste wird automatisch Fokus.

## 7 · Aufräumen, Stand 2026-09-23

Einmalig per Hand erledigt (die Automatik kann das nicht):

- 44× `orchestrator:dispatched` + 6× `triage:redispatch` entfernt — Freigabe-Marker ohne
  offenen PR.
- 23 Claims ohne PR entfernt — der Claim-Workflow (`.github/workflows/issue-claim.yml`)
  hat **keinen Verfall**.
- 163 Follow-up-Issues geschlossen; der `Follow-up-Issues`-Workflow ist deaktiviert und per
  PR auf ein explizites `quality-sweep`-Label gegatet.
- 8 fertige, aber nie geschlossene Issues geschlossen (11 gemergte PRs ohne Close).
- `#337` als veralteten Dispatch erkannt (Fix-PR #343 war seit dem 13.09. gemergt) und
  geschlossen → daraus entstand der `[ALREADY-DONE]`-Pfad oben.
- `1.0` abgeschlossen, die Reste nach `1.0.1`/`1.1` umgesortiert.
- Offene Issues: 271 → ~108.

**Lehre:** Jeder Marker, der Arbeit signalisiert, braucht einen Verfall — sonst blockiert
er lautlos.

## Verwandt

- `docs/automations.md` — Inventar, Sichtbarkeit, as-code vs. fluent.
- `scripts/rift-stale-dispatch.sh` — Freigabe hängender Dispatches (Vorbild für den Fokus-Helper).

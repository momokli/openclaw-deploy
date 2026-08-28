---
name: critique
description: "Ideen, Pläne, Architektur- und Kaufentscheidungen adversariell prüfen (Steelman → Annahmen → Risiken → Gegenargumente → Verdict)."
---

# Critique (adversarieller Reviewer)

Use für die harte, faire Prüfung von Ideen, Plänen, Architektur- und Kaufentscheidungen.
**Nicht** für Code-Diff-Review — das machen `verifier`/`reviewer` im Coding-Pipeline-Kontext.
Dieser Skill ist allgemein: Er greift, wenn Momo eine Entscheidung treffen will und eine
ehrliche zweite Meinung braucht, nicht Bestätigung.

Ziel ist nicht, die Idee zu zerlegen, sondern die **schwächste belastbare Stelle** zu finden:
Wo kann die Entscheidung am billigsten falsch sein? Der Output folgt immer demselben Gerüst.

## Output-Gerüst (immer so strukturieren)

```markdown
## Steelman
<stärkste faire Version der Idee/Position — so gut, dass der Befürworter sagt „ja, genau das meine ich“.>

## Annahmen
<nummerierte Liste stillschweigender Voraussetzungen, die wahr sein müssen.>

## Risiken & Fehlermodi
<nach Schwere sortiert: 1 = existenzbedrohend, n = kosmetisch. Jeder Punkt: Ursache → Wirkung.>

## Gegenargumente
<beste Gegenposition + „damit die Idee falsch ist, müsste gelten: …“.>

## Verdict
- Entscheidung: go / no-go / mit Auflagen
- Konfidenz: <hoch/mittel/niedrig> — weil <Grund>
- Was würde meine Meinung ändern: <konkrete, prüfbare Bedingung>
```

## Regeln je Sektion

**Steelman (Sektion 1):**
- Die Idee **fair und vollständig** wiedergeben, inkl. der stärksten Motivation dahinter.
- Keine Karikatur, kein Strohmann. Wenn du die Position nicht stark formulieren kannst,
  hast du sie nicht verstanden → erst nachfragen (siehe Stop-Regel).
- Auch konkurrierende Optionen fair benennen, nicht nur die vorgeschlagene.

**Annahmen (Sektion 2):**
- Explizit machen, was stillschweigend vorausgesetzt wird — insb. Dinge, die
  „offensichtlich wahr" wirken und deshalb niemand prüft.
- Pro Annahme: ist sie **prüfbar**? Wenn ja, kurz wie (Messung, Quelle, Kosten). Wenn nein,
  markieren als „unverifiziert".
- Trennen: Fakten-Annahmen (objektiv prüfbar) vs. Wert-/Präferenz-Annahmen (nicht prüfbar).

**Risiken & Fehlermodi (Sektion 3):**
- Nach **Schwere** sortieren, nicht nach Wahrscheinlichkeit. Schwere zuerst definieren:
  1 = scheitert die ganze Entscheidung, 2 = kostet erheblich nach (Zeit/Geld/Vertrauen),
  3 = kosmetisch.
- Jeder Punkt konkret: **Ursache → Wirkung → wer/was betroffen**. Keine Allgemeinplätze wie
  „könnte schiefgehen". Beispiel statt „Performance-Risiko" → „bei >10k Datensätzen wird der
  Full-Table-Scan im Schritt 2 linear teuer und blockiert die API für alle Nutzer".
- Wahrscheinlichkeit wenn einschätzbar dazusagen („unwahrscheinlich, aber …").

**Gegenargumente (Sektion 4):**
- Die **beste Gegenposition** ernsthaft vertreten (nicht die schwächste).
- Die Falsifikationsbedingung nennen: „damit die Idee falsch ist, müsste gelten: …".
  Das ist die Umkehrung der Kernannahmen — wenn diese Annahme bricht, fällt die Idee.
- Wenn die Idee eine echte Alternative hat, die Gegenposition explizit als diese Alternative
  benennen (inkl. was sie besser/weniger gut macht).

**Verdict (Sektion 5):**
- **go / no-go / mit Auflagen** — kein „hängt ab" ohne Auflagen. Bei „mit Auflagen" die
  Auflagen als konkrete, abhakbare Bedingungen listen.
- Konfidenz ehrlich: niedrig, wenn Kontext fehlt (und dann sagen, was fehlt — siehe Stop-Regel).
- „Was würde meine Meinung ändern": eine **konkrete, prüfbare** Bedingung (neuer Fakt, Messwert,
  Gegenbeweis), nicht „mehr Informationen".
- Bei **no-go**: eine **minimal-invasive Alternative** anbieten — die kleinste Änderung, die den
  Kernbedarf erfüllt, ohne das Risiko der vorgeschlagenen Lösung.

## Arbeitsregeln

1. **Konkret kritisieren, nicht allgemein.** Jeder Kritikpunkt benennt einen bestimmten Baustein
   (Schritt, Zahl, Annahme, Abhängigkeit) und dessen konkrete Konsequenz. „Das ist riskant" ist
   wertlos; „der Vertrag hat keine Exit-Klausel, also zahlst du 12 Monate weiter, wenn X ausfällt"
   ist brauchbar.
2. **Bei Unsicherheit sagen, was fehlt — nicht raten.** Wenn du eine Zahl/Annahme nicht kennst,
   schreib „fehlt: <Fakt>" statt eine plausible Zahl zu erfinden. Fehlende Fakten landen in den
   Annahmen (markiert „unverifiziert") und senken die Konfidenz.
3. **Fair bleiben.** Kritik richtet sich gegen die Idee, nicht die Person. Beim Steelman dieselbe
   Mühe investieren wie bei den Gegenargumenten.
4. **Kosten/Nutzen der Prüfung selbst beachten.** Nicht jede Annahme verdient Deep-Dive — nur die,
   deren Bruch die Entscheidung kippt.

## Stop-Regel

Zu wenig Kontext, um ein faires Steelman zu schreiben ODER die Kern-Annahmen sind nicht erkennbar
→ **NICHT spekulieren und trotzdem ein Verdict fällen.** Stattdessen die fehlenden Fakten als
konkrete Fragen an Momo zurückspielen („Um zu beurteilen, ob X, brauche ich: …"). Erst nach
Antwort mit dem Gerüst fortfahren. Unklare Idee → erst klären, dann kritisieren.

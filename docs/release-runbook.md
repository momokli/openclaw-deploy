# Release-Runbook

Verbindlicher Ablauf für Releases mit **client-sichtbaren Änderungen** (Mod-/Pack-Update,
HUD, Overlays, JEI, Rezepte). Ergänzt die übrigen Deploy-/Runbook-Dokumente um das
explizite **Client-Gate**.

Stand: 2026-09-12 · Bezug: Issue
[#45](https://github.com/momokli/openclaw-deploy/issues/45)

## Geltungsbereich

Dieses Runbook gilt für Releases, die das Client-Erleben verändern können:

- Mod-Builds/-Updates (z. B. `create:yogglez`) und Pack-Updates (aero / FTB Skies 2).
- Änderungen an HUD, Overlays, JEI-Integration oder Rezept-/Crafting-Logik.
- Alles, was im laufenden Client sichtbar ist, aber von Server-Logik-Tests nicht
  erfasst wird.

Reine Server-/Infra-Änderungen ohne Client-Bezug durchlaufen nur die headless Checks.

## Entscheidung (Issue #45)

Client-Verifikation erfolgt als **manueller Gate-Check auf `aero-test`** (echter
Client + echter Spieler, `/srv/aero-test`, Port 25582).

- **Jetzt:** manueller Gate-Check ist der verbindliche Weg (siehe Checkliste unten).
- **Nicht jetzt:** Xvfb + headless-Client-Harness — aufwändig und instabil, bleibt
  langfristige Option (siehe unten).

## Limitation (IST)

- Es gibt **keinen Client-Verifikations-Harness**.
- Headless-Build/Container (`compileJava`, `runData`, `gameTestServer`, `runServer`)
  decken nur die **Server-Logik** ab. `runClient` braucht ein Display und läuft im
  Devcontainer nicht (kein X-Server).
- **Rendering/HUD/Overlays/JEI sind damit headless nicht prüfbar.** Genau diese Lücke
  schließt das manuelle Client-Gate.

## Ablauf

1. **Headless Checks grün** — CI-Build und Gametests (`./gradlew gameTestServer`) sind
   grün; Server-Logik verifiziert.
2. **Client-Gate (Pflicht, manuell auf `aero-test`)** — Checkliste unten mit echtem
   Client + Spieler durchführen. Ergebnis dokumentieren (Pass/Fail + Nachweis je Punkt).
3. **Deploy/Smoke auf `aero-test`** — Deployment und Smoke-Test gegen die
   Test-Instanz (Port 25582).
4. **Release + Changelog** — erst nach bestandenem Client-Gate; Gate-Ergebnis im
   Release/Changelog verlinken.

## Client-Gate-Checkliste

Manuell auf `aero-test` mit echtem Client + echtem Spieler durchzuführen. Pro Punkt
**Pass/Fail** und **Nachweis** (Screenshot/Notiz) festhalten; Nachweise im Release
verlinken.

| # | Aspekt | Prüfschritt | Erwartet | Nachweis |
|---|--------|-------------|----------|----------|
| 1 | HUD (Lens-Indikator) | Client starten, Lens-Item halten/ausrüsten, HUD beobachten | Lens-Indikator im HUD sichtbar, korrekt eingefärbt/aktualisiert, keine Darstellungsfehler | Screenshot HUD + Notiz |
| 2 | Overlays (Create-Goggle-Overlay / Fremdblock-Tooltip) | Goggle-Overlay aktivieren, auf eigenen und fremden Block zielen | Create-Goggle-Overlay erscheint; Fremdblock-Tooltip zeigt erwarteten Inhalt, kein Flackern/Leerstand | Screenshot Overlay + Tooltip |
| 3 | JEI (Rezept-Ansicht) | JEI öffnen, Rezept/Verwendung eines Mod-Items suchen | Rezepte werden angezeigt, Verlinkung/Rezeptdaten korrekt, keine leere/falsche Ansicht | Screenshot JEI-Ansicht |
| 4 | Rezepte (Crafting) | Rezept im Crafting-Grid nachbauen und Ergebnis entnehmen | Crafting-Logik stimmt mit JEI-Anzeige überein, Ergebnis-Item korrekt | Screenshot Crafting + Notiz |
| 5 | Lens-Zyklus (Keybind) | Lens-Keybind wiederholt drücken, Modi durchschalten | Modi zyklieren in erwarteter Reihenfolge, HUD folgt, kein Hängen/Klemmen | Screenshot/Clip + Notiz |
| 6 | Fremdblock-Analyse | Analyse auf einen Nicht-Mod-Block anwenden | Fremdblock-Analyse liefert erwartetes Ergebnis, keine Exception/Absturz | Screenshot Analyse + Notiz |

Gate gilt als **bestanden**, wenn alle Punkte **Pass** sind und jeder Punkt einen
Nachweis hat. Ein Fail blockiert das Release bis zur Behebung und erneuten Prüfung.

## Review-Regel

„War headless nicht prüfbar" ist **kein zulässiger stiller offener Punkt** mehr im
Review. Für client-sichtbare Änderungen gilt eines von beidem:

- Das **Client-Gate wurde durchgeführt** und der Nachweis ist verlinkt, **oder**
- der Punkt wird als **blockierender** Punkt geführt — mit Verweis auf dieses Runbook
  und die noch ausstehende Gate-Durchführung.

Ein nicht durchgeführtes Client-Gate ohne blockierende Kennzeichnung ist ein
Review-Fehler.

## Langfristige Option (offen)

**Xvfb + headless-Client-Harness** — automatisiertes Rendering/Client-Verifikation
ohne echten Spieler. Aufwändig und instabil; aktuell **nicht** umgesetzt. Wenn
eingeführt, ersetzt/ergänzt er das manuelle Gate, sodass Schritt 2 teilautomatisiert
werden kann. Bis dahin bleibt der manuelle Gate-Check auf `aero-test` verbindlich.

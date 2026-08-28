---
name: price-research
description: "Shopping-/Preis-Recherche für Hardware & Produkte: Preise über Kagi, Geizhals/Idealo und Direktquellen ermitteln und tabellarisch vergleichen."
metadata:
  {
    "openclaw":
      {
        "requires": { "env": ["KAGI_API"] },
      },
  }
---

# Price Research (Shopping)

Use für Produkt-/Preis-Recherche — Momo fragt regelmäßig nach Hardware-/Produkt-Preisen
(z.B. Dell Precision Workstations, Seagate Exos HDDs). Ziel: realistische Preise + Bezugsquellen
liefern, keine erfundenen Zahlen.

## Voraussetzungen

- Env `KAGI_API` (Bearer-Token). Such-/Extract-Mechanik (curl-Befehle) NICHT hier duplizieren —
  siehe Skill `kagi-search` (Search-API + Extract-API als Markdown).

## Wichtigste Gotchas (erst lesen)

1. **eBay/Amazon blocken direktes `curl`-Scraping.** Preise dort über die Kagi **Extract-API**
   holen (liefert Markdown), NICHT über die rohe HTML-Seite fetchen.
2. **Kleinanzeigen via Kagi-Extract:** Response enthält `data[]` mit `markdown`-Feldern —
   Titel = `# …`, Preiszeile = `## …`. So parsen, nicht auf HTML-Struktur raten.
3. **Geizhals (`preisvergleich.heise.de`) + Idealo = DE-Preisvergleichs-Baseline.** Produktseiten
   direkt fetchen, wenn nötig.
4. **refurbed.de / secondbuy.de** lassen sich direkt fetchen (`JSON-LD`/`__NEXT_DATA__`).
5. **Immer Quellen-URLs** in der Antwort mitschicken.
6. **Widersprüchliche Preise** → Spanne angeben (min–max), statt eine Zahl zu erfinden.

## Workflow (Phasen)

### 1. Anforderung klären

Vor der Suche feststellen (bei Unklarheit kurz nachfragen): Produkt/Modell, relevante Specs,
Budget, Neu vs. Gebraucht/Refurbished, Region (DE default). Erst dann suchen.

### 2. Breite Kagi-Suche

Über `kagi-search` breit suchen (z.B. `<Produkt> <Modell> Preis`). Kandidaten + ungefähre
Preisspannen identifizieren. Erste Treffer noch NICHT als finale Preise verwenden.

### 3. Preise gezielt über die richtigen Quellen ziehen

Pro Quelle die passende Methode (siehe Gotchas):

- Geizhals/Idealo: Produktseite suchen, direkt fetchen → Händler + Preis + Verfügbarkeit.
- eBay/Amazon: Kagi Extract-API (Markdown), nicht roh curl.
- Kleinanzeigen: Kagi Extract → `data[].markdown` parsen (`#` = Titel, `##` = Preis).
- refurbed.de / secondbuy.de: direkt fetchen (`JSON-LD`/`__NEXT_DATA__`).

### 4. Vergleichen + strukturierte Antwort

Tabelle: **Produkt | Preis | Verfügbarkeit | Händler | Link**, dann kurze Empfehlung
(bester Preis, bestes Preis-/Leistungsverhältnis, Risiko bei Gebrauchtware). Quellen-URLs
immer beifügen. Bei streuenden Preisen Spanne statt Einzelwert.

## Stop-Regel

Leere oder geblockte Ergebnisse → NICHT endlos curl-Varianten durchprobieren. Stattdessen:
(1) Quelle wechseln (andere Preisvergleichs-/Händlerseite), (2) `kagi-search`-Stop-Regel für
Auth/HTTP-Fehler anwenden, (3) falls keine brauchbare Quelle liefert → Momo fragen (Produkt/Region
präzisieren oder akzeptieren, dass kein verlässlicher Preis verfügbar ist).

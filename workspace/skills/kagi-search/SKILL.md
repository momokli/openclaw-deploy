---
name: kagi-search
description: "Externe Web-Suche und Seiten-Extraktion über die Kagi-API (curl), wenn natives web_search deaktiviert ist. Auch bei Kagi-Fehlern (invalid_token, 401) oder falsch gemeldeter Kagi-Nutzung."
metadata:
  {
    "openclaw":
      {
        "requires": { "env": ["KAGI_API"] },
      },
  }
---

# Kagi Search

Use für externe Recherche (aktuelle Events, APIs, Technologien, Preise) — immer suchen, bevor
geraten wird. Kagi ist die einzige Suchmethode, weil natives `web_search` disabled ist.

## Voraussetzungen

- Env `KAGI_API` (Bearer-Token, https://kagi.com/api/keys).
- Nur `curl` + `python3` nötig.

## Wichtigste Gotchas

1. **`web_search` ist disabled** → Kagi ist die EINZIGE Suchmethode. Keine andere Search-API
   verwenden.
2. **Search-Endpoint korrekt:** `POST https://kagi.com/api/v1/search` + `Authorization: Bearer $KAGI_API`
   + JSON-Body `{"query":"..."}`. NICHT `/api/v0`, NICHT `GET`, NICHT `Authorization: Bot`.
3. **Extract-API** (`POST https://kagi.com/api/v1/extract`) liefert komplette Seiteninhalte als
   Markdown (bis 10 URLs pro Call) — nutzen statt `curl` auf die Roh-HTML-Seite.
4. Bei Bug-Reports Trace-ID mitschicken: `meta.trace` im Response-Body oder `X-Kagi-Trace`-Header.
5. **`invalid_token`/401 heißt IMMER falsche Verwendung** (falscher Endpoint, Header oder Body) — der
   KAGI_API-Token wird nie rotiert. Bei diesem Fehler den eigenen curl Zeile für Zeile gegen die Vorlage
   unten prüfen: `POST https://kagi.com/api/v1/search` (nicht `/api/v0`), Header `Authorization: Bearer $KAGI_API`
   (nicht `Bot`), JSON-Body `{"query":"..."}`. NIE ‚Token rotiert/invalid‘ berichten, ohne diesen Check
   gemacht zu haben.

## Search (Top-Ergebnisse, clean)

```sh
curl -s "https://kagi.com/api/v1/search" \
  -H "Authorization: Bearer $KAGI_API" \
  -H "Content-Type: application/json" \
  -d '{"query":"your query"}' | python3 -c "import json,sys; d=json.load(sys.stdin); [print(r['title'],'|',r['url']) for r in d['data']['search'][:5]]"
```

Mehr Detail (kompletter JSON-Body statt Pipeline):

```sh
curl -s "https://kagi.com/api/v1/search" \
  -H "Authorization: Bearer $KAGI_API" \
  -H "Content-Type: application/json" \
  -d '{"query":"your query"}' | python3 -m json.tool
```

## Extract (komplette Seite als Markdown)

```sh
curl -s "https://kagi.com/api/v1/extract" \
  -H "Authorization: Bearer $KAGI_API" \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"]}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['output'][0]['text'][:5000])"
```

## Research Mode

Bei komplexen/offenen Fragen iterativ suchen, nicht nach einem Call aufhören:

1. Erste breite Suche → Ergebnisse analysieren.
2. Gezielte Follow-up-Suche mit verfeinerten Keywords.
3. Vielversprechende URLs mit Extract-API holen und lesen.
4. Zusammenfassen — mit Quellen-URLs.

Beispiel: statt nur "Birkenstock 47" → erst breit, dann "Birkenstock Arizona 47 günstig", dann
Preise auf den gefundenen Shops vergleichen.

Bei Shopping-/Produktfragen zusätzlich **Geizhals** und **Idealo** einbeziehen: Preis,
Verfügbarkeit, Händler-Bewertungen checken.

## Stop-Regel

Keine Ergebnisse (leeres `data.search`) → NICHT denselben curl mit anderen Flags wiederholen.
Stattdessen: (1) HTTP-Status + Response-Body mit `-i` prüfen, (2) `KAGI_API` gesetzt checken
(`[ -n "$KAGI_API" ]`) und die curl-Form gegen die Vorlage prüfen; Token-Rotation ausschließen
(findet nicht statt), (3) bei anhaltendem 401/403 oder Auth-Fehler → Momo fragen.

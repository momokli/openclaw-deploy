# Playtest-Guide (externer Tester) — Stand 1.0.3 „Spielkapsel"

> Für Matheo & Co.: **kein Operator-Wissen nötig**. Ziel = ein Klick → du landest in einem
> vorgewärmten, **pausierten** Solo-Spiel; nach der Runde geht der Server zurück in den Pool.
>
> **Was der Tester NICHT braucht:** keinen Client-Patch, kein Steam-Konto (GOG geht auch),
> keine Server-Installation. Der Relay ist client-agnostisch.

---

## 0 · Setup (einmalig)

| #   | Was                         | Wert                                                                                                  |
| --- | --------------------------- | ----------------------------------------------------------------------------------------------------- |
| 1   | Spiel                       | Riftbreaker (Steam **oder GOG**), Windows, aktueller Patch                                            |
| 2   | Mod                         | ✅ Client-Mod (`rbbattle`) ist installiert                                                            |
| 3   | Connect-Host                | **`rift.projectmellon.de`**                                                                           |
| 4   | Lobby-Zugang                | `https://proxy.rift.projectmellon.de` — HTTP basic_auth **`operator` / `zukka`**                      |
| 5   | Cockpit (heute für `ready`) | `https://cockpit.drift.projectmellon.de` (dieselben Creds) — **soll mit dem Lobby-`READY` entfallen** |

---

## 1 · Verbinden (im Spiel)

1. Spiel starten → Multiplayer → **per IP/Host verbinden**.
2. Eintragen: **`rift.projectmellon.de`**
   - ⚠️ **Nur den Host** — **keinen Port**! Der Client hängt selbst `:6321` an; eine Eingabe
     mit Port scheitert **still** (es passiert einfach nichts).
3. **Spielername** im Multiplayer setzen:
   - **`<name>-staging`** → du landest auf der **Staging**-Umgebung (so testen wir).
   - ohne Suffix → prod. `-dev` → dev.
4. Verbinden. Der Client bleibt im **Loading** — das ist richtig: der Relay _hält_ dich, bis
   der Test-Server bereit ist. (Der Client gibt nach ~20 s auf und verbindet neu — kurz
   warten ist normal.)

## 2 · Solo-Spiel anfordern (Lobby)

5. `https://proxy.rift.projectmellon.de` öffnen (Login `operator`).
6. Deine Session erscheint als **wartend**.
7. Auf der Karte **`[ solo | self-send on ]`** klicken.
   - Das claimt eine **geparkte** Solo-Instanz und schickt dich automatisch hin
     (kein zweiter Klick).
8. Du landest im Spiel — es ist **PAUSIERT**. (Man sieht das Spiel/die Welt, aber nichts läuft.)

## 3 · Runde starten (`ready`)

9. **`ready`** drücken
   → Das Spiel resümiert: **Warmup → Runde läuft**.
   - **Bis der Lobby-`READY`-Button steht** (im Bau): `ready` kommt heute aus dem Cockpit
     (`https://cockpit.drift.projectmellon.de` → Game Config Editor → Button **`ready`**;
     der `capsule:`-Readout zeigt die Phase). Sag kurz Bescheid, wenn du drin bist — dann
     drücken **wir**.
   - Danach läuft **ein Countdown („3…2…1 → GO")** in den Chat (Announcer, 1.0.7).
10. Runde spielen. Nach dem Ende geht der Server **zurück in den Pool**.

---

## 4 · Was wir testen — und was du meldest

Bitte **immer** mit: Uhrzeit, deinem Spielernamen, Umgebung (`-staging`).

- **Join:** Kommst du rein? Kein „Could not connect", kein Kick?
- **Pause:** Ist es wirklich **pausiert** (nichts läuft), bevor `ready`?
- **Start:** Startet es nach `ready` sauber (Warmup → Runde)?
- **Recycling:** Nach Rundenende — Server wieder verfügbar (zweiter Klick `[ solo ]` gibt dir
  wieder ein Spiel)?
- **Sonstiges:** Crash, Black Screen, Hänger, „ready tut nichts", Chat-Zeilen fehlen.

## 5 · Bekannte Grenzen (kein Bug)

- `ready` ist (noch) **Operator**-Sache → wir drücken es für dich.
- **Chat-Anzeige** (Server-Nachrichten/Panel) ist 1.0.4 (PRs #944/#945 noch offen) — der
  Countdown-Text im Chat kommt damit.
- Mehrere Spieler in _einem_ Solo-Spiel = **1.0.5**.
- VS/Queue/ranked = 1.0.9/1.0.10.

---

## Für uns: Testing-Setup

- **Solo-/Kapsel-Flow läuft aktuell auf DEV** (der Relay-Singleton zeigt auf den dev-Parked-Dienst
  `127.0.0.1:9201`). Ein `[solo]`-Klick provisioniert also eine **dev**-Instanz. `-staging` im
  Namen routet nur **Direkt-Joins** auf staging.
- **Ports:** parked dev `9201`, Kapsel dev `9211` (Ports 8000–8500 sind host-weit von azuracast
  belegt) — Issue #955/PR #956.
- **Relay:** Singleton auf `proxy.rift.projectmellon.de`; Env-Wahl per **Spielnamen-Suffix**
  (`-staging`), nicht per Port.
- **Kapsel-Flow:** Relay `POST /solo` → Kapsel-Dienst `POST /capsule/open` (Claim **ohne**
  resume → pausiert) → Pin auf den GNS-UDP-Endpoint der Instanz.
- **Vor dem Test:** Staging frisch deployen (Branch `staging`), Parked-Pool warm.
- **Kanal für Befunde:** Kommentar am Release-PR (#952) oder neues Issue im Milestone —
  wir sortieren es dem richtigen Milestone zu.

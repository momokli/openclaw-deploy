# Playtest-Guide (externer Tester) — Stand 1.0.3 „Spielkapsel"

> Für Matheo & Co.: **kein Operator-Wissen nötig**. Ziel = ein Klick → du landest in einem
> vorgewärmten, **pausierten** Solo-Spiel; nach der Runde geht der Server zurück in den Pool.
>
> **Was der Tester NICHT braucht:** keinen Client-Patch, kein Steam-Konto (GOG geht auch),
> keine Server-Installation. Der Relay ist client-agnostisch.

---

## 0 · Setup (einmalig)

| # | Was | Wert |
|---|---|---|
| 1 | Spiel | Riftbreaker (Steam **oder GOG**), Windows, aktueller Patch |
| 2 | Mod | *zu bestätigen*: reicht das Basis-Spiel, oder muss der Client-Mod (`rbbattle`) installiert werden? |
| 3 | Connect-Host | **`rift.projectmellon.de`** |
| 4 | Lobby-Zugang | `https://proxy.rift.projectmellon.de` — HTTP basic_auth, User `operator`, **Passwort: von Momo** |
| 5 | Cockpit (für `ready`) | `https://cockpit.staging.projectmellon.de` (Zugang von Momo) |

---

## 1 · Verbinden (im Spiel)

1. Spiel starten → Multiplayer → **per IP/Host verbinden**.
2. Eintragen: **`rift.projectmellon.de`**
   - ⚠️ **Nur den Host** — **keinen Port**! Der Client hängt selbst `:6321` an; eine Eingabe
     mit Port scheitert **still** (es passiert einfach nichts).
3. **Spielername** im Multiplayer setzen:
   - **`<name>-staging`** → du landest auf der **Staging**-Umgebung (so testen wir).
   - ohne Suffix → prod. `-dev` → dev.
4. Verbinden. Der Client bleibt im **Loading** — das ist richtig: der Relay *hält* dich, bis
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

9. **`ready`** drücken — im Cockpit (`https://cockpit.staging.projectmellon.de` → Game Config
   Editor → Button **`ready`**; der `capsule:`-Readout zeigt die Phase).
   → Das Spiel resümiert: **Warmup → Runde läuft**.
   - Sag kurz Bescheid, wenn du drin bist — dann drücken **wir** `ready`
     (das `/ready`-von-Spielern-im-Chat kommt erst in 1.0.6).
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
- **Chat-Anzeige** (Server-Nachrichten/Panel) ist erst **1.0.4** — noch nicht in diesem Test.
- Mehrere Spieler in *einem* Solo-Spiel = **1.0.5**.
- VS/Queue/ranked = 1.0.9/1.0.10.

---

## Für uns: Testing-Setup

- **Ziel-Umgebung: Staging** (`planet :6323`, `cockpit.staging.projectmellon.de`) — Prod bleibt
  unberührt.
- **Relay:** Singleton auf `proxy.rift.projectmellon.de`; Env-Wahl per **Spielnamen-Suffix**
  (`-staging`), nicht per Port.
- **Kapsel-Flow:** Relay `POST /solo` → Kapsel-Dienst `POST /capsule/open` (Claim **ohne**
  resume → pausiert) → Pin auf den GNS-UDP-Endpoint der Instanz.
- **Vor dem Test:** Staging frisch deployen (Branch `staging`), Parked-Pool warm.
- **Kanal für Befunde:** Kommentar am Release-PR (#952) oder neues Issue im Milestone —
  wir sortieren es dem richtigen Milestone zu.

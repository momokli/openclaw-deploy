# Playtest-Guide (externer Tester) — prod-only

> Für Matheo & Co.: **kein Operator-Wissen nötig**. Ziel = ein Klick → du landest in einem
> vorgewärmten, **pausierten** Solo-Spiel; nach der Runde geht der Server zurück in den Pool.
>
> **Was der Tester NICHT braucht:** keinen Client-Patch, kein Steam-Konto (GOG geht auch),
> keine Server-Installation. Der Relay ist client-agnostisch.
>
> **Es gibt nur noch EINE Umgebung: `prod`.** Kein Suffix, kein Env-Schalter — du verbindest
> dich einfach und landest auf prod.

---

## 0 · Setup (einmalig)

| #   | Was          | Wert                                                                        |
| --- | ------------ | --------------------------------------------------------------------------- |
| 1   | Spiel        | Riftbreaker (Steam **oder GOG**), Windows, aktueller Patch                  |
| 2   | Mod          | Client-Mod `rbbattle` installiert (aktueller Stand, s. u.)                  |
| 3   | Connect-Host | **`rift.projectmellon.de`**                                                 |
| 4   | Lobby-Zugang | `https://proxy.rift.projectmellon.de` — basic_auth **`operator` / `zukka`** |

**Mod immer aktuell:** `rbbattle.zip` von `https://rift.projectmellon.de/mods/rbbattle.zip`.

---

## 1 · Verbinden (im Spiel)

1. Spiel starten → Multiplayer → **per IP/Host verbinden**.
2. Eintragen: **`rift.projectmellon.de`**
   - ⚠️ **Nur den Host** — **keinen Port**! Der Client hängt selbst `:6321` an.
3. **Spielernamen** setzen (ganz normal, ohne Suffix).
4. Verbinden. Der Client bleibt im **Loading** — das ist richtig: der Relay _hält_ dich, bis
   die Instanz bereit ist. (Der Client gibt nach ~20 s auf und verbindet neu — kurz warten ist normal.)

---

## 2 · Solo-Spiel anfordern (Lobby)

5. `https://proxy.rift.projectmellon.de` öffnen (Login `operator` / `zukka`).
6. Deine Session erscheint als **wartend**.
7. Auf der Karte **`[ solo | self-send on ]`** klicken.
   - Das claimt eine **geparkte** Solo-Instanz (Core + alle Sidecars) und schickt dich
     automatisch hin. Kein zweiter Klick.
8. Du landest in der Welt — sie ist **PAUSIERT** (man sieht die Welt, aber nichts läuft).

---

## 3 · Runde starten (`ready`)

9. Im Lobby-Screen **`READY`** drücken.
   → Das Spiel resümiert: **Warmup → Runde läuft**. Im Chat läuft ein Countdown („3…2…1 → GO").
10. Runde spielen. Nach dem Ende geht der Server **zurück in den Pool**.

---

## 4 · Was wir testen — und was du meldest

Bitte **immer** mit: Uhrzeit + deinem Spielernamen.

- **Join:** Kommst du rein? Kein „Could not connect", kein Kick?
- **Pause:** Ist es wirklich **pausiert** (nichts läuft), bevor `ready`?
- **Start:** Startet es nach `ready` sauber (Warmup → Runde)?
- **Chat:** Siehst du die Server-Zeilen (Warmup / Waves / Ergebnis)?
- **Recycling:** Nach Rundenende — 2. Klick `[ solo ]` gibt dir wieder ein Spiel?
- **Sonstiges:** Crash, Black Screen, Hänger, „ready tut nichts".

---

## 5 · Bekannte Grenzen (kein Bug)

- **VS / Queue / ranked** ist **noch nicht live** (Provisioner-HTTP-Service `:8094` noch nicht
  deployt). Heute testbar ist **Solo**.
- **Mehrere Spieler in einem Solo-Spiel** und **Matchview** kommen später.

---

## Für uns: Testing-Setup

- **Kanonische Solo-Kette:** Relay `POST /solo` → Capsule `POST /capsule/open` (Claim **ohne**
  resume → pausiert) bzw. Parked `POST /claim` → Pin auf den GNS-UDP-Endpoint der Instanz.
  `ready` → Resume + Round-Start.
- **Host-Dienste (prod, Singletons):** Parked `127.0.0.1:9201`, Capsule `127.0.0.1:9211`,
  Queue `127.0.0.1:9221`, GNS-Relay-API `127.0.0.1:9200`, GNS-Einstieg **UDP :6321**.
- **Relay-Targets:** nur noch `PROD_A` (:6322) / `PROD_B` (:6325) / Default (`PROD`). Kein
  Env-Suffix mehr.
- **Vor dem Test:** Pool warm halten (min. 1 geparkte Instanz), Parked/Capsule/Queue aktiv.
- **Kanal für Befunde:** neues Issue (bzw. Kommentar am offenen Release-PR).

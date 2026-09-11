# Plan: Dev-Loop-Compute von `.149` auf `planet` auslagern

Stand: 2026-09-10 · Status: **PLAN (kein Umbau, keine Config-Änderung)** · Source-of-Truth: dieses Repo.

Ziel dieses Dokuments: Optionen bewerten, wie die beiden autonomen Coding-Loops
(`rbm-loop` alle 15 min, `rbbattle-overnight-loop` alle 30 min) ihre schwere
"Dev-Loop"-Arbeit auf `planet` (Hetzner Metal) verlagern können, während `.149`
nur noch Orchestrierung bleibt (Richtung aus Issues #46/#49).

---

## 1. IST-Zustand

- **`.149`** (`lan`, Tailscale `100.85.52.13`): 16 Cores, ~105 GiB RAM, 628 GiB Disk frei.
  Läuft der OpenClaw-Gateway (Docker) **und** die Automations (`cron`) **und** die
  gespawnten Worker.
- **Die Loops** (`docs/automations.md`): `rbm-loop` (15 min) und `rbbattle-overnight-loop`
  (30 min) sind autonome Coding-Pipelines für `momokli/riftbreaker-battle-mod`. Sie
  clonen, reviewen, mergen, releasen und spawnen dabei `operator`-Worker auf
  **`deepseek/deepseek-v4-pro`** (`timeoutSeconds` 840 bzw. 1500). Ein `rbm-loop`-Lauf
  dauerte zuletzt **553 s**.
- **Orchestrierung heute:** Der Loop-Turn läuft auf dem Gateway (`.149`); die eigentliche
  Arbeit passiert in `operator`-Subagenten (Modell Pro) und in den Stage-Agents
  (`feature-dev-*`, via `sessions_spawn` aus `coding-orchestrator`). Das alles rechnet auf
  `.149`, das gleichzeitig ~20 weitere Container (caddy, ollama, HA, paperless, …) trägt
  und laut `docs/equip-agents.md` A10 schon unter hoher Last (load 7–14, Gateway ~60 GiB RAM)
  leidet.
- **`planet`** (Tailscale `100.77.143.105`): Hetzner Metal, 20 Cores, 62 GiB RAM (inkl.
  ~31 GiB Swap, davon 15 GiB belegt), Disk **88 % voll** (107 GiB frei). Läuft Plex/\*arr/etc.

### Ressourcen-Gegenüberstellung (live gemessen 10.09.)

| Host | Cores | RAM | RAM verfügbar | Swap | Disk frei | Load (1/5/15) | Lastprofil |
|---|---|---|---|---|---|---|---|
| `.149` (`lan`) | 16 | ~105 GiB | — (Gateway zieht ~60 GiB) | — | 628 GiB | 7–14 (A10) | 20+ Container + Gateway + Worker |
| `planet` | 20 | 62 GiB | 31 GiB | 15/31 GiB belegt | **107 GiB (88 % voll)** | 2.7/3.4/3.9 | Plex/\*arr |

**Kern-Erkenntnis:** `planet` hat **mehr Cores und deutlich niedrigere Last**, aber
**weniger RAM und vor allem viel weniger Disk** als `.149`. Das ist die entscheidende
Restriktion für alles, was Build-/Test-Artefakte erzeugt.

---

## 2. Ziel-Zustand

- `.149` = **Orchestrierung** (Gateway, Cron, Routing, Telegram, Memory, State, Auth).
- `planet` = **Compute** für die beiden Dev-Loops (die schweren Worker-Turns: clone/build/
  review/merge/release und die `feature-dev-*`-Stages).
- Keine zweite Gateway-Instanz, keine duplizierten Secrets/Cron/State, wenn vermeidbar.

---

## 3. Native OpenClaw-Mechanismen (Recherche, live via `openclaw docs` + CLI-Help)

Es gibt **vier** relevante Bausteine — aber nur zwei bewegen wirklich "Compute", einer
bewegt nur Shell-Exec, und einer ist für den Fall unbrauchbar:

### 3.1 Node Host (`openclaw node run|install`) — bewegt nur `exec`

- Paart eine Maschine als **Node**; der Gateway leitet `system.run`/`system.which` mit
  `host=node` an den Node weiter. Das Modell/der Agent-Turn bleibt auf dem Gateway.
- Geeignet für "führe Kommandos auf planet aus", **nicht** für "verlagere den Loop".

### 3.2 Session Hosting / Paired Device (`openclaw connect --service --session-host`) — bewegt den ganzen Worker-Turn ✅

Das ist der eigentliche Mechanismus. Quelle: `docs/nodes/session-hosting` +
`docs/gateway/cloud-sessions`.

- Eine gepaarte Maschine hostet **volle OpenClaw-Worker-Sessions** (die echten Coding-Turns:
  Kommandos, File-Edits, Tools). Der Gateway bleibt **Eigentümer** von Transcript,
  Workspace und Credentials; die fertige Arbeit wird zurück-synchronisiert.
- **Modell-Inferenz bleibt über den Gateway geproxied** — Provider-Credentials erreichen
  den Remote-Host nie. Das heißt: auf `planet` läuft kein Modell, nur der Worker + die
  Shell-/Build-Befehle.
- Aktivierung lokal auf dem Node: `nodeHost.workerRuns.enabled: true`, optional
  `nodeHost.workerRuns.capacity` (Worker-Slots, Default 1 pro Core) und
  `nodeHost.workerRuns.isolation: "container"` (jeder Worker in eigenem Docker-Container).
- Placement: `deviceId` (fest) oder `autoDevice: true` (Gateway wählt den Host mit den
  meisten freien Slots). `execNode` bindet Session-Exec an einen Node-Host.

### 3.3 Cloud Workers (Crabbox) — Miet-Maschinen, nicht unser Fall

- `cloudWorkers.profiles` provisioniert Wegwerf-Maschinen (AWS/Hetzner/…) on-demand.
- Konzeptionell verwandt, aber wir haben `planet` schon als eigene Hardware → für diesen
  Plan nur als "Burst"-Option notiert, nicht als Ziel.

### 3.4 Fleet (`openclaw fleet`) — **nicht relevant**

- `fleet` verwaltet **isolierte Multi-Tenant-Zellen** (je eine *komplette* Gateway-Instanz
  im eigenen Container). Das ist Tenant-Isolation, **kein** Remote-Compute-Mechanismus.

---

## 4. Optionen

### Option A — `planet` als Session-Host-Node (empfohlen)

`planet` als Node pairen **und** Session-Hosting aktivieren; die beiden Loops bleiben als
Cron auf `.149`, ihre gespawnten `operator`-/`feature-dev-*`-Worker-Turns laufen auf `planet`.

- **Pros**
  - Eine einzige Gateway-Instanz — kein zweiter State, kein zweites `config/.env`, kein
    zweites Cron, kein zweiter Deploy-Pfad.
  - Gateway behält Transcript/Workspace/Credentials; **Modell-Credentials bleiben auf `.149`**
    (Inferenz proxied).
  - `planet` bringt +4 Cores und massiv niedrigere Load → entlastet genau das, was A10
    diagnostiziert hat.
  - `autoDevice`/`capacity`/Container-Isolation erlauben Feintuning und Lastverteilung.
  - Passt exakt zum Ziel ".149 = Orchestrierung, planet = Compute".
- **Cons**
  - `planet`-Disk (107 GiB frei, 88 % voll) ist das echte Risiko: Gradle-/JDK-Caches und
    FTB-Pack-Downloads/-Extractions (500+ Mods) brauchen Platz. Muss gemessen werden (→ B1/B8).
  - `planet`-RAM (31 GiB verfügbar) muss per `capacity` gedeckelt werden; bei parallelen
    Build-/Gametest-Server-Boots kann es eng werden.
  - Offen, wie Automation-/`sessions_spawn`-Turns auf `deviceId`/`autoDevice` gepinnt
    werden (Syntax noch nicht live verifiziert — siehe §6).
  - Netzwerkpfad über Tailscale (Gateway-WS muss vom planet-Node erreichbar sein).

### Option B — Zweiter Gateway-Container auf `planet`

Eine **volle zweite** OpenClaw-Instanz (eigener Container, eigenes `config/.env`, eigene
Automations) auf `planet`; die zwei Loops werden dort registriert.

- **Pros**
  - Harte Isolation; Loops inkl. Orchestrierung + Inferenz komplett auf `planet`.
- **Cons**
  - Dupliziert State/Sessions/Auth/Pairing und vor allem die Secret-Datei auf `planet`.
  - Zweiter Deploy-Pfad (CI/Compose) und zweite Cron-/Automation-Pflege.
  - Modell-Inferenz-Tokens laufen dann über `planet` → Credentials dort nötig.
  - Widerspricht dem Ziel ".149 = Orchestrierung" (man verdoppelt die Orchestrierung
    statt sie zu belassen) und belastet den RAM-/Disk-knappen Host mit einer ganzen
    Gateway-Instanz.
- **Fazit:** nur sinnvoll, wenn eine vollwertige Zweit-Instanz gewollt ist — für dieses
  Ziel unnötig teuer/komplex.

### Option C — Nur Build/Test-Schritte auf `planet` (Node Host / SSH-only)

`planet` als reiner **Node Host** (`openclaw node run`) oder weiterhin nur via
`operator` → `ssh planet`; nur die teuren `exec`-Befehle (Gradle/Java/FTB) laufen auf
`planet`, Orchestrierung + Modell bleiben auf `.149`.

- **Pros**
  - Minimal-invasiv, kein Session-Hosting; `operator.md` kennt `ssh planet` bereits.
  - Geringster Secret-/State-/Setup-Aufwand; gut als risikoarmer erster Schritt.
- **Cons**
  - Bewegt nur Shell-Befehle, nicht den Agent-Turn selbst → Modell-/Turn-Last bleibt auf
    `.149` (die eigentliche Entlastung bleibt aus).
  - Repo-Checkout/File-Edits der Worker bleiben auf `.149`; `planet`-Disk-Risiko für
    Build-Artefakte bleibt.
  - Kein Auto-Load-Balancing, keine Container-Isolation der Worker.
- **Fazit:** erreicht "Builds woanders", aber **nicht** ".149 nur Orchestrierung".

---

## 5. Empfehlung + nächste Schritte

**Empfohlen: Option A** — `planet` als **Session-Host-Node** pairen und die Worker-Turns der
beiden Loops dorthin verlagern, während Gateway/Cron/State auf `.149` bleiben. Das bewegt
das eigentliche Dev-Loop-Compute (Worker-Turn + Tools) ohne zweite Gateway-Instanz und ohne
Secrets auf `planet`.

Konkrete nächste Schritte (nach Approval, nicht in diesem PR):

1. **Platzierung verifizieren** — Syntax klären, wie Automation-Agent-Turns bzw.
   `sessions_spawn`-Subagenten auf `deviceId`/`autoDevice` (bzw. `execNode`) gepinnt werden.
   Betroffene Flächen: `openclaw automations …` (Agent-Turn-Payload-Flags) und die
   Subagent-Spawn-API von `coding-orchestrator`.
2. **`planet` provisionieren** — OpenClaw-Node auf `planet` einrichten
   (`openclaw connect <join-url> --service --session-host`), `nodeHost.workerRuns.enabled`
   setzen, `capacity` klein starten (z. B. 4–6 Slots statt 1/Core), optional
   `isolation: "container"`.
3. **Gateway-seitig approven** — `openclaw devices approve` + `openclaw nodes approve`;
   `openclaw nodes status`/`describe` als Health-Gate.
4. **Disk-/RAM-Headroom messen** — vor Freigabe: Gradle-/FTB-Footprint auf `planet` prüfen
   (107 GiB frei), `GRADLE_USER_HOME` auf persistentem Pfad (B1); ggf. Build-Artefakte auf
   `.149`-Volume belassen und nur Compute auf `planet`.
5. **Baseline** — ein Loop-Lauf auf `.149` vs. `planet` messen (Zeit je Phase, B8-DoD).
6. **Rollout** — einen Loop zuerst auf `planet` routen, `automations runs` + `nodes status`
   beobachten, dann den zweiten.

---

## 6. Offene Fragen an Momo

1. **Routing-Syntax:** Wie genau werden Automation-/Subagent-Turns auf einen Session-Host
   gepinnt (`deviceId`/`autoDevice`/`execNode` in Cron-Payload oder `sessions_spawn`)?
   (Noch nicht live verifiziert — darf ich das ohne Live-Änderung nur per Doku/CLI-Help klären?)
2. **Disk auf `planet`:** Reichen 107 GiB für FTB-Pack-Downloads/-Extractions + Gradle-Cache,
   oder sollen Build-Artefakte/Caches auf einem anderen Volume (`.149` oder StorageBox) liegen?
3. **Container-Isolation:** Worker auf `planet` im Docker-Container (`isolation: "container"`)
   oder als Prozess (`"none"`)? Docker ist auf `planet` vorhanden (Plex/\*arr).
4. **Kapazität:** Welches RAM-Budget sollen die Worker-Slots auf `planet` bekommen
   (Default 1 Slot/Core wäre bei 20 Cores zu viel für 31 GiB verfügbar)?
5. **Netz/Auth:** Gateway-WS ist heute `bind: lan` hinter Caddy (`trustedProxies`). Ist der
   WS-Endpunkt vom `planet`-Node über Tailscale erreichbar, oder braucht es
   `gateway.remote.url`/`plugins.entries.device-pair.config.publicUrl` für die Join-URL?

---

## Verweise

- `docs/automations.md` — Inventar + Kosten-Treiber der beiden Loops.
- `docs/equip-agents.md` — A10 (`.149`-Last), B1 (Gradle-Cache), B8 (Build-Host-Strategie).
- `ROADMAP.md` — Kosten/Routing-Kontext.
- OpenClaw-Doku: `docs/nodes/session-hosting`, `docs/gateway/cloud-sessions`,
  `docs/nodes/node-host`, `docs/nodes/pairing-and-status`, `docs/automation/cron-jobs/payloads`.

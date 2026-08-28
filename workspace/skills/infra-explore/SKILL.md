---
name: infra-explore
description: "Momos Homelab-Infrastruktur erkunden: was läuft wo, wie ist ein Service/Host konfiguriert (via /lab, read-only)."
---

# Infrastruktur erkunden

Use wenn Momo fragt „was läuft auf Host X?", „wie ist Service Y konfiguriert?" oder
„wo ist Z deployed?". Antworten kommen aus `/lab` (Infra-as-Code, read-only) —
lesen, nicht raten.

## Voraussetzungen

- `/lab` ist **read-only** gemountet. NICHTS dort ändern (keine Writes, keine `git`-Ops).
- `/lab` ist der aktuelle Ist-Stand der Infra. Alte HashiStack-Reste sind dekommissioniert
  und zählen nicht als laufende Infra.

## Wichtigste Gotchas (erst lesen)

1. **Nomad ist TOD.** Der gesamte HashiStack (Nomad/Consul/Vault) wurde dekommissioniert.
   Alles läuft jetzt via **Docker Compose** oder **systemd**. Alte `*.nomad.hcl`-Dateien
   und `/lab/nomad/` **ignorieren** — sie beschreiben keinen laufenden Zustand mehr.
2. **`/lab` ist read-only.** Nur lesen (`cat`, `grep`, `ls`, `find`). Keine Datei editieren,
   kein `sed -i`, keine Commits dort.
3. **Read before you act.** Erst die relevante Datei lesen, dann antworten. Jede Aussage mit
   konkretem Datei-Pfad + wörtlichem Zitat belegen.

## Workflow

1. **Einstieg** — Topologie + generierten Index lesen:

   ```bash
   cat /lab/topology.json                       # Host/VM-Topologie
   cat /lab/agent/knowledge/lab_context.md      # generierter Index über alles
   ```

2. **„Was läuft auf Host Y?"** — relevante Verzeichnisse listen:

   ```bash
   ls /lab/services/        # Docker-Compose-Stacks
   ls /lab/ansible/         # Playbooks/Roles/Inventory
   ```

3. **„Wie ist Service X konfiguriert?"** — gezielt nachschlagen:

   ```bash
   ls /lab/services/<name>/                    # compose-Datei(en) des Service
   grep -rn "<name>" /lab/ansible/             # Playbooks / Roles / Inventory
   ```

4. **Antwort belegen** — Pfad + wörtliches Zitat (Zeile/Kontext) angeben, nicht paraphrasieren
   ohne Beleg.

## Stop-Regel

Wenn ein Pfad nicht existiert, die Datei leer ist oder `/lab` gar nicht gemountet ist →
**NICHT raten.** Sag Momo was fehlt (oder dass `/lab` nicht verfügbar ist) und frag nach,
statt eine Antwort zu erfinden.

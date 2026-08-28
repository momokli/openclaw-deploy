# OpenClaw Skills — Muster & Konventionen

Stand: 2026-08-28. Wie wir agent-seitige Skills in diesem Repo pflegen (Source-of-Truth = git).

## Was Skills sind

Skills = Markdown-`SKILL.md`-Dateien (YAML-Frontmatter + Body), die dem Agent beibringen,
**wie und wann** er ein Tool / einen Workflow nutzt. Frontmatter (`name` + `description`) ist
immer im Prompt; der Body lädt erst nach Trigger; `references/`/`scripts/`/`assets/` laden
nur bei Bedarf.

Offizielle Doku: `openclaw docs skills` bzw. https://docs.openclaw.ai/tools/skills.

## Lade-Reihenfolge (höchste Präzedenz zuerst)

```
<workspace>/skills          ← hier liegen unsere (git)
<workspace>/.agents/skills
~/.agents/skills
~/.openclaw/skills          (managed, Runtime)
bundled + custodian
skills.load.extraDirs
```

## Wie dieses Repo Skills verwaltet

- Skills liegen **in git** unter `workspace/skills/<name>/SKILL.md`.
- Der Mount `./workspace:/openclaw-config/workspace:ro` liefert sie in den Container.
- `entrypoint.sh` (Schritt 4b) kopiert sie nach `/home/node/.openclaw/workspace/skills/`
  (= `<workspace>/skills`, höchste Präzedenz).
- **Neue Session nötig** (oder `/new`), damit der Agent sie sieht — Skills werden pro Session gesnappt.

## SKILL.md-Muster (copy-paste)

```markdown
---
name: mein-skill
description: "Kurze Noun-Phrase (<160 Zeichen): wann/worum geht es."
metadata: { "openclaw": {
        "requires": { "bins": ["<binary>"] }, # optional: nur laden wenn binary da
        # "env": ["<VAR>"], "os": ["linux"], "primaryEnv": "<VAR>"  (weitere Gates)
      } }
---

# Mein Skill

Use für … (1 Satz, was der Skill macht).

## Zugriff / Voraussetzungen

… exakte Pfade, Hosts, Credentials …

## Wichtigste Gotchas

1. … brittle Syntax, Auth-Caveats, Safety-Regeln — genau das, was das Base-Model NICHT weiß …

## Workflow

1. Schritt
2. Schritt
3. …

## Stop-Regel

Wann aufhören und nachfragen statt variieren.
```

**Regeln (aus dem gebündelten `skill-creator`):**

- Body lean halten; generisches Wissen, das das Base-Model schon kann, weglassen.
- Nur trigger-kritische Fakten in `description`; Noun-Phrase, nicht der ganze Workflow.
- Lange Doku → `references/`, deterministische Helper → `scripts/`, Templates → `assets/`.
- Immer eine **Stop-Regel** (verhindert genau die Loop, die wir am 28.08. hatten).

## Inventar

| Skill             | Status      | Quelle                                      |
| ----------------- | ----------- | ------------------------------------------- |
| `minecraft-admin` | ✅ angelegt | `workspace/skills/minecraft-admin/SKILL.md` |
| `infra-status`    | ✅ angelegt | `workspace/skills/infra-status/SKILL.md`    |
| `analytics`       | ✅ angelegt | `workspace/skills/analytics/SKILL.md`       |
| `cost-tracking`   | ✅ angelegt | `workspace/skills/cost-tracking/SKILL.md`   |
| `kagi-search`     | ✅ angelegt | `workspace/skills/kagi-search/SKILL.md`     |
| `deploy-status`   | ✅ angelegt | `workspace/skills/deploy-status/SKILL.md`   |

## Neuen Skill anlegen

```sh
mkdir -p workspace/skills/<name>
# SKILL.md schreiben (Muster oben), optional scripts/ references/
# entrypoint.sh ist schon generisch — nichts weiter zu tun.
# Danach: committen + pushen, im laufenden Chat /new ausführen.
```

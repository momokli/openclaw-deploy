#!/bin/bash
# build-benchmark.sh — leichte, opt-in Baseline-Messung für Build-/Test-Hosts.
#
# Sammelt einen vergleichbaren Ressourcen-Snapshot (Cores, Load, RAM, Disk, Toolchain)
# und — NUR mit explizitem --run — die Wall-Clock für einen kleinen, repräsentativen
# Node-Compute-Task. Zweck: Entscheidungsgrundlage für docs/build-host-strategy.md
# (Builds/Tests auf Planet, .149 nur Orchestrierung) und eine notierbare Baseline für
# Regressionen.
#
# SICHERHEIT:
#   * Dry-run per Default — druckt nur den Snapshot, stößt KEINE Builds an.
#   * Ein Tiny-Node-Compute-Task wird nur mit --run gemessen.
#   * Schwere Builds (neoForm, Gametests, Playwright, cargo test) werden NIE automatisch
#     ausgeführt.
#   * Nur `ssh` + Standard-Unix-Tools; keine Secrets, kein sshpass.
#
# Usage (aus dem Repo-Root oder von überall):
#   ./scripts/build-benchmark.sh [host] [--run]
#
#   host    SSH-Alias aus ssh_config: `planet` (Default, Hetzner) oder `lan` (.149).
#   --run   zusätzlich einen Tiny-Node-Compute-Task messen (repräsentativ, non-destruktiv).
#
# Beispiele:
#   ./scripts/build-benchmark.sh planet            # nur Snapshot (sicher)
#   ./scripts/build-benchmark.sh planet --run      # Snapshot + Micro-Compute
#   ./scripts/build-benchmark.sh lan               # ⚠️ .149: nur Snapshot, siehe Warnung

set -euo pipefail

SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)

warn() { printf '⚠️  %s\n' "$*" >&2; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argumente parsen ────────────────────────────────────────────────────
HOST=""
RUN=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --run) RUN=1 ;;
    -*) warn "unbekannte Option: $arg"; usage; exit 2 ;;
    *) HOST="$arg" ;;
  esac
done
HOST="${HOST:-planet}"

if ! command -v ssh >/dev/null 2>&1; then
  warn "ssh ist nicht installiert — Benchmark nicht möglich"
  exit 1
fi

# ── .149-Schutz: schwere Last dort vermeiden ────────────────────────────
case "$HOST" in
  lan|lan-local)
    warn "'$HOST' ist die Gateway-Kiste .149 (Load-Spitzen ~14/16 Cores, openclaw ~60 GiB)."
    warn "Schwere Builds/Benchmarks hier NICHT laufen lassen — Snapshot ok, --run nur wenn unbelastet."
    ;;
esac

echo "== Build-Benchmark: $HOST =="
if [ "$RUN" = "1" ]; then
  echo "(Modus: Snapshot + Micro-Compute)"
else
  echo "(Modus: dry-run — nur Snapshot; mit --run zusätzlich einen Tiny-Node-Compute-Task messen)"
fi
echo

# Eine SSH-Session: Snapshot immer, Micro-Compute nur bei RUN=1.
ssh "${SSH_OPTS[@]}" "$HOST" "RUN=$RUN bash -s" <<'REMOTE'
set -euo pipefail

echo "=== host ==="
hostname
uname -srmo 2>/dev/null || true

echo
echo "=== cpu ==="
nproc

echo
echo "=== load (1/5/15m) ==="
uptime

echo
echo "=== memory ==="
free -h

echo
echo "=== disk (/) ==="
df -h /

echo
echo "=== toolchain (vorhanden) ==="
for t in cargo rustc node npm java javac gradle docker gh git; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  %-8s %s\n' "$t" "$(command -v "$t")"
  else
    printf '  %-8s -\n' "$t"
  fi
done

echo
echo "=== docker (falls vorhanden) ==="
if command -v docker >/dev/null 2>&1; then
  printf '  laufende Container: %s\n' "$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
else
  echo '  docker nicht vorhanden'
fi

if [ "${RUN:-0}" = "1" ]; then
  echo
  echo "=== micro-benchmark: node (CPU-Loop, 20M Iterationen) ==="
  if command -v node >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/bench.js" <<'JS'
let s = 0;
for (let i = 0; i < 20_000_000; i++) s += i % 7;
console.log(s);
JS
    start="$(date +%s%N)"
    node "$tmp/bench.js" >/dev/null
    end="$(date +%s%N)"
    printf '  wall-clock: %d ms\n' "$(( (end - start) / 1000000 ))"
  else
    echo '  node nicht vorhanden — micro-benchmark übersprungen'
  fi
fi
REMOTE

echo
if [ "$RUN" = "1" ]; then
  echo "Fertig: Snapshot + Micro-Compute gemessen."
else
  echo "Dry-run: keine Build-Last ausgeführt."
  echo "Für eine kleine, repräsentative Zeitmessung: ./scripts/build-benchmark.sh $HOST --run"
fi

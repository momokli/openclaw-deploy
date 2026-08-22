#!/bin/bash
# Generate a self-contained cost dashboard (cost.html) from cost-history.json.
# Run on the .149 host after cost-snapshot.sh (or on demand).
set -euo pipefail
cd /opt/apps/openclaw
HIST="/opt/apps/openclaw/cost-history.json"
OUT="/opt/apps/openclaw/cost.html"

[ -f "$HIST" ] || { echo "no $HIST — run cost-snapshot.sh first"; exit 1; }
DATA="$(cat "$HIST")"

cat > /tmp/cost_template.html <<'HTML'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenClaw Cost</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; background: #0f1115; color: #e6e6e6; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { color: #6b7482; font-size: 12px; margin: 0 0 18px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 18px; }
  .card { background: #171a21; border: 1px solid #262b36; border-radius: 10px; padding: 16px; }
  .card h2 { font-size: 13px; margin: 0 0 10px; color: #9aa4b2; font-weight: 600; }
  canvas { max-height: 300px; }
</style>
</head>
<body>
<h1>🦞 OpenClaw Cost</h1>
<p class="sub">Balance = realer DeepSeek-Stand · est. cost = Token × Pro-off-peak-Preise (konservativ)</p>
<div class="grid">
  <div class="card"><h2>DeepSeek Balance ($)</h2><canvas id="balance"></canvas></div>
  <div class="card"><h2>Est. cost / day ($)</h2><canvas id="cost"></canvas></div>
  <div class="card"><h2>Output + Reasoning tokens</h2><canvas id="output"></canvas></div>
  <div class="card"><h2>Input tokens (miss vs cache-read)</h2><canvas id="input"></canvas></div>
  <div class="card"><h2>Model split (calls)</h2><canvas id="split"></canvas></div>
</div>
<script>
const data = __DATA__;
const labels = data.map(d => d.date);
const gridColor = '#262b36', tickColor = '#9aa4b2';
const fmt = (n) => n >= 1e6 ? (n/1e6).toFixed(1)+'M' : n >= 1e3 ? (n/1e3).toFixed(0)+'k' : (n ?? 0);
const est = data.map(d => (d.input*0.66 + d.cacheRead*0.022 + (d.output + d.reasoning)*1.98) / 1e6);

new Chart(document.getElementById('balance'), {
  type: 'line',
  data: { labels, datasets: [{
    label: 'Balance', data: data.map(d => d.balance),
    borderColor: '#4ade80', backgroundColor: 'rgba(74,222,128,0.15)',
    fill: true, tension: 0.3, spanGaps: true
  }]},
  options: {
    plugins: { legend: { display: false } },
    scales: {
      x: { grid: { color: gridColor }, ticks: { color: tickColor, maxRotation: 60 } },
      y: { grid: { color: gridColor }, ticks: { color: tickColor, callback: v => '$'+v } }
    }
  }
});

new Chart(document.getElementById('cost'), {
  type: 'bar',
  data: { labels, datasets: [{
    label: 'est. cost', data: est,
    backgroundColor: 'rgba(251,191,36,0.6)', borderColor: '#fbbf24', borderWidth: 1
  }]},
  options: {
    plugins: { legend: { display: false } },
    scales: {
      x: { grid: { color: gridColor }, ticks: { color: tickColor, maxRotation: 60 } },
      y: { grid: { color: gridColor }, ticks: { color: tickColor, callback: v => '$'+v.toFixed(1) } }
    }
  }
});

new Chart(document.getElementById('output'), {
  type: 'bar',
  data: { labels, datasets: [
    { label: 'Output', data: data.map(d => d.output), backgroundColor: '#38bdf8' },
    { label: 'Reasoning', data: data.map(d => d.reasoning), backgroundColor: '#a78bfa' }
  ]},
  options: {
    plugins: { legend: { labels: { color: tickColor } } },
    scales: {
      x: { stacked: true, grid: { color: gridColor }, ticks: { color: tickColor, maxRotation: 60 } },
      y: { stacked: true, grid: { color: gridColor }, ticks: { color: tickColor, callback: fmt } }
    }
  }
});

new Chart(document.getElementById('input'), {
  type: 'bar',
  data: { labels, datasets: [
    { label: 'Cache-Miss (input)', data: data.map(d => d.input), backgroundColor: '#f59e0b', yAxisID: 'y' },
    { label: 'Cache-Read', data: data.map(d => d.cacheRead), type: 'line', borderColor: '#64748b', yAxisID: 'y1', tension: 0.3 }
  ]},
  options: {
    plugins: { legend: { labels: { color: tickColor } } },
    scales: {
      x: { grid: { color: gridColor }, ticks: { color: tickColor, maxRotation: 60 } },
      y: { grid: { color: gridColor }, ticks: { color: tickColor, callback: fmt } },
      y1: { position: 'right', grid: { drawOnChartArea: false }, ticks: { color: '#64748b', callback: fmt } }
    }
  }
});

new Chart(document.getElementById('split'), {
  type: 'bar',
  data: { labels, datasets: [
    { label: 'Pro', data: data.map(d => d.pro), backgroundColor: '#ef4444' },
    { label: 'Flash', data: data.map(d => d.flash), backgroundColor: '#22c55e' }
  ]},
  options: {
    plugins: { legend: { labels: { color: tickColor } } },
    scales: {
      x: { stacked: true, grid: { color: gridColor }, ticks: { color: tickColor, maxRotation: 60 } },
      y: { stacked: true, grid: { color: gridColor }, ticks: { color: tickColor } }
    }
  }
});
</script>
</body>
</html>
HTML

sed "s|__DATA__|$DATA|" /tmp/cost_template.html > "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"

#!/bin/sh
# Live observer: poll gate's append-only log, re-audit every run against
# protocols/gate-run.parley, and print any classification changes — a new
# run appearing, a stalled run completing, or (the point) a DEVIATES line
# the moment history stops matching the protocol.
#
#   observer/watch_gate.sh            # 30s interval
#   INTERVAL=10 observer/watch_gate.sh
set -e
cd "$(dirname "$0")/.."

INTERVAL="${INTERVAL:-30}"
STATE_DIR="${TMPDIR:-/tmp}/parley-watch-gate"
mkdir -p "$STATE_DIR"
prev="$STATE_DIR/report.prev"
: > "$prev"

make -C compiler build >/dev/null
echo "watching gate's log; interval ${INTERVAL}s (ctrl-c to stop)"

while :; do
  python3 observer/extract_gate.py > "$STATE_DIR/traces.txt" 2>/dev/null
  compiler/bin/parleyc observe protocols/gate-run.parley "$STATE_DIR/traces.txt" \
    > "$STATE_DIR/report.new"
  if ! diff -q "$prev" "$STATE_DIR/report.new" >/dev/null 2>&1; then
    stamp="$(date +%H:%M:%S)"
    diff "$prev" "$STATE_DIR/report.new" | sed -n "s/^> /[$stamp] /p"
    mv "$STATE_DIR/report.new" "$prev"
  fi
  sleep "$INTERVAL"
done

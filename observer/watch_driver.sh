#!/bin/sh
# Live observer for ship driver runs — same shape as watch_gate.sh.
set -e
cd "$(dirname "$0")/.."

INTERVAL="${INTERVAL:-60}"
STATE_DIR="${TMPDIR:-/tmp}/parley-watch-driver"
mkdir -p "$STATE_DIR"
prev="$STATE_DIR/report.prev"
: > "$prev"

make -C compiler build >/dev/null
echo "watching driver-state; interval ${INTERVAL}s (ctrl-c to stop)"

while :; do
  python3 observer/extract_driver.py > "$STATE_DIR/traces.txt" 2>/dev/null
  compiler/bin/parleyc observe protocols/driver-run.parley "$STATE_DIR/traces.txt" \
    > "$STATE_DIR/report.new"
  if ! diff -q "$prev" "$STATE_DIR/report.new" >/dev/null 2>&1; then
    stamp="$(date +%H:%M:%S)"
    diff "$prev" "$STATE_DIR/report.new" | sed -n "s/^> /[$stamp] /p"
    mv "$STATE_DIR/report.new" "$prev"
  fi
  sleep "$INTERVAL"
done

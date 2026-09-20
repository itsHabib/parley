#!/bin/sh
# Exercise the installed CLI contract with synthetic, public inputs only.
set -eu
bin=${PARLEYC:-./bin/parleyc}
example=../examples/ci-check
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
expect() {
  want=$1
  shift
  got=0
  "$bin" "$@" >"$tmp/out" 2>"$tmp/err" || got=$?
  if [ "$got" -ne "$want" ]; then
    cat "$tmp/out" "$tmp/err"
    echo "expected exit $want, got $got: $*" >&2
    exit 1
  fi
}
p=$example/review.parley
expect 0 verify "$p" "$example/complete.trace"
expect 1 verify "$p" "$example/broken.trace"
grep -q 'expected.*got' "$tmp/out"
expect 1 verify "$p" "$example/interrupted.trace"
grep -q stalled "$tmp/out"
# Replay a retained prefix after the missing acknowledgement is recorded.
expect 0 verify "$p" "$example/recovered.trace"
expect 0 observe "$p" "$example/broken.trace"
: > "$tmp/empty"
expect 1 verify "$p" "$tmp/empty"
expect 1 observe "$p" "$example/broken.trace" "$tmp/empty"
printf 'run malformed\nauthor reviewer\n' > "$tmp/bad"
expect 1 verify "$p" "$tmp/bad"
grep -q 'bad trace line 2' "$tmp/err"
printf 'author reviewer request\n' > "$tmp/bad"
expect 1 verify "$p" "$tmp/bad"
grep -q 'before any run' "$tmp/err"
cat "$example/complete.trace" "$example/complete.trace" > "$tmp/bad"
expect 1 verify "$p" "$tmp/bad"
grep -q 'duplicate trace id' "$tmp/err"
cat "$example/recovered.trace" > "$tmp/bad"
printf 'reviewer author approved\n' >> "$tmp/bad"
expect 1 verify "$p" "$tmp/bad"
grep -q 'past the protocol' "$tmp/out"
expect 1 verify "$tmp/missing" "$example/complete.trace"
printf 'not a protocol\n' > "$tmp/bad"
expect 1 verify "$tmp/bad" "$example/complete.trace"
echo 'CLI: complete, deviation, interruption/recovery, report compatibility, empty, malformed, duplicate, extra event and missing input passed'

# An early empty branch must not hide a later matching loop branch.
cat > "$tmp/loop.parley" <<'PROTOCOL'
protocol loop-example
roles a b
loop rounds {
  a -> b: item
  choice b observes a {
    stop { }
    again { continue rounds }
  }
}
PROTOCOL
printf 'run two-rounds\na b item\na b item\n' > "$tmp/loop.trace"
expect 0 verify "$tmp/loop.parley" "$tmp/loop.trace"
# Reverse the branch order: the language accepted must not change.
cat > "$tmp/loop.parley" <<'PROTOCOL'
protocol loop-example
roles a b
loop rounds {
  a -> b: item
  choice b observes a {
    again { continue rounds }
    stop { }
  }
}
PROTOCOL
expect 0 verify "$tmp/loop.parley" "$tmp/loop.trace"
# A longer valid prefix remains stalled, not a deviation after a short branch.
cat > "$tmp/prefix.parley" <<'PROTOCOL'
protocol prefix-example
roles a b
choice a observes b {
  short { a -> b: first }
  long { a -> b: first a -> b: second a -> b: third }
}
PROTOCOL
printf 'run prefix\na b first\na b second\n' > "$tmp/prefix.trace"
expect 0 observe "$tmp/prefix.parley" "$tmp/prefix.trace"
grep -q '1 stalled, 0 deviating' "$tmp/out"
expect 1 verify "$tmp/prefix.parley" "$tmp/prefix.trace"
echo 'CLI: branch-order independence and shared-prefix interruption passed'

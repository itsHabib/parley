#!/bin/sh
# The whole kernel, end to end: compile the protocol, prove the claims,
# then boot the agents and watch the bus enforce what the compiler emitted.
set -e
cd "$(dirname "$0")"

echo "== plane 1: Haskell — compile the global protocol =="
make -C compiler build test emit check

echo
echo "== plane 3: Lean — check the theorems =="
( cd lean && lake build )

echo
echo "== plane 2: Gleam — run agents as processes behind the enforcing bus =="
( cd runtime && gleam test && gleam run )

#!/bin/sh
# Reproduce first use with standard Ubuntu packages and no host toolchain/state.
set -eu
cd "$(dirname "$0")/.."
image=parley-quickstart-toolchain
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ghc make libc6-dev && rm -rf /var/lib/apt/lists/*
DOCKERFILE
docker build -t "$image" "$tmp"
# Send only public source, with no .git, local binaries, caches, or home mount.
tar --exclude=compiler/bin --exclude=compiler/build -cf "$tmp/source.tar" compiler protocols examples LICENSE
docker run --rm -i --network none "$image" sh -eu -c '
  export LANG=C.UTF-8
  mkdir /source
  tar -xf - -C /source
  cd /source
  ghc --version
  make -C compiler build test
  make -C compiler install PREFIX=/tmp/installed
  cd compiler
  PARLEYC=/tmp/installed/bin/parleyc sh test/cli.sh
  cd /
  mkdir /tmp/inputs
  cp /source/examples/ci-check/review.parley /source/examples/ci-check/complete.trace /tmp/inputs/
  printf "# UTF-8 comment: café\n" >> /tmp/inputs/complete.trace
  rm -rf /source
  env -i HOME=/tmp PATH=/usr/bin:/bin /tmp/installed/bin/parleyc verify /tmp/inputs/review.parley /tmp/inputs/complete.trace
' < "$tmp/source.tar"

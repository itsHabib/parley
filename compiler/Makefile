GHC ?= ghc
GHCFLAGS = -Wall -Werror -isrc -outputdir build

.PHONY: build test emit check clean

build: bin/parleyc

bin/parleyc: src/Protocol.hs src/Emit.hs src/Example.hs app/Main.hs
	$(GHC) $(GHCFLAGS) --make app/Main.hs -o bin/parleyc

bin/spec: src/Protocol.hs src/Example.hs test/Spec.hs
	$(GHC) $(GHCFLAGS) --make test/Spec.hs -o bin/spec

test: bin/spec
	./bin/spec

emit: bin/parleyc
	./bin/parleyc emit ../contracts

check: bin/parleyc
	./bin/parleyc check

clean:
	rm -rf build bin/parleyc bin/spec

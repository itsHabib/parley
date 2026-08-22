GHC ?= ghc
GHCFLAGS = -Wall -Werror -isrc -outputdir build -package directory

.PHONY: build test emit check lint fmt clean

# hlint suggests idiomatic rewrites (declined ones live in .hlint.yaml);
# ormolu is the no-config canonical formatter. `make fmt` rewrites in place.
lint:
	hlint src app test
	ormolu --mode check src/*.hs app/*.hs test/*.hs

fmt:
	ormolu --mode inplace src/*.hs app/*.hs test/*.hs

build: bin/parleyc

bin/parleyc: src/Protocol.hs src/Emit.hs src/Example.hs src/Parse.hs app/Main.hs
	@mkdir -p $(@D)
	$(GHC) $(GHCFLAGS) --make app/Main.hs -o bin/parleyc

bin/spec: src/Protocol.hs src/Example.hs src/Parse.hs test/Spec.hs
	@mkdir -p $(@D)
	$(GHC) $(GHCFLAGS) --make test/Spec.hs -o bin/spec

test: bin/spec
	./bin/spec

emit: bin/parleyc
	./bin/parleyc emit ../contracts

check: bin/parleyc
	./bin/parleyc check

clean:
	rm -rf build bin/parleyc bin/spec

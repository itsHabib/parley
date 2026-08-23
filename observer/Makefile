# The observer as a check, not a report.
#
#   make -C observer check      # audit gate's live log; non-zero on surprise
#   make -C observer baseline   # rewrite the accepted shapes from today
#
# `check` reads ~/dev/gate/state/log.jsonl, so it is local-only and
# deliberately absent from .github/workflows/ci.yml — the log is private
# and does not exist on a runner. `observer/watch_gate.sh` is the live
# variant and goes through the same binary and the same protocol.
#
# `baseline` is a blunt instrument: it records whatever the log says today
# with no reason attached, and gate-run.expected requires a reason per
# line. Use it to see what changed, then write the file by hand.

PARLEYC := ../compiler/bin/parleyc
GATE_LOG := $(HOME)/dev/gate/state/log.jsonl
TRACES := $(shell echo $${TMPDIR:-/tmp})/parley-gate-traces.txt

.PHONY: check baseline traces

$(PARLEYC):
	$(MAKE) -C ../compiler build

traces: $(PARLEYC)
	@test -r $(GATE_LOG) || { echo "no gate log at $(GATE_LOG)"; exit 1; }
	@python3 extract_gate.py > $(TRACES)

check: traces
	@$(PARLEYC) observe ../protocols/gate-run.parley $(TRACES) gate-run.expected

baseline: traces
	@$(PARLEYC) observe ../protocols/gate-run.parley $(TRACES) \
	  | sed -n 's/^[^ ]* *DEVIATES *//p' | sort -u
	@echo
	@echo "^ shapes in the log today. gate-run.expected wants a reason per line."

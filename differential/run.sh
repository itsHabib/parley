#!/bin/sh
# Differential test: switchboard's own replay guard vs parley's protocol.
#
# Oracle A — switchboard `journal.replay`, which re-checks every committed
# event against the projection it lands on (transition_valid).
# Oracle B — `parleyc observe` over protocols/switchboard-session.parley.
#
# The Gleam program judges each sequence with oracle A and writes the same
# sequences as a parley trace file, tagging each with A's verdict. This
# script runs oracle B over that file and checks the two agree, mapping
# parley's classes onto accept/refuse:
#
#   complete | stalled -> accepts (a lawful run, or a lawful prefix)
#   deviating          -> refuses
#
# Exit 0 on full agreement, 1 on any disagreement.
set -e
cd "$(dirname "$0")"

TRACES=/tmp/parley-switchboard-traces.txt

gleam run >/dev/null 2>&1
make -C ../compiler build >/dev/null
../compiler/bin/parleyc observe ../protocols/switchboard-session.parley "$TRACES" \
  > /tmp/parley-switchboard-report.txt

python3 - "$TRACES" /tmp/parley-switchboard-report.txt <<'PY'
import re
import sys

traces, report = sys.argv[1], sys.argv[2]

switchboard = {}
labels = {}
pending = None
steps = None
for line in open(traces):
    line = line.strip()
    if line.startswith("# switchboard replay:"):
        pending = line.endswith("ACCEPTS")
    elif line.startswith("# steps:"):
        steps = line[len("# steps:"):].strip()
    elif line.startswith("run ") and pending is not None:
        switchboard[line[4:]] = pending
        labels[line[4:]] = steps
        pending = None

parley = {}
for line in open(report):
    match = re.match(r"^(\S+)\s+(complete|stalled|DEVIATES)", line)
    if match:
        parley[match.group(1)] = match.group(2) != "DEVIATES"

disagreements = []
for name, accepted in switchboard.items():
    if name not in parley:
        disagreements.append((name, accepted, None))
    elif parley[name] != accepted:
        disagreements.append((name, accepted, parley[name]))

print(f"{len(switchboard)} sequences, {sum(switchboard.values())} lawful by switchboard")
if not disagreements:
    print("AGREE on every sequence")
    raise SystemExit(0)
for name, a, b in disagreements:
    verdict = "absent" if b is None else ("accepts" if b else "refuses")
    print(
        f"DISAGREE [{labels.get(name)}]: "
        f"switchboard {'accepts' if a else 'refuses'}, parley {verdict}"
    )
print(f"\n{len(disagreements)} disagreement(s)")
raise SystemExit(1)
PY

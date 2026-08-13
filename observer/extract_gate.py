#!/usr/bin/env python3
"""Normalize gate's append-only log into parley observer traces.

Reads ~/dev/gate/state/log.jsonl (or argv[1]) and writes one trace per
gate run to stdout in the observer's plain-text format. The abstraction,
matching protocols/gate-run.parley:

  evidence records (collapsed per block)  -> collector gate evidence.bundle
  verdict block before any judgment       -> panel gate verdicts
  verdict block after a judgment          -> panel gate re.verdicts
  escalation                              -> gate judge escalation
  judgment                                -> judge gate judgment
  action                                  -> gate operator merge.command
  resolution                              -> operator gate resolution

Runs whose only record is grant_needed are refused before a run starts
(gate exit 3) and are skipped, with a count reported on stderr.
"""

import json
import sys
from collections import OrderedDict
from pathlib import Path

LOG = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "dev/gate/state/log.jsonl")


def main() -> None:
    runs: "OrderedDict[str, list[str]]" = OrderedDict()
    for line in LOG.read_text().splitlines():
        record = json.loads(line)
        run = record.get("run", "")
        if run.startswith("run_") and run != "run_mint":
            kind = record["kind"]
            # Two park flavors: grant-ceiling parks await a named human
            # resolution; everything else awaits the judge.
            if kind == "escalation" and record["body"].get("question", "").startswith("grant_"):
                kind = "ceiling"
            runs.setdefault(run, []).append(kind)

    skipped = 0
    for run, kinds in runs.items():
        if kinds == ["grant_needed"]:
            skipped += 1
            continue
        print(f"run {run}")
        for event in events(kinds):
            print(event)
        print()
    print(f"skipped {skipped} grant_needed-only refusals", file=sys.stderr)


def events(kinds: list[str]) -> list[str]:
    out = []
    seen_judgment = False
    index = 0
    while index < len(kinds):
        kind = kinds[index]
        # Collapse a block of consecutive identical kinds into one event.
        block_end = index
        while block_end < len(kinds) and kinds[block_end] == kind:
            block_end += 1
        index = block_end
        if kind == "evidence":
            out.append("collector gate evidence.bundle")
        elif kind == "verdict":
            out.append("panel gate re.verdicts" if seen_judgment else "panel gate verdicts")
        elif kind == "escalation":
            out.append("gate judge escalation")
        elif kind == "ceiling":
            out.append("gate operator escalation.ceiling")
        elif kind == "judgment":
            seen_judgment = True
            out.append("judge gate judgment")
        elif kind == "action":
            out.append("gate operator merge.command")
        elif kind == "resolution":
            out.append("operator gate resolution")
        else:
            out.append(f"unmapped unmapped {kind}")
    return out


if __name__ == "__main__":
    main()

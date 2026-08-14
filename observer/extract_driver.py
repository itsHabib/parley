#!/usr/bin/env python3
"""Normalize ship's driver-state stores into parley observer traces.

Reads ~/.workbench/driver-state/dsr_*/events.jsonl (or a dir from
argv[1]) and writes one trace per driver run to stdout. The abstraction,
matching protocols/driver-run.parley:

  run_imported       -> operator driver run.spec
  stream_dispatched  -> driver worker dispatch
  stream_attempt     -> worker driver attempt
  stream_pr_opened   -> worker repo pr.opened
  stream_merged      -> driver repo merge
  stream_skipped     -> driver operator skipped
  run_finished       -> driver operator finished

Every store observed so far is single-stream, so the stream label is
ignored; a multi-stream store would need per-stream traces.
"""

import json
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / ".workbench/driver-state")

EVENT = {
    "run_imported": "operator driver run.spec",
    "stream_dispatched": "driver worker dispatch",
    "stream_attempt": "worker driver attempt",
    "stream_pr_opened": "worker repo pr.opened",
    "stream_merged": "driver repo merge",
    "stream_skipped": "driver operator skipped",
    "run_finished": "driver operator finished",
}


def main() -> None:
    for store in sorted(ROOT.glob("dsr_*/events.jsonl")):
        records = [json.loads(line) for line in store.read_text().splitlines()]
        records.sort(key=lambda r: r["time"])
        print(f"run {store.parent.name}")
        for record in records:
            print(EVENT.get(record["kind"], f"unmapped unmapped {record['kind']}"))
        print()


if __name__ == "__main__":
    main()

# Verify a recorded review conversation

`review.parley` permits a request followed by either approval or rejection.
All inputs here are synthetic and contain no private logs. From the repository
root, after building or installing `parleyc`:

```sh
compiler/bin/parleyc verify examples/ci-check/review.parley examples/ci-check/complete.trace
compiler/bin/parleyc verify examples/ci-check/review.parley examples/ci-check/broken.trace
```

The first exits 0, the second exits 1. Rejection is a **complete** conversation;
complete means the protocol was followed, not that the review approved the work.

## Interrupted and recovered

```sh
compiler/bin/parleyc observe examples/ci-check/review.parley examples/ci-check/interrupted.trace
compiler/bin/parleyc verify examples/ci-check/review.parley examples/ci-check/interrupted.trace
compiler/bin/parleyc verify examples/ci-check/review.parley examples/ci-check/recovered.trace
```

The first prints `stalled` and exits 0; the second exits 1 because CI asked for
completed conversations. The third replays the same prefix plus a recorded
acknowledgement and exits 0. Parley performs no recovery action and never resends
the request. A stalled trace alone cannot tell you whether a worker crashed,
logging lost an event, or the operation is still in progress.

## Export your own trace

Write UTF-8 text with one unique `run <id>` header per conversation followed by
`sender receiver message` triples, in recorded order. Blank lines and `#`
comments are ignored. Identifiers cannot contain spaces or `#`. For example:

```text
run review-42
author reviewer request
reviewer author approved
```

Keep the exporter explicit: map named source events to named protocol messages,
reject unknown relevant events, and test that every expected source event is
represented. Do not export payloads, credentials or private content. Preserve
per-run ordering and separate conversations. Repeated run IDs are rejected;
concatenate events beneath the original header when replaying a longer prefix.
The checker cannot detect events your exporter silently drops.

`verify` exits 0 only for a nonempty file whose traces all complete. It exits 1
for deviations, stalled runs, empty input, invalid syntax or unreadable files.
`observe` reports complete/stalled/deviating and exits 0 for valid input; its
optional baseline argument makes unknown or stale deviation shapes fail.
Do not use plain `observe` as a CI gate.

## Limits

The observer checks a total ordered trace against the global protocol. It does
not infer concurrent interleavings, validate payloads, or consume the runtime
bus's branch-announcement events. Choice labels are inferred from message paths.
Use distinct messages to distinguish branches. This CLI cannot establish that
an approval concerns the current revision, that an effect happened once, or that
a reported event happened at all. Those checks belong in the producing system.

The compiler refuses choices where a participant would have to guess which
branch it is in, and unproductive loops. This can make an independent protocol
worth maintaining as branching grows; for this two-message example alone, a
small direct assertion is cheaper.

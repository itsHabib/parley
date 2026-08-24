# parley

A three-language agent coordination kernel: **Haskell compiles the protocol,
Gleam enforces it at runtime, Lean proves the two agree.**

A *parley* is a conversation conducted under protocol. Here the protocol is a
multi-agent workflow — the evidence-carrying-PR pipeline (producer →
collector → kernel → human → gate) — written **once**, as a single global
value, from which everything else is derived.

```sh
./demo.sh    # all three planes end to end: compile, prove, enforce
```

Needs GHC 9.6, Lean 4 (via `elan`), and Gleam 1.18 on OTP 27. Each plane also
builds on its own — see [Run everything](#run-everything).

The protocol algebra began as a throwaway build-hackathon entry, scored 82 and
refused promotion for "no immediate adoption boundary." The Gleam runtime **is**
that adoption boundary.

## The three planes

### 1. `compiler/` — Haskell, the compile plane

Protocols are plain-text files (`protocols/*.parley`):

```
protocol evidence-pipeline
roles producer collector kernel human gate

producer -> collector: evidence.receipt
choice collector observes producer kernel human gate {
  accepted  { collector -> kernel: validate ... }
  malformed { collector -> producer: receipt.rejected }
}
```

`parleyc compile <file.parley> <dir>` parses that into the global protocol
algebra (`Message`, `Choice`, `End`) and projects it into per-role
local contracts (`Send` / `Receive` / `Select` / `Offer` / `Done`). Projection
**refuses** incoherent protocols at the exact role and branch path:

- a role whose obligations differ across branches it cannot observe;
- self-messages, duplicate labels, a chooser observing its own choice,
  undeclared roles.

Compiled contracts are emitted as one JSON file per role into `contracts/` —
that JSON is the wire boundary between the planes. Dependency-free (base
only); build with `make -C compiler build test emit check`.

### 2. `runtime/` — Gleam, the run plane

Agents are BEAM processes. Every event goes through an **enforcing bus**
(`bus.gleam`) that holds a cursor per role over that role's compiled contract
and checks each event against *both* endpoints' cursors before delivery.

Honest agents need **zero role-specific code**: `agent.gleam` just interprets
the contract — send what it says, await what it expects, consult a scenario
plan at each choice. A rogue agent ignores its contract and fires a script;
its own conscience is gone, but the bus refuses the event by name:

```
=== ROGUE: kernel asserts assurance.pass without ever validating ===
  REFUSED refused at kernel: expected await branch announcement from collector
          [accepted, malformed]; got kernel -> gate assurance.pass
```

Run with `cd runtime && gleam run` (after `make -C compiler emit`).

### 3. `lean/` — Lean 4, the proof plane

The same algebra, projection, and enforcement engine mirrored in Lean, with
the demo's claims stated as theorems checked by computation (`native_decide`):

- the pipeline compiles into one contract per role;
- the gate-blind variant is refused at exactly `gate`;
- the runtime's happy trace drives every cursor to done, and no prefix of it
  stalls — the compiler and the bus agree about the whole run;
- the rogue kernel's first event is refused, and the refusal is *kernel's*
  obligation failing, not gate's.

Check with `cd lean && lake build`.

## Run everything

```sh
./demo.sh
```

## Observer mode — auditing real history

`parleyc observe <file.parley> <trace>` replays recorded traces against a
protocol and classifies each: **complete** (walks the protocol exactly),
**stalled** (a valid prefix — in flight or abandoned), or **deviating**
(an event the protocol cannot account for). No enforcement; a pure audit.

First real subject: the gate merge pipeline. `observer/extract_gate.py`
normalizes `~/dev/gate/state/log.jsonl` into traces;
`protocols/gate-run.parley` is the gate flow as actually practiced — an
outer `loop gather` for evidence re-polling, its park/judge/re-verdict
cycle expressed with `loop review { ... continue review ... }`, and each
round a four-way choice (pass / refused / to-judge / ceiling). Against the
full real history:

```
399 traces: 248 complete, 140 stalled, 11 deviating
```

The stalled are parked runs awaiting a judge/resolution (mostly
superseded — gate opens a fresh run per invocation and old parks stay
parked) plus in-flight runs. The 11 deviating are all one open question,
recorded in `observer/gate-run.expected` rather than modelled away: a
resolution (10) or a judgment (1) stamped onto a run that had already
emitted its merge command or its block. Whether a post-terminal
resolution confers merge authority is not something the log can answer,
so the protocol declines to assert one and the shape is raised with gate
as a finding.

**The observer is a check, not just a report.** Given a baseline it exits
non-zero on a deviation shape nobody has written down — and equally on a
baseline line that no longer describes anything, because a file that only
grows is not a check:

```sh
make -C observer check      # audits gate's live log
make -C observer baseline   # shows today's shapes, to be written up by hand
```

It stays out of CI on purpose: the gate log is local and private, and does
not exist on a runner.

Writing the protocol *discovered* structure the mental model missed:
ceiling parks (grant cycles exhausted) answered by a human resolution
instead of a judge; ceiling parks nonetheless re-judged; one run
(roll-call PR 11) that looped the judge four times — now pinned as the
Lean theorem `roll_call_run_conforms`. The judge loop originally forced a
744-line generated unroll; that pain is why the algebra grew `loop`.

Running the observer again after n-ary choices landed caught two more
things in live history. A workbench PR 227 run gathered evidence and
short-circuited with `already_merged` — never running the panel at all,
a path the protocol did not model (now the `noop` branch, pinned as
`already_merged_run_conforms`). And chasing it exposed that the extractor
was flattening gate's three action outcomes — `would_merge` (99),
`blocked` (71), `already_merged` (1) — into one event, counting 71
refusals as merges. Both fixed; the model is the more faithful for it.

**Live mode**: `observer/watch_gate.sh` polls the log and prints
classification changes as they happen — a deviation surfaces within one
poll interval of being appended.

Second subject: the ship driver loop. `observer/extract_driver.py` +
`protocols/driver-run.parley` (import → dispatch → attempt →
land/retry/skip, the retry cycle as a `loop`) audit
`~/.workbench/driver-state`:

```
236 traces: 40 complete, 196 stalled, 0 deviating
```

No deviations. **Read the stall bands with care, though**: 235 of those
236 runs carry `manifest.generated_by: "test"` and phase
`driver-cli-test` — they are fixture runs that leaked into the real
`~/.workbench/driver-state` ledger, not work. Exactly one run is real
(`work-driver-prep`, workbench, 2026-08-04) and it completed cleanly. An
earlier version of this section reported the stall bands as an
accountability gap; that was measuring the fixtures.

The lesson generalized: an observer is only as good as the provenance of
the history it replays. `observer/extract_driver.py` should learn to
filter on `generated_by` before any of these numbers mean anything.
`observer/watch_driver.sh` is the live variant.

## Differential test — switchboard's guard vs the protocol

`differential/` puts two independently written specifications of the same thing
against each other:

- **Oracle A** — [switchboard](https://github.com/itsHabib/switchboard)'s own
  replay guard: `transition_valid`, a hand-written exhaustive Gleam table.
- **Oracle B** — `protocols/switchboard-session.parley`, that same session
  lifecycle written as a protocol and compiled by `parleyc`.

`./differential/run.sh` enumerates **every** ordering of switchboard's ten
session events up to length four, replays each one through switchboard, and
checks the two verdicts agree:

```
11110 sequences, 19 lawful by switchboard
AGREE on every sequence
```

Enumeration earned its keep immediately: it found an ordering switchboard
accepts and the protocol refused — `start, user, reply-with-tool, stop`. A stop
is legal in *every* state, including the window between recording the model's
intent to call a tool and dispatching it. An earlier hand-picked set of 22
sequences missed it.

Two caveats. Switchboard is a private companion repo — unmodified and unaware
of parley, the dependency runs one way only — so this is the one section here
you cannot run yourself. And parley models *order*: the data predicates
switchboard also enforces (budget bounds, `req_id` matching, tool-call
freshness) are outside the protocol by design.

## The wire schema

`contracts/<role>.json`:

```json
{"role": "...", "protocol": "...", "contract": <node>}

<node> = {"t":"done"}
       | {"t":"send",    "to":R,   "msg":S, "then":<node>}
       | {"t":"receive", "from":R, "msg":S, "then":<node>}
       | {"t":"select",  "observers":[R], "branches":[{"label":L,"then":<node>}]}
       | {"t":"offer",   "from":R,        "branches":[{"label":L,"then":<node>}]}
       | {"t":"loop",    "name":N, "then":<node>}
       | {"t":"continue","name":N}
```

Choices are n-ary: `choice <chooser> observes <roles> { l1 {...} l2 {...}
l3 {...} }` takes any number of labelled branches (at least two — the
compiler refuses a one-branch "choice"). An unnotified role must have
identical obligations on *every* branch or projection refuses.

Loops: `loop <name> { ... }` repeats when a path reaches
`continue <name>`; walking off the end of the body exits. The compiler
refuses continues that target no enclosing loop, shadowed loop names, and
unproductive loops (a continue reachable without exchanging a message).
A role mentioned nowhere in a loop's body projects to done and is never
told the loop exists — unless a path through that body escapes to an
enclosing loop, in which case a branch taken inside it decides whether the
*outer* body runs again. Then the role is projected through after all, and
the ordinary observability rule refuses the protocol if the role would
have to guess.

Runtime events are payloads (`from -> to msg`) or branch announcements
(`from -> to branch:label`). A chooser announces its pick to every declared
observer before proceeding; every declared observer holds an `Offer` (the
compiler guarantees it — declared observers never silently collapse, only
undeclared roles with identical branches do).

## Divergences from the original prototype

- Declared observers always get an `Offer`, even when their branches are
  identical — the runtime chooser notifies every declared observer, so every
  declared observer must be able to receive the announcement. (The original
  collapsed equal branches for observers too, which is unenforceable.)
- The Lean `UnobservableChoice` carries path + role only, not the two locals.

## Where this could go

- Point switchboard's registry at the bus so real sessions run behind it.
- Prove projection faithfulness in general, not per-trace.
- More observed protocols: the ship driver loop, the channel review flows.

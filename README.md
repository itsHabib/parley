# parley

A three-language agent coordination kernel: **Haskell compiles the protocol,
Gleam enforces it at runtime, Lean proves the two agree.**

A *parley* is a conversation conducted under protocol. Here the protocol is a
multi-agent workflow — the evidence-carrying-PR pipeline (producer →
collector → kernel → human → gate) — written **once**, as a single global
value, from which everything else is derived.

Promoted out of the bakeoff archive: the protocol algebra began as
`bakeoff/haskell-08-10/protocol-compiler` (scored 82; refused promotion for
"no immediate adoption boundary"). The Gleam runtime **is** that adoption
boundary, in the style of switchboard's agents-as-processes.

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
`protocols/gate-run.parley` is the gate flow as actually practiced — its
park/judge/re-verdict cycle expressed with `loop review { ... continue
review ... }`. Against the full real history:

```
236 traces: 161 complete, 73 stalled, 2 deviating
```

The stalled are parked runs awaiting a judge/resolution (mostly
superseded — gate opens a fresh run per invocation and old parks stay
parked) plus in-flight runs. The 2 deviating are an Aug 2–4 2026 gate
behavior that stamped a resolution after a judged merge, since dropped.

Writing the protocol *discovered* structure the mental model missed:
ceiling parks (grant cycles exhausted) answered by a human resolution
instead of a judge; ceiling parks nonetheless re-judged; one run
(roll-call PR 11) that looped the judge four times — now pinned as the
Lean theorem `roll_call_run_conforms`. The judge loop originally forced a
744-line generated unroll; that pain is why the algebra grew `loop`.

**Live mode**: `observer/watch_gate.sh` polls the log and prints
classification changes as they happen — a deviation surfaces within one
poll interval of being appended.

Second subject: the ship driver loop. `observer/extract_driver.py` +
`protocols/driver-run.parley` (import → dispatch → attempt →
land/retry/skip, the retry cycle as a `loop`) audit
`~/.workbench/driver-state`:

```
214 traces: 37 complete, 177 stalled, 0 deviating
```

No deviations — but the stall bands are their own report: 117 runs
imported and never dispatched, 48 attempts abandoned with no
land/retry/skip decision, 9 dispatched awaiting a live worker.
`observer/watch_driver.sh` is the live variant.

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

Loops: `loop <name> { ... }` repeats when a path reaches
`continue <name>`; walking off the end of the body exits. The compiler
refuses continues that target no enclosing loop, shadowed loop names, and
unproductive loops (a continue reachable without exchanging a message).
A role mentioned nowhere in a loop's body projects to done and is never
told the loop exists.

Runtime events are payloads (`from -> to msg`) or branch announcements
(`from -> to branch:label`). A chooser announces its pick to every declared
observer before proceeding; every declared observer holds an `Offer` (the
compiler guarantees it — declared observers never silently collapse, only
undeclared roles with identical branches do).

## Divergences from the bakeoff original

- Declared observers always get an `Offer`, even when their branches are
  identical — the runtime chooser notifies every declared observer, so every
  declared observer must be able to receive the announcement. (The original
  collapsed equal branches for observers too, which is unenforceable.)
- The Lean `UnobservableChoice` carries path + role only, not the two locals.

## Where this could go

- N-ary choices, and choices between different responders (judgment vs
  resolution showed binary single-chooser choice is too narrow).
- Point switchboard's registry at the bus so real sessions run behind it.
- Prove projection faithfulness in general, not per-trace.
- More observed protocols: the ship driver loop, the channel review flows.

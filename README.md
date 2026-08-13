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

A global protocol algebra (`Message`, `Choice`, `End`) projected into per-role
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

## The wire schema

`contracts/<role>.json`:

```json
{"role": "...", "protocol": "...", "contract": <node>}

<node> = {"t":"done"}
       | {"t":"send",    "to":R,   "msg":S, "then":<node>}
       | {"t":"receive", "from":R, "msg":S, "then":<node>}
       | {"t":"select",  "observers":[R], "branches":[{"label":L,"then":<node>}]}
       | {"t":"offer",   "from":R,        "branches":[{"label":L,"then":<node>}]}
```

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

- Point switchboard's registry at the bus so real sessions run behind it.
- A `parleyc` protocol *parser* (today the protocol is a Haskell value).
- Multiparty choices (n-ary branches), loops/recursion in the algebra.
- Prove projection faithfulness in general, not per-trace.

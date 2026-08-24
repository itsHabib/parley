/-!
The proof plane. The same protocol algebra the Haskell compiler projects and
the same enforcement engine the Gleam bus runs, mirrored in Lean, with the
demo's and the observer's claims stated as theorems the compiler checks by
computation:

* the evidence pipeline compiles for every role;
* the gate-blind variant is refused at exactly `gate`, at the root;
* the happy trace the runtime prints is accepted end-to-end by every
  role's cursor, leaving every role done;
* the rogue kernel's first event is refused against kernel's own contract;
* the deepest real gate run in history conforms to the gate protocol.

Choices are n-ary: a choice carries a list of labelled branches, so
functions over the algebra are mutually recursive with a helper over that
branch list (the standard Lean idiom for nested recursion).
-/

namespace Parley

abbrev Role := String

abbrev Label := String

/-- The global protocol algebra (compiler/src/Protocol.hs `Protocol`). -/
inductive Protocol where
  | done : Protocol
  | message (sender receiver : Role) (payload : String) (rest : Protocol) : Protocol
  | choice (chooser : Role) (observers : List Role)
      (branches : List (Label × Protocol)) : Protocol
  | loop (name : Label) (body : Protocol) : Protocol
  | cont (name : Label) : Protocol
  deriving Repr

/-- A role's local obligations (compiler/src/Protocol.hs `Local`). -/
inductive Local where
  | done : Local
  | send (peer : Role) (payload : String) (rest : Local) : Local
  | recv (peer : Role) (payload : String) (rest : Local) : Local
  | select (observers : List Role) (branches : List (Label × Local)) : Local
  | offer (chooser : Role) (branches : List (Label × Local)) : Local
  | loopL (name : Label) (body : Local) : Local
  | contL (name : Label) : Local
  deriving Repr

/-! Structural equality, written by hand: `Local` is a nested inductive
(`List (Label × Local)`), which Lean's `DecidableEq` deriving handler does
not cover. Mutually recursive with the branch-list case, as everything
over this algebra is. -/
mutual

def localEq : Local → Local → Bool
  | .done, .done => true
  | .send peer₁ msg₁ rest₁, .send peer₂ msg₂ rest₂ =>
    peer₁ == peer₂ && msg₁ == msg₂ && localEq rest₁ rest₂
  | .recv peer₁ msg₁ rest₁, .recv peer₂ msg₂ rest₂ =>
    peer₁ == peer₂ && msg₁ == msg₂ && localEq rest₁ rest₂
  | .select observers₁ branches₁, .select observers₂ branches₂ =>
    observers₁ == observers₂ && localBranchesEq branches₁ branches₂
  | .offer chooser₁ branches₁, .offer chooser₂ branches₂ =>
    chooser₁ == chooser₂ && localBranchesEq branches₁ branches₂
  | .loopL name₁ body₁, .loopL name₂ body₂ => name₁ == name₂ && localEq body₁ body₂
  | .contL name₁, .contL name₂ => name₁ == name₂
  | _, _ => false

def localBranchesEq : List (Label × Local) → List (Label × Local) → Bool
  | [], [] => true
  | (label₁, local₁) :: rest₁, (label₂, local₂) :: rest₂ =>
    label₁ == label₂ && localEq local₁ local₂ && localBranchesEq rest₁ rest₂
  | _, _ => false

end

inductive CompileError where
  | duplicateRole (role : Role)
  | unknownRole (role : Role)
  | selfMessage (path : List Label) (role : Role) (payload : String)
  | duplicateChoiceLabel (path : List Label) (label : Label)
  | chooserAlsoObserver (path : List Label) (role : Role)
  | unobservableChoice (path : List Label) (role : Role)
  | tooFewBranches (path : List Label) (role : Role)
  | unknownLoop (path : List Label) (name : Label)
  | duplicateLoop (path : List Label) (name : Label)
  | unproductiveLoop (path : List Label) (name : Label)
  deriving Repr, DecidableEq

mutual

def mentionedRoles : Protocol → List Role
  | .done => []
  | .cont _ => []
  | .loop _ body => mentionedRoles body
  | .message sender receiver _ rest => sender :: receiver :: mentionedRoles rest
  | .choice chooser observers branches =>
    chooser :: observers ++ mentionedRolesIn branches

def mentionedRolesIn : List (Label × Protocol) → List Role
  | [] => []
  | (_, branch) :: rest => mentionedRoles branch ++ mentionedRolesIn rest

end

def firstDuplicate : List String → Option String
  | [] => none
  | value :: rest => if value ∈ rest then some value else firstDuplicate rest

/-! Whether any path through this protocol reaches a continue bound
further out than the loop being asked about (`compiler/src/Protocol.hs`
`escapesLoop`). `bound` accumulates the loops entered on the way down, so
a continue naming one of those stays inside; anything else leaves. -/
mutual

def escapesLoop (bound : List Label) : Protocol → Bool
  | .done => false
  | .cont name => !bound.contains name
  | .loop name body => escapesLoop (name :: bound) body
  | .message _ _ _ rest => escapesLoop bound rest
  | .choice _ _ branches => escapesLoopIn bound branches

def escapesLoopIn (bound : List Label) : List (Label × Protocol) → Bool
  | [] => false
  | (_, branch) :: rest => escapesLoop bound branch || escapesLoopIn bound rest

end

/-! Projection, mirroring the Haskell `project` decision for decision:
declared observers always receive an offer; undeclared roles may collapse
branches only when every branch leaves them identical obligations;
anything else is refused with the branch path. -/
mutual

def projectAt (role : Role) : Protocol → List Label → Except CompileError Local
  | .done, _ => .ok .done
  | .cont name, _ => .ok (.contL name)
  | .loop name body, path =>
    -- A body that can escape to an enclosing loop decides whether the
    -- *outer* body runs again, so a role with obligations out there must
    -- be projected through even when this body never mentions it.
    if (mentionedRoles body).contains role || escapesLoop [name] body then
      (projectAt role body path).map fun localBody =>
        if localEq localBody (.contL name) || localEq localBody .done then .done
        else .loopL name localBody
    else .ok .done
  | .message sender receiver payload rest, path =>
    if sender = receiver then .error (.selfMessage path sender payload)
    else if role = sender then (projectAt role rest path).map (.send receiver payload ·)
    else if role = receiver then (projectAt role rest path).map (.recv sender payload ·)
    else projectAt role rest path
  | .choice chooser observers branches, path =>
    if branches.length < 2 then .error (.tooFewBranches path chooser)
    else
      match firstDuplicate (branches.map (·.1)) with
      | some label => .error (.duplicateChoiceLabel path label)
      | none =>
        if chooser ∈ observers then .error (.chooserAlsoObserver path chooser)
        else
          (projectBranches role branches path).bind fun locals =>
            if role = chooser then .ok (.select observers locals)
            else if role ∈ observers then .ok (.offer chooser locals)
            else
              -- An unnotified role must have identical obligations on
              -- every branch, else it cannot know which one it is in.
              match locals with
              | [] => .error (.tooFewBranches path chooser)
              | (_, first) :: rest =>
                if rest.all (fun branch => localEq first branch.2) then .ok first
                else .error (.unobservableChoice path role)

def projectBranches (role : Role) :
    List (Label × Protocol) → List Label → Except CompileError (List (Label × Local))
  | [], _ => .ok []
  | (label, branch) :: rest, path =>
    (projectAt role branch (path ++ [label])).bind fun localBranch =>
      (projectBranches role rest path).map fun others => (label, localBranch) :: others

end

def project (role : Role) (protocol : Protocol) : Except CompileError Local :=
  projectAt role protocol []

mutual

def unguardedContinue : Protocol → Bool
  | .done => false
  | .cont _ => true
  | .message _ _ _ _ => false
  | .loop _ body => unguardedContinue body
  | .choice _ _ branches => unguardedContinueIn branches

def unguardedContinueIn : List (Label × Protocol) → Bool
  | [] => false
  | (_, branch) :: rest => unguardedContinue branch || unguardedContinueIn rest

end

mutual

def validateLoops (scope : List Label) (path : List Label) :
    Protocol → Except CompileError Unit
  | .done => .ok ()
  | .message _ _ _ rest => validateLoops scope path rest
  | .cont name =>
    if name ∈ scope then .ok () else .error (.unknownLoop path name)
  | .loop name body =>
    if name ∈ scope then .error (.duplicateLoop path name)
    else if unguardedContinue body then .error (.unproductiveLoop path name)
    else validateLoops (name :: scope) path body
  | .choice _ _ branches => validateLoopsIn scope path branches

def validateLoopsIn (scope : List Label) (path : List Label) :
    List (Label × Protocol) → Except CompileError Unit
  | [] => .ok ()
  | (label, branch) :: rest =>
    (validateLoops scope (path ++ [label]) branch).bind fun _ =>
      validateLoopsIn scope path rest

end

def compile (roles : List Role) (protocol : Protocol) :
    Except CompileError (List (Role × Local)) := do
  match firstDuplicate roles with
  | some role => .error (.duplicateRole role)
  | none =>
    match (mentionedRoles protocol).find? (· ∉ roles) with
    | some role => .error (.unknownRole role)
    | none => do
      validateLoops [] [] protocol
      roles.mapM fun role => (project role protocol).map (role, ·)

/-! ## The runtime enforcement engine (runtime/src/enforce.gleam) -/

inductive Event where
  | payload (source target msg : String)
  | announce (source target label : String)
  deriving Repr, DecidableEq

abbrev Env := List (Label × Local)

inductive Cursor where
  | at (node : Local) (env : Env)
  | announcing (label : Label) (remaining : List Role) (next : Local) (env : Env)
  deriving Repr

/-- Silently enter loops and re-enter bodies at continues. Fuelled for
termination; the compiler refuses unproductive loops, so fuel suffices. -/
def normalize : Nat → Cursor → Cursor
  | 0, cursor => cursor
  | fuel + 1, .at (.loopL name body) env => normalize fuel (.at body ((name, body) :: env))
  | fuel + 1, .at (.contL name) env =>
    match env.find? (·.1 = name) with
    | some (_, body) => normalize fuel (.at body env)
    | none => .at (.contL name) env
  | _, cursor => cursor

def stepOut (role : Role) (cursor : Cursor) (event : Event) : Option Cursor :=
  match normalize 64 cursor, event with
  | .at (.send to msg rest) env, .payload source target payload =>
    if source = role ∧ target = to ∧ payload = msg then some (.at rest env) else none
  | .at (.select observers branches) env, .announce source target label =>
    if source = role ∧ target ∈ observers then
      let remaining := observers.filter (· ≠ target)
      (branches.find? (·.1 = label)).map fun branch =>
        if remaining.isEmpty then .at branch.2 env
        else .announcing label remaining branch.2 env
    else none
  | .announcing chosen remaining next env, .announce source target label =>
    if source = role ∧ label = chosen ∧ target ∈ remaining then
      let rest := remaining.filter (· ≠ target)
      some (if rest.isEmpty then .at next env else .announcing chosen rest next env)
    else none
  | _, _ => none

def stepIn (role : Role) (cursor : Cursor) (event : Event) : Option Cursor :=
  match normalize 64 cursor, event with
  | .at (.recv peer msg rest) env, .payload source target payload =>
    if target = role ∧ source = peer ∧ payload = msg then some (.at rest env) else none
  | .at (.offer chooser branches) env, .announce source target label =>
    if target = role ∧ source = chooser then
      (branches.find? (·.1 = label)).map fun branch => .at branch.2 env
    else none
  | _, _ => none

abbrev BusState := List (Role × Cursor)

def endpoints : Event → Role × Role
  | .payload source target _ => (source, target)
  | .announce source target _ => (source, target)

def updateRole (state : BusState) (role : Role) (cursor : Cursor) : BusState :=
  state.map fun (r, c) => if r = role then (r, cursor) else (r, c)

/-- One bus routing step: the event must advance BOTH endpoint cursors. -/
def route (state : BusState) (event : Event) : Option BusState := do
  let (sender, receiver) := endpoints event
  let (_, senderCursor) ← state.find? (·.1 = sender)
  let (_, receiverCursor) ← state.find? (·.1 = receiver)
  let senderNext ← stepOut sender senderCursor event
  let receiverNext ← stepIn receiver receiverCursor event
  some (updateRole (updateRole state sender senderNext) receiver receiverNext)

def routeAll (state : BusState) : List Event → Option BusState
  | [] => some state
  | event :: rest => (route state event).bind (routeAll · rest)

def allDone (state : BusState) : Bool :=
  state.all fun (_, cursor) =>
    match normalize 64 cursor with
    | .at .done _ => true
    | _ => false

/-! ## The observer walk (compiler/src/Observe.hs) -/

mutual

/-- Global-trace conformance: walk the protocol, consuming events, trying
each branch of every choice. Returns leftover events on success. Fuelled
for termination. -/
def walk : Nat → List (Label × Protocol) → Protocol → List Event → Option (List Event)
  | 0, _, _, _ => none
  | _ + 1, _, .done, events => some events
  | fuel + 1, env, .loop name body, events => walk fuel ((name, body) :: env) body events
  | fuel + 1, env, .cont name, events =>
    match env.find? (·.1 = name) with
    | some (_, body) => walk fuel env body events
    | none => none
  | fuel + 1, env, .message sender receiver payload rest, events =>
    match events with
    | .payload s r p :: remaining =>
      if s = sender ∧ r = receiver ∧ p = payload then walk fuel env rest remaining else none
    | _ => none
  | fuel + 1, env, .choice _ _ branches, events => walkBranches fuel env branches events

def walkBranches :
    Nat → List (Label × Protocol) → List (Label × Protocol) → List Event →
      Option (List Event)
  | 0, _, _, _ => none
  | _ + 1, _, [], _ => none
  | fuel + 1, env, (_, branch) :: rest, events =>
    (walk fuel env branch events).orElse fun _ => walkBranches fuel env rest events

end

/-! ## The evidence pipeline (compiler/src/Example.hs) -/

def roles : List Role := ["producer", "collector", "kernel", "human", "gate"]

def validProtocol : Protocol :=
  .message "producer" "collector" "evidence.receipt" <|
    .choice "collector" ["producer", "kernel", "human", "gate"]
      [ ("accepted",
          .message "collector" "kernel" "validate" <|
            .choice "kernel" ["collector", "human", "gate"]
              [ ("pass", .message "kernel" "gate" "assurance.pass" .done),
                ("gap",
                  .message "kernel" "human" "assurance.gap" <|
                    .message "human" "gate" "judgment" .done) ]),
        ("malformed", .message "collector" "producer" "receipt.rejected" .done) ]

def invalidProtocol : Protocol :=
  .message "producer" "collector" "evidence.receipt" <|
    .choice "collector" ["producer", "kernel", "human"]
      [ ("accepted", .message "kernel" "gate" "assurance.pass" .done),
        ("malformed", .done) ]

def initialState : BusState :=
  match compile roles validProtocol with
  | .ok contracts => contracts.map fun (role, contract) => (role, .at contract [])
  | .error _ => []

/-- The exact trace the Gleam runtime prints for the accepted/pass run. -/
def happyTrace : List Event :=
  [ .payload "producer" "collector" "evidence.receipt",
    .announce "collector" "producer" "accepted",
    .announce "collector" "kernel" "accepted",
    .announce "collector" "human" "accepted",
    .announce "collector" "gate" "accepted",
    .payload "collector" "kernel" "validate",
    .announce "kernel" "collector" "pass",
    .announce "kernel" "human" "pass",
    .announce "kernel" "gate" "pass",
    .payload "kernel" "gate" "assurance.pass" ]

def rogueEvent : Event := .payload "kernel" "gate" "assurance.pass"

/-! ## The gate protocol (protocols/gate-run.parley) -/

def gateRoles : List Role := ["collector", "panel", "gate", "judge", "operator"]

private def parkResponse : Protocol :=
  .choice "operator" ["collector", "panel", "gate", "judge"]
    [ ("judged",
        .message "judge" "gate" "judgment" <|
          .message "panel" "gate" "re.verdicts" <| .cont "review"),
      ("resolved", .message "operator" "gate" "resolution" .done) ]

def gateProtocol : Protocol :=
  .message "collector" "gate" "evidence.bundle" <|
    .choice "gate" ["collector", "panel", "judge", "operator"]
      [ ("noop", .message "gate" "operator" "noop" .done),
        ("reviewed",
          .message "panel" "gate" "verdicts" <|
            .loop "review" <|
              .choice "gate" ["collector", "panel", "judge", "operator"]
                [ ("pass", .message "gate" "operator" "merge.command" .done),
                  ("refused", .message "gate" "operator" "blocked" .done),
                  ("tojudge", .message "gate" "judge" "escalation" parkResponse),
                  ("ceiling", .message "gate" "operator" "escalation.ceiling" parkResponse) ]) ]

/-- run_58f47c1b3f771b50 (roll-call PR 11): the deepest run in gate's real
history — parked four times, judged four times, merged on the fourth. -/
def rollCallTrace : List Event :=
  [ .payload "collector" "gate" "evidence.bundle",
    .payload "panel" "gate" "verdicts",
    .payload "gate" "judge" "escalation",
    .payload "judge" "gate" "judgment",
    .payload "panel" "gate" "re.verdicts",
    .payload "gate" "operator" "escalation.ceiling",
    .payload "judge" "gate" "judgment",
    .payload "panel" "gate" "re.verdicts",
    .payload "gate" "operator" "escalation.ceiling",
    .payload "judge" "gate" "judgment",
    .payload "panel" "gate" "re.verdicts",
    .payload "gate" "operator" "escalation.ceiling",
    .payload "judge" "gate" "judgment",
    .payload "panel" "gate" "re.verdicts",
    .payload "gate" "operator" "merge.command" ]

/-- run_3f1a7d3c122aaa32 (workbench PR 227): gate found the PR already
merged and short-circuited without ever running the panel. -/
def alreadyMergedTrace : List Event :=
  [ .payload "collector" "gate" "evidence.bundle",
    .payload "gate" "operator" "noop" ]

/-! ## The theorems -/

/-- The pipeline compiles into one local contract per role. -/
theorem valid_compiles :
    (compile roles validProtocol).toOption.map List.length = some roles.length := by
  native_decide

/-- Dropping gate from the outer observers is refused at gate, at the root. -/
theorem invalid_refused_at_gate :
    (match compile roles invalidProtocol with
      | .error (.unobservableChoice [] "gate") => true
      | _ => false) = true := by
  native_decide

/-- An undeclared role whose branches agree is lawfully collapsed. -/
theorem bystander_collapses :
    (match project "bystander" (.choice "a" ["b"] [("l", .done), ("r", .done)]) with
      | .ok .done => true
      | _ => false) = true := by
  native_decide

/-- A choice with fewer than two branches is not a choice. -/
theorem single_branch_refused :
    (match project "a" (.choice "a" ["b"] [("only", .done)]) with
      | .error (.tooFewBranches [] "a") => true
      | _ => false) = true := by
  native_decide

/-- The runtime's happy trace drives every role's cursor to done: the
compiled contracts and the enforcing bus agree about the whole run. -/
theorem happy_trace_conforms :
    (routeAll initialState happyTrace).map allDone = some true := by
  native_decide

/-- No prefix of the happy trace stalls: every event is accepted in order. -/
theorem happy_trace_never_refused :
    ∀ n : Fin happyTrace.length,
      (routeAll initialState (happyTrace.take n.1)).isSome = true := by
  native_decide

/-- The rogue kernel's very first event is refused against kernel's own
contract before anything is delivered. -/
theorem rogue_first_event_refused :
    (route initialState rogueEvent).isNone = true := by
  native_decide

/-- And the refusal is kernel's, not gate's: gate would have accepted the
payload had its turn come — kernel's obligation is what fails. -/
theorem rogue_refusal_is_kernels :
    (initialState.find? (·.1 = "kernel")).map
        (fun (_, cursor) => (stepOut "kernel" cursor rogueEvent).isNone) = some true := by
  native_decide

/-- The n-ary gate protocol compiles into one contract per role. -/
theorem gate_compiles :
    (compile gateRoles gateProtocol).toOption.map List.length = some gateRoles.length := by
  native_decide

/-- The deepest real run in gate's history conforms end-to-end: four
park/judge rounds, then the pinned merge. -/
theorem roll_call_run_conforms :
    walk 1000 [] gateProtocol rollCallTrace = some [] := by
  native_decide

/-- The already-merged short circuit conforms too — the path that the
observer found in live history and the protocol did not yet model. -/
theorem already_merged_run_conforms :
    walk 1000 [] gateProtocol alreadyMergedTrace = some [] := by
  native_decide

/-- A merge command with no verdicts before it does NOT conform. -/
theorem premature_merge_refused :
    walk 1000 [] gateProtocol
      [ .payload "collector" "gate" "evidence.bundle",
        .payload "gate" "operator" "merge.command" ] = none := by
  native_decide

/-- A loop that could spin without exchanging a message is refused. -/
theorem unproductive_loop_refused :
    (match compile ["a", "b"]
        (.loop "x" (.choice "a" ["b"] [("go", .cont "x"), ("stop", .done)])) with
      | .error (.unproductiveLoop [] "x") => true
      | _ => false) = true := by
  native_decide

/-- c decides whether the outer loop goes round again, and a — whose send
sits in that outer body — is nowhere in the inner one. Dropping a from the
inner loop would hand it a contract saying "send once, done" while the
protocol may require it to send again, so projection must refuse. -/
theorem escaping_inner_loop_refused :
    (match compile ["a", "b", "c", "d"]
        (.loop "o" (.message "a" "b" "m"
          (.loop "i" (.message "c" "d" "n"
            (.choice "c" ["d"] [("again", .cont "i"), ("out", .cont "o")]))))) with
      | .error (.unobservableChoice [] "a") => true
      | _ => false) = true := by
  native_decide

/-- The same shape with the inner choice staying inside its own loop: the
outer body then runs exactly once, so dropping the bystander is correct
and the refusal above must not fire. -/
theorem bound_inner_loop_still_collapses :
    (match project "a"
        (.loop "o" (.message "a" "b" "m"
          (.loop "i" (.message "c" "d" "n"
            (.choice "c" ["d"] [("again", .cont "i"), ("stop", .done)]))))) with
      | .ok (.loopL "o" (.send "b" "m" .done)) => true
      | _ => false) = true := by
  native_decide

end Parley

/-!
The proof plane. The same protocol algebra the Haskell compiler projects and
the same enforcement engine the Gleam bus runs, mirrored in Lean, with the
demo's claims stated as theorems the compiler checks by computation:

* the evidence pipeline compiles for every role;
* the gate-blind variant is refused at exactly `gate`, at the root;
* the happy trace the runtime prints is accepted end-to-end by every
  role's cursor, leaving every role done;
* the rogue kernel's first event is refused against kernel's own contract.
-/

namespace Parley

abbrev Role := String
abbrev Label := String

/-- The global protocol algebra (compiler/src/Protocol.hs `Protocol`). -/
inductive Protocol where
  | done : Protocol
  | message (sender receiver : Role) (payload : String) (rest : Protocol) : Protocol
  | choice (chooser : Role) (observers : List Role)
      (label₁ : Label) (branch₁ : Protocol)
      (label₂ : Label) (branch₂ : Protocol) : Protocol
  | loop (name : Label) (body : Protocol) : Protocol
  | cont (name : Label) : Protocol
  deriving Repr

/-- A role's local obligations (compiler/src/Protocol.hs `Local`). -/
inductive Local where
  | done : Local
  | send (peer : Role) (payload : String) (rest : Local) : Local
  | recv (peer : Role) (payload : String) (rest : Local) : Local
  | select (observers : List Role)
      (label₁ : Label) (branch₁ : Local)
      (label₂ : Label) (branch₂ : Local) : Local
  | offer (chooser : Role)
      (label₁ : Label) (branch₁ : Local)
      (label₂ : Label) (branch₂ : Local) : Local
  | loopL (name : Label) (body : Local) : Local
  | contL (name : Label) : Local
  deriving Repr, DecidableEq

inductive CompileError where
  | duplicateRole (role : Role)
  | unknownRole (role : Role)
  | selfMessage (path : List Label) (role : Role) (payload : String)
  | duplicateChoiceLabel (path : List Label) (label : Label)
  | chooserAlsoObserver (path : List Label) (role : Role)
  | unobservableChoice (path : List Label) (role : Role)
  | unknownLoop (path : List Label) (name : Label)
  | duplicateLoop (path : List Label) (name : Label)
  | unproductiveLoop (path : List Label) (name : Label)
  deriving Repr, DecidableEq

/-- Projection, mirroring the Haskell `project` decision for decision:
declared observers always receive an offer; undeclared roles may collapse
equal branches; anything else is refused with the branch path. -/
def mentionedRoles : Protocol → List Role
  | .done => []
  | .cont _ => []
  | .loop _ body => mentionedRoles body
  | .message sender receiver _ rest => sender :: receiver :: mentionedRoles rest
  | .choice chooser observers _ branch₁ _ branch₂ =>
    chooser :: observers ++ mentionedRoles branch₁ ++ mentionedRoles branch₂

def projectAt (role : Role) : Protocol → List Label → Except CompileError Local
  | .done, _ => .ok .done
  | .cont name, _ => .ok (.contL name)
  | .loop name body, path =>
    if role ∈ mentionedRoles body then
      (projectAt role body path).map fun localBody =>
        if localBody = .contL name ∨ localBody = .done then .done
        else .loopL name localBody
    else .ok .done
  | .message sender receiver payload rest, path =>
    if sender = receiver then .error (.selfMessage path sender payload)
    else if role = sender then (projectAt role rest path).map (.send receiver payload ·)
    else if role = receiver then (projectAt role rest path).map (.recv sender payload ·)
    else projectAt role rest path
  | .choice chooser observers label₁ branch₁ label₂ branch₂, path =>
    if label₁ = label₂ then .error (.duplicateChoiceLabel path label₁)
    else if chooser ∈ observers then .error (.chooserAlsoObserver path chooser)
    else if role = chooser then do
      let left ← projectAt role branch₁ (path ++ [label₁])
      let right ← projectAt role branch₂ (path ++ [label₂])
      .ok (.select observers label₁ left label₂ right)
    else do
      let left ← projectAt role branch₁ (path ++ [label₁])
      let right ← projectAt role branch₂ (path ++ [label₂])
      if role ∈ observers then .ok (.offer chooser label₁ left label₂ right)
      else if left = right then .ok left
      else .error (.unobservableChoice path role)

def project (role : Role) (protocol : Protocol) : Except CompileError Local :=
  projectAt role protocol []

def firstDuplicate : List Role → Option Role
  | [] => none
  | role :: rest => if role ∈ rest then some role else firstDuplicate rest

def unguardedContinue : Protocol → Bool
  | .done => false
  | .cont _ => true
  | .message _ _ _ _ => false
  | .loop _ body => unguardedContinue body
  | .choice _ _ _ branch₁ _ branch₂ =>
    unguardedContinue branch₁ || unguardedContinue branch₂

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
  | .choice _ _ label₁ branch₁ label₂ branch₂ => do
    validateLoops scope (path ++ [label₁]) branch₁
    validateLoops scope (path ++ [label₂]) branch₂

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
  deriving Repr, DecidableEq

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
  | .at (.select observers label₁ branch₁ label₂ branch₂) env, .announce source target label =>
    if source = role ∧ target ∈ observers then
      let remaining := observers.filter (· ≠ target)
      let chosen :=
        if label = label₁ then some branch₁
        else if label = label₂ then some branch₂
        else none
      chosen.map fun branch =>
        if remaining.isEmpty then .at branch env
        else .announcing label remaining branch env
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
  | .at (.offer chooser label₁ branch₁ label₂ branch₂) env, .announce source target label =>
    if target = role ∧ source = chooser then
      if label = label₁ then some (.at branch₁ env)
      else if label = label₂ then some (.at branch₂ env)
      else none
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

/-! ## The evidence pipeline (compiler/src/Example.hs) -/

def roles : List Role := ["producer", "collector", "kernel", "human", "gate"]

def validProtocol : Protocol :=
  .message "producer" "collector" "evidence.receipt" <|
    .choice "collector" ["producer", "kernel", "human", "gate"]
      "accepted"
      (.message "collector" "kernel" "validate" <|
        .choice "kernel" ["collector", "human", "gate"]
          "pass" (.message "kernel" "gate" "assurance.pass" .done)
          "gap"
            (.message "kernel" "human" "assurance.gap" <|
              .message "human" "gate" "judgment" .done))
      "malformed" (.message "collector" "producer" "receipt.rejected" .done)

def invalidProtocol : Protocol :=
  .message "producer" "collector" "evidence.receipt" <|
    .choice "collector" ["producer", "kernel", "human"]
      "accepted" (.message "kernel" "gate" "assurance.pass" .done)
      "malformed" .done

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

/-! ## The observer walk (compiler/src/Observe.hs) and the gate protocol -/

/-- Global-trace conformance: walk the protocol, consuming events, trying
both branches of every choice. Returns leftover events on success. Fuelled
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
  | fuel + 1, env, .choice _ _ _ branch₁ _ branch₂, events =>
    (walk fuel env branch₁ events).orElse fun _ => walk fuel env branch₂ events

def gateRoles : List Role := ["collector", "panel", "gate", "judge", "operator"]

/-- protocols/gate-run.parley, the recursive form. -/
def gateProtocol : Protocol :=
  .message "collector" "gate" "evidence.bundle" <|
    .message "panel" "gate" "verdicts" <|
      .loop "review" <|
        .choice "gate" ["collector", "panel", "judge", "operator"]
          "pass" (.message "gate" "operator" "merge.command" .done)
          "parked"
            (.choice "gate" ["collector", "panel", "judge", "operator"]
              "tojudge" (.message "gate" "judge" "escalation" parkResponse)
              "ceiling" (.message "gate" "operator" "escalation.ceiling" parkResponse))
where
  parkResponse : Protocol :=
    .choice "operator" ["collector", "panel", "gate", "judge"]
      "judged"
        (.message "judge" "gate" "judgment" <|
          .message "panel" "gate" "re.verdicts" <| .cont "review")
      "resolved" (.message "operator" "gate" "resolution" .done)

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

/-! ## The theorems -/

/-- The recursive gate protocol compiles into one contract per role. -/
theorem gate_compiles :
    (compile gateRoles gateProtocol).toOption.map List.length = some gateRoles.length := by
  native_decide

/-- The deepest real run in gate's history conforms to the recursive
protocol end-to-end: four park/judge rounds, then the pinned merge. -/
theorem roll_call_run_conforms :
    walk 1000 [] gateProtocol rollCallTrace = some [] := by
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
        (.loop "x" (.choice "a" ["b"] "go" (.cont "x") "stop" .done)) with
      | .error (.unproductiveLoop [] "x") => true
      | _ => false) = true := by
  native_decide

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
    (match project "bystander" (.choice "a" ["b"] "l" .done "r" .done) with
      | .ok .done => true
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
    route initialState rogueEvent = none := by
  native_decide

/-- And the refusal is kernel's, not gate's: gate would have accepted the
payload had its turn come — kernel's obligation is what fails. -/
theorem rogue_refusal_is_kernels :
    (initialState.find? (·.1 = "kernel")).map
        (fun (_, cursor) => stepOut "kernel" cursor rogueEvent) = some none := by
  native_decide

end Parley

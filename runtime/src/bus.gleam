//// The enforcing message bus: every event between agents passes through
//// here and is checked against BOTH endpoints' compiled contracts before
//// delivery. A rogue agent can abandon its own contract, but it cannot
//// make the bus deliver an event the protocol cannot account for.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import contract.{type Node}
import enforce.{type Cursor, type Event, At}

/// Messages an agent's inbox understands. Owned here so agents and the bus
/// can reference each other without an import cycle.
pub type AgentMsg {
  Kick
  Deliver(Event)
}

pub type Msg {
  Register(role: String, inbox: Subject(AgentMsg))
  Begin
  Emit(Event)
}

pub type ReportLine {
  Delivered(String)
  Refused(String)
  AllDone
}

type State {
  State(
    cursors: Dict(String, Cursor),
    inboxes: Dict(String, Subject(AgentMsg)),
    report: Subject(ReportLine),
    halted: Bool,
  )
}

pub fn start(
  contracts: List(#(String, Node)),
  report: Subject(ReportLine),
) -> actor.StartResult(Subject(Msg)) {
  let cursors =
    contracts
    |> list.map(fn(pair) { #(pair.0, At(pair.1, [])) })
    |> dict.from_list
  actor.new(State(cursors:, inboxes: dict.new(), report:, halted: False))
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Register(role:, inbox:) ->
      actor.continue(State(..state, inboxes: dict.insert(state.inboxes, role, inbox)))

    Begin -> {
      dict.each(state.inboxes, fn(_, inbox) { process.send(inbox, Kick) })
      actor.continue(state)
    }

    Emit(_) if state.halted -> actor.continue(state)

    Emit(event) -> actor.continue(route(state, event))
  }
}

fn route(state: State, event: Event) -> State {
  let #(sender, receiver) = endpoints(event)
  let checked = {
    use sender_cursor <- try_cursor(state, sender, event)
    use receiver_cursor <- try_cursor(state, receiver, event)
    use advanced_sender <- try_step(enforce.step_out(sender, sender_cursor, event))
    use advanced_receiver <- try_step(enforce.step_in(receiver, receiver_cursor, event))
    Ok(#(advanced_sender, advanced_receiver))
  }
  case checked {
    Error(violation) -> {
      process.send(state.report, Refused(enforce.describe_violation(violation)))
      State(..state, halted: True)
    }
    Ok(#(sender_cursor, receiver_cursor)) -> {
      let cursors =
        state.cursors
        |> dict.insert(sender, sender_cursor)
        |> dict.insert(receiver, receiver_cursor)
      process.send(state.report, Delivered(enforce.describe_event(event)))
      case dict.get(state.inboxes, receiver) {
        Ok(inbox) -> process.send(inbox, Deliver(event))
        Error(_) -> Nil
      }
      let next = State(..state, cursors:)
      case dict.values(cursors) |> list.all(enforce.is_done) {
        True -> {
          process.send(state.report, AllDone)
          State(..next, halted: True)
        }
        False -> next
      }
    }
  }
}

fn endpoints(event: Event) -> #(String, String) {
  case event {
    enforce.Payload(from:, to:, ..) -> #(from, to)
    enforce.Announce(from:, to:, ..) -> #(from, to)
  }
}

fn try_cursor(
  state: State,
  role: String,
  event: Event,
  next: fn(Cursor) -> Result(a, enforce.Violation),
) -> Result(a, enforce.Violation) {
  case dict.get(state.cursors, role) {
    Ok(cursor) -> next(cursor)
    Error(_) ->
      Error(enforce.Violation(
        role:,
        expected: "a declared protocol role",
        got: enforce.describe_event(event),
      ))
  }
}

fn try_step(
  result: Result(Cursor, enforce.Violation),
  next: fn(Cursor) -> Result(a, enforce.Violation),
) -> Result(a, enforce.Violation) {
  case result {
    Ok(cursor) -> next(cursor)
    Error(violation) -> Error(violation)
  }
}

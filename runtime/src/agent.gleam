//// Agents as processes. An honest agent needs no role-specific code at
//// all: it simply interprets its compiled contract — send what the
//// contract says, wait for what the contract expects, and consult its
//// scenario plan when the contract offers a choice. A rogue agent
//// ignores its contract and fires a script; the bus is what stops it.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import contract.{type Node, Branch, Offer, Receive, Select, Send}
import enforce.{type Event, Announce, At, Payload}
import bus.{type AgentMsg, Deliver, Kick}

type State {
  State(
    role: String,
    cursor: enforce.Cursor,
    // Labels to pick at each Select this scenario, outermost first.
    plan: List(String),
    bus: Subject(bus.Msg),
  )
}

pub fn start_honest(
  role: String,
  node: Node,
  plan: List(String),
  bus_subject: Subject(bus.Msg),
) -> actor.StartResult(Subject(AgentMsg)) {
  actor.new(State(role:, cursor: At(node, []), plan:, bus: bus_subject))
  |> actor.on_message(handle_honest)
  |> actor.start
}

fn handle_honest(state: State, msg: AgentMsg) -> actor.Next(State, AgentMsg) {
  case msg {
    Kick -> actor.continue(drive(state))
    Deliver(event) -> actor.continue(drive(absorb(state, event)))
  }
}

/// Advance through everything the contract obliges us to emit, stopping
/// when the contract next expects input (or is done).
fn drive(state: State) -> State {
  case enforce.normalize(state.cursor) {
    At(Send(to:, msg:, then:), env) -> {
      emit(state, Payload(from: state.role, to:, msg:))
      drive(State(..state, cursor: At(then, env)))
    }
    At(Select(observers:, branches:), env) ->
      case state.plan {
        [label, ..plan] ->
          case list.find(branches, fn(branch) { branch.label == label }) {
            Ok(Branch(then:, ..)) -> {
              list.each(observers, fn(observer) {
                emit(state, Announce(from: state.role, to: observer, label:))
              })
              drive(State(..state, cursor: At(then, env), plan:))
            }
            Error(_) -> state
          }
        [] -> state
      }
    _ -> state
  }
}

/// Advance past the input the bus just delivered (it already validated it).
fn absorb(state: State, event: Event) -> State {
  case enforce.normalize(state.cursor), event {
    At(Receive(then:, ..), env), Payload(..) -> State(..state, cursor: At(then, env))
    At(Offer(branches:, ..), env), Announce(label:, ..) ->
      case list.find(branches, fn(branch) { branch.label == label }) {
        Ok(Branch(then:, ..)) -> State(..state, cursor: At(then, env))
        Error(_) -> state
      }
    _, _ -> state
  }
}

fn emit(state: State, event: Event) -> Nil {
  process.send(state.bus, bus.Emit(event))
}

/// A rogue agent: fires its script on Kick, contract be damned.
pub fn start_rogue(
  script: List(Event),
  bus_subject: Subject(bus.Msg),
) -> actor.StartResult(Subject(AgentMsg)) {
  actor.new(#(script, bus_subject))
  |> actor.on_message(handle_rogue)
  |> actor.start
}

fn handle_rogue(
  state: #(List(Event), Subject(bus.Msg)),
  msg: AgentMsg,
) -> actor.Next(#(List(Event), Subject(bus.Msg)), AgentMsg) {
  let #(script, bus_subject) = state
  case msg {
    Kick -> {
      list.each(script, fn(event) { process.send(bus_subject, bus.Emit(event)) })
      actor.continue(state)
    }
    Deliver(_) -> actor.continue(state)
  }
}

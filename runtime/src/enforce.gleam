//// The pure enforcement engine: a role's cursor walks its compiled local
//// contract, and every event either advances the cursor or is a named
//// violation. The router holds one cursor per role and refuses any event
//// that either endpoint's contract cannot account for — this is the
//// runtime twin of the compiler's projection refusal.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import contract.{type Branch, type Node, Done, Offer, Receive, Select, Send}

/// What actually moves between agents at runtime: a protocol payload, or a
/// chooser announcing which branch it took to one observer.
pub type Event {
  Payload(from: String, to: String, msg: String)
  Announce(from: String, to: String, label: String)
}

/// A role's position in its contract. `Announcing` is the transient state of
/// a chooser that has picked a branch but not yet notified every observer.
pub type Cursor {
  At(Node)
  Announcing(label: String, remaining: List(String), then: Node)
}

pub type Violation {
  Violation(role: String, expected: String, got: String)
}

/// Check an event against its sender's cursor.
pub fn step_out(
  role: String,
  cursor: Cursor,
  event: Event,
) -> Result(Cursor, Violation) {
  case cursor, event {
    At(Send(to:, msg:, then:)), Payload(from:, to: target, msg: payload)
      if from == role && target == to && payload == msg
    -> Ok(At(then))

    At(Select(observers:, branches:)), Announce(from:, to:, label:)
      if from == role
    ->
      case pick_branch(branches, label), list.contains(observers, to) {
        Some(branch), True ->
          Ok(advance_announcing(label, list.filter(observers, fn(o) { o != to }), branch.then))
        _, _ -> refuse(role, cursor, event)
      }

    Announcing(label: chosen, remaining:, then:), Announce(from:, to:, label:)
      if from == role && label == chosen
    ->
      case list.contains(remaining, to) {
        True ->
          Ok(advance_announcing(chosen, list.filter(remaining, fn(o) { o != to }), then))
        False -> refuse(role, cursor, event)
      }

    _, _ -> refuse(role, cursor, event)
  }
}

/// Check an event against its receiver's cursor.
pub fn step_in(
  role: String,
  cursor: Cursor,
  event: Event,
) -> Result(Cursor, Violation) {
  case cursor, event {
    At(Receive(from:, msg:, then:)), Payload(from: sender, to:, msg: payload)
      if to == role && sender == from && payload == msg
    -> Ok(At(then))

    At(Offer(from:, branches:)), Announce(from: sender, to:, label:)
      if to == role && sender == from
    ->
      case pick_branch(branches, label) {
        Some(branch) -> Ok(At(branch.then))
        None -> refuse(role, cursor, event)
      }

    _, _ -> refuse(role, cursor, event)
  }
}

pub fn is_done(cursor: Cursor) -> Bool {
  cursor == At(Done)
}

fn advance_announcing(label: String, remaining: List(String), then: Node) -> Cursor {
  case remaining {
    [] -> At(then)
    _ -> Announcing(label:, remaining:, then:)
  }
}

fn pick_branch(branches: List(Branch), label: String) -> Option(Branch) {
  case list.find(branches, fn(branch) { branch.label == label }) {
    Ok(branch) -> Some(branch)
    Error(_) -> None
  }
}

fn refuse(role: String, cursor: Cursor, event: Event) -> Result(Cursor, Violation) {
  Error(Violation(role:, expected: describe_cursor(cursor), got: describe_event(event)))
}

pub fn describe_event(event: Event) -> String {
  case event {
    Payload(from:, to:, msg:) -> from <> " -> " <> to <> " " <> msg
    Announce(from:, to:, label:) -> from <> " -> " <> to <> " branch:" <> label
  }
}

pub fn describe_cursor(cursor: Cursor) -> String {
  case cursor {
    At(Done) -> "done (no further obligations)"
    At(Send(to:, msg:, ..)) -> "send " <> msg <> " to " <> to
    At(Receive(from:, msg:, ..)) -> "receive " <> msg <> " from " <> from
    At(Select(observers:, ..)) ->
      "announce a branch to [" <> string.join(observers, ", ") <> "]"
    At(Offer(from:, branches:)) ->
      "await branch announcement from "
      <> from
      <> " ["
      <> string.join(list.map(branches, fn(b) { b.label }), ", ")
      <> "]"
    Announcing(label:, remaining:, ..) ->
      "announce branch:" <> label <> " to [" <> string.join(remaining, ", ") <> "]"
  }
}

pub fn describe_violation(violation: Violation) -> String {
  "refused at "
  <> violation.role
  <> ": expected "
  <> violation.expected
  <> "; got "
  <> violation.got
}

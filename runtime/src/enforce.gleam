//// The pure enforcement engine: a role's cursor walks its compiled local
//// contract, and every event either advances the cursor or is a named
//// violation. The router holds one cursor per role and refuses any event
//// that either endpoint's contract cannot account for — this is the
//// runtime twin of the compiler's projection refusal.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import contract.{type Branch, type Node, Continue, Done, Loop, Offer, Receive, Select, Send}

/// What actually moves between agents at runtime: a protocol payload, or a
/// chooser announcing which branch it took to one observer.
pub type Event {
  Payload(from: String, to: String, msg: String)
  Announce(from: String, to: String, label: String)
}

/// Loop bodies entered so far, so `Continue` can re-enter them.
pub type Env =
  List(#(String, Node))

/// A role's position in its contract. `Announcing` is the transient state of
/// a chooser that has picked a branch but not yet notified every observer.
pub type Cursor {
  At(node: Node, env: Env)
  Announcing(label: String, remaining: List(String), then: Node, env: Env)
}

/// Step silently through loop entries and continues until the cursor
/// rests on a node that exchanges something (or is done). Fuelled as a
/// backstop; the compiler already refuses unproductive loops.
pub fn normalize(cursor: Cursor) -> Cursor {
  do_normalize(cursor, 64)
}

fn do_normalize(cursor: Cursor, fuel: Int) -> Cursor {
  case cursor {
    _ if fuel <= 0 -> cursor
    At(Loop(name:, then:), env) ->
      do_normalize(At(then, [#(name, then), ..env]), fuel - 1)
    At(Continue(name:), env) ->
      case list.key_find(env, name) {
        Ok(body) -> do_normalize(At(body, env), fuel - 1)
        Error(_) -> cursor
      }
    _ -> cursor
  }
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
  let cursor = normalize(cursor)
  case cursor, event {
    At(Send(to:, msg:, then:), env), Payload(from:, to: target, msg: payload)
      if from == role && target == to && payload == msg
    -> Ok(At(then, env))

    At(Select(observers:, branches:), env), Announce(from:, to:, label:)
      if from == role
    ->
      case pick_branch(branches, label), list.contains(observers, to) {
        Some(branch), True ->
          Ok(advance_announcing(
            label,
            list.filter(observers, fn(o) { o != to }),
            branch.then,
            env,
          ))
        _, _ -> refuse(role, cursor, event)
      }

    Announcing(label: chosen, remaining:, then:, env:), Announce(from:, to:, label:)
      if from == role && label == chosen
    ->
      case list.contains(remaining, to) {
        True ->
          Ok(advance_announcing(
            chosen,
            list.filter(remaining, fn(o) { o != to }),
            then,
            env,
          ))
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
  let cursor = normalize(cursor)
  case cursor, event {
    At(Receive(from:, msg:, then:), env), Payload(from: sender, to:, msg: payload)
      if to == role && sender == from && payload == msg
    -> Ok(At(then, env))

    At(Offer(from:, branches:), env), Announce(from: sender, to:, label:)
      if to == role && sender == from
    ->
      case pick_branch(branches, label) {
        Some(branch) -> Ok(At(branch.then, env))
        None -> refuse(role, cursor, event)
      }

    _, _ -> refuse(role, cursor, event)
  }
}

pub fn is_done(cursor: Cursor) -> Bool {
  case normalize(cursor) {
    At(Done, _) -> True
    _ -> False
  }
}

fn advance_announcing(
  label: String,
  remaining: List(String),
  then: Node,
  env: Env,
) -> Cursor {
  case remaining {
    [] -> At(then, env)
    _ -> Announcing(label:, remaining:, then:, env:)
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
  case normalize(cursor) {
    At(Done, _) -> "done (no further obligations)"
    At(Send(to:, msg:, ..), _) -> "send " <> msg <> " to " <> to
    At(Receive(from:, msg:, ..), _) -> "receive " <> msg <> " from " <> from
    At(Select(observers:, ..), _) ->
      "announce a branch to [" <> string.join(observers, ", ") <> "]"
    At(Offer(from:, branches:), _) ->
      "await branch announcement from "
      <> from
      <> " ["
      <> string.join(list.map(branches, fn(b) { b.label }), ", ")
      <> "]"
    At(Loop(name:, ..), _) -> "enter loop " <> name
    At(Continue(name:), _) -> "continue loop " <> name
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

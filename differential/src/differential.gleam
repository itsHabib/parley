//// Differential test: two independent oracles for "is this ordering of
//// session events legal?"
////
////   A. switchboard's own replay guard — `journal.replay` re-checks every
////      committed event against the projection it lands on
////      (transition_valid in src/journal.gleam).
////   B. parley's protocol walk — protocols/switchboard-session.parley
////      compiled and replayed by `parleyc observe`.
////
//// This program enumerates event sequences, asks oracle A about each, and
//// writes the same sequences out as a parley trace file so oracle B can be
//// asked too. Any sequence the two disagree about is a gap in one of them:
//// either the protocol is missing a real path, or switchboard's hand-written
//// table admits an ordering the protocol says is impossible.
////
//// Parley models ORDER only, so sequences here vary order alone: every
//// generated event carries data switchboard accepts (budget in range,
//// non-empty text, matching ids).

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import domain
import journal

/// The event vocabulary, in the abstraction parley's protocol uses. Ids are
/// filled in per-sequence so the data predicates always pass.
pub type Step {
  Start
  UserMessage
  Epoch
  Reply
  ReplyWithTool
  ModelFailed
  ToolIntent
  ToolResult
  ToolFailed
  Stop
}

pub fn main() -> Nil {
  let sequences = generate()
  let rows = list.index_map(sequences, judge)
  write_trace_file(rows)
  report(rows)
}

// --- oracle A: switchboard's own replay guard ---

/// Build the journal a sequence implies and ask switchboard to replay it.
/// A sequence is legal iff every event was accepted in order.
fn switchboard_accepts(steps: List(Step), path: String) -> Bool {
  let _ = simplifile.delete(path)
  // Generation starts at 0: the first user message opens req-1.
  let events = to_events(steps, 0, 1, [])
  let lines =
    events
    |> list.index_map(fn(event, index) {
      journal.encode(journal.Envelope(version: 1, sequence: index + 1, event:))
    })
    |> string.join("\n")
  let contents = case lines {
    "" -> ""
    _ -> lines <> "\n"
  }
  case simplifile.write(to: path, contents:) {
    Error(_) -> False
    Ok(_) ->
      case journal.replay(path) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

/// Turn abstract steps into concrete switchboard events, threading the
/// request/call generations so id predicates are satisfied whenever the
/// ordering itself is legal.
fn to_events(
  steps: List(Step),
  generation: Int,
  call: Int,
  acc: List(domain.Event),
) -> List(domain.Event) {
  // `generation` is the request generation currently outstanding; `call` the
  // tool-call counter. Both are threaded so ids match whenever the ORDER is
  // lawful — otherwise a data mismatch would masquerade as an ordering bug.
  case steps {
    [] -> list.reverse(acc)
    [step, ..rest] -> {
      let req = "req-" <> int.to_string(generation)
      let call_id = "call-" <> int.to_string(call)
      case step {
        Start ->
          to_events(rest, generation, call, [
            domain.SessionStarted("sys", 1_000_000),
            ..acc
          ])
        // A user message and a tool result each open a new model request
        // generation (evolve.gleam), so the next reply must name req-(n+1).
        UserMessage ->
          to_events(rest, generation + 1, call, [
            domain.UserMessageRecorded("hello", 0),
            ..acc
          ])
        Epoch ->
          to_events(rest, generation + 1, call, [
            domain.ModelRequestEpochRecorded("req-" <> int.to_string(generation + 1)),
            ..acc
          ])
        Reply ->
          to_events(rest, generation, call, [
            domain.ModelReplyRecorded(
              req,
              domain.ModelReply("ok", None),
              domain.Usage(1, 1),
            ),
            ..acc
          ])
        ReplyWithTool ->
          to_events(rest, generation, call, [
            domain.ModelReplyRecorded(
              req,
              domain.ModelReply("ok", Some(domain.ToolCall(call_id, "t", "{}"))),
              domain.Usage(1, 1),
            ),
            ..acc
          ])
        ModelFailed ->
          to_events(rest, generation, call, [
            domain.ModelFailedRecorded(req, "boom", 0),
            ..acc
          ])
        ToolIntent ->
          to_events(rest, generation, call, [
            domain.ToolCallIntentRecorded(call_id, "t", "{}"),
            ..acc
          ])
        ToolResult ->
          to_events(rest, generation + 1, call + 1, [
            domain.ToolResultRecorded(call_id, "out", 0),
            ..acc
          ])
        ToolFailed ->
          to_events(rest, generation, call + 1, [
            domain.ToolFailedRecorded(call_id, "boom", 0),
            ..acc
          ])
        Stop ->
          to_events(rest, generation, call, [domain.SessionStopped("bye"), ..acc])
      }
    }
  }
}

// --- the sequences under test ---

/// Hand-picked orderings: every lawful lifecycle path, plus the out-of-turn
/// orderings that should be refused. Enumerating all permutations would drown
/// the signal; these are the ones that distinguish the two oracles.
fn generate() -> List(#(String, List(Step))) {
  [
    // Lawful.
    #("start only", [Start]),
    #("start, stop", [Start, Stop]),
    #("one plain turn", [Start, UserMessage, Reply]),
    #("turn then stop", [Start, UserMessage, Reply, Stop]),
    #("two turns", [Start, UserMessage, Reply, UserMessage, Reply]),
    #("model failure then retry turn", [Start, UserMessage, ModelFailed, UserMessage, Reply]),
    #("recovery epoch then reply", [Start, UserMessage, Epoch, Reply]),
    #("tool round trip", [Start, UserMessage, ReplyWithTool, ToolIntent, ToolResult, Reply]),
    #("tool failure returns to idle", [
      Start, UserMessage, ReplyWithTool, ToolIntent, ToolFailed, UserMessage, Reply,
    ]),
    #("two tool rounds", [
      Start, UserMessage, ReplyWithTool, ToolIntent, ToolResult, ReplyWithTool, ToolIntent,
      ToolResult, Reply,
    ]),
    #("stop mid-tool", [Start, UserMessage, ReplyWithTool, ToolIntent, Stop]),
    #("stop while awaiting model", [Start, UserMessage, Stop]),
    // Should be refused.
    #("user message before start", [UserMessage]),
    #("reply before any user message", [Start, Reply]),
    #("double start", [Start, Start]),
    #("anything after stop", [Start, Stop, UserMessage]),
    #("tool result without intent", [Start, UserMessage, ReplyWithTool, ToolResult]),
    #("tool intent with no tool call", [Start, UserMessage, ToolIntent]),
    #("two replies in a row", [Start, UserMessage, Reply, Reply]),
    #("user message while awaiting model", [Start, UserMessage, UserMessage]),
    #("tool result while awaiting model", [Start, UserMessage, ToolResult]),
    #("epoch before any turn", [Start, Epoch]),
  ]
}

// --- oracle B's input, and the report ---

fn judge(entry: #(String, List(Step)), index: Int) -> #(String, List(Step), Bool) {
  let #(name, steps) = entry
  let path = "/tmp/parley-differential-" <> int.to_string(index) <> ".jsonl"
  #(name, steps, switchboard_accepts(steps, path))
}

/// Emit the same sequences in parley's observer trace format, so
/// `parleyc observe protocols/switchboard-session.parley <file>` judges
/// exactly what switchboard just judged.
fn write_trace_file(rows: List(#(String, List(Step), Bool))) -> Nil {
  let body =
    rows
    |> list.map(fn(row) {
      let #(name, steps, accepted) = row
      let header =
        "# switchboard replay: "
        <> case accepted {
          True -> "ACCEPTS"
          False -> "REFUSES"
        }
      let slug = string.replace(name, " ", "_")
      let events = steps |> list.map(trace_line) |> string.join("\n")
      header <> "\nrun " <> slug <> "\n" <> events
    })
    |> string.join("\n\n")
  let _ = simplifile.write(to: "/tmp/parley-switchboard-traces.txt", contents: body <> "\n")
  Nil
}

fn trace_line(step: Step) -> String {
  case step {
    Start -> "operator session session.started"
    UserMessage -> "operator session user.message"
    Epoch -> "session model request.epoch"
    Reply -> "model session reply"
    ReplyWithTool -> "model session reply.with.tool"
    ModelFailed -> "model session model.failed"
    ToolIntent -> "session tool call.intent"
    ToolResult -> "tool session tool.result"
    ToolFailed -> "tool session tool.failed"
    Stop -> "session operator session.stopped"
  }
}

fn report(rows: List(#(String, List(Step), Bool))) -> Nil {
  let accepted = list.count(rows, fn(row) { row.2 })
  echo "switchboard replay verdicts (oracle A)"
  list.each(rows, fn(row) {
    let #(name, _, ok) = row
    echo case ok {
      True -> "  ACCEPT  " <> name
      False -> "  refuse  " <> name
    }
  })
  echo "accepted "
    <> int.to_string(accepted)
    <> " of "
    <> int.to_string(list.length(rows))
  echo "traces written to /tmp/parley-switchboard-traces.txt"
  Nil
}

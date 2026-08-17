//// Differential test: two independent specifications of "which orderings
//// of switchboard session events are legal?"
////
////   Oracle A — switchboard's own replay guard. `journal.replay` re-checks
////     every committed event against the projection it lands on
////     (`transition_valid`, a hand-written exhaustive Gleam table).
////   Oracle B — protocols/switchboard-session.parley, that lifecycle
////     written as a protocol and compiled by parleyc.
////
//// This program enumerates EVERY sequence of events up to a bounded length,
//// judges each with oracle A, and writes them as a parley trace file so
//// oracle B can judge the same set. run.sh compares the two verdicts.
////
//// Two things keep a disagreement meaningful rather than an artefact:
////
////  1. Ids are filled in from switchboard's OWN folded projection
////     (`evolve.evolve` + `domain.next_request_id` / `pending_tool_call`),
////     so a lawfully ordered sequence never fails on a mismatched
////     req_id/call_id. Every refusal is about ORDER.
////  2. Payloads are chosen to satisfy switchboard's data predicates
////     (budget in range, non-empty text, small usage), which parley does
////     not model and this test therefore does not exercise.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import domain
import evolve
import journal

/// How long a sequence to enumerate. Every ordering of every event up to
/// this length is tested: 10 event kinds, so 10 + 100 + 1000 = 1110 at 3.
const depth = 4

/// The event vocabulary in the abstraction parley's protocol uses.
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

const steps = [
  Start, UserMessage, Epoch, Reply, ReplyWithTool, ModelFailed, ToolIntent,
  ToolResult, ToolFailed, Stop,
]

pub fn main() -> Nil {
  let sequences = enumerate(depth)
  let rows =
    sequences
    |> list.index_map(fn(sequence, index) {
      #(index, sequence, switchboard_accepts(sequence, index))
    })
  write_trace_file(rows)
  let accepted = list.count(rows, fn(row) { row.2 })
  echo "sequences: " <> int.to_string(list.length(rows))
  echo "lawful by switchboard: " <> int.to_string(accepted)
  echo "traces: /tmp/parley-switchboard-traces.txt"
  Nil
}

/// All non-empty sequences of length 1..limit.
fn enumerate(limit: Int) -> List(List(Step)) {
  case limit {
    n if n <= 0 -> []
    n -> list.append(enumerate(n - 1), sequences_of_length(n))
  }
}

fn sequences_of_length(length: Int) -> List(List(Step)) {
  case length {
    n if n <= 0 -> [[]]
    n ->
      sequences_of_length(n - 1)
      |> list.flat_map(fn(prefix) {
        list.map(steps, fn(step) { list.append(prefix, [step]) })
      })
  }
}

// --- oracle A: switchboard's own replay guard ---

fn switchboard_accepts(sequence: List(Step), index: Int) -> Bool {
  let path = "/tmp/parley-differential.jsonl"
  let _ = index
  let events = concretize(sequence, domain.Empty, 1, [])
  let contents =
    events
    |> list.index_map(fn(event, position) {
      journal.encode(journal.Envelope(version: 1, sequence: position + 1, event:))
    })
    |> string.join("\n")
  let body = case contents {
    "" -> ""
    _ -> contents <> "\n"
  }
  case simplifile.write(to: path, contents: body) {
    Error(_) -> False
    Ok(_) ->
      case journal.replay(path) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

/// Turn abstract steps into concrete events, folding switchboard's own
/// projection alongside so every id is the one switchboard expects.
fn concretize(
  sequence: List(Step),
  projection: domain.Projection,
  call: Int,
  acc: List(domain.Event),
) -> List(domain.Event) {
  case sequence {
    [] -> list.reverse(acc)
    [step, ..rest] -> {
      let event = concrete(step, projection, call)
      let advanced = case step {
        ToolResult | ToolFailed -> call + 1
        _ -> call
      }
      concretize(rest, evolve.evolve(projection, event), advanced, [event, ..acc])
    }
  }
}

fn concrete(step: Step, projection: domain.Projection, call: Int) -> domain.Event {
  // The request this projection is waiting on, falling back to the next id
  // when nothing is outstanding — an unlawful ordering, refused anyway.
  let outstanding = case domain.current_request(projection) {
    Some(req) -> req
    None -> domain.next_request_id(projection)
  }
  // The tool call this projection is waiting on, likewise.
  let pending = case domain.pending_tool_call(projection) {
    Some(tool) -> tool.call_id
    None -> "call-" <> int.to_string(call)
  }
  let fresh = "call-" <> int.to_string(call)
  case step {
    Start -> domain.SessionStarted("sys", 1_000_000)
    UserMessage -> domain.UserMessageRecorded("hello", 0)
    Epoch -> domain.ModelRequestEpochRecorded(domain.next_request_id(projection))
    Reply ->
      domain.ModelReplyRecorded(
        outstanding,
        domain.ModelReply("ok", None),
        domain.Usage(1, 1),
      )
    ReplyWithTool ->
      domain.ModelReplyRecorded(
        outstanding,
        domain.ModelReply("ok", Some(domain.ToolCall(fresh, "t", "{}"))),
        domain.Usage(1, 1),
      )
    ModelFailed -> domain.ModelFailedRecorded(outstanding, "boom", 0)
    ToolIntent -> domain.ToolCallIntentRecorded(pending, "t", "{}")
    ToolResult -> domain.ToolResultRecorded(pending, "out", 0)
    ToolFailed -> domain.ToolFailedRecorded(pending, "boom", 0)
    Stop -> domain.SessionStopped("bye")
  }
}

// --- oracle B's input ---

/// Emit the sequences in parley's observer trace format, each tagged with
/// oracle A's verdict so run.sh can pair them up.
fn write_trace_file(rows: List(#(Int, List(Step), Bool))) -> Nil {
  let body =
    rows
    |> list.map(fn(row) {
      let #(index, sequence, accepted) = row
      let verdict = case accepted {
        True -> "ACCEPTS"
        False -> "REFUSES"
      }
      let events = sequence |> list.map(trace_line) |> string.join("\n")
      "# switchboard replay: "
      <> verdict
      <> "\n# steps: "
      <> string.join(list.map(sequence, label), ",")
      <> "\nrun s"
      <> int.to_string(index)
      <> "\n"
      <> events
    })
    |> string.join("\n\n")
  let _ =
    simplifile.write(
      to: "/tmp/parley-switchboard-traces.txt",
      contents: body <> "\n",
    )
  Nil
}

fn label(step: Step) -> String {
  case step {
    Start -> "start"
    UserMessage -> "user"
    Epoch -> "epoch"
    Reply -> "reply"
    ReplyWithTool -> "reply+tool"
    ModelFailed -> "model-failed"
    ToolIntent -> "intent"
    ToolResult -> "tool-result"
    ToolFailed -> "tool-failed"
    Stop -> "stop"
  }
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

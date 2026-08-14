import gleam/list
import gleeunit
import contract.{Branch, Continue, Done, Loop, Offer, Receive, Select, Send}
import enforce.{Announce, At, Announcing, Payload, Violation}

pub fn main() -> Nil {
  gleeunit.main()
}

// --- decoding the compiler's emission ---

pub fn decode_roundtrip_test() {
  let source =
    "{\"role\":\"gate\",\"protocol\":\"evidence-pipeline\",\"contract\":"
    <> "{\"t\":\"offer\",\"from\":\"collector\",\"branches\":["
    <> "{\"label\":\"accepted\",\"then\":{\"t\":\"receive\",\"from\":\"kernel\",\"msg\":\"assurance.pass\",\"then\":{\"t\":\"done\"}}},"
    <> "{\"label\":\"malformed\",\"then\":{\"t\":\"done\"}}]}}"
  let assert Ok(parsed) = contract.parse(source)
  assert parsed.role == "gate"
  assert parsed.node
    == Offer("collector", [
      Branch("accepted", Receive("kernel", "assurance.pass", Done)),
      Branch("malformed", Done),
    ])
}

pub fn decode_unknown_tag_test() {
  let source = "{\"role\":\"x\",\"protocol\":\"p\",\"contract\":{\"t\":\"mystery\"}}"
  assert contract.parse(source) |> list.wrap |> list.all(fn(r) { r != Ok(contract.Contract("x", "p", Done)) })
}

// --- the pure enforcement engine ---

pub fn send_receive_advance_test() {
  let event = Payload(from: "a", to: "b", msg: "ping")
  assert enforce.step_out("a", At(Send("b", "ping", Done), []), event) == Ok(At(Done, []))
  assert enforce.step_in("b", At(Receive("a", "ping", Done), []), event) == Ok(At(Done, []))
}

pub fn wrong_payload_is_violation_test() {
  let event = Payload(from: "a", to: "b", msg: "pong")
  let assert Error(Violation(role: "a", ..)) =
    enforce.step_out("a", At(Send("b", "ping", Done), []), event)
}

pub fn done_role_rejects_everything_test() {
  let assert Error(violation) =
    enforce.step_out("a", At(Done, []), Payload(from: "a", to: "b", msg: "ping"))
  assert violation.expected == "done (no further obligations)"
}

pub fn select_announces_each_observer_then_advances_test() {
  let node = Select(["b", "c"], [Branch("l", Send("b", "x", Done)), Branch("r", Done)])
  let assert Ok(mid) =
    enforce.step_out("a", At(node, []), Announce(from: "a", to: "b", label: "l"))
  assert mid == Announcing("l", ["c"], Send("b", "x", Done), [])
  let assert Ok(after) =
    enforce.step_out("a", mid, Announce(from: "a", to: "c", label: "l"))
  assert after == At(Send("b", "x", Done), [])
}

pub fn announcing_cannot_switch_branches_test() {
  let mid = Announcing("l", ["c"], Done, [])
  let assert Error(_) =
    enforce.step_out("a", mid, Announce(from: "a", to: "c", label: "r"))
}

pub fn offer_takes_announced_branch_test() {
  let node = Offer("a", [Branch("l", Receive("a", "x", Done)), Branch("r", Done)])
  let assert Ok(after) =
    enforce.step_in("b", At(node, []), Announce(from: "a", to: "b", label: "r"))
  assert after == At(Done, [])
}

pub fn offer_rejects_unknown_label_test() {
  let node = Offer("a", [Branch("l", Done), Branch("r", Done)])
  let assert Error(_) =
    enforce.step_in("b", At(node, []), Announce(from: "a", to: "b", label: "sideways"))
}

pub fn offer_rejects_wrong_chooser_test() {
  let node = Offer("a", [Branch("l", Done), Branch("r", Done)])
  let assert Error(_) =
    enforce.step_in("b", At(node, []), Announce(from: "z", to: "b", label: "l"))
}

pub fn loop_repeats_until_exit_test() {
  // a's contract: loop x { send ping; offer b { again -> continue x, stop -> done } }
  let body =
    Send("b", "ping", Offer("b", [Branch("again", Continue("x")), Branch("stop", Done)]))
  let start = At(Loop("x", body), [])
  let ping = Payload(from: "a", to: "b", msg: "ping")
  let assert Ok(round1) = enforce.step_out("a", start, ping)
  let assert Ok(again) = enforce.step_in("a", round1, Announce(from: "b", to: "a", label: "again"))
  // Second lap: the continue re-enters the body and expects the same send.
  let assert Ok(round2) = enforce.step_out("a", again, ping)
  let assert Ok(stop) = enforce.step_in("a", round2, Announce(from: "b", to: "a", label: "stop"))
  assert enforce.is_done(stop)
}

pub fn loop_decode_roundtrip_test() {
  let source =
    "{\"role\":\"a\",\"protocol\":\"p\",\"contract\":"
    <> "{\"t\":\"loop\",\"name\":\"x\",\"then\":{\"t\":\"continue\",\"name\":\"x\"}}}"
  let assert Ok(parsed) = contract.parse(source)
  assert parsed.node == Loop("x", Continue("x"))
}

pub fn rogue_skip_is_named_test() {
  // Kernel's real contract starts by receiving `validate`; a rogue send of
  // assurance.pass must be refused at kernel with the expectation named.
  let kernel = At(Receive("collector", "validate", Send("gate", "assurance.pass", Done)), [])
  let assert Error(violation) =
    enforce.step_out("kernel", kernel, Payload(from: "kernel", to: "gate", msg: "assurance.pass"))
  assert violation.role == "kernel"
  assert violation.expected == "receive validate from collector"
}

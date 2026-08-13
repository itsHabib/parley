//// Demo entrypoint: load the contracts the Haskell compiler emitted, boot
//// one process per role behind the enforcing bus, and run the evidence
//// pipeline through every branch — then once more with a rogue kernel
//// that skips validation, which the bus refuses by name.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import contract.{type Node}
import enforce.{type Event, Payload}
import agent
import bus

const roles = ["producer", "collector", "kernel", "human", "gate"]

pub fn main() -> Nil {
  case load_contracts() {
    Error(reason) -> io.println("cannot load contracts: " <> reason)
    Ok(contracts) -> {
      io.println("parley runtime — contracts compiled from the global protocol")
      io.println("")
      scenario(contracts, "accepted / pass", plans([#("collector", "accepted"), #("kernel", "pass")]), None)
      scenario(contracts, "accepted / gap -> human judgment", plans([#("collector", "accepted"), #("kernel", "gap")]), None)
      scenario(contracts, "malformed receipt", plans([#("collector", "malformed")]), None)
      scenario(
        contracts,
        "ROGUE: kernel asserts assurance.pass without ever validating",
        plans([#("collector", "accepted")]),
        Some(#("kernel", [Payload(from: "kernel", to: "gate", msg: "assurance.pass")])),
      )
    }
  }
}

fn plans(choices: List(#(String, String))) -> Dict(String, List(String)) {
  choices
  |> list.map(fn(pair) { #(pair.0, [pair.1]) })
  |> dict.from_list
}

fn scenario(
  contracts: List(#(String, Node)),
  title: String,
  plan: Dict(String, List(String)),
  rogue: Option(#(String, List(Event))),
) -> Nil {
  io.println("=== " <> title <> " ===")
  let report = process.new_subject()
  let assert Ok(router) = bus.start(contracts, report)
  let bus_subject = router.data
  list.each(contracts, fn(pair) {
    let #(role, node) = pair
    let started = case rogue {
      Some(#(rogue_role, script)) if rogue_role == role ->
        agent.start_rogue(script, bus_subject)
      _ -> {
        let decisions = dict.get(plan, role) |> result.unwrap([])
        agent.start_honest(role, node, decisions, bus_subject)
      }
    }
    let assert Ok(agent_actor) = started
    process.send(bus_subject, bus.Register(role, agent_actor.data))
  })
  process.send(bus_subject, bus.Begin)
  report_loop(report)
  io.println("")
}

fn report_loop(report: process.Subject(bus.ReportLine)) -> Nil {
  case process.receive(report, 2000) {
    Ok(bus.Delivered(line)) -> {
      io.println("  ok      " <> line)
      report_loop(report)
    }
    Ok(bus.Refused(line)) -> io.println("  REFUSED " <> line)
    Ok(bus.AllDone) -> io.println("  done    every role completed its contract")
    Error(_) -> io.println("  timeout waiting for the bus")
  }
}

fn load_contracts() -> Result(List(#(String, Node)), String) {
  use dir <- result.try(contracts_dir())
  list.try_map(roles, fn(role) {
    let path = dir <> "/" <> role <> ".json"
    use source <- result.try(
      simplifile.read(path)
      |> result.map_error(fn(_) { "cannot read " <> path }),
    )
    contract.parse(source)
    |> result.map(fn(parsed) { #(parsed.role, parsed.node) })
    |> result.map_error(fn(_) { "cannot decode " <> path })
  })
}

fn contracts_dir() -> Result(String, String) {
  ["../contracts", "contracts"]
  |> list.find(fn(dir) { simplifile.is_directory(dir) |> result.unwrap(False) })
  |> result.map_error(fn(_) {
    "no contracts directory; run `make emit` in compiler/ first"
  })
}

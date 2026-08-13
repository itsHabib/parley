//// Local contract types mirrored from the compiler's JSON emission.
//// The schema is the wire boundary: compiler/src/Emit.hs writes it,
//// this module is the only place that reads it.

import gleam/dynamic/decode
import gleam/json

pub type Node {
  Done
  Send(to: String, msg: String, then: Node)
  Receive(from: String, msg: String, then: Node)
  Select(observers: List(String), branches: List(Branch))
  Offer(from: String, branches: List(Branch))
}

pub type Branch {
  Branch(label: String, then: Node)
}

pub type Contract {
  Contract(role: String, protocol: String, node: Node)
}

pub fn parse(source: String) -> Result(Contract, json.DecodeError) {
  json.parse(from: source, using: contract_decoder())
}

fn contract_decoder() -> decode.Decoder(Contract) {
  use role <- decode.field("role", decode.string)
  use protocol <- decode.field("protocol", decode.string)
  use node <- decode.field("contract", node_decoder())
  decode.success(Contract(role:, protocol:, node:))
}

fn node_decoder() -> decode.Decoder(Node) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "done" -> decode.success(Done)
    "send" -> {
      use to <- decode.field("to", decode.string)
      use msg <- decode.field("msg", decode.string)
      use then <- decode.field("then", node_decoder())
      decode.success(Send(to:, msg:, then:))
    }
    "receive" -> {
      use from <- decode.field("from", decode.string)
      use msg <- decode.field("msg", decode.string)
      use then <- decode.field("then", node_decoder())
      decode.success(Receive(from:, msg:, then:))
    }
    "select" -> {
      use observers <- decode.field("observers", decode.list(decode.string))
      use branches <- decode.field("branches", decode.list(branch_decoder()))
      decode.success(Select(observers:, branches:))
    }
    "offer" -> {
      use from <- decode.field("from", decode.string)
      use branches <- decode.field("branches", decode.list(branch_decoder()))
      decode.success(Offer(from:, branches:))
    }
    _ -> decode.failure(Done, "contract node tag")
  }
}

fn branch_decoder() -> decode.Decoder(Branch) {
  use label <- decode.field("label", decode.string)
  use then <- decode.field("then", node_decoder())
  decode.success(Branch(label:, then:))
}

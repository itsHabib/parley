-- JSON emission for compiled local contracts. Hand-rolled so the compiler
-- stays dependency-free (base only); the schema is the wire contract with
-- the Gleam runtime, documented in the repo README.
module Emit
  ( contractFile,
  )
where

import Data.List (intercalate)
import Protocol (Local (..), Role)

contractFile :: String -> Role -> Local -> String
contractFile protocolName role local =
  obj
    [ ("role", str role),
      ("protocol", str protocolName),
      ("contract", node local)
    ]
    ++ "\n"

node :: Local -> String
node Done = obj [("t", str "done")]
node (Send peer payload rest) =
  obj [("t", str "send"), ("to", str peer), ("msg", str payload), ("then", node rest)]
node (Receive peer payload rest) =
  obj [("t", str "receive"), ("from", str peer), ("msg", str payload), ("then", node rest)]
node (Select observers choices) =
  obj
    [ ("t", str "select"),
      ("observers", list (map str observers)),
      ("branches", branches choices)
    ]
node (Offer chooser choices) =
  obj
    [ ("t", str "offer"),
      ("from", str chooser),
      ("branches", branches choices)
    ]
node (LoopL name body) =
  obj [("t", str "loop"), ("name", str name), ("then", node body)]
node (ContinueL name) = obj [("t", str "continue"), ("name", str name)]

branches :: [(String, Local)] -> String
branches = list . map branch
  where
    branch (label, local) = obj [("label", str label), ("then", node local)]

obj :: [(String, String)] -> String
obj fields = "{" ++ intercalate "," (map field fields) ++ "}"
  where
    field (key, value) = str key ++ ":" ++ value

list :: [String] -> String
list items = "[" ++ intercalate "," items ++ "]"

str :: String -> String
str value = "\"" ++ concatMap escape value ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape c = [c]

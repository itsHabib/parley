-- Observer mode: replay recorded traces against a global protocol and
-- classify each one. No enforcement, no processes — a pure audit of
-- history. A trace file is plain text: `run <id>` starts a trace, each
-- following `sender receiver msg` line is one event, comments (#) and
-- blank lines are ignored.
--
-- A trace is:
--   * complete  — it walks the protocol to End exactly;
--   * stalled   — a valid prefix (the run is in flight or was abandoned);
--   * deviating — some event the protocol cannot account for.
module Observe
  ( Outcome (..),
    Trace (..),
    parseTraces,
    checkTrace,
    describeOutcome,
    deviationShape,
    parseBaseline,
  )
where

import Data.Char (isAsciiLower, isHexDigit)
import Data.Either (rights)
import Protocol (Protocol (..))

data Trace = Trace
  { traceId :: String,
    traceEvents :: [(String, String, String)]
  }
  deriving (Eq, Show)

data Outcome
  = Complete
  | Stalled String
  | Deviating String
  deriving (Eq, Show)

parseTraces :: String -> [Trace]
parseTraces source = build (foldr collect [] meaningful)
  where
    meaningful = filter (not . null) (map (words . stripComment) (lines source))
    stripComment = takeWhile (/= '#')
    collect ["run", runId] acc = Left runId : acc
    collect [sender, receiver, msg] acc = Right (sender, receiver, msg) : acc
    collect tokens _ = error ("bad trace line: " ++ unwords tokens)
    build [] = []
    build (Left runId : rest) =
      let (events, remaining) = span isEvent rest
       in Trace runId (rights events) : build remaining
    build (Right _ : _) = error "trace event before any `run <id>` header"
    isEvent (Right _) = True
    isEvent (Left _) = False

-- A failed walk remembers how far it got so that, of a choice's two
-- branches, the one that matched more of the trace explains the failure.
data Failure = Failure
  { failRemaining :: Int,
    failStalled :: Bool,
    failReason :: String
  }

checkTrace :: Protocol -> Trace -> Outcome
checkTrace protocol trace =
  case walk [] protocol (traceEvents trace) of
    Right [] -> Complete
    Right ((sender, receiver, msg) : _) ->
      Deviating ("events continue past the protocol's end: " ++ eventText sender receiver msg)
    Left failure
      | failStalled failure -> Stalled (failReason failure)
      | otherwise -> Deviating (failReason failure)

-- Terminates on compiled protocols: compile refuses unproductive loops,
-- so every pass around a loop consumes at least one event.
walk ::
  [(String, Protocol)] ->
  Protocol ->
  [(String, String, String)] ->
  Either Failure [(String, String, String)]
walk _ End events = Right events
walk env (Loop name body) events = walk ((name, body) : env) body events
walk env (Continue name) events =
  case lookup name env of
    Just body -> walk env body events
    Nothing -> Left (Failure (length events) False ("continue to unknown loop " ++ name))
walk env (Message sender receiver payload rest) events =
  case events of
    [] ->
      Left (Failure 0 True ("awaiting " ++ eventText sender receiver payload))
    event@(s, r, p) : remaining
      | event == (sender, receiver, payload) -> walk env rest remaining
      | otherwise ->
          Left
            ( Failure
                (length events)
                False
                ("expected " ++ eventText sender receiver payload ++ "; got " ++ eventText s r p)
            )
walk env (Choice _ _ branches) events = go (map attempt branches)
  where
    attempt (label, branch) =
      case walk env branch events of
        Right remaining -> Right remaining
        Left failure ->
          Left failure {failReason = "[" ++ label ++ "] " ++ failReason failure}
    -- First branch that consumes the trace wins; otherwise the failure
    -- that matched the most events explains the mismatch.
    go [] = Left (Failure (length events) False "choice with no branches")
    go (Right remaining : _) = Right remaining
    go (Left failure : rest) =
      case go rest of
        Right remaining -> Right remaining
        Left other -> Left (if failRemaining failure <= failRemaining other then failure else other)

-- A deviation's *shape*: its reason with concrete identifiers replaced by
-- a placeholder. A baseline lists shapes, never trace ids, so it pins the
-- class of surprise rather than the particular run that produced it —
-- baselining on ids would rot the file every time gate opens a run.
deviationShape :: String -> String
deviationShape = unwords . map anonymize . words
  where
    anonymize token =
      case break (== '_') token of
        (prefix, '_' : suffix)
          | not (null prefix),
            all isAsciiLower prefix,
            length suffix >= 8,
            all isHexDigit suffix ->
              prefix ++ "_<id>"
        _ -> token

-- A baseline file is the same plain-text shape as a trace file: one
-- accepted deviation shape per line, `#` comments and blank lines ignored.
parseBaseline :: String -> [String]
parseBaseline = filter (not . null) . map (unwords . words . stripComment) . lines
  where
    stripComment = takeWhile (/= '#')

describeOutcome :: Outcome -> String
describeOutcome Complete = "complete"
describeOutcome (Stalled reason) = "stalled   " ++ reason
describeOutcome (Deviating reason) = "DEVIATES  " ++ reason

eventText :: String -> String -> String -> String
eventText sender receiver msg = sender ++ " -> " ++ receiver ++ ": " ++ msg

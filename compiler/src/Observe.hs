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

parseTraces :: String -> Either String [Trace]
parseTraces source = do
  tokens <- traverse parseLine meaningful
  build [] tokens
  where
    meaningful =
      [ (n, ws)
      | (n, line) <- zip [1 :: Int ..] (lines source),
        let ws = words (takeWhile (/= '#') line),
        not (null ws)
      ]
    parseLine (_, ["run", runId]) = Right (Left runId)
    parseLine (_, [sender, receiver, msg]) = Right (Right (sender, receiver, msg))
    parseLine (n, _) = Left ("bad trace line " ++ show n ++ ": expected run <id> or sender receiver message")
    build _ [] = Right []
    build seen (Left runId : rest)
      | runId `elem` seen = Left ("duplicate trace id: " ++ runId)
      | otherwise = do
          let (events, remaining) = span isEvent rest
          following <- build (runId : seen) remaining
          pure (Trace runId (rights events) : following)
    build _ (Right _ : _) = Left "trace event before any run <id> header"
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
    -- A short branch reaching End is not enough: another branch may
    -- consume the whole trace. Prefer the path with the most progress;
    -- on a tie a completed branch wins over a failure.
    go [] = Left (Failure (length events) False "choice with no branches")
    go [result] = result
    go (Right [] : _) = Right []
    go (result : rest) = best result (go rest)
    best left right = case (left, right) of
      (Right xs, Right ys) -> Right (if length xs <= length ys then xs else ys)
      (Left x, Left y) -> Left (if failRemaining x <= failRemaining y then x else y)
      (Right xs, Left y) -> if length xs <= failRemaining y then left else right
      (Left x, Right ys) -> if failRemaining x < length ys then left else right

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

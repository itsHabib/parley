-- The textual protocol format: a protocol is a readable file, not a
-- Haskell value. Line 1 names the protocol, line 2 declares the roles,
-- and the body is messages and braced binary choices:
--
--   protocol evidence-pipeline
--   roles a b c
--
--   a -> b: ping
--   choice b observes a c {
--     up   { b -> c: go }
--     down { b -> a: stop }
--   }
--
-- Loops: `loop <name> { ... }` repeats when a branch reaches
-- `continue <name>`; walking off the end of the body exits the loop.
-- A choice, loop, or continue ends its block: statements after one would
-- be unreachable on some path, so the parser refuses them.
module Parse
  ( Parsed (..),
    parseProtocol,
  )
where

import Protocol (Protocol (..), Role)

data Parsed = Parsed
  { parsedName :: String,
    parsedRoles :: [Role],
    parsedProtocol :: Protocol
  }
  deriving (Eq, Show)

parseProtocol :: String -> Either String Parsed
parseProtocol source =
  case meaningfulLines source of
    headerLine : rolesLine : bodyLines -> do
      name <- header headerLine
      roles <- declaredRoles rolesLine
      (protocol, rest) <- body (concatMap tokenize bodyLines)
      case rest of
        [] -> Right (Parsed name roles protocol)
        token : _ -> Left ("unexpected " ++ token ++ " after protocol body")
    _ -> Left "expected a protocol line, a roles line, and a body"

meaningfulLines :: String -> [String]
meaningfulLines = filter (not . null . words) . map stripComment . lines
  where
    stripComment = takeWhile (/= '#')

header :: String -> Either String String
header line =
  case words line of
    ["protocol", name] -> Right name
    _ -> Left ("expected `protocol <name>`, got: " ++ unwords (words line))

declaredRoles :: String -> Either String [Role]
declaredRoles line =
  case words line of
    "roles" : roles@(_ : _) -> Right roles
    _ -> Left ("expected `roles <role>...`, got: " ++ unwords (words line))

tokenize :: String -> [String]
tokenize = words . concatMap pad
  where
    pad c
      | c `elem` "{}:" = [' ', c, ' ']
      | otherwise = [c]

body :: [String] -> Either String (Protocol, [String])
body tokens =
  case tokens of
    [] -> Right (End, [])
    "}" : _ -> Right (End, tokens)
    "choice" : chooser : "observes" : rest -> do
      (observers, afterObservers) <- observersUntilBrace rest
      (leftLabel, left, afterLeft) <- branch afterObservers
      (rightLabel, right, afterRight) <- branch afterLeft
      afterChoice <- closeChoice afterRight
      Right (Choice chooser observers leftLabel left rightLabel right, afterChoice)
    "loop" : name : "{" : rest -> do
      (loopBody, remaining) <- body rest
      case remaining of
        "}" : afterLoop -> Right (Loop name loopBody, afterLoop)
        token : _ -> Left ("expected } to close loop " ++ name ++ ", got " ++ token)
        [] -> Left ("unclosed loop " ++ name)
    "continue" : name : rest
      | name `notElem` ["{", "}", ":", "->"] -> Right (Continue name, rest)
    sender : "->" : receiver : ":" : payload : rest -> do
      (continuation, remaining) <- body rest
      Right (Message sender receiver payload continuation, remaining)
    token : _ -> Left ("unexpected token: " ++ token)

observersUntilBrace :: [String] -> Either String ([Role], [String])
observersUntilBrace tokens =
  case break (== "{") tokens of
    ([], _) -> Left "a choice needs at least one observer"
    (observers, "{" : rest)
      | all identifier observers -> Right (observers, rest)
      | otherwise -> Left ("bad observer list: " ++ unwords observers)
    (_, _) -> Left "expected { after the observer list"
  where
    identifier token = token `notElem` ["}", ":", "->", "choice", "observes"]

branch :: [String] -> Either String (String, Protocol, [String])
branch tokens =
  case tokens of
    label : "{" : rest -> do
      (protocol, remaining) <- body rest
      case remaining of
        "}" : afterBranch -> Right (label, protocol, afterBranch)
        token : _ -> Left ("expected } to close branch " ++ label ++ ", got " ++ token)
        [] -> Left ("unclosed branch " ++ label)
    token : _ -> Left ("expected a branch label, got " ++ token)
    [] -> Left "expected a branch label"

closeChoice :: [String] -> Either String [String]
closeChoice tokens =
  case tokens of
    "}" : rest -> Right rest
    token : _ ->
      Left
        ( "expected } to close the choice, got "
            ++ token
            ++ " (a third branch, or statements after a choice, are not allowed)"
        )
    [] -> Left "unclosed choice"

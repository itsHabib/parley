module Main (main) where

import Example (invalidProtocol, roles, validProtocol)
import Parse (Parsed (..), parseProtocol)
import Protocol
import System.Exit (exitFailure)

main :: IO ()
main = do
  fileCase <- parityCase
  let all_ = cases ++ parseCases ++ [fileCase]
  results <- mapM run all_
  if and results then putStrLn (show (length all_) ++ " ok") else exitFailure
  where
    run (name, ok) = do
      putStrLn ((if ok then "ok   " else "FAIL ") ++ name)
      pure ok

-- The committed textual protocol must parse to exactly the builtin value
-- the Gleam demo contracts and the Lean theorems are stated against.
parityCase :: IO (String, Bool)
parityCase = do
  source <- readFile "../protocols/evidence-pipeline.parley"
  pure
    ( "evidence-pipeline.parley parses to the builtin protocol",
      parseProtocol source
        == Right (Parsed "evidence-pipeline" roles validProtocol)
    )

parseCases :: [(String, Bool)]
parseCases =
  [ ( "message chains parse in sequence",
      parseProtocol "protocol p\nroles a b\na -> b: x\nb -> a: y\n"
        == Right (Parsed "p" ["a", "b"] (Message "a" "b" "x" (Message "b" "a" "y" End)))
    ),
    ( "comments and blank lines are ignored",
      parseProtocol "protocol p\nroles a b\n\n# hi\na -> b: x # trailing\n"
        == Right (Parsed "p" ["a", "b"] (Message "a" "b" "x" End))
    ),
    ( "choice parses with observers and two branches",
      parseProtocol
        "protocol p\nroles a b c\nchoice a observes b c {\n l { a -> b: x }\n r { a -> c: y }\n}\n"
        == Right
          ( Parsed
              "p"
              ["a", "b", "c"]
              ( Choice
                  "a"
                  ["b", "c"]
                  "l"
                  (Message "a" "b" "x" End)
                  "r"
                  (Message "a" "c" "y" End)
              )
          )
    ),
    ( "statements after a choice are refused",
      isParseError
        (parseProtocol "protocol p\nroles a b\nchoice a observes b {\n l { }\n r { }\n}\na -> b: x\n")
    ),
    ( "a third branch is refused",
      isParseError
        (parseProtocol "protocol p\nroles a b\nchoice a observes b {\n l { }\n r { }\n m { }\n}\n")
    ),
    ( "unclosed braces are refused",
      isParseError (parseProtocol "protocol p\nroles a b\nchoice a observes b {\n l { }\n r { \n")
    )
  ]
  where
    isParseError = either (const True) (const False)

cases :: [(String, Bool)]
cases =
  [ ( "valid protocol compiles for all roles",
      either (const False) ((== length roles) . length) (compile roles validProtocol)
    ),
    ( "gate offer distinguishes outer branches",
      case lookup "gate" =<< eitherToMaybe (compile roles validProtocol) of
        Just (Offer "collector" "accepted" _ "malformed" Done) -> True
        _ -> False
    ),
    ( "declared observer with equal branches still gets an offer",
      -- collector observes kernel's inner choice; both branches leave it done.
      case lookup "collector" =<< eitherToMaybe (compile roles validProtocol) of
        Just (Receive "producer" "evidence.receipt" (Select _ _ left _ _)) ->
          case left of
            Send "kernel" "validate" (Offer "kernel" "pass" Done "gap" Done) -> True
            _ -> False
        _ -> False
    ),
    ( "undeclared role with equal branches collapses silently",
      case project "bystander" (Choice "a" ["b"] "l" End "r" End) of
        Right Done -> True
        _ -> False
    ),
    ( "unobservable choice is refused at the role and path",
      case compile roles invalidProtocol of
        Left (UnobservableChoice [] "gate" _ _) -> True
        _ -> False
    ),
    ( "self-message is refused",
      case project "a" (Message "a" "a" "x" End) of
        Left (SelfMessage [] "a" "x") -> True
        _ -> False
    ),
    ( "chooser cannot observe its own choice",
      case project "a" (Choice "a" ["a", "b"] "l" End "r" End) of
        Left (ChooserAlsoObserver [] "a") -> True
        _ -> False
    ),
    ( "duplicate labels are refused",
      case project "a" (Choice "a" ["b"] "l" End "l" End) of
        Left (DuplicateChoiceLabel [] "l") -> True
        _ -> False
    ),
    ( "nested refusal carries the branch path",
      case project
        "c"
        ( Choice
            "a"
            ["b", "c"]
            "up"
            (Choice "b" [] "l" (Message "a" "c" "x" End) "r" End)
            "down"
            End
        ) of
        Left (UnobservableChoice ["up"] "c" _ _) -> True
        _ -> False
    ),
    ( "unknown role is refused",
      case compile ["a"] (Message "a" "ghost" "x" End) of
        Left (UnknownRole "ghost") -> True
        _ -> False
    ),
    ( "duplicate declared role is refused",
      case compile ["a", "a"] End of
        Left (DuplicateRole "a") -> True
        _ -> False
    )
  ]

eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe = either (const Nothing) Just

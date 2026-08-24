module Main (main) where

import Example (invalidProtocol, roles, validProtocol)
import Parse (Parsed (..), parseProtocol)
import Protocol
import System.Exit (exitFailure)

main :: IO ()
main = do
  fileCase <- parityCase
  gateFileCase <- gateCase
  let all_ = cases ++ loopCases ++ parseCases ++ [fileCase, gateFileCase]
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

gateCase :: IO (String, Bool)
gateCase = do
  source <- readFile "../protocols/gate-run.parley"
  pure
    ( "gate-run.parley parses and compiles for all five roles",
      case parseProtocol source of
        Left _ -> False
        Right parsed ->
          either (const False) ((== 5) . length) $
            compile (parsedRoles parsed) (parsedProtocol parsed)
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
                  [ ("l", Message "a" "b" "x" End),
                    ("r", Message "a" "c" "y" End)
                  ]
              )
          )
    ),
    ( "statements after a choice are refused",
      isParseError
        (parseProtocol "protocol p\nroles a b\nchoice a observes b {\n l { }\n r { }\n}\na -> b: x\n")
    ),
    ( "a choice takes any number of branches",
      parseProtocol
        "protocol p\nroles a b\nchoice a observes b {\n l { }\n m { }\n r { }\n}\n"
        == Right
          ( Parsed
              "p"
              ["a", "b"]
              (Choice "a" ["b"] [("l", End), ("m", End), ("r", End)])
          )
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
        Just (Offer "collector" [("accepted", _), ("malformed", Done)]) -> True
        _ -> False
    ),
    ( "declared observer with equal branches still gets an offer",
      -- collector observes kernel's inner choice; both branches leave it done.
      case lookup "collector" =<< eitherToMaybe (compile roles validProtocol) of
        Just (Receive "producer" "evidence.receipt" (Select _ (("accepted", left) : _))) ->
          case left of
            Send "kernel" "validate" (Offer "kernel" [("pass", Done), ("gap", Done)]) -> True
            _ -> False
        _ -> False
    ),
    ( "undeclared role with equal branches collapses silently",
      case project "bystander" (Choice "a" ["b"] [("l", End), ("r", End)]) of
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
      case project "a" (Choice "a" ["a", "b"] [("l", End), ("r", End)]) of
        Left (ChooserAlsoObserver [] "a") -> True
        _ -> False
    ),
    ( "duplicate labels are refused",
      case project "a" (Choice "a" ["b"] [("l", End), ("l", End)]) of
        Left (DuplicateChoiceLabel [] "l") -> True
        _ -> False
    ),
    ( "a choice needs at least two branches",
      case project "a" (Choice "a" ["b"] [("only", End)]) of
        Left (TooFewBranches [] "a") -> True
        _ -> False
    ),
    ( "nested refusal carries the branch path",
      case project
        "c"
        ( Choice
            "a"
            ["b", "c"]
            [ ("up", Choice "b" [] [("l", Message "a" "c" "x" End), ("r", End)]),
              ("down", End)
            ]
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

loopCases :: [(String, Bool)]
loopCases =
  [ ( "a participating role's loop projects to a local loop",
      case project "a" pingLoop of
        Right
          ( LoopL
              "x"
              (Send "b" "ping" (Offer "b" [("again", ContinueL "x"), ("stop", Done)]))
            ) -> True
        _ -> False
    ),
    ( "a role untouched by the loop projects to done",
      project "c" pingLoop == Right Done
    ),
    ( "continue outside any loop is refused",
      case compile ["a", "b"] (Message "a" "b" "x" (Continue "ghost")) of
        Left (UnknownLoop [] "ghost") -> True
        _ -> False
    ),
    ( "shadowing loop names are refused",
      case compile ["a", "b"] (Loop "x" (Message "a" "b" "m" (Loop "x" (Message "a" "b" "m" End)))) of
        Left (DuplicateLoop [] "x") -> True
        _ -> False
    ),
    ( "a loop that can continue without a message is refused",
      case compile
        ["a", "b"]
        (Loop "x" (Choice "a" ["b"] [("go", Continue "x"), ("stop", End)])) of
        Left (UnproductiveLoop [] "x") -> True
        _ -> False
    ),
    ( "a bystander to an inner loop that escapes outward is refused",
      case compile ["a", "b", "c", "d"] escapingLoop of
        Left (UnobservableChoice [] "a" (ContinueL "i") (ContinueL "o")) -> True
        _ -> False
    ),
    ( "a bystander to an inner loop whose continues stay bound still collapses",
      project "a" boundLoop == Right (LoopL "o" (Send "b" "m" Done))
    )
  ]
  where
    -- a pings b until b says stop; c is a declared role left untouched.
    pingLoop =
      Loop "x"
        $ Message "a" "b" "ping"
        $ Choice "b" ["a"] [("again", Continue "x"), ("stop", End)]

    -- c decides whether the outer loop goes round again, and a — whose
    -- send sits in that outer body — is nowhere in the inner one. Whether
    -- a sends again therefore depends on a branch a is never told about.
    escapingLoop =
      Loop "o"
        $ Message "a" "b" "m"
        $ Loop "i"
        $ Message "c" "d" "n"
        $ Choice "c" ["d"] [("again", Continue "i"), ("out", Continue "o")]

    -- The same shape with the inner choice staying inside its own loop.
    -- The outer body then runs exactly once, so dropping a is correct.
    boundLoop =
      Loop "o"
        $ Message "a" "b" "m"
        $ Loop "i"
        $ Message "c" "d" "n"
        $ Choice "c" ["d"] [("again", Continue "i"), ("stop", End)]

eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe = either (const Nothing) Just

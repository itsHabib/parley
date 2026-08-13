module Main (main) where

import Example (invalidProtocol, roles, validProtocol)
import Protocol
import System.Exit (exitFailure)

main :: IO ()
main = do
  results <- mapM run cases
  if and results then putStrLn (show (length cases) ++ " ok") else exitFailure
  where
    run (name, ok) = do
      putStrLn ((if ok then "ok   " else "FAIL ") ++ name)
      pure ok

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

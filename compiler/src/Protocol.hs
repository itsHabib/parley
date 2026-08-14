module Protocol
  ( Role,
    Label,
    Protocol (..),
    Local (..),
    CompileError (..),
    compile,
    project,
    renderContract,
    renderError,
  )
where

import Data.List (intercalate)

type Role = String

type Label = String

data Protocol
  = End
  | Message Role Role String Protocol
  | Choice Role [Role] Label Protocol Label Protocol
  | Loop Label Protocol
  | Continue Label
  deriving (Eq, Show)

data Local
  = Done
  | Send Role String Local
  | Receive Role String Local
  | Select [Role] Label Local Label Local
  | Offer Role Label Local Label Local
  | LoopL Label Local
  | ContinueL Label
  deriving (Eq, Show)

data CompileError
  = DuplicateRole Role
  | UnknownRole Role
  | SelfMessage [Label] Role String
  | DuplicateChoiceLabel [Label] Label
  | ChooserAlsoObserver [Label] Role
  | UnobservableChoice [Label] Role Local Local
  | UnknownLoop [Label] Label
  | DuplicateLoop [Label] Label
  | UnproductiveLoop [Label] Label
  deriving (Eq, Show)

compile :: [Role] -> Protocol -> Either CompileError [(Role, Local)]
compile roles protocol = do
  validateRoles roles
  validateMentionedRoles roles protocol
  validateLoops [] [] protocol
  traverse (projectWith protocol) roles
  where
    projectWith value role = fmap (\local -> (role, local)) (project role value)

-- Declared observers always receive a branch announcement, even when their
-- obligations coincide on both branches: the runtime chooser notifies every
-- declared observer, so every declared observer must hold an Offer. Only
-- undeclared roles may silently collapse equal branches.
project :: Role -> Protocol -> Either CompileError Local
project role = go []
  where
    go _ End = Right Done
    go _ (Continue name) = Right (ContinueL name)
    go path (Loop name body)
      -- A role mentioned nowhere in the body has no obligations in any
      -- iteration and needn't know the loop exists; deciding this up
      -- front also spares it the body's observability requirements.
      | role `notElem` mentionedRoles body = Right Done
      | otherwise = do
          localBody <- go path body
          Right $
            if localBody == ContinueL name || localBody == Done
              then Done
              else LoopL name localBody
    go path (Message sender receiver payload rest)
      | sender == receiver = Left (SelfMessage path sender payload)
      | role == sender = Send receiver payload <$> go path rest
      | role == receiver = Receive sender payload <$> go path rest
      | otherwise = go path rest
    go path (Choice chooser observers leftLabel left rightLabel right)
      | leftLabel == rightLabel = Left (DuplicateChoiceLabel path leftLabel)
      | chooser `elem` observers = Left (ChooserAlsoObserver path chooser)
      | role == chooser =
          Select observers leftLabel
            <$> go (path ++ [leftLabel]) left
            <*> pure rightLabel
            <*> go (path ++ [rightLabel]) right
      | otherwise = do
          leftLocal <- go (path ++ [leftLabel]) left
          rightLocal <- go (path ++ [rightLabel]) right
          if role `elem` observers
            then Right (Offer chooser leftLabel leftLocal rightLabel rightLocal)
            else
              if leftLocal == rightLocal
                then Right leftLocal
                else Left (UnobservableChoice path role leftLocal rightLocal)

validateRoles :: [Role] -> Either CompileError ()
validateRoles roles =
  case firstDuplicate roles of
    Nothing -> Right ()
    Just role -> Left (DuplicateRole role)

validateMentionedRoles :: [Role] -> Protocol -> Either CompileError ()
validateMentionedRoles roles protocol =
  case filter (`notElem` roles) (mentionedRoles protocol) of
    [] -> Right ()
    role : _ -> Left (UnknownRole role)

mentionedRoles :: Protocol -> [Role]
mentionedRoles End = []
mentionedRoles (Continue _) = []
mentionedRoles (Loop _ body) = mentionedRoles body
mentionedRoles (Message sender receiver _ rest) = sender : receiver : mentionedRoles rest
mentionedRoles (Choice chooser observers _ left _ right) =
  chooser : observers ++ mentionedRoles left ++ mentionedRoles right

-- Loops must be well-scoped (continue names an enclosing loop, names do
-- not shadow) and productive: a continue reachable without first passing
-- a message would let the protocol spin without consuming anything.
validateLoops :: [Label] -> [Label] -> Protocol -> Either CompileError ()
validateLoops _ _ End = Right ()
validateLoops scope path (Continue name)
  | name `elem` scope = Right ()
  | otherwise = Left (UnknownLoop path name)
validateLoops scope path (Loop name body)
  | name `elem` scope = Left (DuplicateLoop path name)
  | unguardedContinue body = Left (UnproductiveLoop path name)
  | otherwise = validateLoops (name : scope) path body
validateLoops scope path (Message _ _ _ rest) = validateLoops scope path rest
validateLoops scope path (Choice _ _ leftLabel left rightLabel right) = do
  validateLoops scope (path ++ [leftLabel]) left
  validateLoops scope (path ++ [rightLabel]) right

unguardedContinue :: Protocol -> Bool
unguardedContinue End = False
unguardedContinue (Continue _) = True
unguardedContinue (Message {}) = False
unguardedContinue (Loop _ body) = unguardedContinue body
unguardedContinue (Choice _ _ _ left _ right) =
  unguardedContinue left || unguardedContinue right

firstDuplicate :: (Eq a) => [a] -> Maybe a
firstDuplicate = go []
  where
    go _ [] = Nothing
    go seen (value : rest)
      | value `elem` seen = Just value
      | otherwise = go (value : seen) rest

renderContract :: Role -> Local -> String
renderContract role local = role ++ ":\n" ++ render 1 local
  where
    render depth Done = indent depth ++ "done\n"
    render depth (Send peer payload rest) =
      indent depth ++ "send " ++ peer ++ " " ++ payload ++ "\n" ++ render depth rest
    render depth (Receive peer payload rest) =
      indent depth ++ "receive " ++ peer ++ " " ++ payload ++ "\n" ++ render depth rest
    render depth (Select observers leftLabel left rightLabel right) =
      indent depth
        ++ "select for ["
        ++ intercalate ", " observers
        ++ "]\n"
        ++ renderBranch depth leftLabel left
        ++ renderBranch depth rightLabel right
    render depth (Offer chooser leftLabel left rightLabel right) =
      indent depth
        ++ "offer from "
        ++ chooser
        ++ "\n"
        ++ renderBranch depth leftLabel left
        ++ renderBranch depth rightLabel right
    render depth (LoopL name body) =
      indent depth ++ "loop " ++ name ++ "\n" ++ render (depth + 1) body
    render depth (ContinueL name) =
      indent depth ++ "continue " ++ name ++ "\n"
    renderBranch depth label branch =
      indent (depth + 1) ++ label ++ ":\n" ++ render (depth + 2) branch
    indent depth = replicate (depth * 2) ' '

renderError :: CompileError -> String
renderError compileError =
  case compileError of
    DuplicateRole role -> "duplicate declared role: " ++ role
    UnknownRole role -> "protocol mentions undeclared role: " ++ role
    SelfMessage path role payload ->
      at path ++ role ++ " cannot send " ++ payload ++ " to itself"
    DuplicateChoiceLabel path label -> at path ++ "choice repeats label " ++ label
    ChooserAlsoObserver path role ->
      at path ++ "choice owner " ++ role ++ " cannot also be an observer"
    UnobservableChoice path role left right ->
      at path
        ++ "role "
        ++ role
        ++ " has branch-dependent obligations but is not notified\n"
        ++ "  left:  "
        ++ oneLine left
        ++ "\n  right: "
        ++ oneLine right
    UnknownLoop path name -> at path ++ "continue targets no enclosing loop: " ++ name
    DuplicateLoop path name -> at path ++ "loop name shadows an enclosing loop: " ++ name
    UnproductiveLoop path name ->
      at path ++ "loop " ++ name ++ " can continue without exchanging any message"
  where
    at [] = "at root: "
    at path = "at " ++ intercalate "/" path ++ ": "
    oneLine = unwords . words . renderContract "_"

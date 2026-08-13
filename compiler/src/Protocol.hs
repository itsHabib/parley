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
  deriving (Eq, Show)

data Local
  = Done
  | Send Role String Local
  | Receive Role String Local
  | Select [Role] Label Local Label Local
  | Offer Role Label Local Label Local
  deriving (Eq, Show)

data CompileError
  = DuplicateRole Role
  | UnknownRole Role
  | SelfMessage [Label] Role String
  | DuplicateChoiceLabel [Label] Label
  | ChooserAlsoObserver [Label] Role
  | UnobservableChoice [Label] Role Local Local
  deriving (Eq, Show)

compile :: [Role] -> Protocol -> Either CompileError [(Role, Local)]
compile roles protocol = do
  validateRoles roles
  validateMentionedRoles roles protocol
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
mentionedRoles (Message sender receiver _ rest) = sender : receiver : mentionedRoles rest
mentionedRoles (Choice chooser observers _ left _ right) =
  chooser : observers ++ mentionedRoles left ++ mentionedRoles right

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
  where
    at [] = "at root: "
    at path = "at " ++ intercalate "/" path ++ ": "
    oneLine = unwords . words . renderContract "_"

module Main (main) where

import Data.List (nub)
import Emit (contractFile)
import Example (invalidProtocol, protocolName, roles, validProtocol)
import Observe (Outcome (..), Trace (..), checkTrace, describeOutcome, deviationShape, parseBaseline, parseTraces)
import Parse (Parsed (..), parseProtocol)
import Protocol (compile, renderContract, renderError)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["compile", file, dir] -> compileFile file dir
    ["observe", file, traceFile] -> observe file traceFile Nothing
    ["observe", file, traceFile, baselineFile] -> observe file traceFile (Just baselineFile)
    ["emit", dir] -> emit dir
    ["check"] -> check
    _ -> do
      hPutStrLn stderr "usage: parleyc compile <file.parley> <dir> | parleyc observe <file.parley> <trace> [baseline] | parleyc emit <dir> | parleyc check"
      exitFailure

observe :: FilePath -> FilePath -> Maybe FilePath -> IO ()
observe file traceFile baselineFile = do
  source <- readFile file
  case parseProtocol source of
    Left err -> die ("parse error in " ++ file ++ ": " ++ err)
    Right parsed ->
      -- Compile first: an observer against an incoherent protocol proves nothing.
      case compile (parsedRoles parsed) (parsedProtocol parsed) of
        Left err -> die ("refused: " ++ renderError err)
        Right _ -> do
          traces <- parseTraces <$> readFile traceFile
          let outcomes = map (\t -> (t, checkTrace (parsedProtocol parsed) t)) traces
          mapM_ report outcomes
          putStrLn ""
          putStrLn (summary (map snd outcomes))
          maybe (pure ()) (audit (map snd outcomes)) baselineFile
  where
    report (trace, outcome) =
      putStrLn (pad (traceId trace) ++ " " ++ describeOutcome outcome)
    pad name = name ++ replicate (max 0 (24 - length name)) ' '
    summary outcomes =
      show (length outcomes)
        ++ " traces: "
        ++ show (count (== Complete) outcomes)
        ++ " complete, "
        ++ show (count isStalled outcomes)
        ++ " stalled, "
        ++ show (count isDeviating outcomes)
        ++ " deviating"
    count predicate = length . filter predicate
    isStalled outcome = case outcome of
      Stalled _ -> True
      _ -> False
    isDeviating outcome = case outcome of
      Deviating _ -> True
      _ -> False

-- With a baseline the observer stops being a report and becomes a check.
-- Both halves matter: a deviation nobody has written down fails, and so
-- does a baseline line that no longer describes anything. Without the
-- second half the file only ever grows, and a check that cannot go red
-- for the right reason is watching nothing.
audit :: [Outcome] -> FilePath -> IO ()
audit outcomes baselineFile = do
  accepted <- parseBaseline <$> readFile baselineFile
  let shapes = nub [deviationShape reason | Deviating reason <- outcomes]
      unexpected = filter (`notElem` accepted) shapes
      stale = filter (`notElem` shapes) accepted
  putStrLn ""
  mapM_ (putStrLn . ("UNEXPECTED  " ++)) unexpected
  mapM_ (putStrLn . ("STALE       " ++)) stale
  if null unexpected && null stale
    then putStrLn (show (length accepted) ++ " accepted deviation shapes, every one still present")
    else do
      hPutStrLn
        stderr
        ( show (length unexpected)
            ++ " unexpected, "
            ++ show (length stale)
            ++ " stale; "
            ++ baselineFile
            ++ " needs a line — with a reason — for each"
        )
      exitFailure

compileFile :: FilePath -> FilePath -> IO ()
compileFile file dir = do
  present <- doesDirectoryExist dir
  if not present
    then die ("no such output directory: " ++ dir)
    else compileInto file dir

compileInto :: FilePath -> FilePath -> IO ()
compileInto file dir = do
  source <- readFile file
  case parseProtocol source of
    Left err -> die ("parse error in " ++ file ++ ": " ++ err)
    Right parsed ->
      case compile (parsedRoles parsed) (parsedProtocol parsed) of
        Left err -> die ("refused: " ++ renderError err)
        Right contracts -> do
          mapM_ (putStrLn . uncurry renderContract) contracts
          mapM_ (write (parsedName parsed)) contracts
          putStrLn
            ( "compiled "
                ++ parsedName parsed
                ++ ": "
                ++ show (length contracts)
                ++ " contracts to "
                ++ dir
            )
  where
    write name (role, local) =
      writeFile (dir ++ "/" ++ role ++ ".json") (contractFile name role local)

die :: String -> IO ()
die message = hPutStrLn stderr message >> exitFailure

emit :: FilePath -> IO ()
emit dir =
  case compile roles validProtocol of
    Left err -> die ("refused: " ++ renderError err)
    Right contracts -> do
      mapM_ write contracts
      putStrLn ("emitted " ++ show (length contracts) ++ " contracts to " ++ dir)
  where
    write (role, local) =
      writeFile (dir ++ "/" ++ role ++ ".json") (contractFile protocolName role local)

check :: IO ()
check = do
  putStrLn ("protocol: " ++ protocolName)
  putStrLn ""
  case compile roles validProtocol of
    Left err -> do
      hPutStrLn stderr ("valid protocol unexpectedly refused: " ++ renderError err)
      exitFailure
    Right contracts -> mapM_ (putStrLn . uncurry renderContract) contracts
  putStrLn "variant: gate dropped from the outer choice's observers"
  case compile roles invalidProtocol of
    Left err -> putStrLn ("refused: " ++ renderError err)
    Right _ -> do
      hPutStrLn stderr "invalid protocol unexpectedly compiled"
      exitFailure

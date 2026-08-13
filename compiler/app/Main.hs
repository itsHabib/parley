module Main (main) where

import Emit (contractFile)
import Example (invalidProtocol, protocolName, roles, validProtocol)
import Protocol (compile, renderContract, renderError)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["emit", dir] -> emit dir
    ["check"] -> check
    _ -> do
      hPutStrLn stderr "usage: parleyc emit <dir> | parleyc check"
      exitFailure

emit :: FilePath -> IO ()
emit dir =
  case compile roles validProtocol of
    Left err -> do
      hPutStrLn stderr ("refused: " ++ renderError err)
      exitFailure
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

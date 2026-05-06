{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns      #-}

module Plugin.TerminalState where

import           Data.Aeson
import           Data.Text (Text, pack, unpack)
import qualified Data.Text.IO as TIO
import qualified Data.ByteString.Lazy as BSL
import           Data.Time.Clock
import           Data.Time.Format
import           System.Directory
import           System.FilePath
import           System.Environment (lookupEnv)
import           GHC.Generics (Generic)
import           Data.UUID
import qualified Data.Map.Strict as M
import           System.Process
import           Control.Exception.Safe
import           Control.Monad
import           Control.Concurrent
import           Data.Maybe

import           Plugin.Types
import           Control.Lens hiding (Context)
import           Control.Monad.STM (atomically)
import           Control.Concurrent.STM.TVar (readTVar, writeTVar)

getTerminalStateFilePath :: IO FilePath
getTerminalStateFilePath = do
  maybeConfigDir <- lookupEnv "SIMULA_CONFIG_DIR"
  configDir <- case maybeConfigDir of
    Just dir -> return dir
    Nothing -> do
      home <- getHomeDirectory
      return $ home </> ".config" </> "Simula"
  return $ configDir </> "terminal-state.json"

saveTerminalState :: TerminalState -> IO ()
saveTerminalState state = do
  stateFile <- getTerminalStateFilePath
  let configDir = takeDirectory stateFile
  createDirectoryIfMissing True configDir
  BSL.writeFile stateFile (encode state)

loadTerminalState :: IO (Maybe TerminalState)
loadTerminalState = do
  stateFile <- getTerminalStateFilePath
  exists <- doesFileExist stateFile
  if exists
    then do
      content <- BSL.readFile stateFile
      case decode content of
        Just state -> return (Just state)
        Nothing -> do
          logPutStrLn "Failed to parse terminal-state.json"
          return Nothing
    else return Nothing

exportTerminalsToDesktop :: TerminalState -> IO ()
exportTerminalsToDesktop state = do
  logPutStrLn $ "Exporting " ++ show (length (_tsSessions state)) ++ " terminal sessions to desktop"
  forM_ (_tsSessions state) $ \session -> do
    let sessionName = _tsiSessionName session
    let location = Data.Maybe.maybe "terminal" id (_tsiLocation session)
    let title = "Simula: " ++ unpack sessionName
    logPutStrLn $ "Exporting session " ++ unpack sessionName ++ " to desktop"
    void $ createProcess $ proc "kitty" 
      [ "launch", "--title", title
      , "tmux", "attach", "-t", unpack sessionName
      ]

importTerminalsFromDesktop :: IO ()
importTerminalsFromDesktop = do
  logPutStrLn "Closing exported terminal windows on desktop"
  void $ createProcess $ proc "pkill" ["-f", "-i", "kitty.*Simula.*tmux"]

restoreTerminalSessions :: GodotSimulaServer -> TerminalState -> IO ()
restoreTerminalSessions gss state = do
  logPutStrLn $ "Restoring " ++ show (length (_tsSessions state)) ++ " terminal sessions"
  forM_ (_tsSessions state) $ \session -> do
    let sessionName = _tsiSessionName session
    let savedPos = _tsiPosition session
    atomically $ do
      pending <- readTVar (gss ^. gssPendingRestores)
      writeTVar (gss ^. gssPendingRestores) (pending ++ [savedPos])
    exists <- tmuxSessionExists sessionName
    if exists
      then do
        logPutStrLn $ "Session " ++ unpack sessionName ++ " exists, reattaching in Simula at position " ++ show savedPos
        void $ attachToExistingTmuxSession gss session (_tsiLocation session)
      else do
        logPutStrLn $ "Session " ++ unpack sessionName ++ " does not exist, creating new session"
        void $ terminalLaunch gss (_tsiLocation session) (Just savedPos)

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

module PMS.Infra.Watch.DS.Core where

import System.IO
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Lens
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import Data.Default
import qualified Data.Text as T
import Control.Monad.Except
import System.FilePath
import qualified Control.Exception.Safe as E
import qualified System.FSNotify as S
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL


import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM

import PMS.Infra.Watch.DM.Type
import PMS.Infra.Watch.DS.Utility


-- |
--
app :: AppContext ()
app = do
  $logDebugS DM._LOGTAG "app called."
  runConduit pipeline
  where
    pipeline :: ConduitM () Void AppContext ()
    pipeline = src .| cmd2task .| sink

---------------------------------------------------------------------------------
-- |
--
src :: ConduitT () DM.WatchCommand AppContext ()
src = lift go >>= yield >> src
  where
    go :: AppContext DM.WatchCommand
    go = do
      queue <- view DM.watchQueueDomainData <$> lift ask
      liftIO $ STM.atomically $ STM.readTQueue queue

---------------------------------------------------------------------------------
-- |
--
cmd2task :: ConduitT DM.WatchCommand (IOTask ()) AppContext ()
cmd2task = await >>= \case
  Just cmd -> flip catchError errHdl $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: String -> ConduitT DM.WatchCommand (IOTask ()) AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      cmd2task

    go :: DM.WatchCommand -> AppContext (IOTask ())
    go (DM.EchoWatchCommand dat) = genEchoTask dat
    go (DM.ToolsListWatchCommand dat) = genToolsListWatchTask dat
    go (DM.PromptsListWatchCommand dat) = genPromptsListWatchTask dat

---------------------------------------------------------------------------------
-- |
--
sink :: ConduitT (IOTask ()) Void AppContext ()
sink = await >>= \case
  Just req -> flip catchError errHdl $ do
    lift (go req) >> sink
  Nothing -> do
    $logWarnS DM._LOGTAG "sink: await returns nothing. skip."
    sink

  where
    errHdl :: String -> ConduitT (IOTask ()) Void AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "sink: exception occurred. skip. " ++ msg
      sink

    go :: (IO ()) -> AppContext ()
    go task = do
      $logDebugS DM._LOGTAG "sink: start task."
      liftIOE task
      $logDebugS DM._LOGTAG "sink: end task."
      return ()

---------------------------------------------------------------------------------
-- |
--
genEchoTask :: DM.EchoWatchCommandData -> AppContext (IOTask ())
genEchoTask dat = do
  notiQ <- view DM.notificationQueueDomainData <$> lift ask
  let val = dat^.DM.valueEchoWatchCommandData

  $logDebugS DM._LOGTAG $ T.pack $ "echoTask: echo : " ++ val
  return $ echoTask notiQ dat val


-- |
--
echoTask :: STM.TQueue DM.McpNotification -> DM.EchoWatchCommandData -> String -> IOTask ()
echoTask notiQ _ val = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.echoTask run. " ++ val

  let dat = def {DM._methodMcpToolsListChangedNotificationData = val}
      res = DM.McpToolsListChangedNotification dat

  STM.atomically $ STM.writeTQueue notiQ res

  hPutStrLn stderr "[INFO] PMS.Infra.Watch.DS.Core.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.echoTask.errHdl " ++ show e
    
-- |
--
genToolsListWatchTask :: DM.ToolsListWatchCommandData -> AppContext (IOTask ())
genToolsListWatchTask dat = do
  toolsDir <- view DM.toolsDirDomainData <$> lift ask
  notiQ <- view DM.notificationQueueDomainData <$> lift ask
  mgrVar <- view watchManagerAppData <$> ask
  mgr <- liftIOE $ STM.atomically $ STM.readTMVar mgrVar
  let toolsJ = toolsDir </> DM._TOOLS_LIST_FILE

  $logDebugS DM._LOGTAG $ T.pack $ "toolsListWatchTask: directory " ++ toolsDir
  $logDebugS DM._LOGTAG $ T.pack $ "toolsListWatchTask: file " ++ toolsJ
 
  return $ toolsListWatchTask notiQ dat mgr toolsDir


-- |
--   
toolsListWatchTask :: STM.TQueue DM.McpNotification -> DM.ToolsListWatchCommandData -> S.WatchManager -> String -> IOTask ()
toolsListWatchTask notiQ _ mgr toolsDir = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.work.toolsListWatchTask run. "

  _stop <- S.watchTree mgr toolsDir isToolsListJson onToolsListUpdated

  hPutStrLn stderr "[INFO] PMS.Infra.Watch.DS.Core.toolsListWatchTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = hPutStrLn stderr $ "[ERROR] PMS.Infra.Watch.DS.Core.toolsListWatchTask exception occurred. " ++ show e

    isToolsListJson :: S.Event -> Bool
    isToolsListJson e = takeFileName (S.eventPath e) == DM._TOOLS_LIST_FILE

    onToolsListUpdated :: S.Event -> IO ()
#ifdef mingw32_HOST_OS
    onToolsListUpdated e@S.Modified{} = response $ S.eventPath e
#else
    onToolsListUpdated e@S.CloseWrite{} = response $ S.eventPath e
#endif
    onToolsListUpdated e = hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.toolsListWatchTask ignore event: " ++ show e

    readToolsList :: FilePath -> IO BL.ByteString
    readToolsList path = do
      cont <- T.readFile path
      return $ BL.fromStrict $ TE.encodeUtf8 cont

    response :: String -> IO ()
    response toolFile = do
      hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.toolsListWatchTask.response called. " ++ toolFile
      tools <- readToolsList toolFile

      let params = def {DM._toolsMcpToolsListChangedNotificationDataParams = DM.RawJsonByteString tools}
          dat = def {DM._paramsMcpToolsListChangedNotificationData = params}
          res = DM.McpToolsListChangedNotification dat

      STM.atomically $ STM.writeTQueue notiQ res


-- |
--
genPromptsListWatchTask :: DM.PromptsListWatchCommandData -> AppContext (IOTask ())
genPromptsListWatchTask dat = do
  promptsDir <- view DM.promptsDirDomainData <$> lift ask
  notiQ <- view DM.notificationQueueDomainData <$> lift ask
  mgrVar <- view watchManagerAppData <$> ask
  mgr <- liftIOE $ STM.atomically $ STM.readTMVar mgrVar
  let promptsJ = promptsDir </> DM._PROMPTS_LIST_FILE

  $logDebugS DM._LOGTAG $ T.pack $ "promptsListWatchTask: directory " ++ promptsDir
  $logDebugS DM._LOGTAG $ T.pack $ "promptsListWatchTask: file " ++ promptsJ

  return $ promptsListWatchTask notiQ dat mgr promptsDir


-- |
--
promptsListWatchTask :: STM.TQueue DM.McpNotification -> DM.PromptsListWatchCommandData -> S.WatchManager -> String -> IOTask ()
promptsListWatchTask notiQ _ mgr promptsDir = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.work.promptsListWatchTask run. "

  _stop <- S.watchTree mgr promptsDir isTargetFile onPromptsListUpdated

  hPutStrLn stderr "[INFO] PMS.Infra.Watch.DS.Core.promptsListWatchTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = hPutStrLn stderr $ "[ERROR] PMS.Infra.Watch.DS.Core.promptsListWatchTask exception occurred. " ++ show e

    isTargetFile :: S.Event -> Bool
    isTargetFile e =
      let file = takeFileName (S.eventPath e)
          ext  = takeExtension file
      in file == DM._PROMPTS_LIST_FILE || ext `elem` [".md", ".txt", ".prompt"]

    onPromptsListUpdated :: S.Event -> IO ()
    onPromptsListUpdated e@S.CloseWrite{} = response $ S.eventPath e
    onPromptsListUpdated e = hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.promptsListWatchTask ignore event: " ++ show e

    readPromptsList :: FilePath -> IO BL.ByteString
    readPromptsList path = do
      cont <- T.readFile path
      return $ BL.fromStrict $ TE.encodeUtf8 cont

    response :: String -> IO ()
    response updateFile = do
      hPutStrLn stderr $ "[INFO] PMS.Infra.Watch.DS.Core.promptsListWatchTask.response called. " ++ updateFile

      let promptsFile = promptsDir </> DM._PROMPTS_LIST_FILE
      prompts <- readPromptsList promptsFile

      let params = def {DM._promptsMcpPromptsListChangedNotificationDataParams = DM.RawJsonByteString prompts}
          dat = def {DM._paramsMcpPromptsListChangedNotificationData = params}
          res = DM.McpPromptsListChangedNotification dat

      STM.atomically $ STM.writeTQueue notiQ res


{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

module PMS.Infra.Watch.App.ControlSpec (spec) where

import Test.Hspec
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Exception (finally)
import qualified Control.Concurrent.STM as STM
import Control.Lens
import Data.Default
import Data.List (isPrefixOf)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import qualified Data.ByteString.Lazy as BL

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Infra.Watch.App.Control as SUT
import qualified PMS.Infra.Watch.DM.Type as SUT

-- |
--
data SpecContext = SpecContext {
                   _domainDataSpecContext :: DM.DomainData
                 , _appDataSpecContext :: SUT.AppData
                 }

makeLenses ''SpecContext

defaultSpecContext :: IO SpecContext
defaultSpecContext = do
  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return SpecContext {
           _domainDataSpecContext = domDat
         , _appDataSpecContext    = appDat
         }

-- |
--
spec :: Spec
spec = do
  runIO $ putStrLn "Start Spec."
  beforeAll setUpOnce $
    afterAll tearDownOnce .
      beforeWith setUp .
        after tearDown $ run

-- |
--
setUpOnce :: IO SpecContext
setUpOnce = do
  putStrLn "[INFO] EXECUTED ONLY ONCE BEFORE ALL TESTS START."
  defaultSpecContext

-- |
--
tearDownOnce :: SpecContext -> IO ()
tearDownOnce _ = do
  putStrLn "[INFO] EXECUTED ONLY ONCE AFTER ALL TESTS FINISH."

-- |
--
setUp :: SpecContext -> IO SpecContext
setUp ctx = do
  putStrLn "[INFO] EXECUTED BEFORE EACH TEST STARTS."
  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return ctx {
               _domainDataSpecContext = domDat
             , _appDataSpecContext    = appDat
             }

-- |
--
tearDown :: SpecContext -> IO ()
tearDown _ = do
  putStrLn "[INFO] EXECUTED AFTER EACH TEST FINISHES."

-- |
--
run :: SpecWith SpecContext
run = do
  describe "runWithAppData" $ do

    context "when echo command issued." $ do
      it "should call callback" $ \ctx -> do
        putStrLn "[INFO] EXECUTING THE FIRST TEST."

        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.watchQueueDomainData
            notiQ  = domDat^.DM.notificationQueueDomainData
            expect = "abc"
            argDat = DM.EchoWatchCommandData def expect
            args   = DM.EchoWatchCommand argDat

        thId <- async $ SUT.runWithAppData appDat domDat

        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsListChangedNotification dat) <- STM.atomically $ STM.readTQueue notiQ

        let actual = dat^.DM.methodMcpToolsListChangedNotificationData
        actual `shouldBe` expect

        cancel thId

    -- TC-CR01: Verify that fsnotify internal log messages do NOT leak to stdout
    -- when a PromptsListWatchCommand is issued.
    -- On Windows, F.defaultConfig causes the WatchManager to write "fsnotify: h..."
    -- to stdout, which corrupts the MCP JSON-RPC stream.
    -- This test reproduces the defect and serves as a regression guard after the fix.
    context "when PromptsListWatchCommand issued." $ do
      it "should NOT leak fsnotify log messages to stdout" $ \ctx ->
        withSystemTempDirectory "pms-watch-spec" $ \tmpDir -> do
          putStrLn "[INFO] EXECUTING TC-CR01: fsnotify stdout leak test."

          -- Prepare a temporary prompts directory with an empty prompts-list.json
          let promptsDir      = tmpDir </> "prompts"
              promptsListFile = promptsDir </> "prompts-list.json"

          createDirectoryIfMissing True promptsDir
          writeFile promptsListFile "[]"

          -- Override promptsDir in DomainData to point at the temp directory
          let domDat0 = ctx^.domainDataSpecContext
              domDat  = domDat0 { DM._promptsDirDomainData = promptsDir }
              appDat  = ctx^.appDataSpecContext
              cmdQ    = domDat^.DM.watchQueueDomainData

          -- Redirect stdout to a temp file and capture any fsnotify leakage
          capturedLines <- withCapturedStdout $ do

            thId <- async $ SUT.runWithAppData appDat domDat

            -- Issue PromptsListWatchCommand to trigger watchTree startup
            let argDat = DM.PromptsListWatchCommandData {}
                args   = DM.PromptsListWatchCommand argDat
            STM.atomically $ STM.writeTQueue cmdQ args

            -- Wait for watchTree to start and for fsnotify internals to settle
            threadDelay (2 * 1000 * 1000)

            cancel thId

          hPutStrLn stderr $ "[INFO] TC-CR01: captured stdout lines: " ++ show capturedLines

          -- Assert that no "fsnotify:" prefixed lines appeared on stdout
          let leaked = filter ("fsnotify:" `isPrefixOf`) capturedLines
          leaked `shouldBe` []

    -- TC-CR05-01: ToolsListWatchCommand で tools-list.json（UTF-8）を更新したとき、
    -- notifications/tools/list_changed 通知が正常に配信されることを確認する。
    -- BL.readFile により systemLocale decode 例外は発生しない。
    context "when ToolsListWatchCommand issued and tools-list.json updated." $ do
      it "should deliver McpToolsListChangedNotification (TC-CR05-01)" $ \ctx ->
        tcCR05Tools ctx

    -- TC-CR05-02: PromptsListWatchCommand で prompts-list.json（UTF-8）を更新したとき、
    -- notifications/prompts/list_changed 通知が正常に配信されることを確認する。
    context "when PromptsListWatchCommand issued and prompts-list.json updated." $ do
      it "should deliver McpPromptsListChangedNotification (TC-CR05-02)" $ \ctx ->
        tcCR05Prompts ctx


-- |
-- Redirect stdout to a temporary file for the duration of the action,
-- then return the captured output as a list of lines.
withCapturedStdout :: IO () -> IO [String]
withCapturedStdout action =
  withSystemTempFile "captured-stdout" $ \tmpPath tmpHandle -> do
    -- Save the original stdout handle
    origStdout <- hDuplicate stdout
    -- Redirect stdout to the temp file
    hDuplicateTo tmpHandle stdout
    hSetBuffering stdout LineBuffering

    -- Run the action, then restore stdout
    action `finally` do
      hFlush stdout
      hDuplicateTo origStdout stdout
      hClose origStdout
      hClose tmpHandle

    -- Read back the captured content
    content <- readFile tmpPath
    return (lines content)


-- |
-- TC-CR05-01: ToolsListWatchCommand で tools-list.json（UTF-8）を更新したとき、
-- notifications/tools/list_changed 通知が正常に配信されること。
-- また fsnotify の handler 例外がノイズとして出ないこと（BL.readFile 採用により
-- systemLocale decode 例外が発生しない）。
tcCR05Tools :: SpecContext -> IO ()
tcCR05Tools ctx =
  withSystemTempDirectory "pms-watch-cr05-tools" $ \tmpDir -> do
    putStrLn "[INFO] EXECUTING TC-CR05-01: toolsList UTF-8 read test."

    -- Prepare temp tools directory with a minimal tools-list.json (UTF-8)
    let toolsDir      = tmpDir </> "tools"
        toolsListFile = toolsDir </> "tools-list.json"
        toolsContent  = "[{\"name\":\"pms_echo\",\"description\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}]"

    createDirectoryIfMissing True toolsDir
    BL.writeFile toolsListFile (BL.pack (map (fromIntegral . fromEnum) toolsContent))

    let domDat0 = ctx^.domainDataSpecContext
        domDat  = domDat0 { DM._toolsDirDomainData = toolsDir }
        appDat  = ctx^.appDataSpecContext
        cmdQ    = domDat^.DM.watchQueueDomainData
        notiQ   = domDat^.DM.notificationQueueDomainData

    thId <- async $ SUT.runWithAppData appDat domDat

    -- Issue ToolsListWatchCommand to register watchTree
    let argDat = DM.ToolsListWatchCommandData {}
        args   = DM.ToolsListWatchCommand argDat
    STM.atomically $ STM.writeTQueue cmdQ args

    -- Wait for watchTree to start
    threadDelay (1 * 1000 * 1000)

    -- Overwrite tools-list.json to trigger the file-change event
    let toolsContent2 = "[{\"name\":\"pms_echo2\",\"description\":\"echo2\",\"inputSchema\":{\"type\":\"object\"}}]"
    BL.writeFile toolsListFile (BL.pack (map (fromIntegral . fromEnum) toolsContent2))

    -- Wait for fsnotify event and notification delivery
    threadDelay (2 * 1000 * 1000)

    cancel thId

    -- Assert that at least one McpToolsListChangedNotification was enqueued
    notifications <- STM.atomically $ STM.flushTQueue notiQ
    let toolsNoti = [ n | n@(DM.McpToolsListChangedNotification _) <- notifications ]
    hPutStrLn stderr $ "[INFO] TC-CR05-01: tools notifications received: " ++ show (length toolsNoti)
    length toolsNoti `shouldSatisfy` (>= 1)


-- |
-- TC-CR05-02: PromptsListWatchCommand で prompts-list.json（UTF-8）を更新したとき、
-- notifications/prompts/list_changed 通知が正常に配信されること。
tcCR05Prompts :: SpecContext -> IO ()
tcCR05Prompts ctx =
  withSystemTempDirectory "pms-watch-cr05-prompts" $ \tmpDir -> do
    putStrLn "[INFO] EXECUTING TC-CR05-02: promptsList UTF-8 read test."

    -- Prepare temp prompts directory with a minimal prompts-list.json (UTF-8)
    let promptsDir      = tmpDir </> "prompts"
        promptsListFile = promptsDir </> "prompts-list.json"
        promptsContent  = "[{\"name\":\"skill_echo\",\"description\":\"echo skill\"}]"

    createDirectoryIfMissing True promptsDir
    BL.writeFile promptsListFile (BL.pack (map (fromIntegral . fromEnum) promptsContent))

    let domDat0 = ctx^.domainDataSpecContext
        domDat  = domDat0 { DM._promptsDirDomainData = promptsDir }
        appDat  = ctx^.appDataSpecContext
        cmdQ    = domDat^.DM.watchQueueDomainData
        notiQ   = domDat^.DM.notificationQueueDomainData

    thId <- async $ SUT.runWithAppData appDat domDat

    -- Issue PromptsListWatchCommand to register watchTree
    let argDat = DM.PromptsListWatchCommandData {}
        args   = DM.PromptsListWatchCommand argDat
    STM.atomically $ STM.writeTQueue cmdQ args

    -- Wait for watchTree to start
    threadDelay (1 * 1000 * 1000)

    -- Overwrite prompts-list.json to trigger the file-change event
    let promptsContent2 = "[{\"name\":\"skill_echo2\",\"description\":\"echo2 skill\"}]"
    BL.writeFile promptsListFile (BL.pack (map (fromIntegral . fromEnum) promptsContent2))

    -- Wait for fsnotify event and notification delivery
    threadDelay (2 * 1000 * 1000)

    cancel thId

    -- Assert that at least one McpPromptsListChangedNotification was enqueued
    notifications <- STM.atomically $ STM.flushTQueue notiQ
    let promptsNoti = [ n | n@(DM.McpPromptsListChangedNotification _) <- notifications ]
    hPutStrLn stderr $ "[INFO] TC-CR05-02: prompts notifications received: " ++ show (length promptsNoti)
    length promptsNoti `shouldSatisfy` (>= 1)

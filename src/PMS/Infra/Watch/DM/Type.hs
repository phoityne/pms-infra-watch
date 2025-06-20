{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.Watch.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH
import qualified System.FSNotify as F
import qualified Control.Concurrent.STM as STM

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.TH as DM


data AppData = AppData {
               _watchManagerAppData :: STM.TMVar F.WatchManager
             }

makeLenses ''AppData

defaultAppData :: IO AppData
defaultAppData = do
  mgr <- F.startManagerConf F.defaultConfig
  mgrVar <- STM.newTMVarIO mgr
  return AppData {
           _watchManagerAppData = mgrVar
         }

-- |
--
type AppContext = ReaderT AppData (ReaderT DM.DomainData (ExceptT DM.ErrorData (LoggingT IO)))

-- |
--
type IOTask = IO


--------------------------------------------------------------------------------------------
-- |
--
data StringToolParams =
  StringToolParams {
    _argumentsStringToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "StringToolParams", omitNothingFields = True} ''StringToolParams)
makeLenses ''StringToolParams

instance Default StringToolParams where
  def = StringToolParams {
        _argumentsStringToolParams = def
      }

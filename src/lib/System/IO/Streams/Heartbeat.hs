{-# LANGUAGE BangPatterns #-}

module System.IO.Streams.Heartbeat
    ( heartbeatOutputStream
    , heartbeatInputStream
    , HeartbeatException (..)
    ) where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel, link)
import           Control.Exception        (Exception, throw)
import           Control.Monad            (forever)
import           Data.IORef               (atomicModifyIORef', newIORef, writeIORef)
import           Data.Time.Clock          (DiffTime, UTCTime, diffTimeToPicoseconds, diffUTCTime, getCurrentTime)
import           System.IO.Streams        (InputStream, OutputStream)
import qualified System.IO.Streams        as Streams


-- | Send a message 'a' if nothing has been written on the stream for some interval of time.
-- Writing 'Nothing' to this 'OutputStream' is required for proper cleanup.
heartbeatOutputStream :: DiffTime -- ^ Heartbeat interval
                      -> a        -- ^ Heartbeat message
                      -> OutputStream a -> IO (OutputStream a)
heartbeatOutputStream interval msg os = do
    t <- newIORef =<< getCurrentTime
    writeAsync <- async $ delayInterval >> forever (writeHeartbeat t)
    link writeAsync
    Streams.makeOutputStream (resetHeartbeat t writeAsync)
  where
    delayInterval = delayDiffTime interval

    writeHeartbeat t = do
        !now <- getCurrentTime
        (!timeTilHeartbeat, !triggerHeartbeat) <- atomicModifyIORef' t (heartbeatTime interval now)

        if triggerHeartbeat
            then Streams.write (Just msg) os >> delayInterval
            else delayDiffTime timeTilHeartbeat

    resetHeartbeat t _ x@(Just _)       = Streams.write x os >> getCurrentTime >>= writeIORef t
    resetHeartbeat _ writeAsync Nothing = Streams.write Nothing os >> cancel writeAsync


-- | Exception to kill the heartbeat monitoring thread
-- Heartbeat Exceptions carry the grace period, ie. the last time a message was received
data HeartbeatException = MissedHeartbeat DiffTime deriving (Show, Eq)
instance Exception HeartbeatException


-- | Grace period = grace time multiplier x heartbeat interval
-- Usually something like graceMultiplier = 2 is a good idea.
--
-- This throws a 'MissedHeartbeat' exception if a heartbeat is not
-- received within the grace period.
heartbeatInputStream :: DiffTime -- ^ Heartbeat interval
                     -> DiffTime -- ^ Grace time multiplier
                     -> InputStream a -> IO (InputStream a)
heartbeatInputStream interval graceMultiplier is = do
    t <- newIORef =<< getCurrentTime
    checkAsync <- async $ delayDiffTime gracePeriod >> forever (checkHeartbeat t)
    link checkAsync
    -- If disconnect is received, cancel heartbeat watching thread
    Streams.mapM_ (resetHeartbeat t) is >>= Streams.atEndOfInput (cancel checkAsync)
  where
    gracePeriod = graceMultiplier * interval

    checkHeartbeat t = do
        !now <- getCurrentTime
        !triggerDisconnect <- snd <$> atomicModifyIORef' t (heartbeatTime gracePeriod now)

        if triggerDisconnect
            then throw (MissedHeartbeat gracePeriod)
            else delayDiffTime interval

    resetHeartbeat t _ = getCurrentTime >>= writeIORef t


-- | This is structured to work nicely with 'atomicModifyIORef'. Given
-- the heartbeat interval and the current timestamp, calculate if a
-- heartbeat must be sent and how much time there is until the next heartbeat
-- must be sent.
heartbeatTime :: DiffTime -- ^ Maximum time since last message, ie. heartbeat interval or grace period
              -> UTCTime  -- ^ Current timestamp
              -> UTCTime  -- ^ Last message timestamp
              -> (UTCTime, (DiffTime, Bool)) -- ^ (New last message timestamp, (time til heartbeat, send new message?))
heartbeatTime interval now lastTime = (if triggerHeartbeat then now else lastTime, (timeTilHeartbeat, triggerHeartbeat))
  where
    timeSinceMsg = realToFrac $ diffUTCTime now lastTime
    triggerHeartbeat = timeSinceMsg >= interval
    timeTilHeartbeat = interval - timeSinceMsg


delayDiffTime :: DiffTime -> IO ()
delayDiffTime = threadDelay . picosToMicros
  where picosToMicros = fromIntegral . diffTimeToPicoseconds . (/ 1000000)

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TupleSections #-}

module System.IO.Streams.Heartbeat (
    heartbeatOutputStream,
    heartbeatInputStream,
    HeartbeatException (..),
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, link)
import Control.Exception (Exception, throw)
import Control.Monad (forever, void)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromJust)
import Data.Time.Clock (DiffTime, UTCTime, diffTimeToPicoseconds, diffUTCTime, getCurrentTime)
import System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as Streams


-- | Send a message 'a' if nothing has been written on the stream for some
-- interval of time.
--
-- Writing 'Nothing' to this 'OutputStream' is required for proper cleanup.
--
-- Also returns an 'IO' action that can be used to dynamically update the
-- heartbeat interval, where 'Nothing' indicates that heartbeating should be
-- disabled.
heartbeatOutputStream ::
    -- | Heartbeat interval
    Maybe DiffTime ->
    -- | Heartbeat message
    a ->
    OutputStream a ->
    IO (OutputStream a, Maybe DiffTime -> IO ())
heartbeatOutputStream interval msg os = do
    t <- newIORef =<< getCurrentTime
    intervalRef <- newIORef interval
    writeAsync <- async $ delayInterval >> forever (writeHeartbeat t intervalRef)
    link writeAsync
    (,updateHeartbeatInterval intervalRef) <$> Streams.makeOutputStream (resetHeartbeat t writeAsync)
  where
    delayInterval = delayDiffTime interval

    writeHeartbeat t intervalRef = do
        !now <- getCurrentTime
        int <- readIORef intervalRef
        (!timeTilHeartbeat, !triggerHeartbeat) <- atomicModifyIORef' t (heartbeatTime int now)

        if triggerHeartbeat
            then Streams.write (Just msg) os >> delayInterval
            else delayDiffTime timeTilHeartbeat

    resetHeartbeat t _ x@(Just _) = Streams.write x os >> getCurrentTime >>= writeIORef t
    resetHeartbeat _ writeAsync Nothing = Streams.write Nothing os >> cancel writeAsync


-- | Exception to kill the heartbeat monitoring thread
-- Heartbeat Exceptions carry the grace period, ie. the last time a message was received
newtype HeartbeatException = MissedHeartbeat DiffTime deriving (Show, Eq)


instance Exception HeartbeatException


updateHeartbeatInterval :: IORef (Maybe DiffTime) -> (Maybe DiffTime -> IO ())
updateHeartbeatInterval ref int = void $ atomicModifyIORef' ref (const (int, int))


-- | Grace period = grace time multiplier x heartbeat interval
-- Usually something like graceMultiplier = 2 is a good idea.
--
-- Also returns an 'IO' action that can be used to dynamically update
-- the heartbeat interval.
--
-- This throws a 'MissedHeartbeat' exception if a heartbeat is not
-- received within the grace period.
heartbeatInputStream ::
    -- | Heartbeat interval
    Maybe DiffTime ->
    -- | Grace time multiplier
    DiffTime ->
    InputStream a ->
    IO (InputStream a, Maybe DiffTime -> IO ())
heartbeatInputStream interval graceMultiplier is = do
    t <- newIORef =<< getCurrentTime
    intervalRef <- newIORef interval
    checkAsync <- async $ delayDiffTime gracePeriod >> forever (checkHeartbeat t intervalRef)
    link checkAsync
    -- If disconnect is received, cancel heartbeat watching thread
    heartbeatStream <- Streams.mapM_ (resetHeartbeat t) is >>= Streams.atEndOfInput (cancel checkAsync)
    pure (heartbeatStream, updateHeartbeatInterval intervalRef)
  where
    gracePeriod = (graceMultiplier *) <$> interval

    checkHeartbeat t intervalRef = do
        !now <- getCurrentTime
        int <- readIORef intervalRef
        let grace = (graceMultiplier *) <$> int

        !triggerDisconnect <- snd <$> atomicModifyIORef' t (heartbeatTime grace now)

        -- 'triggerDisconnect' can ONLY be true if gracePeriod is NOT 'Nothing', so
        -- 'fromJust' should be safe here
        if triggerDisconnect
            then throw (MissedHeartbeat $ fromJust gracePeriod)
            else delayDiffTime interval

    resetHeartbeat t _ = getCurrentTime >>= writeIORef t


-- | This is structured to work nicely with 'atomicModifyIORef'. Given
-- the heartbeat interval and the current timestamp, calculate if a
-- heartbeat must be sent and how much time there is until the next heartbeat
-- must be sent.
heartbeatTime ::
    -- | Maximum time since last message, ie. heartbeat interval or grace period
    Maybe DiffTime ->
    -- | Current timestamp
    UTCTime ->
    -- | Last message timestamp
    UTCTime ->
    -- | (New last message timestamp, (time til heartbeat, send new message?))
    (UTCTime, (Maybe DiffTime, Bool))
heartbeatTime interval now lastTime = (if triggerHeartbeat then now else lastTime, (timeTilHeartbeat, triggerHeartbeat))
  where
    timeSinceMsg = realToFrac $ diffUTCTime now lastTime
    triggerHeartbeat = maybe False (timeSinceMsg >=) interval
    timeTilHeartbeat = fmap (\i -> i - timeSinceMsg) interval


-- currently this will cause 0 delay if the interval is 'Nothing', maybe we want to have a more sane
-- default that won't spin so much
delayDiffTime :: Maybe DiffTime -> IO ()
delayDiffTime = traverse_ (threadDelay . picosToMicros)
  where
    picosToMicros = fromIntegral . diffTimeToPicoseconds . (/ 1000000)

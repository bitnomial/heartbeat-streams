{-# LANGUAGE TupleSections #-}

module System.IO.Streams.Heartbeat (
    heartbeatOutputStream,
    heartbeatOutputStreamM,
    heartbeatInputStream,
    heartbeatInputStreamWithHandler,
    HeartbeatException (..),
    HeartbeatError (..),
) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, threadDelay)
import Control.Concurrent.Async (
    Async,
    AsyncCancelled (AsyncCancelled),
    ExceptionInLinkedThread (ExceptionInLinkedThread),
    async,
    cancel,
    waitCatch,
 )
import Control.Concurrent.MVar (MVar, modifyMVarMasked_, newMVar, readMVar)
import Control.Exception (Exception, SomeException, fromException, mask, throwIO, throwTo, try)
import Control.Monad (forever, void)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Time.Clock (DiffTime, UTCTime, diffTimeToPicoseconds, diffUTCTime, getCurrentTime)
import System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as Streams


-- | Run an arbitrary IO action if nothing has been written on the stream
-- for some interval of time.
--
-- Writing 'Nothing' to this 'OutputStream' is required for proper cleanup.
--
-- Also returns an 'IO' action that can be used to dynamically update the
-- heartbeat interval, where 'Nothing' indicates that heartbeating should be
-- disabled.
heartbeatOutputStreamM ::
    -- | Heartbeat interval
    Maybe DiffTime ->
    -- | Heartbeat action
    IO () ->
    OutputStream a ->
    IO (OutputStream a, Maybe DiffTime -> IO ())
heartbeatOutputStreamM interval heartbeatAction os = do
    me <- myThreadId
    intervalRef <- newIORef interval
    t <- newIORef =<< getCurrentTime

    let writeHeartbeatForever =
            readIORef intervalRef
                >>= traverse
                    ( \int -> linkedAsyncTo me $ do
                        delayDiffTime int
                        forever (writeHeartbeat t int)
                    )

    asyncRef <- newMVar =<< writeHeartbeatForever
    (,updateHeartbeatInterval writeHeartbeatForever asyncRef intervalRef)
        <$> Streams.makeOutputStream (resetHeartbeat t asyncRef)
  where
    writeHeartbeat t int = do
        now <- getCurrentTime
        (timeTilHeartbeat, triggerHeartbeat) <- atomicModifyIORef' t (heartbeatTime int now)

        if triggerHeartbeat
            then heartbeatAction >> delayDiffTime int
            else delayDiffTime timeTilHeartbeat

    resetHeartbeat t _ x@(Just _) = do
        Streams.write x os
        getCurrentTime >>= writeIORef t
    resetHeartbeat _ asyncRef Nothing = do
        Streams.write Nothing os
        traverse_ cancel =<< readMVar asyncRef


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
heartbeatOutputStream interval msg os = heartbeatOutputStreamM interval sendHeartbeat os
  where
    sendHeartbeat = Streams.write (Just msg) os


-- | Metadata for heartbeating errors
-- Heartbeat Errors carry the grace period, ie. the last time a message was received
-- and the time since last message
data HeartbeatError = MissedHeartbeatError DiffTime DiffTime deriving (Show, Eq)


-- | Exception to kill the heartbeat monitoring thread
-- Heartbeat Exceptions carry the grace period, ie. the last time a message was received
-- and the time since last message
data HeartbeatException = MissedHeartbeat DiffTime DiffTime deriving (Show, Eq)


instance Exception HeartbeatException


-- | Grace period = grace time multiplier x heartbeat interval
-- Usually something like graceMultiplier = 2 is a good idea.
--
-- Also returns an 'IO' action that can be used to dynamically update
-- the heartbeat interval.
--
-- This throws a 'MissedHeartbeat' exception if a heartbeat is not
-- received within the grace period.
--
-- NOTE: The input stream must have a sink in order for it to properly
-- detect heartbeats. If no messages are read within the grace period
-- a HeartbeatException will be thrown.
heartbeatInputStream ::
    -- | Heartbeat interval
    Maybe DiffTime ->
    -- | Grace time multiplier
    DiffTime ->
    InputStream a ->
    IO (InputStream a, Maybe DiffTime -> IO ())
heartbeatInputStream = heartbeatInputStreamWithHandler throwException
  where
    throwException (MissedHeartbeatError grace timeSinceMsg) =
        throwIO $ MissedHeartbeat grace timeSinceMsg


-- | Grace period = grace time multiplier x heartbeat interval
-- Usually something like graceMultiplier = 2 is a good idea.
--
-- Also returns an 'IO' action that can be used to dynamically update
-- the heartbeat interval.
--
-- This takes a 'HeartbeatError' handler to run on any missed heartbeats.
-- Unless the handler explicitly kills the thread, it will continue checking
-- for heartbeats.
--
-- NOTE: The input stream must have a sink in order for it to properly
-- detect heartbeats. If no messages are read within the grace period
-- a HeartbeatException will be thrown.
heartbeatInputStreamWithHandler ::
    -- | Handler for heartbeat errors
    (HeartbeatError -> IO ()) ->
    -- | Heartbeat interval
    Maybe DiffTime ->
    -- | Grace time multiplier
    DiffTime ->
    InputStream a ->
    IO (InputStream a, Maybe DiffTime -> IO ())
heartbeatInputStreamWithHandler onMissedHeartbeat interval graceMultiplier is = do
    me <- myThreadId
    intervalRef <- newIORef interval
    t <- newIORef =<< getCurrentTime

    let checkHeartbeatForever =
            readIORef intervalRef
                >>= traverse
                    ( \int -> linkedAsyncTo me $ do
                        delayDiffTime $ graceMultiplier * int
                        forever (checkHeartbeat t int)
                    )

    asyncRef <- newMVar =<< checkHeartbeatForever
    -- If disconnect is received, cancel heartbeat watching thread
    let killAsync = readMVar asyncRef >>= traverse_ cancel
    heartbeatStream <- Streams.mapM_ (resetHeartbeat t) is >>= Streams.atEndOfInput killAsync
    pure (heartbeatStream, updateHeartbeatInterval checkHeartbeatForever asyncRef intervalRef)
  where
    checkHeartbeat t int = do
        now <- getCurrentTime
        let grace = graceMultiplier * int

        triggerDisconnect <- snd <$> atomicModifyIORef' t (heartbeatTime grace now)

        if triggerDisconnect
            then do
                lastMsg <- readIORef t
                let timeSinceMsg = realToFrac $ diffUTCTime now lastMsg
                onMissedHeartbeat (MissedHeartbeatError grace timeSinceMsg)
            else delayDiffTime int

    resetHeartbeat t _ = getCurrentTime >>= writeIORef t


updateHeartbeatInterval ::
    IO (Maybe (Async ())) ->
    MVar (Maybe (Async ())) ->
    IORef (Maybe DiffTime) ->
    Maybe DiffTime ->
    IO ()
updateHeartbeatInterval newHB asyncRef intervalRef newInterval =
    modifyMVarMasked_ asyncRef $ \hbAsync -> do
        traverse_ cancel hbAsync
        writeIORef intervalRef newInterval
        newHB


-- | This is structured to work nicely with 'atomicModifyIORef'. Given
-- the heartbeat interval and the current timestamp, calculate if a
-- heartbeat must be sent and how much time there is until the next heartbeat
-- must be sent.
heartbeatTime ::
    -- | Maximum time since last message, ie. heartbeat interval or grace period
    DiffTime ->
    -- | Current timestamp
    UTCTime ->
    -- | Last message timestamp
    UTCTime ->
    -- | (New last message timestamp, (time til heartbeat, send new message?))
    (UTCTime, (DiffTime, Bool))
heartbeatTime interval now lastTime =
    (if triggerHeartbeat then now else lastTime, (timeTilHeartbeat, triggerHeartbeat))
  where
    timeSinceMsg = realToFrac $ diffUTCTime now lastTime
    triggerHeartbeat = timeSinceMsg >= interval
    timeTilHeartbeat = interval - timeSinceMsg


delayDiffTime :: DiffTime -> IO ()
delayDiffTime = threadDelay . picosToMicros
  where
    picosToMicros = fromIntegral . diffTimeToPicoseconds . (/ 1000000)


linkedAsyncTo :: ThreadId -> IO a -> IO (Async a)
linkedAsyncTo threadId action = do
    linkedAsync <- async action
    linkTo threadId linkedAsync
    return linkedAsync


-- From the async library but slightly modified to allow linking to another thread

linkTo :: ThreadId -> Async a -> IO ()
linkTo = linkOnlyTo (not . isCancel)


isCancel :: SomeException -> Bool
isCancel e
    | Just AsyncCancelled <- fromException e = True
    | otherwise = False


tryAll :: IO a -> IO (Either SomeException a)
tryAll = try


forkRepeat :: IO a -> IO ThreadId
forkRepeat action =
    mask $ \restore ->
        let go = do
                r <- tryAll (restore action)
                case r of
                    Left _ -> go
                    _ -> return ()
         in forkIO go


linkOnlyTo ::
    (SomeException -> Bool) ->
    ThreadId ->
    Async a ->
    IO ()
linkOnlyTo shouldThrow threadId a = void . forkRepeat $ do
    r <- waitCatch a
    case r of
        Left e | shouldThrow e -> throwTo threadId (ExceptionInLinkedThread a e)
        _otherwise -> return ()

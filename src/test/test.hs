{-# LANGUAGE NumericUnderscores #-}

import Test.Tasty
import Test.Tasty.HUnit

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    ExceptionInLinkedThread (..),
    async,
 )
import Control.Exception (Exception, SomeException, fromException, try)
import Control.Monad ((<=<))
import Data.Time.Clock (DiffTime, diffTimeToPicoseconds)
import qualified System.IO.Streams as Streams
import System.IO.Streams.Concurrent (makeChanPipe)
import System.IO.Streams.Heartbeat (
    HeartbeatException (MissedHeartbeat),
    heartbeatInputStream,
    heartbeatOutputStream,
 )
import System.Timeout (timeout)


main :: IO ()
main = defaultMain tests


data HeartbeatMessage = HeartbeatMessage | TestMessage deriving (Show, Eq)


tests :: TestTree
tests =
    testGroup
        "hearbeat-streams tests"
        [ testCase "heartbeats are written correctly on the interval" $ do
            (from, to) <- makeChanPipe
            (hbOutputStream, _updateOutputInterval) <- heartbeatOutputStream (Just hbInterval) HeartbeatMessage to

            delayHBInterval 2.5

            Streams.write Nothing hbOutputStream

            msgs <- Streams.toList from
            length msgs @?= 2
        , testCase "heartbeats are sent and received correctly" $ do
            (from, to) <- makeChanPipe
            (hbOutputStream, _updateOutputInterval) <- heartbeatOutputStream (Just hbInterval) HeartbeatMessage to
            (hbInputStream, updateInputInterval) <- heartbeatInputStream (Just hbInterval) graceMultiplier from
            (os, getList) <- Streams.listOutputStream

            async $ Streams.connect hbInputStream os

            delayHBInterval 2.5
            Streams.write Nothing hbOutputStream
            updateInputInterval Nothing

            msgs <- getList
            length msgs @?= 2
        , testCase "heartbeats and other messages play nicely" $ do
            (from, to) <- makeChanPipe
            (hbOutputStream, _updateOutputInterval) <- heartbeatOutputStream (Just hbInterval) HeartbeatMessage to

            delayHBInterval 0.5

            Streams.write (Just TestMessage) hbOutputStream

            delayHBInterval 0.5

            Streams.write (Just TestMessage) hbOutputStream

            delayHBInterval 1.5

            Streams.write Nothing hbOutputStream

            msgs <- Streams.toList from
            msgs @?= [TestMessage, TestMessage, HeartbeatMessage]
        , testCaseTimeout 7 "Missed heartbeats are detected" $
            missedHeartbeatTest `shouldThrow` detectHBException
        , testCase "heartbeats intervals can be updated" $ do
            (from, to) <- makeChanPipe
            (_hbOutputStream, updateOutputInterval) <- heartbeatOutputStream (Just hbInterval) HeartbeatMessage to
            (hbInputStream, updateInputInterval) <- heartbeatInputStream (Just hbInterval) graceMultiplier from
            (os, getList) <- Streams.listOutputStream

            async $ Streams.connect hbInputStream os

            -- wait for 2 hbIntervals
            delayHBInterval 2.5
            msgs <- getList
            length msgs @?= 2

            -- kill timer threads, expect no heartbeats
            updateOutputInterval Nothing
            updateInputInterval Nothing

            delayHBInterval 2.5

            msgs2 <- getList
            length msgs2 @?= 0

            -- change hbInterval from what it was before, summoning timer threads again
            updateOutputInterval (Just 2 :: Maybe DiffTime)
            updateInputInterval (Just 2 :: Maybe DiffTime)

            delayHBInterval 2.5

            msgs3 <- getList
            length msgs3 @?= 1
        ]


missedHeartbeatTest :: IO ()
missedHeartbeatTest = do
    (from, _) <- makeChanPipe
    (_hbInputStream, updateInputInterval) <- heartbeatInputStream (Just hbInterval) graceMultiplier from

    delayHBInterval 2.5
    updateInputInterval Nothing

    assertFailure "Should not reach here"


detectHBException :: SomeException -> Bool
detectHBException e
    | Just (ExceptionInLinkedThread _ e') <- fromException e = detectHBException e'
    | Just (MissedHeartbeat _ _) <- fromException e = True
    | otherwise = False


graceMultiplier :: DiffTime
graceMultiplier = 2


hbInterval :: DiffTime
hbInterval = 1


delayHBInterval :: DiffTime -> IO ()
delayHBInterval n = threadDelay (fromIntegral . (`div` 1_000_000) . diffTimeToPicoseconds $ n * hbInterval)


testCaseTimeout :: Int -> String -> Assertion -> TestTree
testCaseTimeout n title = testCase title . (maybe timeoutErr return <=< timeout (n * s))
  where
    timeoutErr = assertFailure "Test ran out of time"
    s = (10 :: Int) ^ (6 :: Int)


shouldThrow :: Exception e => IO a -> (e -> Bool) -> Assertion
action `shouldThrow` p =
    try action >>= either (assertBool <$> exceptionButWrong <*> p) (const $ assertFailure noException)
  where
    exceptionButWrong e = "Threw exception, but wrong exception: " <> show e
    noException = "Did not throw exception"

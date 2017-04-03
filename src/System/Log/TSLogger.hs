{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{-|

Thread-safe logging with bonus controlled-schedule debugging capabilities.

This module supports logging to memory, serializing messages and deferring the work
of actually printing them.  Another thread can flush the logged messages at its
leisure.

The second capability of this infrastructure is to use the debugging print messages
as points at which to gate the execution of the program.  That is, each `logOn`
call becomes a place where the program blocks and checks in with a central
coordinator, which only allows one thread to unblock at a time.  Thus, if there are
sufficient debug logging messages in the program, this can enable a form of
deterministic replay (and quickcheck-style testing of different interleavings).
This becomes most useful when there is a log message before each read and write 
to shared memory.

Note that this library allows compile-time toggling of debug support.
When it is compiled out, it should have no overhead. When it is
compiled in, it will be controlled by an environment variable
dynamically.

 -}

module System.Log.TSLogger
       (

         -- * Global variables
         dbgLvl, defaultMemDbgRange,

         -- * Basic Logger interface
         newLogger,
         logStrLn, logByteStringLn, logTextLn, 

         -- * detailed interface.
         logOn, Logger(closeIt, flushLogs, minLvl, maxLvl),
         WaitMode(..), LogMsg(..), OutDest(..),

         -- * Conversion/printing
         msgBody,
                 
         -- * Detailed configuration control
         DbgCfg(..)
               
         -- General utilities
         --  Backoff(totalWait), newBackoff, backoff,
       )
       where

import           Control.Monad
import qualified Control.Exception as E
import qualified Control.Concurrent.Async as A
import           Data.IORef
import qualified Data.Sequence as Seq
import           Data.List (sortBy)
import           GHC.Conc hiding (yield)
import           Control.Concurrent
import           System.IO.Unsafe (unsafePerformIO)
import           System.IO (stderr, stdout, hFlush, hPutStrLn, Handle)
import           System.Environment(getEnvironment)
import           System.Random
#ifdef DEBUG_LOGGER
import           Text.Printf (printf, hPrintf)
import           Debug.Trace (trace, traceEventIO)
#else
import           Text.Printf (hPrintf)
import           Debug.Trace (traceEventIO)
#endif

import qualified Data.Text as T
import qualified Data.ByteString.Char8 as B

----------------------------------------------------------------------------------------------------

-- | A destination for log messages
data OutDest = -- NoOutput -- ^ Drop them entirely.
               OutputEvents    -- ^ Output via GHC's `traceEvent` runtime events.
             | OutputTo Handle -- ^ Printed human-readable output to a handle.
             | OutputInMemory  -- ^ Accumulate output in memory and flush when appropriate.

-- | DebugConfig: what level of debugging support is activated?
data DbgCfg = 
     DbgCfg { dbgRange :: Maybe (Int,Int) 
                -- ^ Inclusive range of debug messages to accept
                --   (i.e. filter on priority level).  If Nothing, use the default level,
                --   which is (0,N) where N is controlled by the DEBUG environment variable.
                --   The convention is to use Just (0,0) to disable logging.
            , dbgDests :: [OutDest] -- ^ Destinations for debug log messages.
            , dbgScheduling :: Bool
                -- ^ In additional to logging debug messages, control
                --   thread interleaving at these points when this is True.
           }

-- | A Logger coordinates a set of threads that print debug logging messages.
--
--   Loggers are abstract objects supporting only the operations provided by this module
--   and the non-hidden fields of the Logger data type.
data Logger = Logger { coordinator :: A.Async () -- ThreadId
                                      -- ^ (private) The thread that chooses which action to unblock next
                                      -- and handles printing to the screen as well.
                     , minLvl :: Int  -- ^ The minimum level of messages accepted by this logger (usually 0).
                     , maxLvl :: Int  -- ^ The maximum level of messages accepted by this logger.
                     , checkPoint :: SmplChan Writer -- ^ The serialized queue of writers attempting to log dbg messages.
                     , closeIt :: IO () -- ^ (public) A method to complete flushing, close down the helper thread,
                                        -- and generally wrap up.
                     , loutDests :: [OutDest] -- ^ Where to send output.  If empty, messages dropped entirely.
                     , logged   :: IORef [String] -- ^ (private) In-memory buffer of messages, if OutputInMemory is selected.
                                                  -- This is stored in reverse-temporal order during execution.
                     , flushLogs :: IO [String] -- ^ Clear buffered log messages and return in the order they occurred.
                     , waitWorkers :: WaitMode
                     }


-- | A single thread attempting to log a message.  It only unblocks when the attached
-- MVar is filled.
data Writer = Writer { who :: String
                     , continue :: MVar ()
                     , msg :: LogMsg
                       -- TODO: Indicate whether this writer has useful work to do or
                       -- is about to block... this provides a simple notion of
                       -- priority.
                     }

-- | Several different ways we know to wait for quiescence in the concurrent mutator
-- before proceeding.
data WaitMode = WaitDynamic -- ^ UNFINISHED: Dynamically track tasks/workers.  The
                            -- num workers starts at 1 and then is modified
                            -- with `incrTasks` and `decrTasks`.
              | WaitNum {
                numThreads  :: Int,   -- ^ How many threads total must check in?
                downThreads :: IO Int -- ^ Poll how many threads WON'T participate this round.
                                      --   After all *productive* threads have checked in 
                                      --   this number must grow to eventually include all other threads.
                } -- ^ A fixed set of threads must check-in each round before proceeding.
              | DontWait -- ^ In this mode, logging calls are non-blocking and return
                         -- immediately, rather than waiting on a central coordinator.
                         -- This is what we want if we're simply printing debugging output,
                         -- not controlling the schedule for stress testing.

instance Show WaitMode where
  show WaitDynamic         = "WaitDynamic"
  show WaitNum{numThreads} = "WaitNum("++show numThreads++")"
  show DontWait            = "DontWait"


-- | We allow logging in O(1) time in String format.  In practice
-- string conversions are not that important, because only *thunks*
-- should be logged; the thread printing the logs should deal with
-- forcing those thunks.
data LogMsg = StrMsg { lvl::Int, body::String }
            | OffTheRecord { lvl :: Int, obod :: String }
                -- ^ This sort of message is chatter and NOT meant 
                --   to participate in the scheduler-testing framework.
--          | ByteStrMsg { lvl::Int, bbody::ByteString }
  deriving (Show,Eq,Ord,Read)

-- | Convert just the body of the log message to a string.
msgBody :: LogMsg -> String
msgBody x = case x of 
               StrMsg {body} -> body
               OffTheRecord _ s -> s

-- | Maximum wait for the backoff mechanism.
maxWait :: Int
maxWait = 10*1000 -- 10ms
{-
andM :: [IO Bool] -> IO a -> IO a -> IO a
andM [] t _f = t
andM (hd:tl) t f = do
  b <- hd
  if b then andM tl t f
       else f
-}

catchAll :: ThreadId -> E.SomeException -> IO ()
catchAll parent exn =
  case E.fromException exn of 
    Just E.ThreadKilled -> return ()
    _ -> do
     hPutStrLn stderr ("! Exception on Logger thread: "++show exn)
     hFlush stderr
     E.throwTo parent exn
     E.throwIO exn

--------------------------------------------------------------------------------

-- | Create a new logger, which includes forking a coordinator thread.
--   Takes as argument the number of worker threads participating in the computation.
newLogger :: (Int,Int) -- ^ What inclusive range of messages do we accept?  Defaults to `(0,dbgLvl)`.
          -> [OutDest] -- ^ Where do we write debugging messages?
          -> WaitMode  -- ^ Do we wait for workers before proceeding sequentially but randomly (fuzz
                       --   testing event interleavings)?
          -> IO Logger
newLogger (minLvl, maxLvl) loutDests waitWorkers = do
  logged      <- newIORef []  
  checkPoint  <- newSmplChan
  parent      <- myThreadId
  let flushLogs = atomicModifyIORef' logged $ \ ls -> ([],reverse ls)

  shutdownFlag     <- newIORef False -- When true, time to start shutdown.
  
  -- Here's the new thread that corresponds to this logger:
  coordinator <- A.async $ E.handle (catchAll parent) $ do
                   runCoordinator waitWorkers shutdownFlag checkPoint logged loutDests
  let closeIt = do
        atomicModifyIORef' shutdownFlag (\_ -> (True,())) -- Declare that it's time to shutdown:
        A.wait coordinator -- Gently wait for it to be done.
  return $! Logger { coordinator, checkPoint, closeIt, loutDests,
                     logged, flushLogs,
                     waitWorkers, minLvl, maxLvl }

--------------------------------------------------------------------------------

-- | Run a logging coordinator thread until completion/shutdown.  This
-- coordinator manages the interleaving of events that 
runCoordinator :: WaitMode   -- ^ By which method do we wait for all workers to quiesce?
               -> IORef Bool -- ^ Set to True (by someone other than the coordinator) when the
                             --   system should shutdown.
               -> SmplChan Writer -- ^ Input queue where the coordinator recvs dbg messages 
               -> IORef [String]  -- ^ Output queue where the coordinator writes out messages
               -> [OutDest]       -- ^ Where to write log messages
               -> IO ()
runCoordinator waitWorkers shutdownFlag checkPoint logged loutDests = 
       case waitWorkers of
         DontWait -> printLoop =<< newBackoff maxWait
         _ -> schedloop (0::Int) [] =<< newBackoff maxWait -- Kick things off.
  where
          -- Proceed in rounds, gather the set of actions that may happen in parallel, then
          -- pick one.  We log the series of decisions we make for reproducability.
          schedloop :: Int 
                    -> [Writer]   -- ^ Waiting threads, reverse chronological (newest first)
                    -> Backoff -> IO ()
          schedloop !iters !waiting !bkoff = do
            hFlush stdout
            fl <- readIORef shutdownFlag
            if fl then flushLoop
             else do 
              case waitWorkers of
                DontWait -> error "newLogger: internal invariant broken."
                WaitDynamic -> error "UNFINISHED"
                WaitNum target extra -> do
                  waiting2 <- flushChan waiting
                  let numWait = length waiting2
                  n <- extra -- Atomically check how many extra workers are blocked.
                  -- putStrLn $ "TEMP: schedloop/WaitNum: polled for waiting/extra workers: "
                  --            ++show (numWait,n)++" target "++show target
                  let keepWaiting w = do
                           when (iters > 0 && iters `mod` 500 == 0) $
                             putStrLn $ "Warning: logger has spun for "++show iters++" iterations, "++
                                        show (length waiting)++" are checked-in & blocked, "++show n ++" are idling."
                           b <- backoff bkoff
                           schedloop (iters+1) w b
--                           schedloop (iters+1) w bkoff

                  if (numWait + n >= target)
                    then if numWait > 0 
                         then pickAndProceed waiting2
                         else keepWaiting waiting2 -- This sounds like a shutdown is happening, all are idle.
                    else keepWaiting waiting2 -- We don't know if we're waiting for idles to arrive or blocked waiters.

          -- | At shutdown: Keep printing messages until there is (transiently) nothing left.
          flushLoop = do 
              x <- tryReadSmplChan checkPoint
              case x of
                Just wr -> do printAll (formatMessage "" wr)
                              flushLoop -- No wakeups needed here...
                Nothing -> return ()

          -- | In the steady state: 
          flushChan !acc = do
            x <- tryReadSmplChan checkPoint
            case x of
              Just h  -> case msg h of 
                          StrMsg {}       -> flushChan (h:acc)
                          OffTheRecord {} -> do unless silenceOffTheRecord $ printAll (formatMessage "" h)
                                                putMVar (continue h) () -- Wake immediately...
                                                flushChan acc
              Nothing -> return acc

          -- | A simpler alternative schedloop that only does printing (e.g. for DontWait mode).
          printLoop bk = do
            fl <- readIORef shutdownFlag
            if fl then flushLoop
                  else do mwr <- tryReadSmplChan checkPoint
                          case mwr of 
                            Nothing -> do printLoop =<< backoff bk 
                            Just wr -> do printAll (formatMessage "" wr)
                                          printLoop =<< newBackoff (cap bk)

          -- Take the set of logically-in-parallel tasks, choose one, execute it, and
          -- then return to the main scheduler loop.
          pickAndProceed [] = error "pickAndProceed: this should only be called on a non-empty list"
          pickAndProceed waiting = do
            let order a b =
                  let s1 = msgBody (msg a)
                      s2 = msgBody (msg b) in
                  case compare s1 s2 of
                    GT -> GT
                    LT -> LT
                    EQ -> error $" [Logger] Need in-parallel log messages to have an ordering, got two equal:\n "++s1
                sorted = sortBy order waiting
                len = length waiting
            -- For now let's randomly pick an action:
            pos <- randomRIO (0,len-1)
            let pick = sorted !! pos
                (pref,suf) = splitAt pos sorted
                rst = pref ++ tail suf
            -- putStrLn$ "TEMP: pickAndProceed, unblocking "++show (pos,len,msg pick)
            unblockTask pos len pick -- The task will asynchronously run when it can.
            yield -- If running on one thread, give it a chance to run.
            -- Return to the scheduler to wait for the next quiescent point:
            bnew <- newBackoff maxWait
            schedloop 0 rst bnew

          unblockTask pos len wr@Writer{continue} = do
            printAll (messageInContext pos len wr)
            putMVar continue () -- Signal that the thread may continue.

          -- This is the format we use for debugging messages
          formatMessage extra Writer{msg} =
               let leadchar = if isOffTheRecord msg then "\\" else "|" in
               leadchar++show (lvl msg)++ "| "++extra++ msgBody msg
          -- One of these message reports how many tasks are in parallel with it:
          messageInContext pos len wr = formatMessage ("#"++show (1+pos)++" of "++show len ++": ") wr
          printOne str (OutputTo h)   = hPrintf h "%s\n" str
          printOne str OutputEvents = traceEventIO str
          printOne str OutputInMemory =
            -- This needs to be atomic because other messages might be calling "flush"
            -- at the same time.
            atomicModifyIORef' logged $ \ ls -> (str:ls,())
          printAll str = mapM_ (printOne str) loutDests

isOffTheRecord :: LogMsg -> Bool
isOffTheRecord (OffTheRecord{}) = True
isOffTheRecord _ = False

-- | [Undocumented, internal functionality] Suppress echo'ing of
-- messages that don't actually count for the schedule fuzz testing.
silenceOffTheRecord :: Bool
silenceOffTheRecord = case lookup "SILENCEOTR" theEnv of
       Nothing  -> False
       Just "0" -> False
       Just "False" -> False
       Just "false" -> False
       Just _ -> True

{-                   
chatter :: String -> IO ()
-- chatter = hPrintf stderr
-- chatter = printf "%s\n"
chatter _ = return ()

printNTrace s = do putStrLn s; traceEventIO s; hFlush stdout

-- UNFINISHED:
incrTasks = undefined
decrTasks = undefined
-}


-- | Log a string message at a given verbosity level.
logStrLn :: Logger -> Int -> String -> IO ()
logStrLn l i s = logOn l (StrMsg i s)

-- | Log a bytestring message at a given verbosity level.
logByteStringLn :: Logger -> Int -> B.ByteString -> IO ()
logByteStringLn l i b = logStrLn l i (B.unpack b)
 -- TODO: More efficient version ^^ 
    
-- | Log a Text message at a given verbosity level.
logTextLn :: Logger -> Int -> T.Text -> IO ()
logTextLn l i t = logStrLn l i (T.unpack t)
 -- TODO: More efficient version ^^ 
          
-- | Write a log message from the current thread, IF the level of the
-- message falls into the range accepted by the given `Logger`,
-- otherwise, the message is ignored.
logOn :: Logger -> LogMsg -> IO ()
logOn Logger{checkPoint,minLvl,maxLvl,waitWorkers} msg = do   
  
  if (minLvl <= lvl msg) && (lvl msg <= maxLvl) then do     
    -- putStrLn$ "TEMP: "++show (minLvl,maxLvl)++" attempt to log msg: "++show msg
    case waitWorkers of
      -- In this mode we are non-blocking:
      DontWait -> writeSmplChan checkPoint Writer{who="",continue=dummyMVar,msg}
      _ -> do continue <- newEmptyMVar
              writeSmplChan checkPoint Writer{who="",continue,msg}
              takeMVar continue -- Block until we're given permission to proceed.
   else return ()

{-# NOINLINE dummyMVar #-}
dummyMVar :: MVar ()
dummyMVar = unsafePerformIO newEmptyMVar

----------------------------------------------------------------------------------------------------
-- Simple back-off strategy.

-- | The state for an exponential backoff.
data Backoff = Backoff { current :: !Int
                       , cap :: !Int  -- ^ Maximum nanoseconds to wait.
                       , totalWait :: !Int
                       }
  deriving Show

-- | Create an object used for exponentential backoff; see `backoff`.
newBackoff :: Int -- ^ Maximum delay, nanoseconds
           -> IO Backoff
newBackoff cap = return Backoff{cap,current=0,totalWait=0}

-- | Perform the backoff, possibly delaying the thread.
backoff :: Backoff -> IO Backoff
backoff Backoff{current,cap,totalWait} = do
  if current < 1 then 
    -- Yield before we start delaying:
    do yield
       return Backoff{cap,current=current+1,totalWait}
   else
    do let nxt = min cap (2*current)
       threadDelay current
       return Backoff{cap,current=nxt,totalWait=totalWait+current}

----------------------------------------------------------------------------------------------------
-- Simple channels: we need non-blocking reads so we can't use
-- Control.Concurrent.Chan.  We could use TChan, but I don't want to bring STM into
-- it right now.

-- type MyChan a = Chan a

-- -- | A simple channel.  Take-before-put is the protocol.
-- type SmplChan a = MVar [a]

-- | Simple channels that don't support real blocking.
type SmplChan a = IORef (Seq.Seq a) -- New elements pushed on right.

newSmplChan :: IO (SmplChan a)
newSmplChan = newIORef Seq.empty

-- | Non-blocking read.
tryReadSmplChan :: SmplChan a -> IO (Maybe a)
tryReadSmplChan ch = do
  x <- atomicModifyIORef' ch $ \ sq -> 
       case Seq.viewl sq of
         Seq.EmptyL -> (Seq.empty, Nothing)
         h Seq.:< t -> (t, Just h)
  return x
{-
-- | A synchronous read that must block or busy-wait until a value is available.
readSmplChan :: SmplChan a -> IO a
readSmplChan ch = loop =<< newBackoff maxWait
 where
   loop bk = do
     x <- tryReadSmplChan ch
     case x of
       Nothing -> do b2 <- backoff bk
                     loop b2
       Just h  -> return h
-}
-- | Always succeeds.  Asynchronous write to channel.
writeSmplChan :: SmplChan a -> a -> IO ()
writeSmplChan ch x = do
  atomicModifyIORef' ch $ \ s -> (s Seq.|> x,())

----------------------------------------------------------------------------------------------------

{-# NOINLINE theEnv #-}
theEnv :: [(String, String)]
theEnv = unsafePerformIO getEnvironment

-- | Debugging flag shared by several modules.
--   This is activated by setting the environment variable @DEBUG=1..5@.
-- 
--   By convention @DEBUG=100@ turns on full sequentialization of the program and
--   control over the interleavings in concurrent code, enabling systematic debugging
--   of concurrency problems.
dbgLvl :: Int
#ifdef DEBUG_LOGGER
{-# NOINLINE dbgLvl #-}
dbgLvl = case lookup "DEBUG" theEnv of
       Nothing  -> defaultDbg
       Just ""  -> defaultDbg
       Just "0" -> defaultDbg
       Just s   ->
         case reads s of
           ((n,_):_) -> trace (" [!] Responding to env var: DEBUG="++show n) n
           [] -> error$"Attempt to parse DEBUG env var as Int failed: "++show s
#else 
{-# INLINE dbgLvl #-}
dbgLvl = 0
#endif

-- | This codifies the convention of keeping fine-grained
-- per-memory-modification messages at higher debug levels.  These are
-- used for fuzz testing concurrent interleavings.  Setting `dbgRange`
-- in the `DbgCfg` to this value should give you only the messages
-- necessary for stress testing schedules.
defaultMemDbgRange :: (Int, Int)
-- defaultMemDbgRange = (4,10)
defaultMemDbgRange = (0,10)
#ifdef DEBUG_LOGGER
defaultDbg :: Int
defaultDbg = 0
{-
replayDbg :: Int
replayDbg = 100
-}
#endif


{-
Authors: Makarius Wenzel (2021)

Naproche program context: Console or PIDE.
-}

module Naproche.Program (
  Error (..), print_error,
  Context (..), is_pide,
  write_message, read_message, exchange_message, exchange_message0,
  adjust_position, exit_thread, init_console, init_pide, thread_context,
  error,
  serials, serial
)
where

import Prelude hiding (error)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.IORef (IORef)
import qualified Data.IORef as IORef
import System.IO.Unsafe (unsafePerformIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as Char8
import Control.Concurrent (ThreadId)
import Control.Monad (when, replicateM)
import qualified Control.Concurrent as Concurrent
import qualified Control.Exception as Exception
import Control.Exception (Exception)

import Network.Socket (Socket)
import qualified Isabelle.Bytes as Bytes
import Isabelle.Bytes (Bytes)
import qualified Isabelle.Byte_Message as Byte_Message
import qualified Isabelle.Value as Value
import qualified Isabelle.Position as Position
import qualified Isabelle.Options as Options
import qualified Isabelle.Naproche as Naproche
import Isabelle.Library


{- program context -}

data Context = Console | PIDE Socket Options.T

instance Show Context where
  show Console = "Console"
  show (PIDE _ _) = "PIDE"

is_pide :: Context -> Bool
is_pide Console = False
is_pide (PIDE _ _) = True

write_message :: Context -> [Bytes] -> IO ()
write_message Console = Char8.putStrLn . Bytes.unmake . Bytes.concat
write_message (PIDE socket _) = Byte_Message.write_message socket

read_message :: Context -> IO (Maybe [Bytes])
read_message Console = return Nothing
read_message (PIDE socket _) = Byte_Message.read_message socket

exchange_message :: Context -> [Bytes] -> IO [Bytes]
exchange_message context msg = do
  write_message context msg
  res <- read_message context
  return $ fromMaybe [] res

exchange_message0 :: Context -> [Bytes] -> IO ()
exchange_message0 context msg = do
  write_message context msg
  _ <- read_message context
  return ()

adjust_position :: Context -> Position.T -> Position.T
adjust_position Console pos = pos
adjust_position (PIDE _ options) pos =
  let
    pos_id = Options.string options Naproche.naproche_pos_id
    pos_file = Options.string options Naproche.naproche_pos_file
    pos_shift = Options.int options Naproche.naproche_pos_shift
  in
    pos
    |> Position.put_file (fromMaybe pos_file (Position.file_of pos))
    |> Position.put_id pos_id
    |> Position.shift_offsets pos_shift


{- program threads -}

type Threads = Map ThreadId Context

{-# NOINLINE global_threads #-}
global_threads :: IORef Threads
global_threads = unsafePerformIO (IORef.newIORef Map.empty)

update_threads :: (ThreadId -> Threads -> Threads) -> IO ()
update_threads f = do
  id <- Concurrent.myThreadId
  IORef.atomicModifyIORef' global_threads (\threads -> (f id threads, ()))

exit_thread :: IO ()
exit_thread = update_threads Map.delete
    
init_thread :: Context -> IO Context
init_thread context = do
  update_threads (`Map.insert` context)
  return context
  
init_console :: IO Context
init_console = init_thread Console

init_pide :: Socket -> Options.T -> IO Context
init_pide socket options = init_thread (PIDE socket options)

thread_context :: IO Context
thread_context = do
  id <- Concurrent.myThreadId
  threads <- IORef.readIORef global_threads
  return $ fromMaybe Console (Map.lookup id threads)


{- errors -}

newtype Error = Error Bytes
instance Exception Error

print_error :: Error -> Bytes
print_error (Error msg) = msg

instance Show Error where show = make_string . print_error

error :: Bytes -> IO a
error msg = do
  context <- thread_context
  if is_pide context then Exception.throw $ Error msg
  else errorWithoutStackTrace $ make_string msg


{- serial numbers, preferable from Isabelle/ML -}

{-# NOINLINE global_counter #-}
global_counter :: IORef Int
global_counter = unsafePerformIO (IORef.newIORef 0)

next_counter :: IO Int
next_counter = do
  IORef.atomicModifyIORef' global_counter
    (\i ->
      if i < maxBound then (i + 1, i + 1)
      else errorWithoutStackTrace "Overflow of global counter")

serials :: Context -> Int -> IO [Int]
serials context n =
  if is_pide context then
    do
      result <- exchange_message context [Naproche.serials_command, Value.print_int n]
      let res = mapMaybe Value.parse_int result
      let m = length res
      when (m /= n) $
        errorWithoutStackTrace
          ("Bad result of command \"serials\": returned " <> show m <> ", expected " <> show n)
      return res
  else replicateM n next_counter

serial :: Context -> IO Int
serial context = do
  res <- serials context 1
  return $ head res
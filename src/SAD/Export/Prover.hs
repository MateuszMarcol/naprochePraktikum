{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018), Makarius Wenzel (2018)

Prover interface: export a proof task to an external prover.
-}

module SAD.Export.Prover where

import Control.Monad (when, unless)
import Data.Maybe
import Data.List
import System.IO
import System.IO.Error
import qualified System.Process as Process
import qualified Control.Exception as Exception

import qualified Isabelle.File as File
import qualified Isabelle.Standard_Thread as Standard_Thread

import SAD.Core.SourcePos
import SAD.Data.Instr hiding (Prover)
import SAD.Data.Text.Context (Context)
import SAD.Export.Base
import SAD.Helpers (notNull)

import qualified SAD.Core.Message as Message
import qualified SAD.Data.Instr as Instr
import qualified SAD.Export.DFG as DFG
import qualified SAD.Export.TPTP as TPTP

export :: Bool -> Int -> [Prover] -> [Instr] -> [Context] -> Context -> IO Bool
export reduced depth provers instrs context goal = do
  Standard_Thread.expose_stopped

  when (null provers) $ Message.errorExport noSourcePos "No provers"

  let proverName = askArgument Instr.Prover (name $ head provers) instrs
      proversNamed = filter ((==) proverName . name) provers

  when (null proversNamed) $ Message.errorExport noSourcePos $ "No prover named " ++ show proverName

  let prover@(Prover _ label path args fmt yes nos uns) = head proversNamed
      timeLimit = askLimit Timelimit 3 instrs
      proc =
        (Process.proc path (map (setTimeLimit timeLimit) args))
          {Process.std_in = Process.CreatePipe,
           Process.std_out = Process.CreatePipe,
           Process.std_err = Process.CreatePipe,
           Process.create_group = True,
           Process.new_session = True}
      process = do
        (pin, pout, perr, p) <- Process.createProcess proc
        return (fromJust pin, fromJust pout, fromJust perr, p)

  let output = case fmt of TPTP -> TPTP.output; DFG -> DFG.output
      task = output reduced prover timeLimit context goal

  when (askFlag Dump False instrs) $ Message.output "" Message.WRITELN noSourcePos task

  (prvin, prvout, prverr, prv) <-
    Exception.catch process
      (\e -> Message.errorExport noSourcePos $
        "Failed to run " ++ show path ++ ": " ++ ioeGetErrorString e)

  File.setup prvin
  File.setup prvout
  File.setup prverr

  hPutStrLn prvin task
  hClose prvin

  let
    terminate =
      do
        Process.interruptProcessGroupOf prv
        Process.waitForProcess prv
        return ()

  Standard_Thread.bracket_resource terminate $ do
    output <- hGetContents prvout
    errors <- hGetContents prverr
    let lns = filter notNull $ lines $ output ++ errors
        out = map (("[" ++ label ++ "] ") ++) lns

    when (null lns) $ Message.errorExport noSourcePos "No prover response"
    when (askFlag Printprover False instrs) $
        mapM_ (Message.output "" Message.WRITELN noSourcePos) out

    let positive = any (\l -> any (`isPrefixOf` l) yes) lns
        negative = any (\l -> any (`isPrefixOf` l) nos) lns
        inconclusive = any (\l -> any (`isPrefixOf` l) uns) lns

    unless (positive || negative || inconclusive) $
        Message.errorExport noSourcePos $ unlines ("Bad prover response:" : lns)

    hClose prverr
    Process.waitForProcess prv

    return positive


setTimeLimit :: Int -> String -> String
setTimeLimit timeLimit ('%':'d':rs) = show timeLimit ++ rs
setTimeLimit timeLimit (s:rs) = s : setTimeLimit timeLimit rs
setTimeLimit _ _ = []

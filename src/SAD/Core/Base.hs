{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Verifier state monad and common functions.
-}

{-# LANGUAGE PolymorphicComponents #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}


module SAD.Core.Base
  ( RState(..), CRM
  , askRS
  , updateRS
  , justIO
  , reportBracketIO
  , (<|>)
  , runRM

  , retrieveContext
  , makeInitialVState
  , defForm
  , getDef

  , setFailed
  , ifAskFailed
  , unsetChecked
  , setChecked

  , VState(..), VM

  , Tracker(..), Timer(..), Counter(..)
  , sumCounter
  , sumTimer
  , maximalTimer
  , showTimeDiff
  , timeWith

  , askInstructionInt, askInstructionBool, askInstructionText
  , addInstruction, dropInstruction
  , addToTimer, addToCounter, incrementCounter
  , guardInstruction, guardNotInstruction, whenInstruction

  , reasonLog, simpLog, thesisLog, translateLog
  ) where

import Control.Applicative (Alternative(..))
import Control.Monad.Reader
import Control.Monad.State
import Control.Exception (SomeException, try, throw)
import Data.IORef
import Data.Maybe (isJust, fromJust)
import Data.Text.Lazy (Text)
import Data.Time (NominalDiffTime, getCurrentTime, diffUTCTime)

import qualified Data.Set as Set
import qualified Data.Map as Map

import SAD.Data.Definition
import SAD.Data.Formula
import SAD.Data.Instr
import SAD.Data.Rules (Rule)
import SAD.Data.Text.Block (Block, ProofText)
import SAD.Data.Text.Context (Context(Context), MRule(..))

import qualified SAD.Core.Message as Message
import qualified SAD.Data.Structures.DisTree as DT
import qualified SAD.Data.Text.Context as Context (name)

import qualified Isabelle.Bytes as Bytes
import qualified Isabelle.Markup as Markup
import qualified Isabelle.Position as Position
import Isabelle.Library (BYTES, make_bytes)



-- | Reasoner state
data RState = RState
  { trackers       :: [Tracker]
  , failed         :: Bool
  , alreadyChecked :: Bool
  } deriving (Eq, Ord, Show)


-- | All of these counters are for gathering statistics to print out later
data Tracker
  = Timer Timer NominalDiffTime
  | Counter Counter Int
  deriving (Eq, Ord, Show)

data Timer
  = ProofTimer
  | SuccessTimer  -- successful prove time
  | SimplifyTimer
  deriving (Eq, Ord, Show)

data Counter
-- TODO append 'Counter' to each of these?
  = Sections
  | Goals
  | FailedGoals
  | TrivialGoals
  | SuccessfulGoals
  | Symbols
  | TrivialChecks
  | HardChecks
  | SuccessfulChecks
  | Unfolds
  | Equations
  | FailedEquations
  deriving (Eq, Ord, Show)


-- | CPS IO Maybe monad
newtype CRM b = CRM
  { runCRM :: forall a . IORef RState -> IO a -> (b -> IO a) -> IO a }

instance Functor CRM where
  fmap = liftM

instance Applicative CRM where
  pure = return
  (<*>) = ap

instance Monad CRM where
  return r  = CRM $ \ _ _ k -> k r
  m >>= n   = CRM $ \ s z k -> runCRM m s z (\ r -> runCRM (n r) s z k)

instance Alternative CRM where
  empty = mzero
  (<|>) = mplus

instance MonadPlus CRM where
  mzero     = CRM $ \ _ z _ -> z
  mplus m n = CRM $ \ s z k -> runCRM m s (runCRM n s z k) k


-- | @runCRM@ with defaults.
runRM :: CRM a -> IORef RState -> IO (Maybe a)
runRM m s = runCRM m s (return Nothing) (return . Just)

data VState = VS
  { thesisMotivated :: Bool
  , rewriteRules    :: [Rule]
  , evaluations     :: DT.DisTree Evaluation -- (low level) evaluation rules
  , currentThesis   :: Context
  , currentBranch   :: [Block] -- branch of the current block
  , currentContext  :: [Context]
  , mesonRules      :: (DT.DisTree MRule, DT.DisTree MRule)
  , definitions     :: Definitions
  , guards          :: Guards -- tracks which atomic formulas appear as guard
  , skolemCounter   :: Int
  , instructions    :: [Instr]
  , restProofText   :: [ProofText]
  }

makeInitialVState :: [ProofText] -> VState
makeInitialVState text = VS
  { thesisMotivated = False
  , rewriteRules    = []
  , evaluations     = DT.empty
  , currentThesis   = Context Bot [] []
  , currentBranch   = []
  , currentContext  = []
  , mesonRules      = (DT.empty, DT.empty)
  , definitions     = initialDefinitions
  , guards          = initialGuards
  , skolemCounter   = 0
  , instructions    = []
  , restProofText   = text
  }

type VM = ReaderT VState CRM

justRS :: VM (IORef RState)
justRS = lift $ CRM $ \ s _ k -> k s

justIO :: IO a -> VM a
justIO m = lift $ CRM $ \ _ _ k -> m >>= k


-- State management from inside the verification monad

askRS :: (RState -> a) -> VM a
askRS f = justRS >>= (justIO . fmap f . readIORef)

updateRS :: (RState -> RState) -> VM ()
updateRS f = justRS >>= (justIO . flip modifyIORef f)

askInstructionInt :: Limit -> Int -> VM Int
askInstructionInt instr _default =
  fmap (askLimit instr _default) $ asks instructions

askInstructionBool :: Flag -> Bool -> VM Bool
askInstructionBool instr _default =
  fmap (askFlag instr _default) $ asks instructions

askInstructionText :: Argument -> Text -> VM Text
askInstructionText instr _default =
  fmap (askArgument instr _default) $ asks instructions

addInstruction :: Instr -> VM a -> VM a
addInstruction instr =
  local $ \vs -> vs { instructions = instr : instructions vs }

dropInstruction :: Drop -> VM a -> VM a
dropInstruction instr =
  local $ \vs -> vs { instructions = dropInstr instr $ instructions vs }


-- Markup reports (with exception handling)

reportBracketIO :: Position.T -> IO a -> IO a
reportBracketIO pos body = do
  Message.report pos Markup.running
  (res :: Either SomeException a) <- try body
  case res of
    Left e -> do
      Message.report pos Markup.failed
      Message.report pos Markup.finished
      throw e
    Right x -> do
      Message.report pos Markup.finished
      return x


-- Trackers

addToTimer :: Timer -> NominalDiffTime -> VM ()
addToTimer timer time =
  updateRS $ \rs -> rs{trackers = Timer timer time : trackers rs}

addToCounter :: Counter -> Int -> VM ()
addToCounter counter increment =
  updateRS $ \rs -> rs{trackers = Counter counter increment : trackers rs}

incrementCounter :: Counter -> VM ()
incrementCounter counter = addToCounter counter 1

-- Time proof tasks.
timeWith :: Timer -> VM a -> VM a
timeWith timer task = do
  begin  <- justIO getCurrentTime
  result <- task
  end    <- justIO getCurrentTime
  addToTimer timer (diffUTCTime end begin)
  return result

projectCounter :: [Tracker] -> Counter -> [Int]
projectCounter trackers counter =
  [ value | Counter counter' value <- trackers, counter == counter' ]

projectTimer :: [Tracker] -> Timer -> [NominalDiffTime]
projectTimer trackers timer =
  [ time | Timer timer' time <- trackers, timer == timer' ]


sumCounter :: [Tracker] -> Counter -> Int
sumCounter trackers counter = sum (projectCounter trackers counter)

sumTimer :: [Tracker] -> Timer -> NominalDiffTime
sumTimer trackers timer = sum (projectTimer trackers timer)

maximalTimer :: [Tracker] -> Timer -> NominalDiffTime
maximalTimer trackers timer = foldr max 0 (projectTimer trackers timer)

showTimeDiff :: NominalDiffTime -> String
showTimeDiff t =
  if hours == 0
    then format minutes <> ":" <> format restSeconds <> "." <> format restCentis
    else format hours   <> ":" <> format restMinutes <> ":" <> format restSeconds
  where
    format n = if n < 10 then '0':show n else show n
    centiseconds = (truncate $ t * 100) :: Int
    (seconds, restCentis)  = divMod centiseconds 100
    (minutes, restSeconds) = divMod seconds 60
    (hours,   restMinutes) = divMod minutes 60


guardInstruction :: Flag -> Bool -> VM ()
guardInstruction instr _default =
  askInstructionBool instr _default >>= guard

guardNotInstruction :: Flag -> Bool -> VM ()
guardNotInstruction instr _default =
  askInstructionBool instr _default >>= guard . not

whenInstruction :: Flag -> Bool -> VM () -> VM ()
whenInstruction instr _default action =
  askInstructionBool instr _default >>= \b -> when b action

-- explicit failure management

setFailed :: VM ()
setFailed = updateRS (\st -> st {failed = True})

ifAskFailed :: VM a -> VM a -> VM a
ifAskFailed alt1 alt2 = do
  failed <- askRS failed
  if failed then alt1 else alt2

-- local checking support

setChecked, unsetChecked :: VM ()
setChecked = updateRS (\st -> st {alreadyChecked = True})
unsetChecked = updateRS (\st -> st {alreadyChecked = False})


-- common messages

reasonLog :: BYTES a => Message.Kind -> Position.T -> a -> VM ()
reasonLog kind pos = justIO . Message.outputReasoner kind pos

thesisLog :: BYTES a => Message.Kind -> Position.T -> Int -> a -> VM ()
thesisLog kind pos indent msg =
  justIO (Message.outputThesis kind pos (Bytes.spaces (3 * indent) <> make_bytes msg))

simpLog :: BYTES a => Message.Kind -> Position.T -> a -> VM ()
simpLog kind pos = justIO . Message.outputSimplifier kind pos

translateLog :: BYTES a => Message.Kind -> Position.T -> a -> VM ()
translateLog kind pos = justIO . Message.outputTranslate kind pos



retrieveContext :: Position.T -> Set.Set Text -> VM [Context]
retrieveContext pos names = do
  globalContext <- asks currentContext
  let (context, unfoundSections) = runState (retrieve globalContext) names

  unless (Set.null unfoundSections) $
    reasonLog Message.WARNING pos $
      "Could not find sections " <> unwords (map show $ Set.elems unfoundSections)
  return context
  where
    retrieve [] = return []
    retrieve (context:restContext) =
      let name = Context.name context in
        gets (Set.member name) >>= \p ->
          if p
          then modify (Set.delete name) >> fmap (context:) (retrieve restContext)
          else retrieve restContext




-- Definition management

-- initial definitions
initialDefinitions :: Definitions
initialDefinitions = Map.fromList [
  (EqualityId,  equality),
  (LessId,  less),
  (SmallId, isSmall),
  (FunId,  function),
  (AppId,  functionApplication),
  (DomId,  domain),
  (SetId,  set),
  (ClassId,  clss),
  (ElemId,  elementOf),
  (PairId, pair) ]

hole0, hole1 :: VariableName
hole0 = VarHole "0"
hole1 = VarHole "1"

equality :: DefEntry
equality  = DE [] Top Signature (mkEquality (mkVar hole0) (mkVar hole1)) [] []

less :: DefEntry
less = DE [] Top Signature (mkLess (mkVar hole0) (mkVar hole1)) [] []

isSmall :: DefEntry
isSmall = DE [] Top Signature (mkSmall (mkVar hole0)) [] []

set :: DefEntry
set = DE [] Top Signature (mkSet $ mkVar hole0) [] []

clss :: DefEntry
clss = DE [] Top Signature (mkClass $ mkVar hole0) [] []

elementOf :: DefEntry
elementOf = DE [mkClass (mkVar hole1) `Or` mkSet (mkVar hole1)] Top Signature
  (mkElem (mkVar hole0) (mkVar hole1)) [] [[mkClass (mkVar hole1) `Or` mkSet (mkVar hole1)]]

function :: DefEntry
function  = DE [] Top Signature (mkFun $ mkVar hole0) [] []

domain :: DefEntry
domain = DE [mkFun $ mkVar hole0] (mkSet ThisT) Signature
  (mkDom $ mkVar hole0) [mkSet ThisT] [[mkFun $ mkVar hole0]]

pair :: DefEntry
pair = DE [] Top Signature (mkPair (mkVar hole0) (mkVar hole1)) [] []

functionApplication :: DefEntry
functionApplication =
  DE [mkFun $ mkVar hole0, mkElem (mkVar $ hole1) $ mkDom $ mkVar hole0] Top Signature
    (mkApp (mkVar hole0) (mkVar hole1)) []
    [[mkFun $ mkVar hole0],[mkElem (mkVar $ hole1) $ mkDom $ mkVar hole0]]


initialGuards :: DT.DisTree Bool
initialGuards = foldr (\f -> DT.insert f True) (DT.empty) [
  mkSet $ mkVar hole1,
  mkFun $ mkVar hole0,
  mkElem (mkVar $ hole1) $ mkDom $ mkVar hole0]

-- retrieve definitional formula of a term
defForm :: Definitions -> Formula -> Maybe Formula
defForm definitions term = do
  def <- Map.lookup (trmId term) definitions
  guard $ isDefinition def
  sb <- match (defTerm def) term
  return $ sb $ defFormula def


-- retrieve definition of a symbol (monadic)
getDef :: Formula -> VM DefEntry
getDef term = do
  defs <- asks definitions
  let mbDef = Map.lookup (trmId term) defs
  guard $ isJust mbDef
  return $ fromJust mbDef

{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Well-definedness check and evidence collection.
-}

{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
{-# LANGUAGE OverloadedStrings #-}

module SAD.Core.Check (fillDef) where

import Control.Monad
import Data.Maybe
import Data.Either (lefts,rights, isRight)
import Control.Monad.Reader

import SAD.Data.Formula
import SAD.Data.Instr
import SAD.Data.Text.Context (Context)
import qualified SAD.Data.Text.Context as Context
import qualified SAD.Data.Text.Block as Block (link, position)
import SAD.Data.Definition hiding (Guards)
import SAD.Core.Base
import qualified SAD.Core.Message as Message
import SAD.Core.Reason

import qualified Data.Text.Lazy as Text

{- check definitions and fortify terms with evidences in a formula -}
fillDef :: Bool -> Context -> VM Formula
fillDef alreadyChecked context = fill True False [] (Just True) 0 $ Context.formula context
  where
    fill isPredicat isNewWord localContext sign n (Tag tag f)
      | tag == HeadTerm = -- newly introduced symbol
          fmap (Tag HeadTerm) $ fill isPredicat True localContext sign n f
      | otherwise  =  -- ignore every other tag
          fmap (Tag tag) $ fill isPredicat isNewWord localContext sign n f
    fill _ _ _ _ _ Trm {trmName = TermThesis} = thesis >>= return . Context.formula
    fill _ _ localContext _ _ v | isVar v = do
      userInfoSetting <- askInstructionBool Info True
      newContext      <- cnRaise context localContext
      collectInfo userInfoSetting v `withContext` newContext -- fortify the term
    fill isPredicat isNewWord localContext sign n
         term@Trm {trmName = t, trmArgs = tArgs, trmInfo = infos, trmId = tId} =
      if alreadyChecked then return term else do
            userInfoSetting <- askInstructionBool Info True
            fortifiedArgs   <- mapM (fill False isNewWord localContext sign n) tArgs
            newContext      <- cnRaise context localContext
            fortifiedTerm   <- setDef isNewWord context term {trmArgs = fortifiedArgs}
              `withContext` newContext
            collectInfo (not isPredicat && userInfoSetting) fortifiedTerm
              `withContext` newContext        -- fortify term
    fill isPredicat isNewWord localContext sign n f = -- round throuth formula
      roundFM VarW (fill isPredicat isNewWord) localContext sign n f

    collectInfo infoSetting term
      | infoSetting = setInfo term
      | True        = return  term

cnRaise :: Context -> [Formula] -> VM [Context]
cnRaise thisBlock local = asks currentContext >>=
  return . flip (foldr $ (:) . Context.setForm thisBlock) local




setDef :: Bool -> Context -> Formula -> VM Formula
setDef isNewWord context term@Trm{trmName = t, trmId = tId} =
  incrementIntCounter Symbols >>
    (    (guard isNewWord >> return term) -- do not check new word
    <|>  (findDef term >>= testDef context term) -- check term's definition
    <|>  (out >> mzero )) -- failure message
  where
    out =
      reasonLog Message.ERROR (Block.position (Context.head context)) $
        "unrecognized: " <> (Text.pack $ showsPrec 2 term "")


-- Find relevant definitions and test them
type Guards = [Formula]
type FortifiedTerm = Formula
type DefDuo = (Guards, FortifiedTerm)


findDef :: Formula -> VM DefDuo
findDef term@Trm{trmArgs = tArgs} = do
  def <- getDef term
  sb  <- match (defTerm def) term
  let guards   = map (infoSub sb) $ defGuards def -- definition's guards
      evidence = map sb $ defEvidence def -- definitional evidence
      newTerm  = term { trmInfo = evidence } -- fortified term
  return (guards, newTerm)

{-
testDef does what the name suggests and tests a definition. if the use has
disabled ontological checking we just assume that the definition fits, else we
check it. setup and cleanup take care of the special proof times that we allow
an ontological check. easyCheck are inbuild reasoning methods, hardCheck passes
a task to an ATP.
-}
testDef :: Context -> Formula -> DefDuo -> VM Formula
testDef context term (guards, fortifiedTerm) = do
  userCheckSetting <- askInstructionBool Check True
  if   userCheckSetting
  then setup $ easyCheck >>= hardCheck >> return fortifiedTerm
  else return fortifiedTerm
  where
    easyCheck = mapM trivialityCheck guards
    hardCheck hardGuards
      | all isRight hardGuards =
          incrementIntCounter TrivialChecks >>
          defLog ("trivial " <> header rights hardGuards)
      | otherwise =
          incrementIntCounter HardChecks >>
          defLog (header lefts hardGuards <> thead (rights hardGuards)) >>
          mapM_ (reason . Context.setForm (wipeLink context)) (lefts hardGuards) >>
          incrementIntCounter SuccessfulChecks

    setup :: VM a -> VM a
    setup action = do
      timelimit <- LimitBy Timelimit <$> askInstructionInt Checktime 1
      depthlimit <- LimitBy Depthlimit <$> askInstructionInt Checkdepth 3
      addInstruction timelimit $ addInstruction depthlimit action

    wipeLink context =
      let block:restBranch = Context.branch context
      in  context {Context.branch = block {Block.link = []} : restBranch}


    header select guards =
      "check: " <> (Text.pack $ showsPrec 2 term " vs ") <> format (select guards)
    thead [] = ""; thead guards = "(trivial: " <> format guards <> ")"
    format guards = if null guards then " - " else Text.unwords . map (Text.pack . show) $ guards
    defLog =
      whenInstruction Printcheck False .
        reasonLog Message.WRITELN (Block.position (head $ Context.branch context))



    trivialityCheck g =
      if   trivialByEvidence g
      then return $ Right g  -- triviality check
      else (launchReasoning `withGoal` g >> return (Right g)) <|> return (Left g)


-- Info heuristic

{- moves through the low level context and collects typings of a given term. In
   case of equality we also add the typings of the equated term -}
typings :: (MonadPlus m) => [Context] -> Formula -> m [Formula]
typings [] _ = mzero
typings (context:restContext) term =
  albetDive (Context.formula context) `mplus` typings restContext term
  where
    albetDive = dive . albet
    -- when we encouter a literal, compare its arguments with term
    dive f | isLiteral f = compare [] $ trmArgs $ ltAtomic f
      where
        compare _ [] = mzero
        compare ls (arg:rs) = -- try to match argument, else compare with rest
          matchThisArgument ls arg rs `mplus` compare (arg:ls) rs

        matchThisArgument ls arg rs =
          let sign = mbNot f; predicate = ltAtomic f in do
            match term arg
            let newInfo = sign predicate {trmArgs = reverse ls ++ (ThisT : rs)}
            return $ newInfo : notionEvidence ls predicate ++ trInfo arg

    dive e@Trm {trmName = TermEquality, trmArgs = [l,r]} =
      if   twins l term
      then return $ joinEvidences (trInfo l) (trInfo r)
      else if   twins r term
           then return $ joinEvidences (trInfo r) (trInfo l)
           else mzero
    dive (And f g) = albetDive g `mplus` albetDive f
    dive (Tag _ f) = albetDive f
    dive _         = mzero

    joinEvidences ls rs =
      filter (\l -> all (not . infoTwins term l) rs) ls ++ rs

    notionEvidence [] prd | isNotion prd = trInfo prd
    notionEvidence _ _ = []



setInfo :: Formula -> VM Formula
setInfo t = do
  context <- asks currentContext
  let lowlevelContext  = takeWhile Context.isLowLevel context
      lowlevelEvidence = fromMaybe [] $ typings lowlevelContext t
  case t of
    t@Trm {} -> pure $ t {trmInfo = trmInfo t ++ lowlevelEvidence}
    v@Var {} -> pure $ v {varInfo = varInfo v ++ lowlevelEvidence}

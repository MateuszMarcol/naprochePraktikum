{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018), Makarius Wenzel (2021 - 2022)

Main verification loop.
-}

module SAD.Core.Verify (verifyRoot) where

import Data.IORef (IORef, readIORef)
import Data.Maybe (isJust)
import Control.Monad.Reader

import qualified Data.Text.Lazy as Text

import SAD.Core.Base
import SAD.Core.Check (fillDef)
import SAD.Core.Extract (addDefinition, addEvaluation, extractRewriteRule)
import SAD.Core.ProofTask (generateProofTask)
import SAD.Core.Reason (proveThesis)
import SAD.Core.Rewrite (equalityReasoning)
import SAD.Core.Thesis (inferNewThesis)
import SAD.Data.Formula
import SAD.Data.Instr
import SAD.Data.Text.Block (Block(Block), ProofText(..), Section(..))
import SAD.Data.Text.Context (Context(Context))
import SAD.Helpers (notNull)

import qualified SAD.Core.Message as Message
import qualified SAD.Data.Tag as Tag
import qualified SAD.Data.Text.Block as Block
import qualified SAD.Data.Text.Context as Context
import qualified SAD.Prove.MESON as MESON

import Isabelle.Library (trim_line, make_bytes)
import qualified Isabelle.Position as Position


-- | verify proof text (document root)
verifyRoot :: Position.T -> IORef RState -> [ProofText] -> IO (Bool, Maybe [ProofText])
verifyRoot filePos reasonerState text = do
  Message.outputReasoner Message.TRACING filePos "verification started"

  result <- runVerifyMonad reasonerState initVState (verify text)

  trackers <- trackers <$> readIORef reasonerState
  let ignoredFails = sumCounter trackers FailedGoals

  let success = isJust result && ignoredFails == 0
  Message.outputReasoner Message.TRACING filePos $
    "verification " <> (if success then "successful" else "failed")
  return (success, fmap (tail . snd) result)

-- Main verification loop, based on mutual functions:
-- verify, verifyBlock, verifyProof

pushProofText :: ProofText -> ([ProofText], [ProofText]) -> ([ProofText], [ProofText])
pushProofText p (as, bs) = (as, p : bs)

verify :: [ProofText] -> VerifyMonad ([ProofText], [ProofText])
verify [] = do
  motivated <- asks thesisMotivated
  prove <- asks (getInstruction proveParam)
  when (motivated && prove) verifyThesis >> return ([], [])
verify (ProofTextBlock block : rest) = verifyBlock block rest
verify (ProofTextChecked txt : rest) = do
  instructions <- asks instructions
  let newInstructions = [NonProofTextStoredInstr (SetBool proveParam False : Verbose False : instructions)]
  let newTxt = Block.setChildren txt (Block.children txt ++ newInstructions)
  setChecked True
  verify (newTxt : rest)
verify (NonProofTextStoredInstr ins : rest) =
  local (\state -> state {instructions = ins}) (verify rest)
verify (p@(ProofTextInstr pos (Command cmd)) : rest) =
  pushProofText p <$> (command cmd >> verify rest)
  where
    command :: Command -> VerifyMonad ()
    command PrintRules = do
      rules <- asks rewriteRules
      message $ "current ruleset: " <> "\n" <> unlines (map show (reverse rules))
    command PrintThesis = do
      motivated <- asks thesisMotivated
      thesis <- asks currentThesis
      let motivation = if motivated then "(motivated): " else "(not motivated): "
      message $ "current thesis " <> motivation <> show (Context.formula thesis)
    command PrintContext = do
      context <- asks currentContext
      message $ "current context:\n" <>
        concatMap (\form -> "  " <> show (Context.formula form) <> "\n") (reverse context)
    command PrintContextFiltered = do
      context <- asks currentContext
      let topLevelContext = filter Context.isTopLevel context
      message $ "current filtered top-level context:\n" <>
        concatMap (\form -> "  " <> show (Context.formula form) <> "\n") (reverse topLevelContext)
    command _ = do
      message "unsupported instruction"
    message :: String -> VerifyMonad ()
    message msg = reasonLog Message.WRITELN (Position.no_range_position pos) msg
verify (p@(ProofTextInstr _ instr) : rest) = pushProofText p <$> addInstruction instr (verify rest)
verify (p@(ProofTextDrop _ instr) : rest) = pushProofText p <$> dropInstruction instr (verify rest)
verify (p@ProofTextSynonym{} : rest) = pushProofText p <$> verify rest
verify (p@ProofTextPretyping{} : rest) = pushProofText p <$> verify rest
verify (p@ProofTextMacro{} : rest) = pushProofText p <$> verify rest
verify (ProofTextError _ : _) = undefined
verify (ProofTextRoot _ : _) = undefined

verifyThesis :: VerifyMonad ()
verifyThesis = do
  thesis <- asks currentThesis
  let block = Context.head thesis
  let text = Text.unpack $ Block.text block
  let pos = Block.position block
  whenInstruction printgoalParam $ reasonLog Message.TRACING pos $ "goal: " <> text
  if hasDEC (Context.formula thesis) --computational reasoning
    then do
      incrementCounter Equations
      timeWith SimplifyTimer (equalityReasoning pos thesis) <|> (
        reasonLog Message.WARNING pos "equation failed" >> setFailed >>
        guardInstruction skipfailParam >> incrementCounter FailedEquations)
    else do
      unless (isTop . Context.formula $ thesis) $ incrementCounter Goals
      proveThesis pos <|> (
        reasonLog Message.ERROR pos "goal failed" >> setFailed >>
        --guardInstruction Skipfail False >>
        incrementCounter FailedGoals)

verifyBlock :: Block -> [ProofText] -> VerifyMonad ([ProofText], [ProofText])
verifyBlock block rest = do
  state <- ask
  let VState {
      thesisMotivated = motivated,
      rewriteRules    = rules,
      currentThesis   = thesis,
      currentBranch   = branch,
      currentContext  = context,
      mesonRules      = mRules,
      definitions     = defs,
      guards          = grds,
      evaluations     = evaluations } = state

  let Block f body kind _ _ _ _ = block

  alreadyChecked <- readRState alreadyChecked

  -- statistics and user communication
  unless alreadyChecked $ incrementCounter Sections
  whenInstruction printsectionParam $ justIO $
    Message.outputForTheL Message.WRITELN (Block.position block) $
    make_bytes (trim_line (Block.showForm 0 block ""))
  let newBranch = block : branch
  let contextBlock = Context f newBranch []

  whenInstruction translationParam $
    unless (Block.isTopLevel block) $
      translateLog Message.WRITELN (Block.position block) $ Text.pack $ show f

  fortifiedFormula <-
    if Block.isTopLevel block
      then return f
      -- For low-level blocks we check definitions and fortify terms (by supplying evidence).
      else
        fillDef (Block.position block) alreadyChecked contextBlock
          <|> (setFailed >> return f)

  setChecked False

  let restProofText = ProofTextBlock block : rest

  ifFailed (return (restProofText, restProofText)) $ do
    let proofTask = generateProofTask kind (Block.declaredNames block) fortifiedFormula
    let freshThesis = Context proofTask newBranch []
    let toBeProved = Block.needsProof block && not (Block.isTopLevel block)
    proofBody <- do
      flat <- asks (getInstruction flatParam)
      if flat
        then return []
        else return body

    whenInstruction printthesisParam $ when (
      toBeProved && notNull proofBody &&
      not (hasDEC $ Context.formula freshThesis)) $
        thesisLog Message.WRITELN (Block.position block) (length branch - 1) $
        "thesis: " <> show (Context.formula freshThesis)


    (fortifiedProof, markedProof) <-
      local (\st -> st {
        thesisMotivated = toBeProved,
        currentThesis = freshThesis,
        currentBranch = newBranch }) $
      verifyProof (if toBeProved then proofBody else body)

    -- in what follows we prepare the current block to contribute to the context,
    -- extract rules, definitions and compute the new thesis
    thesisSetting <- asks (getInstruction thesisParam)
    let newBlock = block {
          Block.formula = deleteInductionOrCase fortifiedFormula,
          Block.body = fortifiedProof }
    let formulaImage = Block.formulate newBlock
    let markedBlock = block {Block.body = markedProof}

    ifFailed (return (ProofTextBlock newBlock : rest, ProofTextBlock markedBlock : rest)) $ do

      (mesonRules, intermediateSkolem) <- MESON.contras $ deTag formulaImage
      let (newDefinitions, newGuards) =
            if kind == Definition || kind == Signature
              then addDefinition (defs, grds) formulaImage
              else (defs, grds)
      let newContextBlock = Context formulaImage newBranch (uncurry (++) mesonRules)
      let newContext = newContextBlock : context
      let newRules =
            if Block.isTopLevel block
              then MESON.addRules mesonRules mRules
              else mRules
      let (newMotivation, hasChanged , newThesis) =
            if thesisSetting
              then inferNewThesis defs newContext thesis
              else (Block.needsProof block, False, thesis)

      whenInstruction printthesisParam $ when (
        hasChanged && motivated && newMotivation &&
        not (hasDEC $ Block.formula $ head branch) ) $
          thesisLog Message.WRITELN (Block.position block) (length branch - 2) $
          "new thesis: " <> show (Context.formula newThesis)

      when (not newMotivation && motivated) $
        thesisLog Message.WARNING (Block.position block) (length branch - 2) "unmotivated assumption"

      let newRewriteRules = extractRewriteRule (head newContext) ++ rules

      let newEvaluations =
            if   kind `elem` [LowDefinition, Definition]
            then addEvaluation evaluations formulaImage
            else evaluations-- extract evaluations
      -- Now we are done with the block. Move on and verify the rest.
      (newBlocks, markedBlocks) <-
        local (\st -> st {
          thesisMotivated = motivated && newMotivation,
          guards = newGuards,
          rewriteRules = newRewriteRules,
          evaluations = newEvaluations,
          currentThesis = newThesis,
          currentContext = newContext,
          mesonRules = newRules,
          definitions = newDefinitions,
          skolemCounter = intermediateSkolem}) $ verifyProof rest

      -- If this block made the thesis unmotivated, we must discharge a composite
      -- (and possibly quite difficult) prove task
      let finalThesis = Imp (Block.compose $ ProofTextBlock newBlock : newBlocks) (Context.formula thesis)

      -- notice that the following is only really executed if
      -- motivated && not newMotivated == True
      local (\st -> st {
        thesisMotivated = motivated && not newMotivation,
        currentThesis = Context.setFormula thesis finalThesis }) $ verifyProof []
      -- put everything together
      let checkMark = if Block.isTopLevel block then id else ProofTextChecked
      return (ProofTextBlock newBlock : newBlocks, checkMark (ProofTextBlock markedBlock) : markedBlocks)

{- some automated processing steps: add induction hypothesis and case hypothesis
at the right point in the context; extract rewriteRules from them and further
refine the currentThesis. Then move on with the verification loop.
If neither inductive nor case hypothesis is present this is the same as
verify state -}
verifyProof :: [ProofText] -> VerifyMonad ([ProofText], [ProofText])
verifyProof restProofText = do
  state <- ask
  let VState {
    rewriteRules   = rules,
    currentThesis  = thesis,
    currentContext = context,
    currentBranch  = branch} = state
  let
    process :: [Context] -> Formula -> VerifyMonad ([ProofText], [ProofText])
    process newContext f = do
      let newRules = extractRewriteRule (head newContext) ++ rules
          (_, _, newThesis) =
            inferNewThesis (definitions state) newContext $ Context.setFormula thesis f
      whenInstruction printthesisParam $ when (
        noInductionOrCase (Context.formula newThesis) && not (null $ restProofText)) $
          thesisLog Message.WRITELN
          (Block.position $ head $ Context.branch $ head context) (length branch - 2) $
          "new thesis " <> show (Context.formula newThesis)
      local (\st -> st {
        rewriteRules = newRules,
        currentThesis = newThesis,
        currentContext = newContext}) $ verifyProof restProofText
  let
    dive :: (Formula -> Formula) -> [Context] -> Formula -> VerifyMonad ([ProofText], [ProofText])
    dive construct context (Imp (Tag InductionHypothesis f) g)
      | isClosed f = process (Context.setFormula thesis f : context) (construct g)
    dive construct context (Imp (Tag Tag.CaseHypothesis f) g)
      | isClosed f = process (thesis {Context.formula = f} : context) (construct g)
    dive construct context (Imp f g) = dive (construct . Imp f) context g
    dive construct context (All v f) = dive (construct . All v) context f
    dive construct context (Tag tag f) = dive (construct . Tag tag) context f
    dive _ _ _ = verify restProofText

  -- extract rules, compute new thesis and move on with the verification
  dive id context $ Context.formula thesis

{- checks that a formula containt neither induction nor case hyothesis -}
noInductionOrCase :: Formula -> Bool
noInductionOrCase (Tag InductionHypothesis _) = False
noInductionOrCase (Tag Tag.CaseHypothesis _) = False
noInductionOrCase f = allF noInductionOrCase f


{- delete induction or case hypothesis from a formula -}
deleteInductionOrCase :: Formula -> Formula
deleteInductionOrCase = dive id
  where
    dive :: (Formula -> a) -> Formula -> a
    dive c (Imp (Tag InductionHypothesis _) f) = c f
    dive c (Imp (Tag Tag.CaseHypothesis f) _) = c $ Not f
    dive c (Imp f g) = dive (c . Imp f) g
    dive c (All v f) = dive (c . All v) f
    dive c f = c f

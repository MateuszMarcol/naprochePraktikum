{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Pattern parsing and pattern state management.
-}

{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}

module SAD.ForTheL.Pattern where


import qualified Control.Monad.State.Class as MS

import SAD.ForTheL.Base

import SAD.Parser.Base
import SAD.Parser.Combinators
import SAD.Parser.Token
import SAD.Parser.Primitives
import SAD.Core.SourcePos (SourcePos)

import SAD.Data.Formula
import SAD.Data.TermId
import SAD.Data.VarName

import Data.List
import Data.Char
import Control.Applicative
import Control.Monad

-- add expressions to the state of ForTheL

giveId :: Bool -> Int -> Formula -> Formula
giveId p n t = t {trmId = if p then specialId n else (trmId t)}

incId :: Enum p => Bool -> p -> p
incId p n = if p then succ n else n

addExpr :: Formula -> Formula -> Bool -> FState -> FTL Formula

addExpr t@Trm {trmName = 'i':'s':' ':_, trmArgs = vs} f p st =
  MS.put ns >> return nf
  where
    n = idCount st;
    (pt, nf) = extractWordPattern st (giveId p n t) f
    fm  = substs nf $ map varName vs
    ns  = st { adjExpr = (pt, fm) : adjExpr st, idCount = incId p n}

addExpr t@Trm {trmName = 'd':'o':' ':_, trmArgs = vs} f p st =
  MS.put ns >> return nf
  where
    n = idCount st;
    (pt, nf) = extractWordPattern st (giveId p n t) f
    fm = substs nf $ map varName vs
    ns = st {verExpr = (pt, fm) : verExpr st, idCount = incId p n}

addExpr t@Trm {trmName = 'm':'i':'s':' ':_, trmArgs = vs} f p st =
  MS.put ns >> return nf
  where
    n = idCount st;
    ((hp:tp), nf) = extractWordPattern st (giveId p n t) f
    pt = hp : Wd [] : Vr : tp
    fm = substs nf $ map varName vs
    ns = st {adjExpr = (pt, fm) : adjExpr st, idCount = incId p n}

addExpr t@Trm {trmName = 'm':'d':'o':' ':_, trmArgs = vs} f p st =
  MS.put ns >> return nf
  where
    n = idCount st;
    ((hp:tp), nf) = extractWordPattern st (giveId p n t) f
    pt = hp : Wd [] : Vr : tp
    fm = substs nf $ map varName vs
    ns = st {verExpr = (pt, fm) : verExpr st, idCount = incId p n}

addExpr t@Trm {trmName = 'a':' ':_, trmArgs = vs} f p st =
  MS.put ns >> return nf
  where
    n = idCount st;
    (pt, nf) = extractWordPattern st (giveId p n t) f
    fm = substs nf $ map varName vs
    ns = st {ntnExpr = (pt, fm) : ntnExpr st, idCount = incId p n}

addExpr Trm {trmName= "=", trmArgs = [v, t@Trm {trmName = 'a':' ':rs}]} f p st =
  MS.put ns >> return nf
  where
    n = idCount st; vs = trmArgs t
    (pt, nf) = extractWordPattern st (giveId p n t {trmName = "tthe " ++ rs}) f
    fm = substs nf $ map varName (v:vs)
    ns = st {ntnExpr = (pt, fm) : ntnExpr st, idCount = incId p n}

addExpr Trm {trmName = "=", trmArgs = [_, t]} eq@Trm {trmName = "="} p st =
  MS.put nn >> return (zEqu v nf)
  where
    [v, f] = trmArgs eq; vs = trmArgs t
    n = idCount st
    (pt, nf) = extractSymbPattern (giveId p n t) f
    fm = substs nf $ map varName vs
    -- classification of pattern
    csm = lsm && rsm; lsm = notVr (head pt); rsm = notVr (last pt)
    notVr Vr = False; notVr _ = True
    -- add to the right category
    ns | csm = st {cfnExpr = (pt, fm) : cfnExpr st}
       | lsm = st {lfnExpr = (init pt, fm) : lfnExpr st}
       | rsm = st {rfnExpr = (tail pt, fm) : rfnExpr st}
       | otherwise = st {ifnExpr = (init (tail pt), fm) : ifnExpr st}
    -- increment id counter
    nn = ns {idCount = incId p n}


addExpr t@Trm {trmName = s, trmArgs = vs} f p st =
  MS.put nn >> return nf
  where
    n = idCount st
    (pt, nf) = extractSymbPattern (giveId p n t) f
    fm = substs nf $ map varName vs
    -- classification of pattern
    csm = lsm && rsm; lsm = notVr (head pt); rsm = notVr (last pt)
    notVr Vr = False; notVr _ = True
    -- add the pattern to the right category
    ns | csm = st {cprExpr = (pt, fm) : cprExpr st}
       | lsm = st {lprExpr = (init pt, fm) : lprExpr st}
       | rsm = st {rprExpr = (tail pt, fm) : rprExpr st}
       | otherwise = st {iprExpr = (init (tail pt), fm) : iprExpr st}
    -- check if pattern is a symbolic notion
    snt = not lsm && elem (varName $ head vs) (declNames [] nf)
    -- and add it there as well if so (and increment id counter)
    nn | snt = ns {sntExpr = (tail pt,fm) : sntExpr st, idCount = incId p n}
       | otherwise = ns {idCount = incId p n}






-- pattern extraction

extractWordPattern :: FState
                      -> Formula -> Formula -> ([Patt], Formula)
extractWordPattern st t@Trm {trmName = s, trmArgs = vs} f = (pt, nf)
  where
    pt = map getPatt ws
    nt = t {trmName = pr ++ getName pt}
    nf = replace nt t {trmId = NewId} f
    (pr:ws) = words s
    dict = strSyms st

    getPatt "." = Nm
    getPatt "#" = Vr
    getPatt w = Wd $ foldl union [w] $ filter (elem w) dict

    getName (Wd ((c:cs):_):ls) = toUpper c : cs ++ getName ls
    getName (_:ls) = getName ls
    getName [] = ""


extractSymbPattern :: Formula -> Formula -> ([Patt], Formula)
extractSymbPattern t@Trm {trmName = s, trmArgs = vs} f = (pt, nf)
  where
    pt = map getPatt (words s)
    nt = t {trmName ='s' : getName pt}
    nf = replace nt t {trmId = NewId} f

    getPatt "#" = Vr
    getPatt w = Sm w

    getName (Sm s:ls) = symEncode s ++ getName ls
    getName (Vr:ls) = symEncode "." ++ getName ls
    getName [] = ""




-- New patterns


newPrdPattern :: FTL Formula -> FTL Formula
newPrdPattern tvr = multi </> unary </> newSymbPattern tvr
  where
    unary = do
      v <- tvr; (t, vs) <- unaryAdj -|- unaryVerb
      return $ zTrm NewId t (v:vs)
    multi = do
      (u,v) <- liftM2 (,) tvr (comma >> tvr);
      (t, vs) <- multiAdj -|- multiVerb
      return $ zTrm NewId t (u:v:vs)

    unaryAdj = do is; (t, vs) <- ptHead wlexem tvr; return ("is " ++ t, vs)
    multiAdj = do is; (t, vs) <- ptHead wlexem tvr; return ("mis " ++ t, vs)
    unaryVerb = do (t, vs) <- ptHead wlexem tvr; return ("do " ++ t, vs)
    multiVerb = do (t, vs) <- ptHead wlexem tvr; return ("mdo " ++ t, vs)

newNtnPattern :: FTL Formula
                 -> FTL (Formula, (VariableName, SourcePos))
newNtnPattern tvr = (ntn <|> fun) </> unnamedNotion tvr
  where
    ntn = do
      an; (t, v:vs) <- ptName wlexem tvr
      return (zTrm NewId ("a " ++ t) (v:vs), (varName v, varPosition v))
    fun = do
      the; (t, v:vs) <- ptName wlexem tvr
      return (zEqu v $ zTrm NewId ("a " ++ t) vs, (varName v, varPosition v))

unnamedNotion :: FTL Formula
                 -> FTL (Formula, (VariableName, SourcePos))
unnamedNotion tvr = (ntn <|> fun) </> (newSymbPattern tvr >>= equ)
  where
    ntn = do
      an; (t, v:vs) <- ptNoName wlexem tvr
      return (zTrm NewId ("a " ++ t) (v:vs), (varName v, varPosition v))
    fun = do
      the; (t, v:vs) <- ptNoName wlexem tvr
      return (zEqu v $ zTrm NewId ("a " ++ t) vs, (varName v, varPosition v))
    equ t = do v <- hidden; return (zEqu (pVar v) t, v)


newSymbPattern :: FTL Formula -> FTL Formula
newSymbPattern tvr = left -|- right
  where
    left = do
      (t, vs) <- ptHead slexem tvr
      return $ zTrm NewId t vs
    right = do
      (t, vs) <- ptTail slexem tvr
      guard $ not $ null $ tail $ words t
      return $ zTrm NewId t vs


-- pattern parsing


ptHead :: Parser st String
          -> Parser st a -> Parser st (String, [a])
ptHead lxm tvr = do
  l <- unwords <$> chain lxm
  (ls, vs) <- opt ([], []) $ ptTail lxm tvr
  return (l ++ ' ' : ls, vs)


ptTail :: Parser st String
          -> Parser st a -> Parser st (String, [a])
ptTail lxm tvr = do
  v <- tvr
  (ls, vs) <- opt ([], []) $ ptHead lxm tvr
  return ("# " ++ ls, v:vs)


ptName :: FTL String
          -> FTL Formula -> FTL (String, [Formula])
ptName lxm tvr = do
  l <- unwords <$> chain lxm; n <- nam
  (ls, vs) <- opt ([], []) $ ptHead lxm tvr
  return (l ++ " . " ++ ls, n:vs)


ptNoName :: FTL String
            -> FTL Formula -> FTL (String, [Formula])
ptNoName lxm tvr = do
  l <- unwords <$> chain lxm; n <- hid
  (ls, vs) <- opt ([], []) $ ptShort lxm tvr
  return (l ++ " . " ++ ls, n:vs)
  where
    --ptShort is a kind of buffer that ensures that a variable does not directly
    --follow the name of the notion
    ptShort lxm tvr = do
      l <- lxm; (ls, vs) <- ptTail lxm tvr
      return (l ++ ' ' : ls, vs)



-- In-pattern lexemes and variables

wlexem :: FTL String
wlexem = do
  l <- wlx
  guard $ all isAlpha l
  return $ map toLower l

slexem :: FTL String
slexem = slex -|- wlx
  where
    slex = tokenPrim isSymb
    isSymb t =
      let tk = showToken t
      in  case tk of
            [c] -> guard (c `elem` symChars) >> return tk
            _   -> Nothing

wlx :: FTL String
wlx = failing nvr >> tokenPrim isWord
  where
    isWord t =
      let tk = showToken t; ltk = map toLower tk
      in guard (all isAlphaNum tk && ltk `notElem` keylist) >> return tk
    keylist = ["a","an","the","is","are","be"]

nvr :: FTL Formula
nvr = do
  v <- var; dvs <- getDecl; tvs <- MS.gets tvrExpr
  guard $ fst v `elem` dvs || any (elem (fst v) . fst) tvs
  return $ pVar v

avr :: Parser st Formula
avr = do
  v <- var; 
  guard $ null $ tail $ deVar $ fst v
  return $ pVar v
  where
    deVar (VarConstant s) = s
    deVar _ = error "SAD.ForTheL.Pattern.avr: other variable"

nam :: FTL Formula
nam = do
  n <- fmap (const Top) nvr </> avr
  guard $ isVar n ; return n

hid :: FTL Formula
hid = fmap pVar hidden

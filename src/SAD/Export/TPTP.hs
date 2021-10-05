{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Print proof task in TPTP syntax.
-}

{-# LANGUAGE OverloadedStrings #-}

module SAD.Export.TPTP (output) where

import SAD.Data.Formula (Formula(..), showTrName, TermName(..))
import SAD.Data.Text.Block (Block(Block))
import qualified SAD.Data.Text.Block as Block
import SAD.Data.Text.Context (Context(..))
import Data.Text.Lazy (Text)
import qualified Data.Text.Lazy as Text
import Data.Text.Lazy.Builder (Builder)
import qualified Data.Text.Lazy.Builder as Builder
import SAD.Export.Representation
import qualified Isabelle.Position as Position


output :: [Context] -> Context -> Text
output contexts goal = toLazyText $
  mconcat (map (tptpForm ",hypothesis,") $ reverse contexts)
  <> tptpForm ",conjecture," goal

-- Formula print
tptpForm :: Builder -> Context -> Builder
tptpForm s (Context fr (Block { Block.name = m } : _) _) =
  "fof(m"
  <> (if Text.null m then "_" else Builder.fromLazyText m)
  <> s <> tptpTerm 0 fr <> ").\n"
tptpForm _ _ = ""

tptpTerm :: Int -> Formula -> Builder
tptpTerm d = dive
  where
    dive (All _ f)  = buildParens $ " ! " <> binder f
    dive (Exi _ f)  = buildParens $ " ? " <> binder f
    dive (Iff f g)  = sinfix " <=> " f g
    dive (Imp f g)  = sinfix " => " f g
    dive (Or  f g)  = sinfix " | " f g
    dive (And f g)  = sinfix " & " f g
    dive (Tag _ f)  = dive f
    dive (Not f)    = buildParens $ " ~ " <> dive f
    dive Top        = "$true"
    dive Bot        = "$false"
    dive t@Trm {trmName = TermEquality} = let [l, r] = trmArgs t in sinfix " = " l r
    dive t@Trm {}   = Builder.fromLazyText (showTrName t) <> buildArgumentsWith dive (trmArgs t)
    dive v@Var {}   = Builder.fromLazyText (showTrName v)
    dive i@Ind {}   = "W" <> Builder.fromString (show (d - 1 - indIndex i))
    dive ThisT      = error "SAD.Export.TPTP: Didn't expect ThisT here"

    sinfix o f g  = buildParens $ dive f <> o <> dive g

    binder f  = "[" <> tptpTerm (succ d) (Ind 0 Position.none) <> "] : " <> tptpTerm (succ d) f
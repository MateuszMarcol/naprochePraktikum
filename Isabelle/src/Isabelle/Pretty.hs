{- generated by Isabelle -}

{-  Title:      Isabelle/Pretty.hs
    Author:     Makarius
    LICENSE:    BSD 3-clause (Isabelle)

Generic pretty printing module.

See also "$ISABELLE_HOME/src/Pure/General/pretty.ML".
-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

module Isabelle.Pretty (
  T, symbolic, formatted, unformatted,

  str, brk_indent, brk, fbrk, breaks, fbreaks, blk, block, strs, markup, mark, mark_str, marks_str,
  item, text_fold, keyword1, keyword2, text, paragraph, para, quote, cartouche, separate,
  commas, enclose, enum, list, str_list, big_list)
where

import Isabelle.Library hiding (quote, commas)
import qualified Data.List as List
import qualified Isabelle.Buffer as Buffer
import qualified Isabelle.Markup as Markup
import qualified Isabelle.XML as XML
import qualified Isabelle.YXML as YXML


data T =
    Block Markup.T Bool Int [T]
  | Break Int Int
  | Str String


{- output -}

output_spaces n = replicate n ' '

symbolic_text "" = []
symbolic_text s = [XML.Text s]

symbolic_markup markup body =
  if Markup.is_empty markup then body
  else [XML.Elem (markup, body)]

symbolic :: T -> XML.Body
symbolic (Block markup consistent indent prts) =
  concatMap symbolic prts
  |> symbolic_markup block_markup
  |> symbolic_markup markup
  where block_markup = if null prts then Markup.empty else Markup.block consistent indent
symbolic (Break wd ind) = [XML.Elem (Markup.break wd ind, symbolic_text (output_spaces wd))]
symbolic (Str s) = symbolic_text s

formatted :: T -> String
formatted = YXML.string_of_body . symbolic

unformatted :: T -> String
unformatted prt = Buffer.empty |> out prt |> Buffer.content
  where
    out (Block markup _ _ prts) =
      let (bg, en) = YXML.output_markup markup
      in Buffer.add bg #> fold out prts #> Buffer.add en
    out (Break _ wd) = Buffer.add (output_spaces wd)
    out (Str s) = Buffer.add s


{- derived operations to create formatting expressions -}

force_nat n | n < 0 = 0
force_nat n = n

str :: String -> T
str = Str

brk_indent :: Int -> Int -> T
brk_indent wd ind = Break (force_nat wd) ind

brk :: Int -> T
brk wd = brk_indent wd 0

fbrk :: T
fbrk = str "\n"

breaks, fbreaks :: [T] -> [T]
breaks = List.intersperse (brk 1)
fbreaks = List.intersperse fbrk

blk :: (Int, [T]) -> T
blk (indent, es) = Block Markup.empty False (force_nat indent) es

block :: [T] -> T
block prts = blk (2, prts)

strs :: [String] -> T
strs = block . breaks . map str

markup :: Markup.T -> [T] -> T
markup m = Block m False 0

mark :: Markup.T -> T -> T
mark m prt = if m == Markup.empty then prt else markup m [prt]

mark_str :: (Markup.T, String) -> T
mark_str (m, s) = mark m (str s)

marks_str :: ([Markup.T], String) -> T
marks_str (ms, s) = fold_rev mark ms (str s)

item :: [T] -> T
item = markup Markup.item

text_fold :: [T] -> T
text_fold = markup Markup.text_fold

keyword1, keyword2 :: String -> T
keyword1 name = mark_str (Markup.keyword1, name)
keyword2 name = mark_str (Markup.keyword2, name)

text :: String -> [T]
text = breaks . map str . words

paragraph :: [T] -> T
paragraph = markup Markup.paragraph

para :: String -> T
para = paragraph . text

quote :: T -> T
quote prt = blk (1, [str "\"", prt, str "\""])

cartouche :: T -> T
cartouche prt = blk (1, [str "\92<open>", prt, str "\92<close>"])

separate :: String -> [T] -> [T]
separate sep = List.intercalate [str sep, brk 1] . map single

commas :: [T] -> [T]
commas = separate ","

enclose :: String -> String -> [T] -> T
enclose lpar rpar prts = block (str lpar : prts <> [str rpar])

enum :: String -> String -> String -> [T] -> T
enum sep lpar rpar = enclose lpar rpar . separate sep

list :: String -> String -> [T] -> T
list = enum ","

str_list :: String -> String -> [String] -> T
str_list lpar rpar = list lpar rpar . map str

big_list :: String -> [T] -> T
big_list name prts = block (fbreaks (str name : prts))

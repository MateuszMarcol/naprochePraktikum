{- generated by Isabelle -}

{-  Title:      Isabelle/UTF8.hs
    Author:     Makarius
    LICENSE:    BSD 3-clause (Isabelle)

Variations on UTF-8.

See "$ISABELLE_HOME/src/Pure/General/utf8.ML"
and "$ISABELLE_HOME/src/Pure/General/utf8.scala".
-}

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}

module Isabelle.UTF8 (
  Recode (..)
)
where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Error

import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString, toShort, fromShort)


class Recode a b where
  encode :: a -> b
  decode :: b -> a

instance Recode Text ByteString where
  encode :: Text -> ByteString
  encode = Encoding.encodeUtf8
  decode :: ByteString -> Text
  decode = Encoding.decodeUtf8With Error.lenientDecode

instance Recode Text ShortByteString where
  encode :: Text -> ShortByteString
  encode = toShort . encode
  decode :: ShortByteString -> Text
  decode = decode . fromShort

instance Recode String ByteString where
  encode :: String -> ByteString
  encode = encode . Text.pack
  decode :: ByteString -> String
  decode = Text.unpack . decode

instance Recode String ShortByteString where
  encode :: String -> ShortByteString
  encode = encode . Text.pack
  decode :: ShortByteString -> String
  decode = Text.unpack . decode
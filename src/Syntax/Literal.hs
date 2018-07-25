{-# LANGUAGE OverloadedStrings #-}
module Syntax.Literal where

import Data.Word
import Numeric.Natural

import Pretty
import qualified TypeRep

data Literal
  = Integer !Integer
  | Natural !Natural
  | Byte !Word8
  | TypeRep !TypeRep.TypeRep
  deriving (Eq, Ord, Show)

instance Pretty Literal where
  prettyM (Integer i) = prettyM i
  prettyM (Natural n) = "(Nat)" <> prettyM n
  prettyM (Byte i) = "(Byte)" <> prettyM (fromIntegral i :: Integer)
  prettyM (TypeRep tr) = prettyM tr

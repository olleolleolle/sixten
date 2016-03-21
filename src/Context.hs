{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, TypeFamilies #-}
module Context where

import Control.Monad.Except
import Data.Bifunctor
import Data.Set(Set)
import qualified Data.Set as Set
import qualified Data.Vector as Vector

import Syntax
import Util

class Monad cxt => Context cxt where
  type ContextExpr cxt :: * -> *
  lookupDefinition
    :: Name
    -> cxt (Maybe (Definition (ContextExpr cxt) v, ContextExpr cxt v))
  lookupConstructor
    :: Ord v
    => Constr
    -> cxt (Set (Name, ContextExpr cxt v))

definition
  :: (MonadError String cxt, Context cxt, Functor (ContextExpr cxt))
  => Name
  -> cxt (Definition (ContextExpr cxt) v, ContextExpr cxt v)
definition v = do
  mres <- lookupDefinition v
  maybe (throwError $ "Not in scope: " ++ show v)
        (return . bimap (fmap fromEmpty) (fmap fromEmpty))
        mres

constructor
  :: (MonadError String cxt, Context cxt, Ord (ContextExpr cxt v), Functor (ContextExpr cxt))
  => Either Constr QConstr
  -> cxt (Set (Name, ContextExpr cxt v))
constructor (Right qc@(QConstr n _)) = Set.singleton . (,) n <$> qconstructor qc
constructor (Left c) = Set.map (second $ fmap fromEmpty) <$> lookupConstructor c

arity
  :: (MonadError String cxt, Context cxt, Syntax (ContextExpr cxt), Monad (ContextExpr cxt))
  => QConstr
  -> cxt Int
arity = fmap (teleLength . fst . bindingsView piView) . qconstructor

relevantArity
  :: (MonadError String cxt, Context cxt, Functor (ContextExpr cxt), Syntax (ContextExpr cxt), Monad (ContextExpr cxt))
  => QConstr
  -> cxt Int
relevantArity
  = fmap ( Vector.length
         . Vector.filter (\(_, a, _) -> relevance a == Relevant)
         . unTelescope
         . fst
         . bindingsView piView)
  . qconstructor

qconstructor
  :: (MonadError String cxt, Context cxt, Functor (ContextExpr cxt))
  => QConstr
  -> cxt (ContextExpr cxt v)
qconstructor qc@(QConstr n c) = do
  results <- lookupConstructor c
  let filtered = Set.filter ((== n) . fst) results
  case Set.size filtered of
    1 -> do
      let [(_, t)] = Set.toList filtered
      return (fromEmpty <$> t)
    0 -> throwError $ "Not in scope: constructor " ++ show qc
    _ -> throwError $ "Ambiguous constructor: " ++ show qc
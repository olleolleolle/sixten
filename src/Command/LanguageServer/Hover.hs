{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Command.LanguageServer.Hover where

import Protolude

import Control.Lens hiding (Context)
import Control.Monad.ListT(ListT(ListT))
import qualified Data.List.Class as ListT
import Text.Parsix.Position

import Driver.Query
import Effect
import Effect.Context as Context
import Syntax
import Syntax.Core
import TypedFreeVar

inside :: Int -> Int -> Span -> Bool
inside row column (Span start end)
  = row >= visualRow start
  && row <= visualRow end
  && (row /= visualRow start || column >= visualColumn start)
  && (row /= visualRow end || column < visualColumn end)

-- TODO check file as well

data HoverEnv = HoverEnv
  { _freshEnv :: !FreshEnv
  , _context :: !(Context (Expr Void FreeVar))
  , _logEnv :: !LogEnv
  , _reportEnv :: !ReportEnv
  }

makeLenses ''HoverEnv

instance HasFreshEnv HoverEnv where
  freshEnv = Command.LanguageServer.Hover.freshEnv

instance HasContext (Expr Void FreeVar) HoverEnv where
  context = Command.LanguageServer.Hover.context

instance HasLogEnv HoverEnv where
  logEnv = Command.LanguageServer.Hover.logEnv

instance HasReportEnv HoverEnv where
  reportEnv = Command.LanguageServer.Hover.reportEnv

newtype Hover a = Hover { unHover :: ListT (ReaderT HoverEnv (Task Query)) a }
  deriving (Functor, Applicative, Alternative, Monad, MonadIO, Semigroup, Monoid, MonadContext (Expr Void FreeVar), MonadFresh, MonadLog, MonadReport, MonadFetch Query)

instance MonadReader r m => MonadReader r (ListT m) where
  ask = ListT $ do
    x <- ask
    pure $ ListT.Cons x $ ListT $ pure ListT.Nil
  local f (ListT mxs) = ListT $ do
    xs <- local f mxs
    pure $ case xs of
      ListT.Cons x mxs' -> ListT.Cons x $ local f mxs'
      ListT.Nil -> ListT.Nil

instance MonadFetch q m => MonadFetch q (ListT m) where
  fetch key = ListT $ do
    x <- fetch key
    pure $ ListT.Cons x $ ListT $ pure ListT.Nil

runHover :: Hover a -> Task Query ([a], [Error])
runHover (Hover m) = do
  f <- emptyFreshEnv
  errsVar <- liftIO $ newMVar mempty
  let
    l = LogEnv
      { _logCategories = const False
      , _logAction = \_ -> return ()
      }
    r = emptyReportEnv $ \e -> modifyMVar_ errsVar $ pure . (e :)
  res <- runReaderT (ListT.toList m) (HoverEnv f mempty l r)
  errs <- liftIO $ readMVar errsVar
  return (res, errs)

emitCons :: a -> Hover a -> Hover a
emitCons a as
  = Hover $ ListT $ pure $ ListT.Cons a $ unHover as

hoverDefs
  :: (Span -> Bool)
  -> [(GName, SourceLoc, ClosedDefinition Expr, Biclosed Expr)]
  -> Hover (Span, Expr Void FreeVar)
hoverDefs f defs = hoverClosedDef f =<< Hover (ListT.fromList defs)

hoverClosedDef
  :: (Span -> Bool)
  -> (GName, SourceLoc, ClosedDefinition Expr, Biclosed Expr)
  -> Hover (Span, Expr Void FreeVar)
hoverClosedDef f (_, loc, ClosedDefinition def, Biclosed e) = do
  guard $ f $ sourceLocSpan loc
  hoverDef f def <> hoverExpr f e

hoverDef
  :: (Span -> Bool)
  -> Definition (Expr Void) FreeVar
  -> Hover (Span, Expr Void FreeVar)
hoverDef f (ConstantDefinition _ e) = hoverExpr f e
hoverDef f (DataDefinition (DataDef params cs) _rep) =
  teleExtendContext params $ \vs -> do
    context <- getContext
    foldMap (hoverExpr f . _type . (`Context.lookup` context)) vs
    <> foldMap (\(ConstrDef _ s) -> hoverExpr f $ instantiateTele pure vs s) cs

hoverExpr
  :: (Span -> Bool)
  -> Expr Void FreeVar
  -> Hover (Span, Expr Void FreeVar)
hoverExpr f expr = case expr of
  Var _ -> mempty
  Meta m _ -> absurd m
  Global _ -> mempty
  Con _ -> mempty
  Lit _ -> mempty
  Pi h p t s ->
    Context.freshExtend (binding h p t) $ \v ->
      hoverExpr f t <> hoverExpr f (instantiate1 (pure v) s)
  Lam h p t s ->
    Context.freshExtend (binding h p t) $ \v ->
      hoverExpr f t <> hoverExpr f (instantiate1 (pure v) s)
  App e1 _ e2 -> hoverExpr f e1 <> hoverExpr f e2
  Let ds scope -> fold
    [ fold $ forLet ds $ \_ loc _ t -> do
      guard $ f $ sourceLocSpan loc
      hoverExpr f t
    , letExtendContext ds $ \vs ->
      fold (forLet ds $ \_ loc s _ -> do
        guard $ f $ sourceLocSpan loc
        hoverExpr f $ instantiateLet pure vs s)
      <> hoverExpr f (instantiateLet pure vs scope)
    ]
  Case e brs _ -> hoverExpr f e <> hoverBranches f brs
  ExternCode e _ -> fold $ hoverExpr f <$> e
  SourceLoc loc e -> do
    guard $ f $ sourceLocSpan loc
    emitCons (sourceLocSpan loc, e) $ hoverExpr f e

hoverBranches
  :: (Span -> Bool)
  -> Branches (Expr Void) FreeVar
  -> Hover (Span, Expr Void FreeVar)
hoverBranches f (LitBranches lbrs def) =
  foldMap (\(LitBranch _ e) -> hoverExpr f e) lbrs
  <> hoverExpr f def
hoverBranches f (ConBranches cbrs) =
  flip foldMap cbrs $ \(ConBranch _ tele scope) ->
    teleExtendContext tele $ \vs -> do
      context <- getContext
      foldMap (hoverExpr f . _type . (`Context.lookup` context)) vs
      <> hoverExpr f (instantiateTele pure vs scope)

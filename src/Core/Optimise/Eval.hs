{-# LANGUAGE ConstraintKinds, FlexibleContexts #-}
module Core.Optimise.Eval
  ( peval
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Except

import Data.Traversable
import Data.Semigroup
import Data.Foldable
import Data.Triple
import Data.Either
import Data.List

import Syntax (Var(..), Resolved, Lit(LiBool))
import Core.Optimise

import Generics.SYB

import Pretty (tracePretty, tracePrettyId, (<+>))

data Scope = Scope
  { variables :: Map.Map (Var Resolved) CoTerm
  , constructors :: Set.Set (Var Resolved)
  }

type MonadEval m
  = ( MonadReader Scope m
    , MonadState Int m
    )

extend :: (Map.Map (Var Resolved) CoTerm -> Map.Map (Var Resolved) CoTerm) -> Scope -> Scope
extend f (Scope v c) = Scope (f v) c

fuel :: Int
fuel = 100

peval :: [CoStmt] -> [CoStmt]
peval xs = go xs where
  go :: [CoStmt] -> [CoStmt]
  go (CosLet vs:xs)
    = let vs' = map (third3 reduceOne) vs
       in CosLet vs':go xs
  go (it:xs) = it:go xs
  go [] = []

  reduceOne :: CoTerm -> CoTerm
  reduceOne x = evalState (runReaderT (evaluate x) (Scope (mkEnv xs) (mkCS xs))) fuel

  mkEnv (CosLet vs:xs) = foldMap (\x -> Map.singleton (fst3 x) (thd3 x)) vs
             `Map.union` mkEnv xs
  mkEnv (_:xs) = mkEnv xs
  mkEnv [] = Map.empty

  mkCS (CosType _ vs:xs) = Set.fromList (map fst vs) `Set.union` mkCS xs
  mkCS (_:xs) = mkCS xs
  mkCS [] = Set.empty

evaluate :: MonadEval m => CoTerm -> m CoTerm
evaluate term = do
  x <- get
  if x >= 0
     then do
       modify pred
       eval term
     else pure term

eval :: MonadEval m => CoTerm -> m CoTerm
eval it = case it of
  CotRef v _ -> do
    val <- asks (Map.lookup v . variables)
    maybe (pure it) evaluate val
  CotLam s a b -> CotLam s a <$> evaluate b
  CotApp f x -> do
    f' <- evaluate f
    x' <- evaluate x
    case f' of
      CotLam Small (arg, tp) bdy -> do
        pr <- propagate x'
        if pr
           then evaluate (substitute (Map.singleton arg x') bdy)
           else evaluate (CotLet [(arg, tp, x')] bdy)
      _ -> pure (CotApp f' x')
  CotLet vs e -> do
    vars <- for vs $ \(var, tp, ex) -> do
      ex' <- evaluate ex
      pr <- propagate ex'
      tracePretty ("propagating " <+> ex <+> "? " <+> LiBool pr) $ pure ()
      pure $ if pr
         then Left (Map.singleton var ex')
         else Right (var, tp, ex')
    let (propag, keep) = partitionEithers vars
        varsk = case keep of
          [] -> id
          _ -> fmap (CotLet keep)
       in evaluate =<< varsk (local (extend (Map.union (fold propag))) (evaluate e))
  CotMatch s b -> do
    term <- flip reduceBranches b =<< evaluate s
    case term of
      CotMatch sc [(CopCapture v, tp, cs)] ->
        evaluate (CotLet [(v, tp, sc)] cs)
      _ -> pure term
  CotTyApp f tp -> do
    f' <- evaluate f
    case f' of
      CotLam Big _ bdy ->
        evaluate bdy
      _ -> pure (CotTyApp f' tp)
  CotBegin xs e -> do
    xs' <- filterM (fmap not . propagate) xs
    CotBegin <$> traverse evaluate xs' <*> evaluate e
  CotExtend i rs -> CotExtend <$> evaluate i <*> traverse (third3A evaluate) rs
  CotLit{} -> pure it

type Branch = (CoPattern, CoType, CoTerm)

-- Can we /safely/ propagate this without duplicating work?
propagate :: MonadEval m => CoTerm -> m Bool
propagate CotLit{} = pure True
propagate CotRef{} = pure True

propagate (CotLam _ _ b) = propagate b
propagate (CotTyApp x _) = propagate (tracePrettyId x)
propagate (CotApp f x)
  | CotRef v _ <- f = do
    isCs <- asks (Set.member v . constructors)
    tracePretty ("cotApp " <+> v <+> " was a constructor? " <+> LiBool isCs) $ pure ()
    (isCs &&) <$> propagate x
  | CotTyApp f' _ <- f = do
    (&&) <$> propagate x <*> propagate (CotApp f' x)
  | otherwise = pure False
propagate _ = pure False

reduceBranches :: MonadEval m => CoTerm -> [Branch] -> m CoTerm
reduceBranches ex = doIt where
  doIt xs = do
    x <- runExceptT (go xs)
    case x of
      Left (env, term) -> local (extend (env `Map.union`)) (evaluate term)
      Right xs -> pure (CotMatch ex (simplify xs []))

  go :: MonadEval m => [Branch] -> ExceptT (Map.Map (Var Resolved) CoTerm, CoTerm) m [Branch]
  go ((pt, tp, cs):xs) = case ex of
    CotRef v _ -> do
      eval <- asks (Set.member v . constructors)
      if eval
         then go' tp pt ex cs xs
         else do
           cs' <- evaluate cs
           (:) (pt, tp, cs') <$> go xs
    _ -> go' tp pt ex cs xs
  go [] = pure []

  go' tp pt ex cs xs = case match pt (killTyApps ex) of
    Just binds -> throwError (binds, cs)
    Nothing -> do
      cs' <- evaluate cs
      (:) (pt, tp, cs') <$> go xs

  simplify :: [Branch] -> [Branch] -> [Branch]
  simplify (it@(CopCapture{}, _, _):_) acc = reverse (it:acc)
  simplify (x:xs) acc = simplify xs (x:acc)
  simplify [] acc = reverse acc

  -- We simplify terms like 'Foo @int 1' to Foo @
  killTyApps :: CoTerm -> CoTerm
  killTyApps = everywhere (mkT go) where
    go (CotTyApp f _) = f
    go x = x


match :: CoPattern -> CoTerm -> Maybe (Map.Map (Var Resolved) CoTerm)
match (CopCapture v) x = pure (Map.singleton v x)
match (CopConstr x) (CotRef v _)
  | x == v = pure Map.empty
  | otherwise = Nothing
match (CopDestr x p) (CotApp (CotRef v _) a)
  | x == v = match p a
  | otherwise = Nothing
match (CopExtend i ps) (CotExtend l rs) = do
  x <- match i l
  let ps' = sortOn fst ps
      rs' = sortOn fst3 rs
  inside <- for (zip ps' rs') $ \((l, p), (l', _, t)) -> do
    guard (l == l')
    match p t
  pure (x <> fold inside)
match _ _ = Nothing

{-# LANGUAGE ConstraintKinds, FlexibleContexts #-}
module Core.Optimise.Eval
  ( peval
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Set as Set

import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Except

import Data.Traversable
import Data.Semigroup
import Data.Foldable
import Data.Triple
import Data.Maybe
import Data.List

import Syntax (Var(..), Resolved)
import Core.Optimise

import Generics.SYB

data Scope = Scope
  { variables :: Map.Map (Var Resolved) CoTerm
  , constructors :: Set.Set (Var Resolved)
  , target :: Var Resolved
  }

type MonadEval m
  = ( MonadReader Scope m
    , MonadState Int m
    )

extend :: (Map.Map (Var Resolved) CoTerm -> Map.Map (Var Resolved) CoTerm) -> Scope -> Scope
extend f (Scope v c g) = Scope (f v) c g

-- 100'000 is just enough to make `10` into a Peano natural, so that's
-- what we use, for bragging rights
fuel :: Int
fuel = 100000

peval :: [CoStmt] -> [CoStmt]
peval xs = go xs where
  go :: [CoStmt] -> [CoStmt]
  go (CosLet vs:xs)
    = let vs' = map (\(x, t, y) -> (x, t, reduceOne y x)) vs
       in CosLet vs':go xs
  go (it:xs) = it:go xs
  go [] = []

  reduceOne :: CoTerm -> Var Resolved -> CoTerm
  reduceOne x g = evalState (runReaderT (evaluate x) (Scope (mkEnv xs) (mkCS xs) g)) fuel

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
  if x > 0
     then do
       put (x - 1)
       term' <- eval term
       pure term'
    else pure term

eval :: MonadEval m => CoTerm -> m CoTerm
eval it = case it of
  _ | isBop (killTyApps it) -> bop (killTyApps it)
  CotRef v _ -> do
    x <- asks target
    if v == x
       then do
         modify (const 0) -- halt! we only unroll if we inline
         pure it
        else do
          val <- asks (Map.lookup v . variables)
          maybe (pure it) evaluate val
  CotLam s a b -> pure (CotLam s a b)
  CotApp f x -> do
    f' <- evaluate f
    x' <- evaluate x
    case f' of
      CotLam Small (arg, tp) bdy ->
        evaluate (CotLet [(arg, tp, x')] bdy)
      _ -> pure (CotApp f' x')
  CotLet vs e -> do
    vars <- for vs $ \(var, tp, ex) -> do
      ex' <- evaluate ex
      pr <- propagate ex'
      let map = if pr then Map.singleton var ex' else mempty
          val = Just (var, tp, ex')
      pure (map, val)
    let (propag, keep) = unzip vars
        varsk = case (catMaybes keep) of
          [] -> evaluate
          xs -> pure . CotLet xs
    e' <- local (extend (Map.union (fold propag))) $ evaluate e
    varsk e'
  CotMatch s b -> do
    term <- flip reduceBranches b =<< evaluate s
    case term of
      CotMatch sc [(CopCapture v _, tp, cs)] -> do
        sc' <- evaluate sc
        evaluate (CotLet [(v, tp, sc')] cs)
      _ -> evaluate term
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
propagate (CotTyApp x _) = propagate x
propagate (CotApp f x)
  | CotRef v _ <- f = do
    isCs <- asks (Set.member v . constructors)
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
      Left term -> evaluate term
      Right xs -> pure (CotMatch ex (simplify xs []))

  go :: MonadEval m => [Branch] -> ExceptT (CoTerm) m [Branch]
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

  go' tp pt ex cs xs = do
    let pat = match pt (killTyApps ex)
    case pat of
      Just binds -> case xs of
        [] -> do -- TODO: fix this
          cs' <- evaluate cs
          case spine cs' of
            Just (CotRef x _, _) ->
              if x == TgInternal (Text.pack "error")
                 then pure [(pt, tp, cs')] -- see note 1
                 else throwError (CotLet (mkBinds binds) cs)
            _ -> throwError (CotLet (mkBinds binds) cs)
        _ -> throwError (CotLet (mkBinds binds) cs)
      Nothing -> do
        cs' <- evaluate cs
        (:) (pt, tp, cs') <$> go xs

  simplify :: [Branch] -> [Branch] -> [Branch]
  simplify (it@(CopCapture{}, _, _):_) acc = reverse (it:acc)
  simplify (x:xs) acc = simplify xs (x:acc)
  simplify [] acc = reverse acc


  mkBinds :: Map.Map (Var Resolved) (CoType, CoTerm) -> [(Var Resolved, CoType, CoTerm)]
  mkBinds = map (\(x, (y, z)) -> (x, y, z)) . Map.toList

-- We simplify terms like 'Foo @int 1' to Foo @
killTyApps :: CoTerm -> CoTerm
killTyApps = everywhere (mkT go) where
  go (CotTyApp f _) = f
  go x = x

match :: CoPattern -> CoTerm -> Maybe (Map.Map (Var Resolved) (CoType, CoTerm))
match (CopCapture v t) x = pure (Map.singleton v (t, x))
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
match (CopLit l) (CotLit l') = mempty <$ guard (l == l')
match _ _ = Nothing

isBop :: CoTerm -> Bool
isBop (CotApp (CotApp (CotRef (TgInternal _) _) _) _) = True
isBop _ = False

bop :: MonadEval m => CoTerm -> m CoTerm
bop (CotApp (CotApp (CotRef (TgInternal v) t) x) y) = do
  x' <- evaluate x
  y' <- evaluate y
  case (x', y') of
    (CotLit ll, CotLit rr) -> pure $ case (Text.unpack v, ll, rr) of
      ("+",  ColInt l, ColInt r) -> num (l + r)
      ("-",  ColInt l, ColInt r) -> num (l - r)
      ("*",  ColInt l, ColInt r) -> num (l * r)
      ("/",  ColInt l, ColInt r) -> num (l `div` r)
      ("**", ColInt l, ColInt r) -> num (l ^ r)
      ("<" , ColInt l, ColInt r) -> bool (l < r)
      (">",  ColInt l, ColInt r) -> bool (l > r)
      (">=", ColInt l, ColInt r) -> bool (l >= r)
      ("<=", ColInt l, ColInt r) -> bool (l <= r)

      ("&&", ColTrue, ColTrue)   -> bool True
      ("&&", _, _)               -> bool False
      ("||", ColFalse, ColFalse) -> bool False
      ("||", _, _)               -> bool True

      ("^", ColStr l, ColStr r)  -> str (l `Text.append` r)
      ("==", _, _) -> bool (rr == ll)
      ("<>", _, _) -> bool (ll /= rr)
      _ -> reop t v x' y'
    (_, _) -> pure $ reop t v x' y'
  where
    num = CotLit . ColInt
    str = CotLit . ColStr
    bool x = CotLit (if x then ColTrue else ColFalse)
    reop t v l = CotApp (CotApp (CotRef (TgInternal v) t) l)
bop x = pure x

spine :: CoTerm -> Maybe (CoTerm, [CoTerm])
spine (CotApp x y) = go x y where
  go (CotApp f x) y = do
    (a, as) <- go f x
    pure (a, y:as)
  go f x = Just (f, [x])
spine _ = Nothing

-- Note [1]:
-- Since captures always match, we make sure here that this isn't the
-- last case (i.e. the automatically generated non-exhaustive pattern
-- error). If it *is* the last case, we don't exit, because that'd mean
-- reducing the program into an error.

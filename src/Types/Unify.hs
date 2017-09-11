{-# Language MultiWayIf #-}
module Types.Unify (solve) where

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Infer

import Syntax.Subst
import Syntax

import qualified Data.Map.Strict as M
import qualified Data.Set as S

type SolveM = StateT Subst (Except TypeError)

bind :: String -> Type -> SolveM ()
bind var ty | ty == TyVar var = return ()
            | occurs var ty = throwError (Occurs var ty)
            | otherwise = modify ((M.singleton var ty) `compose`)

unify :: Type -> Type -> SolveM ()
unify (TyVar a) b = bind a b
unify a (TyVar b) = bind b a
unify (TyArr a b) (TyArr a' b') = do
  unify a a'
  unify b b'
unify (TyApp a b) (TyApp a' b') = do
  unify a a'
  unify b b'
unify ta@(TyCon a) tb@(TyCon b)
  | a == b = pure ()
  | otherwise = throwError (NotEqual ta tb)
unify t@(TyForall vs _ ty) t'@(TyForall vs' _ ty')
  | length vs /= length vs' = throwError (NotEqual t t')
  -- TODO: Technically we should make fresh variables and do ty[vs/f] ~ ty'[vs'/f]
  | otherwise = unify ty (apply (M.fromList (zip vs' (map TyVar vs))) ty')
unify a b = throwError (NotEqual a b)

runSolve :: Subst -> SolveM a -> Either TypeError Subst
runSolve s x = runExcept (execStateT x s)

solve :: Subst -> [Constraint] -> Either TypeError Subst
solve s [] = pure s
solve s (ConUnify _ a t:xs) = do
  s' <- runSolve s (unify a t)
  solve (s' `compose` s) (apply s' xs)

occurs :: String -> Type -> Bool
occurs _ (TyVar _) = False
occurs x e = x `S.member` ftv e

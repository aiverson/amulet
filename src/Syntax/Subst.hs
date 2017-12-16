{-# LANGUAGE FlexibleInstances
  , FlexibleContexts
  , UndecidableInstances
  , MultiParamTypeClasses
  , FunctionalDependencies
  #-}
module Syntax.Subst
  ( Subst
  , Substitutable
  , ftv
  , apply
  , compose
  , M.fromList )
  where

import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Control.Arrow (second)

import Syntax

type Subst p = M.Map (Var p) (Type p)

class Substitutable p a | a -> p where
  ftv :: a -> S.Set (Var p)
  apply :: Subst p -> a -> a

instance Ord (Var p) => Substitutable p (Type p) where
  ftv TyCon{} = S.empty
  ftv TyStar{} = S.empty
  ftv (TyVar v) = S.singleton v
  ftv (TyForall vs t) = ftv t S.\\ S.fromList vs
  ftv (TyApp a b) = ftv a `S.union` ftv b
  ftv (TyTuple a b) = ftv a `S.union` ftv b
  ftv (TyArr a b) = ftv a `S.union` ftv b
  ftv (TyRows rho rows) = ftv rho `S.union` foldMap (ftv . snd) rows
  ftv (TyExactRows rows) = foldMap (ftv . snd) rows

  apply _ (TyCon a) = TyCon a
  apply _ TyStar = TyStar
  apply s t@(TyVar v) = M.findWithDefault t v s
  apply s (TyArr a b) = TyArr (apply s a) (apply s b)
  apply s (TyApp a b) = TyApp (apply s a) (apply s b)
  apply s (TyTuple a b) = TyTuple (apply s a) (apply s b)
  apply s (TyForall v t) = TyForall v (apply s' t) where
    s' = foldr M.delete s v
  apply s (TyRows rho rows) = TyRows (apply s rho) (map (second (apply s)) rows)
  apply s (TyExactRows rows) = TyExactRows  (map (second (apply s)) rows)

instance (Ord (Var p), Substitutable p a) => Substitutable p [a] where
  ftv = foldMap ftv
  apply s = map (apply s)

compose :: Ord (Var p) => Subst p -> Subst p -> Subst p
s1 `compose` s2 = M.map (apply s1) s2 `M.union` M.map (apply s2) s1

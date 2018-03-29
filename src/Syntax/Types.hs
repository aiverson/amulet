{-# LANGUAGE FlexibleInstances, FlexibleContexts, UndecidableInstances, StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving, DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}
module Syntax.Types
  ( Telescope, one, foldTele, teleFromList
  , Scope, namesInScope
  , Env, freeInEnv, difference, envOf, scopeFromList, toMap
  , values, types, typeVars

  , focus
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Data.Semigroup

import Control.Arrow
import Control.Lens

import Syntax.Pretty
import Syntax.Subst

-- A bag of bindings, returned from pattern match checking
newtype Telescope p =
  Telescope { getTele :: Map.Map (Var Resolved) (Type p) }
  deriving newtype (Semigroup, Monoid)

deriving instance Ord (Var p) => Ord (Telescope p)
deriving instance Ord (Var p) => Eq (Telescope p)

type instance Index (Telescope p) = Var Resolved
type instance IxValue (Telescope p) = Type p
instance Ord (Var p) => Ixed (Telescope p) where
  ix k f (Telescope m) = Telescope <$> ix k f m

instance Ord (Var p) => At (Telescope p) where
  at k f (Telescope m) = Telescope <$> at k f m

newtype Scope p f =
  Scope { getScope :: Map.Map (Var p) f }

deriving instance (Show (Var p), Show f) => Show (Scope p f)
deriving instance (Ord (Var p), Ord f) => Ord (Scope p f)
deriving instance (Ord (Var p), Ord f) => Eq (Scope p f)
deriving instance Ord (Var p) => Semigroup (Scope p f)
deriving instance Ord (Var p) => Monoid (Scope p f)

instance Ord (Var p) => Traversable (Scope p) where
  traverse f (Scope m) = Scope <$> traverse f m

instance Ord (Var p) => Foldable (Scope p) where
  foldMap f (Scope m) = foldMap f m

instance Ord (Var p) => Functor (Scope p) where
  fmap f (Scope m) = Scope (fmap f m)

type instance Index (Scope p f) = Var p
type instance IxValue (Scope p f) = f
instance Ord (Var p) => Ixed (Scope p f) where
  ix k f (Scope m) = Scope <$> ix k f m

instance Ord (Var p) => At (Scope p f) where
  at k f (Scope m) = Scope <$> at k f m

data Env
  = Env { _values   :: Scope Resolved (Type Typed)
        , _types    :: Scope Resolved (Kind Typed)
        , _typeVars :: Set.Set (Var Resolved)
        }
  deriving (Eq, Show, Ord)

makeLenses ''Env

(\\) :: Ord (Var p) => Scope p f -> Scope p f -> Scope p f
Scope x \\ Scope y = Scope (x Map.\\ y)

instance Monoid Env where
  mappend = (<>)
  mempty = Env mempty mempty mempty

instance Semigroup Env where
  Env a b c <> Env a' b' c' = Env (a <> a') (b <> b') (c <> c')

difference :: Env -> Env -> Env
difference (Env ma mb mc) (Env ma' mb' mc') = Env (ma \\ ma') (mb \\ mb') (mc Set.\\ mc')

freeInEnv :: Env -> Set.Set (Var Typed)
freeInEnv (Env vars _ _) = foldMap ftv vars

envOf :: Scope Resolved (Type Typed) -> Scope Resolved (Kind Typed) -> Env
envOf a b = Env a b mempty

scopeFromList :: Ord (Var p) => [(Var p, f)] -> Scope p f
scopeFromList = Scope . Map.fromList

namesInScope :: Scope p f -> [Var p]
namesInScope (Scope m) = Map.keys m

focus :: Telescope t -> Scope Resolved (Type t) -> Scope Resolved (Type t)
focus m s = Scope (getScope s <> getTele m) where

class Degrade r where
  degrade :: Var r -> Var Resolved

instance Degrade Resolved where degrade = id
instance Degrade Typed where degrade = unTvName

one :: Degrade k => Var k -> Type p -> Telescope p
one k t = Telescope (Map.singleton (degrade k) t)

foldTele :: Monoid m => (Type p -> m) -> Telescope p -> m
foldTele f x = foldMap f (getTele x)

teleFromList :: Degrade p
             => [(Var p, Type p)] -> Telescope p
teleFromList = Telescope . Map.fromList . map (first degrade)

toMap :: Scope p f -> Map.Map (Var p) f
toMap = getScope

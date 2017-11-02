{-# LANGUAGE FlexibleContexts, TypeFamilies #-}
module Types.Wellformed (wellformed, improve) where

import Control.Monad.Except

import Control.Monad.Infer
import Syntax.Raise
import Syntax.Subst
import Syntax

import Data.Spanned
import Data.Span

import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Pretty(Pretty)

wellformed :: (Pretty (Var p), MonadError TypeError m) => Type p -> m ()
wellformed tp = case tp of
  TyCon{} -> pure ()
  TyVar{} -> pure ()
  TyStar{} -> pure ()
  TyForall _ t _ -> wellformed t
  TyArr a b _ -> wellformed a *> wellformed b
  TyApp a b _ -> wellformed a *> wellformed b
  TyTuple a b _ -> wellformed a *> wellformed b
  TyRows rho rows _ -> do
    case rho of
      TyRows{} -> pure ()
      TyExactRows{} -> pure ()
      TyVar{} -> pure ()
      _ -> throwError (CanNotInstance tp rho)
    mapM_ (wellformed . snd) rows
  TyExactRows rows _ -> mapM_ (wellformed . snd) rows
  TyCons cs t _ -> mapM wellformedC cs *> wellformed t

wellformedC :: (Pretty (Var p), MonadError TypeError m) => GivenConstraint p -> m ()
wellformedC (Equal a b _) = wellformed a *> wellformed b

improve :: Type Typed -> Type Typed
improve x
  | TyCons cs tp an <- x
  = case (filter (not . redundant) cs) of
      [] -> improve tp
      xs -> TyCons xs (improve tp) an
  | vs <- S.toList (ftv x)
  = runGenFrom (-1) $ do
      fv <- forM vs $ \b -> do
        v <- freshTV (annotation x)
        pure (b, v)
      pure (apply (M.fromList fv) x)
  where redundant (Equal a b _) = raiseT id (const internal) a == raiseT id (const internal) b

{-
   Commentary:

   Surrender all hope, ye who enter here.

   Obviously, this module begs a bit of explaining. Since the kind
   inference engine in Types.Infer isn't usable in Type Typed, here we
   implement a very dumb wellformedness check that will reject
   obviously-wrong types, such as { int | field : type}. Hopefully in
   the future we alleviate the need for this module with a *proper* kind
   system

   Unfortunately, this is the best I can do right now.


   Checks we peform:
    [1] Polymorphic record types' holes may only be instanced to
    something "row-y", i.e. an exact record, another polymorphic record,
    or a type variable. All other instancings are malformed.
     -}

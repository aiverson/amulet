{-# LANGUAGE FlexibleContexts, UndecidableInstances, GADTs #-}
{-# LANGUAGE StandaloneDeriving, OverloadedStrings #-}
module Control.Monad.Infer
  ( module M
  , InferT, Infer
  , TypeError(..)
  , Constraint(..)
  , Env(..)
  , lookupTy, fresh, runInferT, runInfer, extend
  , lookupKind, extendKind
  )
  where

import Control.Monad.Writer.Strict as M hiding ((<>))
import Control.Monad.Reader as M
import Control.Monad.Except as M
import Control.Monad.Identity
import Control.Monad.Gen as M

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Semigroup

import Data.Span (internal)

import qualified Data.Text as T
import Data.Text (Text)

import Pretty hiding (local, (<>))

import Syntax.Subst
import Syntax

type InferT p m = GenT Int (ReaderT Env (WriterT [Constraint p] (ExceptT TypeError m)))
type Infer p = InferT p Identity

data Env
  = Env { values :: Map.Map (Var Parsed) (Type Typed)
        , types  :: Map.Map (Var Parsed) (Type Typed)
        }
  deriving (Eq, Show, Ord)

instance Substitutable Env where
  ftv Env{ values = s } = ftv (Map.elems s)
  apply s env@Env{ values = e} = env { values = Map.map (apply s) e}

instance Monoid Env where
  mappend = (<>)
  mempty = Env mempty mempty

instance Semigroup Env where
  Env a b <> Env a' b' = Env (a `mappend` a') (b `mappend` b')

data Constraint p
  = ConUnify (Expr p) (Type p) (Type p)
deriving instance (Show (Var p), Show (Expr p), Show (Type p)) => Show (Constraint p)

data TypeError where
  NotEqual :: Pretty (Var p) => Type p -> Type p -> TypeError
  Occurs   :: Pretty (Var p) => Var p -> Type p -> TypeError
  NotInScope :: Var Parsed -> TypeError
  EmptyMatch :: Pretty (Ann p) => Expr p -> TypeError
  EmptyBegin :: ( Pretty (Var p)
                , Pretty (Ann p) )
             => Expr p -> TypeError
  FoundHole :: [Expr Typed] -> TypeError
  ArisingFrom :: (Annotated f, Pretty (f p), Pretty (Ann p), Pretty (Var p))
              => TypeError -> f p -> TypeError
  ExpectedArrow :: (Pretty (Var p'), Pretty (Var p))
                => Type p' -> Type p -> Type p -> TypeError
  NoOverlap :: Type Typed -> Type Typed -> TypeError
  Note :: TypeError -> String -> TypeError
  CanNotInstance :: Pretty (Var p)
                 => Type p {- record type -}
                 -> Type p {- instance -}
                 -> TypeError
  Malformed :: Pretty (Var p) => Type p -> TypeError

lookupTy :: (MonadError TypeError m, MonadReader Env m, MonadGen Int m) => Var Parsed -> m (Type Typed)
lookupTy x = do
  rs <- asks (Map.lookup x . values)
  case rs of
    Just t -> instantiate t
    Nothing -> throwError (NotInScope x)

lookupKind :: (MonadError TypeError m, MonadReader Env m) => Var Parsed -> m (Type Typed)
lookupKind x = do
  rs <- asks (Map.lookup x . types)
  case rs of
    Just t -> pure t
    Nothing -> throwError (NotInScope x)

runInfer :: Env -> Infer a b -> Either TypeError (b, [Constraint a])
runInfer ct ac = runExcept (runWriterT (runReaderT (runGenT ac) ct))

runInferT :: Monad m => Env -> InferT a m b -> m (Either TypeError (b, [Constraint a]))
runInferT ct ac = runExceptT (runWriterT (runReaderT (runGenT ac) ct))

fresh :: MonadGen Int m => m Text
fresh = do
  x <- gen
  pure (alpha !! x)

extend :: MonadReader Env m => (Var Typed, Type Typed) -> m a -> m a
extend (v, t) = local (\x -> x { values = Map.insert (eraseVarTy v) t (values x) })

extendKind :: MonadReader Env m => (Var Typed, Type Typed) -> m a -> m a
extendKind (v, t) = local (\x -> x { types = Map.insert (eraseVarTy v) t (types x) })

alpha :: [Text]
alpha = map T.pack $ [1..] >>= flip replicateM ['a'..'z']

instantiate :: MonadGen Int m => Type Typed -> m (Type Typed)
instantiate (TyForall vs ty _) = do
  f <- map (flip TyVar internal)
        <$> mapM (const (flip TvName internalTyVar <$> fresh)) vs
  instantiate (apply (Map.fromList (zip vs f)) ty)
instantiate ty = pure ty

instance Substitutable (Type p) => Substitutable (Constraint p) where
  ftv (ConUnify _ a b) = ftv a `Set.union` ftv b
  apply s (ConUnify e a b) = ConUnify e (apply s a) (apply s b)

instance Pretty (Var p) => Pretty (Constraint p) where
  pprint (ConUnify e a b) = e
                        <+> opClr (" <=> " :: String)
                        <+> a
                        <+> opClr (" ~ " :: String) <+> b



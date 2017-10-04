{-# LANGUAGE FlexibleContexts, GADTs #-}
module Control.Monad.Infer
  ( module M
  , InferT, Infer
  , TypeError(..)
  , Env(..)
  , lookupTy, fresh, runInferT, runInfer, extend
  , lookupKind, extendKind
  )
  where

import Control.Monad.Writer.Strict as M hiding ((<>))
import Control.Monad.Reader as M
import Control.Monad.Except as M
import Control.Monad.Gen as M
import Control.Monad.Identity

import qualified Data.Map.Strict as Map

import Data.Semigroup

import qualified Data.Text as T
import Data.Text (Text)

import Syntax.Subst
import Syntax

import Pretty (prettyPrint, Pretty)

import Text.Printf (printf)

type InferT p m = GenT Int (ReaderT Env (WriterT [Constraint p] (ExceptT TypeError m)))
type Infer p = InferT p Identity

data Env
  = Env { values :: Map.Map (Var 'ParsePhase) (Type 'TypedPhase)
        , types  :: Map.Map (Var 'ParsePhase) (Type 'TypedPhase)
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

data TypeError where
  NotEqual :: Type 'TypedPhase -> Type 'TypedPhase -> TypeError
  Occurs :: Var 'TypedPhase -> Type 'TypedPhase -> TypeError
  NotInScope :: Var 'ParsePhase -> TypeError
  EmptyMatch :: Expr 'ParsePhase -> TypeError
  EmptyBegin :: Expr 'ParsePhase -> TypeError
  EmptyMultiWayIf :: Expr 'ParsePhase -> TypeError
  ArisingFrom :: (Pretty (Ann p), Pretty (Var p))
              => TypeError -> Expr p -> TypeError
  ExpectedArrow :: Pretty (Var p) => Type p -> TypeError

lookupTy :: (MonadError TypeError m, MonadReader Env m, MonadGen Int m) => Var 'ParsePhase -> m (Type 'TypedPhase)
lookupTy x = do
  rs <- asks (Map.lookup x . values)
  case rs of
    Just t -> instantiate t
    Nothing -> throwError (NotInScope x)

lookupKind :: (MonadError TypeError m, MonadReader Env m) => Var 'ParsePhase -> m (Type 'TypedPhase)
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

extend :: MonadReader Env m => (Var 'TypedPhase, Type 'TypedPhase) -> m a -> m a
extend (v, t) = local (\x -> x { values = Map.insert (lowerVar v) t (values x) })

extendKind :: MonadReader Env m => (Var 'TypedPhase, Type 'TypedPhase) -> m a -> m a
extendKind (v, t) = local (\x -> x { types = Map.insert (lowerVar v) t (types x) })

alpha :: [Text]
alpha = map T.pack $ [1..] >>= flip replicateM ['a'..'z']

instantiate :: MonadGen Int m => Type 'TypedPhase -> m (Type 'TypedPhase)
instantiate (TyForall vs _ ty) = do
  f <- map TyVar <$> mapM (const (flip TvName internalTyVar <$> fresh)) vs
  instantiate (apply (Map.fromList (zip vs f)) ty)
instantiate ty = pure ty

lowerVar :: Var 'TypedPhase -> Var 'ParsePhase
lowerVar (TvName x _) = Name x
lowerVar (TvRefresh k _) = lowerVar k

instance Show TypeError where
  show (NotEqual a b) = printf "Type error: failed to unify `%s` with `%s`" (prettyPrint a) (prettyPrint b)
  show (Occurs v t) = printf "Occurs check: Variable `%s` occurs in `%s`" (prettyPrint v) (prettyPrint t)
  show (NotInScope e) = printf "Variable not in scope: `%s`" (prettyPrint e)
  show (EmptyMatch e) = printf "Empty match expression:\n%s" (prettyPrint e)
  show (EmptyBegin v) = printf "%s: Empty match expression" (prettyPrint (extract v))
  show (EmptyMultiWayIf v) = printf "Empty multi-way if expression" (prettyPrint (extract v))

  show (ArisingFrom t v) = printf "%s: %s\n · Arising from use of `%s`" (prettyPrint (extract v)) (show t) (prettyPrint v)
  show (ExpectedArrow a) = printf "Kind error: expected `type -> k`, but got `%s`" (prettyPrint a)


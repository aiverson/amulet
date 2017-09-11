{-# LANGUAGE FlexibleContexts #-}
module Types.Infer where

import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Control.Monad.Infer
import Control.Arrow

import Syntax.Subst
import Syntax

import Types.Unify

-- Solve for the types of lets in a program
inferProgram :: [Toplevel] -> Either TypeError Env
inferProgram ct = fst <$> runInfer builtinsEnv (inferProg ct)

tyBool, tyInt, tyString :: Type
tyInt = TyCon (Name "int")
tyString = TyCon (Name "string")
tyBool = TyCon (Name "bool")

builtinsEnv :: Env
builtinsEnv = Env (M.fromList ops) (M.fromList tps) where
  op x t = (Name x, t)
  tp x = (Name x, KiType)
  intOp = tyInt `TyArr` (tyInt `TyArr` tyInt)
  stringOp = tyString `TyArr` (tyString `TyArr` tyString)
  intCmp = tyInt `TyArr` (tyInt `TyArr` tyBool)
  cmp = TyForall ["a"] [] $ TyVar "a" `TyArr` (TyVar "a" `TyArr` tyBool)
  ops = [ op "+" intOp, op "-" intOp, op "*" intOp, op "/" intOp, op "**" intOp
        , op "^" stringOp
        , op "<" intCmp, op ">" intCmp, op ">=" intCmp, op "<=" intCmp
        , op "==" cmp, op "<>" cmp ]
  tps = [ tp "int", tp "string", tp "bool" ]

unify :: Expr ->  Type -> Type -> InferM ()
unify e a b = tell [ConUnify e a b]

infer :: Expr -> InferM Type
infer expr
  = case expr of
      VarRef k -> lookupTy k
      Literal c -> case c of
                     LiInt _ -> pure tyInt
                     LiStr _ -> pure tyString
                     LiBool _ -> pure tyBool
      Fun p b -> do
        (tc, ms) <- inferPattern p
        tb <- extendMany ms $ infer b
        pure (TyArr tc tb)
      Begin [] -> throwError EmptyBegin
      Begin xs -> last <$> mapM infer xs
      If c t e -> do
        (tc, tt, te) <- (,,) <$> infer c <*> infer t <*> infer e
        unify c tyBool tc
        unify expr tt te
        pure te
      App e1 e2 -> do
        (t1, t2, tv) <- (,,) <$> infer e1 <*> infer e2 <*> (TyVar <$> fresh)
        unify expr t1 (TyArr t2 tv)
        pure tv
      Let ns b -> do
        ks <- forM ns $ \(a, _) -> do
          tv <- TyVar <$> fresh
          pure (a, tv)
        -- We add each binding to scope with a fresh type variable
        extendMany ks $ do
          -- Then infer the actual types
          ts <- forM ns $ \(a, t) -> do
            t <- infer t
            pure (a, t)
          -- And finally infer the body
          extendMany ts (infer b)
      Match t ps -> do
        tt <- infer t
        tbs <- forM ps $ \(p, e) -> do
          (pt, ks) <- inferPattern p
          unify expr tt pt
          extendMany ks $ infer e
        case tbs of
          [] -> throwError (EmptyMatch (Match t ps))
          [x] -> pure x
          (x:xs) -> do
            mapM_ (unify expr x) xs
            pure x
      BinOp l o r -> do
        infer (App (App o l) r)

inferKind :: Type -> InferM Kind
inferKind (TyVar v) = lookupKind (Name v) `catchError` const (pure KiType)
inferKind (TyCon v) = lookupKind v
inferKind (TyForall vs _ k) = extendManyK (zip (map Name vs) (repeat KiType)) $ inferKind k
inferKind (TyArr a b) = do
  _ <- inferKind a
  _ <- inferKind b
  pure KiType
inferKind (TyApp a b) = do
  x <- inferKind a
  case x of
    KiArr t bd -> do
      xb <- inferKind b
      when (t /= xb) $ throwError (KindsNotEqual t xb)
      pure bd
    _ -> throwError (ExpectedArrowKind x)

-- Returns: Type of the overall thing * type of captures
inferPattern :: Pattern -> InferM (Type, [(Var, Type)])
inferPattern Wildcard = do
  x <- TyVar <$> fresh
  pure (x, [])
inferPattern (Capture v) = do
  x <- TyVar <$> fresh
  pure (x, [(v, x)])

inferProg :: [Toplevel] -> InferM Env
inferProg (LetStmt ns:prg) = do
  ks <- forM ns $ \(a, _) -> do
    tv <- TyVar <$> fresh
    pure (a, tv)
  extendMany ks $ do
    ts <- forM ns $ \(a, t) -> do
      -- We need the normalised, generalised type
      (ty, c) <- censor (const mempty) (listen (infer t))
      case solve mempty c of
        Left e -> throwError e
        Right x -> let ty' = apply x ty
                    in do
                      _ <- inferKind ty'
                      pure (a, ty')
    extendMany ts (inferProg prg)
inferProg (ValStmt v t:prg) = extend (v, t) $ inferProg prg
inferProg (ForeignVal v _ t:prg) = extend (v, t) $ inferProg prg
inferProg (TypeDecl n tvs cs:prg) =
  let mkk [] = KiType
      mkk (_:xs) = KiArr KiType (mkk xs)
      mkt [] = foldl TyApp (TyCon n) (TyVar <$> tvs)
      mkt (x:xs) = TyArr x (mkt xs)
   in extendKind (n, mkk tvs) $
      extendMany (map (second mkt) cs) $
        inferProg prg
inferProg [] = ask

extendMany :: MonadReader Env m => [(Var, Type)] -> m a -> m a
extendMany ((v, t):xs) b = extend (v, t) $ extendMany xs b
extendMany [] b = b

extendManyK :: MonadReader Env m => [(Var, Kind)] -> m a -> m a
extendManyK ((v, t):xs) b = extendKind (v, t) $ extendManyK xs b
extendManyK [] b = b

closeOver :: Type -> Type
closeOver a = forall fv a where
  fv = S.toList . ftv $ a
  forall [] a = a
  forall vs a = TyForall vs [] a

instantiate :: Type -> InferM Type
instantiate = undefined

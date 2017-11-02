{-# OPTIONS_GHC -Wno-missing-local-signatures #-}
{-# LANGUAGE FlexibleContexts, OverloadedStrings, TupleSections, GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Types.Infer (inferProgram, builtinsEnv) where

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Set as S

import Data.Semigroup ((<>))

import Data.Spanned
import Data.Span (internal, Span)

import Control.Monad.Infer
import Control.Arrow (first)

import Syntax.Subst
import Syntax.Raise
import Syntax

import Types.Wellformed
import Types.Unify
import Types.Holes

import Data.List
import Debug.Trace(trace, traceShowId)

-- Solve for the types of lets in a program
inferProgram :: [Toplevel Parsed] -> Either TypeError ([Toplevel Typed], Env)
inferProgram ct = fst <$> runInfer builtinsEnv (inferAndCheck ct) where
  inferAndCheck prg = do
    (prg', env) <- inferProg prg
    case findHoles prg' of
      xs@(_:_) -> throwError (FoundHole xs)
      [] -> pure (prg', env)

tyUnit, tyBool, tyInt, tyString :: Type Typed
tyInt = TyCon (TvName Rigid "int" (TyStar internal)) internal
tyString = TyCon (TvName Rigid "string" (TyStar internal)) internal
tyBool = TyCon (TvName Rigid "bool" (TyStar internal)) internal
tyUnit = TyCon (TvName Rigid "unit" (TyStar internal)) internal

star :: Ann p ~ Span => Type p
star = TyStar internal

forall :: Ann p ~ Span => [Var p] -> Type p -> Type p
forall a c = TyForall a c internal

app, arr :: Ann p ~ Span => Type p -> Type p -> Type p
arr a b = TyArr a b internal
app a b = TyApp a b internal

var, con :: Ann p ~ Span => Var p -> Type p
var x = TyVar x internal
con x = TyCon x internal

builtinsEnv :: Env
builtinsEnv = Env (M.fromList ops) (M.fromList tps) where
  op :: T.Text -> Type Typed -> (Var Parsed, Type Typed)
  op x t = (Name x, t)
  tp :: T.Text -> (Var Parsed, Type Typed)
  tp x = (Name x, star)

  intOp = tyInt `arr` (tyInt `arr` tyInt)
  stringOp = tyString `arr` (tyString `arr` tyString)
  intCmp = tyInt `arr` (tyInt `arr` tyBool)

  cmp = forall [TvName Flexible "a" star] $ var (TvName Flexible "a" star) `arr` (var (TvName Flexible "a" star) `arr` tyBool)
  ops = [ op "+" intOp, op "-" intOp, op "*" intOp, op "/" intOp, op "**" intOp
        , op "^" stringOp
        , op "<" intCmp, op ">" intCmp, op ">=" intCmp, op "<=" intCmp
        , op "==" cmp, op "<>" cmp ]
  tps :: [(Var Parsed, Type Typed)]
  tps = [ tp "int", tp "string", tp "bool", tp "unit" ]

unify :: Expr Parsed -> Type Typed -> Type Typed -> Infer Typed ()
unify e a b = tell [ConUnify (raiseE (`tag` internalTyVar) id e) a b]

tag :: Var Parsed -> Type Typed -> Var Typed
tag (Name v) t = TvName Flexible v t
tag (Refresh k a) t = TvRefresh (tag k t) a

infer :: Expr Parsed -> Infer Typed (Expr Typed, Type Typed)
infer expr
  = case expr of
      VarRef k a -> do
        x <- lookupTy k
        pure (VarRef (tag k x) a, x)
      Hole v ann -> do
        tv <- freshTV ann
        pure (Hole (tag v tv) ann, tv)
      Literal c a -> case c of
                       LiInt _ -> pure (Literal c a, tyInt)
                       LiStr _ -> pure (Literal c a, tyString)
                       LiBool _ -> pure (Literal c a, tyBool)
                       LiUnit   -> pure (Literal c a, tyUnit)
      Fun p b a -> do
        (p', tc, ms) <- inferPattern (unify expr) p
        (b', tb) <- extendMany ms $ infer b
        pure (Fun p' b' a, TyArr tc tb a)
      Begin [] _ -> throwError (EmptyBegin expr)
      Begin xs a -> do
        (xs', txs) <- unzip <$> mapM infer xs
        pure (Begin xs' a, last txs)
      If c t e a -> do
        (c', tc) <- infer c
        (t', tt) <- infer t
        (e', te) <- infer e
        unify c tyBool tc
        unify expr tt te
        pure (If c' t' e' a, te)
      App e1 e2 a -> do
        (e1', t1) <- infer e1
        (e2', t2) <- infer e2
        tv <- freshTV (annotation e1 <> annotation e2)
        unify expr t1 (TyArr t2 tv (annotation t1 <> annotation t2))
        pure (App e1' e2' a, tv)
      Let ns b ann -> do
        ks <- forM ns $ \(a, _) -> do
          tv <- freshTV ann
          pure (tag a tv, tv)
        extendMany ks $ do
          (ns', ts) <- inferLetTy ks ns
          (b', ty) <- extendMany ts (infer b)
          pure (Let ns' b' ann, ty)
      Match t ps a -> do
        (t', tt) <- infer t
        (ps', tbs) <- unzip <$> forM ps
            (\ (p, e) ->
               do (p', pt, ks) <- inferPattern (unify expr) p
                  unify expr tt pt
                  (e', ty) <- extendMany ks (infer e)
                  pure ((p', e'), ty))
        ty <- case tbs of
                [] -> throwError (EmptyMatch expr)
                [x] -> pure x
                (ty:xs) -> do
                  mapM_ (unify expr ty) xs
                  pure ty
        pure (Match t' ps' a, ty)
      BinOp l o r a -> do
        (l', tl) <- infer l
        (o', to) <- infer o
        (r', tr) <- infer r
        tv <- freshTV a
        unify expr to (TyArr tl (TyArr tr tv a) a)
        pure (BinOp l' o' r' a, tv)
      Record rows a -> do
        itps <- inferRows rows
        let (rows', rowts) = unzip itps
        pure (Record rows' a, TyExactRows rowts a)
      RecordExt rec rows a -> do
        itps <- inferRows rows
        let (rows', newTypes) = unzip itps
        (rec', rho) <- infer rec
        pure (RecordExt rec' rows' a, TyRows rho newTypes a)
      Access rec key a -> do
        (rho, ktp) <- (,) <$> freshTV a <*> freshTV a
        (rec', tp) <- infer rec
        let rows = TyRows rho [(key, ktp)] a
        unify expr tp rows
        pure (Access rec' key a, ktp)
      Tuple es an -> do
        es' <- mapM infer es
        case es' of
          [] -> pure (Tuple [] an, tyUnit)
          [(x', t)] -> pure (x', t)
          ((x', t):xs) -> pure (Tuple (x':map fst xs) an, mkTupleType an t (map snd xs))
      EHasType e g an -> do
        (e', t') <- infer e
        (g', _) <- inferKind g
        unify expr g' t'
        pure (EHasType e' t' an, t')
      LeftSection{} -> error "desugarer removes right sections"
      RightSection{} -> error "desugarer removes left sections"
      BothSection{} -> error "desugarer removes both-side sections"
      AccessSection{} -> error "desugarer removes access sections"

mkTupleType :: Foldable t => Ann p -> Type p -> t (Type p) -> Type p
mkTupleType an = foldl (\x y -> TyTuple x y an)

inferRows :: [(T.Text, Expr Parsed)] -> Infer Typed [((T.Text, Expr Typed), (T.Text, Type Typed))]
inferRows rows = forM rows $ \(var', val) -> do
  (val', typ) <- infer val
  pure ((var', val'), (var', typ))

freshTV :: MonadGen Int m => Span -> m (Type Typed)
freshTV a = do
  nm <- fresh
  pure (TyVar (TvName Flexible nm (TyStar a)) a)

inferKind :: Type Parsed -> Infer a (Type Typed, Type Typed)
inferKind (TyStar a) = pure (TyStar a, TyStar a)
inferKind (TyVar v a) = do
  x <- lookupKind v `catchError` const (pure (TyStar a))
  pure (TyVar (tag v x) a, x)
inferKind (TyCon v a) = do
  x <- lookupKind v
  pure (TyCon (tag v x) a, x)
inferKind (TyForall vs k a) = do
  (k, t') <- extendManyK (zip (map (`tag` TyStar a) vs) (repeat (TyStar a))) $
    inferKind k
  pure (TyForall (map (`tag` TyStar a) vs) k a, t')
inferKind (TyArr a b ann) = do
  (a', ka) <- inferKind a
  (b', kb) <- inferKind b
  -- TODO: A "proper" unification system
  when (ka /= TyStar (annotation ka)) $ throwError (NotEqual ka (TyStar ann))
  when (kb /= TyStar (annotation kb)) $ throwError (NotEqual kb (TyStar ann))
  pure (TyArr a' b' ann, TyStar ann)
inferKind tp@(TyRows rho rows ann) = do
  wellformed tp
  case rho of
    TyRows rho' rows' ann' -> inferKind (TyRows rho' (rows' `union` rows) ann')
    TyExactRows rows' ann' -> inferKind (TyExactRows (rows' `union` rows) ann')
    TyVar{} -> do
      (rho', _) <- inferKind rho
      ks <- forM rows $ \(var, typ) -> do
        (typ', _) <- inferKind typ
        pure (var, typ')
      pure (TyRows rho' ks ann, TyStar ann)
    _ -> error "wellformedness check rejects this"
inferKind (TyExactRows rows ann) = do
  ks <- forM rows $ \(var, typ) -> do
    (typ', _) <- inferKind typ
    pure (var, typ')
  pure (TyExactRows ks ann, TyStar ann)
inferKind ap@(TyApp a b ann) = do
  (a', x) <- inferKind a
  case x of
    TyArr t bd _ -> do
      (b', xb) <- inferKind b
      when (crush t /= crush xb) $ throwError (NotEqual t xb)
      pure (TyApp a' b' ann, bd)
    _ -> throwError (ExpectedArrow ap x a')
  where crush = raiseT smush (const internal)
inferKind (TyTuple a b an) = do
  (a', _) <- inferKind a
  (b', _) <- inferKind b
  pure (TyTuple a' b' an, TyStar an)
inferKind (TyCons cs b an) = do
  cs' <- forM cs $ \(Equal ta tb an) -> do
    (ta', _) <- inferKind ta
    (tb', _) <- inferKind tb
    pure (Equal ta' tb' an)
  (b', k) <- inferKind b
  pure (TyCons cs' b' an, k)

-- Returns: Type of the overall thing * type of captures
inferPattern :: (Type Typed -> Type Typed -> Infer a ())
             -> Pattern Parsed
             -> Infer a (Pattern Typed, Type Typed, [(Var Typed, Type Typed)])
inferPattern _ (Wildcard ann) = do
  x <- freshTV ann
  pure (Wildcard ann, x, [])
inferPattern _ (Capture v ann) = do
  x <- freshTV ann
  pure (Capture (tag v x) ann, x, [(tag v x, x)])
inferPattern unify (Destructure cns ps ann)
  | Nothing <- ps
  = do
    pty <- lookupTy cns
    pure (Destructure (tag cns pty) Nothing ann, pty, [])
  | Just p <- ps
  = do
    t <- lookupTy cns
    case t of
      (TyArr tup res _) -> do
        (p', pt, pb) <- inferPattern unify p
        unify tup pt
        pure (Destructure (tag cns t) (Just p') ann, res, pb)
      (TyCons cs (TyArr tup res _) an) -> do
        (p', pt, pb) <- inferPattern unify p
        unify tup pt
        pure (Destructure (tag cns t) (Just p') ann, (TyCons cs res an), pb)
      _ -> undefined
inferPattern unify (PRecord rows ann) = do
  rho <- freshTV ann
  (rowps, rowts, caps) <- unzip3 <$> forM rows (\(var, pat) -> do
    (p', t, caps) <- inferPattern unify pat
    pure ((var, p'), (var, t), caps))
  pure (PRecord rowps ann, TyRows rho rowts ann, concat caps)
inferPattern unify (PType p t ann) = do
  (p', pt, vs) <- inferPattern unify p
  (t', _) <- inferKind t `catchError` \x -> throwError (ArisingFrom x t)
  unify pt t'
  pure (PType p' t' ann, pt, vs)
inferPattern unify (PTuple elems ann)
  | [] <- elems = pure (PTuple [] ann, tyUnit, [])
  | [x] <- elems = inferPattern unify x
  | otherwise = do
    (ps, t:ts, cps) <- unzip3 <$> mapM (inferPattern unify) elems
    pure (PTuple ps ann, mkTupleType ann t ts, concat cps)

inferProg :: [Toplevel Parsed] -> Infer Typed ([Toplevel Typed], Env)
inferProg (LetStmt ns ann:prg) = do
  ks <- forM ns $ \(a, _) -> do
    tv <- freshTV ann
    vl <- lookupTy a `catchError` const (pure tv)
    pure (tag a tv, vl)
  extendMany ks $ do
    (ns', ts) <- inferLetTy ks ns
    extendMany ts $
      consFst (LetStmt ns' ann) $ inferProg prg
inferProg (ValStmt v t ann:prg) = do
  (t', _) <- inferKind t `catchError` \x -> throwError (ArisingFrom x t)
  extend (tag v t', closeOver t') $
    consFst (ValStmt (tag v t') t' ann) $ inferProg prg
inferProg (ForeignVal v d t ann:prg) = do
  (t', _) <- inferKind t
  extend (tag v t', closeOver t') $
    consFst (ForeignVal (tag v t') d t' ann) $ inferProg prg
inferProg (TypeDecl n tvs cs ann:prg) =
  let mkk :: [a] -> Type Typed
      mkk [] = star
      mkk (_:xs) = arr star (mkk xs)
      retTy = foldl app (con (n `tag` star)) (map (var . flip tag star) tvs)
      n' = tag n (mkk tvs)
      arisingFromConstructor = "Perhaps you're missing a * between two types of a constructor?"
   in extendKind (n', mkk tvs) $ do
     (ts, cs') <- unzip <$> mapM (inferCon retTy) cs
                               `catchError` \x -> throwError (Note (ArisingFrom x (TyVar n' ann)) arisingFromConstructor)
     extendMany ts $
       consFst (TypeDecl n' (map (`tag` star) tvs) cs' ann) $
         inferProg prg
inferProg [] = do
  let ann = internal
  (_, c) <- censor (const mempty) . listen $ do
    x <- lookupTy (Name "main")
    unify (VarRef (Name "main") ann) x (TyArr tyUnit tyUnit ann)
  x <- gen
  case solve x mempty c of
    Left e -> throwError (Note e "main must be a function from unit to unit")
    Right _ -> ([],) <$> ask

inferCon :: Type Typed
         -> Constructor Parsed
         -> Infer Typed ( (Var Typed, Type Typed)
                        , Constructor Typed)
inferCon ret (ArgCon nm ty ann) = do
  (ty', _) <- inferKind ty
  pure ((tag nm (TyArr ty' ret ann), TyArr ty' ret ann), ArgCon (tag nm ty') ty' ann)
inferCon ret (UnitCon nm ann) = pure ((tag nm ret, ret), UnitCon (tag nm ret) ann)
inferCon ret (GADTCon nm ty ann) = do
  res <- case ty of
    x | x `instanceOf` ret -> pure x
    TyArr _ b _ | b `instanceOf` ret -> pure b
    x -> throwError (IllegalGADT x)
  -- This is a game of matching up paramters of the return type with the
  -- stated parameters, and introducing the proper constraints
  let given = map (raiseT id (const internal)) (instanceArgs res)
      assumed = instanceArgs ret
  given' <- mapM (\x -> fst <$> inferKind x) given
  (ty', _) <- inferKind ty
  let cons = zipWith (\x y -> Equal x y ann) assumed given'
      res' = foldl (\x y -> TyApp x y ann) (raiseT (flip tag star) id (instanceCon res)) assumed
      ty'' = case ty' of
               TyArr a _ p -> TyArr a res' p
               _ -> res'
      TyForall vars tp _ = closeOver (TyCons cons ty'' ann)
      final = TyForall (map (rigidify assumed) vars) tp ann
  pure ((tag nm final, final), GADTCon (tag nm final) final ann)

rigidify :: [Type Typed] -> Var Typed -> Var Typed
rigidify vs t = go (map getTv vs) t where
  getTv (TyVar (TvName _ v _) _) = v
  getTv _ = undefined
  go xs (TvName _ nm t)
    | nm `notElem` xs = trace "rigid" (traceShowId (TvName Rigid nm t))
    | otherwise = trace "flexible" (traceShowId (TvName Flexible nm t))
  -- Problem: Things are being rigidified when they shouldn't. E.g.:
  -- type box 'a = Box : 'a -> box 'a
  -- Leads to the introduction of a fresh type variable 'b(??) which is
  -- rigid. What the fuck?

instanceOf :: Type Parsed -> Type Typed -> Bool
instanceOf (TyCon a _) (TyCon b _) = a == eraseVarTy b
instanceOf (TyApp a _ _) (TyApp b _ _) = a `instanceOf` b
instanceOf _ _ = False

instanceArgs :: Type p -> [Type p]
instanceArgs (TyCon _ _) = []
instanceArgs (TyApp i b _) = instanceArgs i ++ [b]
instanceArgs _ = undefined

instanceCon :: Type p -> Type p
instanceCon x@TyCon{} = x
instanceCon (TyApp x _ _) = instanceCon x
instanceCon _ = undefined

inferLetTy :: (t ~ Typed, p ~ Parsed)
           => [(Var t, Type t)]
           -> [(Var p, Expr p)]
           -> Infer t ( [(Var t, Expr t)]
                      , [(Var t, Type t)])
inferLetTy ks [] = pure ([], ks)
inferLetTy ks ((va, ve):xs) = extendMany ks $ do
  ((ve', ty), c) <- censor (const mempty) (listen (infer ve))
  cur <- gen
  (x, vt) <- case solve cur mempty c of
               Left e -> throwError e
               Right x -> pure (x, closeOver (apply x ty))
  let r (TvName r n t) = TvName r n (apply x t)
      r (TvRefresh k a) = TvRefresh (r k) a
      ex = raiseE r id ve'
  (vt', _) <- inferKind (raiseT eraseVarTy id vt)
  consFst (tag va vt', ex) $ inferLetTy (updateAlist (tag va vt') vt' ks) xs

-- Monomorphic so we can use "close enough" equality
updateAlist :: Var Typed
            -> b
            -> [(Var Typed, b)] -> [(Var Typed, b)]
updateAlist n v (x@(n', _):xs)
  | n == n' = (n, v):updateAlist n v xs
  | n `closeEnough` n' = (n, v):updateAlist n v xs
  | otherwise = x:updateAlist n v xs
updateAlist _ _ [] = []

closeOver :: Type Typed -> Type Typed
closeOver a = forall (fv a) (improve a) where
  fv = S.toList . ftv . improve
  forall :: (Ann p ~ Span, Spanned (Type p))
         => [Var p] -> Type p -> Type p
  forall [] a = a
  forall vs a = TyForall vs a (annotation a)

  improve :: Type Typed -> Type Typed
  improve x
    | vs <- S.toList (ftv x)
    = runGenFrom (-1) $ do
      fv <- forM vs $ \b -> do
        v <- freshTV (annotation x)
        pure (b, v)
      pure (apply (M.fromList fv) x)

consFst :: Functor m => a -> m ([a], b) -> m ([a], b)
consFst a = fmap (first (a:))

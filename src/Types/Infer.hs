{-# LANGUAGE FlexibleContexts, TupleSections, ScopedTypeVariables,
   ViewPatterns, LambdaCase, TypeFamilies, CPP, UndecidableInstances #-}
module Types.Infer
  ( inferProgram, inferExpr
  , closeOver

  , infer, check, solveEx
  , instantiateTc, infer'
  ) where

import Prelude

import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Data.Set as Set
import Data.Traversable
import Data.Spanned
import Data.Reason
import Data.Triple
import Data.Maybe
import Data.These

import Control.Monad.State
import Control.Monad.Infer
import Control.Arrow (first)
import Control.Lens

import Syntax.Implicits
import Syntax.Transform
import Syntax.Builtin
import Syntax.Value
import Syntax.Subst
import Syntax.Types
import Syntax.Var
import Syntax

import Types.Infer.Constructor
import Types.Infer.Function
import Types.Infer.Pattern
import Types.Infer.Builtin
import Types.Infer.Class
import Types.Infer.App
import Types.Infer.Let
import Types.Kinds
import Types.Unify

import Text.Pretty.Semantic
import Text.Pretty.Note

import Types.Unify.Trace

-- | Solve for the types of bindings in a problem: Either @TypeDecl@s,
-- @LetStmt@s, or @ForeignVal@s.
inferProgram :: MonadNamey m => Env -> [Toplevel Desugared] -> m (These [TypeError] ([Toplevel Typed], Env))
inferProgram env ct = fmap fst <$> runInfer env (go ct) where
  go :: MonadInfer Typed m => [Toplevel Desugared] -> m ([Toplevel Typed], Env)
  go ct = do
    ((p, env), cs) <- listen $ inferProg ct
    _ <- solveFixpoint (It'sThis (BecauseInternal "last round of solving")) (onlyDeferred cs) =<< getSolveInfo
    pure (p, env & declaredHere .~ mempty)


-- | Infer the type of a single expression, including any residual
-- constraints as context in the resulting type, generalise over it, and
-- 'rename' it to make it prettier.
--
-- Used in the REPL.
inferExpr :: MonadNamey m => Env -> Expr Desugared -> m (These [TypeError] (Type Typed))
inferExpr env exp = fmap fst <$> runInfer env (inferOne exp) where
  inferOne :: forall m. MonadInfer Typed m => Expr Desugared -> m (Type Typed)
  inferOne expr = do
    ((expr, ty), cs) <- listen $ infer expr
    (sub, _, deferred) <- condemn $ retcons (addBlame (becauseExp expr)) $ solve cs =<< getSolveInfo
    deferred <- pure (fmap (apply sub) deferred)
    (compose sub -> sub, _, cons) <- condemn $ solve (Seq.fromList deferred) =<< getSolveInfo
    (context, _, _, compose sub -> sub) <- reduceClassContext mempty (spanOf expr) cons

    vt <- closeOverStrat (becauseExp expr) mempty expr (apply sub (context ty))
    pure (fst (rename vt))

-- | Check an 'Expr'ession against a known 'Type', annotating it with
-- appropriate 'Wrapper's, and performing /some/ level of desugaring.
check :: forall m. MonadInfer Typed m => Expr Desugared -> Type Typed -> m (Expr Typed)
check e t | trace TcC (keyword "Γ ⊢" <+> pretty e <+> soperator (char '↓') <+> pretty t) False = undefined
check e oty@TyPi{} | isSkolemisable oty = do
  let reason = BecauseOf e

  (wrap, ty, scope, vs) <- skolemise (ByAscription (spanOf e) oty) oty

  when (not (value e) && scope == mempty) $
    dictates (addBlame reason (NotValue reason oty))


  tvs <- view typeVars
  local (classes %~ mappend scope) $ do
    (e, cs) <- censor (const mempty) . listen . local (typeVars %~ Set.union (Set.fromList (map fst vs))) $ check e ty
    (_, as) <- censor (const mempty) . listen . for vs $ \(a, b) ->
      unless (Set.member a tvs) $
        () <$ unify (becauseExp e) (TyVar a ()) b

    tell (Seq.singleton (ConImplies reason tyUnit as cs))
    pure (ExprWrapper wrap e (spanOf e, oty))

check (Hole v a) t = do
  env <- ask
  tell (Seq.singleton (ConFail env (a, t) v t))
  pure (Hole v (a, t))

check (Let re ns b an) t = do
  (ns, ts, vars) <-
    inferLetTy localGenStrat Propagate ns
      `catchChronicle` \e -> do
        tell (DeferredError <$> e)
        fakeLetTys ns

  let bvs = Set.fromList (namesInScope (focus ts mempty))

  local (typeVars %~ Set.union vars) $
    local (letBound %~ Set.union bvs) $
      local (names %~ focus ts) $ do
        b <- check b t
        pure (Let re ns b (an, t))

check ex@(Fun pat e an) ty = do
  (dom, cod, _) <- quantifier (becauseExp ex) (/= Req) ty
  let domain = _tyBinderType dom

  (p, vs, cs, is) <- checkParameter pat domain
  let tvs = boundTvs (p ^. paramPat) vs

  implies (Arm (pat ^. paramPat) Nothing e an) domain cs $
    case dom of
      Anon{} -> do
        traceM TcB (shown vs)
        e <- local (typeVars %~ Set.union tvs) . local (names %~ focus vs) . local (classes %~ mappend is) $
          check e cod
        pure (Fun p e (an, ty))
      _ -> error "invalid quantifier in check Fun"

check (If c t e an) ty = If <$> check c tyBool <*> check t ty <*> check e ty <*> pure (an, ty)

check (Match t ps p a) ty = do
  tt <-
    case ps of
      (Arm p _ _ _:_) -> view _2 <$> inferPattern p
      _ -> view _2 <$> infer t
  t <- check t tt

  ps <- for ps $ \(Arm p g e a) -> do
    (p', ms, cs, is) <- checkPattern p tt
    let tvs = boundTvs p' ms

    implies (Arm p g e a) tt cs
      . local (typeVars %~ Set.union tvs)
      . local (names %~ focus ms)
      . local (classes %~ mappend is)
      $ do
        g' <- traverse (`check` tyBool) g
        e' <- check e ty
        pure (Arm p' g' e' a)
  pure (Match t ps p (a, ty))

check e@(Access rc key a) ty = do
  rho <- freshTV
  rc <- censor (rereason (becauseExp e)) $
    check rc (TyRows rho [(key, ty)])
  pure (Access rc key (a, ty))

check ex@(ListExp es an) t@(TyApp f x) | f == tyList = do
  w <- unify (becauseExp ex) f tyList
  es <- traverse (`check` x) es

  pure (ExprWrapper w (buildList an x es) (an, t))

check ex@(MLet bindv pat expr body an) wanted = do
  let reason = becauseExp ex
      bind = VarRef bindv an
      bind :: Expr Desugared
  (bind, bind_t) <- infer bind

  ~(Anon action_t, c1, w1) <- quantifier reason (/= Req) bind_t
  expr <- check expr action_t

  ~(Anon cont_t, res, w2)    <- quantifier reason (/= Req) c1
  cont_a <- freshTV
  w3 <- subsumes reason (cont_a :-> wanted) cont_t

  (pat', ms, cs, is) <- checkPattern pat cont_a
  let tvs = boundTvs pat' ms

  body <- implies (Arm pat Nothing body an) cont_a cs
        . local (typeVars %~ Set.union tvs)
        . local (names %~ focus ms)
        . local (classes %~ mappend is)
        $ check body wanted

  pure
    (App
      (w2 (App (w1 bind) expr (an, c1)))
      (ExprWrapper w3
        (Fun (PatParam pat')
          body
          (an, TyArr cont_a wanted))
        (an, cont_t))
      (an, res))

-- This is _very_ annoying, but we need it for nested ascriptions
check ex@(Ascription e ty an) goal = do
  ty <- expandType =<< resolveKind (becauseExp ex) ty
  e <- check e ty
  -- here: have ty (given)
  --       want goal (given)
  c <- subsumes (becauseExp ex) ty goal
  pure (ExprWrapper c e (an, goal))

check ex@App{} expected = fst <$> inferApps ex (pure expected)
check ex@Vta{} expected = fst <$> inferApps ex (pure expected)

check (Parens e _) ty = check e ty

check AccessSection{} tau =
  error $ "check AccessSection : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"
check RightSection{} tau =
  error $ "check RightSection : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"
check LeftSection{} tau =
  error $ "check LeftSection : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"
check BothSection{} tau =
  error $ "check BothSection : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"
check TupleSection{} tau =
  error $ "check TupleSection : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"
check Syntax.Lazy{} tau =
  error $ "check Syntax.Lazy : " ++ displayS (pretty tau) ++ " in TC (desugar didn't run?)"

check e ty = do
  (e', t) <- infer e
  -- here: have t (inferred)
  --       want ty (given)
  c <- subsumes (becauseExp e) t ty
  pure (ExprWrapper c e' (spanOf e, ty))

-- [Complete and Easy]: See https://www.cl.cam.ac.uk/~nk480/bidir.pdf

-- | Infer a 'Type' for an 'Expr'ession provided no other information
-- than the environment, producing an 'Expr'ession annotated with
-- 'Wrapper's where nescessary.
infer :: MonadInfer Typed m => Expr Desugared -> m (Expr Typed, Type Typed)

infer e | trace TcI (keyword "Γ ⊢" <+> pretty e <+> soperator (char '↑')) False = undefined

infer (VarRef k a) = do
  (cont, old, (new, cont')) <- third3A (discharge (VarRef k a :: Expr Desugared)) =<< lookupTy' Strong k
  old <- expandType old
  case cont of
    Nothing -> pure (VarRef k (a, old), old)
    Just cont -> do
      new <- expandType new
      pure (cont' (cont (VarRef k (a, old))), new)

infer (Fun (view paramPat -> p) e an) = do
  (p, dom, ms, cs, is) <- inferPattern p
  let tvs = boundTvs p ms

  _ <- leakEqualities p cs

  (e, cod) <- local (typeVars %~ Set.union tvs) . local (classes %~ mappend is) $
    local (names %~ focus ms) (infer e)

  pure (Fun (PatParam p) e (an, TyArr dom cod), TyArr dom cod)

infer (Literal l an) = pure (Literal l (an, ty), ty) where
  ty = litTy l

infer (ListExp es an) = do
  t <- freshTV
  es <- traverse (`check` t) es
  pure (buildList an t es, TyApp tyList t)

infer (Let re ns b an) = do
  (ns, ts, vars) <- inferLetTy localGenStrat Propagate ns
    `catchChronicle` \e -> do
       tell (DeferredError <$> e)
       fakeLetTys ns

  let bvs = Set.fromList (namesInScope (focus ts mempty))

  local (typeVars %~ Set.union vars) $
    local (letBound %~ Set.union bvs) $
      local (names %~ focus ts) $ do
        (b, ty) <- infer' b
        pure (Let re ns b (an, ty), ty)

infer ex@(Ascription e ty an) = do
  ty <- resolveKind (becauseExp ex) ty
  e <- check e ty
  pure (Ascription (correct ty e) ty (an, ty), ty)

infer (BinOp l o r a) = inferApps (App (App o l a) r a) Nothing

infer ex@App{} = do
  (ex, ty) <- inferApps ex Nothing
  (k, ty) <- secondA expandType =<< instantiateTc (becauseExp ex) ty
  pure (k ex, ty)

infer ex@Vta{} = do
  (ex, ty) <- inferApps ex Nothing
  (k, ty) <- secondA expandType =<< instantiateTc (becauseExp ex) ty
  pure (k ex, ty)

infer ex@(Match t ps p a) = do
  (t', tt) <- infer t
  ty <- freshTV

  ps' <- for ps $ \(Arm p g e a) -> do
    (p', ms, cs, is) <- checkPattern p tt
    let tvs = boundTvs p' ms
    leakEqualities ex cs
    local (typeVars %~ Set.union tvs) . local (names %~ focus ms) . local (classes %~ mappend is) $ do
      e' <- check e ty
      g' <- traverse (`check` tyBool) g
      pure (Arm p' g' e' a)
  pure (Match t' ps' p (a, ty), ty)

infer (Record rows a) = do
  (rows, rowts) <- unzip <$> inferRows rows
  let ty = TyExactRows rowts
   in pure (Record rows (a, ty), ty)

infer ex@(RecordExt rec rows a) = do
  (rec, rho) <- infer rec
  (rows, newts) <- unzip <$> inferRows rows
  tv <- freshTV
  let ty = TyRows tv newts

  -- here: have rho (inferred)
  --       want ty (inferred)
  co <- subsumes (becauseExp ex) rho ty
  pure (ExprWrapper co (RecordExt rec rows (a, ty)) (a, ty), ty)

infer (Tuple xs an) =
  let go [x] = first (:[]) <$> infer x
      go (x:xs) = do
        (x', t) <- infer x
        (xs, t') <- go xs
        pure (x':xs, TyTuple t t')
      go [] = error "wot in tarnation"
   in do
     (ex, t) <- go xs
     pure (Tuple ex (an, t), t)

infer (Begin xs a) = do
  let start = init xs
      end = last xs
  start <- traverse (`check` tyUnit) start
  (end, t) <- infer' end
  pure (Begin (start ++ [end]) (a, t), t)

infer (OpenIn mod expr a) = do
  (mod', exEnv) <- inferMod mod
  local (unqualify mod . exEnv Nothing) $ do
    (expr', ty) <- infer expr
    pure (ExprWrapper (TypeAsc ty) (OpenIn mod' (ExprWrapper (TypeAsc ty) expr' (a, ty)) (a, ty)) (a, ty), ty)

infer (Idiom pure_v app_v expr ann) =
  do
    ~(fn:as) <- reverse <$> spine expr
    infer (make_idiom fn as)
  where
    spine (BinOp l o r _) = pure [ r, l, o ]
    spine (App f x _) = do
      sp <- spine f
      pure (x:sp)
    spine ex@Fun{} = pure [ex]
    spine ex@VarRef{} = pure [ex]
    spine ex@ListExp{} = pure [ex]
    spine x = confesses (addBlame (becauseExp expr) (NotAnIdiom x))

    make_idiom fun =
      foldl (\f x -> BinOp f (VarRef app_v ann) x ann) (App (VarRef pure_v ann) fun ann)

infer ex@(ListFrom range_v start an) = do
  let reason = becauseExp ex
  (fun, range_t) <- infer (VarRef range_v an)
  ~(Anon t1, c1, w1) <- quantifier reason (/= Req) range_t

  start <- check start t1

  t_con <- freshTV
  let list_t = TyApp t_con t1
  w2 <- subsumes reason c1 list_t
  pure (ExprWrapper w2 (App (w1 fun) start (an, c1)) (an, list_t), list_t)

infer ex@(ListFromTo range_v start end an) = do
  let reason = becauseExp ex
  (fun, range_t) <- infer (VarRef range_v an)
  ~(Anon t1, c1, w1) <- quantifier reason (/= Req) range_t
  ~(Anon t2, c2, w2) <- quantifier reason (/= Req) c1

  start <- check start t1
  end <- check end t1
  _ <- unify (becauseExp ex) t2 t1

  t_con <- freshTV
  let list_t = TyApp t_con t1
  w3 <- subsumes reason c2 list_t
  pure (ExprWrapper w3 (App (w2 (App (w1 fun) start (an, c1))) end (an, c2)) (an, list_t), list_t)

infer ex@(ListFromThen range_v start next an) = do
  let reason = becauseExp ex
  (fun, range_t) <- infer (VarRef range_v an)
  ~(Anon t1, c1, w1) <- quantifier reason (/= Req) range_t
  ~(Anon t2, c2, w2) <- quantifier reason (/= Req) c1

  start <- check start t1
  next <- check next t1
  _ <- unify (becauseExp ex) t2 t1

  t_con <- freshTV
  let list_t = TyApp t_con t1
  w3 <- subsumes reason c2 list_t
  pure (ExprWrapper w3 (App (w2 (App (w1 fun) start (an, c1))) next (an, c2)) (an, list_t), list_t)

infer ex@(ListFromThenTo range_v start next end an) = do
  let reason = becauseExp ex
  (fun, range_t) <- infer (VarRef range_v an)
  ~(Anon t1, c1, w1) <- quantifier reason (/= Req) range_t
  ~(Anon t2, c2, w2) <- quantifier reason (/= Req) c1
  ~(Anon t3, c3, w3) <- quantifier reason (/= Req) c2

  start <- check start t1
  next <- check next t1
  end <- check end t1
  _ <- unify (becauseExp ex) t2 t1
  _ <- unify (becauseExp ex) t3 t1

  t_con <- freshTV
  let list_t = TyApp t_con t1
  w4 <- subsumes reason c3 list_t
  pure ( ExprWrapper w4
          (App (w3
              (App (w2
                  (App (w1 fun) start (an, c1)))
                next (an, c2)))
            end (an, c3)) (an, list_t)
       , list_t)


infer ex = do
  x <- freshTV
  ex' <- check ex x
  pure (ex', x)

-- | Infer a 'Type' for an 'Expr'ession without instantiating variables
infer' :: MonadInfer Typed m => Expr Desugared -> m (Expr Typed, Type Typed)
infer' (VarRef k a) = do
  (cont, old, ty) <- lookupTy' Weak k
  ty <- expandType ty
  pure (fromMaybe id cont (VarRef k (a, old)), ty)
infer' ex@App{} = inferApps ex Nothing
infer' ex@Vta{} = inferApps ex Nothing
infer' x = infer x

inferRows :: MonadInfer Typed m
          => [Field Desugared]
          -> m [(Field Typed, (T.Text, Type Typed))]
inferRows rows = for rows $ \(Field n e s) -> do
  (e, t) <- infer e
  pure (Field n e (s, t), (n, t))

inferProg :: MonadInfer Typed m
          => [Toplevel Desugared] -> m ([Toplevel Typed], Env)
inferProg (stmt@(LetStmt re am ns a):prg) = censor onlyDeferred $ do
  (ns', ts, _) <- retcons (addBlame (BecauseOf stmt)) (inferLetTy (closeOverStrat (BecauseOf stmt)) Fail ns)
    `catchChronicle` \e -> do
      tell (DeferredError <$> e)
      fakeLetTys ns
  let bvs = Set.fromList (namesInScope (focus ts mempty))

  (ts, es) <- flip foldTeleM ts $ \var ty -> do
    ty <- memento $ skolCheck var (BecauseOf stmt) ty
    case ty of
      Left e -> pure (mempty, e)
      Right t -> do
        t <- expandType t
        pure (one var t, mempty)

  if Seq.null es
     then pure ()
     else confess (Seq.filter ((/= WarningMessage) . diagnosticKind) es)

  local (letBound %~ Set.union bvs) . local (names %~ focus ts) $
    consFst (LetStmt re am ns' a) $
      inferProg prg

inferProg (st@(ForeignVal am v d t ann):prg) = do
  t' <- resolveKind (BecauseOf st) t
  local (names %~ focus (one v t')) . local (letBound %~ Set.insert v) $
    consFst (ForeignVal am v d t' ann) $
      inferProg prg

inferProg (decl@(TySymDecl am n tvs exp ann):prg) = do
  (kind, exp, tvs) <- resolveTySymDeclKind (BecauseOf decl) n tvs exp

  let td = TypeDecl am n tvs (Just [ArgCon am n exp (ann, kind)]) ann
      argv (TyAnnArg v _:xs) = v:argv xs
      argv (TyVarArg v:xs) = v:argv xs
      argv (TyInvisArg v _:xs) = v:argv xs
      argv [] = []
      info = TySymInfo n exp (argv tvs) kind

  local (names %~ focus (one n (fst (rename kind)))) . local (tySyms . at n ?~ info)  $
    consFst td $ inferProg prg

inferProg (decl@(TypeDecl am n tvs cs ann):prg) = do
  (kind, retTy, tvs) <- retcons (addBlame (BecauseOf decl)) $
                          resolveTyDeclKind (BecauseOf decl) n tvs (fromMaybe [] cs)
  let scope (TyAnnArg v k:vs) = one v k <> scope vs
      scope (_:cs) = scope cs
      scope [] = mempty

  let vars =
        flip foldMap tvs $ \case
          TyVarArg v -> Set.singleton v
          TyAnnArg v _ -> Set.singleton v
          TyInvisArg v _ -> Set.singleton v

  let cont cs =
        consFst (TypeDecl am n tvs cs ann) $
          inferProg prg

  local (names %~ focus (one n (fst (rename kind)))) . local (declaredHere %~ Set.insert n) $
    case cs of
      Nothing -> cont Nothing
      Just cs -> do
        (ts, cs') <- unzip <$> local (names %~ focus (scope tvs))
          (for cs (\con -> retcons (addBlame (BecauseOf con)) (inferCon vars retTy con)))

        let ts' = Set.fromList (map fst ts)
        local ( (names %~ focus (teleFromList ts))
                . (types %~ Map.insert n ts')
                . (constructors %~ Set.union ts') ) $
          cont (Just cs')

inferProg (c@Class{}:prg) = do
  let v = className c
  (stmts, decls, clss, implicits, syms) <- condemn $ inferClass c
  first (stmts ++) <$> do
    local (names %~ focus decls)
      . local (declaredHere %~ Set.insert v)
      . local (classDecs . at v ?~ clss)
      . local (classes %~ mappend implicits)
      . local (tySyms %~ extendTySyms syms) $
        inferProg prg

inferProg (inst@Instance{}:prg) = do
  (stmt, instName, instTy, ci, syms) <- condemn $ inferInstance inst
  let addFst (LetStmt _ _ [] _) = id
      addFst stmt = consFst stmt

  flip (foldr addFst) (reverse stmt)
    . local (classes %~ insert (spanOf inst) InstSort instName instTy ci)
    . local (tySyms %~ extendTySyms syms)
    $ inferProg prg

inferProg (decl@(TypeFunDecl am tau arguments kindsig equations ann):prg) = do
  (kind, equations, arguments) <- resolveTyFunDeclKind (BecauseOf decl) tau arguments kindsig equations
  () <- checkValidTypeFunction (BecauseOf decl) tau kind arguments equations
  cons <- makeTypeFunctionHIT arguments equations
  let tfinfo =
        TyFamInfo { _tsName = tau
                  , _tsEquations = zipWith make_eq equations cons
                  , _tsArgs = map arg_name (filter vis arguments)
                  , _tsKind = kind
                  , _tsConstraint = Nothing
                  }
      fakeDecl = TypeDecl am tau arguments (Just cons) ann
      make_eq (TyFunClause (TyApps _ lhs) rhs _) (GadtCon _ v _ _) = (lhs, rhs, v)
      make_eq _ _ = undefined
      arg_name (TyAnnArg v _) = v
      arg_name _ = undefined
      vis TyInvisArg{} = False
      vis _ = True

  local (tySyms %~ Map.insert tau tfinfo) $
    local (names %~ focus (one tau kind)) $
      consFst fakeDecl $ inferProg prg

inferProg (DeriveInstance tau ann:prg) = do
  tau <- checkAgainstKind (BecauseOf (DeriveInstance tau ann)) tau tyConstraint
  let inst = DeriveInstance tau ann

  name <- case tau of
    TyPi (Implicit _) (TyApps (TyCon class_con ()) (_:_)) -> pure class_con
    TyApps (TyCon class_con ()) (_:_) -> pure class_con
    _ -> confesses (DIMalformedHead (BecauseOf inst))

  class_info <- view (classDecs . at name)

  st <- case class_info of
    Just (MagicInfo _ (Just derive)) -> runDerive derive tau ann
    Just ClassInfo { _ciDerive = Just derive }  -> runDerive derive tau ann
    _ -> confesses (DICan'tDerive name (BecauseOf inst))

  case st of
    Just st -> inferProg (st:prg)
    Nothing -> confesses (DICan'tDerive name (BecauseOf inst))

inferProg (Open mod:prg) = do
  (mod', exEnv) <- inferMod mod

  local (unqualify mod . exEnv Nothing) $
    consFst (Open mod') $ inferProg prg

inferProg (Include mod:prg) = do
  (mod', exEnv) <- inferMod mod

  local (unqualify mod . exEnv Nothing) $
    consFst (Include mod') $ inferProg prg

inferProg (Module am name mod:prg) = do
  (mod', exEnv) <- local (declaredHere .~ mempty) $ inferMod mod
  local (exEnv (Just name)) $
      consFst (Module am name mod') (inferProg prg)

inferProg [] = asks ([],)

-- | Infer a module, returning a typed module and a function for extending the environment.
inferMod :: MonadInfer Typed m => ModuleTerm Desugared
         -> m (ModuleTerm Typed, Maybe (Var Typed) -> Env -> Env)
inferMod (ModStruct bod a) = do
  (bod', env) <- inferProg bod
  let append x p = maybe p (<> p) x
      qualifyWrt prefix =
        let go (TyCon n ()) = TyCon (append prefix n) ()
            go x = x
         in transformType go

  pure (ModStruct bod' a
       , \prefix extEnv ->
           let diff = env `difference` extEnv
               env' = (declaredHere .~ mempty)
                    . (names .~ mapScope (append prefix) (qualifyWrt prefix) (diff ^. names))
                    . (types .~ (Set.mapMonotonic (append prefix) <$> Map.mapKeysMonotonic (append prefix) (diff ^. types)))
                    $  env
           in extEnv <> env')

inferMod (ModRef name a) = pure (ModRef name a, const id)

inferMod ModImport{} = error "Impossible"
inferMod ModTargetImport{} = error "Impossible"

buildList :: Ann Resolved -> Type Typed -> [Expr Typed] -> Expr Typed
buildList an tau [] =
  ExprWrapper (TypeApp tau)
    (VarRef nILName (an, nILTy))
    (an, ty)
  where ty = TyApp tyList tau

buildList an tau (x:xs) =
  App (ExprWrapper (TypeApp tau)
        (VarRef cONSName (an, cONSTy)) (an, cONSTy' tau))
    (Tuple [x, buildList an tau xs]
      (an, TyTuple tau ty))
    (an, ty)
  where ty = TyApp tyList tau

consFst :: Functor m => a -> m ([a], b) -> m ([a], b)
consFst = fmap . first . (:)


closeOverStrat :: MonadInfer Typed m
               => SomeReason
               -> Set.Set (Var Typed) -> Expr Typed -> Type Typed -> m (Type Typed)
closeOverStrat r _ e t =
  if value e then closeOver r t else do
    vars_scope <- view typeVars
    let vars = ftv t `Set.difference` vars_scope
    unless (Set.null vars) $
      confesses (ValueRestriction r t vars)
    annotateKind r t

instantiateTc :: MonadInfer Typed m
              => SomeReason
              -> Type Typed
              -> m ( Expr Typed -> Expr Typed
                   , Type Typed )
instantiateTc r tau = do
  (fromMaybe id -> f, _, ty) <- instantiate Strong Expression tau
  (g, ty) <- go ty
  pure (g . f, ty)
  where
    go ty@(TyPi (Implicit tau) sigma) = do
      x <- genName
      i <- view classes
      tell (Seq.singleton (ConImplicit r i x tau))
      (k, sigma) <- go sigma
      let wrap ex =
            ExprWrapper (WrapVar x) (ExprWrapper (TypeAsc ty) ex (spanOf ex, ty)) (spanOf ex, sigma)
      pure (k . wrap, sigma)
    go x = pure (id, x)

solveEx :: TySyms -> Subst Typed -> Map.Map (Var Typed) (Wrapper Typed) -> Expr Typed -> Expr Typed
solveEx syms ss cs = transformExprTyped go id goType where
  go :: Expr Typed -> Expr Typed
  go (ExprWrapper w e a) = case goWrap w of
    WrapFn w@(MkWrapCont _ desc) -> ExprWrapper (WrapFn (MkWrapCont id desc)) (runWrapper w e) a
    x -> ExprWrapper x e a
  go x = x

  goWrap (TypeApp t) = TypeApp (goType t)
  goWrap (TypeAsc t) = TypeAsc (goType t)
  goWrap (Cast c) = erase_c $ Cast (goCast c) where
    goCast = transformCoercion go goType
    go (MvCo v) = case Map.lookup v cs of
      Just (Cast c) -> c
      x -> error ("coercion metavariable " ++ show v ++ " not solved to cast " ++ show x)
    go x = x

    erase_c (Cast c)
      | isReflexiveCo c = IdWrap
      | otherwise = Cast c
    erase_c x = x

  goWrap (TypeLam l t) = TypeLam l (goType t)
  goWrap (ExprApp f) = ExprApp (go f)
  goWrap (x Syntax.:> y) = goWrap x Syntax.:> goWrap y
  goWrap (WrapVar v) =
    case Map.lookup v cs of
      Just x -> goWrap x
      _ -> WrapVar v
  goWrap IdWrap = IdWrap
  goWrap (WrapFn f) = WrapFn . flip MkWrapCont (desc f) $ solveEx syms ss cs . runWrapper f

  goType :: Type Typed -> Type Typed
  goType = apply ss

-- | Is this coercion equal to reflexivity? (Conservative)
isReflexiveCo :: EqPhrase p => Coercion p -> Bool
isReflexiveCo VarCo{} = False
isReflexiveCo MvCo{} = False
isReflexiveCo ReflCo{} = True
isReflexiveCo (AssumedCo a b) = a == b

isReflexiveCo (SymCo c) = isReflexiveCo c
isReflexiveCo TransCo{} = False

isReflexiveCo (AppCo a b) = isReflexiveCo a && isReflexiveCo b
isReflexiveCo (ArrCo a b) = isReflexiveCo a && isReflexiveCo b
isReflexiveCo (ProdCo a b) = isReflexiveCo a && isReflexiveCo b
isReflexiveCo (ExactRowsCo rs) = all (isReflexiveCo . snd) rs
isReflexiveCo (RowsCo a rs) = isReflexiveCo a && all (isReflexiveCo . snd) rs
isReflexiveCo ProjCo{} = False
isReflexiveCo (ForallCo _ _ a b) = isReflexiveCo a && isReflexiveCo b

isReflexiveCo P1{} = False
isReflexiveCo P2{} = False
isReflexiveCo InstCo{} = False

unqualifyWrt :: (Var p ~ Var Resolved) => T.Text -> Type p -> Type p
unqualifyWrt n = transformType go where
  go (TyCon v a) = TyCon (unqualifyVarWrt n v) a
  go t = t

unqualifyVarWrt :: T.Text -> Var Resolved -> Var Resolved
unqualifyVarWrt n (TgName v id)
  | n `T.isPrefixOf` v = TgName (T.drop (T.length n) v) id
  | otherwise = TgName v id
unqualifyVarWrt _ n = n

unqualify :: (Var p ~ Var Resolved) => ModuleTerm p -> Env -> Env
unqualify (ModRef v _) =
 let prefix =
       case v of
         TgName v _ -> v <> T.singleton '.'
         TgInternal v -> v <> T.singleton '.'
  in (names %~ mapScope id (unqualifyWrt prefix))
   . (types %~ fmap (Set.mapMonotonic (unqualifyVarWrt prefix)))

unqualify _ = id

onlyDeferred :: Seq.Seq (Constraint Typed) -> Seq.Seq (Constraint Typed)
onlyDeferred = Seq.filter $ \case
  DeferredError{} -> True
  _ -> False

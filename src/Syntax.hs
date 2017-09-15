{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
module Syntax where

import Text.Parsec.Pos (SourcePos, sourceName, setSourceName)
import Pretty

data Expr'
  = VarRef Var
  | Let [(Var, Expr)] Expr
  | If Expr Expr Expr
  | App Expr Expr
  | Fun Pattern Expr
  | Begin [Expr]
  | Literal Lit
  | Match Expr [(Pattern, Expr)]
  | BinOp Expr Expr Expr
  | MultiWayIf [(Expr, Expr)]
  deriving (Eq, Show, Ord)
type Expr = (SourcePos, SourcePos, Expr')

data Pattern
  = Wildcard
  | Capture Var
  | Destructure Var [Pattern]
  | PType Pattern Type
  deriving (Eq, Show, Ord)

data Lit
  = LiInt Integer
  | LiStr String
  | LiBool Bool
  | LiUnit
  deriving (Eq, Show, Ord)

data Type
  = TyCon Var
  | TyVar String
  | TyForall [String] [Type] Type -- constraints
  | TyArr Type Type
  | TyApp Type Type
  deriving (Eq, Show, Ord)

data Var
  = Name String
  | Refresh Var String
  deriving (Eq, Show, Ord)

data Toplevel
  = LetStmt [(Var, Expr)]
  | ValStmt Var Type
  | ForeignVal Var String Type
  | TypeDecl Var [String] [(Var, [Type])]
  deriving (Eq, Show, Ord)

data Kind
  = KiType
  | KiArr Kind Kind
  deriving (Eq, Show, Ord)

data Constraint
  = ConUnify Expr Type Type
  deriving (Eq, Show, Ord)

instance Pretty Expr where
  pprint (_, _, e) = pprint e

instance Pretty Expr' where
  pprint (VarRef v) = pprint v
  pprint (MultiWayIf xs) = do
    kwClr "if"
    body 2 xs
  pprint (Let [] _) = error "absurd: never parsed"
  pprint (Let ((n, v):xs) e) = do
    kwClr "let " <+> n <+> opClr " = " <+> v <+> newline
    forM_ xs $ \(n, v) ->
      kwClr "and " <+> n <+> opClr " = " <+> v <+> newline
    pprint e
  pprint (If c t e) = do
    kwClr "if " <+> c <+> newline
    block 2 $ do
      kwClr "then " <+> t <+> newline
      kwClr "else " <+> e
  pprint (App c (_, _, e@App{})) = c <+> " " <+> parens e
  pprint (App f x) = f <+> " " <+> x
  pprint (Fun v e) = kwClr "fun " <+> v <+> opClr " -> " <+> e
  pprint (Begin e) = do
    kwClr "begin "
    body 2 e *> newline
    kwClr "end"
  pprint (Literal l) = pprint l
  pprint (BinOp l o r) = parens (pprint l <+> " " <+> pprint o <+> " " <+> pprint r)
  pprint (Match t bs) = do
    kwClr "match " <+> t <+> " with"
    body 2 bs *> newline

instance Pretty (Pattern, Expr) where
  pprint (a, b) = opClr "| " <+> a <+> " -> " <+> b

instance Pretty (Expr, Expr) where
  pprint (a, b) = opClr "| " <+> a <+> " -> " <+> b

instance Pretty Kind where
  pprint KiType = kwClr "Type"
  pprint (KiArr a b) = a <+> opClr " -> " <+> b

instance Pretty Pattern where
  pprint Wildcard = kwClr "_"
  pprint (Capture x) = pprint x
  pprint (Destructure x []) = pprint x
  pprint (Destructure x xs) = parens $ x <+> " " <+> interleave " " xs
  pprint (PType p x) = parens $ p <+> opClr " : " <+> x

instance Pretty Lit where
  pprint (LiStr s) = strClr s
  pprint (LiInt s) = litClr s
  pprint (LiBool True) = litClr "true"
  pprint (LiBool False) = litClr "false"
  pprint LiUnit = litClr "unit"

instance Pretty Type where
  pprint (TyCon v) = typeClr v
  pprint (TyVar v) = opClr "'" <+> tvClr v
  pprint (TyForall vs c v) = kwClr "∀ " <+> interleave " " vs <+> opClr ". " <+> parens (interleave "," c) <+> opClr " => " <+> v

  pprint (TyArr x@TyArr{} e) = parens x <+> opClr " -> " <+> e
  pprint (TyArr x e) = x <+> opClr " -> " <+> e

  pprint (TyApp e x@TyApp{}) = parens x <+> opClr " -> " <+> e
  pprint (TyApp x e) = x <+> opClr " " <+> e

instance Pretty Var where
  pprint (Name v) = pprint v
  pprint (Refresh v _) = pprint v

instance Pretty Constraint where
  pprint (ConUnify e a b) = e <+> opClr " <=> " <+> a <+> opClr " ~ " <+> b

instance Pretty (SourcePos, SourcePos) where
  pprint (a, b)
    = let file = sourceName a
          a' = init . tail . show . setSourceName a $ ""
          b' = init . tail . show . setSourceName b $ ""
       in do
         file <+> ": " <+> a' <+> " to " <+> b'

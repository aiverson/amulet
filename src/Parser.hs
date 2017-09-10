module Parser where

import qualified Text.Parsec.Token as Tok
import Text.Parsec.String
import Text.Parsec.Expr
import Text.Parsec

import Parser.Lexer

import Syntax

bindGroup :: Parser [(Var, Expr)]
bindGroup = flip sepBy1 (reserved "and") $ try funDecl <|> varDecl where
  varDecl = do
    x <- name
    reservedOp "="
    (,) <$> pure x <*> exprP
  funDecl = do
    x <- name
    ps <- many1 name
    reservedOp "="
    b <- exprP
    pure (x, foldr Fun b ps)

exprP' :: Parser Expr
exprP' = parens exprP
     <|> funExpr
     <|> letExpr
     <|> ifExpr
     <|> beginExpr
     <|> VarRef <$> name
     <|> Literal <$> lit where
  funExpr = do
    reserved "fun"
    x <- name
    reservedOp "->"
    Fun x <$> exprP
  letExpr = do
    reserved "let"
    bgs <- bindGroup
    reserved "in"
    Let bgs <$> exprP
  ifExpr = do
    reserved "if"
    c <- exprP
    reserved "then"
    t <- exprP
    reserved "else"
    If c t <$> exprP
  beginExpr = Begin <$> (reserved "begin" *> semiSep1 exprP <* reserved "end")

typeP :: Parser Type
typeP = typeOpP where
  typeOpP = buildExpressionParser table type' <?> "type"
  type' = foldl1 TyApp <$> many1 typeP'
  table = [ [ binary "->" TyArr AssocRight ]]
  binary n f a = flip Infix a $ do
    reservedOp n
    pure f

typeP' :: Parser Type
typeP' = parens typeP
     <|> TyVar <$> tyVar
     <|> tyCon
     <|> tyForall where
  tyForall = do
    reserved "forall"
    nms <- commaSep1 tyVar
    _ <- dot
    cs <- parens . commaSep1 $ typeP
    reservedOp "=>"
    TyForall nms cs <$> typeP
  tyVar = lexeme $ do
    _ <- char '\''
    x <- Tok.identStart style
    (x:) <$> many (Tok.identLetter style)
  tyCon = TyCon <$> name

name :: Parser Var
name = Name <$> identifier

lit :: Parser Lit
lit = intLit <|> strLit <|> true <|> false where
  intLit = LiInt <$> integer
  strLit = LiStr <$> stringLiteral
  true = LiBool True <$ reserved "true"
  false = LiBool False <$ reserved "true"

exprP :: Parser Expr
exprP = foldl1 App <$> many1 exprP'

toplevelP :: Parser Toplevel
toplevelP = letStmt <|> try foreignVal <|> valStmt where
  letStmt = do
    reserved "let"
    LetStmt <$> bindGroup
  valStmt = do
    reserved "val"
    x <- name
    _ <- colon
    ValStmt x <$> typeP
  foreignVal = do
    reserved "val"
    reserved "foreign"
    x <- name
    n <- stringLiteral
    _ <- colon
    ForeignVal x n <$> typeP

program :: Parser [Toplevel]
program = semiSep1 toplevelP <* eof

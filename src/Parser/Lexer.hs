module Parser.Lexer where

import Text.Parsec.String
import Text.Parsec.Language
import qualified Text.Parsec.Token as Tok

import Data.Functor.Identity

style :: GenLanguageDef String u Identity
style = haskellDef
          { Tok.commentStart = "(*"
          , Tok.commentEnd = "*)"
          , Tok.commentLine = ""
          , Tok.nestedComments = True
          , Tok.reservedNames = words
          , Tok.reservedOpNames = ops } where

  ops = ["->", "=", "∀", "=>", "|", "**", "*", "+", "^", "<", ">=", "==", "&&", "||", "/", "-", ">", "<=", "<>"]
  words = ["forall", "let", "and", "if", "then", "else", "begin", "end", "in", "foreign", "val", "true", "false", "match", "with"]

lexer :: Tok.TokenParser ()
lexer = Tok.makeTokenParser style

identifier :: Parser String
identifier = Tok.identifier lexer

reserved :: String -> Parser ()
reserved = Tok.reserved lexer

operator :: Parser String
operator = Tok.operator lexer

reservedOp :: String -> Parser ()
reservedOp = Tok.reservedOp lexer

charLiteral :: Parser Char
charLiteral = Tok.charLiteral lexer

stringLiteral :: Parser String
stringLiteral = Tok.stringLiteral lexer

natural :: Parser Integer
natural = Tok.natural lexer

integer :: Parser Integer
integer = Tok.integer lexer

float :: Parser Double
float = Tok.float lexer

naturalOrFloat :: Parser (Either Integer Double)
naturalOrFloat = Tok.naturalOrFloat lexer

decimal :: Parser Integer
decimal = Tok.decimal lexer

hexadecimal :: Parser Integer
hexadecimal = Tok.hexadecimal lexer

octal :: Parser Integer
octal = Tok.octal lexer

symbol :: String -> Parser String
symbol = Tok.symbol lexer

lexeme :: Parser a -> Parser a
lexeme = Tok.lexeme lexer

whiteSpace :: Parser ()
whiteSpace = Tok.whiteSpace lexer

parens :: Parser a -> Parser a
parens = Tok.parens lexer

braces :: Parser a -> Parser a
braces = Tok.braces lexer

angles :: Parser a -> Parser a
angles = Tok.angles lexer

brackets :: Parser a -> Parser a
brackets = Tok.brackets lexer

semi :: Parser String
semi = Tok.semi lexer

comma :: Parser String
comma = Tok.comma lexer

colon :: Parser String
colon = Tok.colon lexer

dot :: Parser String
dot = Tok.dot lexer

semiSep :: Parser a -> Parser [a]
semiSep = Tok.semiSep lexer

semiSep1 :: Parser a -> Parser [a]
semiSep1 = Tok.semiSep1 lexer

commaSep :: Parser a -> Parser [a]
commaSep = Tok.commaSep lexer

commaSep1 :: Parser a -> Parser [a]
commaSep1 = Tok.commaSep1 lexer


{-# LANGUAGE RankNTypes, OverloadedStrings #-}
module Main where

import Text.Parsec

import System.Environment

import qualified Data.Text.IO as T
import qualified Data.Text as T
import qualified Data.Map as M
import Data.Foldable

import Control.Monad.Infer

import Backend.Compile

import Types.Infer

import Syntax.Resolve
import Syntax.Desugar
import Syntax

import Core.Core
import Core.Lower

import Errors
import Parser
import Pretty

data CompileResult = CSuccess ([Toplevel Typed], [CoStmt], Env)
                   | CParse   ParseError
                   | CResolve ResolveError
                   | CInfer   TypeError


compile :: SourceName -> T.Text -> CompileResult
compile name x =
  case parse program name x of
    Right parsed -> runGen $ do
      desugared <- desugarProgram parsed
      resolved <- resolveProgram desugared
      case resolved of
        Right resolved -> do
          infered <- inferProgram resolved
          case infered of
            Right (prog, env) -> do
              t <- runReaderT (lowerProg prog) env
              pure (CSuccess (prog, t, env))
            Left e -> pure (CInfer e)
        Left e -> pure (CResolve e)
    Left e -> CParse e

compileFromTo :: FilePath
              -> T.Text
              -> (forall a. Pretty a => a -> IO ())
              -> IO ()
compileFromTo fp x emit =
  case compile fp x of
    CSuccess (_, core, env) -> emit (compileProgram env core)
    CParse e -> print e
    CResolve e -> putStrLn "Resolution error" >> report e x
    CInfer e -> putStrLn "Type error" >> report e x

test :: String -> IO (Maybe ([CoStmt], Env))
test x = do
  putStrLn "\x1b[1;32mProgram:\x1b[0m"
  case compile "<test>" (T.pack x) of
    CSuccess (_, core, env) -> do
      putStrLn (x <> "\x1b[1;32mType inference:\x1b[0m")
      for_ (M.toList $ values (difference env builtinsEnv)) $ \(k, t) ->
        T.putStrLn (prettyPrint k <> " : " <> prettyPrint t)
      putStrLn "\x1b[1;32mCore lowering:\x1b[0m"
      traverse_ ppr core
      pure (Just (core, env))
    CParse e -> Nothing <$ print e
    CResolve e -> Nothing <$ report e (T.pack x)
    CInfer e -> Nothing <$ report e (T.pack x)

main :: IO ()
main = do
  ags <- getArgs
  case ags of
    [x] -> do
      x' <- T.readFile x
      compileFromTo x x' ppr
    ["test", x] -> do
      x' <- readFile x
      _ <- test x'
      pure ()
    [x, t] -> do
      x' <- T.readFile x
      compileFromTo x x' $ T.writeFile t . uglyPrint
    [] -> error "REPL not implemented yet"
    _ -> do
      putStrLn "usage: amulet from.ml to.lua"
      putStrLn "usage: amulet from.ml"
      putStrLn "usage: amulet"

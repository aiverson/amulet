module Main where

import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients
import Test.Tasty.Reporter
import Test.Tasty.Rerun
import Test.Tasty.Xml
import Test.Tasty

import qualified Test.Types.Unify as Solver
import qualified Test.Types.Holes as Holes
import qualified Test.Core.Lint as Lint
import qualified Test.Parser.Lexer as Lexer
import qualified Test.Parser.Parser as Parser
import qualified Test.Syntax.Resolve as Resolve
import qualified Test.Syntax.Verify as Verify
import qualified Test.Types.Check as TypesC
import qualified Test.Core.Backend as Backend
import qualified Test.Lua.Parser as LParser
import qualified Test.Frontend.Amc as Amc
import qualified Test.Lsp as Lsp

import GHC.IO.Encoding

tests :: IO TestTree
tests = testGroup "Tests" <$> sequence
  -- These two will timeout if you run 10000 of them.
  -- TODO: Get better CI machines
  [ pure Solver.tests
  , pure Holes.tests

  , Amc.tests
  , Lint.tests
  , Lexer.tests
  , Parser.tests
  , Resolve.tests
  , TypesC.tests
  , Verify.tests
  , Backend.tests
  , LParser.tests
  , Lsp.tests
  ]

main :: IO ()
main = locale *> test where
  locale = setLocaleEncoding utf8
  test = tests >>= defaultMainWithIngredients ingredients
  ingredients =
    [ rerunning
      [ listingTests
      , boringReporter `composeReporters` xmlReporter ]
    ]

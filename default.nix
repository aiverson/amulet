let
  rev = "120b013e0c082d58a5712cde0a7371ae8b25a601";
  pkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
    sha256 = "0hk4y2vkgm1qadpsm4b0q1vxq889jhxzjx3ragybrlwwg54mzp4f";
  };
  nixpkgs = import pkgs {
    config = {
      packageOverrides = pkgs_: with pkgs_; {
        haskell = haskell // {
          packages = haskell.packages // {
            ghc822-profiling = haskell.packages.ghc822.override {
              overrides = self: super: {
                mkDerivation = args: super.mkDerivation (args // {
                  enableLibraryProfiling = true;
                });
              };
            };
          };
        };
      };
    };
  };
in { compiler ? "ghc822", ci ? false }:

let
  inherit (nixpkgs) pkgs haskell;

  f = { mkDerivation, stdenv
      , mtl
      , syb
      , text
      , base
      , lens
      , array
      , HUnit
      , tasty
      , hedgehog
      , monad-gen
      , bytestring
      , containers
      , transformers
      , pretty-show
      , annotated-wl-pprint
      , tasty-hunit
      , tasty-hedgehog
      , alex
      , happy
      }:
      let alex' = haskell.lib.dontCheck alex;
          happy' = haskell.lib.dontCheck happy;
      in mkDerivation rec {
        pname = "amuletml";
        version = "0.1.0.0";
        src = ./.;

        isLibrary = false;
        isExecutable = true;

        libraryHaskellDepends = [
          annotated-wl-pprint array base bytestring containers lens monad-gen
          mtl pretty-show syb text transformers
        ];

        executableHaskellDepends = [
          mtl text base lens monad-gen bytestring containers pretty-show
        ];

        testHaskellDepends = [
          base bytestring hedgehog HUnit lens monad-gen mtl pretty-show
          tasty tasty-hedgehog tasty-hunit text
        ];

        libraryToolDepends = if ci then [ alex happy ] else [ alex' happy' ];
        buildDepends = libraryToolDepends ++ [ pkgs.cabal-install ];

        homepage = "https://amulet.ml";
        description = "A functional programming language";
        license = stdenv.lib.licenses.bsd3;
      };

  haskellPackages = pkgs.haskell.packages.${compiler};

  drv = haskellPackages.callPackage f {};

in
  if pkgs.lib.inNixShell then drv.env else drv

-- Copyright (c) 2019-2024 Digital Asset (Switzerland) GmbH and/or
-- its affiliates. All rights reserved.  SPDX-License-Identifier:
-- (Apache-2.0 OR BSD-3-Clause)

-- CI script, compatible with all of Travis, Appveyor and Azure.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE CPP #-}
import Control.Monad.Extra
import System.Directory
import System.FilePath
import System.IO.Extra
import System.Info.Extra
import System.Process.Extra
import System.Time.Extra
import System.Info (os, arch)
import System.Exit
import System.Environment
import Data.Maybe
import Data.List.Extra
import Data.Time.Clock
import Data.Time.Calendar
import qualified Options.Applicative as Opts
import Data.Foldable
import GHC.Stack
import System.IO.Unsafe

main :: IO ()
main = do
    let opts =
          Opts.info (parseOptions Opts.<**> Opts.helper)
          ( Opts.fullDesc
            <> Opts.progDesc "Build ghc-lib and ghc-lib-parser tarballs."
            <> Opts.header "CI - CI script for ghc-lib"
          )
    Options { ghcFlavor, noGhcCheckout, noBuilds, stackOptions, versionSuffix } <- Opts.execParser opts
    version <- buildDists ghcFlavor noGhcCheckout noBuilds stackOptions versionSuffix
    putStrLn version

data Options = Options
    { ghcFlavor :: GhcFlavor
    , noGhcCheckout :: Bool
    , noBuilds :: Bool
    , stackOptions :: StackOptions
    , versionSuffix :: Maybe String
    } deriving (Show)

data StackOptions = StackOptions
    { stackYaml :: Maybe String -- Optional config file
    , resolver :: Maybe String  -- If 'Just _', override stack.yaml.
    , verbosity :: Maybe String -- If provided, pass '--verbosity=xxx' to 'stack build'. Valid values are "silent",  "error", "warn", "info" or "debug".
    , cabalVerbose :: Bool -- If enabled, pass '--cabal-verbose' to 'stack build'.
    , ghcOptions :: Maybe String -- If 'Just _', pass '--ghc-options="xxx"' to 'stack build' (for ghc verbose, try 'v3').
    } deriving (Show)

data GhcFlavor = Da DaFlavor
               | GhcMaster String
               | Ghc9101
               | Ghc982 | Ghc981
               | Ghc966 | Ghc965 | Ghc964 | Ghc963 | Ghc962 | Ghc961
               | Ghc948 | Ghc947 | Ghc946 | Ghc945 | Ghc944 | Ghc943 | Ghc942 | Ghc941
               | Ghc928 | Ghc927 | Ghc926 | Ghc925 | Ghc924 | Ghc923 | Ghc922 | Ghc921
               | Ghc902 | Ghc901
               | Ghc8107 | Ghc8106 | Ghc8105 | Ghc8104 | Ghc8103 | Ghc8102 | Ghc8101 | Ghc881
               | Ghc884 | Ghc883  | Ghc882
  deriving (Eq, Show)

data DaFlavor = DaFlavor
  { mergeBaseSha :: String
  , patches :: [String]
  , cpp :: [String]
  , flavor :: String
  , upstream :: String
  }
  deriving (Eq, Show)

-- Last tested gitlab.haskell.org/ghc/ghc.git at
current :: String
current = "bc1d435e399d8376b4e33d5d936424ff76cb686a" -- 2024-06-30

-- Command line argument generators.

stackYamlOpt :: Maybe FilePath -> String
stackYamlOpt = \case
  Just stackYaml -> "--stack-yaml " ++ stackYaml
  Nothing -> ""

stackResolverOpt :: Maybe String -> String
stackResolverOpt = \case
  Just resolver -> "--resolver " ++ resolver
  Nothing -> ""

ghcFlavorOpt :: GhcFlavor -> String
ghcFlavorOpt = \case
    Ghc9101 -> "--ghc-flavor ghc-9.10.1"
    Ghc982 -> "--ghc-flavor ghc-9.8.2"
    Ghc981 -> "--ghc-flavor ghc-9.8.1"
    Ghc966 -> "--ghc-flavor ghc-9.6.6"
    Ghc965 -> "--ghc-flavor ghc-9.6.5"
    Ghc964 -> "--ghc-flavor ghc-9.6.4"
    Ghc963 -> "--ghc-flavor ghc-9.6.3"
    Ghc962 -> "--ghc-flavor ghc-9.6.2"
    Ghc961 -> "--ghc-flavor ghc-9.6.1"
    Ghc948 -> "--ghc-flavor ghc-9.4.8"
    Ghc947 -> "--ghc-flavor ghc-9.4.7"
    Ghc946 -> "--ghc-flavor ghc-9.4.6"
    Ghc945 -> "--ghc-flavor ghc-9.4.5"
    Ghc944 -> "--ghc-flavor ghc-9.4.4"
    Ghc943 -> "--ghc-flavor ghc-9.4.3"
    Ghc942 -> "--ghc-flavor ghc-9.4.2"
    Ghc941 -> "--ghc-flavor ghc-9.4.1"
    Ghc928 -> "--ghc-flavor ghc-9.2.8"
    Ghc927 -> "--ghc-flavor ghc-9.2.7"
    Ghc926 -> "--ghc-flavor ghc-9.2.6"
    Ghc925 -> "--ghc-flavor ghc-9.2.5"
    Ghc924 -> "--ghc-flavor ghc-9.2.4"
    Ghc923 -> "--ghc-flavor ghc-9.2.3"
    Ghc922 -> "--ghc-flavor ghc-9.2.2"
    Ghc921 -> "--ghc-flavor ghc-9.2.1"
    Ghc901 -> "--ghc-flavor ghc-9.0.1"
    Ghc902 -> "--ghc-flavor ghc-9.0.2"
    Ghc8101 -> "--ghc-flavor ghc-8.10.1"
    Ghc8102 -> "--ghc-flavor ghc-8.10.2"
    Ghc8103 -> "--ghc-flavor ghc-8.10.3"
    Ghc8104 -> "--ghc-flavor ghc-8.10.4"
    Ghc8105 -> "--ghc-flavor ghc-8.10.5"
    Ghc8106 -> "--ghc-flavor ghc-8.10.6"
    Ghc8107 -> "--ghc-flavor ghc-8.10.7"
    Ghc881 -> "--ghc-flavor ghc-8.8.1"
    Ghc882 -> "--ghc-flavor ghc-8.8.2"
    Ghc883 -> "--ghc-flavor ghc-8.8.3"
    Ghc884 -> "--ghc-flavor ghc-8.8.4"
    Da DaFlavor {flavor} -> "--ghc-flavor " <> flavor
    GhcMaster _hash -> "--ghc-flavor ghc-master"
      -- The git SHA1 hash is not passed to ghc-lib-gen at this time.

cppOpts :: GhcFlavor -> String
cppOpts (Da DaFlavor {cpp}) = unwords $ concat [["--cpp", v] | v <- cpp]
cppOpts _ = ""

stackVerbosityOpt :: Maybe String -> String
stackVerbosityOpt = \case
  Just verbosity -> "--verbosity=" ++ verbosity
  Nothing -> ""

cabalVerboseOpt :: Bool -> String
cabalVerboseOpt True = "--cabal-verbose"; cabalVerboseOpt False = ""

ghcOptionsOpt :: Maybe String -> String
ghcOptionsOpt = \case
  Just options -> "--ghc-options=\"" ++ options ++ "\""
  Nothing -> ""

genDateSuffix :: IO String
genDateSuffix = do
  UTCTime day _ <- getCurrentTime
  pure $ replace "-" "" (showGregorian day)

-- Calculate a version string based on a ghc flavor and a suffix.
genVersionStr :: GhcFlavor -> String -> String
genVersionStr flavor suffix =
  base <> case suffix of
    "" -> ""
    _ -> "." <> suffix
  where
    base = case flavor of
      Da {}       -> "8.8.1"
      GhcMaster _ -> "0"
      Ghc9101     -> "9.10.1"
      Ghc982      -> "9.8.2"
      Ghc981      -> "9.8.1"
      Ghc966      -> "9.6.6"
      Ghc965      -> "9.6.5"
      Ghc964      -> "9.6.4"
      Ghc963      -> "9.6.3"
      Ghc962      -> "9.6.2"
      Ghc961      -> "9.6.1"
      Ghc948      -> "9.4.8"
      Ghc947      -> "9.4.7"
      Ghc946      -> "9.4.6"
      Ghc945      -> "9.4.5"
      Ghc944      -> "9.4.4"
      Ghc943      -> "9.4.3"
      Ghc942      -> "9.4.2"
      Ghc941      -> "9.4.1"
      Ghc928      -> "9.2.8"
      Ghc926      -> "9.2.6"
      Ghc925      -> "9.2.5"
      Ghc924      -> "9.2.4"
      Ghc923      -> "9.2.3"
      Ghc922      -> "9.2.2"
      Ghc921      -> "9.2.1"
      Ghc901      -> "9.0.1"
      Ghc902      -> "9.0.2"
      Ghc8101     -> "8.10.1"
      Ghc8102     -> "8.10.2"
      Ghc8103     -> "8.10.3"
      Ghc8104     -> "8.10.4"
      Ghc8105     -> "8.10.5"
      Ghc8106     -> "8.10.6"
      Ghc8107     -> "8.10.7"
      Ghc881      -> "8.8.1"
      Ghc882      -> "8.8.2"
      Ghc883      -> "8.8.3"
      Ghc884      -> "8.8.4"

parseOptions :: Opts.Parser Options
parseOptions = Options
    <$> ((Da <$> parseDaOptions)
         Opts.<|>
         Opts.option readFlavor
          ( Opts.long "ghc-flavor"
         <> Opts.help "The ghc-flavor to test against"
          )
        )
    <*> Opts.switch
          ( Opts.long "no-checkout"
          <> Opts.help "If enabled, don't perform a GHC checkout"
          )
    <*> Opts.switch
          ( Opts.long "no-builds"
          <> Opts.help "If enabled, don't build & test packages & examples"
          )
    <*> parseStackOptions
    <*> Opts.optional
          ( Opts.strOption
            ( Opts.long "version-suffix"
            <> Opts.help "If specified, append to version string for generated ghc-lib. Otherwise use current date."
            )
          )
 where
   readFlavor :: Opts.ReadM GhcFlavor
   readFlavor = Opts.eitherReader $ \case
       "ghc-9.10.1" -> Right Ghc9101
       "ghc-9.8.2" -> Right Ghc982
       "ghc-9.8.1" -> Right Ghc981
       "ghc-9.6.6" -> Right Ghc966
       "ghc-9.6.5" -> Right Ghc965
       "ghc-9.6.4" -> Right Ghc964
       "ghc-9.6.3" -> Right Ghc963
       "ghc-9.6.2" -> Right Ghc962
       "ghc-9.6.1" -> Right Ghc961
       "ghc-9.4.8" -> Right Ghc948
       "ghc-9.4.7" -> Right Ghc947
       "ghc-9.4.6" -> Right Ghc946
       "ghc-9.4.5" -> Right Ghc945
       "ghc-9.4.4" -> Right Ghc944
       "ghc-9.4.3" -> Right Ghc943
       "ghc-9.4.2" -> Right Ghc942
       "ghc-9.4.1" -> Right Ghc941
       "ghc-9.2.8" -> Right Ghc928
       "ghc-9.2.7" -> Right Ghc927
       "ghc-9.2.6" -> Right Ghc926
       "ghc-9.2.5" -> Right Ghc925
       "ghc-9.2.4" -> Right Ghc924
       "ghc-9.2.3" -> Right Ghc923
       "ghc-9.2.2" -> Right Ghc922
       "ghc-9.2.1" -> Right Ghc921
       "ghc-9.0.1" -> Right Ghc901
       "ghc-9.0.2" -> Right Ghc902
       "ghc-8.10.1" -> Right Ghc8101
       "ghc-8.10.2" -> Right Ghc8102
       "ghc-8.10.3" -> Right Ghc8103
       "ghc-8.10.4" -> Right Ghc8104
       "ghc-8.10.5" -> Right Ghc8105
       "ghc-8.10.6" -> Right Ghc8106
       "ghc-8.10.7" -> Right Ghc8107
       "ghc-8.8.1" -> Right Ghc881
       "ghc-8.8.2" -> Right Ghc882
       "ghc-8.8.3" -> Right Ghc883
       "ghc-8.8.4" -> Right Ghc884
       "ghc-master" -> Right (GhcMaster current)
       hash -> Right (GhcMaster hash)
   parseDaOptions :: Opts.Parser DaFlavor
   parseDaOptions =
       Opts.flag' DaFlavor ( Opts.long "da" <> Opts.help "Enables DA custom build." )
       <*> Opts.strOption
           ( Opts.long "merge-base-sha"
          <> Opts.help "DA flavor only. Base commit to use from the GHC repo."
          <> Opts.showDefault
          <> Opts.value "ghc-8.8.1-release"
           )
       <*> (Opts.some
             (Opts.strOption
              ( Opts.long "patch"
             <> Opts.help "DA flavor only. Commits to merge in from the DA GHC fork, referenced as 'upstream'. Can be specified multiple times. If no patch is specified, default will be equivalent to `--patch upstream/da-master-8.8.1`. Specifying any patch will overwrite the default (i.e. replace, not add)."
              ))
            Opts.<|>
            pure ["upstream/da-master-8.8.1"])
       <*> (Opts.some
             (Opts.strOption
              ( Opts.long "cpp"
             <> Opts.help "DA flavor only. CPP flags to pass on to ghc-lib-gen. Can be specified multiple times. If no flags are specified, default will be equivalent to `--cpp -DDAML_PRIM`. Specifying any flag will overwrite the default (i.e. replace, not add)."
              ))
            Opts.<|>
            pure ["-DDAML_PRIM"])
       <*> Opts.strOption
           ( Opts.long "gen-flavor"
          <> Opts.help "DA flavor only. Flavor to pass on to ghc-lib-gen."
          <> Opts.showDefault
          <> Opts.value "da-ghc-8.8.1")
       <*> Opts.strOption
           ( Opts.long "upstream"
          <> Opts.help "DA flavor only. URL for the git remote add command."
          <> Opts.showDefault
          <> Opts.value "https://github.com/digital-asset/ghc.git")

parseStackOptions :: Opts.Parser StackOptions
parseStackOptions = StackOptions
    <$> Opts.optional ( Opts.strOption
        ( Opts.long "stack-yaml"
       <> Opts.help "If specified, pass '--stack-yaml=xxx' to stack"
        ))
    <*> Opts.optional ( Opts.strOption
        ( Opts.long "resolver"
       <> Opts.help "If specified, pass '--resolver=xxx' to stack"
        ))
    <*> Opts.optional ( Opts.strOption
        ( Opts.long "verbosity"
       <> Opts.help "If specified, pass '--verbosity=xxx' to stack"
        ))
    <*> Opts.switch
        ( Opts.long "cabal-verbose"
       <> Opts.help "If specified, pass '--cabal-verbose' to stack"
        )
    <*> Opts.optional ( Opts.strOption
        ( Opts.long "ghc-options"
       <> Opts.help "If specified, pass '--ghc-options=\"xxx\"' to stack"
        ))

buildDists :: GhcFlavor -> Bool -> Bool -> StackOptions -> Maybe String -> IO String
buildDists
  ghcFlavor
  noGhcCheckout
  noBuilds
  StackOptions {stackYaml, resolver, verbosity, cabalVerbose, ghcOptions}
  versionSuffix
  =
  do
    let stackConfig = fromMaybe "stack.yaml" stackYaml

    -- Clean up old state.
    isCi <- isJust <$> lookupEnv "GHCLIB_AZURE"
    -- Avoid https://github.com/commercialhaskell/stack/issues/5866.
    filesInDot <- getDirectoryContents "."
    let lockFiles = filter (isExtensionOf ".lock") filesInDot
        tarBalls  = filter (isExtensionOf ".tar.gz") filesInDot
        ghcDirs   = ["ghc" | not noGhcCheckout] ++ [ "ghc-lib", "ghc-lib-parser" ]
        toDelete  = ghcDirs ++ tarBalls ++ lockFiles
    forM_ toDelete removePath
    cmd "rm -f cabal.project"
    cmd $ "git checkout " ++ stackConfig
    cmd "git checkout ghc-lib-gen.cabal examples"

    -- Get packages missing on Windows needed by hadrian.
    when isWindows $
        stack "exec -- pacman -S autoconf automake-wrapper make patch python tar mintty --noconfirm"

    -- If '--no-checkout' is given, it's on the caller to get the GHC
    -- clone with e.g.
    --  git clone https://gitlab.haskell.org/ghc/ghc.git && \
    --      git fetch --tags && git submodule update --init --recursive
    -- and it won't be deleted between runs.
    if noGhcCheckout then do
      cmd "{ cd ghc; git remote remove upstream || true; }"
      cmd "cd ghc && git clean -xdf && git submodule foreach git clean -xdf && git submodule foreach git checkout . && git checkout ."
    else do
      if isWindows then do
        cmd "git clone https://github.com/ghc/ghc.git"
        cmd "git config --global url.\"git://github.com/ghc/packages-\".insteadOf     git://github.com/ghc/packages/"
        cmd "git config --global url.\"http://github.com/ghc/packages-\".insteadOf    http://github.com/ghc/packages/"
        cmd "git config --global url.\"https://github.com/ghc/packages-\".insteadOf   https://github.com/ghc/packages/"
        cmd "git config --global url.\"git\\@github.com:/ghc/packages-\".insteadOf    git\\@github.com:/ghc/packages/"
      else
        cmd "git clone https://gitlab.haskell.org/ghc/ghc.git"
      cmd "cd ghc && git fetch --tags"
    gitCheckout ghcFlavor

    cmd "bash -c \"unset GHC_PACKAGE_PATH && cabal update\""
    cmd "bash -c \"unset GHC_PACKAGE_PATH && cabal install alex --overwrite-policy=always\""
    cmd "bash -c \"unset GHC_PACKAGE_PATH && cabal install happy --overwrite-policy=always\""
    cmd "bash -c \"unset GHC_PACKAGE_PATH && cabal build exe:ghc-lib-gen\""

    -- Calculate version and package names.
    version <- tag
    let pkg_ghclib = "ghc-lib-" ++ version
        pkg_ghclib_parser = "ghc-lib-parser-" ++ version

    -- Make and extract an sdist of ghc-lib-parser.
    cmd "cd ghc && git checkout ."
    -- Make and extract an sdist of ghc-lib. The first argument is a
    -- ghc repo dir relative to '.' ('root'), 'patches' needs to be
    -- provided relative to 'root' (i.e. 'ghc') hence '../patches'.
    cmd $ "bash -c \"unset GHC_PACKAGE_PATH && cabal run exe:ghc-lib-gen -- ghc ../patches --ghc-lib-parser " ++ ghcFlavorOpt ghcFlavor ++ " " ++ cppOpts ghcFlavor ++ " " ++ stackResolverOpt resolver ++ "\""
    patchVersion version "ghc/ghc-lib-parser.cabal"
    mkTarball pkg_ghclib_parser
    renameDirectory pkg_ghclib_parser "ghc-lib-parser"
    removeFile "ghc/ghc-lib-parser.cabal"

    -- Make and extract an sdist of ghc-lib. The first argument is a
    -- ghc repo dir relative to '.' ('root'), 'patches' needs to be
    -- provided relative to 'root' (i.e. 'ghc') hence '../patches'.
    cmd $ "bash -c \"unset GHC_PACKAGE_PATH && cabal run exe:ghc-lib-gen -- ghc ../patches --ghc-lib " ++ ghcFlavorOpt ghcFlavor ++ " " ++ cppOpts ghcFlavor ++ " " ++ stackResolverOpt resolver ++ " " ++ "--skip-init\""
    patchVersion version "ghc/ghc-lib.cabal"
    patchConstraints version "ghc/ghc-lib.cabal"
    mkTarball pkg_ghclib
    renameDirectory pkg_ghclib "ghc-lib"
    removeFile "ghc/ghc-lib.cabal"

    copyDirectoryRecursive
      "ghc-lib-gen/ghc-lib-parser"
      "examples/ghc-lib-test-mini-hlint/extra-source-files"
    copyDirectoryRecursive
      "ghc-lib-gen/ghc-lib-parser"
      "examples/ghc-lib-test-mini-compile/extra-source-files/ghc-lib-parser"
    copyDirectoryRecursive
      "ghc-lib-gen/ghc-lib"
      "examples/ghc-lib-test-mini-compile/extra-source-files/ghc-lib"

    patchVersion version "ghc-lib-gen.cabal"
    patchVersion version "examples/ghc-lib-test-utils/ghc-lib-test-utils.cabal"
    patchConstraints version "examples/ghc-lib-test-utils/ghc-lib-test-utils.cabal"
    patchVersion version "examples/ghc-lib-test-mini-hlint/ghc-lib-test-mini-hlint.cabal"
    patchConstraints version "examples/ghc-lib-test-mini-hlint/ghc-lib-test-mini-hlint.cabal"
    patchVersion version "examples/ghc-lib-test-mini-compile/ghc-lib-test-mini-compile.cabal"
    patchConstraints version "examples/ghc-lib-test-mini-compile/ghc-lib-test-mini-compile.cabal"

    verifyConstraint "ghc-lib-parser == " version "ghc-lib/ghc-lib.cabal"
    verifyConstraint "ghc-lib-parser == " version "examples/ghc-lib-test-mini-hlint/ghc-lib-test-mini-hlint.cabal"
    verifyConstraint "ghc-lib-test-utils == " version "examples/ghc-lib-test-mini-hlint/ghc-lib-test-mini-hlint.cabal"
    verifyConstraint "ghc-lib-parser == " version "examples/ghc-lib-test-mini-compile/ghc-lib-test-mini-compile.cabal"
    verifyConstraint "ghc-lib == " version "examples/ghc-lib-test-mini-compile/ghc-lib-test-mini-compile.cabal"

    cmd "cabal sdist -o ."
    cmd "(cd examples/ghc-lib-test-utils && cabal sdist -o ../..)"
    cmd "(cd examples/ghc-lib-test-mini-hlint && cabal sdist -o ../..)"
    cmd "(cd examples/ghc-lib-test-mini-compile && cabal sdist -o ../..)"

    when noBuilds exitSuccess

    writeFile "cabal.project" $
      unlines [ "packages: "
              , "  ghc-lib-parser/ghc-lib-parser.cabal"
              , "  ghc-lib/ghc-lib.cabal"
              , "  examples/ghc-lib-test-utils/ghc-lib-test-utils.cabal"
              , "  examples/ghc-lib-test-mini-hlint/ghc-lib-test-mini-hlint.cabal"
              , "  examples/ghc-lib-test-mini-compile/ghc-lib-test-mini-compile.cabal"
              ]
    cmd "bash -c \"unset GHC_PACKAGE_PATH && cabal build -j all\""

    miniHlintCmdFile <- writeCabalCmdFile "ghc-lib-test-mini-hlint"
    miniCompileCmdFile <- writeCabalCmdFile "ghc-lib-test-mini-compile"
    system_ $ "bash -c \"cd examples/ghc-lib-test-mini-hlint && unset GHC_PACKAGE_PATH && cabal test --project-dir ../.. --test-show-details direct --test-options '--color always --test-command ../../ghc-lib-test-mini-hlint'\"" 
    system_ $ "bash -c \"cd examples/ghc-lib-test-mini-compile && unset GHC_PACKAGE_PATH && cabal test --project-dir ../.. --test-show-details direct --test-options '--color always --test-command ../../ghc-lib-test-mini-compile'\"" 
    system_ $ "bash -c 'cabal exec -- ghc -ignore-dot-ghci -package=ghc-lib-parser -e \"print 1\"'"
    system_ $ "bash -c 'cabal exec -- ghc -ignore-dot-ghci -package=ghc-lib -e \"print 1\"'"

    -- Something like, "8.8.1.20190828".
    tag -- The return value of type 'IO string'.

    where

      writeCabalCmdFile :: String -> IO FilePath
      writeCabalCmdFile exe = do
        let filename = exe
        writeFile filename "cabal run exe:" ++ exe ++ " --project-dir ../.. -- "
        pure filename

      ghcOptionsWithHaddock :: Maybe String -> String
      ghcOptionsWithHaddock = ghcOptionsOpt

      prelude :: (String, String) -> String
#if __GLASGOW_HASKELL__ == 902 && __GLASGOW_HASKELL_PATCHLEVEL1__ == 2
      prelude ("darwin", _) = "C_INCLUDE_PATH=`xcrun --show-sdk-path`/usr/include/ffi"
#endif
      prelude _ = ""

      stack :: String -> IO ()
      stack action = cmd $ prelude (os, arch) ++ " stack " ++
        concatMap (<> " ")
                 [ stackYamlOpt stackYaml
                 , stackResolverOpt resolver
                 , stackVerbosityOpt verbosity
                 , cabalVerboseOpt cabalVerbose
                 ] ++
        action

      cmd :: String -> IO ()
      cmd x = do
        putStrLn $ "\n\n# Running: " ++ x
        hFlush stdout
        (t, _) <- duration $ system_ x
        putStrLn $ "# Completed in " ++ showDuration t ++ ": " ++ x ++ "\n"
        hFlush stdout

      mkTarball :: String -> IO ()
      mkTarball target = do
        writeFile "stack.yaml" . (++ "- ghc\n") =<< readFile' "stack.yaml"
        cmd "(cd ghc && cabal sdist -o ..)"
        cmd $ "tar -xvf " ++ target ++ ".tar.gz"

      tag :: IO String
      tag = do
        suffix <- maybe genDateSuffix pure versionSuffix
        return $ genVersionStr ghcFlavor suffix

      patchVersion :: String -> FilePath -> IO ()
      patchVersion version file =
        writeFile file .
          -- ghc-lib, ghc-lib-parser
          replace "version: 0.1.0" ("version: " ++ version) .
          -- ghc-lib-test-mini-hlint, ghc-lib-test-mini-compile
          replace "version:             0.1.0.0" ("version: " ++ version)
          =<< readFile' file

      patchConstraints :: String -> FilePath -> IO ()
      patchConstraints version file =
        writeFile file .
          -- affects ghc-lib.cabal
          replace "        ghc-lib-parser\n" ("        ghc-lib-parser == " ++ version ++ "\n") .
          -- affects ghc-lib-test-utils, ghc-lib-test-mini-hlint, ghc-lib-test-mini-compile
          replace ", ghc-lib-test-utils" (", ghc-lib-test-utils == " ++ version ++ "\n") .
          replace ", ghc-lib\n" (", ghc-lib == " ++ version ++ "\n") .
          replace ", ghc-lib-parser\n" (", ghc-lib-parser == " ++ version ++ "\n")
          =<< readFile' file

      verifyConstraint :: String -> String -> String -> IO ()
      verifyConstraint constraint version file = do
        res <- stripInfix constraint <$> readFile' file
        case res of
          Just (_, r) -> do
            case words r of
              v : _ -> unless (v == version) exitError
              _ -> exitError
          Nothing -> exitError
       where
         exitError = die $ file ++ ": " ++ constraint ++ version ++ " not satisfied"

      removePath :: FilePath -> IO ()
      removePath p =
        whenM (doesPathExist p) $ do
          putStrLn $ "# Removing " ++ p
          removePathForcibly p

      gitCheckout :: GhcFlavor -> IO ()
      gitCheckout ghcFlavor = do
        cmd $ "cd ghc && git checkout -f " <> branch ghcFlavor
        case ghcFlavor of
          Da DaFlavor { patches, upstream } -> do
            cmd $ "cd ghc && git remote add upstream " <> upstream
            cmd   "cd ghc && git fetch upstream"
            cmd $ "cd ghc && git -c user.name=\"Cookie Monster\" -c user.email=cookie.monster@seasame-street.com merge --no-edit " <> unwords patches
          _ -> pure ()
        cmd "cd ghc && git submodule update --init --recursive"

      branch :: GhcFlavor -> String
      branch = \case
          Ghc9101 -> "ghc-9.10.1-release"
          Ghc982  -> "ghc-9.8.2-release"
          Ghc981  -> "ghc-9.8.1-release"
          Ghc966  -> "ghc-9.6.6-release"
          Ghc965  -> "ghc-9.6.5-release"
          Ghc964  -> "ghc-9.6.4-release"
          Ghc963  -> "ghc-9.6.3-release"
          Ghc962  -> "ghc-9.6.2-release"
          Ghc961  -> "ghc-9.6.1-release"
          Ghc948  -> "ghc-9.4.8-release"
          Ghc947  -> "ghc-9.4.7-release"
          Ghc946  -> "ghc-9.4.6-release"
          Ghc945  -> "ghc-9.4.5-release"
          Ghc944  -> "ghc-9.4.4-release"
          Ghc943  -> "ghc-9.4.3-release"
          Ghc942  -> "ghc-9.4.2-release"
          Ghc941  -> "ghc-9.4.1-release"
          Ghc928  -> "ghc-9.2.8-release"
          Ghc927  -> "ghc-9.2.7-release"
          Ghc926  -> "ghc-9.2.6-release"
          Ghc925  -> "ghc-9.2.5-release"
          Ghc924  -> "ghc-9.2.4-release"
          Ghc923  -> "ghc-9.2.3-release"
          Ghc922  -> "ghc-9.2.2-release"
          Ghc921  -> "ghc-9.2.1-release"
          Ghc901  -> "ghc-9.0.1-release"
          Ghc902  -> "ghc-9.0.2-release"
          Ghc8101 -> "ghc-8.10.1-release"
          Ghc8102 -> "ghc-8.10.2-release"
          Ghc8103 -> "ghc-8.10.3-release"
          Ghc8104 -> "ghc-8.10.4-release"
          Ghc8105 -> "ghc-8.10.5-release"
          Ghc8106 -> "ghc-8.10.6-release"
          Ghc8107 -> "ghc-8.10.7-release"
          Ghc881  -> "ghc-8.8.1-release"
          Ghc882  -> "ghc-8.8.2-release"
          Ghc883  -> "ghc-8.8.3-release"
          Ghc884  -> "ghc-8.8.4-release"
          Da DaFlavor { mergeBaseSha } -> mergeBaseSha
          GhcMaster hash -> hash

copyDirectoryRecursive :: FilePath -> FilePath -> IO ()
copyDirectoryRecursive srcDir destDir = withFrozenCallStack $ do
  srcFiles <- getDirectoryContentsRecursive srcDir
  copyFilesWith copyFile destDir [ (srcDir, f) | f <- srcFiles ]

getDirectoryContentsRecursive :: FilePath -> IO [FilePath]
getDirectoryContentsRecursive topdir = recurseDirectories [""]
  where
    recurseDirectories :: [FilePath] -> IO [FilePath]
    recurseDirectories [] = return []
    recurseDirectories (dir : dirs) = unsafeInterleaveIO $ do
      (files, dirs') <- collect [] [] =<< listDirectory (topdir </> dir)
      files' <- recurseDirectories (dirs' ++ dirs)
      return (files ++ files')
      where
        collect files dirs' [] = return (reverse files, reverse dirs')
        collect files dirs' (entry : entries) = do
          let dirEntry = dir </> entry
          isDirectory <- doesDirectoryExist (topdir </> dirEntry)
          if isDirectory
            then collect files (dirEntry : dirs') entries
            else collect (dirEntry : files) dirs' entries

copyFilesWith :: (FilePath -> FilePath -> IO ()) -> FilePath -> [(FilePath, FilePath)] -> IO ()
copyFilesWith doCopy targetDir srcFiles = withFrozenCallStack $ do
  let dirs = map (targetDir </>) . nub . map (takeDirectory . snd) $ srcFiles
  traverse_ (createDirectoryIfMissing True) dirs
  sequence_ [ let src = srcBase </> srcFile
                  dest = targetDir </> srcFile
               in doCopy src dest
            | (srcBase, srcFile) <- srcFiles ]

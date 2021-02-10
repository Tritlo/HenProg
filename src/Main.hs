{-# LANGUAGE TypeApplications, RecordWildCards, TupleSections #-}
module Main where


import Data.Maybe

import System.Process
import System.IO

import Data.Dynamic
import Data.List
import Data.Maybe
import Data.Char (isSpace)

import Text.ParserCombinators.ReadP

import Control.Monad (filterM, when)
import System.Timeout

import Control.Concurrent
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import System.Posix.Process
import System.Posix.Signals
import System.Exit
import System.Environment

import System.CPUTime
import Text.Printf

import Synth.Eval

import GhcPlugins (unLoc)

qcArgs = "stdArgs { chatty = False, maxShrinks = 0}"
qcImport = "import Test.QuickCheck"
buildCheckExprAtTy :: [String] -> [String] -> String -> String -> String
buildCheckExprAtTy props context ty expr =
     unlines [
         "let qc__ = "  ++ qcArgs
       , "    -- Context"
       , unlines (map ("    " ++) context)
       , "    -- Properties"
       , unlines (map ("    " ++) props)
       , "    expr__ :: " ++ ty
       , "    expr__ = "++  expr
       , "    propsToCheck__ = [ " ++
                 (intercalate
       "\n                     , " $ map propCheckExpr propNames) ++ "]"
       , "in ((sequence propsToCheck__) :: IO [Bool])"]
   where propNames = map (head . words) props
         -- We can't consolidate this into check__, since the type
         -- will be different!
         propCheckExpr pname = "isSuccess <$> quickCheckWithResult qc__ ("
                            ++ pname ++ " expr__ )"
         propToLet p = "    " ++ p

contextLet :: [String] -> String -> String
contextLet context l =
    unlines ["let"
            , unlines $ map ("    " ++)  context
            , "in " ++ l]

-- The time we allow for a check to finish. Measured in microseconds.
timeoutVal :: Int
timeoutVal = 1000000

runCheck :: Either [ValsAndRefs] Dynamic -> IO Bool
runCheck (Left l) = return False
runCheck (Right dval) =
  -- Note! By removing the call to "isSuccess" in the buildCheckExprAtTy we
  -- can get more information, but then there can be a mismatch of *which*
  -- `Result` type it is... even when it's the same QuickCheck but compiled
  -- with different flags. Ugh. So we do it this way, since *hopefully*
  -- Bool will be the same (unless *base* was compiled differently, *UGGH*).
  case fromDynamic @(IO [Bool]) dval of
      Nothing ->
        do pr_debug "wrong type!!"
           return False
      Just res ->
        -- We need to forkProcess here, since we might be evaulating
        -- non-yielding infinte expressions (like `last (repeat head)`), and
        -- since they never yield, we can't do forkIO and then stop that thread.
        -- If we could ensure *every library* was compiled with -fno-omit-yields
        -- we could use lightweight threads, but that is a very big restriction,
        -- especially if we want to later embed this into a plugin.
        do pid <- forkProcess (proc res)
           res <- timeout timeoutVal (getProcessStatus True False pid)
           case res of
             Just (Just (Exited ExitSuccess)) -> return True
             Nothing -> do signalProcess killProcess pid
                           return False
             _ -> return False
  where proc action =
          do res <- action
             exitImmediately $ if and res then ExitSuccess else (ExitFailure 1)

pr_debug :: String -> IO ()
pr_debug str = do dbg <- ("-fdebug" `elem`) <$> getArgs
                  when dbg $ putStrLn str

putStr' :: String -> IO ()
putStr' str = putStr str >> hFlush stdout

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace


type SynthInput = (CompileConfig, Int, [String], String, [String])
type Memo = IORef (Map SynthInput [String])


synthesizeSatisfying :: CompileConfig -> Int -> Memo -> [String]
                     -> [String] -> String -> IO [String]
synthesizeSatisfying _    depth     _       _  _     _ | depth < 0 = return []
synthesizeSatisfying cc depth ioref context props ty = do
  let inp = (cc, depth, context, ty, props)
  sM <- readIORef ioref
  case sM Map.!? inp of
    Just res -> pr_debug ("Found " ++ (show inp) ++ "!") >> return res
    Nothing -> do
      pr_debug $ "Synthesizing " ++ (show inp)
      mono_ty <- monomorphiseType cc ty
      Left r <- compileAtType cc (contextLet context "_") ty
      case r of
        ((vals,refs):_) -> do
          let rHoles = map readHole refs
          rHVs <- sequence $ map recur rHoles
          let cands = ((map showHF vals) ++ (map wrap $ concat rHVs))
              lv = length cands
          res <- if null props then return cands else do
             -- This ends the "GENERATING CANDIDATES..." message.
             case mono_ty of
               Nothing -> do
                 putStrLn "FAILED!"
                 putStrLn $ "COULD NOT MONOMORPHISE " ++ ty
                 putStrLn "THIS MEANS QUICKCHECKS CANNOT BE DONE!"
                 return []
               Just mty -> do
                 putStrLn "DONE!"
                 putStrLn $ "GENERATED " ++ show lv ++ " CANDIDATES!"
                 putStr' "COMPILING CANDIDATE CHECKS..."
                 let imps' = qcImport:importStmts cc
                     cc' = (cc {hole_lvl=0, importStmts=imps'})
                     to_check_exprs = map (bcat mty) cands
                 -- Doesn't work, since the types are too polymorphic, and if
                 -- the target type cannot be monomorphised, the fits will
                 -- be too general for QuickCheck
                 -- to_check_exprs <-
                 --    case mono_ty of
                 --        Just typ -> return $ map (bcat typ) cands
                 --        Nothing -> genCandTys cc' bcat cands
                 to_check <- zip cands <$> compileChecks cc' to_check_exprs
                 putStrLn "DONE!"
                 putStr' ("CHECKING " ++ (show lv) ++ " CANDIDATES...")
                 fits <- mapM
                   (\(i,(v,c)) ->
                      do pr_debug ((show i) ++ "/"++ (show lv) ++ ": " ++ v)
                         (v,) <$> runCheck c) $ zip [1..] to_check
                 putStrLn "DONE!"
                 pr_debug $ (show inp) ++ " fits done!"
                 let res = map fst $ filter snd fits
                 return res
          atomicModifyIORef' ioref (\m -> (Map.insert inp res m, ()))
          return res
        _ -> do atomicModifyIORef' ioref (\m -> (Map.insert inp [] m, ()))
                return []

  where
    bcat = buildCheckExprAtTy props context
    wrap p = "(" ++ p ++ ")"
    cc' = if depth <= 1 then (cc {hole_lvl=0}) else (cc {hole_lvl=1})
    recur :: (String, [String]) -> IO [String]
    recur (e, []) = return [e]
    recur (e, holes) = do
      pr_debug $ "Synthesizing for " ++ show holes
      holeFs <- mapM (synthesizeSatisfying cc' (depth-1) ioref context []) holes
      pr_debug $ (show holes) ++ " Done!"
      -- We synthesize for each of the holes, and then produce ALL COMBINATIONS
      return $
       if any null holeFs then []
       else map ((e ++ " ") ++) $ map unwords $ combinations holeFs
      where combinations :: [[String]] -> [[String]]
            combinations [] = [[]]
            -- List monad magic
            combinations (c:cs) = do x <- c
                                     xs <- combinations cs
                                     return (x:xs)


hasDebug :: IO Bool
hasDebug = ("-fdebug" `elem`) <$> getArgs

data SynthFlags = SFlgs { synth_holes :: Int
                        , synth_depth :: Int
                        , synth_debug :: Bool}


getFlags :: IO SynthFlags
getFlags = do args <- Map.fromList . (map (break (== '='))) <$> getArgs
              let synth_holes = case args Map.!? "-fholes" of
                                    Just r | not (null r) -> read (tail r)
                                    Nothing -> 2
                  synth_depth = case args Map.!? "-fdepth" of
                                    Just r | not (null r) -> read (tail r)
                                    Nothing -> 1
                  synth_debug = "-fdebug" `Map.member` args
              when (synth_holes < 0) (error "NUMBER OF HOLES CANNOT BE NEGATIVE!")
              when (synth_depth < 0) (error "DEPTH CANNOT BE NEGATIVE!")
              return $ SFlgs {..}

-- All the packages here need to be *globally* available. We should fix this
-- by wrapping it in e.g. a nix-shell or something.
pkgs = ["base", "process", "QuickCheck" ]

imports = [
    "import Prelude hiding (id, ($), ($!), asTypeOf)"
  ]



compConf :: CompileConfig
compConf = CompConf { importStmts = imports
                    , packages = pkgs
                    , hole_lvl = 0}


repair :: CompileConfig -> [String] -> [String] -> String -> String -> IO [String]
repair cc props context ty wrong_prog =
   do let prog_at_ty = "("++ wrong_prog ++ ") :: " ++ ty
      res <- getHoley cc prog_at_ty
      -- We add the context by replacing a hole in a let.
      holeyContext <- runJustParseExpr cc $ contextLet context "_"
      let addContext = fromJust . fillHole holeyContext . unLoc

      fits <- mapM (\e -> (e,) <$> (getHoleFits cc $ addContext e)) res
      let repls = fits >>= (uncurry replacements)
          to_check = map (trim . showUnsafe) repls
          bcat = buildCheckExprAtTy props context ty
          checks = map bcat to_check
      pr_debug  "Fix candidates:"
      mapM pr_debug to_check
      let cc' = (cc {hole_lvl=0, importStmts=(qcImport:importStmts cc)})
      compiled_checks <- zip repls <$> compileChecks cc' checks
      res2 <- map fst <$> filterM (\(r,c) -> runCheck c) compiled_checks
      return $ map showUnsafe res2

showTime :: Integer -> String
showTime time = if res > 1000
                then (printf "%.2f" ((fromIntegral res * 1e-3) :: Double)) ++ "s"
                else show res ++ "ms"
  where res :: Integer
        res = (floor $ (fromIntegral time) * 1e-9)

time :: IO a -> IO (Integer, a)
time act = do start <- getCPUTime
              r <- act
              done <- getCPUTime
              return (done - start, r)

main :: IO ()
main = do
    SFlgs {..} <- getFlags
    let cc = compConf {hole_lvl=synth_holes}
        props = [ "prop_is_symmetric f xs = f xs == f (reverse xs)"
                , "prop_bin f = f [] == 0 || f [] == 1"
                , "prop_not_const f = not (f [] == f [1,2,3])"
                , "prop_is_sum f = f [1,2,3] == 6" ]
        ty = "[Int] -> Int"
        wrong_prog = "foldl (-) 0"
        context = [ "zero = 0 :: Int"
                  , "one = 1 :: Int"
                  , "add = (+) :: Int -> Int -> Int"]
    putStrLn "SCOPE:"
    mapM_ (putStrLn . ("  " ++)) imports
    putStrLn "TARGET TYPE:"
    putStrLn $ "  "  ++ ty
    putStrLn "MUST SATISFY:"
    mapM_ (putStrLn . ("  " ++)) props
    putStrLn "IN CONTEXT:"
    mapM_ (putStrLn . ("  " ++)) context
    putStrLn "PARAMETERS:"
    putStrLn $ "  MAX HOLES: "  ++ (show synth_holes)
    putStrLn $ "  MAX DEPTH: "  ++ (show synth_depth)
    putStr' "PORGAM TO REPAIR: "
    putStrLn wrong_prog
    putStr' "REPAIRING..."
    (t, fixes) <- time $ repair cc props context ty wrong_prog
    putStrLn $ "DONE! (" ++ showTime t ++ ")"
    putStrLn "REPAIRS:"
    mapM (putStrLn . (++) "  " . trim) fixes

    putStrLn "SYNTHESIZING..."
    memo <- newIORef (Map.empty)
    putStr' "GENERATING CANDIDATES..."
    (t, r) <- time $ synthesizeSatisfying cc synth_depth memo context props ty
    putStrLn $ "DONE! (" ++ showTime t ++ ")"
    case r of
        [] -> putStrLn "NO MATCH FOUND!"
        [xs] -> do putStrLn "FOUND MATCH:"
                   putStrLn xs
        xs -> do putStrLn $ "FOUND " ++ (show  $ length xs) ++" MATCHES:"
                 mapM_ putStrLn xs



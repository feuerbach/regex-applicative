--------------------------------------------------------------------
-- |
-- Module    : Text.Regex.Applicative.Object
-- Copyright : (c) Roman Cheplyaka
-- License   : MIT
--
-- Maintainer: Roman Cheplyaka <roma@ro-che.info>
-- Stability : experimental
--
-- This is a low-level interface to the regex engine.
--------------------------------------------------------------------
{-# LANGUAGE TypeFamilies, GADTs #-}
module Text.Regex.Applicative.Object
    ( ReObject
    , compile
    , Thread
    , threads
    , failed
    , isResult
    , results
    , ThreadId
    , threadId
    , step
    , fromThreads
    ) where

import Text.Regex.Applicative.Types
import Text.Regex.Applicative.StateQueue
import qualified Text.Regex.Applicative.Compile as Compile
import Data.Maybe
import Control.Monad.State
import Control.Applicative hiding (empty)

-- | The state of the engine is represented as a \"regex object\" of type
-- @'ReObject' s r@, where @s@ is the type of symbols and @r@ is the
-- result type (as in the 'RE' type). Think of 'ReObject' as a collection of
-- 'Thread's ordered by priority. E.g. threads generated by the left part of
-- '<|>' come before the threads generated by the right part.
newtype ReObject s r = ReObject (StateQueue (Thread s r))

-- | List of all threads of an object
threads :: ReObject s r -> [Thread s r]
threads (ReObject sq) = getElements sq

-- | Create an object from a list of threads. It is recommended that all
-- threads come from the same 'ReObject', unless you know what you're doing.
-- However, it should be safe to filter out or rearrange threads.
fromThreads :: [Thread s r] -> ReObject s r
fromThreads ts = ReObject $ foldl (flip insertThread) empty ts

isResult :: Thread s r -> Bool
isResult Accept {} = True
isResult _ = False

getResult :: Thread s r -> Maybe r
getResult (Accept r) = Just r
getResult _ = Nothing

-- | Checks if the object has no threads. In that case it never will
-- produce any new threads as a result of 'step'.
failed :: ReObject s r -> Bool
failed obj = null $ threads obj

results :: ReObject s r -> [r]
results obj =
    mapMaybe getResult $ threads obj

-- | Feeds a symbol into a regex object
step :: s -> ReObject s r -> ReObject s r
step s (ReObject sq) =
    let accum q t =
            case t of
                Accept {} -> q
                Thread _ c ->
                    foldl (\q x -> insertThread x q) q $ c s
        newQueue = fold accum empty sq
    in ReObject newQueue

insertThread t q =
    case  t of
        Accept {} -> insert t q
        Thread { threadId_ = ThreadId i } -> insertUnique i t q

-- | Compiles a regular expression into a regular expression object
compile :: RE s r -> ReObject s r
compile =
    fromThreads .
    flip Compile.compile (\x -> [Accept x]) .
    renumber

renumber :: RE s a -> RE s a
renumber e = flip evalState 1 $ go e
  where
    go :: RE s a -> State ThreadId (RE s a)
    go e =
        case e of
            Eps -> return Eps
            Symbol _ p -> Symbol <$> fresh <*> pure p
            Alt a1 a2 -> Alt <$> go a1 <*> go a2
            App a1 a2 -> App <$> go a1 <*> go a2
            Fmap f a -> Fmap f <$> go a
            Rep f b a -> Rep f b <$> go a

fresh :: (MonadState m, StateType m ~ ThreadId) => m ThreadId
fresh = do
    i <- get
    put $! i+1
    return i
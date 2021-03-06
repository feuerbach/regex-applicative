{-# LANGUAGE GADTs #-}
module Text.Regex.Applicative.Compile (compile) where

import Control.Monad ((<=<))
import Control.Monad.Trans.State
import Data.Foldable
import Data.Maybe
import Data.Monoid (Any (..))
import qualified Data.IntMap as IntMap
import Text.Regex.Applicative.Types

compile :: RE s a -> (a -> [Thread s r]) -> [Thread s r]
compile e k = compile2 e (SingleCont k)

data Cont a = SingleCont !a | EmptyNonEmpty !a !a

instance Functor Cont where
    fmap f k =
        case k of
            SingleCont a -> SingleCont (f a)
            EmptyNonEmpty a b -> EmptyNonEmpty (f a) (f b)

emptyCont :: Cont a -> a
emptyCont k =
    case k of
        SingleCont a -> a
        EmptyNonEmpty a _ -> a
nonEmptyCont :: Cont a -> a
nonEmptyCont k =
    case k of
        SingleCont a -> a
        EmptyNonEmpty _ a -> a

-- compile2 function takes two continuations: one when the match is empty and
-- one when the match is non-empty. See the "Rep" case for the reason.
compile2 :: RE s a -> Cont (a -> [Thread s r]) -> [Thread s r]
compile2 e =
    case e of
        Eps -> \k -> emptyCont k ()
        Symbol i p -> \k -> [t $ nonEmptyCont k] where
          -- t :: (a -> [Thread s r]) -> Thread s r
          t k = Thread i $ \s ->
            case p s of
              Just r -> k r
              Nothing -> []
        App n1 n2 ->
            let a1 = compile2 n1
                a2 = compile2 n2
            in \k -> case k of
                SingleCont k -> a1 $ SingleCont $ \a1_value -> a2 $ SingleCont $ k . a1_value
                EmptyNonEmpty ke kn ->
                    a1 $ EmptyNonEmpty
                        -- empty
                        (\a1_value -> a2 $ EmptyNonEmpty (ke . a1_value) (kn . a1_value))
                        -- non-empty
                        (\a1_value -> a2 $ EmptyNonEmpty (kn . a1_value) (kn . a1_value))
        Alt n1 n2 ->
            let a1 = compile2 n1
                a2 = compile2 n2
            in \k -> a1 k ++ a2 k
        Fail -> const []
        Fmap f n -> let a = compile2 n in \k -> a $ fmap (. f) k
        CatMaybes n -> let a = compile2 n in \k -> a $ (<=< toList) <$> k
        -- This is actually the point where we use the difference between
        -- continuations. For the inner RE the empty continuation is a
        -- "failing" one in order to avoid non-termination.
        Rep g f b n ->
            let a = compile2 n
                threads b k =
                    combine g
                        (a $ EmptyNonEmpty (\_ -> []) (\v -> let b' = f b v in threads b' (SingleCont $ nonEmptyCont k)))
                        (emptyCont k b)
            in threads b
        Void n
          | hasCatMaybes n -> compile2 n . fmap (. \ _ -> ())
          | otherwise -> compile2_ n . fmap ($ ())

data FSMState
    = SAccept
    | STransition !ThreadId

type FSMMap s = IntMap.IntMap (s -> Bool, [FSMState])

mkNFA :: RE s a -> ([FSMState], (FSMMap s))
mkNFA e =
    flip runState IntMap.empty $
        go e [SAccept]
  where
  go :: RE s a -> [FSMState] -> State (FSMMap s) [FSMState]
  go e k =
    case e of
        Eps -> return k
        Symbol i@(ThreadId n) p -> do
            modify $ IntMap.insert n $
                (isJust . p, k)
            return [STransition i]
        App n1 n2 -> go n1 =<< go n2 k
        Alt n1 n2 -> (++) <$> go n1 k <*> go n2 k
        Fail -> return []
        Fmap _ n -> go n k
        CatMaybes _ -> error "mkNFA CatMaybes"
        Rep g _ _ n ->
            let entries = findEntries n
                cont = combine g entries k
            in
            -- return value of 'go' is ignored -- it should be a subset of
            -- 'cont'
            go n cont >> return cont
        Void n -> go n k

  findEntries :: RE s a -> [FSMState]
  findEntries e =
    -- A simple (although a bit inefficient) way to find all entry points is
    -- just to use 'go'
    evalState (go e []) IntMap.empty

hasCatMaybes :: RE s a -> Bool
hasCatMaybes = getAny . foldMapPostorder (Any . \ case CatMaybes _ -> True; _ -> False)

compile2_ :: RE s a -> Cont [Thread s r] -> [Thread s r]
compile2_ e =
    let (entries, fsmap) = mkNFA e
        mkThread _ k1 (STransition i@(ThreadId n)) =
            let (p, cont) = fromMaybe (error "Unknown id") $ IntMap.lookup n fsmap
            in [Thread i $ \s ->
                if p s
                    then concatMap (mkThread k1 k1) cont
                    else []]
        mkThread k0 _ SAccept = k0

    in \k -> concatMap (mkThread (emptyCont k) (nonEmptyCont k)) entries

combine :: Greediness -> [a] -> [a] -> [a]
combine g continue stop =
    case g of
        Greedy -> continue ++ stop
        NonGreedy -> stop ++ continue

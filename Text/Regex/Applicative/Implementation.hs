{-# LANGUAGE GADTs, TupleSections, DeriveFunctor #-}
module Text.Regex.Applicative.Implementation where
import Control.Applicative
import Data.List
import qualified Data.Sequence as Sequence

-- | An applicative functor similar to Maybe, but it's '<|>' method honors
-- priority.
data Priority a = Priority { priority :: !PrSeq, pValue :: a } | Fail
    deriving (Functor, Show)
type PrSeq = Sequence.Seq PrNum
type PrNum = Int

instance Applicative Priority where
    pure x = Priority Sequence.empty x
    Priority p1 f <*> Priority p2 x = Priority (p1 Sequence.>< p2) (f x)
    _ <*> _ = Fail

instance Alternative Priority where
    empty = Fail
    p@Priority {} <|> Fail = p
    Fail <|> p@Priority {} = p
    Fail <|> Fail = Fail
    p1@Priority {} <|> p2@Priority {} =
        case compare (priority p1) (priority p2) of
            LT -> p2
            GT -> p1
            EQ -> error $
                "Two priorities are the same! Should not happen.\n" ++ show (priority p1)


-- Adds priority to the end
withPriority :: PrNum -> Priority a -> Priority a
withPriority p (Priority ps x) = Priority (ps Sequence.|> p) x
withPriority _ Fail = Fail

-- Overwrite the priority
--setPriority :: PrSeq -> Priority a -> Priority a

-- Discards priority information
priorityToMaybe :: Priority a -> Maybe a
priorityToMaybe p =
    case p of
        Priority { pValue = x } -> Just x
        Fail -> Nothing

data Regexp s r a where
    Eps :: Regexp s r a
    Symbol :: (s -> Bool) -> Regexp s r s
    Alt :: RegexpNode s r a -> RegexpNode s r a -> Regexp s r a
    App :: RegexpNode s (a -> r) (a -> b) -> RegexpNode s r a -> Regexp s r b
    Fmap :: (a -> b) -> RegexpNode s r a -> Regexp s r b
    Rep :: (b -> a -> b) -- folding function (like in foldl)
        -> b             -- the value for zero matches, and also the initial value
                         -- for the folding function
        -> RegexpNode s (b, b -> r) a
                         -- Elements of the 2-tuple are the value accumulated so far
                         -- and the continuation
        -> Regexp s r b

data RegexpNode s r a = RegexpNode
    { active :: !Bool
    , skip   :: !(Priority a)
    , final_ :: !(Priority r)
    , reg    :: !(Regexp s r a)
    }

isOK p =
    case p of
        Fail -> False
        Priority {} -> True

emptyChoice p1 p2 = withPriority 1 p1 <|> withPriority 0 p2

final r = if active r then final_ r else empty

epsNode :: RegexpNode s r a
epsNode = RegexpNode
    { active = False
    , skip   = pure $ error "epsNode"
    , final_ = empty
    , reg    = Eps
    }

symbolNode :: (s -> Bool) -> RegexpNode s r s
symbolNode c = RegexpNode
    { active = False
    , skip   = empty
    , final_ = empty
    , reg    = Symbol c
    }

altNode :: RegexpNode s r a -> RegexpNode s r a -> RegexpNode s r a
altNode a1 a2 = RegexpNode
    { active = active a1 || active a2
    , skip   = skip a1 `emptyChoice` skip a2
    , final_ = final a1 <|> final a2
    , reg    = Alt a1 a2
    }

appNode :: RegexpNode s (a -> r) (a -> b) -> RegexpNode s r a -> RegexpNode s r b
appNode a1 a2 = RegexpNode
    { active = active a1 || active a2
    , skip   = skip a1 <*> skip a2
    , final_ = final a1 <*> skip a2 <|> final a2
    , reg    = App a1 a2
    }

fmapNode :: (a -> b) -> RegexpNode s r a -> RegexpNode s r b
fmapNode f a = RegexpNode
    { active = active a
    , skip = fmap f $ skip a
    , final_ = final a
    , reg = Fmap f a
    }

repNode :: (b -> a -> b) -> b -> RegexpNode s (b, b -> r) a -> RegexpNode s r b
repNode f b a = RegexpNode
    { active = active a
    , skip = withPriority 0 $ pure b
    , final_ = withPriority 0 $ (\(b, f) -> f b) <$> final a
    , reg = Rep f b a
    }

shift :: Priority (a -> r) -> RegexpNode s r a -> s -> RegexpNode s r a
shift Fail r _ | not $ active r = r
shift k re s =
    case reg re of
        Eps -> re
        Symbol predicate ->
            let f = k <*> if predicate s then pure s else empty
            in re { final_ = f, active = isOK f }
        Alt a1 a2 -> altNode (shift (withPriority 1 k) a1 s) (shift (withPriority 0 k) a2 s)
        App a1 a2 -> appNode
            (shift kc a1 s)
            (shift (kc <*> skip a1 <|> final a1) a2 s)
            where kc = fmap (.) k
        Fmap f a -> fmapNode f $ shift (fmap (. f) k) a s
        Rep f b a -> repNode f b $ shift k' a s
            where
            k' = withPriority 1 $
                    (\(b, k) -> \a -> (f b a, k)) <$>
                        ((b,) <$> k <|> final a)

match :: RegexpNode s r r -> [s] -> Priority r
match r [] = skip r
match r (s:ss) = final $
    foldl' (\r s -> shift empty r s) (shift (pure id) r s) ss
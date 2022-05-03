{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveTraversable  #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE KindSignatures     #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}
module Plutonomy.Hereditary where

import Data.Foldable      (foldl', toList)
import Data.Kind          (Type)
import Data.Sequence      (Seq)
import Data.String        (IsString (..))
import Data.Text          (Text)
import PlutusCore.Default (DefaultFun (..), DefaultUni (..), Some (..), ValueOf (..))

import qualified Data.Sequence as Seq

import Plutonomy.Builtins
import Plutonomy.Name
import Plutonomy.Raw      (Raw)
import Plutonomy.Known    (pattern RawFix)
import Subst

import qualified Plutonomy.Raw as Raw

-- $setup
-- >>> import Subst (Nat (..))
-- >>> import Data.Text (Text)
-- >>> import Plutonomy.Pretty (prettyRaw)
-- >>> import qualified Prettyprinter as PP
-- >>> let pp t = prettyRaw PP.pretty (toRaw (t :: Term Text Z))

-------------------------------------------------------------------------------
-- * Types
-------------------------------------------------------------------------------

-- | Term representation.
--
-- This representation is more-normalised then the 'Term'.
-- It forces applications to form 'mkLet bindings (we don't perfrom substitions!)
--
-- In addition the applications are represented in spine form,
-- therefore we can quickly access the head of a spine,
-- which we do often in the optimizer.
--
-- Terms are either
--
-- * Definitions 'Defn'
--
-- * Error
--
-- * or 'mkLet binding.
--
-- Before using this representation the @Script size" tests took 13.5 seconds.
-- Using @'toRaw' . 'fromRaw'@ as a simplify function takes 14.2 seconds.
--
type Term :: Type -> Nat -> Type
data Term a n
    = Defn (Defn a n)
    | Error
    | Let Name (Defn a n) (Term a (S n))
  deriving (Eq, Ord, Show)

-- | 'Spine' head is
--
-- * a variable ('HeadVar')
--
-- * free ('HeadFree')
--
-- * or a builtin ('HeadBuiltin')
--
data Head a n
    = HeadVar (Var n)
    | HeadFree a
    | HeadBuiltin DefaultFun
    | HeadFix
  deriving (Eq, Ord, Show)

-- | Eliminators.
--
-- * Applications of an argument to a function ('App'), or
--
-- * Forcing of delayed terms ('Force').
--
-- Technically builtins should be eliminators, but we treat
-- them more like free variables.
--
data Elim a n
    = App (Term a n)
    | Force
    | Fst
    | Snd
  deriving (Eq, Ord, Show)

-- | Definition forms.
--
-- * Neutral spines
--
-- * Lambda abstractions ('Lam'),
--
-- * Delayed terms ('Delay'), or
--
-- * Constants ('Constant').
--
-- in other forms neutral terms and introduction forms.
--
data Defn a n
    = Neutral (Head a n) (Spine a n)
    | Lam Name (Term a (S n))
    | Delay (Term a n)
    | Constant (Some (ValueOf DefaultUni))
  deriving (Eq, Ord, Show)

type Spine a n = Seq (Elim a n)

-------------------------------------------------------------------------------
-- * Patterns
-------------------------------------------------------------------------------

pattern Var :: Var n -> Term a n
pattern Var x = Defn (Neutral (HeadVar x) Seq.Empty)

pattern Free :: a -> Term a n
pattern Free x = Defn (Neutral (HeadFree x) Seq.Empty)

pattern Builtin :: DefaultFun -> Term a n
pattern Builtin x = Defn (Neutral (HeadBuiltin x) Seq.Empty)

pattern Var0 :: Term a (S n)
pattern Var0 = Var VZ

pattern Var1 :: Term a (S (S n))
pattern Var1 = Var (VS VZ)

pattern Var2 :: Term a (S (S (S n)))
pattern Var2 = Var (VS (VS VZ))

-------------------------------------------------------------------------------
-- * Instances
-------------------------------------------------------------------------------

instance IsString a => IsString (Term a n) where
    fromString = Free . fromString

instance Rename (Term a) where
    r <@> Defn t    = Defn (r <@> t)
    r <@> Let n t s = Let n (r <@> t) (liftRen r <@> s)
    _ <@> Error     = Error

instance Rename (Defn a) where
    r <@> Neutral h xs = Neutral (r <@> h) (fmap (r <@>) xs)
    r <@> Lam n t      = Lam n (liftRen r <@> t)
    r <@> Delay t      = Delay (r <@> t)
    _ <@> Constant c   = Constant c

instance Rename (Head a) where
    r <@> HeadVar x     = HeadVar (r <@> x)
    _ <@> HeadFix       = HeadFix
    _ <@> HeadFree x    = HeadFree x
    _ <@> HeadBuiltin b = HeadBuiltin b

instance Rename (Elim a) where
    r <@> App t = App (r <@> t)
    _ <@> Force = Force
    _ <@> Fst   = Fst
    _ <@> Snd   = Snd

instance Vars (Term a) where
    var  = Var

instance Vars (Defn a) where
    var x = Neutral (HeadVar x) Seq.Empty
    bound = flip defnVars pure

instance Subst (Term a) where
    subst = substTerm

substTerm :: Sub (Term a) n m -> Term a n -> Term a m
substTerm  sub (Defn i)    = substDefn sub i
substTerm _sub Error       = Error
substTerm  sub (Let n t s) = mkLet n (substDefn sub t) (substTerm (liftSub sub) s)

substDefn :: Sub (Term a) n m -> Defn a n -> Term a m
substDefn  sub (Neutral h xs) = neutral_ (substHead sub h) (substElim sub <$> xs)
substDefn  sub (Lam n b     ) = Defn (Lam n (subst (liftSub sub) b))
substDefn  sub (Delay t     ) = Defn (Delay (subst sub t))
substDefn _sub (Constant c  ) = Defn (Constant c)

substHead :: Sub (Term a) n m -> Head a n -> Term a m
substHead _sub (HeadFree x)    = Free x
substHead _sub (HeadBuiltin b) = Builtin b
substHead  sub (HeadVar x)     = substVar sub x
substHead _sub HeadFix         = Defn (Neutral HeadFix Seq.Empty)

substElim :: Sub (Term a) n m -> Elim a n -> Elim a m
substElim  sub (App x) = App (subst sub x)
substElim _sub Force   = Force
substElim _sub Fst     = Fst
substElim _sub Snd     = Snd

instance Free Term where
    ret    = Free
    (>>==) = bindTerm
    vars   = termVars

bindTerm :: Term a n -> (a -> Term b n) -> Term b n
bindTerm (Defn i   ) k = bindDefn i k
bindTerm (Error    ) _ = Error
bindTerm (Let n t s) k = mkLet n (bindDefn t k) (bindTerm s (weaken . k))

bindHead :: Head a n -> (a -> Term b n) -> Term b n
bindHead (HeadFree x)    k = k x
bindHead (HeadVar x)     _ = Var x
bindHead (HeadBuiltin b) _ = Builtin b
bindHead HeadFix         _ = Defn (Neutral HeadFix Seq.empty)

bindElim :: Elim a n -> (a -> Term b n) -> Elim b n
bindElim (App x) k = App (bindTerm x k)
bindElim Force   _ = Force
bindElim Fst     _ = Fst
bindElim Snd     _ = Snd

bindDefn :: Defn a n -> (a -> Term b n) -> Term b n
bindDefn (Neutral h xs) k = neutral_ (bindHead h k) (fmap (`bindElim` k) xs)
bindDefn (Lam n t   ) k   = Defn (Lam n (bindTerm t (weaken . k)))
bindDefn (Delay t   ) k   = Defn (Delay (bindTerm t k))
bindDefn (Constant c) _   = Defn (Constant c)

termVars ::  Applicative f => (Var n -> f (Var m)) -> (a -> f b) -> Term a n -> f (Term b m)
termVars f g (Defn i)       = Defn <$> defnVars f g i
termVars _ _ (Error       ) = pure Error
termVars f g (Let n t s   ) = Let n <$> defnVars f g t <*> termVars f' g s where
    f' VZ     = pure VZ
    f' (VS x) = VS <$> f x

headVars :: Applicative f => (Var n -> f (Var m)) -> (a -> f b) -> Head a n -> f (Head b m)
headVars _ g (HeadFree x)    = HeadFree <$> g x
headVars _ _ (HeadBuiltin b) = pure (HeadBuiltin b)
headVars f _ (HeadVar x)     = HeadVar <$> f x
headVars _ _ HeadFix         = pure HeadFix

elimVars :: Applicative f => (Var n -> f (Var m)) -> (a -> f b) -> Elim a n -> f (Elim b m)
elimVars f g (App x) = App <$> vars f g x
elimVars _ _ Force   = pure Force
elimVars _ _ Fst     = pure Fst
elimVars _ _ Snd     = pure Snd

defnVars :: Applicative f => (Var n -> f (Var m)) -> (a -> f b) -> Defn a n -> f (Defn b m)
defnVars f g (Neutral h xs) = Neutral <$> headVars f g h <*> traverse (elimVars f g) xs
defnVars f g (Lam n t)      = Lam n <$> vars f' g t where
    f' VZ     = pure VZ
    f' (VS x) = VS <$> f x
defnVars _ _ (Constant c  ) = pure (Constant c)
defnVars f g (Delay t     ) = Delay <$> vars f g t

-------------------------------------------------------------------------------
-- * Value
-------------------------------------------------------------------------------

-- | Applications, Forcing terms, 'mkLet and 'Error' are not values.
--
-- Unsaturated applications of builtins are also values.
--
-- >>> isValue (const 0) (const 0) (force_ trace_ :@ str_ "err")
-- True
--
-- >>> isValue (const 0) (const 0) (force_ trace_ :@ str_ "err" :@ tt_)
-- False
--
-- >>> isValue (const 0) (const 0) $ fix_ :@ lams_ ["rec", "x"] "x"
-- True
--
isValue
    :: (Var n -> Int)
    -> (a -> Int)
    -> Term a n
    -> Bool
isValue _ _ Error {}                                  = False
isValue _ _ Let {}                                    = False
isValue _ _ (Defn (Neutral (HeadBuiltin b) args))     = builtinArity b > length args
isValue v _ (Defn (Neutral (HeadVar x) args))         = null args || v x > length args
isValue _ h (Defn (Neutral (HeadFree x) args))        = null args || h x > length args
isValue _ _ (Defn (Neutral HeadFix Seq.Empty))        = True
isValue _ _ (Defn (Neutral HeadFix (f Seq.:<| args))) = elimArity f - 1 > length args
isValue _ _ (Defn Lam {})                             = True
isValue _ _ (Defn Delay {})                           = True
isValue _ _ (Defn Constant {})                        = True

-- | Approximate arity of a term.
--
-- >>> termArity $ lam_ "x" "x"
-- 1
--
-- >>> termArity $ lams_ ["x","y","z"] "x"
-- 3
--
-- >>> termArity "free"
-- 0
--
termArity :: Term a n -> Int
termArity (Defn d) = defnArity d
termArity _        = 0

elimArity :: Elim a n -> Int
elimArity (App t) = termArity t
elimArity Force   = 0
elimArity Fst     = 0
elimArity Snd     = 0

defnArity :: Defn a n -> Int
defnArity = go 0 where
    go :: Int -> Defn a n -> Int
    go !acc (Lam _ t) = go' (acc + 1) t
    go  acc (Delay t) = go' (acc + 1) t
    go  acc _         = acc

    go' :: Int -> Term a n -> Int
    go' !acc (Defn t) = go acc t
    go'  acc _        = acc

-------------------------------------------------------------------------------
-- * Error
-------------------------------------------------------------------------------

isErrorTerm :: Term n a -> Bool
isErrorTerm Error = True
isErrorTerm _     = False

isErrorElim :: Elim n a -> Bool
isErrorElim (App t) = isErrorTerm t
isErrorElim Force   = False
isErrorElim Fst     = False
isErrorElim Snd     = False

-------------------------------------------------------------------------------
-- * Normilising \"constructors\"
-------------------------------------------------------------------------------

neutral_ :: Foldable f => Term a n -> f (Elim a n) -> Term a n
neutral_ = foldl' elim_

elim_ :: Term a n -> Elim a n -> Term a n
elim_ h Force   = force_ h
elim_ h (App x) = app_ h x
elim_ h Fst     = fst_ h
elim_ h Snd     = snd_ h

-- | Let constructor on terms.
--
-- This automatically does /let-from-let/ transformation.
--
-- >>> let term = let_ "x" (let_ "y" (delay_ "foo") (delay_ "bar")) ("body" :@ "x" :@ "z")
-- >>> pp term
-- let* y = \ ~ -> foo
--      x = \ ~ -> bar
-- in body x z
--
-- It also inlines cheap definitions.
--
-- >>> let term = let_ "x" "foo" "x"
-- >>> pp term
-- foo
--
mkLet :: Name -> Term b n -> Term b (S n) -> Term b n
mkLet _ t            Var0 = t
mkLet _ Error        _    = Error
mkLet n (Defn d)     r    = mkLet' n d r
mkLet n (Let n' t s) r    = Let n' t $ mkLet n s (rename bumpRen r)

-- cheap definitions
mkLet' :: Name -> Defn b n -> Term b (S n) -> Term b n
mkLet' n d r
    | cheap d            = instantiate1 (Defn d) r
    | otherwise          = Let n d r
  where
    cheap :: Defn a m -> Bool
    cheap (Delay Error)         = True
    cheap (Lam _ Error)         = True
    cheap (Lam _ Var0)          = True
    cheap (Neutral _ Seq.Empty) = True
    cheap _                     = False

-------------------------------------------------------------------------------
-- * Smart constructors
-------------------------------------------------------------------------------

-- | Application @f x@
--
-- This automatically reduces an application of @'Lam' n s@ to @t@ to @'mkLet n t s@.
-- This also floats let from the head of application.
--
-- >>> let term = let_ "n" (delay_ "def") "f" :@ "x"
-- >>> pp term
-- let* n = \ ~ -> def
-- in f x
--
app_ :: Term a n -> Term a n -> Term a n
app_ (Defn (Neutral h xs)) x = Defn (Neutral h (xs Seq.|> App x))
app_ (Defn (Lam n t))   x = mkLet n x t
app_ (Defn Delay {})    _ = Error
app_ (Defn Constant {}) _ = Error
app_ (Let n t s)        x = Let n t (app_ s (weaken x))
app_ Error              _ = Error

-- | Matching oa npplication.
matchApp_ :: Term a n -> Maybe (Term a n, Term a n)
matchApp_ (Defn (Neutral h (xs Seq.:|> App x))) = Just (Defn (Neutral h xs), x)
matchApp_ _                                     = Nothing

-- | Infix version of 'app_'
--
-- >>> pp $ lam_ "x" $ "x" :@ "x"
-- \ x -> x x
--
pattern (:@) :: Term a n -> Term a n -> Term a n
pattern (:@) f x <- (matchApp_ -> Just (f, x))
  where (:@) f x = app_ f x
infixl 9 :@

-- | Force @f !@
--
-- This automatically reduces forcing of @'Delay' t@ to @t@
-- This also floats out lets (or floats ins @!@).
--
-- >>> let term = force_ (delay_ "t")
-- >>> pp term
-- t
---
force_ :: Term a n -> Term a n
force_ (Defn (Neutral h xs)) = Defn (Neutral h (xs Seq.|> Force))
force_ (Defn (Delay t))   = t
force_ (Defn Lam {})      = Error
force_ (Defn Constant {}) = Error
force_ (Let n t s)        = Let n t (force_ s)
force_ Error              = Error

-- | 'Delay'.
delay_ :: Term a n -> Term a n
delay_ = Defn . Delay

-- | N-ary application.
--
-- >>> pp $ apps_ "f" ["x", "y", "z"]
-- f x y z
--
apps_ :: Foldable f => Term a n -> f (Term a n) -> Term a n
apps_ = foldl' app_

-- | Let smart constructor.
--
-- >>> pp $ let_ "x" (delay_ "foo") $ let_ "y" (delay_ "bar") "body"
-- let* x = \ ~ -> foo
--      y = \ ~ -> bar
-- in body
--
let_ :: Text -> Term Text n -> Term Text n -> Term Text n
let_ n t s = mkLet (Name n) t (abstract1 n s)

-- | Functioa nbstraction smart constructor.
--
-- >>> pp $ lam_ "x" $ "x" :@ "x"
-- \ x -> x x
--
lam_ :: Text -> Term Text n -> Term Text n
lam_ n t = Defn (Lam (Name n) (abstract1 n t))

-- | Functioa nbstraction for multiple arguments.
--
-- >>> pp $ lams_ ["x", "f"] $ "f" :@ "x"
-- \ x f -> f x
--
lams_ :: [Text] -> Term Text n -> Term Text n
lams_ n t = foldr lam_ t n

-- | Fixed-point
--
-- >>> pp fix_
-- let* fix = \ f -> let* s = \ s0 x -> f (s0 s0) x in s s
-- in fix
--
fix_ :: Term a n
fix_ = Defn (Neutral HeadFix Seq.Empty)

-- |
--
-- >>> pp $ fst_ "foo"
-- let* fstPair!! = fstPair# ! !
-- in fstPair!! foo
--
fst_ :: Term a n -> Term a n
fst_ (Defn (Neutral h xs)) = Defn (Neutral h (xs Seq.|> Fst))
fst_ (Defn (Delay _))   = Error
fst_ (Defn Lam {})      = Error
fst_ (Defn Constant {}) = Error -- TODO
fst_ (Let n t s)        = Let n t (fst_ s)
fst_ Error              = Error

-- |
--
-- >>> pp $ snd_ "bar"
-- let* sndPair!! = sndPair# ! !
-- in sndPair!! bar
--
snd_ :: Term a n -> Term a n
snd_ (Defn (Neutral h xs)) = Defn (Neutral h (xs Seq.|> Snd))
snd_ (Defn (Delay _))   = Error
snd_ (Defn Lam {})      = Error
snd_ (Defn Constant {}) = Error -- TODO
snd_ (Let n t s)        = Let n t (snd_ s)
snd_ Error              = Error

-- | If-then-else
ite_ :: Term a n
ite_ = Builtin IfThenElse

-- | Trace
trace_ :: Term a n
trace_ = Builtin Trace

-- | String constant.
str_ :: Text -> Term a n
str_ t = Defn (Constant (Some (ValueOf DefaultUniString t)))

-- | Builtin unit constant.
tt_ :: Term a n
tt_ = Defn (Constant (Some (ValueOf DefaultUniUnit ())))

-------------------------------------------------------------------------------
-- * Conversion
-------------------------------------------------------------------------------

-- | Convert 'Term' to 'Raw'.
toRaw :: Term a n -> Raw a n
toRaw t =
    rawLet "fix"       (RawFix "f" "s" "s0" "x") $
    rawLet "fstPair!!" (Raw.Force $ Raw.Force $ Raw.Builtin FstPair) $
    rawLet "sndPair!!" (Raw.Force $ Raw.Force $ Raw.Builtin SndPair) $
    id t'
  where
    t' = rename (mkRen $ VS . VS . VS) (toRaw' t) >>== \aux -> case aux of
        Aux a      -> Raw.Free a
        AuxFix     -> Raw.Var (VS (VS VZ))
        AuxFstPair -> Raw.Var (VS VZ)
        AuxSndPair -> Raw.Var VZ

    rawLet :: Name -> Raw a n -> Raw a (S n) -> Raw a n
    rawLet name term s
        | Just s' <- bound unusedVar s = s'
        | otherwise                    = Raw.Let name term s

toRaw' :: Term a n -> Raw (Aux a) n
toRaw' Error          = Raw.Error
toRaw' (Defn i)       = defnToRaw i
toRaw' (Let n t s)    = Raw.Let n (defnToRaw t) (toRaw' s)

data Aux a
    = Aux a
    | AuxFix
    | AuxFstPair
    | AuxSndPair

elimToRaw :: Elim a n -> Raw.Arg (Aux a) n
elimToRaw (App t) = Raw.ArgTerm (toRaw' t)
elimToRaw Force   = Raw.ArgForce
elimToRaw Fst     = Raw.ArgFun (Raw.Free AuxFstPair)
elimToRaw Snd     = Raw.ArgFun (Raw.Free AuxSndPair)

headToRaw :: Head a n -> Raw (Aux a) n
headToRaw (HeadVar x)     = Raw.Var x
headToRaw HeadFix         = Raw.Free AuxFix
headToRaw (HeadFree x)    = Raw.Free (Aux x)
headToRaw (HeadBuiltin b) = Raw.Builtin b

defnToRaw :: Defn a n -> Raw (Aux a) n
defnToRaw (Neutral h xs) = Raw.appArgs_ (headToRaw h) (map elimToRaw (toList xs))
defnToRaw (Constant c)   = Raw.Constant c
defnToRaw (Delay t)      = Raw.Delay (toRaw' t)
defnToRaw (Lam n t)      = Raw.Lam n (toRaw' t)

-- | Convert 'Raw' to 'Term'.
fromRaw :: Raw a n -> Term a n
fromRaw (RawFix _ _ _ _) = Defn (Neutral HeadFix Seq.Empty)
-- fromRaw (Raw.Force (Raw.Force (Raw.Builtin FstPair)) Raw.:@ t) = fst_ (fromRaw t)
-- fromRaw (Raw.Force (Raw.Force (Raw.Builtin SndPair)) Raw.:@ t) = snd_ (fromRaw t)
fromRaw (Raw.Var x)      = Var x
fromRaw (Raw.Free x)     = Free x
fromRaw (Raw.Builtin FstPair) = Defn $ Delay $ Defn $ Delay $ Defn $ Lam "p" $ fst_ Var0
fromRaw (Raw.Builtin SndPair) = Defn $ Delay $ Defn $ Delay $ Defn $ Lam "q" $ snd_ Var0
fromRaw (Raw.Builtin b)  = Builtin b
fromRaw (Raw.Constant c) = Defn (Constant c)
fromRaw (Raw.Lam n t)    = Defn (Lam n (fromRaw t))
fromRaw (Raw.Delay t)    = Defn (Delay (fromRaw t))
fromRaw (Raw.App f t)    = app_ (fromRaw f) (fromRaw t)
fromRaw (Raw.Let n t s)  = mkLet n (fromRaw t) (fromRaw s)
fromRaw (Raw.Force t)    = force_ (fromRaw t)
fromRaw Raw.Error        = Error

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{- |
lensref core API
-}
module LensRef
    ( -- * Monads
      RefReader            -- RefReader
    , RefCreator           -- RefCreator
    , RefWriter            -- RefWriter
    , readerToWriter
    , readerToCreator
    , runRefCreator        -- runRefCreator

    -- * References
    , Ref
    , readRef
    , writeRef
    , modRef
    , joinRef
    , lensMap
    , unitRef
    , newRef

    -- * composed with register
    , memoRead
    , extendRef
    , onChange
    , onChange_
    , onChangeEq
    , onChangeEq_
    , onChangeEqOld
--    , onChangeEqOld'
    , onChangeMemo

    -- * Other
    , currentValue
    , RegionStatusChange (..)
    , onRegionStatusChange
    , onRegionStatusChange_

    -- * Reference context
    , RefContext (..)
    ) where

import Data.Maybe
import Data.String
import Data.IORef
import Data.STRef
import qualified Data.IntMap.Strict as Map
import Control.Applicative
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State.Strict
import Control.Monad.ST
import Lens.Family2
import Lens.Family2.Stock
import Lens.Family2.State.Strict

import Unsafe.Coerce

----------------------------------- data types

-- | reference temporal state
data RefState m where
    RefState
        :: a        -- reference value
        -> TIds m   -- registered triggers (run them if the value changes)
        -> RefState m

-- | trigger temporal state
data TriggerState m = TriggerState
    { _alive        :: Bool
    , _targetid     :: (Id m)     -- ^ target reference id
    , _dependencies :: (Ids m)    -- ^ source reference ids
    , _updateFun    :: (RefCreator m ())     -- ^ what to run if at least one of the source ids changes
    , _reverseDeps  :: (TIds m)   -- ^ reverse dependencies (temporarily needed during topological sorting)
    }


-----------------------

-- | global variables
data GlobalVars m = GlobalVars
    { _handlercollection  :: !(SimpleRef m (Handler m))  -- ^ collected handlers
    , _dependencycoll     :: !(SimpleRef m (Ids m))      -- ^ collected dependencies
    , _postpone           :: !(SimpleRef m (RefCreator m ()))       -- ^ postponed actions
    , _counter            :: !(SimpleRef m Int)          -- ^ increasing counter
    }

-- | reference identifier
type Id  m = OrdRef m (RefState m)
-- | reference identifiers
type Ids m = OrdRefSet m (RefState m)

-- | trigger identifier
type TId  m = OrdRef m (TriggerState m)
-- | trigger identifiers
type TIds m = OrdRefSet m (TriggerState m)

-- | IORef with Ord instance
type OrdRef    m a = (Int, SimpleRef m a)
-- | IORefs with Ord instance
type OrdRefSet m a = Map.IntMap (SimpleRef m a)

------------- data types for computations

-- reference reader monad
newtype RefReader m a
    = RefReader { runRefReader :: RefCreator m a }
        deriving (Monad, Applicative, Functor, MonadFix)

-- reference creator monad
newtype RefCreator m a
    = RefCreator { unRefCreator :: GlobalVars m -> m a }

-- reference writer monad
newtype RefWriter m a
    = RefWriter { runRefWriterT :: RefCreator m a }
        deriving (Monad, Applicative, Functor, MonadFix)

-- trigger handlers
-- The registered triggers may be killed, blocked and unblocked via the handler.
type Handler m = RegionStatusChange -> RefCreator m ()

type HandT = RefCreator

------------------------------

instance RefContext m => RefContext (RefCreator m) where
    type SimpleRef (RefCreator m) = SimpleRef m
    newSimpleRef = lift . newSimpleRef
    readSimpleRef = lift . readSimpleRef
    writeSimpleRef r = lift . writeSimpleRef r

------------------------------

newReadReference :: forall m a . RefContext m => a -> (a -> RefCreator m a) -> RefCreator m (RefReader m a)
newReadReference a0 ma = do

    (ih, a1) <- getDependency $ ma a0

    if Map.null ih
      then return $ pure a1
      else do
        i <- newId
        oir <- newSimpleRef $ RefState a1 mempty

        regTrigger (i, oir) ih ma

        return $ RefReader $ getVal oir i

getVal oir i = do
    RefState a' _ <- readSimpleRef oir
    r <- RefCreator $ return . _dependencycoll
    dp <- readSimpleRef r
    writeSimpleRef r $ Map.insert i oir dp
    return $ unsafeCoerce a'


newReference :: forall m a . RefContext m => a -> RefCreator m (Ref m a)
newReference a0 = do

    i <- newId
    oir <- newSimpleRef $ RefState a0 mempty

    let am :: RefReader m a
        am = RefReader $ getVal oir i

    let unsafeWriterToCreator rep init upd = do

            RefState aold_ nas <- readSimpleRef oir
            let aold = unsafeCoerce aold_ :: a

            let ma = upd

            (ih, a) <- getDependency $ ma aold

            when init $ do

                writeSimpleRef oir $ RefState a nas

                when (not $ Map.null nas) $ do

                    let ch :: TId m -> RefCreator m [TId m]
                        ch (_, n) = do
                            TriggerState _ (_, w) dep _ _ <- readSimpleRef n
                            RefState _ revDep <- readSimpleRef w
                            ls <- flip filterM (Map.toList revDep) $ \(_, na) -> do
                                TriggerState _alive (i, _) _ _ _ <- readSimpleRef na
                                pure $ {-alive &&-} not (Map.member i dep)
                            return ls

                        collects p = mapM_ (collect p) =<< ch p

                        collect (i, op) v@(_, ov) = do
                            ts <- readSimpleRef ov
                            writeSimpleRef ov $ ts { _reverseDeps = Map.insert i op $ _reverseDeps ts }
                            when (Map.null $ _reverseDeps ts) $ collects v

                    let as = Map.toList nas
--                    as <- (`filterM` Map.toList nas) $ \(_, na) -> readSimpleRef na <&> _alive
                    mapM_ collects as

                    let topSort [] = return $ pure ()
                        topSort (p@(i, op):ps) = do
                            act <- readSimpleRef op <&> _updateFun

                            let del (_, n) = do
                                    ts <- readSimpleRef n
                                    let rd = Map.delete i $ _reverseDeps ts
                                    writeSimpleRef n $ ts { _reverseDeps = rd }
                                    return $ Map.null rd
                            ys <- filterM del =<< ch p
                            acts <- topSort $ mergeBy (\(i, _) (j, _) -> compare i j) ps ys
                            return $ act >> acts

                        del' (_, n) = readSimpleRef n <&> Map.null . _reverseDeps

                    join $ topSort =<< filterM del' as

                    pr <- RefCreator $ return .  _postpone

                    p <- readSimpleRef pr
                    writeSimpleRef pr $ return ()
                    p

            when (rep && not (Map.null ih)) $ regTrigger (i, oir) ih ma

    pure $ Ref $ \ff ->
        buildRefAction ff am
            (RefWriter . unsafeWriterToCreator False True . (return .))
            (unsafeWriterToCreator True)


regTrigger :: forall m a . RefContext m => Id m -> Ids m -> (a -> RefCreator m a) -> RefCreator m ()
regTrigger (i, oir) ih ma = do

    j <- newId
    ori <- newSimpleRef $ error "impossible"

    let addRev, delRev :: SimpleRef m (RefState m) -> RefCreator m ()
        addRev x = modSimpleRef x $ revDep %= Map.insert j ori
        delRev x = modSimpleRef x $ revDep %= Map.delete j

        modReg = do

            RefState aold nas <- readSimpleRef oir

            (ih, a) <- getDependency $ ma $ unsafeCoerce aold

            writeSimpleRef oir $ RefState a nas

            ts <- readSimpleRef ori
            writeSimpleRef ori $ ts { _dependencies = ih }
            let ih' = _dependencies ts

            mapM_ delRev $ Map.elems $ ih' `Map.difference` ih
            mapM_ addRev $ Map.elems $ ih `Map.difference` ih'

    writeSimpleRef ori $ TriggerState True (i, oir) ih modReg mempty

    mapM_ addRev $ Map.elems ih

    tellHand $ \msg -> do

        ts <- readSimpleRef ori
        writeSimpleRef ori $ ts { _alive = msg == Unblock }

        when (msg == Kill) $
            mapM_ delRev $ Map.elems $ _dependencies ts

        pr <- RefCreator $ return . _postpone

        -- TODO
        when (msg == Unblock) $
            modSimpleRef pr $ modify (>> _updateFun ts)

readRef__ :: RefContext m => Ref m a -> RefCreator m a
readRef__ r = readerToCreator $ readRef r

newRef :: RefContext m => a -> RefCreator m (Ref m a)
newRef a = newReference a

extendRef :: RefContext m => Ref m b -> Lens' a b -> a -> RefCreator m (Ref m a)
extendRef m k a0 = do
    r <- newReference a0
    -- TODO: remove getHandler?
    _ <- getHandler $ do
        register r True $ \a -> readerToCreator $ readRef m <&> \b -> set k b a
        register m False $ \_ -> readRef__ r <&> (^. k)
    return r

onChange :: RefContext m => RefReader m a -> (a -> RefCreator m b) -> RefCreator m (RefReader m b)
onChange m f = do
    r <- newReadReference (const $ pure (), error "impossible #4") $ \(h, _) -> do
        a <- readerToCreator m
        noDependency $ do
            h Kill
            getHandler $ f a
    tellHand $ \msg -> do
        (h, _) <- readerToCreator r
        h msg
    return $ r <&> snd


onChange_ :: RefContext m => RefReader m a -> (a -> RefCreator m b) -> RefCreator m (Ref m b)
onChange_ m f = do
    r <- newReference (const $ pure (), error "impossible #3")
    register r True $ \(h', _) -> do
        a <- readerToCreator m
        noDependency $ do
            h' Kill
            (h, b) <- getHandler $ f a
            return (h, b)
    tellHand $ \msg -> do
        (h, _) <- readRef__ r
        h msg

    return $ lensMap _2 r

onChangeEq :: (Eq a, RefContext m) => RefReader m a -> (a -> RefCreator m b) -> RefCreator m (RefReader m b)
onChangeEq m f = do
    r <- newReadReference (const False, (const $ pure (), error "impossible #3")) $ \it@(p, (h, _)) -> do
        a <- readerToCreator m
        noDependency $ if p a
          then return it
          else do
            h Kill
            hb <- getHandler $ f a
            return ((== a), hb)
    tellHand $ \msg -> do
        (_, (h, _)) <- readerToCreator r
        h msg

    return $ r <&> snd . snd

onChangeEqOld :: (Eq a, RefContext m) => RefReader m a -> (a -> a -> RefCreator m b) -> RefCreator m (RefReader m b)
onChangeEqOld m f = do
    x <- readerToCreator m
    r <- newReadReference ((x, const False), (const $ pure (), error "impossible #3")) $ \it@((x, p), (h, _)) -> do
        a <- readerToCreator m
        noDependency $ if p a
          then return it
          else do
            h Kill
            hb <- getHandler $ f x a
            return ((a, (== a)), hb)
    tellHand $ \msg -> do
        (_, (h, _)) <- readerToCreator r
        h msg

    return $ r <&> snd . snd
{-
onChangeEqOld' :: (Eq a, RefContext m) => RefReader m a -> b -> (Ref m b -> a -> b -> RefCreator m b) -> RefCreator m (RefReader m b)
onChangeEqOld' m b0 f = do
    r <- newReference ((const False), (const $ pure (), b0))
    register r True $ \it@(p, (h, b)) -> do
        a <- readerToCreator m
        noDependency $ if p a
          then return it
          else do
            h Kill
            hb <- getHandler $ f (lensMap (_2 . _2) r) a b
            return ((== a), hb)
    tellHand $ \msg -> do
        (_, (h, _)) <- readerToCreator $ readRef r
        h msg

    return $ readRef r <&> snd . snd
-}
onChangeEq_ :: (Eq a, RefContext m) => RefReader m a -> (a -> RefCreator m b) -> RefCreator m (Ref m b)
onChangeEq_ m f = do
    r <- newReference (const False, (const $ pure (), error "impossible #3"))
    register r True $ \it@(p, (h', _)) -> do
        a <- readerToCreator m
        noDependency $ if p a
          then return it
          else do
            h' Kill
            (h, b) <- getHandler $ f a
            return ((== a), (h, b))
    tellHand $ \msg -> do
        (_, (h, _)) <- readRef__ r
        h msg

    return $ lensMap (_2 . _2) r

onChangeMemo :: (RefContext m, Eq a) => RefReader m a -> (a -> RefCreator m (RefCreator m b)) -> RefCreator m (RefReader m b)
onChangeMemo mr f = do
    r <- newReadReference ((const False, ((error "impossible #2", const $ pure (), const $ pure ()) , error "impossible #1")), [])
      $ \st'@((p, ((m'',h1'',h2''), _)), memo) -> do
        let it = (p, (m'', h1''))
        a <- readerToCreator mr
        noDependency $ if p a
          then return st'
          else do
            h2'' Kill
            h1'' Block
            case listToMaybe [ b | (p, b) <- memo, p a] of
              Just (m',h1') -> do
                h1' Unblock
                (h2, b') <- getHandler m'
                return (((== a), ((m',h1',h2), b')), it: filter (not . ($ a) . fst) memo)
              Nothing -> do
                (h1, m_) <- getHandler $ f a
                let m' = m_
                (h2, b') <- getHandler m'
                return (((== a), ((m',h1,h2), b')), it: memo)

    tellHand $ \msg -> do
        ((_, ((_, h1, h2), _)), _) <- readerToCreator r
        h1 msg >> h2 msg

    return $ r <&> snd . snd . fst

onRegionStatusChange :: RefContext m => (RegionStatusChange -> m ()) -> RefCreator m ()
onRegionStatusChange h
    = tellHand $ lift . h

onRegionStatusChange_ :: RefContext m => (RegionStatusChange -> RefReader m (m ())) -> RefCreator m ()
onRegionStatusChange_ h
    = tellHand $ join . fmap lift . readerToCreator . h


runRefCreator
    :: RefContext m
    => ((forall b . RefWriter m b -> m b) -> RefCreator m a)
    -> m a
runRefCreator f = do
    s <- GlobalVars
            <$> newSimpleRef (const $ pure ())
            <*> newSimpleRef mempty
            <*> newSimpleRef (return ())
            <*> newSimpleRef 0
    flip unRefCreator s $ f $ flip unRefCreator s . runRefWriterT

-------------------- aux

register :: RefContext m => Ref m a -> Bool -> (a -> HandT m a) -> RefCreator m ()
register r init k = runRegisterAction (runRef r k) init

tellHand :: RefContext m => Handler m -> RefCreator m ()
tellHand h = do
    r <- RefCreator $ return . _handlercollection
    modSimpleRef r $ modify $ \f msg -> f msg >> h msg

getHandler :: RefContext m => RefCreator m a -> RefCreator m (Handler m, a)
getHandler m = do
    r <- RefCreator $ return . _handlercollection
    h' <- readSimpleRef r
    writeSimpleRef r $ const $ pure ()
    a <- m
    h <- readSimpleRef r
    writeSimpleRef r h'
    return (h, a)

noDependency :: RefContext m => RefCreator m a -> RefCreator m a
noDependency (RefCreator m) = RefCreator $ \st -> do
    ih <- readSimpleRef $ _dependencycoll st
    a <- m st
    writeSimpleRef (_dependencycoll st) ih
    return a

getDependency :: RefContext m => RefCreator m a -> RefCreator m (Ids m, a)
getDependency (RefCreator m) = RefCreator $ \st -> do
    ih' <- readSimpleRef $ _dependencycoll st       -- TODO: remove this
    writeSimpleRef (_dependencycoll st) mempty
    a <- m st
    ih <- readSimpleRef $ _dependencycoll st
    writeSimpleRef (_dependencycoll st) ih'       -- TODO: remove this
    return (ih, a)

newId :: RefContext m => RefCreator m Int
newId = RefCreator $ \(GlobalVars _ _ _ st) -> do
    c <- readSimpleRef st
    writeSimpleRef st $ succ c
    return c

revDep :: Lens' (RefState m) (TIds m)
revDep k (RefState a b) = k b <&> \b' -> RefState a b'

------------------------------------------------------- type class instances

instance RefContext m => Monoid (RefCreator m ()) where
    mempty = return ()
    m `mappend` n = m >> n

instance RefContext m => Monad (RefCreator m) where
    return = RefCreator . const . return
    RefCreator m >>= f = RefCreator $ \r -> m r >>= \a -> unRefCreator (f a) r

instance RefContext m => Applicative (RefCreator m) where
    pure = RefCreator . const . pure
    RefCreator f <*> RefCreator g = RefCreator $ \r -> f r <*> g r

instance RefContext m => Functor (RefCreator m) where
    fmap f (RefCreator m) = RefCreator $ fmap f . m

instance (RefContext m, MonadFix m) => MonadFix (RefCreator m) where
    mfix f = RefCreator $ \r -> mfix $ \a -> unRefCreator (f a) r

currentValue :: RefContext m => RefReader m a -> RefReader m a
currentValue = RefReader . noDependency . runRefReader

readRef :: RefContext m => Ref m a -> RefReader m a
readRef r = runReaderAction $ runRef r Const

readerToCreator :: RefContext m => RefReader m a -> RefCreator m a
readerToCreator = runRefReader

readerToWriter :: RefContext m => RefReader m a -> RefWriter m a
readerToWriter = RefWriter . readerToCreator

instance MonadTrans RefWriter where
    lift = RefWriter . lift

instance MonadTrans RefCreator where
    lift m = RefCreator $ \_ -> m

unsafeWriterToCreator :: RefContext m => RefWriter m a -> RefCreator m a
unsafeWriterToCreator = runRefWriterT

------------------------

newtype Ref m a = Ref { runRef :: Ref_ m a }

type Ref_ m a =
        forall f
        .  (RefAction f, RefActionCreator f ~ m)
        => (a -> RefActionFunctor f a)
        -> f ()

class ( Functor (RefActionFunctor f)
      , RefContext (RefActionCreator f)
      )
    => RefAction (f :: * -> *) where

    type RefActionFunctor f :: * -> *
    type RefActionCreator f :: * -> *

    buildRefAction
        :: (a -> RefActionFunctor f a)
        -> RefReader (RefActionCreator f) a
        -> ((a -> a) -> RefWriter (RefActionCreator f) ())
        -> RefRegOf (RefActionCreator f) a
        -> f ()

    joinRefAction :: RefReader (RefActionCreator f) (f ()) -> f ()

    buildUnitRefAction :: (() -> RefActionFunctor f ()) -> f ()

type RefRegOf m a = Bool -> (a -> HandT m a) -> RefCreator m ()


-------------------- reader action

newtype ReaderAction b m a = ReaderAction { runReaderAction :: RefReader m b }

instance RefContext m => RefAction (ReaderAction b m) where

    type RefActionFunctor (ReaderAction b m) = Const b
    type RefActionCreator (ReaderAction b m) = m

    buildRefAction f a _ _ = ReaderAction $ a <&> getConst . f
    joinRefAction m      = ReaderAction $ m >>= runReaderAction
    buildUnitRefAction f = ReaderAction $ pure $ getConst $ f ()


-------------------- writer action

newtype WriterAction m a = WriterAction { runWriterAction :: RefWriter m () }

instance RefContext m => RefAction (WriterAction m) where

    type RefActionFunctor (WriterAction m) = Identity
    type RefActionCreator (WriterAction m) = m

    buildRefAction f _ g _ = WriterAction $ g $ runIdentity . f
    joinRefAction m = WriterAction $ readerToWriter m >>= runWriterAction
    buildUnitRefAction _ = WriterAction $ pure ()

-------------------- register action

newtype RegisterAction m a = RegisterAction { runRegisterAction :: Bool -> RefCreator m a }

instance RefContext m => RefAction (RegisterAction m) where
    type RefActionFunctor (RegisterAction m) = HandT m
    type RefActionCreator (RegisterAction m) = m

    buildRefAction f _ _ g = RegisterAction $ \init -> g init f
    joinRefAction m = RegisterAction $ \init -> do

        r <- newReadReference (const $ pure ()) $ \kill -> do
            kill Kill
            noDependency . fmap fst . getHandler . ($ init) . runRegisterAction =<< readerToCreator m
        tellHand $ \msg -> readerToCreator r >>= ($ msg)

    buildUnitRefAction _ = RegisterAction $ const $ pure ()



infixr 8 `lensMap`

{- | Apply a lens on a reference.
-}
lensMap :: Lens' a b -> Ref m a -> Ref m b
lensMap k (Ref r) = Ref $ r . k

{- | unit reference
-}
unitRef :: RefContext m => Ref m ()
unitRef = Ref buildUnitRefAction

joinRef :: RefContext m => RefReader m (Ref m a) -> Ref m a
joinRef mr = Ref $ \f -> joinRefAction (mr <&> \r -> runRef r f)

----------------------

writeRef :: RefContext m => Ref m a -> a -> RefWriter m ()
writeRef (Ref r) = runWriterAction . r . const . Identity

---------------- aux

mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeBy _ [] xs = xs
mergeBy _ xs [] = xs
mergeBy p (x:xs) (y:ys) = case p x y of
    LT -> x: mergeBy p xs (y:ys)
    GT -> y: mergeBy p (x:xs) ys
    EQ -> x: mergeBy p xs ys

--------------------------------------------------------------------------------

-- | TODO
data RegionStatusChange = Kill | Block | Unblock deriving (Eq, Ord, Show)

modRef :: RefContext m => Ref m a -> (a -> a) -> RefWriter m ()
r `modRef` f = readerToWriter (readRef r) >>= writeRef r . f

memoRead :: RefContext m => RefCreator m a -> RefCreator m (RefCreator m a)
memoRead g = do
    s <- newRef Nothing
    pure $ readerToCreator (readRef s) >>= \x -> case x of
        Just a -> pure a
        _ -> g >>= \a -> do
            unsafeWriterToCreator $ writeRef s $ Just a
            pure a

--------------------------------------------------------------------------------

instance (IsString str, RefContext s) => IsString (RefReader s str) where
    fromString = pure . fromString

instance (RefContext s, Num a) => Num (RefReader s a) where
    (+) = liftA2 (+)
    (*) = liftA2 (*)
    negate = fmap negate
    abs    = fmap abs
    signum = fmap signum
    fromInteger = pure . fromInteger

instance (RefContext s, Fractional a) => Fractional (RefReader s a) where
    recip  = fmap recip
    fromRational = pure . fromRational


--------------------------------------------------------------------------------

infixl 1 <&>

{-# INLINE (<&>) #-}
(<&>) :: Functor f => f a -> (a -> b) -> f b
as <&> f = f <$> as

----------------

class (Monad m, Applicative m) => RefContext m where

    -- simple reference
    type SimpleRef m :: * -> *

    newSimpleRef   :: a -> m (SimpleRef m a)
    readSimpleRef  :: SimpleRef m a -> m a
    writeSimpleRef :: SimpleRef m a -> a -> m ()

modSimpleRef :: RefContext m => SimpleRef m a -> StateT a m b -> m b
modSimpleRef r s = do
    a <- readSimpleRef r
    (x, a') <- runStateT s a
    writeSimpleRef r a'
    return x

-------------------

instance RefContext IO where
    type SimpleRef IO = IORef

--    {-# INLINE newSimpleRef #-}
    newSimpleRef x = newIORef x
--    {-# INLINE readSimpleRef #-}
    readSimpleRef r = readIORef r
--    {-# INLINE writeSimpleRef #-}
    writeSimpleRef r a = writeIORef r a

instance RefContext (ST s) where
    type SimpleRef (ST s) = STRef s
    newSimpleRef = newSTRef
    readSimpleRef = readSTRef
    writeSimpleRef = writeSTRef

instance RefContext m => RefContext (ReaderT r m) where
    type SimpleRef (ReaderT r m) = SimpleRef m
    newSimpleRef = lift . newSimpleRef
    readSimpleRef = lift . readSimpleRef
    writeSimpleRef r = lift . writeSimpleRef r

instance (RefContext m, Monoid w) => RefContext (WriterT w m) where
    type SimpleRef (WriterT w m) = SimpleRef m
    newSimpleRef = lift . newSimpleRef
    readSimpleRef = lift . readSimpleRef
    writeSimpleRef r = lift . writeSimpleRef r


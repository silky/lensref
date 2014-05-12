{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}
{- |
Register reference implementation for the @MonadRefCreator@ interface.

The implementation uses @unsafeCoerce@ internally, but its effect cannot escape.
-}
module Data.LensRef.Pure
    ( Register
    , runRegister
    , runTests
    ) where

import Data.Monoid
import Control.Applicative
import Control.Monad.State
import Control.Monad.Reader
import Control.Arrow (second)
import qualified Data.Sequence as Seq
import Control.Lens hiding ((|>))
import Data.Foldable (toList)

import Unsafe.Coerce

import Data.LensRef
import Data.LensRef.Common
import Data.LensRef.TestEnv
import Data.LensRef.Test

----------------------

newtype instance RefWriterOf (ReaderT s m) a
    = RefWriterOfReaderT { runRefWriterOfReaderT :: StateT s m a }
        deriving (Monad, Applicative, Functor, MonadReader s, MonadState s)

----------------------

newtype Lens_ a b = Lens_ {unLens_ :: ALens' a b}

runLens_ :: Reader a (Lens_ a b) -> Lens' a b
runLens_ r f a = cloneLens (unLens_ $ runReader r a) f a

type LSt = Seq.Seq CC

data CC = forall a . CC (LSt -> a -> a) a

initLSt :: LSt
initLSt = empty

instance MonadRefReader (Reader LSt) where
    type BaseRef (Reader LSt) = Lens_ LSt
    liftRefReader = id

instance Monad m => MonadRefReader (RefWriterOf (ReaderT LSt m)) where
    type BaseRef (RefWriterOf (ReaderT LSt m)) = Lens_ LSt
    liftRefReader = RefWriterOfReaderT . gets . runReader

instance MonadRefWriter (RefWriterOf (Reader LSt)) where
    liftRefWriter = id

instance RefClass (Lens_ LSt) where
    type RefReaderSimple (Lens_ LSt) = Reader LSt

    readRefSimple = view . runLens_
    writeRefSimple r a = runLens_ r .= a
    lensMap l r = return $ Lens_ $ runLens_ r . l
    unitRef = return $ Lens_ united

instance Monad m => MonadRefReader (StateT LSt m) where
    type BaseRef (StateT LSt m) = Lens_ LSt

    liftRefReader = gets . runReader

instance Monad m => MonadRefCreator (StateT LSt m) where
    extRef r r2 a0 = state extend
      where
        rk = set (runLens_ r) . (^. r2)
        kr = set r2 . (^. runLens_ r)

        extend x0 = (return $ Lens_ $ lens get set, x0 Seq.|> CC kr (kr x0 a0))
          where
            limit = second toList . Seq.splitAt (Seq.length x0)

            get = unsafeData . head . snd . limit

            set x a = foldl (\x -> (Seq.|>) x . ap_ x) (rk a zs Seq.|> CC kr a) ys where
                (zs, _ : ys) = limit x

        ap_ :: LSt -> CC -> CC
        ap_ x (CC f a) = CC f (f x a)

        unsafeData :: CC -> a
        unsafeData (CC _ a) = unsafeCoerce a


instance Monad m => MonadMemo (StateT LSt m) where
    memoRead = memoRead_

--instance MonadMemo (RefWriterOf (Reader LSt)) where
--    memoRead = memoRead_

instance Monad m => MonadRefWriter (StateT LSt m) where
    liftRefWriter = state . runState . runRefWriterOfReaderT


---------------------------------


type Register_ n m
    = ReaderT (Ref m (MonadMonoid m, RegisteredCallbackCommand -> MonadMonoid n)) m

newtype Register n a
    = Register { unRegister :: ReaderT (SLSt n () -> n ()) (Register_ n (SLSt n)) a }
        deriving (Monad, Applicative, Functor)

type SLSt = StateT LSt
{-
mapReg :: (forall a . m a -> n a) -> Register m a -> Register n a
mapReg ff (Register m) = Register $ ReaderT $ \f -> ReaderT $ \r -> StateT $ \s -> 
    ff $ flip runStateT s $ flip runReaderT (iso undefined undefined `lensMap` r) $ runReaderT m $ undefined f
-}
instance MonadTrans Register where
    lift = Register . lift . lift . lift

instance MonadFix m => MonadFix (Register m) where
    mfix f = Register $ mfix $ unRegister . f

instance Monad m => MonadRefReader (Register m) where

    type BaseRef (Register n) = Lens_ LSt

    liftRefReader = Register . lift . lift . liftRefReader

instance Monad n => MonadRefCreator (Register n) where
    extRef r l = Register . lift . lift . extRef r l
    newRef = Register . lift . lift . newRef

instance Monad m => MonadMemo (Register m) where
    memoRead = memoRead_
{-
    memoWrite = memoWrite_
    future = future_
-}
instance Monad n => MonadRefWriter (Register n) where
    liftRefWriter = Register . lift . lift . liftRefWriter

instance Monad n => MonadRegister (Register n) where

    type EffectM (Register n) = n

    liftEffectM = lift

    newtype Modifier (Register n) a = RegW {unRegW :: Register n a} deriving (Monad, Applicative, Functor)

    liftModifier = RegW

    onChangeAcc r b0 c0 f = Register $ ReaderT $ \ff ->
        toSend lift r b0 c0 $ \b b' c' -> liftM (\x -> evalRegister ff . x) $ evalRegister ff $ f b b' c'

    registerCallback f = Register $ ReaderT $ \ff -> do
        writerstate <- ask
        return $ fmap (ff . flip runReaderT writerstate . evalRegister ff . unRegW) f

    getRegionStatus g = Register $ ReaderT $ const $ tell' (mempty, MonadMonoid . g)

instance Monad m => MonadRefWriter (Modifier (Register m)) where
    liftRefWriter = RegW . liftRefWriter

instance Monad m => MonadRefReader (Modifier (Register m)) where

    type BaseRef (Modifier (Register m)) = Lens_ LSt

    liftRefReader = RegW . liftRefReader

instance Monad m => MonadRefCreator (Modifier (Register m)) where
    extRef r l = RegW . extRef r l
    newRef = RegW . newRef

instance Monad m => MonadMemo (Modifier (Register m)) where
    memoRead = memoRead_
{-
    memoWrite = memoWrite_
    future = future_
-}
instance MonadFix m => MonadFix (Modifier (Register m)) where
    mfix f = RegW $ mfix $ unRegW . f


evalRegister ff (Register m) = runReaderT m ff

runRegister :: Monad m => (forall a . m (m a, a -> m ())) -> Register m a -> m (a, m ())
runRegister newChan (Register m) = do
    (read, write) <- newChan
    runRegister_ read write (Register m)


runRegister_ :: Monad m => m (SLSt m ()) -> (SLSt m () -> m ()) -> Register m a -> m (a, m ())
runRegister_ read write (Register m) = do
    ((a, tick), s) <- flip runStateT initLSt $ do
        (a, r) <- runRefWriterT $ runReaderT m write
        (w, _) <- readRef r
        return (a, runMonadMonoid w)
    let eval s = do
            m <- read
            s <- flip execStateT s $ do
                m
                tick
            eval s
    return $ (,) a $ eval s

------------------------------------

toSend
    :: (Eq b, MonadRefCreator m, MonadRefWriter m, Monad n)
    => (n () -> m ())
    -> RefReader m b
    -> b -> (b -> c)
    -> (b -> b -> c -> {-Either (Register m c)-} Register_ n m (c -> Register_ n m c))
    -> Register_ n m (RefReader m c)
toSend li rb b0 c0 fb = do
    let doit st = readRef st >>= runMonadMonoid . fst
        reg st msg = readRef st >>= li . runMonadMonoid . ($ msg) . snd

    memoref <- lift $ do
        b <- liftRefReader rb
        (c, st1) <- runRefWriterT $ fb b b0 $ c0 b0
        (val, st2) <- runRefWriterT $ c $ c0 b0
        doit st1
        doit st2
        newRef ((b, (c, val, st1, st2)), [])      -- memo table

    let act = MonadMonoid $ do
            b <- liftRefReader rb
            (last@(b', cc@(_, oldval, st1, st2)), memo) <- readRef memoref
            (_, _, st1, st2) <- if b' == b
              then
                return cc
              else do
                reg st1 Block
                reg st2 Kill
                (c, oldval', st1, _) <- case lookup b memo of
                  Nothing -> do
                    (c, st1) <- runRefWriterT $ fb b b' oldval
                    return (c, c0 b, st1, undefined)
                  Just cc'@(_, _, st1, _) -> do
                    reg st1 Unblock
                    return cc'
                (val, st2) <- runRefWriterT $ c oldval'
                let cc = (c, val, st1, st2)
                writeRef memoref ((b, cc), filter ((/= b) . fst) (last:memo))
                return cc
            doit st1
            doit st2

    tell' (act, mempty)
    return $ readRef $ (_1 . _2 . _2) `lensMap` memoref

------------------------

instance MonadRegisterRun (Register (Prog TP)) where

    type AsocT (Register (Prog TP)) = TP

    runReg r w m = runRegister_ (liftM unTP r) (w . TP) m

newtype TP = TP { unTP :: SLSt (Prog TP) () }

runTests = do
    mkTests runTestSimple
    tests runTest

runTest :: (Eq a, Show a) => Register (Prog TP) a -> Prog' (a, Prog' ()) -> IO ()
runTest = runTest_ (TP . lift) runReg

runTestSimple :: Register (Prog TP) () -> IO ()
runTestSimple m = runTest m $ return ((), return ())




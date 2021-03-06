{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
-- | This module defines a 'Monad' for the binary rewriter.
--
-- The monad basically provides facilities to allocate symbolic
-- addresses for code relocation, and also provides for error
-- handling.
module Renovate.Redirect.Monad (
  SomeAddr(..),
  Diagnostic(..),
  Rewriter,
  RewriterT,
  SymbolMap,
  NewSymbolsMap,
  RewriterState(..),
  Diagnostics,
  RewriterResult(..),
  runRewriterT,
  throwError,
  logDiagnostic,
  askISA,
  askMem,
  askSymbolMap,
  putNewSymbolsMap,
  getNewSymbolsMap,
  recordUnrelocatableTermBlock,
  recordIncompleteBlock,
  recordUnrelocatableSize,
  recordReusedBytes,
  recordBlockMap,
  ) where


import qualified Control.Monad.Catch as E
import qualified Control.Monad.Except as ET
import qualified Control.Monad.RWS.Strict as RWS
import qualified Control.Monad.Trans as T
import qualified Data.Functor.Identity as I
import           Data.Monoid
import qualified Data.Sequence as Seq

import           Prelude

import qualified Data.Macaw.CFG as MM

import           Renovate.Address
import           Renovate.ISA
import           Renovate.Diagnostic
import           Renovate.Rewrite ( HasInjectedFunctions )
import           Renovate.Recovery.SymbolMap ( SymbolMap, NewSymbolsMap )

data SomeAddr a = Addr32 (a 32)
                | Addr64 (a 64)

deriving instance (Eq (a 32), Eq (a 64)) => Eq (SomeAddr a)
deriving instance (Ord (a 32), Ord (a 64)) => Ord (SomeAddr a)
deriving instance (Show (a 32), Show (a 64)) => Show (SomeAddr a)

-- | Reader data for 'RewriterT'.
data RewriterEnv arch = RewriterEnv
  { reISA       :: !(ISA arch)
  , reMem       :: !(MM.Memory (MM.ArchAddrWidth arch))
  , reSymbolMap :: !(SymbolMap arch)
  }

-- | State data for 'RewriterT'.
data RewriterState arch = RewriterState
  { rwsNewSymbolsMap         :: !(NewSymbolsMap arch)
  , rwsUnrelocatableTerm     :: !Int
  -- ^ Count of blocks unrelocatable due to ending in an IP-relative indirect jump
  , rwsSmallBlockCount       :: !Int
  -- ^ Count of blocks unrelocatable due to being too small to redirect
  , rwsReusedByteCount       :: !Int
  -- ^ Count of bytes re-used by the compact layout strategy
  , rwsIncompleteBlocks      :: !Int
  -- ^ Count of blocks that are in incomplete functions
  , rwsBlockMapping          :: [(ConcreteAddress arch, ConcreteAddress arch)]
  -- ^ A mapping of original block addresses to the address they were redirected to
  }
deriving instance (MM.MemWidth (MM.ArchAddrWidth arch)) => Show (RewriterState arch)

-- | Result data of 'RewriterT', the combination of state and writer results.
data RewriterResult arch = RewriterResult
  { rrState :: RewriterState arch
  , rrDiagnostics :: Diagnostics
  }

-- | The base 'Monad' for the binary rewriter and relocation code.
--
-- It provides a source for symbolic addresses and provides error
-- handling facilities.
newtype RewriterT arch m a =
  RewriterT { unRewriterT :: ET.ExceptT E.SomeException
                                        (RWS.RWST (RewriterEnv arch)
                                                  Diagnostics
                                                  (RewriterState arch)
                                                  m)
                                         a
            }
  deriving (Applicative,
            Functor,
            Monad,
            RWS.MonadReader (RewriterEnv arch),
            RWS.MonadState  (RewriterState arch),
            RWS.MonadWriter Diagnostics,
            ET.MonadError E.SomeException)

instance T.MonadIO m => T.MonadIO (RewriterT arch m) where
  liftIO = RewriterT . T.liftIO

-- | A 'RewriterT' over the 'I.Identity' 'Monad'
type Rewriter arch a = RewriterT arch I.Identity a

instance T.MonadTrans (RewriterT arch) where
  lift m = RewriterT $ ET.ExceptT $ do
    res <- RWS.RWST $ \_ s -> do
      a <- m
      return (a, s, mempty)
    return (Right res)

-- | The initial state of the 'Rewriter' 'Monad'
initialState :: RewriterState arch
initialState =  RewriterState
  { rwsNewSymbolsMap         = mempty
  , rwsUnrelocatableTerm     = 0
  , rwsSmallBlockCount       = 0
  , rwsReusedByteCount       = 0
  , rwsIncompleteBlocks      = 0
  , rwsBlockMapping          = []
  }

-- | Run a 'RewriterT' computation.
--
-- It returns *all* diagnostics that occur before an exception is
-- thrown.
--
-- FIXME: This needs the set of input additional blocks that are allocated symbolic addresses
runRewriterT :: (Monad m, HasInjectedFunctions m arch)
             => ISA arch
             -> MM.Memory (MM.ArchAddrWidth arch)
             -> SymbolMap arch
             -> RewriterT arch m a
             -> m (Either E.SomeException a, RewriterResult arch)
runRewriterT isa mem symmap a = do
  let env = RewriterEnv isa mem symmap
  (r, s, w) <- RWS.runRWST (ET.runExceptT (unRewriterT a)) env initialState
  return (r, RewriterResult s w)

-- | Log a diagnostic in the 'RewriterT' monad
logDiagnostic :: (Monad m) => Diagnostic -> RewriterT arch m ()
logDiagnostic = RWS.tell . Diagnostics . Seq.singleton

-- | Throw an error that halts the 'RewriterT' monad.
throwError :: (E.Exception e, Monad m) => e -> RewriterT arch m a
throwError = ET.throwError . E.SomeException

-- | Read the 'ISA' from the 'RewriterT' environment
askISA :: (Monad m) => RewriterT arch m (ISA arch)
askISA = reISA <$> RWS.ask

askMem :: (Monad m) => RewriterT arch m (MM.Memory (MM.ArchAddrWidth arch))
askMem = reMem <$> RWS.ask

askSymbolMap :: Monad m => RewriterT arch m (SymbolMap arch)
askSymbolMap = reSymbolMap <$> RWS.ask

putNewSymbolsMap :: Monad m => NewSymbolsMap arch -> RewriterT arch m ()
putNewSymbolsMap symmap = do
  s <- RWS.get
  RWS.put $! s { rwsNewSymbolsMap = symmap }

getNewSymbolsMap :: Monad m => RewriterT arch m (NewSymbolsMap arch)
getNewSymbolsMap = do
  s <- RWS.get
  return $! rwsNewSymbolsMap s

recordUnrelocatableTermBlock :: (Monad m) => RewriterT arch m ()
recordUnrelocatableTermBlock = do
  s <- RWS.get
  RWS.put $! s { rwsUnrelocatableTerm = rwsUnrelocatableTerm s + 1 }

recordUnrelocatableSize :: (Monad m) => RewriterT arch m ()
recordUnrelocatableSize = do
  s <- RWS.get
  RWS.put $! s { rwsSmallBlockCount = rwsSmallBlockCount s + 1 }

recordReusedBytes :: (Monad m) => Int -> RewriterT arch m ()
recordReusedBytes nBytes = do
  s <- RWS.get
  RWS.put $! s { rwsReusedByteCount = rwsReusedByteCount s + nBytes }

recordBlockMap :: (Monad m) => [(ConcreteAddress arch, ConcreteAddress arch)] -> RewriterT arch m ()
recordBlockMap m = do
  s <- RWS.get
  RWS.put $! s { rwsBlockMapping = m }

recordIncompleteBlock :: (Monad m) => RewriterT arch m ()
recordIncompleteBlock = do
  s <- RWS.get
  RWS.put $! s { rwsIncompleteBlocks = rwsIncompleteBlocks s + 1 }
